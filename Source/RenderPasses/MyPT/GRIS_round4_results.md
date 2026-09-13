# 第四轮：Random Replay 与 Hybrid Shift

日期：2026-09-10。M5 已在本文声明的支持范围内完成并通过恢复验收。最终审计状态为 `passed_with_retained_interruption`：四组核心统计、新的全部 27 项边界、同构建图像、Layered、原入口和人工图像检查均通过；原中断报告保持原状态。

本轮在现有 MyPT 的 ReSTIR 模式内实现 RandomReplay 与 Hybrid，Mode 保持 PT / ReSTIR 两项。类默认策略仍是 Reconnection，原 `MyPT.py` 显式选择 Hybrid；没有增加 PT 产品入口。本轮的本地一致性验收与 M6 的原版 GRIS 画质、性能对齐分别记录。

## 参考实现与实际流程

```text
GeneratePaths → TracePaths
→ [TemporalPathRetrace → TemporalReuse]
→ [SpatialPathRetrace → SpatialReuse] × rounds
→ Resolve → StoreHistory
```

Retrace 只在 Hybrid 且相应复用开启时执行；其他策略在 Reuse 内完成映射。每轮冻结输入，Retrace 与 Reuse 使用相同邻居序号及双向缓存，无效槽也明确写入。StoreHistory 保存最终空间 reservoir 和同帧 primary。只有连接 `shiftDebug` 的诊断配置额外执行 ValidateShift。

- 路径生成、指定贡献 Replay 和 Hybrid 前缀追踪共用 [PathTracer](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/PathTracer.slang) 的运输循环，对照参考 [Replay 初始化](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathTracer.slang:234) 与 [Hybrid 可逆性检查](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathTracer.slang:1165)。
- [PathBuilder](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/PathBuilder.slang) 对照参考 [forceAdd](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathBuilder.slang:87)，通过 initialSeed、长度和贡献槽恢复样本，不重新执行树内 RIS。MyPT 独立采样三类 NEE，因此槽位保留光源分支；同长度的 BSDF arrival 允许发光面与环境互换。
- [Shift](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/Shift.slang) 对照参考 [RandomReplay / Hybrid](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/Shift.slang:90)。完整 Replay 使用单位 PSS Jacobian；Hybrid 重放前缀并连接固定后缀，Jacobian 只含连接几何及相关 BSDF PDF 比例。选中后更新目的域贡献和连接前端描述。
- 时间保留 Talbot、空间保留 Pairwise 的既有权重生命周期，对照参考同名 TemporalReuse / SpatialReuse。关闭某一阶段时完整旁路，历史取最终结果。

## 策略与支持范围

本轮对应参考的 `separatePathBSDF=false` 分支：使用材质 roughness 分类和完整 BSDF / mixture PDF。参考默认的分量拆分需要成套分量 eval/pdf 与 MIS，尚未统一。

Hybrid 选择第一个满足两端粗糙度及最小距离的有限表面 rc。目的前缀提前终止、出现更早 rc、分类或连接事件改变时拒绝；连接另检查两侧距离、可见性及约 11 倍的对称 Jacobian 支持域。失败由 defensive canonical 提案保留贡献，不裁剪辐射，不改用完整 Replay 绕过失败。

有限 rc 的前缀和连接端限定 Standard 材质，连接前 RNG 状态必须匹配。非 Standard 前缀归入 noRC 完整 Replay；目的也必须属于 noRC 分区。RR 按现有 MyPT 参数执行，连接前存活倒数进入前缀，rc 及后续的存活倒数进入后缀，各计一次。

以下差异仍然成立：

- BSDF 恰在首次可连接表面发光终止时，该贡献归入 noRC；已有更早有限 rc 的后缀仍保留它。本轮未实现参考额外的发光/逃逸终端 rc 表示，包括无限远 rc。
- 当前只支持三角形几何。静态场景允许相机运动重投影；几何、材质和光照变化清空历史，DOF 时间复用旁路。
- MyPT 自己计算三类 NEE，尚未与参考外部 DI 输入统一。Uniform 沿用 Falcor 的余弦参考采样分支，其连续 BSDF 求值不能证明 delta 反射/透射能量正确；必需能量配置均开启 importance sampling。
- Layered 补充仅用于兼容性和数值稳定性，不证明分层材质统计收敛。fresh 的深 rc、镜面/透射事件计数也不能代替各类前缀成功跨像素复用的覆盖证据。

## 数值一致性修复

所有 GRIS compute programs 使用 `FloatingPointModePrecise`。对数 Jacobian 改为分别计算源/目的成对差再相加，使交换方向时保留符号对称性；原支持范围及 `1e-3` 诊断阈值不变。

[GRIS/BSDF.slang](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/BSDF.slang) 从已有 StandardMaterialInstance 取得最终 shading frame，以明确顺序的 precise 标量乘加完成方向变换，随后调用原 StandardBSDF eval/pdf 和半球检查。其他材质保留原接口。生成、Replay 和重连共用该入口，没有另写 BSDF 物理模型。

固定 rc 另保存位置、UV、未调整 TBN、原 tangentW 和未翻转 faceN，生成与双向移位共用这些视角无关的原始表面属性。目标 V/frontFacing 仍重算，材质 setup 仍处理目标视角的法线调整与折射率。新增字段合计 84 字节，实际 buffer stride 以反射为准；性能与存储代价留到 M6 测量。参考本身仅存 rcHit 后重建表面，这份缓存属于本地 Falcor 8 数值适配。

身份诊断实际重放或重建 F，只将恒等连接 J 设为解析值 1；不复制源 F，也不放宽门槛。`shiftDebug` 同时记录缓存/现场差异与正反映射失败码；失败支持域与 invalid contribution 分开统计。

## 冻结构建的验收结果

最终证据见 [验收索引](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/FINAL_STATUS.md)、[聚合报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/aggregate_report.json) 和 [source_state](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/source_state.json)。[冻结清单](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/freeze_manifest.json) 固定生产源文件、DLL、部署 shader、场景、参考实现和验证框架；每个完成的 worker 独立检查运行前后状态。旧构建的通过结果不计入本轮。

四组核心配置均完成 16 个预定种子 × 2048 帧，共 131,072 帧。四种时间/最终结果相对初始 RIS/同树 PTReference 的配对比较，均满足每个 RGB 通道的 whole-seed 95% CI 完整落入 ±1%；初始 RIS 对照和数值检查也通过。每个 worker 的构建状态检查为一致。单 worker 的 `status=partial_pass` 表示仅运行分配到的配置，整体结论来自严格聚合。统计单位是完整独立种子序列，半程诊断和相关历史帧未当作独立样本；逐案例/通道区间不宣称同时覆盖所有比较的置信度。

- [Hybrid / Cornell indirect](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/hybrid_cornell_indirect/report.json)：核心检查通过；四种比较所有 RGB 的最远相对 CI 端点为 0.7717%。
- [RandomReplay / tutorial](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/random_replay_tutorial/report.json)：核心检查通过；对应最大端点为 0.3397%。
- [RandomReplay / Cornell indirect](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/random_replay_cornell_indirect/report.json)：核心检查通过；对应最大端点为 0.3579%。
- [Hybrid / tutorial](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/hybrid_tutorial/report.json)：核心检查通过；对应最大端点为 0.3749%。

四组核心的最大 fresh 身份贡献误差为 `5.09333e-7`，最大空间身份/往返误差为 `4.43512e-7`，最大时间往返误差为 `2.38129e-7`；身份 J 与缓存/现场误差为零。这里的最大值仅覆盖四组核心测试，不能提前作为边界及补充测试的全局最大值。

- **27 项边界：完整复验通过。** [新报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/boundaries/report.json) 与[结束快照](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/boundaries/run_end_state.json) 确认全部项目通过且生产状态未变。覆盖身份恢复、零/重复/越界槽、多轮、零贡献、RR、材质、近场、noRC、策略/分辨率切换、相机运动、缺少 mvec、jitter 与最终空间历史保存。[原中断报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundaries/report.json) 的 20 项和开始快照原位保留，计入通过数量为零。[恢复附录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/recovery_plan.json) 在重跑前登记；新进程的测试逻辑、顺序、预算和门槛不变。四组完整核心结果属于同一冻结构建，已重新独立审计，未从中断帧拼接验收。这不等于原五进程一次完整通过。
- **边界图像：通过结构检查。** 已查看新的近场、材质和运动前/移动/稳定后三组图，未见明显新增缺失表面、轮廓错位或大块旧物体残留；单帧噪声较大，不能据此排除细微拖影。Uniform 行的镜面/玻璃在包括 ptReference 的四阶段均有黑轮廓，受前述已有 delta 限制约束。[人工记录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/boundary_previews/manual_visual_review.json) 绑定本次预览和报告哈希。
- **较高分辨率视觉：通过结构检查。** [报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/visual/report.json) 覆盖 convergence_test 与 Cornell indirect 各 256×192、128 帧。已实际查看两组固定 EV0 / Reinhard / sRGB 阶段图，物体、材质与遮挡结构一致，未见明显新黑洞或边缘漏光；部分 temporal/final 区域比同树参考更颗粒化，仍有亮点。原始 HDR、相机/参数、图像哈希及[人工记录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/visual/manual_visual_review.json) 保留；不宣称降噪或性能提升。
- **Layered：通过兼容性和数值检查。** [报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/layered/report.json) 使用 PBRTCoatedDiffuse，64×48，三种策略各 20 帧。六项映射误差及 invalid contribution 全为零；RandomReplay、Hybrid 各有 120,910 次空间接纳，Hybrid 正贡献 noRC fresh 为 57,231。该测试不证明分层材质统计收敛。
- **原入口：通过。** [检查记录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/entry/entry_checks.json) 确认原 MyPT.py + tutorial 的 640×360、16 帧渲染，以及 83×47 / 可选 viewW 输入兼容性。原 Accumulate、ToneMapper、Stratified 流程保留，已实际查看[输出截图](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/entry/MyPT-entry.ToneMapper.dst.0.png)。
- **严格聚合：通过。** [恢复审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/boundary-recovery/aggregate_report.json) 的 `acceptance_pass`、`core_acceptance_pass`、`supplementary_validation_complete` 均为 true，状态为 `passed_with_retained_interruption`；完整性、统计及运行/数值失败列表为空。审计重算核心原始数组与 CI，核验全部新边界和三项补充，并保留原中断及历史失败的哈希。Release / MyPT 编译通过；最终冻结源码与部署 shader 一致。原 PT shader 与共享 MyPTCommon 未因 M5 修改。

新边界中保存累计诊断的 21 项，最大身份 F 误差为 `3.55685e-6`，空间身份/往返为 `4.04630e-7`，时间往返为 `2.01877e-7`；身份 J 和缓存/现场误差为零，均低于 `1e-3`。其余 6 项逐帧执行门槛断言并通过，但未保存累计最大值，因此这些数值不表述为全部 27 项的精确全局最大值。独立复核的 41 份新边界快照九通道全部有限，radiance 非负、invalid=0。最终 360 项产物哈希匹配，四组核心、新边界及三项补充共八个完成进程的开始/结束状态均匹配冻结构建。

## 保留的失败历史

以下是修复依据，不属于最终通过证据；旧报告和原始数组保持原状态，不覆盖为成功：

- [初始四组能量测试](C:/Users/13243/Desktop/Restir/Falcor/build/gris-hybrid-validation/report.json) 各 4 种子 × 1024 帧，未全部达到 CI 精度要求；随后使用预先固定的 16 种子 × 2048 帧预算。
- [Hybrid / Cornell seed=2027、frame=102](C:/Users/13243/Desktop/Restir/Falcor/build/gris-hybrid-confirmation/report.json) 出现单向通过、反向超界的 Jacobian 失败，定位到对数比值左结合，改为成对差求和。
- [seed=3511、frame=613](C:/Users/13243/Desktop/Restir/Falcor/build/gris-hybrid-recovery/hybrid_cornell_indirect/report.json) 的 emissive NEE 身份误差为 `0.00116894976`。共享稳定点积的短回归降到 `0.00087558612`，但后续完整重试仍在 [seed=4507、frame=1944](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-final-validation/hybrid_cornell_indirect/report.json) 出现 `0.00125626556`，该轮继续判失败。固定 rc 原始表面缓存加入后，两处[短回归](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m5-surface-validation/surface_regression.json) 降到约 `3e-7`，再冻结新构建并从头运行本轮全部预算。短回归只断言目标帧，不能代替完整验收；本轮完整 Cornell 核心测试已覆盖这两个种子的所有帧。
- [旧单进程长测试](C:/Users/13243/Desktop/Restir/Falcor/build/gris-hybrid-fixed-validation/report.json) 发生 `MemoryError: bad allocation`。源码发现 [ProgramManager 的成功编译路径](C:/Users/13243/Desktop/Restir/Falcor/Source/Falcor/Core/Program/ProgramManager.cpp:124) 未释放创建的 Slang compile request；尚未完成分配归因，不能声称它是耗尽的唯一来源。本轮未修改 Falcor 核心，采用固定预算的新进程分组执行。这与最后一轮缺少结束快照的外部中断分别记录，不能仅凭后者没有 traceback 推断操作系统终止原因。

## M6 保留事项

M6 仍需完成跨 Falcor 的原始 HDR 对拍，统一或记录 separatePathBSDF、终端 rc 表示、DI 与采样配置差异，再比较 realtime/offline 的图像误差、动态残留及同时间性能。每 pass GPU 时间、射线数、失败率和表面缓存成本尚待实测；NRD 按需要另行接入。

成功编译请求生命周期修复及长进程重复重建 shader 的资源复验也保留到 M6。分进程验收通过不等于该问题已修复。同树 PTReference 的统计一致性不等于完整原版 GRIS 的画质与性能已经对齐。
