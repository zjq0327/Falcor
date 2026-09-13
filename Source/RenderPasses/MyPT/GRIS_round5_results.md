# 第五轮：M6 实现、对照与验收记录

状态：最终 support-gate 构建的实施、固定预算测量、最终 16 进程/344 帧边界回归，以及四项独立长轨迹能量确认已完成，原 PT / ReSTIR UI 保持不变。首轮三光组能量验收为 14 项通过、4 项统计精度不足；后四项在另行登记的 8×4096 帧确认中全部通过原门槛，原不足结果完整保留。同 GPU 时间质量仍待验证，当前 DI 分工、部分末端 RC 和性能仍与参考有差距，不能声明 M6 已全部完成或效果/性能完全对齐 GRIS。同 GPU 时间校准在第 34 项失败，正式比较未启动；本记录按实际通过、失败和未执行状态收尾。

## 1. 最终实现与崩溃修复

MyPT 继续在既有 ReSTIR 模式按 GeneratePaths → TracePaths → TemporalPathRetrace → TemporalReuse → SpatialPathRetrace → SpatialReuse → Resolve → StoreHistory 执行；空间阶段可多轮，禁用时间复用时不执行时间阶段。M6 没有另建 PT 产品模式，也没有改变用户原 MyPT.py 入口。

针对 Mogwai 的访问异常和反复重建图时内存增长，最终统一构建包含五项组合：成功/失败编译请求的 RAII 释放；ProgramVersion 持有 Slang session；ProgramReflection 持有其借用 layout 的确切 composite/entry component；参数块改用显式指定所属 session 的 GFX API2；按完整编译配方和已解析依赖复用/失效 session。此前仅释放请求或仅保留 session 的版本仍崩溃，未将这些中间结果当作修复通过。

用户截图仅提供一次非法内存读取的信息，没有该次故障的转储或符号调用栈，因此不能仅凭读取地址 0x18 唯一归因到某个对象。这里的根因证据来自独立复现：保留会话但释放确切 composite 后，旧 layout 会失效或被其他布局地址复用；补齐所有权、参数块所属会话及缓存的组合随后通过规定重建工作负载与最终入口回归。它证明已复现的生命周期/绑定缺口得到修正，不证明每次访问异常都只有这一原因，也不将后来的 Python 测量接口失败混作同一故障。

统一 ALL_BUILD 后，规定的同进程 8 图重建全部完成，8 图颜色哈希与该旧工作负载相同。运行 837.563 秒，采样峰值私有内存 5,407,604,736 bytes；预热后释放点净增 58,834,944 bytes，低于预登记 8 GiB 上限。这里是进程 PrivateBytes，不是 GRIS buffers 或总显存；也不证明任意新编译配方都不会增长。证据：[8 图生命周期报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-memory/after_session_cache/report.json)。

上述 8 图证据来自最终框架组合、发光面可见性修复前的 shader。之后框架代码保持不变，但可见性修正有意改变画面，不能把这项旧工作负载的颜色哈希冒充最终 shader 的 HDR 等价证据；最终 shader 的批次、插桩和边界回归分别记录。

同框架构建 GPU 测试包括 CompileSessionCache 3 项、ShaderString 7 项执行通过（另 1 项原有跳过）、ParameterBlockSession 1 项、ParamBlockCB 1 项、RootBufferParamBlock 4 项。发光面可见性实际求交测试另有 1 项通过。后续独立源码审查未发现所检查正常调用路径中的新阻塞缺陷，见 [core 只读审查](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-core-review/readonly_review.md)；这项源码审查不代替运行测试。

保留边界：缓存检查已解析的依赖；更高优先级搜索目录新建同名文件造成遮蔽时需要 force reload。ProgramReflection 的 mpProgramVersion 仍是借用指针，不能脱离其所属版本生命周期使用全部反射 API。不同新编译配方仍可能由 GFX 缓存保留到 Device 结束。

## 2. 可见性与重放查询修正

共享场景相机/深度已经一致，但修复前当前高样本初始结果明显偏暗：RGB=[0.009023669, 0.009345520, 0.004116299]，参考=[0.018983913, 0.019880018, 0.013076298]。原因是当前几何起点偏移更大，旧发光面阴影射线在偏移起点后仍沿用原方向和距离，地板/箱顶会被光源自身遮挡。

按参考 generateEmissiveSample 的方式，对着色点和光源点分别偏移，再重新计算可见性段的方向/长度。既有 PT 与 GRIS 共用 getMyPTEmissiveVisibilityRay；采样点、BSDF、PDF 和随机序列的语义不变。真实 GPU 单测覆盖旧线自遮挡、新线可见、真实箱体/墙面遮挡和可见控制项。修复后诊断高样本均值与参考差小于 0.03%；最终能量结论以第 5 节完整置信区间为准，未用曝光或 clamp 掩盖偏差。

重放仅在会被使用的贡献槽执行相应可见性，保留普通运输采样的 RNG 消耗。有限 RC 前缀不执行 NEE 阴影查询；noRC 回放只检查目标贡献槽。相同 primary hit/direction 的时间恒等映射在 TemporalReuse 本就不消费前缀，TemporalPathRetrace 现在共用判据跳过它们。Hybrid compact prefix 不返回源支持标志或缓存 PDF，因此以独立 evaluateSourceSupport=false 分支同时跳过无用支持查询和计数；普通 generation 和完整 Replay 默认保留该检查。

最终 support-gate 前后普通末帧和 16 帧计数阶段 HDR 逐字节一致；全部 shift 结果和其余计数一致，仅空间 connection 计数 20,210,527 → 20,180,365（减少 30,162）。这是删除不被消费的查询表达式与配套计数的验证；Slang 可移除 __NoSideEffect 查询，旧插桩的增量不能单独证明同样数量的硬件射线实际执行。MyPT 时间 6.336124 → 6.669484 ms，单次数据没有证明加速。证据：[独立逐字节审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/support_review.json)。

最终重新运行的 emissive 六组 8×256 批次与门控前同配置的 1,536 份检查点 HDR 全部逐位一致；两端各自保留独立运行/构建审计，旧精度不足结论没有被覆盖。见 [六组输出等价性](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/support_gate_six_batch_equivalence.json)。

## 3. 测量接口与最终插桩验收

新增接口均用于脚本和可选输出。resetSampling(seed) 只重置 MyPT 的帧号、种子与历史，不重置上游 jitter 或动画。referenceLambertian 默认为 false；本次比较显式启用以匹配旧材质模型，没有新增 UI 模式。resourceStats 返回实际 GRIS StructuredBuffer 的 bytes/stride/elements，不代表整个程序显存。

五张可选 RGBA32Uint 输出只有连接时启用。rayStats0 依次为 generation closest/shadow、temporal prefix closest/shadow；rayStats1 为 temporal connection、spatial prefix closest/shadow、spatial connection；rayStats2 为 validation closest/shadow、普通 PT closest/shadow。temporalShiftStats 与 spatialShiftStats 依次为通过几何筛选的 pair、算法使用的非恒等非零源方向尝试、失败方向、正贡献成功方向。零目标支持可使后两项之和小于尝试数。

计数是追踪调用次数，不是路径数或求交次数；同一前缀可包含多条射线。通道按查询语义/时间或空间阶段分类，不能机械地认定 connection 全部来自 Reuse Pass。额外诊断单独计数，VBuffer 主射线另列。

最终 realtime/offline × indirect/full 的四组插桩全部通过，每组 13 序列 × 4 帧，共 208 帧。检查包括开关计数颜色逐位一致、诊断隔离、无中间 readback 的连续渲染等价、resetSampling 与重建 pass 一致、关闭复用计数为零、普通 PT 独立 seed/零 seed 重放。20 个正式 profile 与六组当前批次也完成；29 项队列加单独 support-gate profile 共 30 份结果已独立核验全部原始文件、内外层状态、64 条时间记录与 16 帧计数。见 [最终 profile/插桩审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/final_support_gate_campaign_audit.json)。

## 4. 参考物理配置及适用范围

参考源码为 ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass。共享夹具是静态三角形、无纹理/透射、opaque rough SpecGloss、pinhole Center 采样；当前启用参考 Lambert diffuse。两端关闭 RR，完整 BSDF/mixture PDF 对应 separatePathBSDF=false。当前 maxBounces=8 与参考各 bounce 上限=8 对应。GGX 采样、随机数消耗与部分末端编码仍不同，不要求跨版本同 seed 逐路径一致。

当前没有参考“发光末端/无限远末端本身作为额外 RC”的全部编码；此类终止贡献可能归入 noRC 完整贡献槽回放，较早有限 RC 的后缀仍可重连。贡献没有据此直接丢弃，但可复用机会、方差和开销可能不同。不能称逐路径映射完全复制参考。

参考开启内部 DI、关闭外部 DI 的简单组合不构成有效完整光照对照。正式完整图使用已有第二个参考 ReSTIRPTPass：原生 PT、四项 bounce=0、NEE 开、MIS 关、T/S 关，DI.color 接主 GI directLighting。主参考 GI 关闭内部 DI。算法 DI 为 1 spp，高样本基线为 GI64+DI64；完整图性能包括额外 DI。原参考 DLL/源码未为此改写。

当前完整光照仍有一项明确的结构差异：MyPT 的 PathBuilder.acceptsContribution 仅在 COMPUTE_DIRECT=false 时拒绝 length≤1；computeDirect=true 时，primary NEE 等短直接贡献与较长 GI 贡献通过 addContribution 进入同一个 reservoir。TracePaths 对 N 棵完整候选树执行 mergeTree，再统一 RIS。参考 addNeeVertex 只让 pathLength≥1 的 NEE 入 GI reservoir，其 primary 表面 path.length=0；正式参考完整图的 primary DI 由外部 DI-only Pass 计算，随后在最终阶段单独相加。两端长度字段的计数定义不同，不能只看常数 1 就认定筛选相同。对应源码：[当前贡献筛选](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/PathBuilder.slang:32)、[当前候选合并](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/TracePaths.cs.slang:18)、[参考 NEE 筛选](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathBuilder.slang:118)、[参考最终 DI 相加](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/SpatialReuse.cs.slang:541)。本轮保留既有 MyPT 实现，这项估计器分工尚未与参考完全对齐。

GI seeds=[1103,2203,3301,4409,5501,6607,7703,8803]，DI seeds=GI+1,000,000。正式测量独立切换 emissive、analytic、environment 三个光组，各含 indirect/full；每次只测对应光组。analytic/environment 的额外 6 项 DI ownership smoke、24 项 batch 全部完成：共 24×8×256=49,152 正式帧及 24 smoke 帧。独立审计核验 3,912 份 raw HDR、种子/帧数/配置、DI>0、full=GI+DI 仅加一次和同 seed 重放。见 [额外光组原始合同审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/additional_light_groups_raw_audit.json)。

完整 DI 合同仅覆盖共享 opaque rough 场景，无相机可见发光体/背景；不扩大为任意 delta、透射或背景所有权证明。参考 ColorFormat 未注册导致完整属性 getter 不可用的事实仍保留；报告用源码核对的 setter、after-scene-load 更新和可读取 fixed-seed 状态记录参数，没有伪造完整 getter 成功。更多源码对应见 [源码对齐记录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-reference/final_alignment_notes.md)。

## 5. 三光组固定预算统计

固定数值预算为 96×64，每配置 8 条独立完整轨迹 × 256 帧，无排除预热。ROI=[12,8,84,56]，共 3,456 像素；实际批次深度逐位匹配，hit mask 无差异。baseline 主验收通道为 ptReference；realtime/offline 为最终 color，同时保留 initialColor、temporalColor 等阶段。每个 RGB 分量的差值区间必须整体进入 ±1%；参考自身 95% 相对半宽须小于 0.25%。统计独立单位是完整 seed 轨迹，不把相邻时间复用帧当独立样本。两引擎使用独立均值区间，未伪装为逐路径配对。

以下直接摘录既有独立 CPU 统计，未另行重算或修改预算。18 项主输出中 14 项 pass、4 项 insufficient_precision；没有 energy_mismatch 或 invalid。所有参考自身精度检查通过。

### emissive

[完整统计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/results_emissive_support_gate_v1/summary.json)。

- baseline_indirect：pass；R=[-0.015406%, 0.064877%], G=[-0.017397%, 0.055133%], B=[-0.019452%, 0.077629%]。
- baseline_full：pass；R=[0.015424%, 0.060367%], G=[0.014802%, 0.055727%], B=[0.018724%, 0.062196%]。
- realtime_indirect：insufficient_precision；R=[-0.107010%, 1.282217%], G=[-0.871453%, 1.295316%], B=[-0.660840%, 1.658825%]。
- realtime_full：pass；R=[-0.442692%, 0.856559%], G=[-0.446123%, 0.738150%], B=[-0.553058%, 0.615431%]。
- offline_indirect：pass；R=[-0.032319%, 0.231292%], G=[-0.126472%, 0.070837%], B=[0.009711%, 0.237607%]。
- offline_full：pass；R=[-0.012486%, 0.087845%], G=[-0.026855%, 0.076150%], B=[-0.017004%, 0.072721%]。

### analytic

[完整统计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/results_analytic_support_gate_v1/summary.json)。

- baseline_indirect：pass；R=[-0.034028%, 0.046284%], G=[-0.037844%, 0.050554%], B=[-0.033616%, 0.051386%]。
- baseline_full：pass；R=[-0.010817%, 0.014740%], G=[-0.012385%, 0.016570%], B=[-0.007752%, 0.011888%]。
- realtime_indirect：insufficient_precision；R=[-1.343153%, 0.476740%], G=[-0.795226%, 0.958206%], B=[-1.129339%, 0.896872%]。
- realtime_full：pass；R=[-0.634979%, 0.794038%], G=[-0.428656%, 0.463729%], B=[-0.619064%, 0.848464%]。
- offline_indirect：pass；R=[-0.108107%, 0.189023%], G=[-0.129776%, 0.096812%], B=[-0.043221%, 0.140861%]。
- offline_full：pass；R=[-0.074751%, 0.105685%], G=[-0.060443%, 0.056525%], B=[-0.051344%, 0.056875%]。

### environment

[完整统计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/results_environment_support_gate_v1/summary.json)。

- baseline_indirect：pass；R=[-0.021776%, 0.039932%], G=[-0.034176%, 0.040949%], B=[-0.034140%, 0.044753%]。
- baseline_full：pass；R=[-0.046300%, 0.055353%], G=[-0.048536%, 0.051641%], B=[-0.056007%, 0.061384%]。
- realtime_indirect：insufficient_precision；R=[-1.610211%, 0.275917%], G=[-0.317972%, 0.515332%], B=[-0.268620%, 0.966725%]。
- realtime_full：insufficient_precision；R=[-1.091822%, 1.155008%], G=[-0.452402%, 0.366995%], B=[-0.737512%, 0.707501%]。
- offline_indirect：pass；R=[-0.154861%, 0.087514%], G=[-0.083034%, 0.035881%], B=[-0.202538%, 0.116634%]。
- offline_full：pass；R=[-0.093567%, 0.100211%], G=[-0.114365%, 0.096241%], B=[-0.099729%, 0.104015%]。

四项不足是三个光组的 realtime indirect，以及 environment realtime full。对应实时 initialColor/ptReference 通过，而 temporalColor 后区间变宽，说明旧预算无法对时间复用的相关性给出足够精度；不能仅因点估计接近就改判通过，也不能由区间过宽直接断言有偏差。

另行登记的独立长轨迹确认已经完成。三光组 realtime indirect 与 environment realtime full 各为 8 条完整冷启动轨迹×4096 帧，共 131,072 实际帧；种子为 [21000011,23000017,25000019,27000023,29000027,31000033,33000037,35000041]。这四组使用同一组新 seed，组间及同轨迹各阶段不宣称独立；每项统计仍只把自身 8 条完整轨迹作为独立单位，原 256 帧样本不合并、不覆盖。

四项最终 color 的相对差值区间全部进入原 ±1% 门槛，参考自身 95% 相对半宽均小于 0.25%：

- emissive realtime indirect：pass；R=[-0.471786%,0.195114%]，G=[-0.205526%,0.281261%]，B=[-0.181671%,0.282011%]。
- analytic realtime indirect：pass；R=[-0.444654%,0.338474%]，G=[-0.223247%,0.219048%]，B=[-0.139374%,0.253531%]。
- environment realtime indirect：pass；R=[-0.420286%,0.244930%]，G=[-0.101454%,0.388278%]，B=[-0.259474%,0.242771%]。
- environment realtime full：pass；R=[-0.038993%,0.304657%]，G=[-0.185451%,0.188037%]，B=[-0.117520%,0.245734%]。

同批四阶段 color、initialColor、temporalColor、ptReference 的 16 项检查均通过；区间是逐分量保证，不主张所有 RGB/光组同时的 familywise 置信度。独立 CPU 审计再次核验四进程退出/内外层状态、全部冻结身份和原始产物哈希、每条实际 4096 帧预算、ROI 深度及原始均值图，并从 raw 重新计算 ROI 和区间算术，与汇总一致。证据：[三光组间接确认](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-confirmation-resume1/results_v1/summary.json)、[环境完整图确认](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-confirmation-env-full/results_v1/summary.json)、[独立 raw 与区间审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/final_confirmation_raw_audit.json)。这补足了所登记场景和 ROI 的能量精度，不证明同时间质量或任意材质已经对齐。

三光组原确认队列因环境/工具中断没有写出任何 seed 结果，原子进程随后已不存在；其未完成状态不是 shader 崩溃证据，也不构成通过结果。旧目录完整保留，在 gris-m6-confirmation-resume1 重新登记完全相同的 worker、代码/种子与每组 8×4096 帧预算，原样本不合并。environment realtime full 另有先行登记的同预算确认，最终四组全部执行完固定预算，未按中途误差跳过或延长。见 [中断与重登记记录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-confirmation-resume1/interruption_record.json)。

### 暗区覆盖

预登记暗区阈值为参考线性 RGB<0.001，但六份参考均值在此次中央 ROI 内每个分量的暗像素计数都为 0；最小值是 analytic 蓝分量 0.001407853750。因此暗区绝对误差条件没有被这些批次触发，必须记录为“未覆盖”，不能写暗区 GPU 验证通过。证据：[暗区覆盖检查](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/dark_roi_coverage_support_gate_v1.json)。

## 6. 640×360 性能记录与查询量

这些是既有计时实现的描述性记录。第 7 节记录了后来发现的参考时间读回同步缺口：这不会改变已保存的原始数字，但限制精确帧对应和最终同时间结论；同步修订后还需重新校准，不能把本节比例当作该验收通过。

以下为共享 emissive 场景的单次固定 profile，不把 96×64 时间冒充代表性分辨率。每组预热 32 帧、保留 64 条 GPU 时间；查询量来自另一个预热后的 16 帧计数段，正常计时不连接计数/诊断。完整图包含 VBuffer 和参考额外 DI，父 Pass 已包含子阶段，不能重复相加。

- pt indirect：MyPT 0.322272 ms；当前完整图 0.369860 ms / 参考完整图 0.513228 ms（当前/参考 0.720654）；MyPT 实际查询 7.818132324 条/像素/帧。
- pt full：MyPT 0.316332 ms；当前完整图 0.351400 ms / 参考完整图 0.600672 ms（当前/参考 0.585011）；MyPT 实际查询 8.821218262 条/像素/帧。
- realtime indirect：MyPT 6.669484 ms；当前完整图 6.709344 ms / 参考完整图 2.508400 ms（当前/参考 2.674750）；MyPT 实际查询 13.266003961 条/像素/帧。
- realtime full：MyPT 6.657676 ms；当前完整图 6.698132 ms / 参考完整图 2.568164 ms（当前/参考 2.608140）；MyPT 实际查询 14.255562066 条/像素/帧。
- offline indirect：MyPT 57.804272 ms；当前完整图 57.829312 ms / 参考完整图 30.463936 ms（当前/参考 1.898288）；MyPT 实际查询 282.392511122 条/像素/帧。
- offline full：MyPT 58.821236 ms；当前完整图 58.862396 ms / 参考完整图 30.080904 ms（当前/参考 1.956803）；MyPT 实际查询 314.250856662 条/像素/帧。

以上查询另加入口代码推导的 VBuffer 主射线 1 条/像素/帧。RT 已分配 GRIS buffers=333,619,200 bytes，offline=351,129,600 bytes；PT 模式相应 buffers=0，但 PT 仍使用纹理等其他 GPU 资源。参考未增加相同查询/缓冲统计接口，不提供虚构的参考计数。

当前主要差距是 SpatialReuse：RT 间接 3.539128 ms / 参考 0.822824 ms；RT 完整 3.350824 / 0.799472 ms。Offline 间接 TracePaths 33.577892 / 参考 tracePass 24.776140 ms，SpatialReuse 19.910636 / 4.099208 ms；完整分别 34.286200 / 24.514556 ms 与 18.860984 / 4.028092 ms。这些是测量差异，不把单个 Pass 的成本直接解释成同样比例的光线量或图像质量差异。

每阶段均值/中位数/p95、12 个 ray 分量、失败率分母和每个缓冲的 stride/elements/bytes 已完整记录于 [性能明细](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/final_performance_draft.md)，原始精度见配套 JSON。RT 间接明确使用最终 support-gate 的 6.669484 ms，没有使用旧 postopt 的 6.336124 ms。单次轨迹的时间比例是描述性结果；既有 profile 显示明显差距，精确比例待有效计时复测，不能称性能已对齐。

## 7. 同 GPU 时间质量及最终边界回归

同时间质量 v1 首个 current preflight 在创建 AccumulatePass 时触发 Python 属性转换错误：ResourceFormat.RGBA32Float 枚举无法转为该接口所需 JSON。错误发生在预热循环之前，实际完成预热 0 帧、seed 0 条；报告的 warmup_frames=32 是计划值。外层失败及原日志保留，不能写作渲染成功或内存访问崩溃。support_gate_fix1 只修订 current outputFormat 为对应字符串，保持原 N、种子、重置与时间门，用于时间校准和描述性对照。见 [原 preflight 失败报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-equal-time-campaigns/support_gate_v1/realtime_indirect/current_preflight/report.json)。

fix1 的前 9 项通过，第 10 项 reference offline indirect preflight 未通过同 seed 逐位重放门，后 6 项未启动。实际完成了两次各 4 帧及各 1 帧计时排空：前三帧分别有 2,389 / 2,925 / 2,888 个 RGBA32Float 分量不同，最大绝对差分别约 1.606e-6 / 9.537e-7 / 1.770e-6；第 4 帧和末帧图逐位一致。每次轨迹自身的 GPU Double 累积均值都与 CPU 均值逐位一致，但两次均值彼此仍不同，最大差约 4.023e-7。因此累积核对通过不能替代 reset 门，微小差值也没有被直接改判为通过；根因仍须诊断。子进程正常退出、业务报告 failed，源状态未变，不是本次出现了新的访问异常。见 [fix1 队列](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-equal-time-campaigns/support_gate_fix1/launcher/launcher_report.json) 与 [实际失败报告及 raw](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-equal-time-campaigns/support_gate_fix1/offline_indirect/reference_preflight/report.json)。

随后参考重置诊断 probe 的首版登记为 2 进程共 84 次 render calls，并非实际完成 84 帧。首进程完成 32 次预热及第一帧渲染后，在读取旧版 Texture.width Python getter 时发生参数签名异常，实际调用 33 次、完整记录的测量帧为 0，第二进程未启动。exit_code=0 而业务 failed，所有旧输出保留；该诊断没有形成 reset 或质量通过证据，也不是渲染器崩溃。见 [probe 原始失败](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-reference-reset-probe/runs/original/report.json) 与 [外层结果](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-reference-reset-probe/launcher/jobs/original/launcher_report.json)。

独立 probe-fix1 修复 getter 调用后，original 变体完成了 42 次 render calls，但第二条重复轨迹的 profiler 辅助统计包含 NaN，严格 JSON 序列化因此失败，仍不能记整项通过。已保存的原始颜色可单独核验：旧失败 preflight 与该 probe 分属两个进程，匹配 repeat 0/1、frame 0..3 的 8 对图逐位一致；旧 preflight 的全部生产文件 pin 在新 probe 中存在且相同。这是当时两个进程之间的 8 对 raw 观察，不能泛化为后续任何新进程必然相同，也没有修好或推翻同进程重复间的差异。证据：[probe-fix1 报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-reference-reset-probe-fix1/runs/original/report.json)、[跨进程 raw 独立审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/reference_cross_process_raw_audit.json)。

随后 probe-fix2 在独立目录只修正诊断序列化：非有限辅助值保留为明确 NaN/±Infinity 标签，不当作 0；完整必需 graph/Accumulate/直接子阶段时间仍严格 finite，camera 非有限值明确标为不可用。两个隔离变体实际各 42 次、共 84 次 render 完成，退出/内外层状态与全部 raw 哈希、Double 均值、原始时间解码均通过；163 个捕获依赖逐文件复核仍相同。original 图与 primary_instrumented 图各自的两次重复、以及跨图同重复的四帧/mean/last/CPU mean 全部逐位相同。instrumented 四帧 packed VBuffer/depth 和 12 个公开 camera 参数也全部相同。本轮实际 profiler 没有出现非有限标签，其处理分支通过 CPU 测试覆盖。证据：[probe-fix2 完整 raw 审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/reference_reset_probe_fix2_audit.json)、[probe-fix2 全部来源复核](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/reference_reset_probe_fix2_source_audit.json)。

这些新 HDR 全部等于两次旧失败进程的 repeat 1；旧 repeat 0 的前 3 帧及均值仍不同，第 4 帧/last 相同。不能把新诊断完成解释为旧失败已通过。本轮未复现 radiance 微差，旧失败缺少逐帧 primary，因此匹配的新 primary 数据不能反推旧差异位于后续 trace，也不能定位具体内部状态或浮点原因。“随 repeat 稳定”和“fresh process 天然逐位确定”都没有被证明；运行时间变化是否影响观察仅是未经验证的假设。三个版本的失败与完成范围分别保留，未改生产代码或 transport。

新 fresh-process 方案已另行登记并运行，不覆盖旧 gate：预检由两个新进程分别完成 32 次预热+4 帧+1 次计时排空，要求双方逐位相同；每个校准 seed 单独启动进程，完成 32+N+1 次调用。fresh_calibration_v1 共登记 80 个进程，manifest SHA256 为 84b1b5e71a5f3b4634421d3cd24ed3c98bb4d85826b319d6bbdaf0d4ef737ab5。前 33 项通过，第 34 项 realtime_full_reference_seed_300007 失败，后 46 项未启动；全队列实际记录 5,278 次调用。realtime indirect/full 的 fresh 预检报告已通过，offline 两组尚未运行，不能写成四组均已通过。

第 34 项完成了 32 次预热、190 帧冷轨迹及 1 次排空，共 223 次调用，实际冷 GI seed 为 300007、DI seed 为 20300007。它触发原有时间门：某帧直接子 pass 的 GPU 时间总和超过所属图时间加 0.0001 ms。worker 在此解码检查之后才保存 raw Profiler capture，所以失败的实际时间序列没有落盘；无法量化幅度、定位帧或把原因归给某个 pass。mean/last 原始 HDR 已保存并通过独立哈希与有限值检查，但颜色不能代替有效计时。内外进程身份及 start/end 源状态相符，业务报告 failed、子进程 exit_code=0；reference 的 exit() 不传错误码，外层据业务状态正确拒绝。这不是新的访问异常证据。见 [失败队列](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-equal-time-campaigns/fresh_calibration_v1/launcher/launcher_report.json)、[独立原始证据审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/fresh_calibration_timestamp_failure_audit_v1.json)。冻结 helper、原时间门和失败产物均保留。

已发现同时间质量 v1 的初始化域缺口：参考实现的 sampleNumber=(N+1+rounds)×(seedOffset+frame)+sampleIdx，单纯选不同 seedOffset 不能保证构造器整数输入集合不重叠。v1 realtime indirect/full 分别有 212/190 个 fresh 输入值与参考 PT64 基线 GI 域相交，offline fresh 域没有交集。旧同配置检查点比较中，realtime fresh 域没有交集，而 offline 每配置有 11,040 个交集。v1 原预算保留用于真实时间和描述性 MSE，不能把它标为与有限基线独立的最终质量通过。

这些数字只描述源码算术得到的顶层构造器参数集合；T/S 域包含可能提前退出的分支，是保守可能域，不是实际执行次数。它不证明最终贡献逐位相同，也不证明无交集就等于 PRNG 数学独立。完整域、来源和集合哈希见 [初始化输入交集证据](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/reference_rng_input_overlap_v1.json)。

旧 v2 在执行前登记 fresh 初始化域分离与慢端 512 帧成本规则、N 限于 512–4096，但其原定四组 fix1 校准前提未全部完成，不能据此称最终 N 已注册。新的 fresh-process 正式框架仍要求全部 80 项校准通过，才按同流程的实测冷时间选 N，图像不参与选 N。上述第 34 项失败后，实际 CPU readiness 在全部 80 项 aggregate 检查处拒绝，尚未计算或注册四组正式 N，值继续为 null；不能用前 33 项绕过该条件。实际平均时间差 ≤2%、每条配对轨迹 ≤5% 门槛保持不变。见 [正式注册拒绝记录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/fresh_formal_readiness_after_timestamp_failure_v1.json)。旧方案及失败证据保留，后续实验须登记新身份并完成全部前提。

同 GPU 时间验收当前未通过。fresh_calibration_v1 登记 80 个独立进程，前 33 项通过，第 34 项 reference realtime full seed 300007 的计时加和检查失败，后 46 项未启动；实际共 5,278 次 render 调用。失败进程完成 223 次调用并正常退出，但业务状态是 failed，不能记为校准通过。旧 worker 在严格解码后才保存 raw Profiler，因此失败时间序列未落盘，不能判断超差幅度或具体帧。正式注册检查已拒绝该队列，四组最终 N 均为 null，正式同时间图像比较未启动。证据：[计时失败独立审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/fresh_calibration_timestamp_failure_audit_v1.json)、[正式注册拒绝](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/fresh_formal_readiness_after_timestamp_failure_v1.json)。

参考计时源码另发现同步缺口：D3D12GpuTimer::apiResolve 将 ResolveQueryData 放入命令列表后立即 Map 读回，而该 Read buffer 的 Map 不负责等待 GPU。Profiler 又使用上一帧的双缓冲事件槽，因此旧读回值可能无法对应所假定的帧。这里是源码发现的风险，不能凭缺失的失败记录确认它就是本次异常的唯一原因。Direct3D 12 要求应用负责 CPU/GPU 访问同步，见 [Microsoft Map 文档](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12resource-map)。同步修订的构建和诊断状态单独记录；原参考 DLL、原门槛和失败证据保持原样。

独立诊断 fix1 已完成 10 项 CPU 测试和输入检查，固定一次 223 calls，保存顺序为 raw Profiler → mean/last/depth → 原严格 decoder → 全 lane 诊断；原 v1 顺序缺口已保留，两个版本均未运行 GPU。诊断即使成功也不具备校准替代资格。见 [诊断说明](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-reference-timing-probe-fix1/README.md) 及 [独立复审](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/reference_timing_probe_fix1_framework_review_v1.json)。

同步修订仅在工作区 build/gris-reference-timer-sync-candidate-v1 中制作独立候选：Resolve 后显式标记 pending commands，再 flush(true) 等待，最后 Map。实际编译和链接均返回 0；4,801 个导出名称/序号、40 个依赖与原 DLL 相同，8,974 条原参考及构建输入的前后哈希全部未变。候选状态是 cpu_candidate_built_not_gpu_validated，没有部署到当前或参考程序；它尚未证明时间帧对应、渲染等价或旧异常根因。逐事件等待还会改变提交节奏，不能预先称性能等价。见 [候选构建报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-reference-timer-sync-candidate-v1/build_report.json)。

本次收尾时另一个 Material 项目的 Mogwai 仍在运行，GPU 诊断暂停。该进程在 11:36:40 才启动，晚于 11:33:08–11:33:26 的旧校准失败，不构成旧失败的解释。本次文档写回会改变 Source 文档身份，写回前的两份原文及其余 Source 哈希单独归档；上述已登记未运行的诊断绑定写回前身份，后续应在新目录重新登记实际输入并先检查，不编辑旧 manifest 绕过冻结检查。

后续顺序为：保存完整原始计时的独立诊断 → 验证所使用计时实现的帧对应及严格加和 → 在登记的新身份下完成全部四组校准 → 只按时间选择固定 N → 完成正式轨迹的实际时间与 HDR 误差比较。平均时间差 ≤2%、每条配对轨迹 ≤5% 的条件保持不变，不用同帧数 MSE、最近检查点或旧局部通过数据代替有效同时间结果。M6 的整体效果/性能对齐仍未达成。

三光组 × realtime/offline × indirect/full 共 12 组双方同配置真实检查点质量已完成。只存在 1/8/32/64/128/256 帧 raw；没有 16 帧图像，未插值补造。256 帧当前/参考算法的 MSE 比例（越小表示当前对同一有限基线的实测误差越低）：

- emissive：indirect realtime=1.223892324；indirect offline=1.023868805；full realtime=3.467182439；full offline=0.460782362。
- analytic：indirect realtime=1.095576178；indirect offline=1.030242721；full realtime=5.597011519；full offline=4.384678788。
- environment：indirect realtime=1.124774558；indirect offline=1.069196098；full realtime=0.168065634；full offline=0.013583899。

这些是相同帧数的描述性 MSE，不是同 GPU 时间的质量结论；基线只有有限样本，噪声底没有被扣除。参考算法与参考基线的初始化流未仅因模式/seed 数值不同就假设独立。完整图当前把 DI 与 GI 合并进同一 reservoir，参考则对 GI 复用后另加 DI1，两者的采样预算、候选竞争及复用对象不同。这是完整图 MSE 存在差异时必须披露的结构因素；仅凭这些结果不能量化其因果份额，也不能宣称方差与 GRIS 完全一致。完整双端六检查点与基线噪声底见 [同配置质量报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-cpu/same_configuration_support_gate_v1/summary.json)。

最终 support-gate 的 16 进程/344 帧有限预算回归全部通过，主报告状态为 bounded_regression_passed。独立 CPU 审计核验了全部子进程退出值、内外层通过状态、冻结源/运行时一致性及产物，包含 27 项 Hybrid/Replay/Reconnection 边界、5 项 temporal reset、3 种 Layered 策略各 20 帧及原入口 18 帧。采样峰值私有内存 6,639,640,576 bytes，子进程耗时之和 1,621.499 秒；二者属于回归运行，不是每帧 GPU 性能。实际触及 deep RC、delta/transmission prefix、near-field rejection 及正贡献 T/S 分支。见 [最终回归报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-regression/final-support-gate/run_report.json) 与 [独立证据审计](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-final-review/final_bounded_regression_audit.json)。这些短回归验证边界与稳定性，不替代能量收敛；未复用旧 entry 或 M5 长统计充当本次通过证据。

已实际打开最终 MyPT.py/tutorial 入口截图：橙色方块、绿色兔、蓝球和反光棋盘地板可正常辨认；16 帧短累积的噪声仍很重，不能据此称画质已收敛。该观察只确认此入口的可见输出与场景内容，没有以测试夹具替换原产品入口。截图：[最终入口输出](C:/Users/13243/Desktop/Restir/Falcor/build/gris-m6-regression/final-support-gate/entry/MyPT-entry.ToneMapper.dst.0.png)。

## 8. 保留证据与明确限制

所有旧失败和中间版本保留：原请求保留导致第 5 图触及 8 GiB；RAII-only 启动访问异常；session-only 第 5 图异常；确切 composite 的 CPU 对照；cache 测试最初布局断言错误；旧发光面自遮挡图像；插桩运行期间新增测试 shader 导致的外层输入变化；为最终 support-gate 冻结构建主动停止的自有队列。它们用于说明修复依据和证据边界，不冒充最终通过。主要位置为 build/gris-m6-memory、build/gris-m6-measurement、build/gris-m6-final/intentional-queue-stop.json。

当前可覆盖范围是已声明的静态三角形与有限路径截断条件，运动/材质边界以实际最终回归为限。任意动态几何、动画材质/光照直接时间更新、全部特殊材质能量、参考额外末端 RC、BPR、复杂 DOF/滤波、曲线/体积、缓冲压缩与完整 NRD 信号不在此处声称完成。场景编辑清历史的保守行为不等于参考任意动态路径复用。

NRD 为可选后续显示功能，不替代原始 HDR、能量或时间质量验收。独立能量确认和最终回归已通过；同时间校准失败，正式质量比较未执行，整体效果和性能对齐仍未达成。
