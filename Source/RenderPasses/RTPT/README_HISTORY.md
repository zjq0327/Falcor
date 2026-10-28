# RTPT / VXPG 历史记录

以下内容保留重构前的阶段记录；开关、测试数量和实验性能以记录时版本为准。当前实现请阅读 [README](README.md)。

# RTPT、VXPG、SHaRC 与 NRD

## RTPT/VXPG 专项测试已删除（2026-10-26）

按用户要求删除 FalcorTest 中的 7 个 RTPT/VXPG 专项 C++/Slang 文件（原 17 项 GPU 测试），移除对应的 CMake 注册和 FalcorTest 对 RTPT 的专用构建依赖，并清理专项测试的运行目录着色器副本和对象文件。`tests/RTPT/` 的旧验证、基准脚本此前已移除；光照观察记录数量中仅供测试 fixture 使用的零值兼容分支也已清理。

运行时 Debug、Detailed diagnostics、Morton/树快照及其 CMD/UI/脚本接口继续保留。Falcor 通用测试与共享测试框架保留。下文 GPU 回归数量、专项测试源码路径和命令均属于历史验收记录，当前不再提供这些测试；历史报告和测量数据仍保留，日常运行使用 `RTPR_START.cmd`。

删除后验证：Release 的 RTPT / FalcorTest / Mogwai 构建通过；重建后的 FalcorTest 枚举中 RTPT/VXPG 用例为 0，215 个通用用例仍保留。主入口 1080p 完整管线及 321×181 的 Debug、详细诊断开关和树快照共 13 项运行检查通过，进程正常退出。本次临时验证脚本已清理；记录见 [删除后运行检查](../../../build/vxpg-remove-tests-20261026/smoke.json) 和 [清理清单](../../../build/vxpg-remove-tests-20261026/cleanup.json)。

## LBVH 与 Bitonic 已删除（2026-10-25）

按用户要求，删除 LBVH 建树、显式父子链接与采样分支、64 位拼接编码和 Bitonic 排序，以及专用 GPU 资源、调度、UI、CMD 参数、可序列化属性和实验测试。当前簇内路径固定为 **Cluster + 21 位 Morton 组合键、独立 32 位活动索引 → 稳定 Radix Sort → 叶子数补齐到二次幂的 Heap 二叉树**。Visibility 关闭时继续使用全局树；成员不变时的局部权重更新保留。

旧属性 `vxpgLBVHEnabled`、`vxpgBitonicSortEnabled` 无论传入 true 或 false 都作为未知属性报错。主入口、场景、RayQuery 架构及其他模块的默认值和开关保留。

保留本轮定位过程中发现的通用正确性修复：分支概率限制在 `[0,1]`，避免浮点除法使右分支概率为负；无效模型不发布簇分布。真实浮点数据的概率回归已迁移到基础 Heap GPU 测试，覆盖正反向概率和质量回退分支。

删除依据和旧实验数据保留为历史记录：[LBVH 优化](VXPG_LBVH_OPTIMIZATION_RESULTS.md)、[Bitonic 实验](VXPG_BITONIC_RESULTS.md)、[Morton / LCP 定位](VXPG_MORTON_LCP_RESULTS.md)。其中实验开关和回放工具已移除，不代表当前可用功能。

删除后验证：Release 的 RTPT / FalcorTest 构建通过，D3D12 debug layer 下 **16 项 GPU 回归全部通过**。VeachAjar 的主入口完整管线以 1920×1080 验证静止 128 帧 Stop、连续移动、网格复用、输出有限性、诊断快照、Visibility / VXPG / Guiding / SHaRC 的关闭与恢复、冻结恢复和手动重置；旧属性的 true / false 均被拒绝。运行目录的六个旧着色器副本已清理；共享框架的 Bitonic 工具不属于 VXPG，未改动。本次为删除后的正确性验证，没有重跑性能对比。详见[验证记录](../../../build/vxpg-remove-lbvh-bitonic-20261025/verification.json)与[GPU 测试](../../../build/vxpg-remove-lbvh-bitonic-20261025/gpu-tests.log)。

## Morton 与树结构诊断

在 **VXPG → Detailed diagnostics → Enabled** 下，点击 **Read Morton / tree snapshot** 可读取当前已发布模型的簇内 Morton 重复数量和真实叶深度。脚本可显式调用 `RTPT.vxpgTreeSnapshot()`；未启用诊断或模型无效时返回 `available=false`，仅显式请求才读回，不增加普通帧的 GPU 工作。CMD 保留 `RTPT_VXPG_DIAGNOSTICS_ENABLED`。

快照格式版本为 2，标明 `treeType=Heap`、`sortBackend=Radix`，保留排序键、真实叶子、每簇重复组/深度、节点和采样上下文；删除旧的树/排序模式字段与显式链接数组。

## 当前 VXPG 固定基础实现（2026-10-24）

VXPG 只保留一条空间路径：**世界空间稀疏哈希 → 按射线命中增量插入/过期回收 → 距离 Multi LOD → 持久光照重要性历史 → 带置信度和相邻层级初始化的局部树更新**。普通相机移动保留世界空间状态，屏幕相关分布继续每帧更新。

Sparse grid、Incremental spatial grid、Multi LOD、Camera reuse、Lighting history、History confidence、Adjacent LOD history、Local tree update 八项均固定启用。它们的 CMD 变量、可修改属性、序列化开关和 UI Enabled 均已删除；`vxpgStats` 保留只读能力状态。旧配置中的这些属性会作为未知属性明确报错，不能设为 false 恢复旧行为。

稠密网格、固定格宽稀疏模式、三角形体素化建格、旧坐标/格宽/分辨率设置及 LOD geometry reuse 已删除。相机运动不再经过三角形覆盖球重建。空间格子仍有容量限制，满时拒绝新条目并保留已有记录；无效提议、预算不足和冻结中无法更新的视角仍按规则回退 BSDF。

主入口继续是 `RTPR_START.cmd` 和 `scripts/RTPTSHARCNRD.py`，使用 VeachAjar、D3D12、ComputePass + RayQuery 和完整 SHaRC/NRD/材质合成/最终累积/ToneMapper 管线，默认输出 `ToneMapper.dst`。最终累积保持 Enabled、128 帧、Stop、autoReset；RTPT 的 `accumulate=False`。

仍可调整的基础参数：

- `RTPT_VXPG_LOD_SCENE_SCALE` / `vxpgLodSceneScale`：默认 8，越大格子越细。
- `RTPT_VXPG_LOD_HASH_CAPACITY` / `vxpgLodHashCapacity`：默认 65536；`RTPT_VXPG_LOD_GEOMETRY_CAPACITY` / `vxpgLodGeometryCapacity`：默认 8192。
- `RTPT_VXPG_LOD_BUDGET_MB` / `vxpgLodBudgetMB`：默认 256 MiB，仅为 VXPG 模型预算。
- `RTPT_VXPG_DISCOVERY_STRIDE` / `vxpgDiscoveryStride`：默认 5；`RTPT_VXPG_SPATIAL_STALE_FRAMES` / `vxpgSpatialStaleFrames`：默认 512 次更新。
- `RTPT_VXPG_HISTORY_FRAMES` / `vxpgHistoryFrames`：默认 32；`RTPT_VXPG_HISTORY_STALE_FRAMES` / `vxpgHistoryStaleFrames`：默认 128。零光照是有效观测，缺测不等于零；冻结暂停老化。
- `RTPT_VXPG_TREE_REFRESH_FRAMES` / `vxpgTreeRefreshFrames`：默认 16；成员不变时局部更新权重，初始、成员变化、周期刷新和无效数据时重建。

其余可选模块继续保留独立 CMD 与运行时 Enabled：PG SHaRC、Visibility、Debug、Diagnostics，以及全局 SHaRC、NRD、FrameAccumulation、ToneMapper。2026-10-26 按用户要求，Shared injection 固定启用多次反弹共享；共享总开关、仅第二表面共享模式及独立第二表面注入均已删除。VXPG 总开关和冻结仍保留。

固定基础实现阶段（删除六项可选优化之前）：Release 构建通过；D3D12 debug layer 下 19 项 GPU 回归通过，分进程完成 48 组主图运行检查，另检查 5 种调试视图。覆盖默认/1080p、128 帧 Stop、普通移动、其余模块开关三态、冻结恢复、空间容量拒绝、预算回退、手动重置、历史窗口 1 和奇数分辨率。连续大量切换配置的单进程检查在完成 41 组后发生内存分配失败；小容量配置和剩余项目在独立进程通过，未声称解决长期配置切换的进程内存积累。验证记录位于 `build/vxpg-required-20261024-001/verification-summary.json`。下方“六个可选开关的移动测试”及之后的章节保留旧阶段的历史协议、配置和测量数据；其中旧开关、旧空间后端和性能结论不代表当前实现。

## 六项可选优化已删除（2026-10-25）

按用户要求，删除 Leaf updates、Compact query tree、Adaptive tree、Fast query、Cached hash query、Support bounds 的 CMD 环境变量、主图属性、C++ Settings、序列化接口、UI、专用统计、资源分配与 GPU 分支。删除整个动态叶增删/紧凑/轮转更新着色器 `RTPTVXPGDynamic.cs.slang` 及其构建注册；删除缓存哈希记录和观测范围缓冲/发布 Pass。旧配置传入这些属性时按未知属性报错，不能重新开启。

保留六项全部关闭时的路径：普通相机移动保留网格与光照历史，新区域仍增量插入，距离 LOD、历史置信度和相邻 LOD 借用保持启用；查询使用普通完整 key 哈希查找和常规分支概率，采样提议使用完整格子边界。**局部树权重更新仍固定启用：成员不变时更新脏叶和祖先，成员增减时重建。** 基础森林本身的 Morton 排序、按成员数分配和有效成员索引检查保留；删除的是稳定动态槽位上的额外紧凑查询方案。

验证：Release 的 RTPT 与 FalcorTest 构建通过，D3D12 debug layer 下剩余 **15 项 GPU 回归全部通过**；删除 4 项仅覆盖已移除路径的测试，将成员空槽专项改为基础路径的有效成员排名、填充叶和无效索引检查。主入口默认配置以 1920×1080 预热 128 帧后连续移动 160 帧，移动期间网格重建为 0，末帧无效样本和几何/分布溢出为 0，历史 carried=672，局部权重更新正常。12 种旧属性 true/false 设置均被拒绝；Visibility、VXPG、Use guiding、SHaRC 的关闭/恢复及冻结移动恢复、手动重置通过。另在 640×360、D3D12 debug layer 下完成 12 组共享注入（SHaRC 开/关）、PG SHaRC、诊断和五种调试视图检查。

清理了原先六项关闭时仍分配的额外簇成员表及脏标记，默认 VXPG 模型载荷由 207455300 B 降到 206930756 B，减少 524544 B（约 0.5002 MiB）。保留 1080p 删除前后移动末帧图像；输出均有限，移动中最终累积等于当前帧合成。并行插入顺序及 NRD 帧间隔会导致运行间图像差异，本次是功能与图像回归检查，没有重跑此前的多种子画质/性能矩阵，不以此宣称稳定提速或逐像素一致。

记录：[删除验证](../../../build/vxpg-remove-six-20261024-001/verification-summary.json)、[GPU 回归](../../../build/vxpg-remove-six-20261024-001/gpu-tests.log)、[移动末帧对照](../../../build/vxpg-remove-six-20261024-001/moving-comparison.png)。

本节下方的六开关性能结果是删除前的历史测量，用于记录删除依据，不是当前可用配置。

## 六个可选开关的移动测试（历史，2026-10-24）

**删除前测试结论：当时建议六项继续默认关闭；现已按用户要求删除。** 当时的测试任务只更新说明，没有修改渲染实现或 `RTPR_START.cmd` 的默认值。增量稀疏距离 LOD、普通移动复用、光照历史、置信度、相邻 LOD 历史和局部权重更新仍为固定基础行为。

RTX 5070 / 驱动 610.88 / D3D12 Release / 1920×1080。读取主入口 CMD 的环境设置，并调用实际 `scripts/RTPTSHARCNRD.py` 主图，使用 VeachAjar、1 spp、4 bounces、SHaRC、NRD RELAX、材质合成、FrameAccumulation 128 Stop / autoReset 和 ACES ToneMapper。详细诊断关闭。随机种子为 71/97/131，每轮轮换配置顺序；每种子测试平移加转向、前进转向后返回两条路线。

每次重放开始前清空 VXPG、SHaRC、NRD 历史并对齐 32 帧相机抖动周期，预热 128 帧；**移动段不手动重置历史**。每条性能路线得到 160 个有效 GPU profiler 帧。11 种配置共 33 组、66 条路线、10,560 个计时帧。画质独立重放相同的 160 帧轨迹，每路线取 8 个检查点和 4 对相邻帧，共 528 个画质检查点、264 对相邻帧。

画质重放仅用 25 个单帧 Stop 快照 Pass 在 GPU 保存检查点，连续移动结束后才读回图像与统计、计算误差；这些快照 Pass 不在性能图中。这样避免 CPU 分析停顿影响 NRD 内部跟踪的帧间隔。末帧快照与当帧 ToneMapper 输出逐像素一致；另验证移动时最终累积输出等于当前帧材质合成输出，没有被 128 帧 Stop 的旧画面掩盖。

配置缩写：L = Leaf updates，C = Compact query tree，A = Adaptive tree，F = Fast query，H = Cached hash query，S = Support bounds。C 在 L 上测试，A 在 LC 上测试；Visibility 保持启用。F/H/S 分别对照基线，并另外检查与 LCA 的组合。

下表变化均相对同种子、同路线的基线配对计算，再等权平均；负值表示耗时或误差降低。每配置 GPU 统计含 960 帧，画质含 48 个检查点。基线原始 / 最终 HDR NMSE 为 9.43143 / 0.70561，ToneMapper 输出 RMSE 为 0.062681，相邻帧残差 RMSE 为 0.065833。

| 配置 | GPU 均值 ms | p95 ms | 耗时变化 | 原始 HDR 误差变化 | 最终 HDR 误差变化 | 色调输出误差变化 | 相邻帧残差变化 |
|---|---:|---:|---:|---:|---:|---:|---:|
| 基线：六项关 | 25.684 | 26.663 | 0 | 0 | 0 | 0 | 0 |
| L | 26.023 | 27.828 | +1.35% | +1.60% | -0.11% | +0.07% | +0.05% |
| LC | 25.629 | 27.315 | -0.19% | +1.44% | -0.22% | +0.07% | +0.06% |
| LCA | 25.497 | 26.614 | -0.70% | +2.16% | +0.00% | +0.08% | +0.10% |
| F | 26.095 | 27.302 | +1.62% | +0.07% | -0.13% | -0.02% | +0.06% |
| H | 25.527 | 26.722 | -0.60% | +0.33% | -0.08% | -0.02% | +0.04% |
| S | 26.743 | 28.055 | +4.14% | -2.86% | -1.07% | +0.10% | +0.23% |
| LCAF | 25.628 | 26.872 | -0.20% | +2.31% | -0.08% | +0.11% | +0.11% |
| LCAH | 25.525 | 26.691 | -0.61% | +2.09% | -0.17% | +0.11% | +0.08% |
| LCAS | 26.370 | 27.477 | +2.68% | +0.20% | -0.99% | +0.29% | +0.45% |
| LCAFHS | 25.878 | 27.058 | +0.78% | +0.22% | -0.97% | +0.32% | +0.40% |

按依赖看，C 相对 L 的耗时平均下降 1.51%，A 相对 LC 再下降 0.50%；它们收回部分前置成本，整体仍没有稳定胜过基线。在 LCA 上分别加 F/H/S，耗时变化为 +0.51% / +0.12% / +3.44%。不能把相对前置配置的改善直接当作相对默认的收益。

删除前的默认建议及原因如下：

- **LEAF_UPDATES = 0**：平均更慢，p95 从 26.663 增至 27.828 ms；没有明显的最终画质收益。
- **COMPACT_QUERY_TREE = 0**：能改善开启 L 后的成本，但 LC 相对默认仅快 0.19%，p95 仍较高，原始 HDR 误差增加约 1.44%。
- **ADAPTIVE_TREE = 0**：局部维护机制生效，但 LCA 平均提速仅 0.70%，原始 HDR 误差增加约 2.16%，最终误差基本持平。
- **FAST_QUERY = 0**：单开平均慢 1.62%；加在 LCA 上也未取得平均收益，画质差异很小。
- **CACHED_HASH_QUERY = 0**：单开名义提速约 0.60%，种子配对的 95% t 区间为 [-3.44%, +2.25%]，没有稳定提速证据；额外占用约 2 MiB 模型载荷。LCAH 的提速区间同样跨零：[-2.63%, +1.41%]。
- **SUPPORT_BOUNDS = 0**：单开原始 / 最终 HDR 误差降低约 2.86% / 1.07%，但耗时增加 4.14%，色调输出误差和相邻帧残差略升。当时不建议作为完整主图的默认优化；现已移除该实验选项。

局部树更新占比并不能代表整帧收益：基线在每组 161 次更新中平均为 70.17 次局部、90.83 次全量；L/LC 为 150 次局部、11 次全量；A 组合为 161 次局部、0 次全量。这些计数含 profiler 延迟刷新所需的额外一次更新，与 160 个计时记录分开解释。世界树维护均值为基线 0.382 ms、L 0.460 ms、LC 0.441 ms、LCA 0.301 ms；LCA 相对基线只节省约 0.081 ms。主渲染本身约 17.67 ms，才是主要成本。各配置移动段几何重建次数均为零，历史保留和相邻 LOD 基础能力没有被关闭。

基线 VXPG 模型载荷约 197.845 MiB；开启 L 后约 199.845 MiB，C/A 不会把预留显存按实际成员数同步缩小；H 额外约 2 MiB，S 额外约 0.25 MiB。此处不包含独立 SHaRC、NRD、场景或测试快照的分配。

指标说明与限制：HDR 使用全图 RGB NMSE = MSE / 参考图均方能量，各视角等权；`display_rmse` 实际测量 ACES 后、交换链 sRGB 编码前的 `ToneMapper.dst` 线性 RGB。另保留统一 Reinhard + gamma 2.2 的误差。相邻帧残差为 `(输出_t - 参考_t) - (输出_t-1 - 参考_t-1)` 的 RMSE，没有光流重投影，不能当作纯闪烁率。GPU 变化的 t 区间先将两条路线在种子内合并，再使用 3 个种子估计，没有把 960 帧当成独立样本；样本较少，区间只作稳定性参考。

参考为每个检查点同相机下的纯 BSDF 8192 spp、4 bounces，仍有 Monte Carlo 噪声；4096 与 8192 spp 的色调输出差 RMSE 均值约 0.0214。画质比较按相同帧数和 1 spp，不是等 GPU 时间预算。建议仅针对当前 VeachAjar、scale=8、1080p 主入口。代表帧中各开关配置仍有相近的墙面斑块和反射噪声，本次六项优化没有消除现有管线的这些可见误差。

Release 构建及 D3D12 debug layer 下 19 项 GPU 回归通过；33 组测量均完成。采集的预热后/移动段末统计中，无效样本、成员不一致、几何/分布溢出、叶容量和网格容量拒绝均为零；快照、累积直通、配置依赖、源码/二进制哈希和运行着色器副本核对通过。临时 Python 脚本清理，正式数据和无损图像保留。

数据：[测量协议](../../../build/vxpg-six-switch-benchmark-20261024-001/protocol.json)、[完整汇总](../../../build/vxpg-six-switch-benchmark-20261024-001/summary.json)、[CSV](../../../build/vxpg-six-switch-benchmark-20261024-001/summary.csv)、[核验记录](../../../build/vxpg-six-switch-benchmark-20261024-001/verification-summary.json)。图：[耗时与 HDR 误差](../../../build/vxpg-six-switch-benchmark-20261024-001/performance-quality-chart.png)、[预设代表帧对照](../../../build/vxpg-six-switch-benchmark-20261024-001/quality-comparison.png)。

## 相机复用与光照历史固定启用（2026-10-24）

VXPG 运行时始终保留普通相机移动下的世界空间状态，并始终解析跨帧光照重要性历史。`RTPT_VXPG_CAMERA_REUSE_ENABLED`、`RTPT_VXPG_LIGHTING_HISTORY_ENABLED` 已从主入口删除，Camera reuse 的 UI 开关和 Lighting history → Enabled 已删除，Settings、属性导出及 GPU 历史关闭分支也已移除。

旧配置若仍传入 `vxpgCameraReuseEnabled` / `vxpgLightingHistoryEnabled`，会收到 obsolete 警告并忽略该值，即使设为 false 也无法关闭固定行为。`vxpgStats` 中同名能力状态始终为 true，仅用于只读诊断，不是可修改选项。

Lighting history 分组继续提供 History frames（默认 32）和 Stale lifetime（默认 128）。Local tree update、Leaf insertion/removal、Compact query tree 等仍独立控制树的更新策略：移动本身不使世界空间分布失效，不代表关闭 Local tree update 后还会复用树拓扑。屏幕分布仍每帧刷新。冻结中移动、投影变化、几何/材质/光照改变、布局调整和手动 Reset 仍遵循必要的失效、回退或历史清理规则。

历史内存固定计入 VXPG 预算，容量不足仍按原路径回退 BSDF。原主入口的 RayQuery RTPT + SHaRC + NRD → ModulateIllumination → FrameAccumulation（128 帧 Stop）→ ToneMapper 保留，其余模块开关保留。

**下方性能与画质数字是在本次固定启用改动之前测得，尤其“原网格/历史关闭”配置属于旧版本，不代表当前主入口默认性能。** 本次 Release 构建、24 项 GPU 回归和 13 组主入口运行检查通过。检查覆盖默认历史保留、旧 false 配置无效、普通移动局部更新、增量 LOD、局部树/Visibility 关闭回退、VXPG 重新开启、冻结移动恢复、手动重置、历史参数与预算回退。Dense 局部树 64 帧移动及增量 LOD 128 帧移动均没有因移动全量重建，历史 carried 非零；所有有效运行帧 invalid/overflow/成员不一致为零。记录位于 `build/vxpg-always-history-20261024/`。

## 查询树与跨 LOD 历史优化（2026-10-24）

先修复动态森林的成员空槽错误：屏幕顶层的 32 对采样现在通过连续有效成员表选择体素，不再把有效成员数当成叶槽跨度，并在读取前验证 compact/cell 索引。此为正确性修复，所有模式均使用，不提供恢复错误行为的开关。下面“增量 LOD 慢约 10.6%”来自修复前版本，只作历史记录。

七项优化都有独立的 `RTPR_START.cmd` 1/0 开关、RTPT → VXPG 中的 Enabled 复选框和可序列化属性，默认关闭。关闭后回到已修复成员抽样的路径。主入口继续保持完整 RayQuery RTPT + SHaRC + NRD → ModulateIllumination → FrameAccumulation → ToneMapper，最终累积默认 128 帧 Stop。

- **Compact query tree**：`RTPT_VXPG_COMPACT_QUERY_TREE_ENABLED` / `vxpgCompactQueryTreeEnabled`。需要 Local tree update + Leaf insertion/removal，作用于可见性簇内查询树。网格 ID、光照历史和全局叶槽稳定；脏簇按真实成员数构建紧凑树并同步反向映射。最多 2048 个成员的簇恢复 Morton 排序，更大簇使用正确的未排序紧凑树。物理存储仍有预留空间，逻辑节点数减少不等于显存同比减少。Visibility 关闭及未采用簇分布的反弹仍使用原全局质量树。
- **Adaptive cluster updates**：`RTPT_VXPG_ADAPTIVE_TREE_ENABLED` / `vxpgAdaptiveTreeEnabled`。依赖 Compact query tree。新增叶子并行分配，每次轮到一个旧簇更新描述、评估成员归属，改动涉及的簇重建小树，替代固定周期全量重建。保留原可见性代表点和种子作为分类基础。关闭时仍使用原周期刷新；重置、布局变化和无效分布继续触发完整恢复。
- **Fast tree queries**：`RTPT_VXPG_FAST_QUERY_ENABLED` / `vxpgFastQueryEnabled`。单个有效子树直接通过，保持 Full 分支概率。
- **Cached hash queries**：`RTPT_VXPG_CACHED_HASH_QUERY_ENABLED` / `vxpgCachedHashQueryEnabled`。依赖增量网格，另存连续的完整 int4 key + cell ID 查询记录；插入、失败插入、淘汰和 ID 再利用同步维护，仍验证完整 key，代价为每个哈希槽额外 32 B。首轮组合测试出现性能退化，因此与单子树快速路径分开测试和控制。
- **Observed support bounds**：`RTPT_VXPG_SUPPORT_BOUNDS_ENABLED` / `vxpgSupportBoundsEnabled`。依赖 Incremental spatial grid。累积已观测表面的格内范围，并加 1/16 格 padding；无观测时保留整格。这是采样提议范围，不是全场景几何的保守包围盒。正向接受、反向 PDF、面积权重和树节点使用同一发布范围；范围外仍由 BSDF 分支承担。关闭后恢复整格。
- **History confidence**：`RTPT_VXPG_HISTORY_CONFIDENCE_ENABLED` / `vxpgHistoryConfidenceEnabled`。使用固定启用的光照历史。区分缺测与有效零光照观测，保留历史记录，同时按样本权重和缺测年龄调低当前采样重要性。年龄因子最低 0.1，寿命到期使用原淘汰规则，不因离开屏幕立即删除空间记录。
- **Adjacent LOD history**：`RTPT_VXPG_LOD_HISTORY_REUSE_ENABLED` / `vxpgLodHistoryReuseEnabled`。依赖 Incremental spatial grid + Distance LOD，光照历史固定启用。相机移动后，首次获得光照观测的新层级查找该位置上一相机对应的相邻层级。读取上一帧历史和法线快照，要求样本权重至少 4、法线点积至少 0.8，借入权重最多 2，再融合真实新观测。移植平均重要性，目标层级使用自己的面积。借入过历史的记录不能继续作为供体，防止反复跨层复制放大；没有合格供体则正常冷启动。未进行材质分桶。

新增统计包括成员数不一致、全局/森林根权重、本帧及累计跨 LOD 借用数。Detailed diagnostics 另提供正向/反向查询数、遍历层数、最大深度及单子树快速通过次数，保留原 owner 探测和引导接受/拒绝计数。诊断运行与正式计时分开，正常移动没有 CPU 树读回。

验证数据位于 `build/vxpg-query-opt-20261024/`。另修复自适应重分类中条件表达式提前执行原子预留的问题，以及网格重置后未清完整历史缓冲导致旧槽历史可能被误借用的问题。24 项 RTPT GPU 测试通过，主入口完成 19 组开关、关闭/恢复与回退组合，并验证移动后整库重置不借入旧历史。专项 GPU 测试覆盖空槽尾部成员、无效索引、紧凑/自适应叶增删与正反向 PDF、快查询表淘汰和容量耗尽、观测范围、跨 LOD 借用与重复/回声/法线拒绝。各配置的统一移动路线、计时和图像数据见该目录协议及汇总；以下保留旧版历史结果。

### 本次逐项移动测量（最终代码）

RTX 5070 / 驱动 610.88 / D3D12 Release；1280×720，完整主入口管线。三个种子 71/97/131，配置顺序每轮轮换，预热 128 帧后捕获 128 个有效 GPU 帧；九种配置共 3456 个计时帧。计时窗口不读回图像或统计，详细诊断关闭。画质独立重复相同路线，在第 31/63/95/127 帧保存原始与 NRD 后 HDR：共 108 个检查点、216 张 HDR 图。参考是对应相机下纯 BSDF 1024 spp。

本轮性能与画质统一使用平移幅度 x=0.6、z=0.2 加 yaw=0.25 弧度的路线。**这不同于旧 1080p 小幅移动的“慢 10.6%”测试，不能直接相减这两轮绝对耗时。** 下面均与本轮同条件结果比较。

主序列从 p0 到 lod 逐项累加六项优化；cached_hash 在 fast 配置上单独加缓存哈希，不包含支持范围、置信度及跨 LOD，不代表七项全开的性能。七项全开的功能与开关恢复另在生命周期测试中通过。以下每行给出 GPU 均值 / p95、相对 p0 的耗时变化，以及相对 p0 的原始 / 最终 HDR 误差变化。HDR 误差是各视角等权 NMSE，负数表示降低。

- **原网格配置（新优化关闭）**：12.023 / 12.579 ms；耗时 -7.80%；raw / 最终误差 -5.53% / -14.97%。
- **修复成员错误后的增量 LOD**：13.040 / 14.696 ms；耗时 +0.00%；raw / 最终误差 +0.00% / +0.00%。
- **再开紧凑查询树**：12.819 / 14.460 ms；耗时 -1.69%；raw / 最终误差 +2.95% / +14.66%。
- **再开自适应簇更新**：12.658 / 13.313 ms；耗时 -2.93%；raw / 最终误差 +3.42% / +18.00%。
- **再开单子树快速路径**：12.488 / 13.082 ms；耗时 -4.23%；raw / 最终误差 +2.54% / +2.88%。
- **再开观测支持范围**：12.903 / 13.629 ms；耗时 -1.05%；raw / 最终误差 -2.21% / -10.75%。
- **再开历史置信度**：12.592 / 13.579 ms；耗时 -3.44%；raw / 最终误差 +1.56% / +13.01%。
- **再开跨 LOD 历史**：12.504 / 13.398 ms；耗时 -4.11%；raw / 最终误差 +6.10% / +33.80%。
- **fast 配置单独加缓存哈希**：12.408 / 12.987 ms；耗时 -4.85%；raw / 最终误差 +3.57% / +15.40%。

紧凑树恢复了真实的小查询结构，但不是所有画质指标都改善。自适应模式消除了本路线中的周期全量重建：p0/compact 在每组 129 次更新里有 9 次全量、120 次局部，开启自适应后为 0 次全量、129 次局部。脏簇的小树仍然更新，并非无需建树。世界树维护从 p0 的约 0.450 ms 降至 lod 的 0.288 ms；MainRender 从 9.134 ms 降至 8.655 ms，但仍高于原网格的 7.946 ms。lod 主组合相对 p0 快 4.11%，相对原网格仍慢 4.00%。

缓存哈希拆分后的三轮均值相对 fast 仅快约 0.65%，增加约 2 MiB 查询记录；这修正了首轮组合探索中无法隔离变量的判断。收益量级小，三个配对样本不足以证明普遍收益。Observed support bounds 在本路线降低了等视角 HDR 误差，但比 fast 多约 0.414 ms；存在性能与画质取舍。

最终 HDR 的等视角 / 整体能量归一化 NMSE：原网格 0.39984 / 0.12103，p0 0.47022 / 0.12391，lod 0.62914 / 0.16392。lod 相对 p0 分别增加约 33.80% / 32.29%，而统一 Reinhard + gamma 2.2 后的 display RMSE 为 p0 0.07384、lod 0.07389，变化很小。HDR 误差受到有限高亮噪点显著影响：种子 71、姿态 63 的 lod 最终图，最差 100 个像素贡献约 84% 平方误差。不能只看缩略图，也不能把有限样本下的差异当作已证明的系统性偏差。

本轮没有得到“跨 LOD 历史稳定提高画质”的证据。记录保留、相邻层级借用与 PDF 一致性已验证，但历史借用仍是实验性提议初始化；法线筛选不能替代材质/光照分区。新选项继续默认关闭。需要速度时可单独比较 compact + adaptive + fast，不能因复用达到 100% 就建议全部开启。原网格默认配置仍保留。

数据：[测量协议](../../../build/vxpg-query-opt-20261024/protocol-final-details.json)、[性能汇总](../../../build/vxpg-query-opt-20261024/performance-summary.json)、[画质汇总](../../../build/vxpg-query-opt-20261024/quality-summary.json)、[指标定义](../../../build/vxpg-query-opt-20261024/metric-definitions.json)。图像：[四视角对照](../../../build/vxpg-query-opt-20261024/quality-comparison.png)、[高亮区域](../../../build/vxpg-query-opt-20261024/quality-highlight-crops.png)、[HDR 误差热图](../../../build/vxpg-query-opt-20261024/quality-hdr-error-crops.png)。热图选取已测得的退化实例，整体指标使用全部三个种子。

### 接近相同 GPU 预算的独立复测

使用新种子 163/199/233，比较原网格、p0、confidence、lod 四种配置；相机轨迹端点不变，按上面的实测 GPU 均值调整轨迹上的采样帧数。每段分别为 32 / 30 / 31 / 31 帧，完整路线分别 128 / 120 / 124 / 124 帧。这是 GPU 预算校准，不是严格相同墙钟时间；目标每条路线约 1539 ms，实际比目标高 1.18%～5.81%，同一种子不同配置之间实际 GPU 总量最大相差约 3.20%。原始实际耗时保留在汇总中。

相对同批次 p0，依次给出 raw 等视角 NMSE、最终等视角 NMSE、最终整体能量 NMSE 和最终 display RMSE 的变化：

- **原网格**：+14.85% / +281.92% / +9.61% / +0.82%。
- **不含跨 LOD 的主组合**：-1.68% / -17.42% / +1.95% / +0.53%。
- **加入跨 LOD 的主组合**：-5.25% / -18.05% / +0.96% / +0.09%。

新种子下 lod 的最终等视角误差降低、整体能量误差略升，与相同帧数实验的变化方向不同。两批实验同时改变了种子和帧数，因此不能把两批结果的差异单独归因于时间预算。它们共同说明高亮尾部样本对当前结果影响很大，尚不能证明稳定画质收益；所有主要指标及退化实例均保留，没有裁掉高亮值来优化评分。参考本身仍有 Monte Carlo 噪声，误差还包含原有 SHaRC/NRD 行为。

见 [等 GPU 预算汇总](../../../build/vxpg-query-opt-20261024/equal-budget-summary.json)。

### 查询诊断与交付检查

诊断单独运行，不使用其耗时作为性能结果。p0 簇内平均正向遍历 11.00 层，compact 为 4.11 层；其逻辑森林节点从 131072 个降至三轮末帧的 740 / 774 / 734 个，但两者 VXPG 载荷均约 98.49 MiB，因为物理森林仍预留固定区段。lod 载荷约 98.99 MiB，cached_hash 分支约 100.49 MiB；均不含独立 SHaRC 和其余管线分配。

记录的引导接受比例 `accepted/(accepted+rejected)`：p0 4.13%、compact 4.17%、adaptive 3.31%、fast 3.33%、support 7.74%、confidence 3.39%、lod 3.57%。因此支持域收紧带来更多有效引导命中，同时增加后续着色工作；不能把所有配置的耗时变化都归结为相同工作量下的计算优化。跨 LOD 在正式计时三轮分别成功借用 276 / 255 / 259 次，另一次诊断为 265 次，实际借用路径已执行；借用次数本身不代表画质收益。

24 项 GPU 回归（D3D12 debug layer）通过，19 组开关/回退组合共检查 456 帧，另有移动后整库重置检查及主入口默认/全部新开关启动两项验证。正式性能、画质、等预算与诊断各运行均就绪，未发现 invalid、成员数不一致或几何/分布溢出。主入口保持 SHaRC、NRD、FrameAccumulation 128 帧 Stop / autoReset、ToneMapper 启用，默认输出 ToneMapper.dst。采用 ComputePass + RayQuery，变更限于 RTPT、主入口/专用图和 RTPT 专项测试。

详见 [查询诊断](../../../build/vxpg-query-opt-20261024/diagnostics-summary.json)、[生命周期检查](../../../build/vxpg-query-opt-20261024/lifecycle-summary.json)、[本任务修改清单](../../../build/vxpg-query-opt-20261024/changes.json) 和 [独立补丁](../../../build/vxpg-query-opt-20261024/task-changes.patch)。原始 GPU 帧记录、HDR 图、测量协议、验证日志及版本哈希保留；本任务临时 Python 脚本在交付前清理。

## VXPG 移动复用与增量空间结构（2026-10-24）

统一主入口仍为 `RTPR_START.cmd`，使用 `scripts/RTPTSHARCNRD.py` 的完整 VeachAjar 管线，输出 `ToneMapper.dst`。以下为旧实现记录；当前 Camera reuse 固定启用，其余列出的可选功能仍有独立 CMD 与运行时 Enabled 开关：

- **Camera reuse（现已固定启用）**：普通相机平移、旋转不再使世界空间分布整体失效。固定网格及光照历史保持身份，屏幕相关分布仍每帧更新；要复用采样树拓扑还需开启 Local tree update。
- `RTPT_VXPG_LEAF_UPDATES_ENABLED` / **Leaf insertion and removal**：配合 Local tree update，在活跃集合增删时回收/分配稳定叶槽，只更新受影响的祖先。关闭后恢复活跃集合变化触发全量树重建。
- `RTPT_VXPG_INCREMENTAL_GRID_ENABLED` / **Incremental spatial grid**：配合 Sparse grid，按主命中及训练路径命中发现新空间 key，在 GPU 哈希表内去重、插入、计龄、淘汰。关闭后恢复原三角形体素化支持表；未开启 Sparse grid 时保留参数但不激活增量模块。
- `RTPT_VXPG_MULTILOD_ENABLED` / **Multi LOD**：沿用独立距离 LOD 开关。与增量网格组合后，位置和层级共同组成 key，旧层级暂存、新层级按命中插入，不因跨越旧覆盖球而重建全部几何。旧 **LOD geometry reuse** 覆盖球选项只适用于三角形体素化模式，在增量模式下不生效。

增量组合需开启 Leaf insertion/removal、Incremental spatial grid、Multi LOD，以及 `RTPT_VXPG_SPARSE_GRID_ENABLED`、`RTPT_VXPG_LOCAL_TREE_UPDATE_ENABLED`；Camera reuse 与光照历史固定启用。各开关改变时会按需重置提议、NRD 与最终累积，参数保留；普通移动不会清除静态世界空间历史。冻结时暂停计龄，冻结后相机变化先回退 BSDF，解冻重新发布。投影/视锥、场景几何、材质、光照和网格配置改变仍采用保守失效路径；未验证蒙皮和顶点缓存形变。全部射线仍使用 Compute Shader + RayQuery。

**稳定身份与光照历史。** 持久空间 cell ID 与采样树叶槽分开管理；cell 从哈希移除后先让叶子退出本帧提议，发布完成才归还 cell ID，下次更新才允许复用，同时递增 cell 的复用版本。每帧候选和正反向 PDF 使用同一 proposal generation。相同 key 的旧历史原地保留；未开启上节 Adjacent LOD history 时，新 key 冷启动，不做跨 LOD 历史迁移。旧层级记录只有符合当前相机 owner key 时才进入活跃分布，避免同一位置重复发布多层级质量。

**叶子增删。** 全局树使用固定叶槽与 free list；每个簇保留固定容量的森林区段，新叶优先分配到描述最相近且有空槽的簇，满簇可转入其他簇。这是有界 GPU 存储方案，不实现可变长簇内存搬迁。质量变化、旧叶删除和新叶插入分别记录脏地址，再分层重算共享祖先；删除记录保留旧森林地址，即使叶槽同帧重用也不会漏更新旧祖先。预计算几何节点合并包围球。`RTPT_VXPG_TREE_REFRESH_FRAMES` 默认 16，仍定期更新可见性代表点和聚类种子；未开启 Compact query tree 时，动态模式按新种子重新分配固定槽，不执行原 Morton 重排；开启后查询树独立紧凑排序。Adaptive cluster updates 则替代固定周期刷新。屏幕超像素、顶层估计和顶部树仍每帧构建。关闭 Visibility 时使用同一动态全局质量树。

**增量发现与淘汰。** `RTPT_VXPG_DISCOVERY_STRIDE` 默认 5；主表面按每 5×5 像素一个轮换命中发现空间。光照训练固定按 SHaRC 实际 tile 布局，为每条路径、每个观察深度分别保留记录，兼容不同 stride、相位及奇数分辨率，浅层表面不会抢占深层记录。不新增发现专用射线。已有 cell 的正常光照观测立即积累；缺失 cell 按 key 去重、插入后回放每份观察一次，包括有效零光照；已立即写入的观察不会重复回放。记录池按配置的最坏深度预分配并计入预算，待插入槽位队列不超过哈希容量。每帧只插入新 key，但记录清理、发现、过期扫描和质量解析仍有容量相关开销。

`RTPT_VXPG_SPATIAL_STALE_FRAMES` 默认 512，按实际模型更新次数计龄，与光照历史缺测期限 128 分开。淘汰使用哈希 tombstone 保留探测链；容量或探测预算不足时丢弃新插入并计数，已有记录和提议继续有效，未覆盖区域仍由 BSDF 支路承担。冷启动发现需要若干帧，容量不是无限增长。未开启 Observed support bounds 时，增量模式保存完整空间格子边界，不再保存三角形裁剪包围盒；这会扩大采样支持域，也可能增加空样本，必须与性能和画质一起评估。

`vxpgStats` 和 **Read GPU statistics** 提供动态活跃叶数、叶插入/删除/容量拒绝、叶槽跨度，以及 `gridLiveCells`、空间插入/淘汰/复用 ID/容量拒绝等计数。`occupiedCells` 和各 LOD Geometry 计数显示实际驻留 cell；`geometrySlotSpan` 单独表示曾分配的 cell ID 高水位，含已回收槽。历史 valid/carried 与拓扑复用是不同概念；树复用率使用测量区间 `ΔtreeLocalUpdates / (ΔtreeLocalUpdates + ΔtreeFullBuilds)`，不是“复用了多少个网格”的比例。计数读取在 CPU 显式查询时同步，正常渲染调度不做读回。

实施顺序与阶段验证：先完成相机移动复用，在 1280×720、同一 128 帧轨迹上从 0% 提高到 54.7%；再启用叶子增删达到 93.8%（120 次局部 / 8 次周期刷新）；随后增量固定格与距离 LOD 均维持该树复用比例。将空间寿命缩短为 64 次更新的压力验证实际发生插入、淘汰和 ID 再利用，且没有 invalid/overflow。正式数据、运行组合和最终性能/画质测量保存在 `build/vxpg-incremental-20261024/`。这些阶段比例不等于最终整帧加速。

Release 构建与 D3D12 debug layer 下 18 项 VXPG GPU 测试通过，包括动态叶增删/槽位复用/满簇转移/空树恢复、增量去重/回放/淘汰/容量耗尽/ID 版本，以及 4096 次正反向 PDF 检查。运行验证包含 25 组开关和生命周期组合，最终补充 11 组容量/分辨率/可视化/冻结恢复检查。主入口七个相关启动开关全开后的往返验证，在 640×360 下每个位置运行 64 次更新：原点、新区域 x+1.2、返回的驻留格子数为 2563 / 2999 / 3013，几何版本始终不变；无空间淘汰，三个位置都有历史沿用。容量压力测试中的有界拒绝属于预期，其他验证未出现无效采样或分布溢出。共享框架及 Material/BSDF 未修改。

最终统计修正另在空间寿命 16、移动 128 帧下验证：累计淘汰 1335 个记录、复用 971 个 cell 槽；驻留数 2649、槽位跨度 3013、活跃叶 223。各 LOD 驻留/活跃计数之和分别与全局驻留/活跃总数一致，invalid=0。临时 Python 验证与分析脚本在交付前删除，正式 GPU 回归测试、测量协议、日志、原始数据和对照图保留。

### 本轮移动性能

RTX 5070 / 驱动 610.88 / D3D12 Release，1920×1080，完整主入口配置，VeachAjar 的位置和目标一起做 128 步周期平移（x/z 幅度 0.12/0.04）。六配置、六轮平衡交错、六个种子；每组重置并预热 128 次，再调用 129 次 render，获得 128 个有效 GPU profiler 帧。每配置 768 个计时帧，总计 4608 帧。详细诊断和 debug layer 关闭，统计/图像读回放在窗口外。GPU 整帧均值 / p95：

- 原配置：**25.378 / 26.042 ms**，VXPG 载荷 225.76 MiB。
- 原历史 + 局部更新：**25.594 / 26.171 ms**，移动树复用 **0%**。
- 再开相机复用：**25.110 / 25.880 ms**，树复用 **65.2%**，载荷 232.51 MiB。
- 再开叶子增删：**25.714 / 30.473 ms**，树复用 **93.0%**，载荷 234.51 MiB。
- 改为增量固定网格：**28.083 / 32.429 ms**，树复用 **93.0%**，载荷 207.25 MiB。
- 增量距离 LOD：**28.056 / 29.264 ms**，树复用 **93.0%**，载荷 199.09 MiB。

这里的树计数覆盖每组 129 次更新，与 profiler 的 128 个记录不同：相机复用为 505 次局部 / 269 次重建；叶子增删和两种增量模式各为 720 次局部 / 54 次周期重建（93.023%）。阶段验证的 120/128=93.75% 与此没有矛盾。原配置未启用局部模块，其树计数不可用；不能把零计数解释为没有树构建。

相机复用相对原配置均值 **−1.06%**，六轮配对 bootstrap 95% 区间 **[−2.43%, −0.15%]**；相对原历史+局部模式 **−1.89%**。叶子增删相对原配置 **+1.33%**，区间跨零，且周期刷新引起明显 p95 开销。完整增量固定格/LOD 相对原配置分别 **+10.66% / +10.55%**，区间 **[10.31%, 11.00%] / [10.18%, 11.01%]**。这些结果仅针对本机、本场景和该路线。

完整增量 LOD 的世界空间采样树阶段合计 **0.364 ms**，原历史+局部为 **0.688 ms**；新网格维护+插入约 **0.040 ms**。但 MainRender 从原配置 **17.167 ms** 增至固定格 **19.817 ms** / LOD **20.048 ms**，抵消构建阶段节省。稀疏 owner 查询、完整格子支持域和固定槽森林均改变主渲染行为，本轮未进一步消融各自贡献。**高拓扑复用率不等于整帧加速**；当前完整增量组合无净性能收益，保持独立开关、默认关闭。显存数字只计 VXPG 逻辑载荷，不含独立 SHaRC 和其他进程分配。

所有计时段分布就绪、HDR 有限，invalid/geometry overflow/distribution overflow 和插入拒绝为零，窗口内整网格重建为零。固定格与 LOD 在计时区间分别新增 821 / 67 个空间记录。长进程第 31 组预热时发生一次 **Slang internal error**，没有产生该组计时数据；保留前 30 组并在新进程按原种子/顺序/预热完整补完最后六组，未重编译渲染器。根因未定位，不把恢复运行描述为已修复编译器问题。最终又补充了 CPU 显式统计/界面显示，未修改计时所用 GPU 算法和 shader；后续画质与统计检查使用最终二进制。协议、原始数据、恢复记录和配对区间见 [性能汇总](../../../build/vxpg-incremental-20261024/performance-summary.json)、[数据索引](../../../build/vxpg-incremental-20261024/performance-index.json)。

### 本轮移动画质

640×360，三个种子、六种配置、每条路线四个检查点，共 72 次测量。路线使用 x/z 幅度 0.6/0.2 的平移和 0.25 弧度转头，128 帧一个周期；每组先预热 128 帧，再在第 31/63/95/127 帧取样。参考是相同相机姿态、相同路径深度的纯 BSDF 1024 spp（4 个独立 256 spp 批次），关闭 SHaRC/VXPG/NRD；所有测试配置均保持完整 SHaRC+NRD 管线、当前帧 1 spp。三个种子批次分别运行在新进程中。**按相同帧数比较，不是相同耗时预算**，且画质路线/分辨率与上述性能路线不同。

`relativeMSE` 表示各姿态归一化 HDR 平方误差的等权平均，`pooledRelativeMSE` 表示把全部姿态的误差和参考能量相加后归一化。两者都报告，因为该路线不同姿态的亮度差别很大。相对原配置，依次为“原历史+局部、相机复用、叶子增删、增量固定格、增量 LOD”：

- 各视角等权的 raw HDR 误差变化：**+4.48%、+3.92%、+6.22%、+8.90%、+8.61%**；最终 HDR：**+2.89%、+2.92%、+2.45%、+2.81%、+3.34%**。
- 整体能量归一化的 raw HDR 误差变化：**+0.76%、−0.12%、+1.43%、+1.40%、+2.18%**；最终 HDR：**+0.23%、+0.16%、+0.20%、+0.29%、+0.26%**。
- 原配置 raw/最终 HDR 的整体 NMSE 是 **3.472991 / 0.364228**；增量 LOD 为 **3.548570 / 0.365164**。统一 Reinhard + gamma 2.2 后，最终图的 display RMSE 为原配置 **0.079513**、固定格 **0.079343**、LOD **0.079472**。因此不同指标有细微差异，不能把它解释为整体画质改善。

72 个检查点 HDR 均有限、提议就绪；最终 FrameAccumulation 输出与 NRD 合成 HDR 完全一致，移动自动重置累积生效。所选对照帧主体轮廓一致，仍有原始噪声、反射与 NRD 平滑差异。参考图仍有噪声：由两半独立样本差估计，整体能量归一化的参考噪声约 **0.00630**，等视角权重约 **0.03379**，没有从误差中扣除。误差还包含原有 SHaRC/NRD 近似；三个种子、四个姿态的有限抽查不足以证明普遍退化或等价，**本轮没有获得稳定画质收益的证据**。

原始数据与逐种子结果见 [画质汇总](../../../build/vxpg-incremental-20261024/quality-summary.json)、[协议](../../../build/vxpg-incremental-20261024/quality-protocol.json)。对照图使用同一曝光映射： [原始 HDR](../../../build/vxpg-incremental-20261024/quality-raw-comparison.png)、[NRD 后 HDR](../../../build/vxpg-incremental-20261024/quality-filtered-comparison.png)、[GPU 阶段比较](../../../build/vxpg-incremental-20261024/performance-comparison.png)。

## VXPG 光照历史

以下为原历史模块说明；三角形体素化模式仍遵循原几何重建规则，新增增量模式按上节保留相同 key 的历史。

当前光照历史固定启用；**VXPG → Lighting history** 仅提供历史长度与过期时间参数。未开启 History confidence 时，历史保存的是正光照观测的 maxRGB 重要性，不是可终止路径的 RGB 辐射缓存；沿用原来的“正观测均值 × 包围盒最大面面积”质量定义。原来的仅本帧观测关闭路径已删除。

当帧 flux/count 仍每帧清空。独立历史记录保存均值、有效样本权重和缺测年龄；新正观测按样本权重合并，旧权重按 `(1-1/historyFrames)^elapsedUpdates` 衰减。缺少正观测时保留均值，达到 `historyStaleFrames` 后淘汰。`RTPT_VXPG_HISTORY_FRAMES` 默认 32（有效指数历史长度），`RTPT_VXPG_HISTORY_STALE_FRAMES` 默认 128；均提供 UI 参数。窗口 1 表示新观测完全替换旧均值，缺测保留仍由 lifetime 单独控制。

几何重建、网格配置/场景/训练目标改变和历史参数改变会清除历史；冻结模型时暂停更新与计龄。历史仅在当前几何版本内按 cell 身份保存，不跨几何重建重映射；距离 LOD 平移导致的重建仍会清除历史。普通相机视图变化只使屏幕分布失效，静态世界空间记录可保留。开关/参数变化重置 NRD 与最终累积，正常逐帧更新不重置最终累积。

历史载荷为 **16 B/几何容量**（默认 Dense 64³ 额外 4 MiB），纳入 VXPG 预算；当前始终分配历史缓冲，不再提供关闭路径。Read GPU statistics 与 `vxpgStats` 提供 valid/carried/expired/updated 数量。所有求交继续使用 RayQuery，主入口的 SHaRC、NRD、128 帧 Stop 累积和 ToneMapper 保留。

启用距离 LOD 的几何覆盖复用时，缺测历史必须仍属于当前相机的 owner key 才能进入活跃提议；旧层级记录可继续保留至过期，但不重复发布同一表面的其他层级。valid/carried 统计包含这些暂未发布的记录。

## VXPG 采样树局部更新

以下介绍原“只更新质量”的局部模式及历史测量。Camera reuse 现已固定启用；另开启 Leaf insertion and removal 后，普通移动和活跃集合变化按上节处理，不再直接触发全量树重建。

`RTPT_VXPG_LOCAL_TREE_UPDATE_ENABLED=1/0` 对应 **VXPG → Local tree update → Enabled**；光照历史固定启用，局部树更新仍可单独关闭。`RTPT_VXPG_TREE_REFRESH_FRAMES` / **Topology refresh frames** 默认 16；设为 1 时每次更新都全量刷新拓扑。当前仅局部树更新默认关闭，光照历史固定启用。

每帧先在 GPU 上解析当前体素质量，检查活跃集合。如果身份和支持域仍有效，保留 compact 编号、聚类、排序与森林结构；质量有任何变化的叶子进入有界队列，然后按层级更新这些叶子的祖先。以 proposal generation 去重共享祖先，无质量变化阈值，也不采用浮点原子增量，父权重始终由两个子权重相加。published 节点的中心/半径保持原样，避免把查询格式误当成 AABB 再次合并。

活跃体素增删、视角/几何失效、功能开关、无效发布和周期到期会全量重建。全量刷新重新选择代表屏幕点、计算可见性描述、聚类和 Morton 排序。复用期间聚类可能不再是当前权重的最佳分组，但采样与反向 PDF 使用同一份当前权重。所有更新、屏障和发布在主渲染之前完成；无 CPU 每帧读回调度数量。

本阶段更新的是**全局质量树和簇内森林**。超像素成员、32 对顶层估计和屏幕顶部树仍每帧刷新；几何体素化也保留原来的构建方式。原有全量 pass 在复用帧通过 GPU 条件退出，CPU 调度外壳仍保留；因此“局部更新”不代表全部构建工作或全部 dispatch 都消失。若活跃集合频繁变化，可能几乎总是全量回退，关闭光照历史时尤其如此。

额外载荷是每几何 cell 4 B 的解析质量、每 active 容量 4 B 的脏叶队列、全局树/森林的 4 B 节点标记和少量控制缓冲。默认 Dense 64³ / active 65536 实际约 **2.75 MiB**，预算按非二次幂容量的最坏情况保守计算。关闭时释放相关缓冲及未使用 pass 的资源引用；重新开启强制重新发布。冻结暂停两项更新；开关或周期参数变化会重置 NRD 与最终图像累积。

`vxpgStats` 提供 `treeFullBuilds` / `treeLocalUpdates`、`treeDirtyLeaves`、`treeGlobalNodesUpdated` / `treeForestNodesUpdated`、`treeTopologyAge`、`treeTopologyValid` 和 `treeRebuildReason`。重建原因位为 reset=1、周期=2、活跃集合变化=4、无效=8，可组合；计数在当前缓冲生命周期内累计。UI 的 Read GPU statistics 也显示全量/局部次数和本次局部节点数量。

测试入口：`FalcorTest.exe --device-type d3d12 --enable-debug-layer --test-case RTPT_Temporal`。覆盖历史合并/缺测/过期、实际 compact 活跃集合、LOD 当前归属、Dense/Sparse 的结构回退，以及局部节点质量与同拓扑全量构建比较和 4096 次正反向 PDF 检查。完整管线的运行记录与本轮测量保存在 `build/vxpg-history-local-20261024/`。

本轮按“先历史、验证后再局部更新”的顺序实施：历史 18 个运行场景通过，随后两项功能的 24 个组合场景通过；Release 构建和 D3D12 debug layer 下 16 项 RTPT GPU 回归测试通过。场景覆盖开关/重新开启、冻结、共享注入、稀疏/距离 LOD、覆盖复用内移动、全局/森林分布和 128 帧 Stop 后的开关重置。最终的开关处理还保留已编译程序，只解除停用缓冲的引用，不因这两项运行时开关而重建 shader；最终二进制的 16 项开关复核（含冻结中切换）全部通过。

VeachAjar 探索测量：1080p 完整主图，诊断/debug layer 关闭；种子 71/97/131，每组预热 192 次，再捕获 129 次 render 调用，统计读取在窗口外。GPU 整帧均值：全关 **32.43 ms**、仅历史 **30.60 ms**、仅局部更新 **31.40 ms**、同时开启 **31.35 ms**。同时开启时 387 次更新中 260 次复用、127 次重建；仅局部更新时 387 次均重建。段间有明显波动，三个种子的均值不足以证明稳定加速；尤其不能将“零复用”的局部单开均值变化解释为树复用收益。

同时开启相对仅历史的可见性聚类阶段约 **0.456 → 0.171 ms**、Morton 排序 **0.148 → 0.075 ms**；但整帧并未优于仅历史。默认 1080p VXPG 逻辑载荷全关 **225.76 MiB**、历史 **229.76 MiB**、同时开启 **232.51 MiB**，不含独立 SHaRC 缓存和进程其他分配。原始记录见 [1080p 测量](../../../build/vxpg-history-local-20261024/temporal-timing-1080p.json) 与 [阶段汇总](../../../build/vxpg-history-local-20261024/temporal-timing-summary.json)。最终增补的资源引用处理仅影响功能切换；上述计时窗口内的 GPU 更新算法未改变。

720p 静止相机、三个相同种子、4 秒共同预算的画质抽查，使用额外 raw 图像累积，实验中的图像累积上限设为不限；日常主入口仍为 128 Stop。预热 192 次后只重置两份图像平均，保留已训练的 VXPG/SHaRC/NRD；采用截止前最后一次完成的 GPU 读回结果，未按帧数比例修正误差。参考复用相同 V 场景/相机的两张独立 BSDF 8192 SPP 均值，参考噪声估计 NMSE=0.001934，未扣除。

全关/仅历史/同时开启的全图 raw HDR NMSE 为 **0.060642 / 0.062484 / 0.067644**，即历史约 +3.0%、同时开启约 +11.5%；最终 HDR 为 **0.223000 / 0.223158 / 0.223292**。最终图包含原有 SHaRC/NRD 近似，接近不能证明 raw 的差异消失。部分暗部/高光 ROI 也变差，逐种子、预先选定 ROI 和参考身份见 [画质汇总](../../../build/vxpg-history-local-20261024/temporal-quality-summary.json)。这是有限抽查，不是普遍退化或改善的统计结论；本轮未取得足够的性能/画质收益证据，故两项默认关闭，保留独立对照与后续调参能力。

### 追加性能复测：最终版本，48 组 / 6144 个 GPU 计时帧

2026-10-24，RTX 5070 / 驱动 610.88 / D3D12 Release / 1920×1080，使用 `RTPR_START.cmd` 的全部现有开关及实际主图。只改变历史/局部更新两项开关，未修改渲染实现或默认设置。每组重新初始化 VXPG、SHaRC、NRD 和图像累积状态，预热 128 次，再调用 129 次 render 得到 128 个有效 profiler 帧。详细诊断和 D3D12 debug layer 关闭，统计/图像读回及 GPU 遥测位于捕获区间外；静止时仍保留最终 128 Stop，RTPT/SHaRC/NRD 继续执行。

静止视角用 8 个种子组成 8 轮四配置对照，采用平衡交错顺序；每配置 1024 个计时帧。GPU 整帧均值：**全关 25.934 ms、仅历史 26.122 ms、仅局部更新 25.981 ms、同时开启 25.821 ms**。对应 p95 为 26.736 / 26.997 / 26.810 / 26.769 ms，p99 为 27.175 / 27.738 / 27.453 / 27.169 ms。

相对全关，静止均值变化为历史 **+0.725%**、局部更新 **+0.181%**、同时开启 **−0.436%**；配对轮次 bootstrap 95% 区间分别为 [−0.081%, +1.380%]、[−0.703%, +1.077%]、[−0.882%, +0.025%]，均包含零。**相对仅历史，同时开启快 1.153%**，区间 [−1.768%, −0.308%]；因此可确认本批次中局部更新为“已开启历史”的静止场景节省了一点时间，但不能据此声称组合相对原始全关已有明确整帧优势。

静止时，两项同开在 1032 次更新调用中复用 671 次（**65.0%**），仅局部更新则全部重建。全局/局部更新、可见性聚类、Morton 排序及森林的合计耗时，相对仅历史为 **0.650 → 0.391 ms（约 −40%）**；屏幕顶层树仍约 0.69 ms。两项同开的 MainRender 为 **17.80 ms，约占整帧 69%**；全关为 17.67 ms，构建阶段节省部分被主渲染耗时变化抵消。模型载荷全关/历史/局部/同时开启为 225.76 / 229.76 / 228.51 / 232.51 MiB。

移动测试使用 4 轮四配置、每配置 512 个计时帧。相机位置和目标一起围绕固定原点做 128 步周期平移，x/z 幅度为 0.12/0.04 世界单位。均值依次为 **25.541 / 25.604 / 25.478 / 25.525 ms**；同时开启相对全关 −0.063%，95% 区间 [−1.594%, +0.871%]。两项同开的 516 次更新全部重建，**复用率 0%**，构建合计相对仅历史为 0.634 → 0.692 ms；未确认整帧收益。正式移动数据使用独立 `float3` 原点副本和每步位置断言；发现相机属性返回可变引用后，先前错误轨迹的 9 组数据全部排除并重测，不参与汇总。

所有 48 组输出有限、分布就绪、错误/溢出为零，捕获期间几何重建数为零。GPU 观测温度 63–72°C、核心频率 2872–2895 MHz。区间按整轮配对数据重采样 20000 次，避免把相邻帧当成独立重复；结论限于本机、V 场景和这些路线。该轮比前面的三种子探索增加了重复、固定了每组重置并平衡顺序；两批绝对时间不宜直接相减。原始阶段记录与协议见 [数据索引](../../../build/vxpg-temporal-perf-20261024-002/index.json)、[测试协议](../../../build/vxpg-temporal-perf-20261024-002/protocol.json)、[完整性能汇总](../../../build/vxpg-temporal-perf-20261024-002/analysis.json)。本轮未重复画质实验。

## O8.2 距离 LOD（2026-10-24）

VXPG 可采用当前 SHaRC 的相机距离规则。先开启 `RTPT_VXPG_SPARSE_GRID_ENABLED=1`，再开启 `RTPT_VXPG_MULTILOD_ENABLED=1`；运行时对应 **VXPG → Sparse grid → Enabled** 和 **Multi LOD → Enabled**。Multi LOD 默认关闭。Sparse grid 关闭时保留 LOD 参数并使用原稠密模式；仅关闭 Multi LOD 则返回 O7 固定网格。

主入口的 V 场景参数采用 VXPG scene scale=8：距离小于 4 的点使用 L1（格宽 0.25），[4,8) 使用 L2（0.5），[8,16) 使用 L3（1.0），更远自动继续增长。SHaRC 自身仍为 scale=64；其他图直接创建 RTPT 时的通用 VXPG 默认值也仍为 64。距离和世界量化都包含与 SHaRC 一致的 1e-4 位置偏移；阈值以 GPU 实际浮点计算为准。层级取决于真实表面点，不按整个盒中心选层。VXPG 独立保存完整 `(x,y,z,LOD)` 身份，不使用 SHaRC 的法线分桶或辐射缓存条目。

V 主入口的 LOD 哈希/几何/活跃容量为 65536/8192/65536，单独模型预算 256 MiB；固定网格及 Dense 配置保留。scale=8、覆盖半径 1.0 在五个 V 预检位置最多 5014 格。该容量只针对 V 的已测范围，不可直接配给 scale=64：后者初始精确模式就需要 182748 格。通用 RTPT 默认哈希/几何/预算仍为 524288/262144/384 MiB。对应设置为 `RTPT_VXPG_LOD_HASH_CAPACITY`、`RTPT_VXPG_LOD_GEOMETRY_CAPACITY`、`RTPT_VXPG_LOD_BUDGET_MB`；尺度使用 `RTPT_VXPG_LOD_SCENE_SCALE`。活跃池允许大于几何池，保留 65536 可避免切回 Dense 时意外缩小其容量。

可选 `RTPT_VXPG_LOD_GEOMETRY_REUSE_ENABLED=1` 对应 **Multi LOD → LOD geometry reuse → Enabled**，默认关闭。覆盖半径由 `RTPT_VXPG_LOD_COVERAGE_RADIUS` 设置，V 主入口为 1.0 世界单位，通用 RTPT 默认仍为 0.25。范围内复用几何支持表，但每帧仍按当前相机确定 owner、训练和发布提议；越界、瞬移或几何改变重建。关闭复用时每次相机平移重建；仅旋转无需重建几何。冻结模型后移动会回退 BSDF，解冻后恢复。

开启 VXPG 的 Debug，并在 **Debug view → Distance LOD** 中选择层级视图，通过 `RTPT.vxpgDebug` 查看。Read GPU statistics 显示每级几何与活跃数量，Python `vxpgStats` 还提供有效模式、重建次数和失败原因；读回只发生于显式查询。切换网格、尺度、容量或复用设置会重置提议及 NRD/最终累积历史。统一主入口仍默认显示 ToneMapper，保留完整管线和 128 帧 Stop。

验证入口：`FalcorTest.exe --device-type d3d12 --enable-debug-layer --test-case RTPT_O`，执行 O7 与 O8.2 共 11 项 GPU 测试，包括超像素归一化舍入回归。实施依据见 [距离 LOD 计划](VXPG_O8_2_DISTANCE_LOD_PLAN.md)，最初 scale64 的历史测量见 [首轮 V 场景结果](VXPG_O8_2_RESULTS.md)；后续调优与修复的最新对照见下方报告。

已按 [V 场景尺度优化计划](VXPG_O8_2_V_TUNING_PLAN.md)实施 scale=16/32/8、复用半径和容量对照，协议、原始数据及结论见 [V 调优结果](VXPG_O8_2_V_TUNING_RESULTS.md)。Detailed diagnostics 额外提供 owner 探测、Full 遍历分支、自体素拒绝及每级观测数分布；关闭时高频计数编译掉，观测分布只在显式统计读取时读回。

本轮 V 的 LOD8/R1 在 1080p 静止/短路线为 26.07/26.40 ms，相对旧 LOD64 精确模式少 5.1%/29.4% 帧时，但仍比 Dense 慢约 8%。4 秒 raw 误差相对旧 LOD64 改善、相对 Dense 仍恶化，故保留可选而非默认启用。长路线重建 p99 仍约 42.6 ms。重复验收还修复了 RTPT 超像素计数使用原始权重、写入使用归一化权重引起的浮点平局不一致；统计现在区分容量不足与该类错误。

## O7 固定世界格 Spatial Hash（2026-10-23）

O7 提供独立的 `RTPT_VXPG_SPARSE_GRID_ENABLED=1/0` 启动开关及 **RTPT → VXPG → Sparse grid → Enabled** 运行时开关，默认关闭；关闭即使用原稠密网格。主入口继续加载 VeachAjar 的 RayQuery RTPT + SHaRC + NRD → ModulateIllumination → FrameAccumulation → ToneMapper，保留 128 帧 Stop 累积及全部原有开关。

固定网格使用显式 `vxpgCellSize`、`vxpgGridOrigin` 和完整有符号 int3 key。主 CMD/图的初值匹配 V 场景原 64³ 网格：cellSize=0.2668444812297821，origin=(-9.647193908691406,-6.647402763366699,-12.039023399353027)。它们不再随场景包围盒缩放。哈希槽、几何记录、光照活跃记录容量分别由 `vxpgHashCapacity`、`vxpgGeometryCapacity`、`vxpgMaxVoxels` 控制，初值为 131072/65536/65536。

几何全量体素化后一次发布哈希表；帧内清理与 compact 按几何占用数执行，排序和树按实际活跃数量执行。GPU 生成间接参数，CPU 不逐帧读回调度数量。原 Full 分布、32 clusters、SPixel32 和顶层采样预算保留；Shared injection 仍可独立组合。哈希/记录/jobs 溢出、坐标精度或资源预算不足时完整回退 BSDF，UI 的 Read GPU statistics 可读取原因。修改模式、原点、尺度或容量会使 VXPG 提议及图像历史失效；冻结时须解冻才能重建。

V 场景 RTX 5070 实测：1080p 完整帧 24.304 → 25.324 ms（慢 4.20%）；720p 同 8 秒 raw HDR NMSE 增加 3.26%，最终 HDR NMSE 变化 +0.0075%。结构目标完成，但当前场景没有净性能或画质收益，默认关闭保留。协议、阶段时间、对照图及限制见 [O7 结果报告](VXPG_O7_RESULTS.md)，设计与实施差异见 [O7 实施记录](VXPG_O7_IMPLEMENTATION_PLAN.md)。

新增 O7 专项测试位于 `Source/Tools/FalcorTest/Tests/RTPT/VXPGSparseGrid.cpp`，6 项在 D3D12 debug layer 下通过，仅覆盖本模块，不恢复此前删除的旧测试套件。运行：`FalcorTest.exe --device-type d3d12 --enable-debug-layer --test-case RTPT_O7_`。构建 FalcorTest 时会同时准备 RTPT shader 依赖。

## VXPG 接入与使用

VXPG 已接入普通 PT 和主图的 NRD diffuse/specular 路径，所有求交保持 ComputePass + RayQuery。独立模型包含三角形裁剪的包围体素、当前帧 BRDF 光照注入、128 位可见性描述、MRCS K-means++ 聚类、Morton GPU 排序、簇内树和超像素顶层树。构建及发布不做每帧 CPU 分布读回；窗口中的 Read GPU statistics 会主动读取一次诊断快照。

体素质量为正光照观察的平均值乘包围盒最大面面积。顶层按每个超像素/体素簇的 32 对实际成员估计材质贡献、距离衰减和可见性，并保留 5% 几何重要性正则化；超像素成员收集、前缀和、散射与建树全部在 GPU 上完成。

统一入口仍为根目录 `RTPR_START.cmd`，加载 VeachAjar 和 `scripts/RTPTSHARCNRD.py`，默认输出 `ToneMapper.dst`，保留 SHaRC、NRD、最终 128 帧 Stop 累积和 ToneMapper。交付默认 **VXPG 开启、ShortBranch A、PG 缓存关闭**。完整行为见 [实施计划](VXPG_IMPLEMENTATION_PLAN.md) 和 [接口契约](VXPG_DESIGN_CONTRACT.md)。

CMD 顶部的 `RTPT_GUIDING_MODE` 选择 `BSDF` 或 `VXPG`；`RTPT_VXPG_ENABLED=1/0` 控制 VXPG，窗口中对应 **RTPT → Guiding mode** 和 **VXPG → Enabled**。旧 PG 已移除，不再提供模式、参数、训练、采样或诊断 API。VXPG 的 **Use guiding** 只停止采样；**Freeze updates** 停止模型构建；**Reset VXPG** 使模型失效并重建。冻结后改变相机、几何或光照会先回退 BSDF，解冻后恢复。

当前仅保留 **A：ShortBranch**；2026-10-22 按用户要求删除 B：MixturePath。Estimator 下拉框、Guide fraction (B)、CMD 的 `RTPT_VXPG_ESTIMATOR` 和 GPU 混合续接分支均已移除。旧图中的 `vxpgEstimator="ShortBranch"` 可兼容加载；其他值明确报错。旧 `vxpgGuideFraction` 仅警告并忽略，不再保存。

- 只允许物理 bounce=0/1 使用 VXPG，bounce>=2 仅 BRDF。在每个实际展开且可引导的顶点，先独立完成 PG 短支路，再处理 BRDF 主路径。BRDF 命中 SHaRC 时终止自身后续；PG 不递归，真实首个命中不属于所选体素时作为空样本，不重抽。
- `RTPT_VXPG_PG_SHARC_ENABLED=0/1` 对应 **VXPG → PG SHaRC → Enabled**。关闭时 PG 计算真实直接光与自发光；开启且缓存资格/配对记录有效时返回完整缓存，否则仍计算真实局部项。局部项用 p/q 分配，后缀只在 H_G=1 的区域用 p/(p+H_G*q) 分配。
- 引导命中复用 candidate.pdf；BSDF 命中的 q 仍需反向求值，用于短分支/主路径分配及缓存资格。NEE 和命中光源的参考密度仍为材质 `evalPdf`，不查询 VXPG 的光源端点 q。

本次删除的 Release 构建与 320×180 VeachAjar 的 15 项运行检查通过，覆盖缓存/模块开关、全局/聚类分布、普通 PT 和旧 B 配置拒绝；实际 PG 缓存命中已观察到，所有检查帧 HDR 有限且 invalidSamples=0。默认关闭详细诊断的 1920×1080 主图另运行 8 帧，原始 HDR、合成、累积和 ToneMapper 输出全部有限，分布就绪。报告位于 `build/vxpg-remove-b-01/report.json` 和 `main-1080p.json`；临时 Python 脚本与调试产物已删除。本轮不提供新的性能或图像等价性结论。

NRD diffuse/specular 使用各自条件 PDF、贡献和已有主 BRDF 射线的首次命中距离。B 专用的辅助距离射线已删除。主图关闭下游 NRD 滤波时，仍保留 `enableNRD=True` 的分量信号路径用于直通合成；普通 PT 使用 `enableNRD=False`。

A 的缓存 C/R 与 full 共用 hash、计数、调制和历史规则，使用不可变快照 Resolve。额外内存为 **120 B/entry**，默认 1M 项额外占用 120 MiB；该内存与 VXPG 模型预算分开报告。PG 缓存开关不改变训练目标，也不因切换而重新预热缓存。SHaRC 仍是近似缓存：插值/足迹、有限历史和更新路径长度都可能引入误差，MIS 不会消除这些近似。A 的 PG 缓存默认关闭，用于对照实验。

`RTPT_VXPG_VISIBILITY_ENABLED=1/0` 对应 **Visibility Enabled**；关闭时停止可见性/聚类构建，使用全局体素分布。`RTPT_VXPG_DEBUG_ENABLED=1/0` 对应 **Debug Enabled**；关闭额外调试追踪/绘制，独立 `RTPT.vxpgDebug` 输出保持可用。Debug view 可查看体素、超像素、体素簇与可见性描述，均不接入 NRD。模型容量溢出、零质量、预算不足或冻结后失效时回退 BSDF，诊断快照和 `vxpgStats` 显示原因。

`RTPT_VXPG_DIAGNOSTICS_ENABLED=1/0` 控制详细活动计数，对应属性 `vxpgDetailedDiagnostics` 和 **VXPG → Detailed diagnostics → Enabled**，默认 **0（关闭）**，与 Debug Enabled 独立。关闭时编译掉引导尝试、射线、缓存活动和构建观察等高频诊断原子；ready/generation、有效体素数、队列/溢出及无效数据检查仍保留。纯诊断切换保留模型、NRD 历史和最终累积，不改变采样 RNG 或射线预算；首次切换可能需要编译 shader 变体。

当前簇内采样仅保留 **Full**：每层使用当前点与法线的几何重要性，BRDF 命中的反向 PDF 使用相同分支概率。Visibility 关闭或条件行无效时仍回退到原全局质量提议，bounce=1 也仍使用全局质量树。2026-10-23 按用户要求删除 O3 的 Mass-only / Hybrid（包括 2 层、3 层）实现、属性、Fast sampling UI 和 CMD/主图参数；[O3 阶段记录](VXPG_O3_RESULTS.md) 仅保留为历史测量，不代表当前可选功能。

2026-10-23 按用户要求删除 O5.1 **Primary reuse**：移除 MainRender 首命中缓存读取、专用 hitT/完成标志纹理、属性、统计字段以及 CMD/UI 开关。MainRender 的普通 PT、NRD 和 VXPG 路径均直接执行主射线 RayQuery。此前 V 场景未获得净性能收益，[O5.1 阶段报告](VXPG_O5_1_RESULTS.md) 仅保留为历史测量。

删除后的 Release RTPT/Mogwai 构建及 VeachAjar 14 组运行状态、142 项检查通过：包含 1080p 完整主图、普通 PT 3 SPP、NRD 直通/恢复、共享训练开/关/重开、冻结、SHaRC 关闭后的稀疏回退以及 BSDF 回退。321×181 下主渲染每帧追踪 58,101 条 primary，3 SPP 为 174,303 条；VXPG 全屏 primary 仍完整生产。验证输出均有限且 invalidSamples=0，未重新测量性能或画质等价性。记录在 `build/vxpg-remove-primary-reuse-20261023-001/runtime.json`，临时验证脚本已删除。

**Shared injection 固定启用。** 2026-10-26 按用户要求删除共享总开关，以及关闭共享时的独立第二表面注入实现。CMD 不再读取 `RTPT_VXPG_SHARED_INJECTION_ENABLED`，UI 仅显示共享状态；旧属性 `vxpgSharedInjectionEnabled` 和 `vxpgSharedInjectionAllBouncesEnabled` 无论传入 true 或 false 均作为未知属性报错。VXPG 训练时，从第二表面（bounce=1）至训练路径实际到达的最后一个表面，每个深度都提供局部观察。共享路径默认每 **5×5 像素一条**、SHaRC Update bounces=8；步长与深度仍可调，不补足因未命中或俄罗斯轮盘终止的深度，不改变 SHaRC 路径数量和反弹预算。保留 VXPG 总开关和冻结；不再提供仅第二表面共享模式。

各深度复用 SHaRC 的 BSDF 续接、光源样本、材质求值和遮挡求交。SHaRC 保留原 MIS 训练值，VXPG 使用自发光加 raw NEE 的 maxRGB 重要性，不乘相机路径 throughput，不将 SHaRC 后缀辐射写入 VXPG；二者不共用缓存载荷。全屏 primary position/normal/hit 仍完整生产，Full 分布和采样/PDF 算法不变。1080p、stride=5、8 个观察深度的 48 字节记录池约 30.375 MiB；当前主入口配置仍在 **256 MiB** 预算内，保持原预算。更密步长或更深路径须重新核对预算；超预算会明确报告并回退 BSDF。空间池或哈希饱和沿用已有拒绝统计，不按深度裁剪记录池。

SHaRC 关闭或冻结时，VXPG 以同一配置的 stride 和完整反弹深度独立训练，不写 SHaRC、不推进其更新帧索引；不再存在专门追踪到第二表面就结束的稀疏回退。只关闭 SHaRC 查询仍共享其全部更新。VXPG 冻结时停止注入而 SHaRC 继续训练。SHaRC 任意终止表面的额外 raw NEE 使用 RNG 副本，不延长或改写 SHaRC 后缀。共享 stride/深度或训练来源变化会清理 VXPG 光照历史并重置 NRD 与最终累积；普通每帧训练不重置历史。固定共享沿用此前默认开启时的训练算法；主表面数据由 `RTPTVXPGPrimary.cs.slang` 完整采集，已删除旧独立注入着色器及其光源绑定。详细诊断可读取 `sharedObservationsBounce1...32` 和 `sharedRecordedObservations`；它们统计本次更新实际留下的观察，非配置深度，也不等于最终成功建格数量。将训练深度显式设为 1 仍是合法的最小预算，不代表恢复已删除的共享模式。

**2026-10-26 固定共享、删除关闭分支后验证。** Release 的 RTPT / FalcorTest / Mogwai 构建通过，17 项 D3D12 debug-layer GPU 回归和 95 项主入口运行检查通过，最终进程正常退出。主入口 1080p 下反弹 1–8 均有实际观察，全屏主表面数据保留，估算 227.50 MiB 仍在原 256 MiB 预算内；完整管线和 128/Stop 配置保留，达到上限后训练继续。321×181 下验证 SHaRC 关闭/冻结/查询关闭及恢复、VXPG 冻结/关闭及恢复、BSDF 着色器变体、4/8 深度调整。两项旧共享属性 true/false 均被拒绝，继承环境中的旧 CMD 变量设为 0 也无法选择已删除路径。临时脚本及旧独立注入的运行目录着色器副本已清理；首次检查脚本的退出接口错误修正后完整重跑。详见 [本轮运行验证](../../../build/vxpg-fixed-shared-training-20261026/validation.json) 和 [GPU 测试](../../../build/vxpg-fixed-shared-training-20261026/gpu-tests.log)。本轮未重新测量性能或画质。

**2026-10-26 删除仅第二表面共享模式后的历史验证（当时仍保留共享总开关）。** Release 的 RTPT / FalcorTest / Mogwai 构建通过，17 项 D3D12 debug-layer GPU 回归和 89 项主入口运行检查通过。验证默认 1080p 下反弹 1–8 均有实际观察、256 MiB 预算内提议有效、完整全局管线与 128/Stop 设置保留且达到上限后训练继续；321×181 下检查当时的共享总开关关闭/重开、SHaRC 关闭/冻结/恢复、只关闭缓存查询以及 4/8 深度调整。SHaRC 停更时深层观察仍存在且其更新帧索引不推进；旧属性 true/false 均被拒绝，旧序列化和统计子开关字段已移除。详见 [阶段运行验证](../../../build/vxpg-fixed-shared-bounces-20261026/validation.json) 和 [GPU 测试](../../../build/vxpg-fixed-shared-bounces-20261026/gpu-tests.log)。下方性能/画质为删除前阶段的历史数据，该阶段验证针对模式删除及停更时的多深度独立训练。

详细诊断的旧字段 `injectionSecondaryRays` 在多反弹共享下统计所有被观察深度的续接求交尝试；这些求交复用 SHaRC 原路径，不能把此计数解释为多反弹模块额外发射的射线数。

**2026-10-25 多次反弹共享历史验证（包含现已删除的模式）。** Release RTPT / FalcorTest / Mogwai 构建通过，17 项 D3D12 debug-layer GPU 测试通过；其中新增回归覆盖不同发现步长、奇数尺寸、多深度新格子、同格多份观察、有效零光照、回放不重复计数及当时的仅第二表面回退。主入口配置的 69 项运行检查通过，确认当时默认开启共享与深度子开关、反弹 1–8 均有实际观察、全屏 primary 保留、128 Stop 保持和切换重置、SHaRC 关闭/冻结及只关查询、VXPG 关闭/冻结和恢复。321×181、seed=19、64 帧对照的 `RTPT.sharcCacheRadiance` 输出在独立、仅第二表面及全部反弹模式下逐像素一致。验证记录见 [validation.json](../../../build/vxpg-shared-all-bounces-20261025/validation.json)。初次状态验证使用 320 MiB 临时预算；最终入口恢复原 256 MiB，以下历史性能及画质批次均使用该预算。

RTX 5070 / 驱动 610.88 / D3D12 Release / 静态 VeachAjar / 1920×1080，直接读取 `RTPR_START.cmd` 的脚本、场景和模块配置，主图完整开启，PG SHaRC 关闭、详细诊断与 debug layer 关闭。三个种子 0/19/37，平衡正反序，每个窗口重新初始化并预热 128 帧，再保留 128 个 GPU profiler 记录；18 个窗口共 2304 个有效计时帧。最终图仍为 128/Stop，RTPT、SHaRC、NRD 和 VXPG 更新继续执行。独立 / 仅第二表面 / 全部反弹的整帧 GPU 均值为 **25.025 / 24.773 / 24.857 ms**；全部反弹相对仅第二表面约 **+0.34%**，相对独立约 **−0.67%**。三个种子的配对 t 区间均包含零，不据此宣称稳定加速。全部反弹的 SparseTrace 为 0.370 ms，观察记录清理及发现插入也增加开销；主渲染约 17.69 ms，仍占主要成本。VXPG 资源载荷从 196.65 增至 **223.22 MiB**，保守预算估算 **227.50 MiB**，不包含另列的 SHaRC 配对缓存和其他管线资源。详见 [性能汇总](../../../build/vxpg-shared-all-bounces-20261025/performance-summary.json) 与 [完整计时](../../../build/vxpg-shared-all-bounces-20261025/performance.json)。

长批次反复替换图和编译时出现一次 `slang.dll / 0xc0000005` 原生异常；保留当时已完成记录，单独保存第三种子的中断窗口，并在新进程中完整重测该种子的正反序组。最终汇总使用完整平衡的 18 个窗口；分批续测正常退出，没有修改 Slang 或共享框架。

画质使用同一 1080p 完整主图、三个种子，分别保存冷启动 128 帧最终图；随后重置累积，在每配置约 8 秒的渲染窗口内记录预热后的最终 128/Stop 图和全部窗口帧的原始信号均值。原始信号仅在画质阶段增加测量用 AccumulatePass，不计入上述性能图；窗口末允许完成一整帧，图像读回在窗口外，各模式平均渲染窗口约 8.013–8.017 秒、每窗口 306–320 帧。参考为 SHaRC/VXPG 关闭、16 bounces、两个独立种子各 2048 帧的 BSDF 原始信号均值；比较配置仍保持主入口 maxBounces=4，并包含 SHaRC/NRD 的近似误差。两个参考的差异 NMSE=0.03327，估计合并参考噪声底约 0.00832，绝对误差不能解释为本次共享模式单独造成。

独立 / 仅第二表面 / 全部反弹的三种子平均原始信号 NMSE 为 **0.041830 / 0.041416 / 0.041770**，预热后最终 HDR NMSE 为 **0.162553 / 0.162572 / 0.162703**。全部反弹相对仅第二表面的配对变化为：原始信号 **+0.86%**、冷启动最终图 **+0.076%**、预热后最终图 **+0.081%**；误差增加表示变差。分别对两个参考计算也没有得到画质改善结论。该阶段 V 场景表现为训练覆盖增加、资源开销增加，性能和画质没有测出收益；当时保留两个独立开关用于对照，共享总开关、深度子开关及仅第二表面共享模式现均已删除，测量数据仍作为历史记录保留。详见 [画质汇总](../../../build/vxpg-shared-all-bounces-20261025/quality-summary.json)、[逐窗口数据](../../../build/vxpg-shared-all-bounces-20261025/quality.json) 和 [seed 0 冷启动/预热后显示对照](../../../build/vxpg-shared-all-bounces-20261025/comparison-seed0.png)。

O5.2 的历史 V 场景 1080p、9 对交错实测：Full/共享整帧 **25.781/26.049 ms**，均值慢 **1.04%**，未见稳定净收益；VXPGInject **0.631/0.289 ms**，但 MainRender **17.614/18.127 ms**。720p、8 秒、3 种子的 raw NMSE 增加 **0.28%**，最终 HDR 基本持平。159 项数值/运行检查通过；当时仅第二表面共享保持默认关闭，不能把这组历史结果当作当前多次反弹模式的性能结论。

删除 O5.1 后，按用户要求只在 V 场景复测 O5.2 开/关：1080p 完整主图、9 对交错运行，每种模式 1,152 个 GPU 帧。关闭/开启共享的整帧为 **25.073/25.221 ms**（均值 +0.59%，配对 bootstrap 95% 区间 −1.35%～+2.03%），MainRender **17.112/17.671 ms**（+3.26%），VXPGInject **0.611/0.242 ms**（−60.40%）。未确认稳定整帧收益，默认继续关闭；206 项配置、状态和输出检查通过。本次未重新进行画质误差对照，也不把与旧测试时段的差值归因于删除 O5.1。完整数据在 `build/vxpg-full-after-removal-20261023-001/`，临时脚本已清理。

读取 `vxpgStats` 时先检查 `diagnosticsAvailable`/`diagnosticsStatus` 及 `modelDiagnosticsAvailable`/`modelDiagnosticsStatus`。状态分别为 `disabled`、`unavailable` 或 `current_frame`/`current_update`；活动字段缺失表示未采集或当前无覆盖，**不表示射线数、接受数或缓存命中数为零**。渲染活动只覆盖最近一个有效主渲染帧，由 `diagnosticsFrameCount=1`、sample offset、SPP 和 generation 标识；模型活动只覆盖当前一次实际更新，由 `modelDiagnosticsFrameCount=1` 和更新 frame index 标识。Freeze updates 下，仍渲染时可以得到当前帧的渲染活动，但模型活动为 unavailable，不把冻结前的构建计数当作当前帧；解冻并实际更新后才重新提供。Read GPU statistics 和属性读取会主动读回，性能计时窗口内应避免调用。

参考为 [VXPG 固定提交](https://github.com/SuikaSibyl/SIByLEngine2023/tree/8c1adad28c16e07592bc79122cb9d0c9738699bc)。本项目采用等价的 GPU radix sort 和按 Morton 次序组织的簇堆，使用明确条件化的模糊超像素和正反一致 PDF；并非原 Vulkan 实验代码的逐位移植。细小/远处病态盒子使用保守包围锥，锥外/盒外失败保留空质量。当前支持 RTPT 既有的反射型 StandardMaterial 三角形场景、alpha 纹理、实例变换；skinning/顶点缓存形变尚未验证，明确回退 BSDF，不修改共享框架。

2026-10-22 按用户要求删除 RTPT/VXPG 专项测试：`tests/RTPT/` 下的验证脚本、基准脚本、依赖清单和两个专用场景（共 6 个文件），以及 FalcorTest 的 6 个 `RTPTVXPG*` C++/Slang 文件、对应 CMake 注册和运行目录中的测试 shader 副本。Falcor 通用测试、正式渲染代码、主入口、优化计划及历史性能报告保留。下述 10 项 GPU 测试和脚本运行结果属于删除前的历史证据，相关命令当前不可直接重跑；日常运行继续使用 `RTPR_START.cmd`。

首次复刻的历史验收包括Release构建、10项GPU测试和主图组合回归；当时RTX 5070的VeachAjar 1080p完整图，旧PG/A缓存关/A缓存开/B约15.58/41.14/41.40/36.71 ms，短时raw HDR质量未优于旧PG。该组数字不与后续不同轮测量混用。历史协议、显存、缓存近似、自发光材质连续编辑的共享内存限制见 [验收结果](VXPG_VALIDATION_RESULTS.md)。

2026-10-22完成O0–O2等价优化：默认关闭高频详细计数，复用候选PDF和同一端点q，提前拒绝无效引导命中，拆分PDF-only立体角计算，并在32 B节点内预计算查询几何。RTX 5070、VeachAjar、1080p完整主图、每模式9次运行均值，A缓存关 **43.24→29.96 ms（−30.71%）**、A缓存开 **43.19→30.18 ms（−30.13%）**、B **38.66→27.66 ms（−28.47%）**；720p下降约24%–28%。4秒配对raw HDR NMSE下降约24%–25%，最终NRD图像误差变化较小，不宣称确定改善。当前仍慢于同轮旧PG的约16.79 ms，主要差距仍在MainRender。

本轮7项临时GPU测试在两种节点配置均通过，诊断开/关冻结原图逐位一致，主入口418条生命周期检查和清理后的Release构建通过。临时Python/GPU测试、注册、运行副本和临时采样偏移接口已删除，原始测量保留。节点独立消融小于5%门槛、核心子项按组合测量、1秒部分质量配对时间不合格以及冷重建稀疏计时排除等边界，详见 [O0–O2阶段报告](VXPG_O0_O2_RESULTS.md)。默认A/PG缓存关与完整管线保持原语义，未改变采样预算或引入O3后的新算法。

## 旧 PG 移除（2026-10-24）

旧 PG 的 Manager、空间区域/方向树、训练记录、发布过程、采样混合、统计 API、UI、启动开关和 CMake 注册已删除。`Guiding mode` 仅保留 `BSDF` 与 `VXPG`；旧 `PG` 模式与 `enablePG` / `pg*` 属性会报错，外部保存的旧渲染图需删去这些参数并选择现有模式。

普通 PT 和 NRD 的 BSDF 路径直接调用原有材质 `sample` / `evalPdf`；稀疏更新仍服务于 SHaRC 与可选 VXPG 共享注入，保留原训练像素序列。`vxpgPGUseCache` 和 `RTPT_VXPG_PG_SHARC_ENABLED` 属于 VXPG 引导分支的 SHaRC 查询开关，不是被删除的旧 PG 模块，继续保留。

主入口仍为 VeachAjar 的 RayQuery RTPT + SHaRC + NRD → ModulateIllumination → FrameAccumulation → ToneMapper，默认显示 `ToneMapper.dst`，最终累积为 128 帧 Stop。VXPG、SHaRC、NRD、累积和 ToneMapper 的独立开关不变。共享 Material/BSDF 和 Falcor 框架源码未修改。

此前旧 PG 的测试与分析报告、历史 VXPG 对照文档仍是历史记录，不代表当前可运行功能。旧 PG 专项 Python/GPU 测试在此前任务中已删除。项目修改范围遵守根目录 `AGENTS.md`。

本次删除验证：Release 的 RTPT/Mogwai/FalcorTest 构建通过；VeachAjar、640×360、D3D12 debug layer 下完整管线、共享注入、SHaRC 关闭、BSDF、距离 LOD 与纯 PT 共 7 种运行配置通过，输出均有限；旧 API/参数拒绝、各模块关/开、128 帧 Stop 与重置等 28 项检查通过，现有 11 项 VXPG GPU 测试通过。验证记录位于 `build/pg-removal-20261024/summary.json`；运行目录的 6 个旧着色器与旧 PG 对象文件已清理，临时 Python 验证脚本已删除。
