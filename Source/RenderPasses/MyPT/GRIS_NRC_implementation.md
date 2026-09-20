# GRIS + NRC QueryOnly 实现说明

## 使用

Release 构建目标仍为 `MyPT`。在 Mogwai 中加载 `scripts/MyPTGRISNRC.py` 后载入场景，或创建如下 pass：

```python
createPass("MyPT", {
    "mode": "ReSTIR",
    "shiftStrategy": "Reconnection",
    "giRISCandidateCount": 1,
    "maxBounces": 8,
    "nrcQueryDepth": 2,
    "nrcUseCache": True,
    "nrcTrainCache": True,
    "nrcQueryTrainingMaxVertices": 9,
    "nrcTrainingIterations": 4,
    "temporalReuse": True,
    "spatialReuse": True,
    "spatialNeighborCount": 3,
    "rrProbability": 0.0,
})
```

不增加渲染模式：`mode` 仍只有 `PT` / `ReSTIR` / `NRC`。在原 `ReSTIR` 上显式设置 `nrcUseCache=True` 即启用 NRC；默认 False，原有 ReSTIR 脚本不必修改。独立 `NRC` 模式的缓存默认 True 保持不变。两种模式分别记住自己的缓存开关；属性更新按目标 mode 应用 nrcUseCache，不依赖字典顺序。序列化保存 `mode="ReSTIR"` 和实际 `nrcUseCache` 值，开启/关闭缓存不需要切换模式。

主表面深度为 0。固定查询深度至少为 2，必须位于重连接点之后且早于硬深度截止；该表面不支持缓存时继续普通追踪。`nrcQueryTrainingMaxVertices` 只限制记录容量，不能用它延长/缩短渲染路径。ReSTIR 启用缓存时强制 MIS；缓存旁路尊重原 GRIS 设置。

首版 Cache 终端只支持 Reconnection。启用缓存时通过属性选择 Hybrid/RandomReplay 会报错并回滚属性，UI 显示 Reconnection。`nrcUseCache=False` 时 ReSTIR 的三种策略保持可用。缓存关闭、零反弹或零 GI 候选时走普通 GRIS；SDK 不可用时显示原因并回退普通 GRIS。

## 帧内数据流

```text
BeginFrame
  -> PrepareQueryTraining（训练/记录开启时）
  -> GRIS.GeneratePaths
  -> GRIS.TracePaths（候选显式前缀、缓存查询、选中候选的局部记录）
  -> BuildTrainingFromQuery（训练/记录开启时，无射线）
  -> QueryAndTrain
  -> FinalizeNrcCandidates（缓存贡献进入树，再完成初始 RIS）
  -> ValidateShift（可选）
  -> TemporalReuse -> SpatialReuse -> Resolve -> StoreHistory
  -> EndFrame
```

每个训练 cell 在追踪前选一个 owner pixel 和 candidate index。候选选择使用独立 hash，不受亮度或 reservoir 选择结果影响。训练槽规模仍为 T，顶点记录为 T×V；所有渲染候选的 pending 状态规模为 P×K。每候选最多一个渲染 query，每条有效 Cache 训练记录另加一个 bootstrap query。

局部训练 beta/radiance 与相机 throughput、重连接 suffix 分开累计。发光命中属于前一段，NEE 使用已计算的可见性/MIS，BSDF 权重采用 GRIS 最终的完整混合估计；记录不会增加训练射线。Cache 末端 direct probe 属于渲染本身，即使冻结训练也会执行，最多追踪 64 段。

Miss/吸收/RR 终止不做 bootstrap；硬深度、溢出、probe 上限、非有限记录排除整条训练路径。缓存预测不直接写入局部记录，而由 SDK bootstrap 处理。复用、诊断和显式 PT reference 都不生产训练记录。

`FinalizeNrcCandidates` 将缓存预测解码为 C，构造 `F=beta_q*C`、`rcIrradiance=suffix_q*C`，恢复树内选择状态，加入 Cache 贡献，再合并候选树。M 仍按候选树计数。有限负预测 clamp 为零并计数；非有限预测进入可见错误计数。最终图像仍为选中 `F*W`。

历史保存已补全的数值样本，不保存可跨帧解引用的 query index。在线训练或仅切换训练开关不清 GRIS 历史；场景/重要参数变化、resize、模式切换、同一 ReSTIR 模式内的缓存开关、显式 cache reset 和热重载仍按生命周期失效。

## 文件职责

- `MyPTGRIS.cpp`：组合调度、候选 pending buffer、SDK 与 Falcor 资源依赖。
- `MyPTGRISNRC.cpp`：ReSTIR 缓存配置，以及与原 NRC 共用的训练资源创建/绑定。
- `GRIS/NrcQuery.slang`：compute 查询适配、SDK 特征、pending 结构。
- `GRIS/PathTracer.slang`：固定深度截断、direct probe 和局部训练记录。
- `GRIS/FinalizeNrcCandidates.cs.slang`：批量推理后的候选补全与初始 RIS。
- `GRIS/Shift.slang`：Cache 使用保存的后缀重连接，不额外施加光源命中 MIS。
- `NRC/NrcQueryTrainingData.slang` / `NrcPrepareQueryTraining.cs.slang` / `NrcQueryRecording.slang`：多候选 owner 契约；普通 NRC 的 candidate 固定为 0，保留原像素选择序列。

## 诊断

- `initialEstimate`：补全缓存后的候选树直接求和均值，未经过 RIS。
- `initialColor`：初始 RIS 的 F×W。
- `ptReference`：ReSTIR 启用缓存时额外执行不使用 NRC 的显式候选追踪，不参与训练。正式计时不连接此输出。
- `nrcExplicit` / `nrcCached`：按最终被选中的终端类型拆分 F×W，RGB 和为 color；不是初始路径各分量的直接和。
- `nrcCandidateDebug`：渲染查询数、含负预测的查询数、非有限预测数、ownerCandidate+1（非 owner 为 0）。
- `nrcQueryTrainingDebug`：终止原因、记录顶点数、接受顶点数、bootstrap 查询数；`nrcTrainingDebug.xyz` 恒为 0，w 为接受顶点数。
- GRIS 射线与 shift 测量继续使用 `rayStats0/1/2`、`shiftDebug`、`spatialDebug` 和 `temporalDebug`。`nrcQueryDebug` 和 `nrcSdkReference` 是原独立 NRC 模式的诊断，ReSTIR 不填充。
- `resourceStats` 增加 `grisNrcActive`、`grisFrameIndex`、`historyValid` 和 `nrcCandidates`；NRC 子项标明 `recordProducer=GRISInitialCandidates`。

脚本诊断 `nrcRecordWhileFrozen=True` 允许在 `nrcTrainCache=False` 时生成训练记录和 bootstrap，但不优化网络，用于同网络的记录开/关对照。正常使用保持 False。

## 验证入口与限制

```text
Mogwai.exe --headless --script scripts/nrc_validation/gris_query_only.py --verbosity 2
Mogwai.exe --headless --script scripts/nrc_validation/query_only.py --verbosity 2
Mogwai.exe --headless --script scripts/nrc_validation/gris_quality.py --verbosity 2
```

SDK OFF 构建运行 `scripts/nrc_validation/gris_sdk_off.py`；测试完成后恢复 `FALCOR_ENABLE_NRC=ON` 并重建。每次测试在 `build/nrc-validation/` 下生成独立报告目录。组合功能测试含原 ReSTIR 三种策略默认不开缓存、独立 NRC 默认值、ReSTIR 缓存配置序列化、同模式缓存开/关、记录不扰动候选、初始 RIS 亮度质量守恒、K=1/2/8、终止过滤、历史增长、重连接 identity/round-trip、冻结/恢复、resize、热重载、空批次、旁路和原三种 shift。普通 GRIS 对照显式设置 `nrcUseCache=False`，NRC 组合测试显式设置 True，不再通过切换渲染模式控制缓存。

质量脚本是 96×64、单种子的 warmed wall-time pilot，使用不截断到缓存的有限深度显式 PT 候选均值作参考，并保存线性图像和 profiler 各阶段数据；不能代表生产分辨率或无限深度真值。QueryOnly 没有额外深层观测，固定浅截断可能发生自举停滞。在线历史使用旧预测，未实现版本校正。候选 pending buffer 的显存按 P×K 增长，超出 4 GiB 单缓冲上限会明确报错；SDK 内部显存不包含在公开 buffer 统计内。

## 原 ReSTIR 开关入口验证（2026-09-18）

- 移除独立组合枚举后，NRC ON 的 Release `MyPT` 构建成功。
- `build/nrc-validation/gris-query-only-20260918-221808-871052/report.json`：23 项全部通过。新增覆盖模式默认值、按模式保存的独立缓存开关、属性顺序、非法跨模式更新回滚、旧枚举拒绝、序列化恢复，以及同一 ReSTIR 模式内开启/关闭缓存后普通 GRIS 输出的逐位一致性；其余训练、时空复用、resize、热重载、旁路和三种原 shift 回归也通过。
- `build/nrc-validation/query-only-20260918-221622-789467/report.json`：原独立 NRC QueryOnly 的 17 项回归全部通过。
- 本轮只调整入口、属性和主机分支，没有修改 transport / training shader；未重跑 SDK OFF、混合材质及质量/性能 pilot，以下旧报告保留其原验证范围，不将其视为本轮重测。

## 首版历史验证结果（2026-09-18，旧入口）

以下已有报告验证的是首版 `ReSTIRNRC` 旧入口，保留作渲染/训练实现和性能基线记录；当前入口已调整为原 `ReSTIR` 的 `nrcUseCache` 开关。新入口的默认值与生命周期回归使用上一节的独立报告，不以这些旧报告代替。

- NRC ON / OFF 的 Release `MyPT` 构建均成功；交付目录已恢复 ON。最后另修正了 UI 从旁路 Hybrid 开启缓存时的当帧策略切换，并重新构建。
- 组合 GPU 回归通过：`build/nrc-validation/gris-query-only-20260918-215728-831150/report.json`。包含 K=1/2/8、记录开关对照、RR/硬深度/溢出、在线更新、时空复用、resize、热重载、显式 cache reset、空批次、旁路、原三种 shift 和可选输出断开。该报告在最后 UI 单点修正之前运行，渲染逻辑相同。
- 最终构建的镜面/玻璃混合场景完整回归通过（19 项）：`build/nrc-validation/gris-query-only-20260918-220547-418613/report.json`。场景使用既有测试生成的 `build/nrc-validation/edges-query_only_mixed-20260918-204412-196741/closed_cornell.pyscene`，通过 `MYPT_GRIS_NRC_SCENE` 指定；包含纯镜面大盒、透射玻璃小盒和封闭前墙。K=1 首个对照帧产生 2537 个渲染 query 和 7050 个接受训练顶点，记录开启/关闭的射线计数逐位相同；时空复用的 M 最大达到 273。此结果不等于已定向覆盖 64 段 probe 上限。
- 原独立 NRC QueryOnly 回归通过：`build/nrc-validation/query-only-20260918-215204-189242/report.json`，覆盖共享训练辅助代码的重构。不是用此报告替代组合验收。
- SDK OFF 回退通过：`build/nrc-validation/gris-sdk-off-20260918-215633-499912/report.json`，固定种子输出与普通 GRIS 逐位相同。
- 质量/耗时 pilot 完成：`build/nrc-validation/gris-quality-20260918-220311-162079/report.json`，原始线性图像保存于同目录 `linear_images.npz`。每组预算约 2 秒；参考是 4096 个显式候选树/像素、maxBounces=8。没有连接诊断 PT reference 参与正式计时。

本次 pilot **未显示画质或性能收益**。普通 GRIS 的同时间 RMSE 为 0.02782；默认 q=2、K=1 在线模式为 0.03168，冻结模式为 0.03471。MyPT pass 平均 GPU 时间分别约 0.182 / 0.570 / 0.321 ms；在线模式的 QueryAndTrain 约 0.216 ms。测试的 q=2/3/4、K=1/2/8 组合中没有超过基线。q=2、K=1 在线结果的 RGB 均值比有限深度参考高约 1.30%，不能将该差异单独解释为训练或重连接错误，也不能据此证明收敛。

历史测试中首次进入缓存组合配置约 30.1 秒，包含 shader 首次编译和 SDK 初始化；后续各次 cache reset 的首帧约 1.57–1.59 秒，均未计入上述稳态预算。在线与冻结顺序测量，后者使用前者训练后的网络；只有一个种子和小分辨率，不作生产性能结论。

当前反射到的 pending stride 为 532 bytes：1920×1080、K=1 时仅该缓冲就约 1.03 GiB，K=4 会触及 4 GiB 限制。这是首版明确的优化事项，尚未压缩为最小必要状态。后续仍需生产分辨率、多种子、多场景的质量/性能评估，以及长镜面链 probe 上限等定向覆盖。
