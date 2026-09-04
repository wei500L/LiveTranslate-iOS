# Architecture

## 总览

```
AVAudioEngine (麦克风, 原生采样率)
   │  installTap → 快速拷贝到有界环形缓冲 (回调内无重活)
   ▼
AudioConverter → 16 kHz mono Float32, 512 样本/块 (≈32 ms)
   ▼
Silero VAD (sherpa-onnx, 与 ASR 后端无关的共享层)
   ▼
SpeechSegmenter → SpeechSegment(sequenceID, 2–20 s, 25 s 绝对上限)
   ▼
ASREngineManager (单一驻留后端, 串行推理)
   ├── GigaAMCoreMLEngine  (Core ML FP16: Log-Mel → Encoder → 宿主端 RNN-T greedy → tokens.json 解码)
   └── GigaAMSherpaEngine  (sherpa-onnx OfflineRecognizer, INT8, nemo_transducer)
   ▼
俄语原文立即持久化 (SwiftData TranscriptEntry, status=.pending)
   ▼
翻译并发池 (2–3 并发, OpenAI 兼容 chat/completions, SSE 可选)
   ▼
OrderedResultBuffer (按 sequenceID 乱序恢复)
   ▼
UI 双语字幕 + 持久化更新 + 导出 (Markdown/TXT×3/JSON/SRT)
```

## 模块

| 目录 | 职责 |
|---|---|
| `App/` | 入口、组合根 (`AppEnvironment`)、Tab 结构 |
| `Audio/` | 采集、重采样、环形缓冲、中断/路由恢复 |
| `VAD/` | Silero VAD 封装、语音分段策略（pre-roll/post-roll/强制切分） |
| `ASR/Shared/` | `ASREngine` 协议、`ASREngineManager`（单后端驻留强制点） |
| `ASR/CoreML/` | Core ML 后端：vDSP Log-Mel、RNN-T 解码循环、token 解码、编译缓存 |
| `ASR/Sherpa/` | sherpa-onnx 后端与模型配置 |
| `Models/` | 模型清单、下载安装、SHA256 完整性、Core ML 编译缓存 |
| `Translation/` | OpenAI 兼容客户端、SSE、课堂提示词、重试策略 |
| `Pipeline/` | `LiveTranslationCoordinator`（管线编排）、顺序恢复缓冲 |
| `Persistence/` | SwiftData 模型与仓储 |
| `Export/` | 导出格式与 Share Sheet |
| `Security/` | Keychain 封装（API Key 唯一存放处） |
| `Diagnostics/` | 基准测试、双后端对比报告、性能指标、Signpost |
| `UI/` | 实时/记录/设置/模型管理/基准 页面与组件 |
| `System/` | 系统集成：Live Activity 控制器（课堂/学习）、App Group 快照、命令消费、统一系统路由、Spotlight 索引、App Intents/App Entities |
| `SharedInboxKit/` | 收件箱共享契约（App Group 存储；编译进主 App + Share Extension） |
| `SharedSystemKit/` | 系统集成共享契约：版本化快照 / 命令队列 / 路由请求 / ActivityKit Attributes（编译进主 App + Widget Extension） |
| `Widgets/` | Widget Extension：Live Activity 渲染（锁屏 + 灵动岛）、三个小组件、控制中心控件（iOS 18+ 防护）、扩展侧 Intent |

## 关键不变量

1. **单后端驻留**：`ASREngineManager` 是唯一能加载/卸载 ASR 引擎的地方；加载新后端前必须完整卸载旧后端。一场实时会话只使用一个后端，会话中禁止切换。
2. **无静默回退**：任何后端失败（加载/推理/完整性）都成为显式错误状态；绝不自动切到另一后端、Apple Speech 或云端 ASR。
3. **ASR 串行、翻译并发**：识别逐段顺序执行（经 `ASREngineManager.transcribe` 串行化）；翻译在 2–3 并发的池上运行，完成乱序，由 `OrderedResultBuffer` 按 `sequenceID` 恢复顺序。
4. **俄语原文不因翻译失败丢失**：识别完成即刻持久化，译文是后续更新。
5. **音频回调零重活**：tap 回调只拷贝进环形缓冲 + 轻量 RMS；VAD/ASR/网络/DB 全部在下游任务中。
6. **模型身份统一**：两个后端在 UI/导出/持久化中都表述为同一个 `GigaAM-v3 e2e_rnnt` 模型的两种推理后端。

## 并发模型

- Swift 6 严格并发。UI 层 `@MainActor`；引擎内部用 `actor` 隔离模型实例（推理天然串行）；音频 tap 在其自身实时线程上只做拷贝。
- 协调器持有结构化任务树，`stop()` 取消并等待全部子任务，然后 flush 最后一段语音。
- `OrderedResultBuffer` 以 `NSLock` 保护（临界区为纯字典/数组操作）。

## 状态机（实时页）

`idle → (downloading|verifying|compilingCoreML) → loadingModel → warmingUp → ready → listening ⇄ speechDetected → transcribing → translating → … → finished`

异常分支：`paused`、`micInterrupted`（看门狗触发后自动走 10 步恢复流程）、`networkOffline`（ASR 继续，翻译挂起待重试）、`backendError`（保持错误直到用户决定）、`diskSpaceLow`。

## 持久化

SwiftData（`Application Support/LiveTranslate.sqlite`，按账号分目录，见 `AccountScope`）：

- `ClassroomSession`：每场课堂一行，记录实际使用的后端、模型版本、计算单元、翻译模型、时长、是否异常终止（App 被杀后下次启动标记）、所属课程（`courseID`，可空）。
- `TranscriptEntry`：每条话轮一行（`sequenceID`、时间偏移、俄语原文、译文、翻译状态、ASR 延迟/RTF、翻译延迟）。
- `Course`：一门可复用的课程（名称、教师、地点、调色板颜色、归档状态、最近使用时间）；删除课程时其课堂保留并变为独立课堂。
- `SessionNote`：用户输入的课堂笔记，可锚定到某条转录段落（`anchorEntryID`）；随课堂删除而删除，段落消失时仅清除锚定。
- 书签与收藏仍是 UserDefaults 中的 ID 记录（`BookmarkStore`）；原始录音（可选开启）写入 `Application Support/Sessions/<session-id>/`，随课堂删除一并清理。

## Core ML 编译缓存

`.mlpackage` 下载源保存在 `Application Support/Models/gigaam-v3-e2e-rnnt/coreml-fp16/Source/`；首次使用编译为 `.mlmodelc` 并原子移动到 `Compiled/v{cacheVersion}/`。缓存版本升级时旧版本整体失效。编译失败不影响仍然有效的旧缓存。
