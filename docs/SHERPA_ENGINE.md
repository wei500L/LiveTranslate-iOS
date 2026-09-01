# sherpa-onnx INT8 Backend

`GigaAM-v3 e2e_rnnt · sherpa-onnx INT8`——同一 GigaAM-v3 `e2e_rnnt` 检查点的 ONNX INT8 量化版，通过 sherpa-onnx 的 Offline Transducer Recognizer 在 CPU 上推理。

来源：`Alexxerm/gigaam-v3-e2e-rnnt-sherpa-onnx` @ `c0acd38c8aeb2bdc04da221bd661ffcdb9645f7d`

## 固定配置

```
encoder         = encoder.int8.onnx     (214.3 MB, INT8)
decoder         = decoder.onnx          (1.1 MB)
joiner          = joiner.onnx           (0.7 MB)
tokens          = tokens.txt
num_threads     = 2（默认；设置页提供 2/4 选项）
sample_rate     = 16000
feature_dim     = 64        ← 必须显式设置
decoding_method = greedy_search
model_type      = nemo_transducer   ← 必须显式设置
provider        = cpu
```

`feature_dim=64` 与 `model_type=nemo_transducer` 通过 C API 显式传入——不依赖 sherpa-onnx 的猜测逻辑。

## 运行时

- sherpa-onnx v1.13.7 iOS **静态** XCFramework（`SherpaOnnxC` 模块，含 ONNX Runtime；SHA256 见 `scripts/fetch_third_party.sh`）。
- recognizer **只创建一个**，存活于整个引擎生命周期；每次推理创建/销毁 OfflineStream（`AcceptWaveformOffline` → `DecodeOfflineStream` → 取 `result.text`）。
- 推理经 actor 隔离串行执行。
- 输出即 GigaAM `e2e_rnnt` 原生带标点文本，**无任何后处理**（除 trim）。
- 加载后执行短静音预热；记录加载时间、首次推理、热推理时间、RTF。
- `unload()` 销毁 recognizer 与缓存。
- 失败绝不静默切换到 Core ML。
- 同一 sherpa-onnx 运行时同时为两个后端提供 **Silero VAD**（`silero_vad.onnx`，与 ASR 后端选择无关的共享层）。

## INT8 量化说明

INT8 量化允许与 FP16/PyTorch 存在输出差异（边界 token 漂移、偶发词形差异）。双后端对比页（`docs/BACKEND_COMPARISON.md`）量化这些差异；有人工参考文本时报告各自 CER/WER，没有参考文本时只描述差异、不宣称谁更准确。
