# Translator - 实时同声传译软件

## 功能特性

- **端侧语音识别 (ASR)**: 使用 WhisperKit 在设备上运行 Whisper 模型，无需网络
- **端侧翻译**: 使用 Apple Translation API 离线翻译，隐私安全
- **多语言支持**: Whisper 支持 100+ 语言识别，Apple Translation 支持主流语言互译
- **双音频源**: 支持麦克风和屏幕共享两种音频输入
- **完全离线**: 模型下载后无需网络连接

## 技术架构

```
[麦克风/屏幕共享音频] → WhisperKit (ASR) → Apple Translation API (翻译) → UI 显示
```

所有处理均在 iPhone 上完成，不依赖远程服务器。

### 核心组件

| 组件 | 技术 | 说明 |
|------|------|------|
| ASR | WhisperKit (CoreML) | OpenAI Whisper 端侧推理，Neural Engine 加速 |
| 翻译 | Apple Translation API | iOS 17.4+ 原生翻译框架，离线可用 |
| 音频捕获 | AVAudioEngine / ReplayKit | 麦克风直接捕获 + 屏幕共享音频 |

### 支持的 Whisper 模型

| 模型 | 大小 | 推荐场景 |
|------|------|----------|
| tiny | ~39 MB | 最快速度，适合实时对话 |
| base | ~74 MB | 速度与准确率平衡（推荐） |
| small | ~244 MB | 更高准确率 |
| medium | ~769 MB | 近云端准确率 |
| large-v3-turbo | ~809 MB | 最高准确率，需 A17 Pro/M3+ |

## 快速开始

### 1. 生成 Xcode 项目

```bash
cd ios
# 安装 xcodegen (如未安装)
brew install xcodegen
# 生成项目
xcodegen generate
```

### 2. 运行应用

1. 用 Xcode 打开 `TranslatorApp.xcodeproj`
2. 连接 iPhone 设备（需 iOS 17.4+）
3. 选择目标设备并运行
4. 首次使用在设置中加载 Whisper 模型
5. 选择翻译目标语言
6. 点击"麦克风翻译"或"屏幕共享翻译"开始

## 使用流程

1. **加载模型**: 设置 → 选择 Whisper 模型 → 点击"加载模型"
2. **选择语言**: 设置 → 选择翻译目标语言
3. **开始翻译**: 点击"麦克风翻译"或"屏幕共享翻译"
4. **实时翻译**: 语音会被实时识别并翻译显示

## 项目结构

```
Translator/
├── ios/
│   ├── project.yml                          # XcodeGen 项目配置
│   ├── TranslatorApp/
│   │   ├── Sources/
│   │   │   ├── ContentView.swift            # 主界面
│   │   │   └── TranslationViewModel.swift   # 业务逻辑（ASR + 翻译）
│   │   └── Resources/
│   │       └── Info.plist
│   └── TranslatorApp.xcodeproj/
└── README.md
```

## 注意事项

1. **系统要求**: iOS 17.4+（Apple Translation API 最低版本）
2. **硬件要求**: A14 Bionic 及以上芯片（推荐 A15+ 获得更佳体验）
3. **模型下载**: 首次使用需下载 Whisper 模型和翻译语言包，之后完全离线
4. **权限要求**: 需要麦克风权限和屏幕录制权限
5. **语言包**: 翻译语言包在首次翻译时自动下载

## 许可证

Apache 2.0
