import SwiftUI
import ReplayKit
import AVFoundation
import WhisperKit
import Translation

class TranslationViewModel: ObservableObject {
    @Published var isModelLoaded = false
    @Published var isModelLoading = false
    @Published var modelLoadError: String?
    @Published var modelDownloadProgress: Float = 0
    @Published var isModelDownloading = false
    @Published var localModels: [String] = []

    @Published var isTranslating = false
    @Published var isScreenSharing = false
    @Published var originalText = ""
    @Published var translatedText = ""
    @Published var detectedLanguage = ""
    @Published var translationHistory: [(original: String, translated: String, language: String)] = []

    @Published var selectedModel: String {
        didSet { defaults.set(selectedModel, forKey: "selectedModel") }
    }
    @Published var sourceLanguage: String {
        didSet { defaults.set(sourceLanguage, forKey: "sourceLanguage") }
    }
    @Published var targetLanguage: String {
        didSet { defaults.set(targetLanguage, forKey: "targetLanguage") }
    }
    @Published var availableModels = [
        "openai_whisper-tiny",
        "openai_whisper-base",
        "openai_whisper-small",
        "openai_whisper-medium",
        "openai_whisper-large-v3_turbo",
        "distil-whisper_distil-large-v3_turbo",
    ]
    @Published var availableSourceLanguages: [(code: String, name: String)] = [
        ("auto", "自动检测"),
        ("en", "English"),
        ("zh", "中文"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español"),
        ("ru", "Русский"),
        ("pt", "Português"),
    ]
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

    /// Whisper language code → Apple Translation language code
    private let whisperToAppleLanguage: [String: String] = [
        "en": "en",
        "zh": "zh-Hans",
        "ja": "ja",
        "ko": "ko",
        "fr": "fr",
        "de": "de",
        "es": "es",
        "ru": "ru",
        "pt": "pt-BR",
    ]

    /// Apple Translation source language for .translationTask
    var appleSourceLanguage: String {
        if sourceLanguage == "auto" {
            return whisperToAppleLanguage[detectedLanguage] ?? "en"
        }
        return whisperToAppleLanguage[sourceLanguage] ?? sourceLanguage
    }

    /// Unique ID to recreate .translationTask when languages change
    var translationTaskId: String {
        "\(appleSourceLanguage)-\(targetLanguage)"
    }

    // Streaming state
    @Published var currentTranscriptionText: String = ""
    @Published var isStreamMode = false

    // Translation: AsyncStream feeds text to .translationTask in the view
    private(set) var translationStream: AsyncStream<String>
    private var translationContinuation: AsyncStream<String>.Continuation?

    private var whisperKit: WhisperKit?
    private let screenRecorder = RPScreenRecorder.shared()
    private let defaults = UserDefaults.standard

    // Streaming state
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(10))
        self.translationStream = stream
        self.translationContinuation = continuation

        selectedModel = defaults.string(forKey: "selectedModel") ?? "openai_whisper-base"
        sourceLanguage = defaults.string(forKey: "sourceLanguage") ?? "auto"
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "zh-Hans"
        scanLocalModels()
    }

    deinit {
        translationContinuation?.finish()
    }

    // MARK: - Model Storage

    private static func modelStoragePath() -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml").path
    }

    /// Check if a model is bundled in the app bundle
    func bundledModelPath(for model: String) -> String? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = (resourcePath as NSString).appendingPathComponent("WhisperModels/\(model)")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Models available in the app bundle
    var bundledModels: [String] {
        guard let resourcePath = Bundle.main.resourcePath else { return [] }
        let whisperModelsPath = (resourcePath as NSString).appendingPathComponent("WhisperModels")
        guard FileManager.default.fileExists(atPath: whisperModelsPath) else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: whisperModelsPath)) ?? []
        return contents.filter { $0.hasPrefix("openai_whisper") || $0.hasPrefix("distil-whisper") }
    }

    private func scanLocalModels() {
        var models = Set<String>()
        // Scan Documents directory
        let path = Self.modelStoragePath()
        if FileManager.default.fileExists(atPath: path),
           let contents = try? FileManager.default.contentsOfDirectory(atPath: path) {
            let docModels = contents.filter { $0.hasPrefix("openai_whisper") || $0.hasPrefix("distil-whisper") }
            models.formUnion(docModels)
        }
        // Scan app bundle
        models.formUnion(bundledModels)
        localModels = Array(models).sorted()
    }

    func deleteLocalModel(_ model: String) {
        // Only delete from Documents directory, not bundle
        let path = (Self.modelStoragePath() as NSString).appendingPathComponent(model)
        try? FileManager.default.removeItem(atPath: path)
        scanLocalModels()
        if selectedModel == model && bundledModelPath(for: model) == nil {
            whisperKit = nil
            isModelLoaded = false
        }
    }

    func isModelDownloaded(_ model: String) -> Bool {
        return localModels.contains(model)
    }

    func isModelBundled(_ model: String) -> Bool {
        return bundledModelPath(for: model) != nil
    }

    // MARK: - Model Loading

    func loadModel() async {
        await MainActor.run {
            isModelLoading = true
            modelLoadError = nil
            modelDownloadProgress = 0
        }

        do {
            let modelFolder = Self.modelStoragePath()
            let localModelPath = (modelFolder as NSString).appendingPathComponent(selectedModel)
            let bundlePath = bundledModelPath(for: selectedModel)
            let isLocal = FileManager.default.fileExists(atPath: localModelPath)
            let isBundled = bundlePath != nil

            // Determine the model path: Documents > Bundle
            let modelPath: String
            if isLocal {
                modelPath = localModelPath
            } else if isBundled, let bundle = bundlePath {
                modelPath = bundle
            } else {
                modelPath = "" // will download
            }

            if isLocal || isBundled {
                let config = WhisperKitConfig(
                    model: selectedModel,
                    modelFolder: modelPath,
                    verbose: true,
                    load: false,
                    download: false
                )
                let kit = try await WhisperKit(config)
                self.whisperKit = kit
                kit.modelFolder = URL(fileURLWithPath: modelPath)
                try await kit.loadModels()
            } else {
                // Download model
                let config = WhisperKitConfig(
                    model: selectedModel,
                    verbose: true,
                    load: false,
                    download: false
                )
                let kit = try await WhisperKit(config)
                self.whisperKit = kit

                await MainActor.run { isModelDownloading = true }
                let downloadedFolder = try await WhisperKit.download(
                    variant: selectedModel,
                    downloadBase: URL(fileURLWithPath: modelFolder)
                ) { progress in
                    DispatchQueue.main.async {
                        self.modelDownloadProgress = Float(progress.fractionCompleted)
                    }
                }
                kit.modelFolder = downloadedFolder
                try await kit.loadModels()

                await MainActor.run {
                    isModelDownloading = false
                }
            }

            await MainActor.run {
                scanLocalModels()
                isModelLoaded = true
                isModelLoading = false
                modelDownloadProgress = 1.0
            }
        } catch {
            await MainActor.run {
                modelLoadError = "模型加载失败: \(error.localizedDescription)"
                isModelLoading = false
                isModelDownloading = false
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

            // Update Live Activity during screen share mode
            if self.isScreenSharing {
                if #available(iOS 16.1, *) {
                    self.liveActivityManager?.updateTranslation(
                        original: original,
                        translated: translated,
                        language: self.detectedLanguage
                    )
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

    // MARK: - Microphone Translation (Streaming)

    func startMicTranslation() {
        guard isModelLoaded, let whisperKit = whisperKit else {
            modelLoadError = "请先加载模型"
            return
        }

        isStreamMode = true
        Task {
            guard await AudioProcessor.requestRecordPermission() else {
                await MainActor.run { modelLoadError = "需要麦克风权限" }
                return
            }
            do {
                try whisperKit.audioProcessor.startRecordingLive(callback: nil)
                await MainActor.run { isTranslating = true }
                try await realtimeLoop()
            } catch {
                await MainActor.run { modelLoadError = "录音启动失败: \(error.localizedDescription)" }
            }
        }
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

        isStreamMode = true
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
                guard let self = self else { return }
                if let error = error {
                    self.modelLoadError = "启动捕获失败: \(error.localizedDescription)"
                } else {
                    self.isTranslating = true
                    self.isScreenSharing = true

                    // Start Live Activity
                    if #available(iOS 16.1, *) {
                        self.liveActivityManager = LiveActivityManager()
                        self.liveActivityManager?.startActivity(targetLanguage: self.targetLanguage)
                    }

                    // Auto-minimize app after 1 second
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        UIApplication.shared.perform(#selector(UIResponder.resignFirstResponder))
                    }

                    // Start the realtime loop after capture is active
                    Task {
                        try? await self.realtimeLoop()
                    }
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

        var processedAudio = channels == 2 ? convertToMono(inputFloats) : inputFloats

        let sourceRate = Int(sampleRate)
        let targetRate = 16000
        if sourceRate != targetRate {
            processedAudio = resample(processedAudio, from: sourceRate, to: targetRate)
        }

        // Feed into WhisperKit's audio processor
        if let processor = whisperKit?.audioProcessor as? AudioProcessor {
            processor.processBuffer(processedAudio)
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

    // MARK: - Streaming Realtime Loop

    private func realtimeLoop() async throws {
        guard let whisperKit = whisperKit else { return }
        let requiredSegmentsForConfirmation = 2

        while isTranslating && isStreamMode {
            let currentBuffer = whisperKit.audioProcessor.audioSamples
            let nextBufferSize = currentBuffer.count - lastBufferSize
            let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

            guard nextBufferSeconds > 1.0 else {
                if currentTranscriptionText.isEmpty && isTranslating {
                    await MainActor.run { currentTranscriptionText = "等待语音输入..." }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            // VAD check
            let voiceDetected = AudioProcessor.isVoiceDetected(
                in: whisperKit.audioProcessor.relativeEnergy,
                nextBufferInSeconds: nextBufferSeconds,
                silenceThreshold: 0.3
            )
            guard voiceDetected else {
                if currentTranscriptionText.isEmpty && isTranslating {
                    await MainActor.run { currentTranscriptionText = "等待语音输入..." }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
                continue
            }

            lastBufferSize = currentBuffer.count

            let whisperLanguage: String? = sourceLanguage == "auto" ? nil : sourceLanguage
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: whisperLanguage,
                usePrefillPrompt: true,
                usePrefillCache: true,
                withoutTimestamps: false,
                clipTimestamps: [lastConfirmedSegmentEndSeconds]
            )

            do {
                let results = try await whisperKit.transcribe(
                    audioArray: Array(currentBuffer),
                    decodeOptions: options
                )
                guard let result = results.first else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                let segments = result.segments
                guard !segments.isEmpty else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text != "[BLANK_AUDIO]" else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }

                await MainActor.run {
                    self.currentTranscriptionText = ""
                    self.detectedLanguage = result.language

                    if segments.count > requiredSegmentsForConfirmation {
                        let numToConfirm = segments.count - requiredSegmentsForConfirmation
                        let confirmedArray = Array(segments.prefix(numToConfirm))
                        let remaining = Array(segments.suffix(requiredSegmentsForConfirmation))

                        if let lastConfirmed = confirmedArray.last,
                           lastConfirmed.end > lastConfirmedSegmentEndSeconds {
                            lastConfirmedSegmentEndSeconds = lastConfirmed.end
                            let confirmedText = confirmedArray.map { $0.text }.joined()
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !confirmedText.isEmpty {
                                requestTranslation(of: confirmedText)
                            }
                        }
                        self.currentTranscriptionText = remaining.map { $0.text }.joined()
                    } else {
                        self.currentTranscriptionText = text
                    }
                }
            } catch {
                print("Streaming transcription error: \(error)")
            }

            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Stop Translation

    func stopTranslation() {
        isStreamMode = false

        // Finalize any pending transcription text
        let pendingText = currentTranscriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingText.isEmpty && pendingText != "等待语音输入..." {
            requestTranslation(of: pendingText)
        }
        currentTranscriptionText = ""

        if isScreenSharing {
            stopScreenCapture()
        } else {
            whisperKit?.audioProcessor.stopRecording()
        }

        // End Live Activity
        if #available(iOS 16.1, *) {
            liveActivityManager?.endActivity()
            liveActivityManager = nil
        }

        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0

        DispatchQueue.main.async {
            self.isTranslating = false
        }
    }

    // MARK: - Live Activity

    @available(iOS 16.1, *)
    private var liveActivityManager: LiveActivityManager?
}
