import SwiftUI
import ReplayKit
import AVFoundation
import WhisperKit
import Translation

struct TranslationHistoryItem: Identifiable {
    let id = UUID()
    let original: String
    let translated: String
    let language: String
}

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
    @Published var translationHistory: [TranslationHistoryItem] = []

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
    @Published var currentTranslationText: String = ""
    @Published var isStreamMode = false
    @Published var isTranscribing = false

    // Accumulated confirmed text from previous segments (prevents fragment loss)
    private var confirmedText: String = ""

    // Translation: AsyncStream feeds text to .translationTask in the view
    private(set) var translationStream: AsyncStream<String>
    private var translationContinuation: AsyncStream<String>.Continuation?

    // Draft translation stream
    private(set) var draftTranslationStream: AsyncStream<String>
    private var draftTranslationContinuation: AsyncStream<String>.Continuation?

    private var whisperKit: WhisperKit?
    private let screenRecorder = RPScreenRecorder.shared()
    private let defaults = UserDefaults.standard

    // Streaming state
    private var lastBufferSize: Int = 0
    private var lastConfirmedSegmentEndSeconds: Float = 0
    private var hasActiveSpeech: Bool = false
    private var silenceBufferCount: Int = 0
    private let silenceBuffersForFinalization = 8  // 8 × 100ms = 800ms

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(10))
        self.translationStream = stream
        self.translationContinuation = continuation

        let (draftStream, draftContinuation) = AsyncStream<String>.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(10))
        self.draftTranslationStream = draftStream
        self.draftTranslationContinuation = draftContinuation

        selectedModel = defaults.string(forKey: "selectedModel") ?? "openai_whisper-base"
        var srcLang = defaults.string(forKey: "sourceLanguage") ?? "zh"
        if srcLang == "auto" { srcLang = "zh" }
        sourceLanguage = srcLang
        targetLanguage = defaults.string(forKey: "targetLanguage") ?? "zh-Hans"
        scanLocalModels()
    }

    deinit {
        translationContinuation?.finish()
        draftTranslationContinuation?.finish()
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
                self.translationHistory.append(TranslationHistoryItem(original: original, translated: translated, language: self.detectedLanguage))
                if self.translationHistory.count > 50 {
                    self.translationHistory.removeFirst()
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
            let whisperLanguage: String? = sourceLanguage == "auto" ? nil : sourceLanguage
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: whisperLanguage
            )
            let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
            guard let result = results.first else {
                await MainActor.run {
                    modelLoadError = "未识别到语音内容"
                }
                return
            }
            let text = cleanTranscriptionText(result.text)
            guard !text.isEmpty else {
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
                try await streamingLoop()
            } catch {
                await MainActor.run { modelLoadError = "录音启动失败: \(error.localizedDescription)" }
            }
        }
    }

    // MARK: - Screen Share Translation (via Broadcast Extension for system audio)

    private var broadcastAudioTimer: Timer?
    private let appGroupDefaults = UserDefaults(suiteName: "group.com.dujing.translator")

    func startScreenShareTranslation() {
        guard isModelLoaded else {
            modelLoadError = "请先加载模型"
            return
        }
        isStreamMode = true
        isTranslating = true
        isScreenSharing = true

        // Start Live Activity
        if #available(iOS 16.1, *) {
            liveActivityManager = LiveActivityManager()
            liveActivityManager?.startActivity(targetLanguage: self.targetLanguage)
        }

        // Start polling for broadcast audio data from extension
        startBroadcastAudioPolling()

        // Start the streaming loop
        Task {
            try? await self.streamingLoop()
        }
    }

    private func startBroadcastAudioPolling() {
        // Poll App Group UserDefaults for audio data sent by Broadcast Upload Extension
        broadcastAudioTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.readBroadcastAudio()
        }
    }

    private func readBroadcastAudio() {
        guard let defaults = appGroupDefaults else { return }

        // Read audio data from App Group (already 16kHz mono from SampleHandler)
        for type in ["audioApp", "audioMic"] {
            let key = "broadcast_\(type)_data"
            guard let data = defaults.data(forKey: key) else { continue }

            // Clear so we don't re-process
            defaults.removeObject(forKey: key)

            let floatCount = data.count / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            let audioSamples = data.withUnsafeBytes { ptr in
                Array(UnsafeBufferPointer(start: ptr.baseAddress!.assumingMemoryBound(to: Float.self), count: floatCount))
            }

            // Feed into WhisperKit's audio processor (already 16kHz mono)
            if let processor = whisperKit?.audioProcessor as? AudioProcessor {
                processor.processBuffer(audioSamples)
            }
        }
    }

    private func stopBroadcastAudioPolling() {
        broadcastAudioTimer?.invalidate()
        broadcastAudioTimer = nil
    }

    private func processScreenAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return
        }

        let sampleRate = asbd.pointee.mSampleRate
        let channels = Int(asbd.pointee.mChannelsPerFrame)
        let isPlanar = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var audioData: [Float] = []

        if isPlanar {
            // Planar format: use AudioBufferList for correct channel access
            var blockBuffer: CMBlockBuffer?
            var audioBufferList = AudioBufferList.allocate(maximumBuffers: channels)
            let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: audioBufferList.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channels),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard status == noErr else { return }

            // Take first channel only (for mono output)
            let buffer = audioBufferList.unsafePointer.pointee.mBuffers
            if let data = buffer.mData {
                let frameCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                data.withMemoryRebound(to: Float.self, capacity: frameCount) { ptr in
                    audioData = Array(UnsafeBufferPointer(start: ptr, count: frameCount))
                }
            }
        } else {
            // Interleaved format: use CMBlockBufferGetDataPointer
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
            audioData = pointer.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
                Array(UnsafeBufferPointer(start: ptr, count: floatCount))
            }

            if channels == 2 {
                audioData = convertToMono(audioData)
            }
        }

        guard !audioData.isEmpty else { return }

        let sourceRate = Int(sampleRate)
        let targetRate = 16000
        if sourceRate != targetRate {
            audioData = resample(audioData, from: sourceRate, to: targetRate)
        }

        // Feed into WhisperKit's audio processor
        if let processor = whisperKit?.audioProcessor as? AudioProcessor {
            processor.processBuffer(audioData)
        }
    }

    private func stopScreenCapture() {
        stopBroadcastAudioPolling()
        screenRecorder.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                self?.isScreenSharing = false
                if let error = error {
                    print("Stop capture error: \(error)")
                }
            }
        }
    }

    // MARK: - Streaming Transcription Loop

    /// Strip Whisper special tokens like <|en|>, (music), [BLANK_AUDIO]
    private func cleanTranscriptionText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finalize current speech: move draft to history, send for confirmed translation, reset state
    private func finalizeCurrentSpeech() {
        let text = currentTranscriptionText
        guard !text.isEmpty, text != "等待语音输入..." else { return }

        // Send confirmed text for translation (will be added to history by handleTranslationResult)
        requestTranslation(of: text)

        // Clear draft state
        currentTranscriptionText = ""
        currentTranslationText = ""
        confirmedText = ""
        hasActiveSpeech = false
        silenceBufferCount = 0

        // Reset audio buffer for next utterance
        lastBufferSize = 0
        lastConfirmedSegmentEndSeconds = 0
        if let whisperKit = whisperKit {
            whisperKit.audioProcessor.purgeAudioSamples(keepingLast: WhisperKit.sampleRate * 2)
        }
    }

    private func streamingLoop() async throws {
        guard let whisperKit = whisperKit else { return }
        let compressionCheckWindow = 60

        while isTranslating && isStreamMode {
            let currentBuffer = whisperKit.audioProcessor.audioSamples
            let nextBufferSize = currentBuffer.count - lastBufferSize
            let nextBufferSeconds = Float(nextBufferSize) / Float(WhisperKit.sampleRate)

            // Check for silence to finalize sentence
            let energyValues = Array(whisperKit.audioProcessor.relativeEnergy.suffix(silenceBuffersForFinalization))
            if hasActiveSpeech && energyValues.count >= silenceBuffersForFinalization {
                let allSilent = energyValues.allSatisfy { $0 < 0.15 }
                if allSilent {
                    await MainActor.run { finalizeCurrentSpeech() }
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
            }

            // Force finalization if buffer exceeds 20 seconds (prevents unbounded growth)
            if hasActiveSpeech && Float(currentBuffer.count) / Float(WhisperKit.sampleRate) > 20.0 {
                await MainActor.run { finalizeCurrentSpeech() }
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            guard nextBufferSeconds > 0.5 else {
                if currentTranscriptionText.isEmpty && isTranslating {
                    await MainActor.run { currentTranscriptionText = "等待语音输入..." }
                }
                try await Task.sleep(nanoseconds: 50_000_000)
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
                try await Task.sleep(nanoseconds: 50_000_000)
                continue
            }

            // Voice detected — mark speech as active
            hasActiveSpeech = true
            silenceBufferCount = 0
            lastBufferSize = currentBuffer.count

            let isAutoDetect = sourceLanguage == "auto"
            let whisperLanguage: String? = isAutoDetect ? nil : sourceLanguage
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: whisperLanguage,
                usePrefillPrompt: true,
                usePrefillCache: isAutoDetect,
                withoutTimestamps: false,
                clipTimestamps: [lastConfirmedSegmentEndSeconds],
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0
            )

            // Progress callback: show confirmed + new partial text
            let progressCallback: TranscriptionCallback = { [weak self] progress in
                guard let self else { return nil }
                let partialText = self.cleanTranscriptionText(progress.text)
                if !partialText.isEmpty {
                    let displayText = self.confirmedText.isEmpty ? partialText : self.confirmedText + partialText
                    DispatchQueue.main.async {
                        self.isTranscribing = true
                        self.currentTranscriptionText = displayText
                    }
                }
                let tokens = progress.tokens
                if tokens.count > compressionCheckWindow {
                    let checkTokens = Array(tokens.suffix(compressionCheckWindow))
                    let ratio = TextUtilities.compressionRatio(of: checkTokens)
                    if ratio > (options.compressionRatioThreshold ?? 2.4) {
                        return false
                    }
                }
                if let avgLogprob = progress.avgLogprob,
                   let threshold = options.logProbThreshold,
                   avgLogprob < threshold {
                    return false
                }
                return nil
            }

            do {
                let results = try await whisperKit.transcribe(
                    audioArray: Array(currentBuffer),
                    decodeOptions: options,
                    callback: progressCallback
                )
                guard let result = results.first else {
                    try await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }

                let segments = result.segments
                let newText = cleanTranscriptionText(result.text)

                await MainActor.run {
                    self.isTranscribing = false
                    self.detectedLanguage = result.language

                    guard !segments.isEmpty, !newText.isEmpty else { return }

                    // Accumulate: confirmed text + new transcription text
                    if self.confirmedText.isEmpty {
                        self.confirmedText = newText
                    } else {
                        self.confirmedText += newText
                    }
                    self.currentTranscriptionText = self.confirmedText

                    // Request draft translation of full text
                    self.draftTranslationContinuation?.yield(self.confirmedText)

                    // Update last confirmed segment position
                    if let lastSegment = segments.last {
                        lastConfirmedSegmentEndSeconds = lastSegment.end
                    }
                }

                purgeConfirmedAudio()
            } catch {
                print("Streaming transcription error: \(error)")
                await MainActor.run { self.isTranscribing = false }
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func purgeConfirmedAudio() {
        guard let whisperKit = whisperKit else { return }
        let maxBufferSamples = WhisperKit.sampleRate * 30  // 30 seconds
        let currentCount = whisperKit.audioProcessor.audioSamples.count
        guard currentCount > maxBufferSamples else { return }

        let keepSamples = WhisperKit.sampleRate * 2  // keep 2s overlap before confirmed position
        let purgedSamples = currentCount - keepSamples
        let timeOffset = Float(purgedSamples) / Float(WhisperKit.sampleRate)
        whisperKit.audioProcessor.purgeAudioSamples(keepingLast: keepSamples)
        lastConfirmedSegmentEndSeconds = max(0, lastConfirmedSegmentEndSeconds - timeOffset)
        lastBufferSize = min(lastBufferSize, keepSamples)
    }

    // MARK: - Stop Translation

    func stopTranslation() {
        isStreamMode = false
        isTranscribing = false

        // Finalize any pending speech
        finalizeCurrentSpeech()
        confirmedText = ""
        currentTranscriptionText = ""
        currentTranslationText = ""

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
        hasActiveSpeech = false
        silenceBufferCount = 0

        DispatchQueue.main.async {
            self.isTranslating = false
        }
    }

    // MARK: - Live Activity

    @available(iOS 16.1, *)
    private var liveActivityManager: LiveActivityManager?
}
