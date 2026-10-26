# RTPT、VXPG、SHaRC 与 NRD

## 当前入口与管线

使用仓库根目录的 [RTPR_START.cmd](../../../RTPR_START.cmd)，加载
[scripts/RTPTSHARCNRD.py](../../../scripts/RTPTSHARCNRD.py) 和
[VeachAjarRTPT.pyscene](../../Data/VeachAjar/VeachAjarRTPT.pyscene)。
架构为 **ComputePass + RayQuery**，D3D12；默认显示 `ToneMapper.dst`。

完整管线：RTPT + VXPG + SHaRC → NRD → ModulateIllumination → FrameAccumulation → ToneMapper。
RTPT 使用 `accumulate=False`，向缓存和降噪提供当前帧信号。最终 HDR 累积由
FrameAccumulation 管理，默认 Enabled、128 帧、Stop、autoReset；0 表示不限帧数。
达到上限后最终图像保持，VXPG、SHaRC、NRD 仍继续更新。普通 PT 的
`maxAccumulationFrames` 属于另一种模式，不是最终图像的累积上限。

主入口的 SHaRC、NRD、FrameAccumulation、ToneMapper 默认启用，保留各自 CMD 1/0
和运行时 Enabled。图中 `enableSHARC=True`、`enableNRD=True` 保持资源连线。
NRD 关闭时传递当前帧信号；SHaRC 的 `sharcEnabled` 控制更新和查询，`sharcUseCache`
只控制查询。影响信号的切换会重置 NRD 历史及最终累积。

## VXPG 固定行为与控制

VXPG 固定使用世界空间稀疏哈希、增量建格、距离 Multi LOD、普通相机移动复用、
光照重要性历史、历史置信度、相邻 LOD 历史借用和局部树更新。
成员改变时重建，成员不变时更新权重；周期刷新、场景失效、手动重置和预算回退保留。
**Visibility 固定开启**，簇内排序/建树只有 **Radix + Heap**，每次模型更新都维护簇树和屏幕分布。
CMD、UI、序列化参数和 GPU 参数中的 Visibility 开关均已删除，旧 `vxpgVisibilityEnabled` 属性会被拒绝。
首个着色点使用有效的屏幕条件分布；bounce 1 和无有效屏幕条件行时仍使用全局树，保持原开启路径的采样与 PDF 规则。
全局树因此继续保留；它不是可选的 Visibility 关闭模式。VXPG 总开关、冻结及无效模型 BSDF 回退仍有效。

**Shared injection 固定启用多反弹共享，没有独立开关。** VXPG 本帧可训练时一定运行稀疏多反弹训练。
SHaRC 正常更新时共用同一批路径；SHaRC 关闭或冻结时仍运行 VXPG 训练，只停止 SHaRC 写入。
训练步幅/深度继续使用配置的 SHaRC Update 参数。VXPG 关闭、冻结或资源准备失败时停止
VXPG 写入；内部 `writeSHARC` / `writeVXPG` 是本次调度的有效写入目标，不是可选模块开关。

主入口 VXPG 参数：

- `RTPT_GUIDING_MODE=VXPG`；可选 BSDF / VXPG。`enableVXPG` 控制图资源，`vxpgEnabled` 控制运行时启用。
- `RTPT_VXPG_ENABLED=1`；运行时还保留 Use guiding、Freeze updates 和 Reset VXPG。
- `RTPT_VXPG_PG_SHARC_ENABLED=0`、`RTPT_VXPG_DEBUG_ENABLED=0`、
  `RTPT_VXPG_DIAGNOSTICS_ENABLED=0`，各有运行时控制。
- Discovery stride 5，空间寿命 512 次更新，拓扑刷新周期 16 次更新。
- 光照历史窗口 32，历史寿命 128 次更新。有效零观测会更新历史，缺测不等于零；冻结暂停老化。
- LOD scene scale 8，hash capacity 65536，geometry capacity 8192，模型预算 256 MiB。

以上是主入口预设；C++ Settings 的通用默认值保持原样。旧稠密/固定稀疏/三角形建格、
LBVH、Bitonic 及已删除的六项优化均未恢复。无效提议继续回退 BSDF。

## 代码导航

VXPG 专用实现集中在 [VXPG](VXPG) 目录，仍只有一个 `RTPTVXPG::Manager`。
内部资源按网格、光照历史、采样树、屏幕数据分组；这些是代码职责，不新增功能开关。

- [RTPTVXPG.cpp](VXPG/RTPTVXPG.cpp)：生命周期、失效处理、GPU 更新阶段和发布顺序。
- [RTPTVXPGResources.cpp](VXPG/RTPTVXPGResources.cpp)：资源创建/初始化、释放、预算与着色器绑定。
- [RTPTVXPGSettings.cpp](VXPG/RTPTVXPGSettings.cpp)：属性解析/导出、校验、变化分类与参数 UI。
- [RTPTVXPGDiagnostics.cpp](VXPG/RTPTVXPGDiagnostics.cpp)：计数器读回、统计属性、结构快照和诊断显示。
- [RTPT.cpp](RTPT.cpp)：主渲染、共享训练、SHaRC/NRD/累积联动，以及 Python 接口转发。

UI 生成参数补丁，与脚本共同经过 `RTPT::setProperties()` 的候选参数校验和统一应用。
`compareSettings()` 分类 VXPG 参数的影响；RTPT 决定跨模块刷新，Manager 按最强影响统一处理模型内部失效。
`RuntimeContext` 只传递选中模式、训练状态和诊断帧信息，诊断层不依赖整个 RTPT 类。

Pass 统一通过 `createPass()` 创建，显式声明是否需要场景、采样器及当前诊断配置。
直接/间接调度统一绑定 VXPG 参数及 Shader 实际需要的场景数据；入口专用参数、采样器绑定、
GPU barrier 和间接参数缓冲复制仍写在各阶段内部，保持执行依赖可见。

Shader 的职责：

- `Types.slang`：参数、数据布局和资源声明；`Diagnostics.slang`：可编译关闭的活动计数。
- `Grid.slang` / `Incremental.cs.slang`：距离 LOD、空间查询与增量网格维护。
- `Training.slang` / `Observation.slang`：共享训练与观测记录；`History.slang` / `HistoryResolve.slang`：历史公式与 GPU 解析。
- `Prepare.cs.slang` / `Local.cs.slang` / `Tree.cs.slang` / `Distribution.slang`：全局树、局部更新、簇树和公共概率规则。
- `Primary.cs.slang` / `Visibility.cs.slang` / `Debug.cs.slang`：主表面数据、聚类/屏幕分布与调试输出。
- `Sampling.slang` / `Geometry.slang` / `Math.slang` / `Integrator.slang`：采样、反向 PDF、接受判定和渲染接入。

以上 Shader 名称均带 `RTPTVXPG` 前缀。计算入口不互相包含；公共历史解析通过
`HistoryResolve.slang` 共享。正向采样与反向 PDF 共用概率计算，保留概率边界修复。

## 每帧顺序与不变量

1. 准备资源、清本帧观测、标记过期网格，并保存上一帧历史/法线。
2. RTPT 调度固定的 Shared injection；已有 cell 直接累积，缺失 cell 记录待回放观测。
3. 生成当前帧主表面 position/normal/hit。此阶段不是单独的光照注入路径。
4. 网格 discover → insert → replay，只回放原先未写入的观测。
5. 解析历史及置信度，判断成员变化，建立或更新全局树。
6. 局部权重更新，固定更新 Visibility 的 Radix + Heap 簇树和当前帧屏幕分布。
7. 发布完整提议，再回收旧 cell ID；主渲染查询已发布模型。

Visibility 的编排入口只串联四个阶段：`updateVisibilityClusters()` → `sortClusterVoxels()` →
`buildClusterForest()` → `updateScreenDistribution()`。排序阶段返回最终缓冲，建树阶段显式接收它；
各阶段保留原有 profiler 区间和同步顺序。

普通相机移动保留世界空间状态，屏幕相关分布持续更新。冻结后移动导致屏幕提议失效时，
使用 BSDF，解除冻结后恢复。借入的 LOD 历史不能再次作为供体；采样到源体素是空事件，
不能重试或重新归一化。GPU barrier、间接调度参数和随机数消费顺序属于这些阶段的契约。

## 失效与恢复

模型失效统一经过 `Manager::invalidate()`，范围从小到大包含前一层的影响：

- `Proposal`：停止使用当前提议，保留网格和光照历史；用于空间寿命、拓扑周期和视图变化。
- `LightingHistory`：同时清理光照历史；用于训练配置或历史参数变化。
- `Grid`：同时重建空间网格、重置训练帧索引，保留可复用的资源；用于手动重置和场景失效。
- `Resources`：同时释放模型资源；用于布局、容量、分辨率变化及预算回退。

多项参数同时修改时只应用最强范围。已发布或已准备训练的模型失效时推进一次 `generation`；
已经失效的模型收到重复通知不再推进，但更强的历史、网格或资源清理仍然执行。
正常模型更新继续推进代次，因此它表示模型身份，不表示失效通知的数量。

`RTPT::updateSceneState()` 集中处理场景和相机事件，RTPT 继续负责 SHaRC、NRD 和最终累积的刷新。
普通相机移动保留网格与 NRD 历史；投影变化重建提议并重置图像历史；冻结时视图改变回退 BSDF。
相机通知使用当前请求的 Freeze 状态，覆盖同一帧开启冻结并转向的情况，不读取上一帧尚未同步的配置。
光照、材质、几何等场景变化沿用既有保守网格重建策略。诊断、Debug 和 Freeze 开关本身不清理模型或图像历史。

## 诊断与验证

`RTPT.vxpgStats` 保留现有属性；关闭详细诊断时缺失的活动字段表示 unavailable，不是零。
`RTPT.vxpgTreeSnapshot()` 或 UI 的 Read Morton / tree snapshot 只在显式请求时读回，
需要 Detailed diagnostics Enabled 和有效簇模型。快照版本 2，`treeType=Heap`、`sortBackend=Radix`。
这些接口不进入普通帧的 CPU 读回路径。

RTPT/VXPG 专项测试已按用户要求删除，本次重构不恢复它们。交付验证使用统一入口配置，
覆盖静止累积、移动复用、开关恢复、共享训练、冻结、预算回退及诊断；本次临时验证脚本完成后清理。
2026-10-26 重构验证：Release 的 RTPT/Mogwai 构建成功，VeachAjar 上 82 项运行检查通过，
包含 1080p 的 128 帧 Stop、普通相机移动及奇数分辨率诊断。128 个 Shader 函数体保持不变。
这是行为与结构验证，不是性能基准；运行验证通过无窗口脚本进行，未手动操作 GUI。
本地结果与日志索引见 [验证摘要](../../../build/vxpg-refactor-20261026/verification-summary.json)。

同日的 Visibility 阶段拆分与 Pass 调度重构另通过 52 项运行检查，覆盖完整管线、五种调试视图、
冻结/诊断切换、共享训练、资源重新分配及场景重载。47 个 Pass 的入口和编译配置、59 处资源分配配置
保持一致；Shader 文件未修改。见 [调度重构验证](../../../build/vxpg-dispatch-refactor-20261026/verification-summary.json)。

后续状态失效重构保留了重构前 69 项行为检查，并通过最终版本的 111 项运行检查。
组合参数变化只使模型失效一次，冻结移动后不再反复增加代次；更强的资源重建请求仍生效。
另复现并修复了同帧开启冻结与相机转向时读取旧冻结状态的问题，覆盖冻结、解除冻结及投影变化。
主入口 1080p 的 128 帧 Stop、NRD/最终累积重置及诊断切换均通过。
见 [状态重构验证与前后对照](../../../build/vxpg-state-refactor-20261026/verification-summary.json)。

固定 Visibility 后，Release 的 RTPT/Mogwai 构建通过，D3D12 debug layer 下合计 80 项运行检查通过。
覆盖旧属性 true/false 拒绝、1080p 完整管线与 128 帧 Stop、321×181 屏幕分布、Radix/Heap 快照、
五种调试视图、SHaRC 关闭/冻结时的独立训练、相机复用、冻结恢复、VXPG 总开关及参数调整和重置。
采样概率、MIS、聚类、排序、建树和共享训练算法保持原样；临时验证脚本及依赖已清理。
见 [固定 Visibility 验证](../../../build/vxpg-fixed-visibility-20261026/verification-summary.json)。
历史实验、已删除功能与旧测试数量见 [历史记录](README_HISTORY.md)，不代表当前可用功能。
