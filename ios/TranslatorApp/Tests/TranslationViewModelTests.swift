import Testing
import AVFoundation
@testable import TranslatorApp

@Suite("Audio Processing Tests")
struct AudioProcessingTests {

    @Test("Mono conversion from stereo")
    func testConvertToMono() async {
        let stereo: [Float] = [1.0, 3.0, 2.0, 4.0, 5.0, 7.0]
        let mono = convertToMono(stereo)
        #expect(mono.count == 3)
        #expect(mono[0] == 2.0)
        #expect(mono[1] == 3.0)
        #expect(mono[2] == 6.0)
    }

    @Test("Mono conversion with empty input")
    func testConvertToMonoEmpty() async {
        let stereo: [Float] = []
        let mono = convertToMono(stereo)
        #expect(mono.isEmpty)
    }

    @Test("Resample downsample 44100 to 16000")
    func testResampleDownsample() async {
        let audio = [Float](repeating: 1.0, count: 44100)
        let resampled = resample(audio, from: 44100, to: 16000)
        #expect(resampled.count == 16000)
        for sample in resampled {
            #expect(sample == 1.0)
        }
    }

    @Test("Resample with different values preserves signal shape")
    func testResampleSignalShape() async {
        var audio = [Float](repeating: 0.0, count: 4410)
        for i in 0..<4410 {
            audio[i] = Float(sin(Double(i) * 2.0 * .pi / 441.0))
        }
        let resampled = resample(audio, from: 44100, to: 16000)
        #expect(resampled.count == 1600)
        for sample in resampled {
            #expect(sample >= -1.1 && sample <= 1.1)
        }
    }

    @Test("Resample returns original when target >= source rate")
    func testResampleNoOp() async {
        let audio: [Float] = [0.5, 0.6, 0.7]
        let resampled = resample(audio, from: 16000, to: 44100)
        #expect(resampled == audio)
    }
}

@Suite("TranslationViewModel State Tests")
struct TranslationViewModelStateTests {

    @Test("Initial state is correct")
    func testInitialState() async {
        let vm = TranslationViewModel()
        #expect(vm.isModelLoaded == false)
        #expect(vm.isModelLoading == false)
        #expect(vm.isTranslating == false)
        #expect(vm.isScreenSharing == false)
        #expect(vm.translationHistory.isEmpty)
        #expect(vm.targetLanguage == "zh-Hans")
        #expect(vm.isStreamMode == false)
        #expect(vm.currentTranscriptionText.isEmpty)
    }

    @Test("Available models contain expected options")
    func testAvailableModels() async {
        let vm = TranslationViewModel()
        #expect(vm.availableModels.contains("openai_whisper-tiny"))
        #expect(vm.availableModels.contains("openai_whisper-base"))
        #expect(vm.availableModels.contains("openai_whisper-small"))
        #expect(vm.availableModels.contains("openai_whisper-large-v3_turbo"))
    }

    @Test("Available target languages contain expected options")
    func testAvailableTargetLanguages() async {
        let vm = TranslationViewModel()
        let codes = vm.availableTargetLanguages.map { $0.code }
        #expect(codes.contains("zh-Hans"))
        #expect(codes.contains("en"))
        #expect(codes.contains("ja"))
        #expect(codes.contains("ko"))
    }

    @Test("Translation history is capped at 50")
    func testTranslationHistoryCap() async {
        let vm = TranslationViewModel()
        for i in 0..<60 {
            vm.translationHistory.append(TranslationHistoryItem(original: "text \(i)", translated: "翻译 \(i)", language: "en"))
            if vm.translationHistory.count > 50 {
                vm.translationHistory.removeFirst()
            }
        }
        #expect(vm.translationHistory.count == 50)
        #expect(vm.translationHistory.last?.original == "text 59")
    }

    @Test("Selected model is persisted to UserDefaults")
    func testSelectedModelPersistence() async {
        let key = "selectedModel"
        let original = UserDefaults.standard.string(forKey: key)
        defer {
            if let original = original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set("openai_whisper-small", forKey: key)
        let vm = TranslationViewModel()
        #expect(vm.selectedModel == "openai_whisper-small")
    }
}

@Suite("Streaming State Tests")
struct StreamingStateTests {

    @Test("Current transcription text starts empty")
    func testCurrentTranscriptionTextInitial() async {
        let vm = TranslationViewModel()
        #expect(vm.currentTranscriptionText.isEmpty)
    }

    @Test("Stream mode starts as false")
    func testStreamModeInitial() async {
        let vm = TranslationViewModel()
        #expect(vm.isStreamMode == false)
    }
}
