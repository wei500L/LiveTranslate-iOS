# Core ML FP16 Backend

`GigaAM-v3 e2e_rnnt · Core ML FP16`——同一 GigaAM-v3 `e2e_rnnt` 检查点的 Apple Core ML FP16 转换（smkrv 转换仓库），完全独立于 sherpa-onnx 的推理路径。

来源：`smkrv/gigaam-v3-e2e-rnnt-coreml` @ `846833ef075fde2a8e50521d093ddb9ed7b7fd45`

## 流水线

```
[Float] 16k mono ≤30 s
  → 补零到 30 s 窗口（length 传真实帧数）
  → vDSP Log-Mel（见下）
  → Encoder（Core ML）→ encoded [1,768,750] + encoded_len
  → 宿主端 RNN-T greedy 解码循环（DecoderStep + JointStep）
  → tokens.json piece 解码 → 带标点俄语文本
```

## Log-Mel 前处理（转换契约，禁止更改）

| 参数 | 值 |
|---|---|
| sample_rate | 16000 |
| n_fft / win_length / hop_length | 320 / 320 / 160 |
| center | false |
| 窗函数 | periodic Hann |
| n_mels | 64 |
| mel_scale | HTK |
| norm | none（mel 滤波器组无 Slaney 归一化） |
| power | 2.0（功率谱） |
| log clamp min | 1e-9（`clamp(1e-9, 1e9).log()`） |
| 均值方差归一化 | 无 |

帧数 = `(n_samples − 320) / 160 + 1`；输入形状 `[1, 64, 2999]`（30 s 窗口），`length` 为 Int32 真实帧数。

实现：Accelerate/vDSP（DFT setup + 预计算 periodic Hann 窗、64×161 HTK mel 矩阵、复用工作缓冲）。窗、矩阵、setup 均只构建一次。

**禁止**：FFT 改 512、80 维 Mel、Slaney、`center=true`、Mel/响度归一化。

## RNN-T greedy 解码（宿主端）

常量：`blank_id=1024`、`vocab=1025`、`pred_hidden=320`（单层 LSTM）、`max_symbols_per_frame=10`。

```
h = c = zeros[1,1,320]; last = 1024
for t in 0..<enc_len:                      # enc_len = Int(encoded_len)，安全范围检查
    enc_t = encoded[:, :, t]
    for _ in 0..<10:
        dec_out, h', c' = DecoderStep(token=[[last]], h_in=h, c_in=c)
        logits = JointStep(enc_t, dec_t=dec_out)
        k = argmax(logits)
        if k == 1024: break                # blank：不提交 h'/c'，进入下一帧
        emit k; h = h'; c = h'; last = k   # 当前帧继续，最多 10 token
```

每个 VAD 片段重置状态。解码循环复用 `MLMultiArray`，外层 `autoreleasepool`，不产生每次迭代的临时分配。

## Token 解码

`tokens.json`（JSON 字符串数组，1025 项）：`pieces[ids].joined().replacingOccurrences(of: "▁", with: " ").trim()`；连续空格折叠；byte fallback token（`<0xNN>`）按 UTF-8 解码。保留大小写、标点、数字——**不做**任何再次小写化或标点处理。未引入 SentencePiece 运行时依赖。

## 计算单元

```swift
enum CoreMLComputePreference { case accuracy, neuralEngineExperimental }
```

- `accuracy`（默认）→ `.cpuAndGPU`：与 PyTorch 参考 token 级一致（转换仓库作者注明 CPU_AND_GPU 为 token-exact）。
- `neuralEngineExperimental` → `.cpuAndNE`：UI 明确标注"实验性"，可能改变边界 token、首次编译更慢；切换后需重载模型；实际分配的计算单元会被记录（`MLModel` 加载后回读 `configuration.computeUnits` 并写入会话元数据）。

## 加载与编译缓存

1. 优先使用 `Compiled/v{cacheVersion}/*.mlmodelc`（版本化缓存目录）。
2. 无缓存 → 校验 `Source/*.mlpackage` 每文件 SHA256（对照 `ModelManifest.json`）→ `MLModel.compileModel` → 临时目录 → 原子 rename 到缓存目录。编译失败**不删除**仍然有效的旧版本。
3. 三个子模型以一致的 `MLModelConfiguration` 加载，只在启动时加载一次，绝不每段重载。
4. 记录：首次编译时间、加载时间、预热时间、热推理时间。`unload()` 释放三个模型与全部缓冲。

## 黄金测试

`scripts/generate_coreml_golden_fixtures.py`（用参考项目只读 venv 的 torch/torchaudio/transformers）生成：

- 16 kHz 俄语测试 WAV（macOS TTS Milena 生成，本地合成、无版权问题）
- 黄金 Log-Mel 特征（torchaudio 参考实现，与转换契约同参数）
- 期望帧数、期望 token 序列与期望文本（ai-sage/GigaAM-v3 PyTorch 参考输出）

Swift 单元测试断言 **Log-Mel 最大绝对误差 ≤ 1e-4**；若 vDSP 实现导致数值偏差，必须展示误差分布并说明原因，不得直接放宽容差。Core ML 真实识别与 PyTorch 参考的一致性在集成测试（`LiveTranslateIOSIntegrationTests`）覆盖，不进入普通 CI。
