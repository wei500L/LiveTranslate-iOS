# Third-Party Notices

本项目使用的第三方模型与库。模型文件不随仓库分发，下载时遵循各自上游许可。

## GigaAM-v3（ai-sage/GigaAM-v3）

- 来源：https://huggingface.co/ai-sage/GigaAM-v3
- 用途：俄语语音识别基础模型（本项目仅作模型身份与参考实现依据；App 分发其衍生转换格式，见下）
- 许可：MIT（见上游模型卡）。论文：arXiv:2506.01192

## Core ML FP16 转换（smkrv/gigaam-v3-e2e-rnnt-coreml）

- 来源：https://huggingface.co/smkrv/gigaam-v3-e2e-rnnt-coreml
- 固定 revision：`846833ef075fde2a8e50521d093ddb9ed7b7fd45`
- 内容：GigaAM v3 e2e_rnnt 的 Core ML FP16 转换（Encoder / DecoderStep / JointStep `.mlpackage` + tokens.json + tokenizer.model 等）
- 许可：MIT（模型卡声明）

## sherpa-onnx INT8 转换（Alexxerm/gigaam-v3-e2e-rnnt-sherpa-onnx）

- 来源：https://huggingface.co/Alexxerm/gigaam-v3-e2e-rnnt-sherpa-onnx
- 固定 revision：`c0acd38c8aeb2bdc04da221bd661ffcdb9645f7d`
- 内容：同一检查点的 ONNX INT8 量化（encoder.int8.onnx / decoder.onnx / joiner.onnx / tokens.txt）
- 许可：MIT（模型卡声明）

## sherpa-onnx 运行时

- 来源：https://github.com/k2-fsa/sherpa-onnx
- 版本：v1.13.7（iOS 静态 XCFramework，含 ONNX Runtime）
- 许可：Apache-2.0（sherpa-onnx 与其捆绑的 ONNX Runtime）

## Silero VAD

- 来源：https://github.com/snakers4/silero-vad（经 sherpa-onnx 发布渠道获取 `silero_vad.onnx`）
- 许可：MIT

## Hy-MT2-1.8B GGUF（tencent/Hy-MT2-1.8B-GGUF）

- 来源：https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF
- 固定 revision：`1cd5208700acedef4ef93019b6cfc148b8522d45`
- 内容：`Hy-MT2-1.8B-Q4_K_M.gguf`（1.13 GB）——默认的俄语→简体中文离线翻译模型（hunyuan-dense 2B）
- 许可：Apache-2.0（模型卡声明）
- 注意：模型卡说明其 GGUF 依赖 llama.cpp 的 STQ kernel（PR #22836 起合入主线）；本项目使用的固定 llama.cpp commit 已包含该 kernel。

## MiLMMT-46-1B-v1.0 GGUF（xiaomi-research/milmmt-46-1b-v1.0 via mradermacher）

- 原始模型：https://huggingface.co/xiaomi-research/MiLMMT-46-1B-v1.0
- GGUF（本项目实际下载）：https://huggingface.co/mradermacher/MiLMMT-46-1B-v1.0-GGUF
- 固定 revision（GGUF 仓库）：`34df5efbe6592773ec168cc7b307728c08623472`
- 内容：`MiLMMT-46-1B-v1.0.Q4_K_M.gguf`（806 MB）——可选的省电离线翻译模型（gemma-3-1b 血统）
- 许可：**gemma**（Google Gemma 条款，随原始模型传播；mradermacher 的量化仓库同样标注 gemma 许可）。Gemma 条款对商用附加了命名与用途披露义务，发布 App 前需人工复核：https://ai.google.dev/gemma/terms

## Gemma 4 E2B it LiteRT-LM（litert-community/gemma-4-E2B-it-litert-lm）

- 来源：https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm
- 固定 revision：`b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1`
- 内容：`gemma-4-E2B-it.litertlm`（2.59 GB）——独立的图片理解与翻译模型（LiteRT-LM 格式）
- 许可：Apache-2.0（模型卡声明；注意与上条 gemma 许可的 MiLMMT 不同，此 litert-community 发行版为 Apache-2.0）

## llama.cpp 运行时

- 来源：https://github.com/ggml-org/llama.cpp
- 固定 commit：`465e49b9cea78a68b9c244ffb48d0ee24a82873d`（含 Hy-MT2 所需的 STQ kernel）
- 获取方式：`scripts/fetch_llama.sh` 从该 commit 构建 iOS XCFramework（设备 + 模拟器，Metal 加速）
- 许可：MIT（llama.cpp 与 ggml）；Metal shader 部分按上游声明

## LiteRT-LM 运行时

- 来源：https://github.com/google-ai-edge/LiteRT-LM（C API 预编译 XCFramework 经 https://github.com/mylovelycodes/LiteRTLM-Swift 打包，固定 commit `0e63b19c21ba562d6824fbfc409fba0916acea18`）
- 获取方式：`scripts/fetch_litertlm.sh`
- 许可：Apache-2.0（Google LiteRT-LM / ODML，engine.h 头部声明）

## Apple 框架

Core ML、AVFoundation、Accelerate/vDSP、CryptoKit、Security(Keychain)、SwiftData、OSLog、Translation（系统翻译兜底，iOS 26+）—— 按 Apple 开发者协议使用。

## SentencePiece

未引入运行时依赖：Token 解码使用内置轻量实现，行为与上游 `tokens.json`/SentencePiece BPE 解码一致（`▁`→空格、byte fallback）。`tokenizer.model` 文件随模型分发但当前 App 不加载它。
