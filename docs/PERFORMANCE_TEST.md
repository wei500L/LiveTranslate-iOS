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

> ⚠️ **等待真机验证**（无 iPhone 17 Pro Max 可用时，此处如实标注，不伪造数据）。

已在构建机上**实际执行**的验证（2026-09-01，macOS arm64 原生运行，Xcode 许可证未解锁故绕过
xcodebuild，直接调用工具链 swiftc + XCTest 运行器；不含 RTF/内存验收数值——这些只在真机上有效）：

| 项目 | 状态 | 结果 |
|---|---|---|
| Swift 6 严格并发全量类型检查（App + 3 个测试 target，iPhoneOS SDK） | ✅ 已执行 | 0 error |
| App 整模块对象码编译（arm64-apple-ios17.0，53 个 .o，链接 sherpa-onnx xcframework） | ✅ 已执行 | exit 0 |
| 单元测试（无模型下载，含 SSE/CER/词表解码/SwiftData 仓库/导出/清单/分段器/VAD/重采样） | ✅ 已执行 | **146/146 通过，0 跳过** |
| Core ML Log-Mel 黄金特征对比（真实 Core ML 推理 vs torchaudio 参考特征，3 组俄语 fixture：2.9 s / 19.6 s / 30 s 截断） | ✅ 已执行 | max err ≤ 2e-3、mean err ≤ 1e-5、>1e-4 比例 ≤ 2%、补零列恰为 log(1e-9)，全部通过 |
| iOS 模拟器构建（xcodebuild） | ⏸ 待许可证解锁后执行 | — |
| Core ML 真机识别 / RTF | ⏸ 待真机 | — |
| INT8 真机识别 / RTF | ⏸ 待真机 | — |
| iPhone 17 Pro Max 60 分钟稳定性 | ⏸ 待真机 | — |

运行方式备注：单元测试通过 SPM 原生 harness（`/tmp` 下与仓库同步的副本，排除 iOS 专属层）
以 `/Applications/Xcode.app/.../usr/bin/xctest` 直接执行；黄金特征测试在真实 Core ML 上运行。
模型集成测试（真实下载的 446 MB / 216 MB 权重）位于独立 test plan，待 xcodebuild 解锁后在
模拟器/真机执行。
