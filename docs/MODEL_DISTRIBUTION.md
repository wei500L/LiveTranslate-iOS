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
