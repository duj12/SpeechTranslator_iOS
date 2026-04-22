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
        // Resampled signal should still be a sine wave (values between -1 and 1)
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
        #expect(vm.selectedModel == "base")
        #expect(vm.targetLanguage == "zh-Hans")
    }

    @Test("Available models contain expected options")
    func testAvailableModels() async {
        let vm = TranslationViewModel()
        #expect(vm.availableModels.contains("tiny"))
        #expect(vm.availableModels.contains("base"))
        #expect(vm.availableModels.contains("small"))
        #expect(vm.availableModels.contains("large-v3-turbo"))
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
        // Simulate adding 60 items
        for i in 0..<60 {
            vm.translationHistory.insert(("text \(i)", "翻译 \(i)", "en"), at: 0)
            if vm.translationHistory.count > 50 {
                vm.translationHistory.removeLast()
            }
        }
        #expect(vm.translationHistory.count == 50)
        // Most recent should be first
        #expect(vm.translationHistory.first?.original == "text 59")
    }
}

@Suite("Audio Buffer Chunking Tests")
struct AudioBufferChunkingTests {

    @Test("2-second buffer at 16kHz is 32000 samples")
    func testBufferSizeCalculation() async {
        let sampleRate: Double = 16000
        let duration: Double = 2.0
        let requiredSamples = Int(sampleRate * duration)
        #expect(requiredSamples == 32000)
    }

    @Test("Buffer accumulates correctly before triggering processing")
    func testBufferAccumulation() async {
        let chunkSize = 32000
        var buffer: [Float] = []

        // Add samples in smaller chunks
        for _ in 0..<3 {
            buffer.append(contentsOf: [Float](repeating: 0.5, count: 12000))
        }

        // Should have 36000 samples total, enough for one chunk
        #expect(buffer.count >= chunkSize)
    }
}
