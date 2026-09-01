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

## Apple 框架

Core ML、AVFoundation、Accelerate/vDSP、CryptoKit、Security(Keychain)、SwiftData、OSLog —— 按 Apple 开发者协议使用。

## SentencePiece

未引入运行时依赖：Token 解码使用内置轻量实现，行为与上游 `tokens.json`/SentencePiece BPE 解码一致（`▁`→空格、byte fallback）。`tokenizer.model` 文件随模型分发但当前 App 不加载它。
