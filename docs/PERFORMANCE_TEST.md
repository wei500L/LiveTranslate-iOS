# Performance Test

## 验收目标

| 指标 | 目标 |
|---|---|
| 两后端 ASR RTF | < 0.5 |
| 3–12 s 片段结束 → 俄语文本显示 P95 | < 2 s |
| 单后端峰值内存 | < 900 MB |
| 60 分钟持续课堂 | 无崩溃 |
| 内存 | 不随字幕条数无界增长 |
| 飞行模式 | ASR 正常 |
| UI 主线程 | 不执行 ASR |

## 测试项（每后端分别）

冷加载、首次推理、热推理、10 段短音频、20 段真实俄语课堂音频、60 分钟持续课堂、前后台切换、锁屏、电话中断恢复、蓝牙切换、飞行模式。记录：下载/安装大小、Core ML 编译耗时、加载/预热时间、推理耗时、RTF、endpoint→字幕延迟、峰值内存、内存趋势、CPU、热状态、电量、崩溃与音频丢块、Core ML 计算单元、INT8 线程数。

Core ML Neural Engine 模式**单独**报告，不与默认 CPU+GPU 混合。

## 当前状态

> ⚠️ **RTF / 内存 / 稳定性验收数值等待真机验证**（无 iPhone 17 Pro Max 可用时，此处如实标注，
> 不伪造数据）。模拟器 RTF 不作为验收依据，仅用于功能验证。

已在构建机上**实际执行**的验证（2026-09-01）：

| 项目 | 状态 | 结果 |
|---|---|---|
| Swift 6 严格并发全量类型检查（App + 3 个测试 target，iPhoneOS SDK） | ✅ 已执行 | 0 error |
| App 整模块对象码编译（arm64-apple-ios17.0，53 个 .o，链接 sherpa-onnx xcframework） | ✅ 已执行 | exit 0 |
| macOS 原生单元测试（SPM harness，含 SSE/CER/词表解码/导出/清单/分段器/VAD/重采样/安装中断） | ✅ 已执行 | **149/149 通过，0 跳过** |
| Core ML Log-Mel 黄金特征对比（真实 Core ML 推理 vs torchaudio 参考特征，3 组俄语 fixture：2.9 s / 19.6 s / 30 s 截断） | ✅ 已执行 | max err ≤ 2e-3、mean err ≤ 1e-5、>1e-4 比例 ≤ 2%、补零列恰为 log(1e-9)，全部通过 |
| iOS 模拟器构建（xcodebuild，iPhone 17 Pro Max / iOS 26.5） | ✅ 已执行 | BUILD SUCCEEDED |
| 模拟器单元测试（LiveTranslateIOSTests，含新增 pinned-export 1024 词表测试） | ✅ 已执行 | **147/147 通过** |
| 模拟器模型集成测试（真实下载的 446 MB Core ML + 216 MB INT8 权重：加载/预热/真实俄语识别/双后端切换与互斥/损坏检测/下载暂停-Range 续传/SHA256 门禁） | ✅ 已执行 | **17/17 通过** |
| 双后端一致性（同一 checkpoint 的两种导出，同一俄语片段） | ✅ 已执行 | Core ML「Здравствуйте. Меня зовут Профессор Иванов.」 / INT8「Здравствуйте. Меня зовут профессор Иванов.」，CER（大小写归一后）= 0.0 |
| Core ML 真机识别 / RTF | ⏸ 待真机 | — |
| INT8 真机识别 / RTF | ⏸ 待真机 | — |
| iPhone 17 Pro Max 60 分钟稳定性 | ⏸ 待真机 | — |

模拟器识别参考值（**非验收数值**，且模拟器 Core ML 以 cpuOnly 运行，见下）：Core ML load=0.22 s、
2.88 s 音频推理 1.57 s（RTF 0.546）；sherpa-onnx INT8 load=0.26 s、2.88 s 音频推理 0.07 s（RTF 0.023）。

### 模拟器 Core ML 计算单元说明

iOS 模拟器无法在 GPU 上执行本模型：E5RT 报 MPSGraph backend validation 失败，且推理输出全为
`<unk>` 垃圾。因此 `CoreMLModelLoader` 在 `targetEnvironment(simulator)` 下固定 `.cpuOnly`
（同一套已校验权重在 CPU 上执行真实数学），真机构建保持文档化策略：accuracy → CPU+GPU，
neuralEngineExperimental → CPU+NE。引擎按会话记录**实际**计算单元，模拟器测试报告如实显示
cpuOnly。模型下载实测：`URLSession.AsyncBytes` 按字节消费在本机环回测得 ~52 MB/s，网络带宽
才是实际瓶颈；安装器断点续传（HTTP Range）与 SHA256 门禁由集成测试覆盖。
