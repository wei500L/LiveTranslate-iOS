# Model Distribution

模型文件**不进入 Git 仓库**（`.gitignore` 排除 `LocalModels/`、`*.onnx`、`*.mlpackage/`、`*.mlmodelc/` 等）。所有分发通过运行时下载 + SHA256 校验。

## 统一模型身份

| 字段 | 值 |
|---|---|
| 模型 | GigaAM-v3 |
| Revision | e2e_rnnt |
| 语言 | ru（仅俄语） |
| 能力 | 标点、大小写、数字规范化（模型原生输出） |
| 推理位置 | iPhone 本地 |
| 上游 | `ai-sage/GigaAM-v3`（MIT） |

两个后端 = 同一检查点的两种转换/精度/运行时，**不是两个模型**。

## 后端 A：Core ML FP16

| 字段 | 值 |
|---|---|
| 仓库 | `smkrv/gigaam-v3-e2e-rnnt-coreml` |
| **固定 revision（commit SHA）** | `846833ef075fde2a8e50521d093ddb9ed7b7fd45` |
| 下载大小 | ≈ 446 MB |
| 运行时 | Apple Core ML（默认 CPU+GPU；NE 为实验选项） |
| 磁盘需求（安装前检查） | ≈ 1.2 GB（源 446 MB + 编译副本 ≈ 446 MB + 临时文件 + 安全余量） |

文件（安装到 `Application Support/Models/gigaam-v3-e2e-rnnt/coreml-fp16/`）：

```
Source/GigaAMv3Encoder.mlpackage/     (weight.bin ≈ 421.5 MB)
Source/GigaAMv3DecoderStep.mlpackage/ (weight.bin ≈ 2.2 MB)
Source/GigaAMv3JointStep.mlpackage/   (weight.bin ≈ 1.3 MB)
Metadata/tokens.json, tokenizer.model, model_info.json,
        convert_info.json, v3_e2e_rnnt.yaml, README.md, example_infer.py
Compiled/v{N}/*.mlmodelc/             (首次使用时编译生成)
```

## 后端 B：sherpa-onnx INT8

| 字段 | 值 |
|---|---|
| 仓库 | `Alexxerm/gigaam-v3-e2e-rnnt-sherpa-onnx` |
| **固定 revision（commit SHA）** | `c0acd38c8aeb2bdc04da221bd661ffcdb9645f7d` |
| 下载大小 | ≈ 216.5 MB |
| 运行时 | sherpa-onnx v1.13.7（iOS 静态 XCFramework，CPU） |
| 磁盘需求 | ≈ 500 MB（含临时空间余量） |

文件（安装到 `.../sherpa-onnx-int8/`）：`encoder.int8.onnx`（214.3 MB）、`decoder.onnx`、`joiner.onnx`、`tokens.txt`、`config.yaml`。

## 共享运行时

- **sherpa-onnx v1.13.7** iOS `ios-shared-onnxruntime-static` XCFramework（动态 framework，ONNX Runtime 静态链接在内，自包含；普通 `ios-static` 资产缺少 Ort 符号无法链接）：SHA256 `72db1b34ff75c6b4f3f40a73d46c4241e1c2b23599638975c66ad6dec10bb298`，`scripts/fetch_third_party.sh` 下载并校验（Core ML 后端也用它运行 Silero VAD）。框架不入 Git。
- **Silero VAD**：`silero_vad.onnx`（≈ 628 KB），安装到 `Models/vad/`。

## 下载与校验流程（App 内）

1. 读取内置 `Resources/ModelManifest.json`（由 `scripts/generate_manifest.py` 用实测 SHA256 生成，schemaVersion 2）。
2. 检查可用磁盘空间 ≥ `minimumFreeDiskBytes`，不足报 `diskSpaceLow`。
3. **逐文件**顺序下载（`.{uuid}.partial` 临时名，避免半成品被当作已安装）。
4. 每文件完成即流式 SHA256 校验；失败删除临时文件并报错（可重试，支持暂停/继续）。
5. Core ML：全部校验通过后重建 `.mlpackage` 目录 → 编译（`MLModel.compileModel`）→ 原子移动到版本化缓存目录。编译失败不删除仍然有效的旧版本。
6. Manifest 记录每后端固定 commit revision，升级 = 换 revision + 新 SHA。

## 为什么固定 commit SHA

`main` 分支是移动目标：上游一次 force-push 就会让 SHA256 校验全错。两个 HF 仓库都固定在本文档开头写明的 commit SHA；上游更新时需要重新走 `prepare_models.sh` → 实测 SHA → 更新 Manifest 的流程，Core ML 同时递增 `coreMLCompiledCacheVersion` 使旧编译缓存失效。

## 开发模式

```bash
./scripts/prepare_models.sh        # 下载到 LocalModels/（git 忽略）并生成 Manifest
```

App 的模型管理页展示：安装状态、下载/本地占用、版本（revision 前 8 位）、SHA256 校验状态、Core ML 编译状态、最近加载时间、最近推理 RTF，以及下载/暂停/继续/删除/重新校验/设为当前后端操作。

---

# 离线 AI 模型（翻译 + 图片理解）

ASR 之外的三台可下载 AI 模型走**同一套**"清单 + 实测 SHA256 + 断点续传 + 暂停/删除/校验"分发体系（`ModelManifest.json` 的 `aiModels` 字典，`LocalAIModelManager`/`AIModelInstaller` 管理），安装到 `Models/<目录名>/`。

| 模型 | manifest key | 文件 | 大小 | 用途 | 上游 | 许可 |
|---|---|---|---|---|---|---|
| Hy-MT2-1.8B Q4_K_M | `hy-mt2-1.8b-q4km` | `Hy-MT2-1.8B-Q4_K_M.gguf` | 1.13 GB | **默认**俄→简中离线翻译 | tencent/Hy-MT2-1.8B-GGUF @ `1cd52087` | Apache-2.0 |
| MiLMMT-46-1B v1.0 Q4_K_M | `milmmt-46-1b-q4km` | `MiLMMT-46-1B-v1.0.Q4_K_M.gguf` | 806 MB | **可选省电**离线翻译 | mradermacher/MiLMMT-46-1B-v1.0-GGUF @ `34df5efb`（原始：xiaomi-research/MiLMMT-46-1B-v1.0） | gemma |
| Gemma 4 E2B it | `gemma-4-e2b-it` | `gemma-4-E2B-it.litertlm` | 2.59 GB | 独立图片理解/翻译 | litert-community/gemma-4-E2B-it-litert-lm @ `b3ca0d2f` | Apache-2.0 |

## 运行时

- **llama.cpp**（固定 commit `465e49b9`，`scripts/fetch_llama.sh` 构建 iOS XCFramework，Metal 加速，含 Hy-MT2 所需 STQ kernel）：两台 GGUF 翻译模型的推理引擎。同一时刻最多**一台**翻译模型常驻（`LlamaContext` actor），课堂会话把所选模型**锁**到会话结束（`LocalAIModelManager.beginSessionPin`），结束后才允许切换/删除。
- **LiteRT-LM**（`scripts/fetch_litertlm.sh` 获取 Google C API XCFramework）：Gemma 图片理解模型的推理引擎。**仅在图片请求进行期间加载，用完即释放**——与常驻的翻译模型互不挤占内存。
- **Apple Translation**（系统框架，iOS 26+ 可编程会话）：本地模型加载/推理失败时按请求兜底，绝不替代默认本地模型；iOS 17–25 上诚实报 notConfigured。

## 磁盘预算（下载前检查）

- Hy-MT2 ≥ 1.4 GB 可用
- MiLMMT ≥ 1.0 GB 可用
- Gemma ≥ 3.1 GB 可用

## 下载源

manifest 中的 URL 指向 Hugging Face 固定 revision（默认下载源）。设置中可将下载源改为**用户自己的同步服务器**：安装器把 URL 重写为 `<CloudSyncServerURL>/models/ai/<manifest-key>/<file>` 并附 Bearer 令牌（Go 服务端 `MODEL_STORAGE_DIR` + `livetranslate-server download-models` 预下载，见 Go 仓库 README「模型托管」）。SHA256 校验与来源无关——两种来源的字节必须逐字节一致。

## 离线语义

- 模型下载完成后，翻译与图片理解**完全离线**工作（无任何网络调用；`isConfiguredNow` 只做文件存在性检查）。
- 翻译失败绝不丢俄语原文（原文在 ASR 完成时即已落库）；失败条目可手动/网络恢复重试。
- 模型文件不进 Git（`.gitignore` 含 `*.gguf`、`*.litertlm`），也不打进初始 App 包——全部按需下载。
