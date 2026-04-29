# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

```bash
cd ios
xcodegen generate                          # generate .xcodeproj from project.yml
./build_check.sh                           # regenerate project + build for simulator (no signing)
./run_tests.sh                             # run unit tests (auto-detects device, falls back to simulator)
./run_tests.sh device                      # run tests on connected iPhone
```

Single test file via xcodebuild:
```bash
xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:TranslatorAppTests \
  CODE_SIGNING_ALLOWED=NO
```

## Requirements

- iOS 18.0+ deployment target, iOS 17.4+ for Apple Translation API
- Physical device with A14+ recommended (A17 Pro/M3+ for large-v3-turbo model)
- XcodeGen (`brew install xcodegen`) to generate the project from `project.yml`
- WhisperKit v0.9.4 (resolved via Swift Package Manager)

## Architecture

MVVM with three source files in `ios/TranslatorApp/Sources/`:

**Data flow:** `[Mic/ScreenShare Audio] → AVAudioEngine/ReplayKit → 16kHz mono buffer → WhisperKit (ASR) → AsyncStream → Apple Translation API (.translationTask) → UI`

### TranslationViewModel.swift
Core business logic as `ObservableObject`. Key responsibilities:
- **Model loading** — `WhisperKit(model:)` initialization, model switching
- **Audio capture** — two input paths:
  - `startMicTranslation()` → `AVAudioEngine` tap on input node, converts to 16kHz mono via `AVAudioConverter`
  - `startScreenShareTranslation()` → `RPScreenRecorder` capture, processes `CMSampleBuffer` audio
- **Audio chunking** — accumulates samples on `bufferQueue` (serial DispatchQueue), triggers `transcribeAndTranslate()` every 2 seconds of audio (32000 samples at 16kHz)
- **Translation bridge** — `AsyncStream<String>` (`translationStream`) decouples ASR output from the SwiftUI `.translationTask` modifier in ContentView. ViewModel yields text via `requestTranslation()`, view's `.translationTask` consumes and calls `session.translate()`

### ContentView.swift
SwiftUI view with four sub-views: `StatusBarView`, `TranslationAreaView`, `ControlsAreaView`, `SettingsView`. The `.translationTask` modifier on an invisible host view is the integration point — it recreates when `targetLanguage` changes via `.id()`.

### AudioUtils.swift
Free functions `convertToMono()` (stereo→mono averaging) and `resample()` (linear interpolation downsampling). Used by screen share audio path; mic path uses `AVAudioConverter` instead.

## Key Design Details

- **Project is generated** — never edit `TranslatorApp.xcodeproj` directly. Edit `ios/project.yml` and run `xcodegen generate`
- **Tests use Swift Testing** (`import Testing`, `@Suite`/`@Test`/`#expect`), not XCTest
- **UI text is in Chinese** (同声传译, 麦克风翻译, etc.) — keep consistent when adding new strings
- **Translation history** is capped at 50 entries (most recent first)
- **File import** uses security-scoped resource access with 5-second timeout for cleanup
