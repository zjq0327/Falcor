# RTPT、PG、SHaRC 与 NRD

## 独立 delta 反射降噪

`RTPTSHARCNRD.py` 默认启用独立反射 NRD；设置 `RTPT_DELTA_REFLECTION_NRD_ENABLED=0` 可回到原来的 residual 合成。底层 RTPT 属性为 `enableDeltaReflectionNRD`，默认关闭以兼容既有渲染图。`RTPT_NRD_ENABLED=0` 同时旁路普通和反射降噪，保留材质恢复。

镜面仍沿原有独立续接追踪，材质粗糙度、Fresnel 和随机数流保持原定义。当前实现为静止、几何面法线与着色法线一致的镜面首跳生成虚像深度、反射后的表面法线和世界空间运动；运动门的上一帧命中位置参与虚像运动计算。反射辐射与首个反射命中的材质因子成对去除/恢复，发光项独立合成。原始 `noisyColor` 保留完整追踪贡献；仅在最终信号合成中从 residual 移走有效的反射贡献，避免重复计光。

无有效反射命中、超出 NRD 深度范围、移动/法线不匹配镜面以及不支持的纯镜面链保留原 residual；合法的零辐射命中仍为有效引导。反射引导不进入 GRIS，也不扩展 GRIS 的根分量或候选/历史布局。额外资源为反射信号纹理和独立 NRD 的内部缓存；关闭功能的渲染图不分配这些反射输出。

同一 Veach 开关门场景的 [修复前后验证](../../../build/delta-reflection-nrd/report.html) 包含 399 帧捕获、亮点/闪烁/亮度测量、动图与 ABBA GPU 计时。RTX 5070 的 720p 渲染图增加约 0.73 ms（6.3%），公共反射纹理增加约 77.34 MiB，另有 NRD 内部缓存。桌面亮点显著减少，但部分运动帧的局部变暗仍存在；本次不解决原有全局偏暗和桌腿暗斑。

> RTPT 实验测试代码、场景及验证说明已归档到 `build/rtpt-experiment-tests-backup-20261101/`，并从当前测试构建中移除。下文的阶段验证链接指向历史归档；已有性能报告和图像仍保留在 `build/`。

## PG 持续更新与 GRIS 历史保留

PG 现在保留已学习区域并按新的独立观测持续更新。相机移动、PG Enabled/Use guiding、混合比例、prefix 0/1、训练参数或预算变化不再自动清空 PG；Freeze 暂停训练，恢复后接续原进度。首次分配初始化模型，显式 Reset PG 和更换整个 Scene 仍可清空模型，但不再因为单独 Reset PG 而重启主采样序列或清 GRIS/NRD 历史。材质、光照、几何等真实运输变化仍独立使 GRIS 辐射历史失效，PG proposal 则用后续观测逐步适应。

模型池扩缩容保留已有 Read/Build、未消费统计和诊断后重新绑定，不重编译仅因容量变化而不变的 shader。相机选择不同 LOD 时保留原 level 的区域；sceneScale 切换用 CPU 命名空间区分同数值 key 对应的不同世界范围。容量压力每批最多替换容量 1/8 的陈旧区域，预算缩小时保留有界子集，不承诺永久保留所有访问过的区域。Read 在本帧采样/PDF 评价期间保持不变，训练写独立 Build，发布仍在本帧及训练完成后进行。

固定 x2 reference-domain GRIS 不再以 PG version、generation 或 lookup 相机锚点判断历史有效性。PG 引起的程序重编译保留符合尺寸、反射布局及 reference 语义的 GRIS 历史，重新建立程序绑定和工作资源；旧 owner 使用保存的上一帧相机评价，目标 owner 使用当前相机。其他阶段按自身规则重建，例如 ENABLE_PG 重编译仍清首表面 ReSTIR DI 历史。cell-only ReGIR 在 brightnessThreshold=0 时，相机/LOD 改变不再单独触发域失效；正弱光截断保留其独立域检查。旧 F/W/M/R 始终配套使用，不按新 PG 重算源 R。GPU 记录仍为 fresh/candidate 128 B、history 108 B/像素。

`pgStats` 新增 initializations、resetCalls、modelMigrations、lastMigrationPreservedRegions、evictedRegions、namespaceChanges、activeRegions 和 readModelFingerprint；后者描述当前 namespace 的 Read 内容。`stageStats` 提供历史代际/已发布帧及 reference 语义标记；grisPGSnapshotDependent 在 reference 模式为 false，实际引导状态由 grisPGProposalActive 报告。实施契约和验证范围见 [持续更新计划](GRIS_PG_HISTORY_DECOUPLING_PLAN.md)。下文首版和性能实验中的“相机平移重置 PG”“跨 LOD 区域保留暂缓”属于当时行为，当前以上述实现为准。

本次 Release 构建通过；最终 GPU 生命周期验收为 821 帧、43,879 项检查，覆盖普通采灯、ReGIR、实际独立队列训练、容量压力及预检失败恢复。两种采灯模式各 10 独立种子的 PT/local/joint 原始 HDR 均值验收均通过，local/joint 的 D/S/RGB 共 36/36 通道满足预定 ±2% / 95% 区间门槛，包含连续 alpha 更新和 16/32 MiB 模型池迁移。精确枚举和实际 shader 抽样压力检查也通过；完整协议、数值边界限制、二进制指纹和结果见 [最终验证汇总](../../../build/gris-pg-continuous-validation/summary.json)。这些结果不作等时画质或性能结论。

## ReGIR：3D LOD cell 候选光源列表

ReGIR 使用与 SHaRC 同类的世界空间对数 LOD，尺寸独立设置：`regirCellSize=2.0`，`regirCoarsenCellDistance=16.0`。相机欧氏距离达到 16 个当前层 cell 边长时变粗一级，默认距离 32、64、128 分别换为边长 4、8、16；改变 `sharcSceneScale` 不改变 ReGIR。`regirGridSize=20` 是兼容容量提示，向上取二次幂后分配 8192 个持久哈希槽，不表示空间边长。

每个 cell 缓存完整的候选稳定 ID 列表，RIS 只从该列表抽样，首表面、次反弹和独立训练均无全局候选混合或全局回退。新 cell 首次使用先完整筛选候选，再从 cell 内抽取；没有当前 RIS 的新 cell 先使用列表内均匀提议。构建中的并发查询不自旋等待，而使用同一完整筛选集合的程序化视图。哈希或 ID 池不足也使用完整 cell 视图，不截断列表，不随机从全局取灯再拒绝；这条保留支持的路径可能增加成本，由统计明确报告。首表面记录未通过逐位相机射线校验时，仍对新追踪的表面使用 cell 内估计，并保留相同覆盖域，不能进入旧的全局 NEE；关闭屏幕 DI 时也采用该 cell 内根估计。准备和专用资源预算失败会明确报错，独立关闭 ReGIR 时保留原全局模式。

`regirLightCullingEnabled` 控制整 cell 剔除；LOD 先按未抖动位置选择，再扩展 AABB 覆盖该层完整 jitter 范围与数值余量。单面发光面须整个体积都背向才剔除，双面材质跳过背向判断；聚光灯使用完整包围体与光锥。`regirBrightnessThreshold=1e-4` 是可调的线性入射光强度代理阈值，0 关闭弱光距离截断，启动脚本可用 `RTPT_REGIR_BRIGHTNESS_THRESHOLD` 覆盖。点光以最大绝对 RGB 强度、无纹理面光以面积乘最大绝对 RGB 辐亮度估计上界；发光纹理/光源方向配置没有可靠最大值时保留距离支持。距离取源/接收 AABB 的保守最近距离，不用中心距离。这是已接受的弱光近似，不是最终像素误差上限。

静态光源不重复构建描述和候选列表；光源增删、移动、朝向或强度变化时，只重建旧/新候选归属不同的 cell。稳定 ID 与当前目录位置分离，压缩重排不串灯；RIS 使用当前光源每帧刷新，归一化分母为本 cell 候选数量。120 帧未查询的 cell 回收并复用候选存储段。64 MiB 专用预算计入所有新增缓存、描述、映射和临时资源；默认 32 RIS 槽/每槽 8 候选。`regirStats` 报告实际字节、列表构建/复用、程序化视图、容量压力、回收与稳定 ID。测试代码已清理，历史验证结果见 [验证汇总](../../../build/regir-cell-validation/summary.json)，VeachAjar 开关对比见 [场景报告](../../../build/regir-veach-comparison/summary.json)。

## 固定 x2 GRIS 的 ReGIR 尾段采灯

[RTPTGRISReGIR 测试图](../../../scripts/RTPTGRISReGIR.py) 将已有 cell-only ReGIR 接入新版多跳 GRIS：x0 直接光和 x1 本地贡献独立累计，x2 及深处的 ReGIR 项进入共享 terminal picker，再参与空间/时间重采样。图中关闭屏幕 ReSTIR DI、SHaRC 查询和 RR，开启 ReGIR 次级与独立训练；`useNEE` 保持 true，以启用直接光入口。默认 `grisPGPrefixDepth=1` 只引导 D root 首段，0 关闭 GRIS guiding，x1 及更深方向仍为 BSDF。弱光距离截断设为 0。

新 `GrisReGIRPath` kind 使用现有方向/尾因子槽保存已含内层 RIS 补偿的静态尾段，与旧 `GrisReGIR` 的 UV/权重重建编码区分。x2 直接项不套普通灯/BSDF MIS，也不含 x2 continuation 比率；深尾继续保留 q2/reference 转换。被 ReGIR 覆盖的非 delta 命灯 emission 按已有规则去重，delta 及直接可见 emission 保留。

reference-tail 目前仅对 ReGIR-only、次级采灯开启、SHaRC 查询关闭的组合启用；混合屏幕 DI 等组合保留完整本地估计。`stageStats.grisReGIRPathReuseEnabled` 报告实际编译生效状态。持久结构不新增字段，历史按场景、运输参数及独立光照域规则失效，不依赖 PG reset generation。ReGIR 自身共享缓存仍单独占用显存。

`grisReGIRSelectiveHistory=true` 默认启用按光源分域的动态历史：静态几何、反射材质及环境下，点/聚光灯新增、停用、移动、改色或修改 spot 参数，只排除相关光源域的旧时间技术，未变化灯的历史继续参与。当前 fresh/空间技术覆盖全部当前光源，交叉评价/MIS 同步检查被评价终端的光源身份，保留旧源 `R/W/M`。范围要求 NRD、1 spp、时间复用开启、RR 关闭及 `brightnessThreshold=0`；PG 可同时开启。每像素记录仍为 128/108 B，另有 16 B/稳定光源 ID 的共享版本表（容量向上取二次幂，最少 16 项）。将该属性设为 false 可保留旧全局失效对照。几何/材质/环境及未覆盖变化继续拒绝历史；本阶段不重放变化灯自身的旧尾段。实现与验收范围见 [计划第 12–13 节](GRIS_REGIR_NEE_PLAN.md#12-按光源划分-gris-动态历史复用)。

该动态扩展完整重建通过；18 组/268 项精确检查、310 功能检查帧与持续 PG 联合测试通过。PG0 固定 10 seed、三臂各 1,024 移动帧的原始 D/S/RGB 对照完成 30,720 帧，旧/新策略各 9/9 通道满足预先锁定的 ±2% 均值等价门槛；40 帧关闭 ReGIR 回归的原始/NRD/记录字节与修改前完全一致。实际未变化灯旧尾段导入、元数据、版本、RNG 连续性、失败保留和范围限制见 [动态验证汇总](../../../build/gris-regir-dynamic-validation/summary.json)。该组结果不作性能或任意动态场景无偏性结论。

固定 x2 的 reference-domain GRIS（普通采灯及上述 ReGIR-only 模式）保留每条历史记录配套的 `F/W/M` 和表示比例 `R=areaPdf/sourceAreaPdf`。fresh 记录的 R 来自实际生成密度，重连赢家则保存新 owner 下配套的 R 与归一化权重。交叉评价使用物理 BSDF 和固定辅助前缀分布，不使用新版 guide 重算旧记录的 R。连续帧、尺寸、记录语义和真实运输/光照域检查继续有效，PG 数据身份不再参与这条路径的历史门控，无需新增逐像素字段或保存旧 PG 树。

此前仅放宽普通 publication 的验证：Release 构建通过；独立有理数枚举的 7 项用例、33,363 个状态和 56 项 indicator 检查通过。普通采灯及 ReGIR-only 的 temporal/joint 共 272 帧、4,068 项生命周期/有限值检查通过；其中 prefix 切换、Reset PG 和相机平移沿用旧失效预期。该历史验证仅检查可读标志，不代表本节持续更新实现或实际历史赢家的验收。记录见 [旧验证汇总](../../../build/gris-pg-history-validation/summary.json)。

光路图、MIS/PDF 契约、实施范围及验证结果见 [接入计划](GRIS_REGIR_NEE_PLAN.md)。构建、245,631 条严格重建路径、功能和独立 10 seed 均值确认通过，PG0 四模式与 PG1 joint 共 45/45 通道满足预定 ±2% / 95% 区间门槛。PG1 精确关闭回归和初轮 5 seed 均值对照的未通过结果仍分别保留，最终汇总不标为全部验收通过。本场景 640×360 完整图 GPU 均值为 off 4.556 ms、on 5.424 ms；ReGIR 缓存约 34.283 MiB，GRIS 持久记录净增 0 B。具体范围见 [最终汇总](../../../build/gris-regir-validation/summary.json)。本轮隔离验证保存在 `build/gris-regir-validation/`，不恢复已归档的旧测试构建。

## 首表面 ReSTIR DI 与 NRD 及后续 ReGIR 接入方案

[实施方案与参考代码](REGIR_RESTIR_DI_NRD_PLAN.md) 以当前 PG、SHaRC、NRD 版本为基线，按用户指定顺序先完成首表面 ReSTIR DI 与 NRD：全局候选 → 最终灯样本 → RayQuery 阴影 → 分别评价 D/S → 与原间接信号合成并送入 NRD，完整验收后再增加 ReGIR。首批保留当前 D/S 双续接，概率式根通道单路径单独评估。阶段 1 的结构拆分、阶段 2 的全局 Initial RIS 和阶段 3 的 Temporal/Spatial 已接入；ReGIR 留在阶段 5。

方案第 11 节列出 ReSTIR DI 的具体实现：已安装 RTXDI 1.3 的算法调用、RTPT 私有 bridge、Initial/Temporal/Spatial、buffer bank、运动和灯身份、最终 D/S 着色，以及每一步对应的本地和官方参考代码。

第 12 节补充 ReGIR 的完整实现参考：本地 SDK 的 Grid/Onion、建表与查询函数、体素目标及资源布局，NVIDIA 官方示例、原始论文与补充实现，并记录当前包装层空缺及 1.3 参数适配细节。ReGIR 仍在首批 ReSTIR DI 与 NRD 验收之后实施。

## 阶段 3：Temporal 与 Spatial

`RTPTDIReuse.cpp` 调度独立的 SDK 1.3 Temporal 和 Spatial ComputePass。四个 reservoir/完整 UV 侧车 bank 分别保存 Initial、Temporal、Spatial 和前帧 Temporal 结果；每个 Pass 只向独立区域写入，完成后设置 barrier。当前帧最终阴影与真实 D/S 读取最后启用阶段的结果；组合模式读取 Spatial，下一帧历史则独立从 Temporal 发布，空间混合结果不循环反馈。Temporal、Spatial 可分别关闭，两个都关闭恢复阶段 2。

历史保存实际同帧 Primary 和完整 jittered view-projection 矩阵，按 `previousPixel-currentPixel` 和线性深度差重投影，检查边界、深度、法线、材质、灯代次及记录标签。当前版本在几何、材质或灯光改变（包括移动）时保守清历史；普通相机运动允许复用，大幅 camera cut 与 frustum 变化清历史。PG 重训或 NRD 重置不代替这些 DI 判定。

重采样使用固定 RayTraced 校正，visibility shortcut 关闭。复用模式会对 Initial 与各级输出作规定的可见性零事件筛选，保留 M；最终仍重新测试当前阴影。因此额外可见性射线成本高于阶段 2，本轮不宣称加速。所有交叉评价使用真实当前/静态前帧材质及完整 float UV；仅在 SDK 函数内部用临时 token 访问侧车，持久 reservoir 恢复标准 24 B 格式。

新增属性 `restirDITemporalEnabled`、`restirDISpatialEnabled`，裸 RTPT 默认 false，正式主图/CMD 默认 true；对应环境开关为 `RTPT_RESTIR_DI_TEMPORAL_ENABLED`、`RTPT_RESTIR_DI_SPATIAL_ENABLED`。历史权重上限默认 20，空间邻居数 4、半径 16 像素，可由 `restirDIHistoryLength`、`restirDISpatialSamples`、`restirDISpatialRadius` 调节。`diStats.historyValid` 表示本帧可读旧历史，`historyAvailable` 表示帧末已发布下帧历史；`historyInputBank` 报告发布来源，组合模式为 1，`finalInputBank` 为 2。另报告实际 T/S 状态、历史失效与复用回退原因。

当前复用资源为 448 B/像素，加目录和 2 KiB 邻居偏移；两个复用开关都关时仍为阶段 2 的 120 B/像素。复用准备或预算失败保留 Initial；Initial 也不可用时保留旧根选灯，阶段 1 继续运行。详细协议与验证结果见 [阶段 3 验证说明](../../../build/rtpt-experiment-tests-backup-20261101/tests/rtpt_stage3/README.md)。

最终版本的 Release 构建、24 项 D3D12 GPU 测试、8 项 CPU 检查通过；关闭复用后 120 份数组与阶段 2 基线逐字节一致。三种复用模式各 6 场景、16 独立 seed 的 162 个均值通道，以及额外 16 个新 seed 的 9 个混合光源通道均通过预设统计区间。主图 213 帧的 441 项生命周期检查、720p 144 帧的 37 项检查、NRD 关闭直通及四模式 64 项精确零检查也通过。Initial、T-only、S-only 共 3,744 份数组与首版逐字节一致。

首版空间结果反馈历史时，混合光源的两个均值通道曾越界；原始失败、独立审计和结构对照均已保留。当前采用独立 Temporal 历史，完整重验及新种子检查通过。这些有限样本检查不证明所有动态条件下严格无偏，也不构成性能提升结论；早期长会话 Slang 编译器崩溃及分进程恢复的证据另有记录。

## 阶段 2：全局 Initial RIS 与最终 D/S 着色（2026-10-31）

新增 RTPT 私有 `DirectLighting/`、`ReSTIRDI/` 和 `RTPTDirectLighting.cpp`。Initial 调用本地 RTXDI 1.3 的 `RTXDI_SampleLightsForSurface()`，关闭 ReGIR、BRDF、环境及时间/空间候选；全局均匀目录覆盖全部发光三角形与启用的点光/聚光灯。目录不按近似功率或 active 三角形列表剔除零代理灯。最终着色从完整精度 UV、稳定灯身份与代次重建当前灯样本，乘一次 SDK 已归一化的逆 PDF，共用一次当前 RayQuery 阴影，分别评价真实材质的 D/S。

DI 接管首表面非 delta 的覆盖域：去掉该域的旧根 NEE 和首段命中发光面的 emission，同时继续原间接续接。环境、方向光及其他解析灯使用剩余域的正确选灯概率；主可见 emission、delta residual、深层 NEE 和独立 PG/SHaRC 训练保留原规则。合法空、黑色、遮挡或选中身份失效保留 DI 域，不根据结果补抽旧 NEE。只有准备或记录元数据失败才能恢复旧域。

裸 RTPT 的 `restirDIEnabled` 默认关闭，正式主图与 `RTPR_START.cmd` 默认开启；设置 `RTPT_RESTIR_DI_ENABLED=0` 可关闭。`restirDICandidateCount` 默认 8（1–128），`restirDIBudgetMB` 默认 512（16–2048）。目前仅 NRD 输入模式、1 spp、NEE 开启时生效，普通积分器保留旧路径。当前新增 120 B/像素（SDK reservoir 24、完整 UV/身份 sidecar 48、D/S 48），加灯目录与剩余解析灯索引，使用独立预算；准备失败保留阶段 1 并回退原选灯。`RTPT.diStats` 报告实际生效状态、代次、覆盖域、字节、步长与原因。

Release 构建、16 项 GPU 测试、183 项生命周期检查、720p 144 帧和 NRD 关闭直通检查通过。K=8 的 16 场景及 K=1/32 各 5 场景原始均值通过预设统计区间，关闭 DI 的 98 份源信号与封存基线逐字节一致；格式转换及后处理差异单独记录。协议、完整结果和限制见 [阶段 2 验证说明](../../../build/rtpt-experiment-tests-backup-20261101/tests/rtpt_stage2/README.md)。本阶段不宣称时间/空间复用或性能提升，共享 Material/BSDF、RTXDI、NRDPass、ModulateIllumination 未修改。

## 阶段 1：主表面与最终信号组装（2026-10-31）

新增 RTPT 私有 `PrimarySurface/`、`Signal/` 与 `RTPTStages.cpp`。主表面由 ComputePass + RayQuery 生成，固定复用当前帧主命中；普通多 spp 仅复用 `s=0`，训练保持独立。主着色仍从该命中重建当前材质，并在原浮点上下文计算 NRD guides。Final Signal Resolve 收集材质化 direct/indirect D/S、emission、residual 和首段距离，合成后只去材质化一次，继续交给原 NRDPass 打包。原选灯、D/S 双续接、PG/SHaRC 资格和随机流保留。

资源按反射分配，当前 Primary/Signal 分别为 112/144 B/像素；固定 1 GiB 上限仅约束这两类新增中间资源。准备失败完整回退原积分器，单像素元数据不匹配回退真实求交；没有增加主命中关闭开关。`RTPT.stageStats` 提供实际 active、字节数、步长及回退原因。

Release 构建与 D3D12 debug layer 下 10 项 GPU 测试通过。默认编译的 88 份全部输出一致；完整组合的 499 份 RTPT 源信号一致，保留 6 份最终累积/ToneMapper 的严格差异，最大约 `9.09e-7`。后处理另按预先固定 `0.001` 绝对误差界验收，RTPT 源信号不放宽。资源准备故障注入后 88 份输出与原版一致，源码已按 SHA 恢复并重建。最终长窗口训练对照、同版本 A/A 非确定性证据及全部结果见 [阶段 1 验证说明](../../../build/rtpt-experiment-tests-backup-20261101/tests/rtpt_stage1/README.md)。本轮不宣称性能提升。

1280×720 正式主图全模块开启运行 144 帧、15 项检查通过，新增中间资源 225 MiB。核心结构验证通过，但完整长训练窗口的逐字节一致性没有全部通过：首次 `unlimited/128` 有 3 份源信号微差，最高约 `1.53e-5`；相同最终 DLL 的复跑与首次结果也不一致，复跑的 22 份源信号则与旧基线一致。首次失败保留，未用复跑覆盖。单独诊断的 NRD 后处理超出 `0.001` 界，相关比较仍标记失败；不能把它与完整套件中 `9.09e-7` 的结果混用，也没有证明两次训练模型缓冲字节同一或确定具体原因。

## 当前修改范围与 Material 恢复状态

按用户要求，Falcor `Rendering/Materials` 中此前 PG 优化新增的接口、实现和 include 已恢复到优化前版本，新增 `MaterialInstanceOptional.slangh` 已移除。RTPT 续接改回通用 `sample`、`evalPdf`、`eval` 调用。NRD 首跳 diffuse/specular 的 PG 区域查询复用也已撤回，恢复各分量独立创建 sampling context；各分量 active-lobe 资格、独立采样和 NEE 规则保留。下文“主采样重复工作复用”第 2、3、4 项只属于历史实验，当前均已撤回；相关性能与查询计数不代表本次恢复后的版本。叶子 PDF 复用、发布优化和诊断开关仍保留。

此前 Material 恢复时，用户同意恢复 `Source/Falcor/CMakeLists.txt` 和两份 `RTPTPGMaterialTests`，当时保留了原 PDF characterization；恢复记录位于 `build/pg-material-restore-01/`。随后按用户要求，四份 `RTPTPGTests` / `RTPTPGMaterialTests` C++、Slang 文件及对应的四条 FalcorTest CMake 注册均已删除，运行目录中的对应测试着色器及旧查询实验残留一并清理；删除验证记录位于 `build/pg-tests-remove-01/`。

用户随后要求删除 `tests/RTPT` 中的 `PGBenchmark.py`、`PGCompare.py`、`PGProfile.py`、`PGValidate.py` 和 `README.md`，这组文件及空目录均已删除。下文的测试数量、测量工作负载和运行结果只记录历史，不代表这些脚本仍存在。日常主入口仍为 `RTPR_START.cmd`，它不依赖上述测试文件；本次删除记录位于 `build/pg-python-tests-remove-01/`。

NRD 查询复用的撤回仅修改 RTPT 内的 `RTPTNRD.slang` 和本说明，并同步正常运行着色器；验证记录位于 `build/pg-nrd-query-revert-01/`。QUERY/FALLBACK 诊断重新统计各分量实际发起的查询，不能直接与历史共享查询窗口的绝对计数比较。

项目根目录 `AGENTS.md` 已加入跨对话的修改范围限制：允许修改 RTPT 及其专用构建、测试、启动和集成依赖；Material/BSDF 等通用共享实现不得擅自修改，确需修改时须先列明文件、原因与影响并取得用户同意。不能仅因 RTPT 依赖某段共享代码，就将它视为可直接修改的专用依赖。RayQuery、统一主入口与独立模块开关要求继续有效；SHaRC 终止策略和三项暂缓问题保持原状。

## PG 首版：粗区域和按需方向树

统一入口 `RTPR_START.cmd` 现在提供 `RTPT_PG_ENABLED=1/0`，与 SHaRC、NRD、FrameAccumulation、ToneMapper 的开关独立。主入口仍加载 VeachAjar，默认显示 `ToneMapper.dst`，保留最后一层 128 帧 Stop 累积。窗口中的 **RTPT → PG → Enabled** 同时控制 PG 采样和训练；**Use guiding** 只停止采样、继续训练；**Freeze training** 保留模型并停止训练；**Reset PG** 清模型并重新训练。参数不会因 Enabled 切换而丢失。

PG 复用 SHaRC 的世界坐标量化、以相机距离选择的二倍 LOD 和法线八象限分组，默认使用 `SHaRC LOD+2`（四倍边长）的粗区域。区域索引和方向节点池独立，不把 PG 数据塞进 SHaRC 的辐射缓存或绑定到可回收的 SHaRC 槽位。多个细体素可汇集到同一 PG 区域；方向分布使用世界方向全球面等面积参数化。

全部追踪仍为 **ComputePass + SceneRayQuery/TraceRayInline**。没有迁移到 DXR RayGeneration/ClosestHit/Miss 管线，也不依赖原 MyPT PG 的 HitObject/SER 实现。

每个新区域从一个方向节点（四个终端方向格）起步。已发布 Read 模型供主渲染采样，Build 独立累计实际方向格的质量、平方和和观测数。默认每 16 个训练帧同步检查发布，没有观测的区域保持原模型；合法零质量观测会发布零分布，两者分开处理。每格至少 32 次真实观测且满足质量、深度及预算限制后才允许细分，默认每区域最多 85 个节点、方向深度 8。新区域由有界请求表发现，下一批才开始真实训练，因此启动后需要至少两个检查批次才能出现有效引导。

训练复用 BSDF-only 稀疏更新路径，记录完整路径并倒序恢复入射辐射。原始 emission、到达边的 MIS、局部 NEE、运输/RR 补偿与实际方向 PDF 分开记录。只记录实际发射的方向；当前方向通过 RR 才产生观测时，训练分母还包含其存活概率。被 SHaRC 提前终止的主渲染后缀不作为真实训练标签，SHaRC 的已解调缓存值不代替入射辐射。

SHaRC 和 PG 的实际更新 tile、反弹数相同时共享一次稀疏追踪；不同则分别调度，不静默覆盖任一模块参数。PG 单独开启时仍可训练，SHaRC 的写入和查询确实停止。SHaRC 插入失败不丢弃 PG 的有效路径。

主渲染默认 `pgGuideFraction=0.5`，运输、NEE、环境和发光体 MIS 使用同一个真实混合 PDF；NRD 首跳 diffuse/specular 分别使用对应分量的密度，delta 保持原 BSDF。空/零质量模型走原 BSDF，关闭 PG 的路径不额外消耗混合选择随机数。

**组合限制：PG 选中的 guide 边继续真实追踪，BSDF 选中的边沿用原 SHaRC 终止筛选。** 当前 SHaRC 的足迹判定基于 BSDF 粗糙度，尚未扩展到 PG 的角分布；不能把 guide 方向伪装成 diffuse 样本来绕过判定。因此同时开启两者可能降低缓存命中并增加射线数，必须比较包含训练、发布的同时间画质，不能套用原 PG 的历史加速比。

默认 `pgTreeBudgetMB=64` 包含 Read/Build 节点、48 B/Build 节点的训练统计、区域索引、请求表及有界传输/对齐预留。方向 Read/Build 节点各 20 B，合计每对节点 88 B。固定池按容量占用显存，池内按需分配区域与方向节点；达到预算不再增长。`pgRecordBudgetMB=128` 独立管理完整路径记录，8 跳时每槽约 832 B；预算不足增大实际训练 tile，而不截断单条路径。现有 SHaRC、NRD 和图像资源不计入这两个 PG 预算。

`RTPT.pgStats` 提供区域数、有效模型、节点数、训练帧、发布次数、实际/预留字节、实际 tile、代次、发布耗时和诊断计数。诊断下标：0 请求溢出、1 记录溢出、2 无效数据、3 累计溢出、4 查询、5 guide 分支、6 基础 BSDF 回退、7 guide 边跳过 SHaRC、8 实际训练顶点、9 零权重观测、10 新区域请求、11 完整训练路径、12 无效 PDF。当前普通发布、纯 PG Enabled/采样参数变化及单独 Reset PG 都不清空 GRIS/NRD/最终累积；场景、实际运输设置和显式全渲染重置独立处理。最终累积达到 128 帧后，上游训练继续；Freeze 后可手动 Reset FrameAccumulation 观察固定模型。

高频活动计数 4–11 由 `pgDetailedDiagnostics` 控制，默认关闭；`RTPR_START.cmd` 的 `RTPT_PG_DIAGNOSTICS_ENABLED=1/0` 和窗口 **PG → Detailed diagnostics enabled** 可独立切换。关闭时保留已有活动计数，后续不再增加，不能把这些值解释为当前没有查询或训练。错误计数 0–3、12 始终启用，训练质量、平方和、真实观测数和区域请求写入不受此开关影响。纯诊断切换保留模型、NRD 历史和最终累积。

发布计时以 `publishCalls` 为分母，区别于实际更新 Read 的 `publications`。`totalPublishMs`/`maxPublishMs`/`lastPublishMs` 及 `totalDrainMs`、`totalReadbackMs`、`totalCpuRebuildMs`、`totalUploadMs` 记录 CPU 墙钟时间；传输阶段包含已有 GPU 等待，不额外引入同步。对应 `total*Bytes` 和 `total*Waits` 记录真实传输量和显式等待次数。Falcor Profiler 中另有 `SparseTrace`、`PGPrepare`、`PGTrain`、`SHARCResolve`、`MainRender`、`PGPublishCPU` 分项；发布范围的 GPU 时间包含跨提交的空闲间隔，不能当成纯计算核耗时。性能对照脚本在独立区间采集 profile，避免计时器开销混入吞吐测量。

首版暂缓的三项中，本次已经实现有界的跨 LOD 旧区域保留；**LOD 切换迟滞、按模型成熟度选择回退模型仍暂缓**。相机移动以及同一场景内材质、光照、几何变化不再全量清空 PG，旧 proposal 用后续独立观测适应；真实运输变化仍独立使 GRIS 辐射历史失效。空/零质量分布沿用合法 BSDF 路径，不做成熟度评分、父模型选择或成熟度驱动的引导比例。

原 FalcorTest `RTPTPG*` 数值测试和 `tests/RTPT` Python 验证脚本均已按用户要求删除，日常启动使用 `RTPR_START.cmd`。以下是首版的历史记录：2026-10-17 在 RTX 5070 / D3D12 上，Release 构建、四项 GPU 数值回归和统一主图 86 项生命周期检查通过。160×90、两组种子、每组约 2 秒且包含训练/发布的短时对照没有显示收益：PG 开启后的归一化误差约高 1.6%–1.7%，完成帧数约为关闭时的 62%–64%。这只是低分辨率 smoke，参考图本身也有噪声，不是生产分辨率或普遍性能结论；本轮交付是可独立开关的功能首版。

## 发布性能优化与同时间对照（2026-10-17）

本轮保留每 16 帧的训练窗口、非零模型细分、采样 RNG、PDF/MIS 和 SHaRC 查询条件。发布改用固定 **2 MiB Readback + 4 MiB Upload**，按容量打包传输，满批等待完成后才复用 staging；第一批读回同时完成旧工作排空，不再单独等待一次。大模型按同样的字节顺序分批，staging 不随模型增长。6 MiB staging 加分配余量仍在原 8 MiB 预留内，默认 64 MiB 模型预算及方向节点容量不变。

CPU 复用工作数组、已知键集合和哈希表；区域集合稳定时跳过整表重建与上传。Read 集合变化仍按原区域 ID 顺序插入，描述符始终更新根偏移。合法零质量窗口直接复制当前 Build 拓扑为零 Read，并保持所有已有分支，省去不会产生细分的临时树构建；无观测及异常窗口保持既有语义。`lastZeroFastPathRegions`/`totalZeroFastPathRegions` 可验证这条路径的覆盖。

对照使用实际完整主图、VeachAjar、640×360、种子 11/29/47，每组目标 4 秒；冷启动和预训练 256 帧后的稳态分开测量。所有 Pass 先完整预热，末尾 GPU 排空和纹理读回计入总时间。两版共用同一个有限 4096-SPP 纯 PT 参考，另测固定模型的诊断开关。报告保留每个种子及版本指纹：

- 冷启动发布平均 **19.16 → 7.51 ms**；稳态 **22.77 → 5.48 ms**。CPU 重建分别 **13.34 → 3.35 ms**、**17.01 → 1.74 ms**。这些按真实发布调用数加权，不能当作每帧 GPU 时间。
- 每次发布显式等待从约 **11 次降到 2.5 次**；不同活跃大小及 map 是否变化会影响批次数。新的 Readback 阶段包含原 Drain 的等待，不能把 Drain=0 解释成省掉了之前的 GPU 工作。
- PG 开启组前后绝对吞吐提高 **26%–79%**。PG 关闭对照组也有吞吐变化，因此另比较 `(PG-on/PG-off)_after / (PG-on/PG-off)_before`：冷启动三个种子的中位数约 **1.34×**，稳态约 **1.42×**；稳态单种子范围 **1.16×–1.61×**，不作为跨场景加速结论。
- 同时间原始平均 HDR 的 NMSE 相对优化前下降约 **14%–32%**；NRD 后最终平均 HDR 的误差变化小于 **0.2%**。总 NMSE 混有有限参考噪声、SHaRC 近似及 NRD 滤波，不能当作纯采样方差。
- 固定模型、同种子下，详细诊断关闭后的吞吐仅约提高 **0.5%**，MainRender GPU 时间 **1.1595 → 1.1591 ms**，近乎不变。开关确实移除了高频计数，但本次主要收益来自发布；不宣称诊断原子是剩余主瓶颈。
- **优化后 PG 稳态吞吐仍只有关闭时约 62%**，原始 HDR 误差也尚未优于关闭 PG。固定模型开关引导时 MainRender GPU 时间约 **0.58 → 1.16 ms**。后续应继续隔离重复区域/PDF 查询、材质重评估、方向分歧及 SHaRC 终止机会变化，本轮没有修改这些运输条件或三项暂缓功能。

原始结果位于 `build/pg-perf-before-01/report.json`、`build/pg-perf-after-01/report.json`，配对汇总为 `build/pg-perf-comparison.json`；诊断隔离汇总为 `build/pg-perf-diagnostic-comparison.json`。`build/pg-perf-quality-comparison.png` 展示稳态种子 29 的原始/最终 HDR；预览统一使用 Reinhard+sRGB，误差在线性 HDR 中计算。对应的复现与离线比较脚本、使用说明现已删除，旧报告保留供参考。

该次优化版 Release 构建、D3D12 debug layer 下 **5 项 GPU 数值测试与 106 项生命周期检查（216 帧）**通过；覆盖诊断开关/错误保留、训练和请求等价、模块恢复、预算重建、Stop 累积保持，以及 65536 区域配置的多批传输。大表验证实际读回 3 批、上传 3 批，未发生无效样本或记录/累计溢出，预留仍在 64 MiB 内。日志分别为 `build/pg-perf-gpu-tests.xml` 和 `build/pg-perf-validation-02/report.json`。当时未实现 LOD 迟滞、跨 LOD 区域保留或未成熟模型回退；当前跨 LOD 保留行为见本文开头的持续更新说明。

## PG 剩余成本定位（2026-10-17）

在同一完整主图、VeachAjar、640×360 上，原优化后三个种子的稳态 GPU 均值为：`PGPrepare` **0.0031 ms/帧**，`PGTrain` **0.0404 ms/帧**，共享的 `SparseTrace` **0.0819 → 0.0858 ms/帧**，`MainRender` **0.5698 → 1.1819 ms/帧**，`SHARCResolve` **0.0441 → 0.0429 ms/帧**。SparseTrace 和 Resolve 本来就属于 SHaRC，不能把完整范围都计为 PG 增量。主渲染增加约 **0.6121 ms/帧**，明显大于准备和训练核的直接成本。

同一数据的 CPU 发布墙钟摊销约 **0.339–0.345 ms/渲染帧**，其中读回 **0.205–0.206 ms**、CPU 重建 **0.107–0.111 ms**、上传阶段 **0.027–0.030 ms**。读回包含等待已有 GPU 工作；Profiler 中约 **0.1551 ms/帧** 的发布 GPU 范围还包含 CPU 重建造成的队列空隙，不能与 CPU 发布时间相加，也不能称为纯拷贝或 kernel 成本。吞吐计时与 profile 是不同区间，不把这些均值解释成严格闭合的百分比饼图。

冻结 PG、SHaRC 更新后，两个 BSDF-only 预训练的对照都没有发布调用。仅开启 guiding 时，总墙钟 **1.2036 → 1.7922 ms/帧**，MainRender GPU **0.5786 → 1.1591 ms/帧**；冻结后仍有约 **0.5805 ms** 主渲染增量。最后一帧 radiance ray 数增加 **12.3%**、SHaRC 终止次数减少 **12.9%**，说明引导也改变实际追踪工作量。这些 ray 计数不含 NEE shadow rays；该轮两个独立运行使用相同预训练步骤及一致模型统计，尚未证明缓存和模型逐字节相同。该轮尚不能分别给查树、方向 PDF、BSDF 重评估、额外求交及寄存器压力定价；后续同进程和管理员硬件采集见下节。

新增九组 `off / train-only / on` 对照进一步确认：只训练时 MainRender GPU **0.5574–0.5748 ms**，完整引导时 **1.1569–1.2014 ms**，GPU 训练核 **0.0402–0.0433 ms**。但本轮 CPU 发布时间和调度有明显波动，只训练总墙钟 **1.5269–2.2714 ms/帧**，完整开启 **2.1908–2.8254 ms/帧**，不能用一个平均数宣称稳定的训练占比。每个种子的原始数值保存在 `build/pg-cost-training-01/report.json`；结合前一轮稳态与冻结对照的分项汇总为 `build/pg-cost-breakdown.json`。

Nsight Graphics 2026.3.1 的启动问题已定位：显式 `--platform "Windows (x86_64)"` 被 Qt 当作 QPA 插件名，省略这个参数后成功加载 `qwindows.dll` 并连接 Mogwai。此前 GPU Trace 的 **GPU Performance Counters unavailable** 错误随后通过实际 Windows 管理员令牌启动采集解决，已获得两组有效硬件 trace。另一个 Aftermath 弹窗来自 Windows 保留 TCP 端口 50101–50200 覆盖其通信范围 50152–50162，提示仅禁用该实例的 Monitor 通信。未修改系统端口或全局驱动计数器权限；当时的 `PGProfile.py` 工作负载和使用说明现已删除，已采集的 trace 与报告仍为历史证据。

## MainRender 根因采集（2026-10-17）

本轮只增加永久测量工作负载的 `frozen-abba` 模式和记录分析结果，没有优化或替换采样算法。一次 BSDF-only 预训练 256 帧后，在同一进程、同一渲染图和同一组冻结 PG/SHaRC 资源上依次测 `off / on / on / off`，每段 128 条 GPU profile 记录，起始采样相位一致。MainRender GPU 平均 **0.589668 → 1.180648 ms/帧（2.0022×，增加 0.590980 ms）**；两次 off 漂移 **−0.236%**，两次 on 漂移 **+0.539%**。模型代次、资源统计、发布调用数不变，同模式末帧统计文件逐字节相同。原始记录位于 `build/pg-profile-abba-01/report.json`。

管理员 GPU Trace 使用同一完整主图、VeachAjar、640×360，先后采集 200 ms 和 50 ms 窗口，均包含 MainRender marker、硬件指标和实时 shader PC 样本。第二组完整帧的 MainRender 为 **0.7233 → 1.4614 ms**，总帧 **1.4770 → 2.2032 ms**，NRD **0.6794 → 0.6683 ms**，其余后处理基本不变。Nsight 采集有开销，绝对时间不能代替上述普通运行；边界孤立 marker 与完整父帧分开统计。原始 trace 和 BASE TSV 位于 `build/pg-nsight-admin-pair-01/`、`build/pg-nsight-admin-pair-02/`，第二组汇总为 `timing-summary.json`。

硬件证据指向**动态指令获取和指令缓存压力增加**。on/off Main shader hash 相同，均为 **128 registers、16 warps、5888 B shared memory、8×8×1 CTA**，没有因运行时开关重新编译成另一份寄存器配置。第一组 MainRender 加权指令缓存命中率 **60.67% → 50.58%**，每 Main marker 的 instruction-cache 请求量约 **2.21×**、miss 量约 **2.77×**；这里只使用导出值的比值，不宣称未核实的绝对计数单位。第二组 Main 的 `NOINST` 样本占比 **36.17% → 49.35%**，独立重复了等待指令增加的趋势。活动 warp 和寄存器分配比例近乎不变，DRAM/RT-core 吞吐百分比未接近饱和；不能把吞吐百分比降低解释为执行工作减少，也不能据此声称没有任何 spill。详情为第一组 `hardware-comparison.json`。

Nsight UI 选定同一 Main shader 后导出全部 HLSL 行统计。严格只累加互斥的 `Samples`，on/off 分别 **6,885,718 / 4,996,243**，精确等于各自 pipeline 的 Main stall 计数总和。**下面是 Main 内的 PC 样本份额，不是函数耗时、调用次数、可节省比例或总增量的因果分摊。** `Total Samples` 含子调用，不能和子函数相加。优化后的源码映射也有误差：off 的 PG root-mass 行仍有样本归属，不能把它解读为关闭后仍真实查树。

- 区域查询和 Grid 源码区域：on **7.07%**；包括距离 LOD/键生成、map probe、region/root 检查与依赖载入。定位 `RTPTPG.slang:71–104`、`RTPTGrid.slang:4–35`。
- 方向树采样与正向方向映射：on **4.15%**；方向 PDF 遍历与 quadrant：**4.19%**；共享反向方向映射：**2.98%**；共享 child 和诊断门控另列。严格 PG 源码类别合计 **19.17%**。树采样后紧接 `rtptContinuationPdf()`，会再次做方向映射和 PDF 遍历，是保持当前数学语义的复用候选。不能把 `atan2` 行的等待指令样本称为 `atan2` 算术本身耗时。
- BSDF 及单列的 GGX/Fresnel 等共享数学类别：**14.86% → 21.66%**。其中互斥的 eval 源码范围 **0.82% → 2.54%**、PDF **0.97% → 2.51%**、构造 **1.74% → 2.59%**、sample **5.03% → 4.93%**。sample 份额近乎不变不代表绝对成本不变。另有包含 helper 的上下文估算，和这些互斥值不能相加。
- RayQuery 源码类别：**20.73% → 13.34%**，其中 visibility **2.93% → 3.50%**。Main 整体约翻倍，份额下降不能说明求交变便宜。实际射线数量另做调用计数，见下段。

重复工作有源码和编译产物依据：有效 guide 的 BSDF 分支先 `mi.sample()`，再通过 `rtptContinuationPdf()` 调 `mi.evalPdf()`；guide 分支要分别求混合 PDF 和 `mi.eval()`。`StandardMaterialInstance` 的这些入口各自构造 `StandardBSDF`。离线 DXIL 中留下 36 个非空构造 inline 上下文，分别属于 sample 11、eval 10、evalPdf 15；这是**静态展开位置**，各处只保留部分操作，不能当作每帧构造次数。后续复用必须验证 Falcor selected-lobe estimator、完整 marginal PDF、delta 和 RNG 语义，不能直接用 `sample.pdf` 代替所有重新求值。分析和实际函数行范围位于第二组 `on-source-breakdown.json`、`off-source-breakdown.json`、`source-comparison.json`，静态证据为第一组 `main-dxil-summary.json`。

**阴影射线是此前遗漏的明显工作量增项。** 在实际 `traceVisibilityRay()` 前增加局部整数调用计数，临时借用调试输出的 W 通道，重新执行相同 ABBA；稀疏训练计数与 Main 分开，不增加射线或消耗随机数。四段末帧的原 R/T/Q 三通道与普通 ABBA **整张逐元素相同**。off/on 末帧分别为：radiance **847,415 → 952,618（+12.41%）**，shadow **83,322 → 178,139（+113.80%）**，合计 **930,737 → 1,130,757（+21.49%）**。主射线固定 230,400，二级 radiance 增加 **17.05%**。这些是可复现的**末帧计数**，不是整个 128 帧区间的总数，也不能按数量比例换算成求交毫秒。源码和运行时 shader 共 8 份文件在采集后逐字节恢复，临时补丁、原文件备份、验证及恢复 SHA256 保留于 `build/pg-shadow-count-01/`；该目录的正式结果为 `shadow-analysis.json`，最初未加载插桩的一轮明确保留为无效计数尝试，不用于结论。

路径增长的重要机制在 `RTPTSharc.slang:128–133`：**当前到达边由 guide 选出时，跳过这一次 SHaRC 终止**，之后 BSDF 选出的边仍可查询；这不是整条路径永久禁用缓存。ABBA 末帧 attempted queries **407,443 → 353,802**，成功终止 **324,710 → 282,562**，进入查询后的成功率 **79.69% → 79.86%**，所以不能称缓存内容的命中质量变差。guide 拒绝发生在 footprint 和真正查表之前，拒绝计数不等于本来能成功命中的数量。PG 也改变方向、混合权重、RR 与随机流；这些机制分别造成多少净增射线尚不能从汇总分开，但实际更多后续路径、NEE/BSDF 工作及 shadow calls 已经确认。

后续优化优先验证**保持运输语义的重复工作复用**：采样返回与实际生成方向一致的 PG 密度，减少紧邻的反向映射/重走树；复用同顶点 BSDF 构造及可证明等价的 PDF 中间量；再检查 map/region/root/node 的依赖读取和布局。指令缓存、PG 与 BSDF 代码共同造成的 stall 不能拆成互斥因果份额，不能直接宣称某个改动能省去 19% 或 22%。改变 guide 边 SHaRC 终止条件需要另行设计和验证其角分布足迹，本轮没有修改。RayQuery 架构、统一入口和模块独立开关均保留；LOD 迟滞、未成熟模型回退仍暂缓，跨 LOD 旧区域现已按有限容量保留。

## 主采样重复工作复用与缓存复核（2026-10-17）

本轮按四个阶段分别构建、GPU 数值回归、冻结模型 ABBA 和同时间画质对照，阶段源码与运行时文件保存在 `build/pg-sampling-opt-01/step*-source/`，对应 SHA256 manifest、日志及报告一并保留：

1. 方向采样累计叶子 PDF，安全内点直接复用；靠近叶子边界、方向修正及异常树路径返回 `-1`，由调用方按实际方向重求 PDF。四边使用全局 UV 的 `2^-18` 保护区。不能把冷路径求值移回 sampler 内部：本次实测旧编译器的内联浮点重结合会在边界取到相邻叶子的不同密度。正式回归另用独立 kernel 读取已存 float32 方向，验证 PDF，避免同 kernel 的代数简化掩盖问题。
2. NRD 首跳 diffuse/specular 各自保持原 active-lobe 资格，共享位置和朝向面法线对应的一次 PG 区域查询。两者仍独立抽样，不共享方向或随机数。QUERY/FALLBACK 诊断改为实际物理查询次数，不能再按 component 数比较。
3. PG 选中 BSDF 分支时，Standard 材质将采样和实际世界方向的 marginal PDF 放在同一构造实例中计算。原始 `sample.pdf`、selected-lobe weight、lobe、方向及 RNG 保留；额外 PDF 独立输出，不能直接把 local 采样 PDF 当成所有材质的世界方向 PDF。窄 GGX、掠射和变换基底的压力测试证实两者并非始终相同。
4. PG 选中 guide 分支时，Standard 材质的确定性 eval/PDF 共享方向变换、半球检查和 BSDF 构造。其他材质通过显式无副作用接口返回 unsupported，保留 PDF→混合 PDF 验证→eval 的原顺序；不提前消耗随机数。`MaterialInstanceOptional.slangh` 提供各非 Standard 类型的直接声明，兼容项目旧版 Slang 的泛型继承限制。

第 0/1/2/3/4 阶段的 PG-on MainRender GPU 均值分别约为 **1.153 / 1.138 / 1.136 / 1.142 / 1.120 ms**，最终第二轮复测为 **1.131 ms**。第 2、3 项的单次变化很小，第 3 项未显示独立加速；不能把四项都表述为稳定收益。两轮最终版相对基线约减少 **1.9%–2.9%**，按同轮 PG-off 控制归一后约 **1.7%–2.0%**；单轮内部漂移最高约 1.7%，不是解决原有约 40% 总吞吐差距的证据。同时间吞吐和线性 HDR NMSE 另见各阶段 `*-benchmark/report.json`，不能用 PC 采样份额换算节省时间。

完整同时间对照已完成冷启动/稳态、种子 11/29/47 共 12 组，与基线复用同一个有限 4096-SPP 参考。PG-on 的原始 HDR 平均 NMSE 相对基线分别下降约 **5.3%–13.1% / 4.3%–12.4%**，NRD 后最终 HDR 变化小于 **0.061%**。但 PG-off 控制组的吞吐也有明显波动，稳态按 on/off 控制归一后的吞吐比为 **0.901 / 1.201 / 0.976**，故本轮**不能宣称总吞吐有稳定提升或约 40% 的差距已经解决**。这些 NMSE 含有限参考噪声和 SHaRC/NRD 近似，不是纯采样方差。配对原始汇总为 `build/pg-sampling-opt-01/final-comparison.json`，种子 29 的固定显示映射图为 `quality-comparison.png`。

缓存复核区分了三种不同含义：

- **SHaRC 终止覆盖**：同进程冻结模型 ABBA 的末帧，off/on 实际查询 **407443→353802**，终止 **324710→282562**；通过前置门槛后的有效终止率 **79.69%→79.86%**。新增临时门控计数测得 on 有 **141143** 次因 guide 到达边被跳过；短 segment/specular footprint 拒绝合计 **7003→5915**。查询失败（含 hash miss、样本不足等）反而 **82733→71240**。因此允许使用缓存的机会减少，不能描述成 SHaRC 内容命中质量变差，也不能把 guide skip 数当成原本必定能命中的次数。
- **PG 区域查询**：当前冻结模型末帧 **667402** 次物理查询中，**300770（45.07%）** 返回有效正模型，**183831（27.54%）** 为 observed-zero，**182801（27.39%）** 在 Read map 中缺失。平均探测 **1.087** 槽，最大 **7**；没有严重碰撞的证据。这些查询可能包含不合格 component，validated guide 也不等于实际发射的 guide 边。`ObservedZero` 是有真实观测但当前窗口质量全零；无观测窗口保留旧模型，不应混为一谈。
- **硬件缓存**：优化前两组 Nsight 都显示 GCC instruction hit 约 **60%→50%**，每次 Main 的指令 miss 指标约增至 **2.8 倍**，NOINST 样本份额约 **36.2%→49.4%**。总 L1/L2 命中率提高，L1 global-load 只下降约 **1.4 个百分点**，DRAM 未显示饱和。这支持取指压力方向，仍不能排除串行树读取延迟，也不能把硬件指标分摊到某个 PG/SHaRC buffer。GCC 对应 GPC L1.5 指令/常量缓存，不是 SM L0 的直接指标；这些旧版采集不代表最终优化版的新硬件计数。

缓存原始调查位于 `cache-gates/analysis.json`、`pg-cache-probes/analysis.json` 和 `cache-review.json`，均在 `build/pg-sampling-opt-01/` 下。临时插桩只统计实际执行结果，没有增加求交、修改缓存终止或消耗 RNG；原 R/T/Q 纹理逐元素一致，两组重复计数一致。插桩改变编译上下文后 RGB 存在小幅舍入差异，因此不宣称整张图逐位一致，也不将插桩耗时用于性能结论。所有临时 shader 与 Python harness 已按 SHA256 恢复。

最终 GPU 回归覆盖 12 项，包括 PDF 边界/异常树、显存存储方向的独立求值、159 组材质配置、原始 sample/RNG、combined eval/PDF、随机材质回退与 12 种类型的接口一致性。MERLMix 原模块已有悬空 `ExtraBSDFProperties` getter，类型一致性测试使用明确标注的测试兼容类型；没有修改其算法，也不宣称修复了该模块独立导入。

Release 构建与 D3D12 的 12 项 GPU 测试通过；D3D12 debug layer 下统一主图 **106 项生命周期检查、216 帧**通过，覆盖关闭/重新开启各模块、NRD/最终累积历史、Freeze、预算重建和 128 帧 Stop 后继续训练。报告为 `build/pg-sampling-opt-01/final-validation/report.json`。

## PG 资格提前拒绝与 ObservedZero 快返实验（2026-10-17，未采用）

两项均完成独立实现、Release 构建、数值回归、三轮 ABBA 与同时间画质对照，但没有达到原计划“收益可重复后再保留”的验收条件。因此已恢复本轮开始时的渲染实现；当前版本仍是上一节四项采样复用完成后的版本，不包含本节两项性能实验。实验源码、CMake、测试和二进制仍完整保存在 `build/pg-query-opt-01/{baseline,eligibility,zero}-source/`，对应 manifest/SHA、报告和插桩补丁可复核。恢复清单为 `production-restoration.json`。

**计时结果。** 640×360、每阶段三轮同进程 off/on/on/off，PG-on MainRender 均值依次为 **1.125230 / 1.120483 / 1.113397 ms**；PG-off 控制为 **0.580357 / 0.574043 / 0.571535 ms**。资格实验绝对减少 0.42%，但对照归一化后时间增加约 0.67%；再加 Zero 快返绝对减少 0.63%，对照归一化仅减少约 0.20%。两项合计绝对减少约 1.05%，对照归一化反而增加约 0.47%，没有超过实测漂移的独立收益。不能把“减少工作”或绝对 1% 的变化当成可重复加速，更没有解决 PG 的整体吞吐差距。

每轮 ABBA 内四臂共用该轮冻结 PG/SHaRC 资源，各轮按相同 BSDF-only 256 帧协议重新训练。九轮 PG 元数据一致：11190 regions、2682 Ready、8109 Zero、14323 Read nodes、14767 Build nodes；跨轮没有模型 buffer 的字节校验，不能描述成跨版本导入完全相同模型。数值与模型边界见 `model-metadata-audit.json`。

PG-off 也可能受资格前置的 enabled guard 及编译上下文影响，不能视为严格未受改动的负对照。上述归一化仅辅助检查敏感度，不能据此证明回退，也不能把 off 的全部变化归为机器漂移。拒绝实验的依据仍是原始 Main 变化没有超过重复测量漂移，以及完整管线未建立可重复净收益。

**资格实验。** `RTPTSampling.slang` 实验使用显式控制流，在 PG 关闭、guide fraction 非正或 active BSDF 不 eligible 时返回 BSDF context。Falcor 全局禁用了逻辑短路，原来的 `eligible && GetGuide()` 能触发不合格 component 的查询副作用；本轮未改全局编译选项。冻结末帧临时分类从 **667402** 次物理调用降至 **539694**，不合格调用 **127708→0（-19.14%）**，probe 总量减少约 21.0%。被剔除调用中约 88.7% 原本就未找到区域。剩余 293795 Ready、176358 Zero、69541 Absent，并不等于对应数量的实际 guide 射线；baseline 的 Ready 数包含未使用的、不合格 component 查询，不能用 Ready 数下降推断有效覆盖变差。NRD 首跳共享查询、逐 component 资格、方向/PDF/RNG 语义保持原规则。

**Zero 实验。** 保持 16 B MapEntry，用 Read `regionId` 最高位编码已发布 ObservedZero。编码值至少为 `2^31`，CPU 保证 `readRegionCount <= 65536`，沿用原 unsigned bounds 检查就能在 descriptor 之前回退，不先 mask ID，也无需新增 Ready 热路径判断。Ready 保留原验证，Build 始终使用普通 ID。ObservedZero 仍表示有真实观测、该窗口质量为零；无观测或非法窗口保留旧 Read，没有引入新的成熟度或回退策略。旧 Zero 在 descriptor flags 处已经拒绝，实验直接省的是 descriptor 读取/验证，不能额外声称省去了原本存在的树根读取。

实验发布同步跟踪 canonical 槽位；新增 Read key 按原 ID 顺序重建，稳定 key 只更新 Ready↔Zero 标记。相邻变化槽先合并，超过 128 段再合并最小间隙，和其他模型缓冲共用原 4 MiB staging，没有每槽/每段等待。但实测稳定 key 的标记传输平均仍增加约 **143–293 kB/次 publication**，其中 **96.01%–96.03% 是未变化槽的 padding**，全流程平均约 **23.6–47.3 个 ReadMap copy ranges/publication**。随机散布的状态变化使有用小更新扩成较大的连续范围；总 upload bytes/publication 相对资格阶段增加约 2.1%–14.1%，等待次数还受模型生长和 full upload 频率影响。详见 `zero-publication-audit.json`。没有可重复 Main 收益来补偿这些额外发布工作，因此没有保留该实现。

**同时间画质。** 每阶段 8 秒/臂，cold-start/warm-steady、种子 11/29/47、PG-off/on 共 12 臂，三阶段合计 36 臂。复用同一份有限 4096-SPP 参考，SHA256 为 `0e3c928c01243b06fbe93bf60bfe0a958ad49338839379236f91bdd3a7cf01a7`。最终实验相对基线的 PG-on raw HDR 平均 NMSE 冷启动增加约 1.84%、稳态增加约 7.62%，NRD 后差异很小且混向；没有系统性画质改善。各阶段 PG-off 控制也有明显吞吐波动，最终对照归一化吞吐比跨种子/阶段约 0.710–1.214，不能把某一臂的变化归因于优化。NMSE 含有限参考噪声及 SHaRC/NRD 近似，不是纯采样方差。完整逐臂数据见 `eligibility-comparison.json`、`zero-comparison.json`、`final-comparison.json`；种子 29、两阶段及 raw/final 的统一 Reinhard+sRGB 显示见 `quality-experiments.png`，没有逐图自动曝光。

**新版 Nsight 基线。** 本轮在管理员身份下重新采集了现有版本的 PG-off/on。Main 的 GCC instruction hit 约 **60.34%→49.98%**，导出 instruction miss 指标每 Main 约 **×2.83**；L1 global hit 约 81.76%→79.64%，L2 总命中约 86.70%→92.61%，不支持把问题简单归结为 L2 命中崩塌。compute active warp 指标约 14.87→14.40；no_instruction per-cycle 是推导速率，不是 NOINST PC 样本份额。当前导出没有静态 registers/thread 或真实 spill 量，local memory 指标不能当成 spill。硬件明细与定义在 `baseline-nsight-retry/hardware-analysis.json`。最终 Zero 实验的首次管理员启动被 Windows 报告取消；用户要求重新发起后，两组已在管理员身份下成功完成，运行时文件随后按 SHA 恢复。相对新版基线 PG-on，GCC instruction request/Main 下降约 **2.09%**、miss/Main 下降约 **3.08%**，hit 从 **49.98% 到 50.59%**；但该单次短窗口的 Nsight Main 从 1.390 到 1.429 ms，没有时间改善。指标只小幅变化，仍不足以消除取指压力。数据见 `zero-nsight/hardware-analysis.json`，启动与恢复记录为 `final-hardware-status.json`、`runtime-final-nsight-swap.json`。Nsight 锁频、调试信息及采样工具开销下的时间不与普通 ABBA 毫秒混用，短窗口对比也不证明普通运行的确定回退。

实验版共 **17 项 D3D12 GPU 测试通过**：已有 12 项加 2 项资格/查询、3 项真实 Manager 发布/上传测试。新增测试验证方向/PDF、权重、后续 RNG、Ready↔Zero、无观测与异常窗口保留、canonical 碰撞顺序、300 个稀疏变化槽合并到 128 段，以及目标 offset 257、跨 4 MiB staging 的内容与前后哨兵。测试直接编译生产 Manager，没有重写发布算法。完整实验主图在 D3D12 debug layer 下 **106 项生命周期检查、216 帧**通过。新增测试及接线随未采用实现保留在 `zero-source/`，没有留在当前测试目标中；恢复版本重新构建并通过原 **12 项 GPU 测试**，最终生命周期状态见 `retained-validation/report.json`。

临时诊断只借用 alpha，R/T/Q 逐元素对照通过后才引用分类。它会改变编译上下文、使原本未用的查询结果可观察，不能据此推定未插桩机器码的实际 load 数、buffer 带宽或可节省时间。插桩 RGB 并非逐位相同，不自动归为无害舍入，不用于同时间画质或性能证据。所有临时 shader/harness 需按 SHA256 恢复，正式热路径无新增统计。

补充基线生命周期窗口按 primary/secondary 和 bounce 细分：NRD、1 spp、maxBounces=4 下，ON 合格 component 共 **688072**，实际 physical query **667402**，其中 eligible physical **539694**。primary 共用查询 230400 次可供两个独立 component 采样，因此 component 数不能直接当成物理查询数。primary 的 Ready/Zero/Absent 为 144350/17068/68982；secondary 物理查询 437002，其中合格 309294、不合格 127708。guide 选中与采样函数返回成功均为 **215116**，真正发射的 guided radiance 边为 **186320**，不能把查询成功数或采样成功数当成实际射线数。

- bounce 0：physical 230400，eligible components 378778；guide selected/succeeded 140311，traced 136372。
- bounce 1：physical 298223，eligible components 203630；guide selected/succeeded 52459，traced 49424。
- bounce 2：physical 134114，eligible components 102415；guide selected/succeeded 21840，traced 404。
- bounce 3：physical 4665，eligible components 3249；guide selected/succeeded 506，traced 120。

此窗口无溢出，逐像素守恒与四臂 R/T/Q 对照通过；OFF 的 query/guide 事件为零，但合格 component 仍有 556736。没有分别归因后续零/非正 throughput 与 RR 等拒绝。该补采在按原始源码恢复并重新链接后执行，DLL SHA 与最初基线不同，报告保留这一来源限制，未宣称二进制或 RGB 逐位相同。详细计数、打包范围与来源在 `baseline-lifecycle-classification/analysis.json`；原 harness 和 5 份 runtime shader 已逐字节恢复。

本轮保持 Compute Shader + RayQuery、`RTPR_START.cmd` 默认完整管线和各模块独立开关。SHaRC 终止策略不变；**LOD 切换迟滞、旧区域保留、未成熟模型回退仍暂缓**。NEE 共算和收缩机器码热路径未在本轮实施。

## NEE 分支 eval/PDF 共算实验（2026-10-17，未采用）

NEE 先从光源采样一个方向，然后计算该方向的 BSDF 值 `eval`，以及 BSDF/PG 续接策略对该方向的混合 PDF，供 MIS 使用。`eval` 在本实现中已包含余弦；光源采样权重仍由原 `LiOverPdf` 提供。共算的目标是让 Standard 材质在同一次调用中返回 BSDF 值和 BSDF PDF，共享方向变换、半球检查和 BSDF 构造，而不是改变光源、MIS 或路径采样算法。

本轮完成普通 NEE 和 NRD component NEE 的实现与验证，但两种代码形状都未达到“收益可重复后再保留”的验收条件，已恢复本轮开始时的生产源码、运行着色器和测试目标。**当前版本不包含本节 NEE 共算改动**。实验源码、测试、CMake、运行文件与 SHA256 manifest 保存在 `build/pg-nee-opt-01/{baseline,proposed,ordered}-source/`；`production-restoration.json` 记录恢复和移除本轮新增测试的操作。

实验只在非解析光源且存在有效 PG context 时尝试已有 `tryEvalWithPdf` 接口；Standard 采用无 RNG 的确定性共算，其他材质保持 PDF→混合 PDF finite 检查→MIS→eval/RNG 的可观察顺序。解析光源、PG 编译关闭、alpha=0 和 sparse overload 保持原路径。NEE 仍接受有限的零/负竞争 PDF，未套用续接采样的严格正 PDF 检查。普通 NEE 的 finite/正通道过滤与 visibility 位置、NRD component 的仅 finite 过滤分别保留。第二种形状仅将纯只读的 guide PDF 遍历移到共算之前，尝试缩短 BSDF 输出的活跃区间；混合 PDF 算式未改。

**普通 GPU 计时。** 640×360、VeachAjar，每阶段三轮同进程 off/on/on/off 冻结模型 ABBA，PG-on MainRender 均值为基线 **1.140862 ms**、直接共算 **1.200286 ms（+5.21%）**、先求 guide PDF **1.211494 ms（+6.19%）**。每个实验的三轮 PG-on 均值均高于全部三轮基线。PG-off 均值为 **0.582645 / 0.586456 / 0.592630 ms**；辅助按 on/off 比值归一后，两实验仍分别增加约 **4.53% / 4.41%**。PG-off 本身也受编译布局影响，不是严格未受改动的负对照。恢复后追加一轮 ABBA 为 off **0.594045 ms**、on **1.140844 ms**，Main 回到基线附近。详见 `frozen-abba-comparison.json`。

这些是 Main 整体时间，不是 NEE 函数的独立毫秒；不能将变化直接解释为某种缓存命中或 spill 的变化。源码上，直接共算让 BSDF 输出跨过 guide PDF 树遍历继续存活；但反向调整顺序也未改善。新增控制流、内联和机器码布局的实际影响需要硬件证据，本轮未重新采集 Nsight，因此不认定具体硬件原因。各轮按相同 256 帧 BSDF-only 协议训练后冻结，跨轮未对模型 buffer 做字节校验，不宣称跨版本导入了完全相同的模型。

**相同时间画质与完整管线。** 三版本各 8 秒/臂，cold-start/warm-steady、种子 11/29/47、PG-off/on 共 36 臂，复用同一有限 4096-SPP 参考及原 SHA256。直接共算的 PG-on 吞吐几何平均冷/暖阶段分别增加约 **5.63% / 30.91%**，但 PG-off 也增加 **8.59% / 16.73%**；第二形状 PG-on 增加 **18.42% / 31.80%**，PG-off 同时增加 **11.05% / 28.55%**。发布耗时也明显变化，而发布代码没有改动。上述完整管线波动不能归因于 NEE，更不能覆盖冻结 Main 的一致回退或证明净收益。

直接共算的冷启动 raw HDR NMSE 混向，稳态随更多帧有所下降；第二形状 raw NMSE 冷/暖分别下降约 **4.6%–7.1% / 8.1%–12.6%**。最终 NRD HDR NMSE 的相对变化很小，两形状最大绝对变化均小于 **0.04%**。这些误差包含有限参考噪声及 SHaRC/NRD 近似，不是纯采样方差或无偏性的证明。逐臂数据见 `compare-proposed.json`、`compare-ordered.json` 及 `benchmark-*-analysis.json`。种子 29 的四组 raw/final 显示保存在 `quality-comparison.png`，使用同一 exposure=1、Reinhard+sRGB，无逐图自动曝光。

**射线与正确性。** 临时计数直接放在普通 NEE 和 NRD shared NEE 的实际 visibility 调用点；三版本的四臂逐像素 shadow 计数完全一致，末帧 off **83322**、on **178139**。radiance 分别 **847415 / 952618**，R/T/Q 与完整 SHaRC stats 在普通和诊断两种状态中也一致。因此本固定窗口的回退不是更多射线造成的。插桩改变编译上下文后 RGB 并非逐位相同，具体差异见 `shadow-analysis.json`；诊断图像和时间不用于画质或性能结论。每次诊断的四个 runtime 文件均已逐字节恢复。

两个实验均通过 **14 项 D3D12 GPU 测试**和 debug layer 下 **106 项生命周期检查、216 帧**。新增两项测试使用独立的旧 NEE 调用顺序作 oracle，覆盖 120 组 Standard 配置、随机材质回退、解析光源、非有限/零/负 PDF、MIS、贡献过滤和后续 RNG；两种 PG 编译状态下，本轮样本最大 ULP 差异为 0。这不等于整场景 RGB 逐位一致。测试随未采用实现归档，当前测试目标已恢复原 12 项；恢复后 Release 构建、12 项 GPU 回归、主图 106 项生命周期检查再次通过，报告为 `retained-lifecycle/report.json`。

本轮未改 RayQuery、统一主入口、各模块独立开关或 SHaRC 终止策略；**LOD 切换迟滞、旧区域保留、未成熟模型回退仍暂缓**。正式热路径没有新增 NEE 诊断计数，也没有遗留本轮一次性 Python 验证脚本。
