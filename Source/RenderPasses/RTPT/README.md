# RTPT、VXPG、PG、SHaRC 与 NRD

## VXPG 接入与使用

VXPG 已接入普通 PT 和主图的 NRD diffuse/specular 路径，所有求交保持 ComputePass + RayQuery。独立模型包含三角形裁剪的包围体素、当前帧 BRDF 光照注入、128 位可见性描述、MRCS K-means++ 聚类、Morton GPU 排序、簇内树和超像素顶层树。构建及发布不做每帧 CPU 分布读回；窗口中的 Read GPU statistics 会主动读取一次诊断快照。

体素质量为正光照观察的平均值乘包围盒最大面面积。顶层按每个超像素/体素簇的 32 对实际成员估计材质贡献、距离衰减和可见性，并保留 5% 几何重要性正则化；超像素成员收集、前缀和、散射与建树全部在 GPU 上完成。

统一入口仍为根目录 `RTPR_START.cmd`，加载 VeachAjar 和 `scripts/RTPTSHARCNRD.py`，默认输出 `ToneMapper.dst`，保留 SHaRC、NRD、最终 128 帧 Stop 累积和 ToneMapper。交付默认 **VXPG 开启、ShortBranch A、PG 缓存关闭**。完整行为见 [实施计划](VXPG_IMPLEMENTATION_PLAN.md) 和 [接口契约](VXPG_DESIGN_CONTRACT.md)。

CMD 顶部的 `RTPT_GUIDING_MODE` 选择 `BSDF`、`PG` 或 `VXPG`；`RTPT_VXPG_ENABLED=1/0` 控制 VXPG，窗口中对应 **RTPT → Guiding mode** 和 **VXPG → Enabled**。未选中的旧 PG 不采样、不训练，参数保留。VXPG 的 **Use guiding** 只停止采样；**Freeze updates** 停止模型构建；**Reset VXPG** 使模型失效并重建。冻结后改变相机、几何或光照会先回退 BSDF，解冻后恢复。

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

O5.2 **Shared injection** 已接入 `RTPT_VXPG_SHARED_INJECTION_ENABLED=1/0`、属性 `vxpgSharedInjectionEnabled` 和 **VXPG → Shared injection → Enabled**，默认 **0**。开启后 VXPG 使用 SHaRC 原有训练路径的第二表面，默认每 **5×5 像素一条路径**；复用其 BSDF 续接、光源样本和遮挡求交。SHaRC 保留原 MIS 训练值，VXPG 使用自发光加 raw NEE 的正 maxRGB 重要性，二者不共用缓存载荷。全屏 primary position/normal/hit 仍完整生产并用于 VXPG 分布构建，Full 分布和采样/PDF 算法不变。

SHaRC 关闭或冻结时，VXPG 以相同 stride 独立追踪到第二表面，不写 SHaRC；只关闭 SHaRC 查询仍共享更新。VXPG 冻结时停止注入而 SHaRC 继续训练。SHaRC 深度为 1 时，第二表面的额外 raw NEE 使用 RNG 副本，不延长或改写 SHaRC 后缀。共享开关、共享 stride/深度变化会使提议失效并重置图像历史；普通每帧训练不重置历史。该模式改变 VXPG 训练覆盖，不能视为逐位等价优化。V 场景对照和限制见 [O5.2 阶段报告](VXPG_O5_2_RESULTS.md)。

O5.2 的 V 场景 1080p、9 对交错实测：Full/共享整帧 **25.781/26.049 ms**，均值慢 **1.04%**，未见稳定净收益；VXPGInject **0.631/0.289 ms**，但 MainRender **17.614/18.127 ms**。720p、8 秒、3 种子的 raw NMSE 增加 **0.28%**，最终 HDR 基本持平。159 项数值/运行检查通过；共享保持默认关闭。

删除 O5.1 后，按用户要求只在 V 场景复测 O5.2 开/关：1080p 完整主图、9 对交错运行，每种模式 1,152 个 GPU 帧。关闭/开启共享的整帧为 **25.073/25.221 ms**（均值 +0.59%，配对 bootstrap 95% 区间 −1.35%～+2.03%），MainRender **17.112/17.671 ms**（+3.26%），VXPGInject **0.611/0.242 ms**（−60.40%）。未确认稳定整帧收益，默认继续关闭；206 项配置、状态和输出检查通过。本次未重新进行画质误差对照，也不把与旧测试时段的差值归因于删除 O5.1。完整数据在 `build/vxpg-full-after-removal-20261023-001/`，临时脚本已清理。

读取 `vxpgStats` 时先检查 `diagnosticsAvailable`/`diagnosticsStatus` 及 `modelDiagnosticsAvailable`/`modelDiagnosticsStatus`。状态分别为 `disabled`、`unavailable` 或 `current_frame`/`current_update`；活动字段缺失表示未采集或当前无覆盖，**不表示射线数、接受数或缓存命中数为零**。渲染活动只覆盖最近一个有效主渲染帧，由 `diagnosticsFrameCount=1`、sample offset、SPP 和 generation 标识；模型活动只覆盖当前一次实际更新，由 `modelDiagnosticsFrameCount=1` 和更新 frame index 标识。Freeze updates 下，仍渲染时可以得到当前帧的渲染活动，但模型活动为 unavailable，不把冻结前的构建计数当作当前帧；解冻并实际更新后才重新提供。Read GPU statistics 和属性读取会主动读回，性能计时窗口内应避免调用。

参考为 [VXPG 固定提交](https://github.com/SuikaSibyl/SIByLEngine2023/tree/8c1adad28c16e07592bc79122cb9d0c9738699bc)。本项目采用等价的 GPU radix sort 和按 Morton 次序组织的簇堆，使用明确条件化的模糊超像素和正反一致 PDF；并非原 Vulkan 实验代码的逐位移植。细小/远处病态盒子使用保守包围锥，锥外/盒外失败保留空质量。当前支持 RTPT 既有的反射型 StandardMaterial 三角形场景、alpha 纹理、实例变换；skinning/顶点缓存形变尚未验证，明确回退 BSDF，不修改共享框架。

2026-10-22 按用户要求删除 RTPT/VXPG 专项测试：`tests/RTPT/` 下的验证脚本、基准脚本、依赖清单和两个专用场景（共 6 个文件），以及 FalcorTest 的 6 个 `RTPTVXPG*` C++/Slang 文件、对应 CMake 注册和运行目录中的测试 shader 副本。Falcor 通用测试、正式渲染代码、主入口、优化计划及历史性能报告保留。下述 10 项 GPU 测试和脚本运行结果属于删除前的历史证据，相关命令当前不可直接重跑；日常运行继续使用 `RTPR_START.cmd`。

首次复刻的历史验收包括Release构建、10项GPU测试和主图组合回归；当时RTX 5070的VeachAjar 1080p完整图，旧PG/A缓存关/A缓存开/B约15.58/41.14/41.40/36.71 ms，短时raw HDR质量未优于旧PG。该组数字不与后续不同轮测量混用。历史协议、显存、缓存近似、自发光材质连续编辑的共享内存限制见 [验收结果](VXPG_VALIDATION_RESULTS.md)。

2026-10-22完成O0–O2等价优化：默认关闭高频详细计数，复用候选PDF和同一端点q，提前拒绝无效引导命中，拆分PDF-only立体角计算，并在32 B节点内预计算查询几何。RTX 5070、VeachAjar、1080p完整主图、每模式9次运行均值，A缓存关 **43.24→29.96 ms（−30.71%）**、A缓存开 **43.19→30.18 ms（−30.13%）**、B **38.66→27.66 ms（−28.47%）**；720p下降约24%–28%。4秒配对raw HDR NMSE下降约24%–25%，最终NRD图像误差变化较小，不宣称确定改善。当前仍慢于同轮旧PG的约16.79 ms，主要差距仍在MainRender。

本轮7项临时GPU测试在两种节点配置均通过，诊断开/关冻结原图逐位一致，主入口418条生命周期检查和清理后的Release构建通过。临时Python/GPU测试、注册、运行副本和临时采样偏移接口已删除，原始测量保留。节点独立消融小于5%门槛、核心子项按组合测量、1秒部分质量配对时间不合格以及冷重建稀疏计时排除等边界，详见 [O0–O2阶段报告](VXPG_O0_O2_RESULTS.md)。默认A/PG缓存关与完整管线保持原语义，未改变采样预算或引入O3后的新算法。

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

`RTPT.pgStats` 提供区域数、有效模型、节点数、训练帧、发布次数、实际/预留字节、实际 tile、代次、发布耗时和诊断计数。诊断下标：0 请求溢出、1 记录溢出、2 无效数据、3 累计溢出、4 查询、5 guide 分支、6 基础 BSDF 回退、7 guide 边跳过 SHaRC、8 实际训练顶点、9 零权重观测、10 新区域请求、11 完整训练路径、12 无效 PDF。正常模型发布不反复清空 NRD/最终累积；Enabled、采样模式、场景失效或显式 Reset 会重置相关历史。最终累积达到 128 帧后，上游训练继续；Freeze 后可手动 Reset FrameAccumulation 观察固定模型。

高频活动计数 4–11 由 `pgDetailedDiagnostics` 控制，默认关闭；`RTPR_START.cmd` 的 `RTPT_PG_DIAGNOSTICS_ENABLED=1/0` 和窗口 **PG → Detailed diagnostics enabled** 可独立切换。关闭时保留已有活动计数，后续不再增加，不能把这些值解释为当前没有查询或训练。错误计数 0–3、12 始终启用，训练质量、平方和、真实观测数和区域请求写入不受此开关影响。纯诊断切换保留模型、NRD 历史和最终累积。

发布计时以 `publishCalls` 为分母，区别于实际更新 Read 的 `publications`。`totalPublishMs`/`maxPublishMs`/`lastPublishMs` 及 `totalDrainMs`、`totalReadbackMs`、`totalCpuRebuildMs`、`totalUploadMs` 记录 CPU 墙钟时间；传输阶段包含已有 GPU 等待，不额外引入同步。对应 `total*Bytes` 和 `total*Waits` 记录真实传输量和显式等待次数。Falcor Profiler 中另有 `SparseTrace`、`PGPrepare`、`PGTrain`、`SHARCResolve`、`MainRender`、`PGPublishCPU` 分项；发布范围的 GPU 时间包含跨提交的空闲间隔，不能当成纯计算核耗时。性能对照脚本在独立区间采集 profile，避免计时器开销混入吞吐测量。

**明确暂缓，首版完成后需要提醒的三项：LOD 切换迟滞、跨 LOD 旧区域保留、按模型成熟度选择回退模型。** 当前相机位置实际变化会清空 PG 并重训，投影采样抖动不触发。当前只做空/零质量分布的合法 BSDF 路径，不做成熟度评分、父模型选择或成熟度驱动的引导比例。材质、光照、几何变化保守重置 PG。

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

优化版 Release 构建、D3D12 debug layer 下 **5 项 GPU 数值测试与 106 项生命周期检查（216 帧）**通过；覆盖诊断开关/错误保留、训练和请求等价、模块恢复、预算重建、Stop 累积保持，以及 65536 区域配置的多批传输。大表验证实际读回 3 批、上传 3 批，未发生无效样本或记录/累计溢出，预留仍在 64 MiB 内。日志分别为 `build/pg-perf-gpu-tests.xml` 和 `build/pg-perf-validation-02/report.json`。本次未实现 LOD 迟滞、跨 LOD 区域保留或未成熟模型回退。

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

后续优化优先验证**保持运输语义的重复工作复用**：采样返回与实际生成方向一致的 PG 密度，减少紧邻的反向映射/重走树；复用同顶点 BSDF 构造及可证明等价的 PDF 中间量；再检查 map/region/root/node 的依赖读取和布局。指令缓存、PG 与 BSDF 代码共同造成的 stall 不能拆成互斥因果份额，不能直接宣称某个改动能省去 19% 或 22%。改变 guide 边 SHaRC 终止条件需要另行设计和验证其角分布足迹，本轮没有修改。RayQuery 架构、统一入口和模块独立开关均保留；LOD 迟滞、跨 LOD 旧区域保留、未成熟模型回退仍暂缓。

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
