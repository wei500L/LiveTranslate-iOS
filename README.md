# LiveTranslate iOS

iPhone 原生俄语课堂实时翻译 App，面向莫斯科大学课堂、说明会和会议。持续收听俄语讲课，**完全本地**识别（GigaAM-v3），实时翻译成简体中文，双语字幕展示并保存完整课堂记录。

> 桌面端参考项目位于 `/Users/oo/project/LiveTranslate`（只读参考，本项目完全独立，不依赖其任何文件或 Python 运行时）。

## 核心特性

- **统一模型、双本地推理后端**：同一 GigaAM-v3 `e2e_rnnt` 检查点的两种部署形态
  - `GigaAM-v3 e2e_rnnt · Core ML FP16`（精度优先，Apple 原生，默认 CPU+GPU，约 446MB）
  - `GigaAM-v3 e2e_rnnt · sherpa-onnx INT8`（体积优先，CPU 推理，约 216MB）
  - 两个后端是**同一个 ASR 模型**的两种运行时，不是两个模型
- 断网时俄语识别照常可用，网络恢复后补充翻译
- 带标点、大小写、数字规范化的俄语原文（模型原生输出）
- OpenAI 兼容翻译 API（OpenAI / DeepSeek / Qwen / Grok / Ollama / vLLM / LM Studio / 自建 HY-MT 服务）
- 课堂记录：搜索、改标题、重试翻译、删除、导出（Markdown / TXT×3 / JSON / SRT）
- 双后端对比测试（CER/WER、RTF、内存），可导出报告

## 隐私

- 麦克风音频由 GigaAM 在 iPhone 本地识别，不上传
- 默认不保存原始音频，只保存文字（可在设置中主动开启录音保存）
- 只有俄语识别文本发送给你配置的翻译 API
- API Key 仅存 Keychain
- 详见 [docs/PRIVACY.md](docs/PRIVACY.md)

## 重要限制（请先读）

- **系统音频**：普通 iOS App **不能**捕获其他 App 的内部音频。本 App 的输入是 iPhone 麦克风（建议设备靠近讲课者或使用领夹麦）。
- **模型体积**：首次使用需下载模型（Core ML 约 446MB / INT8 约 216MB），通过 App 内模型管理页下载，Wi-Fi 推荐。

## 构建

要求：macOS + Xcode 16+（含 iOS 17 SDK）、[xcodegen](https://github.com/yonaskolb/XcodeGen)。

```bash
# 1. 获取 sherpa-onnx 静态 XCFramework（不入库，脚本自动下载并校验）
./scripts/fetch_third_party.sh

# 2. 生成 Xcode 工程
xcodegen generate

# 3. 构建
xcodebuild -project LiveTranslateIOS.xcodeproj -scheme LiveTranslateIOS \
  -destination 'generic/platform=iOS Simulator' build
```

真机运行：用 Xcode 打开工程，选择你的开发团队签名，接上 iPhone（iOS 17+）直接 Run。模型在 App 内"模型管理"页下载。

## 模型下载

模型文件**不随 Git 仓库分发**。两种方式：

- **App 内**（推荐用户路径）：设置 → 模型管理 → 选择后端 → 下载（逐文件下载 + SHA256 校验 + Core ML 编译缓存）
- **开发模式**：`./scripts/prepare_models.sh` 下载到 `LocalModels/`（git 忽略）并生成含实测 SHA256 的 Manifest

两个后端都固定在 Hugging Face 的具体 commit revision（绝不追随 `main`），详见 [docs/MODEL_DISTRIBUTION.md](docs/MODEL_DISTRIBUTION.md)。

## 翻译 API 设置

设置 → 翻译 API：填入 API Base（如 `https://api.deepseek.com`，自动补 `/v1`）、API Key（仅存 Keychain）、模型名。支持流式 SSE、思考模式禁用（DeepSeek/Qwen/vLLM/OpenAI 四种风格 + 自动检测）、上下文条数（0–10，默认 4）、自定义系统提示词。局域网 HTTP 端点（Ollama / LM Studio）可用（ATS 仅放行本地网络）。

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 模块架构与数据流 |
| [docs/COREML_ENGINE.md](docs/COREML_ENGINE.md) | Core ML 后端：Log-Mel、RNN-T 解码、黄金测试 |
| [docs/SHERPA_ENGINE.md](docs/SHERPA_ENGINE.md) | sherpa-onnx 后端配置 |
| [docs/MODEL_DISTRIBUTION.md](docs/MODEL_DISTRIBUTION.md) | 模型分发、固定 revision、SHA256、编译缓存 |
| [docs/BACKEND_COMPARISON.md](docs/BACKEND_COMPARISON.md) | 双后端对比方法与结果 |
| [docs/PERFORMANCE_TEST.md](docs/PERFORMANCE_TEST.md) | 性能验收流程与结果 |
| [docs/PRIVACY.md](docs/PRIVACY.md) | 隐私细节 |
| [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) | 第三方许可 |

## 目录结构

```
LiveTranslateIOS.xcodeproj      # xcodegen 生成
LiveTranslateIOS/               # App 源码（App/Audio/VAD/ASR/Translation/...）
LiveTranslateIOSTests/          # 单元测试（不下载模型）
LiveTranslateIOSIntegrationTests/  # 模型集成测试（需已安装模型）
Resources/                      # ModelManifest.json、本地化、资产
scripts/                        # 模型准备/Manifest 生成/黄金数据脚本
docs/                           # 文档
ThirdParty/                     # sherpa-onnx.xcframework（git 忽略，脚本下载）
```

## 已知问题

- Core ML Neural Engine 模式为实验性：可能改变边界 token，首次编译更慢，默认不启用
- 未捕获的边界情况见 GitHub Issues

## 性能测试状态

见 [docs/PERFORMANCE_TEST.md](docs/PERFORMANCE_TEST.md)。真机（iPhone 17 Pro Max）60 分钟持续课堂测试状态在该文档中如实标注（未完成的测试不会被报告为通过）。

## 许可

本项目代码：见仓库 LICENSE。模型权重各自遵循其上游许可（MIT，详见 THIRD_PARTY_NOTICES.md）。
