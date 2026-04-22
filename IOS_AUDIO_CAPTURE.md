# iOS 系统音频捕获技术说明

## 技术限制

**iOS 系统对第三方应用音频捕获有严格限制：**

1. **ReplayKit**: 仅支持捕获 app 自身音频和麦克风，**无法**捕获其他 app 的系统音频
2. **AVCaptureSession**: 只能捕获麦克风输入，无法捕获系统音频流
3. **Apple 官方 API**: 没有提供捕获其他 app 音频输出的接口

## 替代方案

### 方案 1: Mac 中转 (推荐)

```
[其他App音频] → [Mac BlackHole/ScreenCaptureKit] → [翻译服务器] → [iPhone显示]
```

1. Mac 安装 **BlackHole** 循环音频驱动 (免费开源)
2. 使用 ScreenCaptureKit 捕获系统音频
3. 运行本项目的翻译服务器
4. iPhone 连接并显示翻译结果

**参考项目**: 
- [BlackHole](https://github.com/ExistAudio/BlackHole) - macOS 循环音频驱动
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) - macOS 屏幕/音频捕获

### 方案 2: 音频路由方案

```
[Mac音频输出] → [音频分配器] → [翻译服务器] → [iPhone]
```

使用 macOS 的音频分配器将系统音频路由到翻译程序。

### 方案 3: iOS 17+ 实时歌词 API (有限支持)

iOS 17 引入了实时歌词 (Live Lyrics) API，但仅限 Apple Music 使用，第三方 app 无法访问。

### 方案 4: 辅助功能 + 语音合成

虽然无法获取音频，但可以：
1. 使用 iOS 辅助功能 (Accessibility) 读取屏幕内容
2. 结合语音识别其他来源
3. 展示翻译文本

## 实现状态

| 功能 | 状态 | 说明 |
|------|------|------|
| 麦克风输入 → 翻译 | ✅ 完成 | 使用系统麦克风 |
| 系统音频捕获 (macOS) | 🔶 可行 | 需 Mac + BlackHole |
| 系统音频捕获 (iOS) | ❌ 不可行 | Apple 不支持 |
| iPhone 显示翻译 | ✅ 完成 | WebSocket 连接 |

## 后续计划

1. **Mac 版翻译应用**: 开发 macOS 应用，使用 ScreenCaptureKit 捕获系统音频
2. **iOS 悬浮窗**: 在 iPhone 上以悬浮窗显示翻译结果
3. **多平台支持**: 支持 Android、Web

## 相关资源

- [Apple 官方文档 - Capturing system audio](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [ScreenCaptureKit 文档](https://developer.apple.com/documentation/screencapturekit)
- [BlackHole 音频驱动](https://github.com/ExistAudio/BlackHole)
