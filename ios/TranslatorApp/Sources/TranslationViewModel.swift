import SwiftUI
import ReplayKit
import AVFoundation
import WhisperKit
import Translation

class TranslationViewModel: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isModelLoading = false
    @Published var modelLoadError: String?

    @Published var isTranslating = false
    @Published var isScreenSharing = false
    @Published var originalText = ""
    @Published var translatedText = ""
    @Published var detectedLanguage = ""
    @Published var translationHistory: [(original: String, translated: String, language: String)] = []

    @Published var selectedModel = "base"
    @Published var targetLanguage = "zh-Hans"
    @Published var availableModels = ["tiny", "base", "small", "medium", "large-v3-turbo"]
    @Published var availableTargetLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("ru", "Русский"),
        ("pt-BR", "Português"),
    ]

    // Translation: AsyncStream feeds text to .translationTask in the view
    private(set) var translationStream: AsyncStream<String>
    private var translationContinuation: AsyncStream<String>.Continuation?

    private var whisperKit: WhisperKit?
    private let screenRecorder = RPScreenRecorder.shared()
    private var audioEngine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private let bufferQueue = DispatchQueue(label: "audio.buffer")
    private let chunkDuration: Double = 2.0
    private let targetSampleRate: AVAudioFrameCount = 16000

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(10))
        self.translationStream = stream
        self.translationContinuation = continuation
    }

    deinit {
        translationContinuation?.finish()
    }

    // MARK: - Model Loading

    func loadModel() async {
        await MainActor.run {
            isModelLoading = true
            modelLoadError = nil
        }

        do {
            let kit = try await WhisperKit(model: selectedModel)
            self.whisperKit = kit
            await MainActor.run {
                isModelLoaded = true
                isModelLoading = false
            }
        } catch {
            await MainActor.run {
                modelLoadError = "模型加载失败: \(error.localizedDescription)"
                isModelLoading = false
            }
        }
    }

    func switchModel(_ model: String) {
        guard model != selectedModel else { return }
        selectedModel = model
        isModelLoaded = false
        whisperKit = nil
        Task {
            await loadModel()
        }
    }

    // MARK: - Translation

    func requestTranslation(of text: String) {
        translationContinuation?.yield(text)
    }

    func handleTranslationResult(original: String, translated: String) {
        DispatchQueue.main.async {
            self.translatedText = translated

            if !original.isEmpty {
                self.translationHistory.insert((original, translated, self.detectedLanguage), at: 0)
                if self.translationHistory.count > 50 {
                    self.translationHistory.removeLast()
                }
            }
        }
    }

    // MARK: - Audio File Translation (for testing)

    func transcribeFile(url: URL) {
        guard isModelLoaded else {
            modelLoadError = "请先加载模型"
            return
        }

        Task {
            await transcribeFileAsync(url)
        }
    }

    private func transcribeFileAsync(_ url: URL) async {
        guard let whisperKit = whisperKit else { return }

        do {
            let results = try await whisperKit.transcribe(audioPath: url.path)
            guard let result = results.first else {
                await MainActor.run {
                    modelLoadError = "未识别到语音内容"
                }
                return
            }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "[BLANK_AUDIO]" else {
                await MainActor.run {
                    modelLoadError = "未识别到语音内容"
                }
                return
            }

            let language = result.language

            await MainActor.run {
                self.originalText = text
                self.detectedLanguage = language
            }

            requestTranslation(of: text)

        } catch {
            await MainActor.run {
                modelLoadError = "文件识别失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Microphone Translation

    func startMicTranslation() {
        guard isModelLoaded else {
            modelLoadError = "请先加载模型"
            return
        }

        requestMicrophonePermission { [weak self] granted in
            guard granted else {
                DispatchQueue.main.async {
                    self?.modelLoadError = "需要麦克风权限"
                }
                return
            }
            self?.startAudioEngine()
        }
    }

    private func requestMicrophonePermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                completion(granted)
            }
        default:
            completion(false)
        }
    }

    private func startAudioEngine() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            modelLoadError = "音频会话配置失败: \(error.localizedDescription)"
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: Double(targetSampleRate),
            channels: 1
        ) else {
            modelLoadError = "无法创建音频格式"
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            modelLoadError = "无法创建音频转换器"
            return
        }

        let bufferSize: AVAudioFrameCount = 1024

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let targetFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * Double(self.targetSampleRate) / inputFormat.sampleRate
            )
            guard targetFrameCount > 0 else { return }

            let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCount)!

            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            guard status != .error else { return }

            let channelData = convertedBuffer.floatChannelData?[0]
            let frameLength = Int(convertedBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))

            self.bufferQueue.async {
                self.audioBuffer.append(contentsOf: samples)
                self.processAudioBufferIfNeeded()
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
            DispatchQueue.main.async {
                self.isTranslating = true
            }
        } catch {
            modelLoadError = "音频引擎启动失败: \(error.localizedDescription)"
        }
    }

    private func stopAudioEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Screen Share Translation

    func startScreenShareTranslation() {
        guard isModelLoaded else {
            modelLoadError = "请先加载模型"
            return
        }
        guard screenRecorder.isAvailable else {
            modelLoadError = "屏幕录制不可用"
            return
        }

        screenRecorder.isMicrophoneEnabled = true
        screenRecorder.isCameraEnabled = false

        screenRecorder.startCapture(handler: { [weak self] sampleBuffer, bufferType, error in
            guard let self = self else { return }
            if let error = error {
                print("Screen capture error: \(error)")
                return
            }
            if bufferType == .audioApp || bufferType == .audioMic {
                self.processScreenAudioBuffer(sampleBuffer)
            }
        }, completionHandler: { [weak self] error in
            DispatchQueue.main.async {
                if let error = error {
                    self?.modelLoadError = "启动捕获失败: \(error.localizedDescription)"
                } else {
                    self?.isTranslating = true
                    self?.isScreenSharing = true
                }
            }
        })
    }

    private func processScreenAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = asbd.pointee.mChannelsPerFrame

        var lengthAtOffset = Int()
        var totalLength = Int()
        var outPointer: UnsafeMutablePointer<CChar>?

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferGetDataPointer(
                  blockBuffer,
                  atOffset: 0,
                  lengthAtOffsetOut: &lengthAtOffset,
                  totalLengthOut: &totalLength,
                  dataPointerOut: &outPointer
              ) == kCMBlockBufferNoErr,
              let pointer = outPointer else {
            return
        }

        let floatCount = totalLength / MemoryLayout<Float>.size
        let inputFloats = pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: floatCount))
        }

        bufferQueue.async { [weak self] in
            guard let self = self else { return }

            var processedAudio = channels == 2 ? convertToMono(inputFloats) : inputFloats

            let sourceRate = Int(sampleRate)
            let targetRate = Int(self.targetSampleRate)
            if sourceRate != targetRate {
                processedAudio = resample(processedAudio, from: sourceRate, to: targetRate)
            }

            self.audioBuffer.append(contentsOf: processedAudio)
            self.processAudioBufferIfNeeded()
        }
    }

    private func stopScreenCapture() {
        screenRecorder.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                self?.isScreenSharing = false
                if let error = error {
                    print("Stop capture error: \(error)")
                }
            }
        }
    }

    // MARK: - Stop Translation

    func stopTranslation() {
        if isScreenSharing {
            stopScreenCapture()
        } else {
            stopAudioEngine()
        }
        audioBuffer.removeAll()
        DispatchQueue.main.async {
            self.isTranslating = false
        }
    }

    // MARK: - Audio Processing

    private func processAudioBufferIfNeeded() {
        let requiredSamples = Int(Double(targetSampleRate) * chunkDuration)
        guard audioBuffer.count >= requiredSamples else { return }

        let chunk = Array(audioBuffer.prefix(requiredSamples))
        audioBuffer.removeFirst(min(requiredSamples, audioBuffer.count))

        Task {
            await transcribeAndTranslate(chunk)
        }
    }

    private func transcribeAndTranslate(_ audioSamples: [Float]) async {
        guard let whisperKit = whisperKit else { return }

        do {
            let results = try await whisperKit.transcribe(audioArray: audioSamples)
            guard let result = results.first else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != "[BLANK_AUDIO]" else { return }

            let language = result.language

            await MainActor.run {
                self.originalText = text
                self.detectedLanguage = language
            }

            requestTranslation(of: text)

        } catch {
            print("Transcription error: \(error)")
        }
    }
}
