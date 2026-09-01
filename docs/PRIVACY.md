# Privacy

LiveTranslate iOS 的数据处理边界。

## 麦克风音频

- 麦克风输入在 **iPhone 本地**完成全部语音识别（GigaAM-v3，Core ML 或 sherpa-onnx/ONNX Runtime，均在本机运行）。
- 音频样本不会发送到任何服务器。
- 默认**不保存**原始音频。设置中开启"保存原始录音"后，录音仅写入本机 App 沙盒，可随时在设置中删除。
- App 不会在后台自动开启麦克风；每次录音会话都由你点击"开始"显式发起。会话期间进入后台/锁屏，录音会继续（已声明音频后台模式），停止按钮随时可用。

## 文本

- 只有**俄语识别文本**（不是音频）会发送给你自己配置的翻译 API 端点。
- 课堂记录（俄语原文与中文译文）保存在本机 SwiftData 数据库，不上传。
- 你可以删除任何单场记录或全部记录。

## 密钥

- 翻译 API Key 仅存储在 iOS Keychain（`kSecAttrAccessibleAfterFirstUnlock`），不写入 UserDefaults、不导出、不进入日志。
- 导出的任何文件（Markdown/TXT/JSON/SRT/对比报告）都不包含 API Key、Authorization 头或内部路径。

## 日志

- 日志（OSLog）对端点、模型名做脱敏；绝不记录 API Key 与请求头。

## 系统能力边界

- 普通 iOS App 无法捕获其他 App 的内部音频；本 App 只使用麦克风输入。
- 无任何云端 ASR 回退：断网时识别继续，翻译暂停并在网络恢复后重试。

## 权限

- 麦克风权限（NSMicrophoneUsageDescription）：用于课堂录音识别，拒绝后无法使用实时功能。
- 无其他隐私敏感权限。
