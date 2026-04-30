import SwiftUI
import Translation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = TranslationViewModel()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                StatusBarView(viewModel: viewModel)
                TranslationAreaView(viewModel: viewModel)
                ControlsAreaView(viewModel: viewModel)
            }
            .navigationTitle("同声传译")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(viewModel: viewModel)
            }
            .background {
                // Invisible view hosting the translation session.
                // Uses .id to recreate when languages change.
                Color.clear
                    .frame(width: 0, height: 0)
                    .id(viewModel.translationTaskId)
                    .translationTask(
                        TranslationSession.Configuration(
                            source: Locale.Language(identifier: viewModel.appleSourceLanguage),
                            target: Locale.Language(identifier: viewModel.targetLanguage)
                        )
                    ) { session in
                        for await text in viewModel.translationStream {
                            do {
                                let response = try await session.translate(text)
                                viewModel.handleTranslationResult(original: text, translated: response.targetText)
                            } catch {
                                viewModel.handleTranslationResult(original: text, translated: "")
                                print("Translation error: \(error)")
                            }
                        }
                    }
            }
        }
    }
}

struct StatusBarView: View {
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
        HStack {
            if viewModel.isModelLoading {
                ProgressView()
                    .scaleEffect(0.7)
                if viewModel.isModelDownloading {
                    Text("下载中 \(Int(viewModel.modelDownloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("加载模型中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Circle()
                    .fill(viewModel.isTranslating ? Color.green : (viewModel.isModelLoaded ? Color.gray : Color.orange))
                    .frame(width: 10, height: 10)

                if viewModel.isTranscribing {
                    Text("识别中...")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else if viewModel.isTranslating {
                    Text("实时翻译中")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(viewModel.isModelLoaded ? "就绪" : "未加载模型")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !viewModel.detectedLanguage.isEmpty {
                Text("识别语言: \(viewModel.detectedLanguage)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if viewModel.isScreenSharing {
                Text("悬浮字幕")
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple)
                    .cornerRadius(4)
            }
        }
        .padding()
        .background(Color(white: 0.95))
    }
}

struct TranslationAreaView: View {
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                // Live streaming preview (unconfirmed/draft text)
                if !viewModel.currentTranscriptionText.isEmpty {
                    HStack {
                        Text(viewModel.currentTranscriptionText)
                            .font(.body)
                            .foregroundColor(viewModel.isTranscribing ? .blue : .secondary)
                            .italic(viewModel.isTranscribing)
                        Spacer()
                        if viewModel.isTranscribing {
                            ProgressView()
                                .scaleEffect(0.5)
                        }
                    }
                    .padding()
                    .background(Color(white: 0.97))
                    .cornerRadius(12)
                }

                ForEach(0..<viewModel.translationHistory.count, id: \.self) { index in
                    let item = viewModel.translationHistory[index]
                    TranslationCardView(
                        originalText: item.original,
                        translatedText: item.translated,
                        language: item.language
                    )
                }

                if viewModel.translationHistory.isEmpty && viewModel.currentTranscriptionText.isEmpty {
                    VStack {
                        Spacer()
                        Image(systemName: "waveform")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        Text(viewModel.isModelLoaded ? "等待音频输入..." : "请在设置中加载模型")
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding()
        }
    }
}

struct TranslationCardView: View {
    let originalText: String
    let translatedText: String
    let language: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(language)
                    .font(.caption2)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.8))
                    .cornerRadius(4)
                Spacer()
            }

            Text(originalText)
                .font(.body)
                .foregroundColor(.secondary)

            Text(translatedText)
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
        .padding()
        .background(Color(white: 0.95))
        .cornerRadius(12)
    }
}

struct ControlsAreaView: View {
    @ObservedObject var viewModel: TranslationViewModel
    @State private var showFilePicker = false

    var body: some View {
        VStack(spacing: 16) {
            if viewModel.isTranslating {
                Button {
                    viewModel.stopTranslation()
                } label: {
                    Label("停止翻译", systemImage: "stop.circle.fill")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red)
                        .cornerRadius(12)
                }
            } else {
                VStack(spacing: 12) {
                    Button {
                        viewModel.startMicTranslation()
                    } label: {
                        Label("麦克风翻译", systemImage: "mic.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.isModelLoaded ? Color.blue : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!viewModel.isModelLoaded)

                    Button {
                        viewModel.startScreenShareTranslation()
                    } label: {
                        Label("屏幕共享翻译", systemImage: "rectangle.on.rectangle.circle.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.isModelLoaded ? Color.purple : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!viewModel.isModelLoaded)

                    Button {
                        showFilePicker = true
                    } label: {
                        Label("音频文件测试", systemImage: "doc.text")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(viewModel.isModelLoaded ? Color.green : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!viewModel.isModelLoaded)
                    .fileImporter(
                        isPresented: $showFilePicker,
                        allowedContentTypes: [.audio, .wav, .mp3],
                        allowsMultipleSelection: false
                    ) { result in
                        switch result {
                        case .success(let urls):
                            if let url = urls.first {
                                // Access security-scoped resource
                                guard url.startAccessingSecurityScopedResource() else { return }
                                viewModel.transcribeFile(url: url)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                    url.stopAccessingSecurityScopedResource()
                                }
                            }
                        case .failure(let error):
                            viewModel.modelLoadError = "文件选择失败: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color(white: 1.0))
    }
}

struct SettingsView: View {
    @ObservedObject var viewModel: TranslationViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("语音识别模型") {
                    Picker("Whisper 模型", selection: $viewModel.selectedModel) {
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            HStack {
                                Text(displayName(for: model))
                                Spacer()
                                if viewModel.isModelBundled(model) {
                                    Image(systemName: "app.fill")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                } else if viewModel.isModelDownloaded(model) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                } else {
                                    Image(systemName: "arrow.down.circle")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                }
                            }
                            .tag(model)
                        }
                    }
                    .onChange(of: viewModel.selectedModel) { _, newValue in
                        viewModel.switchModel(newValue)
                    }

                    if viewModel.isModelDownloading {
                        VStack(alignment: .leading) {
                            Text("正在下载模型...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            ProgressView(value: viewModel.modelDownloadProgress)
                                .tint(.blue)
                        }
                    }

                    if viewModel.isModelLoading && !viewModel.isModelDownloading {
                        HStack {
                            ProgressView()
                            Text("正在加载模型...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let error = viewModel.modelLoadError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(viewModel.isModelLoaded ? "模型已加载" : (viewModel.isModelDownloaded(viewModel.selectedModel) ? "加载模型" : "下载并加载模型")) {
                        Task {
                            await viewModel.loadModel()
                        }
                    }
                    .disabled(viewModel.isModelLoading || viewModel.isModelLoaded)

                    if viewModel.isModelDownloaded(viewModel.selectedModel) && !viewModel.isModelBundled(viewModel.selectedModel) && !viewModel.isModelLoading {
                        Button("删除本地模型", role: .destructive) {
                            viewModel.deleteLocalModel(viewModel.selectedModel)
                        }
                    }
                }

                Section("输入语种") {
                    Picker("识别语言", selection: $viewModel.sourceLanguage) {
                        ForEach(viewModel.availableSourceLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }

                Section("输出语种") {
                    Picker("目标语言", selection: $viewModel.targetLanguage) {
                        ForEach(viewModel.availableTargetLanguages, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                }

                Section("关于") {
                    LabeledContent("版本", value: "0.0.3")
                    LabeledContent("ASR 引擎", value: "WhisperKit (端侧)")
                    LabeledContent("翻译引擎", value: "Apple Translation (端侧)")
                    LabeledContent("网络要求", value: "无需网络（离线可用）")
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func displayName(for model: String) -> String {
        // Convert "openai_whisper-base" → "base", "openai_whisper-large-v3_turbo" → "large-v3-turbo"
        let name = model
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_distil-", with: "distil-")
            .replacingOccurrences(of: "_turbo", with: "-turbo")
        return name
    }
}

@main
struct TranslatorApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
