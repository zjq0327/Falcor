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

## 局部光源采样与显示

主入口接入独立的 LocalLights 模块。`RTPT_LIGHT_GRID_ENABLED`、
`RTPT_LIGHT_TILE_ENABLED`、`RTPT_LIGHT_TILE_ADAPTIVE_ENABLED` 默认 1；
`RTPT_LIGHT_GRID_CDF_ENABLED`、`RTPT_LIGHT_GRID_PERSISTENT_ENABLED` 默认 1，
分别控制格内 CDF 查找与跨帧格子复用。
Light Grid 固定使用全量分布，`RTPT_LIGHT_GRID_RESOLUTION=16` 控制最大轴格数；
窗口中 `Light Grid → Maximum grid axis` 可调。旧稀疏 Grid、后端切换、
Global 混合比例、哈希容量、每格灯数上限、影响半径和未使用格寿命均已删除。
`RTPT_LOCAL_LIGHT_DEBUG_ENABLED`、`RTPT_LOCAL_LIGHT_OVERLAY_ENABLED` 默认 0。
窗口中 `RTPT → Local light sampling` 提供对应 Enabled、参数和 Inspector；
`Light Grid → CDF sampling → Enabled` 与 `Light Grid → Persistent cache → Enabled`
可以独立切换，两者都依赖 Light Grid 总开关。
`LocalLightOverlay` Pass 有独立 Enabled 与透明度。原有 VXPG、SHaRC、NRD、累积和后处理控制保留。

直接查看 `RTPT.localLightDebug` 可绕过 NRD 与最终累积；查看 `LocalLightOverlay.output`
可在 ToneMapper 后叠加诊断。默认输出仍是 `ToneMapper.dst`。诊断模式包括 Grid 候选数量、
Grid Cell、Tile 边界、真实 LightKey、真实采样来源、遮挡结果、历史有效性和年龄。
原有模式 0–7 保留；模式 8 为 Grid cache state（橙色为本帧重建、绿色为复用、灰色为不可用，
洋红色为类别无效），模式 9 为 Grid cache build age。建表年龄按 256 帧归一化显示；
不表示到期倒计时，静态格子可长期复用。
选定 Inspector X/Y 后点 Capture selected pixel，可读取该帧实际选灯的 PMF/PDF、
Grid/Tile、候选权重及版本；不会重新采样或额外追踪阴影射线。未测试可见性的合法空事件
与真正遮挡分别显示。采样来源蓝/绿/橙对应 Global/Grid/Tile；可见性绿/红/黄对应
可见/遮挡/未测试。切换显示、选点或读取快照不会重置渲染历史。

`PrimarySurface/` 统一生成当前帧位置、面法线/粗糙度与 HitInfo，使用与主渲染一致的
相机和绝对 sample index。VXPG 在原有更新位置复制到自己的模型快照，冻结时保持该快照；
LocalLights 继续使用当前视图，因此不依赖 VXPG 或 SHaRC 是否启用。

`LocalLights/` 管理世界空间 Light Grid、32/16/8 像素 Tile、重投影历史与探测反馈。
唯一的 **Full-CDF** 在场景几何包围盒上一次构建完整三维规则网格。每格包含当前
Falcor LightCollection 全部活跃发光三角形，以及 Scene 全部启用的解析灯（包含 Directional / Distant）；
Grid 外的有限查询位置钳制到边界格。位置、包围盒和功率仅影响重要性权重，不用于硬剔除。
零估计、极暗和远灯仍分配正概率；没有每格灯数、catalog 扫描上限或影响半径裁剪。
天光继续由原 EnvMapSampler 单独采样。

每个非空类别以 `2^24` 个整数区间表示概率，每灯至少一个区间，剩余区间按重要性分配。
CDF 二分查找、线性查找和 PMF 求值读取同一份量化分布，PMF 是实际整数区间宽度除以 `2^24`。
CDF 关闭时存储区间宽度并线性扫描，完整性不变。
Tile/Grid 分支选择与 Grid 区间选择使用独立随机数，
防止 24-bit 分支重映射跳过最小区间。索引顺序复用共享 catalog，不为每格复制 Light ID 与 float 原始权重。
每格每灯只需 4 字节，另有每格 48 字节元数据和每灯 32 字节热描述符。

正常主表面在有有效 Tile 时使用 `75% Tile + 25% Full Grid`，无 Tile 时使用 `100% Full Grid`；
次反弹、训练和 Probe 使用 `100% Full Grid`，**正常 Global 份额为 0**。
这里的 Global 指独立的全灯抽样分支；完整的源灯目录继续用于建表和着色。
因此主表面的类别内最小选灯 PMF 至少为 `1/(4*2^24)`；无 Tile 时至少为 `1/2^24`。
最终 NEE PDF 还包含类别概率与灯面几何密度。所有分支对同一 LightKey 的概率相加后用于除权。
完整 Grid 不可用、类别与 catalog 不匹配或资源准备失败时，整个查询回退 Global，避免只剩截断的 Tile。
主动关闭 Grid 时使用 100% Global；Tile 保留配置，但需有效 Grid 才参与采样。重新开启 Grid 后恢复原 Tile 配置。

预算不足时逐步减少网格分辨率，保留所有灯；最小一格与 Tile/历史仍无法容纳时回退 Global。
每类别超过 `2^24` 盏灯也回退，避免承诺无法表示的最小概率。全量 CDF 的显存随格数乘灯数增长，
降低分辨率会减弱空间重要性的精度，不会减少灯的支持域。
只启用 Full Grid 而 Tile/Debug 均关闭时，Grid 自身不要求生成 PrimarySurface；其他模块仍可独立要求主表面。
Persistent 关闭后每帧重建；开启时静态世界格子直接复用，相机移动不重建。
光源集合、能量、变换、发光几何和采样配置变化会重建并重置相关历史和最终累积。
准备阶段完成更新后，训练、Probe 和主渲染读取同一帧冻结的概率模型。

每帧在准备阶段重投影历史，并用独立随机流的稀疏 Probe 探索局部光源，然后发布只读采样分布。
之后执行共享训练和主渲染；主渲染反馈写入另一组资源，下一帧使用。
NRD 的 diffuse/specular 共用一次选灯和阴影测试，反馈只合并记录一次。
为保持现有 SHaRC 缓存目标一致，实际采样 PDF 与旧全局 MIS 参考 PDF 分开存储；
NEE 和命中发光面的互补 MIS 使用同一参考分布，实际估计仍按真正的混合采样 PDF 除权。
天光仍沿用原 EnvMapSampler，本次功能针对局部光源。

历史采用有界反馈的加权替换与同光源均值更新，用于学习提议分布，不是完整的 ReSTIR reservoir
估计器。模型预算约束 Grid、Tile 和历史；PrimarySurface 与可单独增删的 Debug 纹理另计，
`localLightStats.resourceBytes` 统计 LocalLights 实际总分配，`primarySurfaceBytes` 单独报告主表面。

Python 提供只读 `RTPT.localLightStats` 和显式 `RTPT.captureLocalLightInspection()`；
后者只按请求读取 2032 字节快照，常规帧不做 CPU 读回。快照保留旧布局前 122 个 uint4，
额外记录所选格子的缓存代次和建表年龄，以及每类别前 16 个候选的
`float4(integerBins, cdfLo, cdfHi, gridPmf)`；CDF 关闭时区间为 -1，不能当作有效 CDF。
实际事件灯即使不在前 16 项中，也单独提供同一组 Grid 数值。Grid PMF 只描述 Grid 分支，
最终估计仍使用所有选灯分支相加后的类别内混合 PMF。

开启 Debug 时，GPU 遍历所有格子/所有灯，核对正区间、类别归一化与发布代次；
`fullGridSupportAudit` 返回检查格数、无效格数、区间错误数、检查条目数。
`queryBranchCounts0..3` 分别返回主表面/次反弹/训练/Probe 的 Global、Grid、Tile 实际选择次数。
这些审计和原子计数只在 Debug 开启时执行，正常采样不增加 CPU 读回。
`gridResourceBytes` 单列 Grid 实际分配，`fullGridDimensions` 与 `fullGridBudgetReduced` 报告预算降级。

显式快照同时读取本帧 GPU 建格、复用和查询计数。
`gridCellReuseRatio` 为 reused/(built+reused)，是格子级复用率，不是射线查询命中率。
Debug 开启时另统计实际选灯路径的 Grid 查询与缺格次数，`gridQueryMissRatio` 仅描述缺格，
不等于全部 Global 回退比例；Inspector 的 PMF 求值不增加这些查询计数。
纯 PT 内建累积达到上限时诊断仍可
刷新，保持已累积颜色，不再训练提议或推进反馈历史。实现不修改共享 Material/BSDF，也不引入 DXR RT Pipeline。

### LocalLights 专项测试已删除（2026-10-27）

LocalLights 的专项 GPU 测试、测试着色器、验证与基准脚本、专用场景及 FalcorTest 注册已移除。
以下保留删除前的验证和测量记录；对应的专项测试与采集命令不再提供，历史报告和图像继续保留。
正式渲染实现、运行时 Debug/Inspector 与主入口不受影响，日常运行继续使用 `RTPR_START.cmd`。
删除后 FalcorTest Release 重建通过；D3D12 用例枚举中 RTPT/VXPG 专项为 0，215 个通用用例保留。

### 仅保留新 Grid 的历史验证（2026-10-27）

旧后端及其专用资源/测试已删除，主入口、UI 与序列化不再包含后端选择或 Global 比例。
Release RTPT/FalcorTest 构建、1 项生产整数 CDF GPU 测试、294 条真实渲染图运行检查通过。
覆盖主管线、无 PrimarySurface 的纯 Grid、冷首帧灯光停用/恢复、发光类别移除/恢复、
CDF/线性、Persistent、Tile/Adaptive、Debug 切换，以及预算降分辨率和整模型回退/恢复。

VeachAjar、256×144、seed=1：删除前后纯 PT 的 16/64/128 帧 HDR 图像逐像素一致。
完整管线 128 帧 HDR 均值差 −0.096%，相对 RMSE 0.993%；含时序缓存的结果不要求逐像素一致，
单 seed 对照不构成无偏证明。1920×1080 完整管线在热身 160 帧、3×32 帧下，
GPU 整图时间中位数为 27.85 → 27.87 ms（93 个有效样本，约 +0.07%），未观察到明显性能变化。
Grid 逻辑缓冲统计由 28,876 → 28,832 字节，仅少了旧路径的占位缓冲，不代表进程驻留显存有明显变化。

见 [本次验证汇总](../../../build/new-grid-only-validation/summary.json)。

### Full-CDF 改造历史验证（2026-10-27，删除旧后端之前）

Release 构建通过，RTX 5070 / D3D12 debug layer 上 8 项 GPU 测试与 917 条运行断言通过。
覆盖 76 盏解析灯（含极远暗灯、零强度、Directional、Distant）、每格全部区间的正概率审计、
四类查询来源、首帧/目录变化、相机复用、CDF/线性与 Persistent/Tile/Adaptive 开关，
以及预算降分辨率、整模型 Global 回退和恢复。正常查询的 Global 次数为 0；
次反弹、共享训练与 Probe 的 Tile 次数为 0。旧的每格灯数/catalog/半径限制设为极小值后，
Full 模式仍保留全部灯。源码与运行目录的 17 份局部灯光 Shader 已逐一核对一致。

1920×1080 完整管线，热身 160 帧、3 轮 × 32 帧，Profiler GPU 整图时间中位数：
VeachAjar 旧 Grid+Tile 为 33.47 ms，Full Grid+Tile 为 27.85 ms（下降 16.8%）；
32 点灯场景为 42.16 → 39.57 ms（下降 6.1%）。Global 基线分别为 30.83 / 36.19 ms，
因此 Full 模式的收益随场景变化；多灯场景仍慢于 Global。单独完成批次的墙钟时间另存，
不将 GPU 时间解释为应用 FPS。Full 与旧后端分别编译，避免通用热路径携带两套实现的额外开销。

多灯 1080p 的 Grid 缓冲为 6.313 → 0.091 MiB，LocalLights 全部分配为
36.124 → 29.903 MiB（下降约 17.2%）；仍由 VXPG 使用的 PrimarySurface 为 101.25 MiB。
这些统计累加模块缓冲/纹理的分配量，整进程驻留显存还包含其他模块与驱动资源。
只启用 Full Grid 的纯 PT 对照已确认 `primarySurfaceBytes=0`、模型有效且输出有限。

正式画质矩阵为两种场景、纯 PT/完整管线、三 seed（1/7/19）、16/64/128 帧；
另有两种场景各两份独立 2048 spp Global PT4 参考。保留 46 个无损图像归档与 67 个采集案例。
128 帧时，纯 PT 新旧 HDR 方差在约 ±1% 内，平均亮度差约 0.15–0.17%；
完整管线 HDR 方差分别下降约 10.0% / 4.7%，平均亮度差约 +0.59% / −0.32%。
三 seed 仅为粗略估计，有限噪声 PT4 参考不作为完整管线真值，也不构成严格无偏证明。

长批次反复重载场景后曾发生 E_OUTOFMEMORY；失败批次排除，受影响的矩阵按每模式/seed
独立进程重跑并全部完成。`RTPR_START.cmd` 已实际启动，窗口确认 `ToneMapper.dst`、
FrameAccumulation Enabled / Auto Reset / Max Frames=128 / Stop / 128 帧完成，并显示 Full-CDF 模式。
嵌套 ImGui 树未能通过自动输入展开，因此窗口中的逐个复选框点击未声明通过；
开关的关闭/恢复由真实渲染图 `set_properties` 回归验证。默认模块值未在窗口中更改。

见 [完整汇总](../../../build/full-cdf-grid-validation/summary.json)、
[画质、误差和实际图像](../../../build/full-cdf-grid-validation/report/summary.json)、
[1080p 阶段耗时](../../../build/full-cdf-grid-validation/report-1080/summary.json)、
[主入口累积状态](../../../build/full-cdf-grid-validation/ui/main-entry-accumulation.png)。

以下是旧稀疏 Grid 的历史验证，不代表 Full-CDF 的性能。

此前 LocalLights 初版的 Release 构建、763 帧/145 项功能检查，以及主入口配置的 1080p、139 帧/22 项检查通过。
以下初版记录不覆盖新增的 CDF 与持久 Grid；新增路径的验证见本节后续记录。
覆盖全局基线、Grid/Tile/Adaptive/Debug/Overlay 独立切换、预算与容量回退、相机/分辨率/seed、
无场景、纯 PT 持帧及完整管线 128 帧 Stop；停止最终累积后采样模型和 SHaRC 仍继续更新。
已实际运行 `RTPR_START.cmd` 并检查窗口，默认输出为 `ToneMapper.dst`。
两个 seed、256 spp 的多灯纯 PT 对照中，引导/全局平均亮度差为解析灯 +0.069%、面光源 −0.028%，
处于 seed 波动范围；这不是严格无偏性的数值证明或性能基准，也不保证 VeachAjar 单灯场景加速。
本机 1080p 的分配统计为 LocalLights 约 34.1 MiB、PrimarySurface 约 101.3 MiB，VXPG 仍保留独立快照。
临时验证脚本与场景已清理。见 [完整验证报告](../../../build/local-lights-validation/local-lights-verification-summary.json)、
[实际四视图](../../../build/local-lights-validation/local-light-veach-views.png) 和
[主入口窗口](../../../build/local-lights-validation/main-entry-window.png)。

下述历史画质/耗时数据由现已删除的专项采集工具生成。many 测试场景为原 VeachAjar 加
32 个非均匀点光源，保留原发光面，与旧 96 灯合成基准不同。采集时保留主图连线；
纯 PT 对照关闭 VXPG/SHaRC/NRD，完整管线保留这些模块并使用最终累积 128 帧 Stop。
无损 NPZ 图像与 JSON 报告继续保留；GPU 时间来自 Profiler 时间戳，墙钟批次在两端等待 GPU 完成。
Global PT4 双参考仅用于纯 PT 误差及参考噪声底估计，完整管线只比较多 seed 噪声和可视结果。

2026-10-27 的 CDF / 持久 Grid 版本已通过 Release 的 RTPT、Mogwai、FalcorTest 构建。
RTX 5070 / D3D12 debug layer 上 7 项生产 Shader helper GPU 测试及 1153 条运行断言通过。
运行断言涵盖 CDF 区间和实际混合 PMF、哈希碰撞/退役/重插、同 Tile 跨多个 Cell、
Grid 缺失或溢出时的 Tile 回退、光照失效，以及 Grid 实际开启时 CDF / Persistent 四组合。
Grid / Tile 关闭时，CDF / Persistent 四组合的纯 PT 图像逐像素一致。
阶段 A / B 的 31 / 122 条检查单独保留为历史记录，不重复计入上述 1153 条。
原始报告、硬件证据与校验值见 [当前自动验证汇总](../../../build/local-light-cdf-validation/summary.json)。

同版本正式画质矩阵已完成：256×144、三 seed、16 / 64 / 128 帧，纯 PT 六种模式及完整管线四种模式，
两种场景共 42 个采集进程、64 个无损图像归档，另含各场景两份独立 2048 spp 纯 PT 参考。
本组场景中 CDF 与线性 Grid 的画质基本相同；持久 CDF 在多灯纯 PT 的 GPU 图耗时为 0.305 ms，
线性 Grid + Adaptive Tile 为 0.317 ms，Global 为 0.170 ms。
完整管线多灯的持久 CDF / 线性 / Global 则为 1.827 / 1.810 / 1.532 ms。
这些是开启 Profiler 的 GPU 图时间，不是应用 FPS；独立完成批次墙钟也保留在报告中。
128 帧多灯纯 PT 的持久 CDF HDR 方差约为 Global 的 0.977，完整管线约为 0.893，
显示空间的差异更小；三 seed 仅提供粗略估计，本次结果不支持明显的整体加速或收敛收益。
误差曲线采用有限噪声参考，不作严格无偏证明；近似同 GPU 预算图使用帧数乘稳态耗时，
排除冷启动和编译，不能解释为实际冷启动等墙钟时间测试。
见 [画质/阶段耗时/复用诊断与实际图像](../../../build/local-light-cdf-comparison/report/summary.json)。

默认 1920×1080 的完整管线另完成 8 组稳态计时（热身 160 帧，3 轮，计时 seed=1）。
VeachAjar 的 Global / 线性 Grid+Tile / CDF 每帧重建 / 持久 CDF 为
29.49 / 31.59 / 32.13 / 32.30 ms；32 点灯场景为 34.85 / 39.97 / 40.24 / 40.73 ms。
这里都是完整 RenderGraph 的 GPU 时间中位数，1080p 没有另采画质矩阵。
多灯持久化将 LocalLightPrepare 从 0.235 降至 0.206 ms，但整图没有因此加速，
MainRender 的完整路径工作仍占主要耗时。当前数据不支持优先增加复杂的并行建表或候选池；
后续优化应先隔离主渲染查询与请求维护的成本，不能将 MainRender 全部归为选灯开销。
见 [1080p 完整计时](../../../build/local-light-cdf-comparison-1080/report/summary.json) 与
[紧凑耗时图](../../../build/local-light-cdf-comparison-1080/report/timing-overview.png)。

已实际通过 `RTPR_START.cmd` 打开窗口验证：默认 VeachAjar、`ToneMapper.dst`、NRD Enabled、
FrameAccumulation Enabled / Auto Reset / Max Frames=128 / Stop / 128 帧完成均保留。
CDF 与 Persistent 默认启用，分别关闭和重新开启后画面重新累积；Grid、Tile、Adaptive 开关保留。
新增 Grid cache state 和 Grid cache build age 两个视图均已在窗口中实际显示。
结束时恢复 CDF / Persistent / Grid / Tile / Adaptive 启用、Debug 关闭、`ToneMapper.dst` 正常输出。
见 [窗口验证记录及截图索引](../../../build/local-light-cdf-validation/main-entry-ui.json)。

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

**PG SHaRC 固定开启，没有独立 CMD、UI、序列化或 GPU 参数开关。** PG 命中始终尝试符合资格的
SHaRC 配对缓存查询，仍服从全局 `sharcEnabled` / `sharcUseCache`；反弹深度、粗糙度、
射线段长度及材质资格检查保留。缓存缺失、样本不足或配对记录无效时，PG 分支计算真实局部光照后结束。
局部光照保持 BSDF/PG 的 p/q 权重分配；后续间接光仅在 PG 确实能读取有效缓存时分配给 PG，
否则完整保留给 BSDF 后续路径，避免重复计光或遗漏。旧 `vxpgPGUseCache` 属性会被拒绝。
详细诊断开启时，只读 `vxpgStats.pgCacheHits` 报告本帧实际 PG 缓存命中数。

主入口 VXPG 参数：

- `RTPT_GUIDING_MODE=VXPG`；可选 BSDF / VXPG。`enableVXPG` 控制图资源，`vxpgEnabled` 控制运行时启用。
- `RTPT_VXPG_ENABLED=1`；运行时还保留 Use guiding、Freeze updates 和 Reset VXPG。
- `RTPT_VXPG_DEBUG_ENABLED=0`、`RTPT_VXPG_DIAGNOSTICS_ENABLED=0`，各有运行时控制。
- Discovery stride 5，空间寿命 512 次更新，拓扑刷新周期 16 次更新。
- 光照历史窗口 32，历史寿命 128 次更新。有效零观测会更新历史，缺测不等于零；冻结暂停老化。
- LOD scene scale 8，hash capacity 65536，geometry capacity 8192，模型预算 256 MiB。

以上是主入口预设；C++ Settings 的通用默认值保持原样。旧稠密/固定稀疏/三角形建格、
LBVH、Bitonic 及已删除的六项优化均未恢复。无效提议继续回退 BSDF。

## 代码导航

VXPG 专用实现集中在 [VXPG](VXPG) 目录，仍只有一个 `RTPTVXPG::Manager`。
内部资源按网格、光照历史、采样树、屏幕数据分组；这些是代码职责，不新增功能开关。

资源尺寸通过 `ResourceDimensions` 统一派生，创建缓冲与预算估算共用体素、哈希、树、屏幕和观测容量。
各组提供 `release()`、`bind()` 和 `getPayloadBytes()`；Manager 只协调四组绑定并汇总实际分配字节数。
每组用一份 `forEachResource()` 清单维护资源名与成员的对应关系，绑定和显存统计共用清单。
间接调度副本及排序临时缓冲也参与统计，但不增加公共绑定；各阶段继续显式绑定自己的临时资源。
统计保留缓冲 `getSize()` 与纹理 `getTextureSizeInBytes()` 的口径，空资源贡献零，不进行 GPU 读回。
完整释放时一起清理 GPU 对象与已分配尺寸；View 保留当前分辨率的驱动分配估算缓存。
预算仍使用含驱动对齐和安全余量的原有保守估算，与实际分配字节数分别管理。
`ensureTrainingResources()` 按组协调光照、提议树和主表面纹理的创建，历史清零与局部树初始化各有独立入口。
`ensureVisibilityResources()` 协调簇树与屏幕资源；两处仍使用原有联动重建条件。
Pass 创建与缓冲创建分开，`resetTrainingPasses()`、`resetClusterPasses()`、`resetScenePasses()` 明确各类依赖。
重建范围继续由 `compareSettings()` 和 `invalidate()` 决定，预算公式、分辨率变化后的重建范围及冻结恢复规则保持原样。

- [RTPTVXPG.cpp](VXPG/RTPTVXPG.cpp)：生命周期、失效处理、GPU 更新阶段和发布顺序。
- [RTPTVXPGResources.cpp](VXPG/RTPTVXPGResources.cpp)：资源创建/初始化、释放、预算与着色器绑定。
- [RTPTVXPGSettings.cpp](VXPG/RTPTVXPGSettings.cpp)：属性解析/导出、校验、变化分类与参数 UI。
- [RTPTVXPGDiagnosticData.h](VXPG/RTPTVXPGDiagnosticData.h)：诊断使用的 CPU 快照与解释结果，不持有 GPU 资源。
- [RTPTVXPGReadback.cpp](VXPG/RTPTVXPGReadback.cpp)：显式读回入口、可用性检查与快照采集。
- [RTPTVXPGDiagnostics.cpp](VXPG/RTPTVXPGDiagnostics.cpp)：纯 CPU 的观测统计、LOD 计数及树结构/屏幕上下文分析。
- [RTPTVXPGDiagnosticsFormat.cpp](VXPG/RTPTVXPGDiagnosticsFormat.cpp)：将快照转换为 Python 属性、树 JSON 和 UI 文本。
- [RTPTVXPGDiagnosticsUI.cpp](VXPG/RTPTVXPGDiagnosticsUI.cpp)：Python API 与诊断按钮适配，缓存并显示最近一次读取的文本。
- [RTPTVXPGLayout.slangh](VXPG/RTPTVXPGLayout.slangh)：CPU 与 Shader 共用的状态槽位、计数器、错误位、间接调度偏移和缓冲字数。
- [RTPTVXPGResources.slang](VXPG/RTPTVXPGResources.slang)：公共 GPU 资源声明及训练、构建、查询阶段的读写约定。
- [RTPT.cpp](RTPT.cpp)：主渲染、共享训练、SHaRC/NRD/累积联动，以及 Python 接口转发。

UI 生成参数补丁，与脚本共同经过 `RTPT::setProperties()` 的候选参数校验和统一应用。
`compareSettings()` 分类 VXPG 参数的影响；RTPT 决定跨模块刷新，Manager 按最强影响统一处理模型内部失效。
`RuntimeContext` 只传递选中模式、训练状态和诊断帧信息，诊断层不依赖整个 RTPT 类。
诊断读回保留 Python 统计与 UI 按钮各自原有的读取范围；普通帧和未点击的 UI 不采集 GPU 快照。
树快照先读取并验证结构，再读取屏幕上下文，结构无效时提前返回。格式化层只消费 CPU 数据，
不触发额外读回；树摘要直接使用解释后的数据，不再先生成完整 JSON 再解析为 UI 文本。

Pass 统一通过 `createPass()` 创建，显式声明是否需要场景、采样器及当前诊断配置。
直接/间接调度统一绑定 VXPG 参数及 Shader 实际需要的场景数据；入口专用参数、采样器绑定、
GPU barrier 和间接参数缓冲复制仍写在各阶段内部，保持执行依赖可见。

CPU 绑定分为三个入口：`bindTraining()` 为共享训练绑定观测写入目标，帧索引由 Manager 提供；
`bindRendering()` 为主渲染绑定已发布提议，明确接收 `sampleOffset`；内部 `bindBuildPass()` 服务构建及调试计算入口。
训练和构建继续使用 `mLightingFrameIndex`，主渲染继续使用采样偏移，均映射到原 GPU 参数字段。
三者复用私有的 `bindParameters()` 和 `bindResources()`，保持唯一的参数/资源映射以及原有反射筛选行为。
公共资源保留原先的 RW 类型和声明顺序；查询阶段写入诊断计数和非法数据计数，不更新观测、历史或拓扑。
非法数据计数不受 Detailed diagnostics 开关控制，保留原有无条件记录行为。

每帧由 `beginUpdate()` 创建不可复制的 `FrameUpdate`，在无场景或基础 PT 累积上限等提前返回之前清理训练许可。
`FrameUpdate::prepare()` 封装配置、调试输出清零、建格与观测准备，并返回 `TrainingInputs` 中的写入许可和训练帧索引。
RTPT 使用这份本帧结果调度共享或独立训练；`bindTraining()` 和训练后的 barrier 保持在原有位置。
`FrameUpdate::finish()` 完成更新、发布与调试绘制；冻结时仍能绘制已有模型。作用域结束只清理训练许可，不隐式提交 GPU 工作。
`configure()`、`buildGeometry()`、`prepareLighting()`、`updateLighting()` 和 `renderDebug()` 均为 Manager 私有实现。

`hasSubmittedModel()` / `mModelSubmitted` 只表示 CPU 已提交模型发布命令，不代表 GPU 已完成或模型有效。
Shader 继续检查 GPU READY 与当前代次，失败时走既有 BSDF 回退。显式诊断中的 `ready`、`gpuReady` 等字段含义保持不变；
区分这两类状态不会在普通帧新增 CPU 读回或等待。

`RTPTVXPGLayout.slangh` 是六组状态/统计缓冲及三组间接调度参数的共同定义来源。
CPU 资源分配、读回与调度，以及 Shader 读写和清零，都使用这里的命名常量。
偏移单位为 32 位字，CPU 调用间接调度时仍转换为字节；保留原有槽位数值、保留槽位、
缓冲容量和清零范围。参数及结构化记录的字段、顺序和步长保持不变。

Shader 的职责：

- `Types.slang`：参数和结构化记录，并包含共享布局头；`Resources.slang`：公共资源声明；`Diagnostics.slang`：可编译关闭的活动计数。
- `Grid.slang` / `Incremental.cs.slang`：距离 LOD、空间查询与增量网格维护。
- `Training.slang` / `Observation.slang`：共享训练与观测记录；`History.slang` / `HistoryResolve.slang`：历史公式与 GPU 解析。
- `Prepare.cs.slang` / `Local.cs.slang` / `Tree.cs.slang` / `Distribution.slang`：全局树、局部更新、簇树和公共概率规则。
- `Primary.cs.slang` / `Visibility.cs.slang` / `Debug.cs.slang`：主表面数据、聚类/屏幕分布与调试输出。
- `Sampling.slang` / `Geometry.slang` / `Math.slang` / `Integrator.slang`：采样、反向 PDF、接受判定和渲染接入。

以上 Shader 名称均带 `RTPTVXPG` 前缀。计算入口不互相包含；公共历史解析通过
`HistoryResolve.slang` 共享。正向采样与反向 PDF 共用概率计算，保留概率边界修复。
训练入口显式依赖 `Observation.slang`，查询入口经 `Sampling.slang` 依赖公共资源声明；
`History.slang` 的历史解析公式由构建侧 `HistoryResolve.slang` 引入，训练和查询不再间接包含它。

## 每帧顺序与不变量

1. 准备 VXPG 资源、清本帧观测、标记过期网格，并保存上一帧历史/法线。
2. PrimarySurface 生成当前视图；独立的 LocalLights 完成 Grid/Tile/Probe 更新并发布选灯分布。
3. RTPT 调度固定的 Shared injection；已有 cell 直接累积，缺失 cell 记录待回放观测。
4. VXPG 将共享主表面复制到自己的 position/normal/hit 快照。此阶段不是单独的光照注入路径。
5. 网格 discover → insert → replay，只回放原先未写入的观测。
6. 解析历史及置信度，判断成员变化，建立或更新全局树。
7. 局部权重更新，固定更新 Visibility 的 Radix + Heap 簇树和当前帧屏幕分布。
8. 发布完整提议，再回收旧 cell ID；主渲染查询已发布模型。

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

GPU 布局定义统一后，Release 的 RTPT/Mogwai 构建通过；重构前 46 项运行检查及重构后 51 项检查全部通过。
验证使用主入口配置、VeachAjar 和 D3D12 debug layer，覆盖 1080p 的 128 帧 Stop、奇数分辨率诊断、
Heap/Radix 快照、调试视图、共享训练、相机复用、冻结恢复、VXPG 开关及参数调整和手动重置。
106 个命名布局常量展开后，40 个现有代码文件的代码 token 一致（忽略注释、格式及整数后缀），
原有 28 个命名常量数值全部保留；属性、诊断/快照字段和 GPU 分配字节数与基线一致。
图像不是逐像素一致：重构前后 HDR 平均绝对差约 0.000802，同版本重复运行约 0.000812，
均为 1080p、128 帧 RGBA 读回；差异处于相近量级，本验证不作逐像素一致或性能提升保证。
见 [GPU 布局重构验证](../../../build/vxpg-gpu-layout-20261026/verification-summary.json)。

资源生命周期重构后，Release 的 RTPT/Mogwai 构建通过，重构前 91 项及重构后 95 项运行检查全部通过。
21 个状态的资源估算、实际分配字节数、容量、模型代次和网格重建次数与基线一致。
覆盖 1080p 的 128 帧 Stop、奇数分辨率、非二次幂容量、训练布局调整、冻结调整分辨率、
开关恢复、场景重载与诊断恢复；本配置 227 MiB 时预算回退并释放资源，228 MiB 时恢复。
59 处资源分配配置、47 个 Pass 配置及 106 个完整释放的 GPU 成员保持一致；Shader 未修改。
验证使用主入口配置和 D3D12 debug layer，通过无窗口脚本执行；临时脚本和依赖在交付前清理。
见 [资源生命周期重构验证](../../../build/vxpg-resources-20261026/verification-summary.json)。

训练、构建与渲染接口拆分后，Release 的 RTPT/Mogwai 构建通过；重构前 82 项及重构后 86 项运行检查全部通过。
18 个状态的模型代次、发布状态、训练状态、容量及资源分配量等 11 个字段与基线一致，属性与快照字段保持不变。
53 个公共资源声明的类型与顺序、10 个参数/记录结构保持原样；30 个 Shader 文件的算法代码及 CPU 调度、同步顺序不变。
覆盖主入口 1080p 的 128 帧 Stop、奇数分辨率、冻结查询与诊断切换、五种调试视图、
SHaRC 关闭/冻结时的独立训练、训练步幅/深度调整、VXPG 开关恢复、PG SHaRC 和手动重置。
验证使用 VeachAjar 和 D3D12 debug layer，通过无窗口脚本执行；本阶段未做逐像素对比或性能基准。
临时脚本和依赖在交付前清理。见 [接口拆分验证](../../../build/vxpg-interfaces-20261026/verification-summary.json)。

四组资源的绑定与实际显存统计归组后，Release 的 RTPT/Mogwai 构建通过；重构前 84 项及重构后 88 项运行检查全部通过。
53 项公共绑定、59 个缓冲/纹理的统计范围保持一致；每组的绑定与统计共用一份资源清单，31 个 Shader 文件未修改。
18 个状态的实际分配量、预算估算、容量、模型代次及训练状态等 13 个字段与基线一致，属性与快照字段保持不变。
覆盖完整管线的 1080p/128 帧 Stop、奇数分辨率、容量和训练布局调整、SHaRC 独立训练、五种调试视图、
冻结调整分辨率、开关恢复、手动重置与场景重载；227 MiB 时回退并释放全部资源，228 MiB 时恢复。
验证使用 VeachAjar 和 D3D12 debug layer，通过无窗口脚本执行；未做逐像素对比或性能基准，临时脚本和依赖已清理。
见 [资源分组绑定与统计验证](../../../build/vxpg-resource-groups-20261026/verification-summary.json)。

每帧更新接口收拢后，Release 的 RTPT/Mogwai 构建通过；基线 98 项检查及重构后完整运行的 102 项检查通过。
22 个模型状态的发布代次、GPU READY、资源分配量、训练状态和 SHaRC 帧索引等 12 个字段与基线一致。
覆盖无场景、1080p/128 帧最终累积、同帧冻结与相机移动、冻结诊断及五种调试视图、
SHaRC 关闭/冻结时独立训练、VXPG/引导开关、预算回退恢复、手动重置和场景卸载重载。
基础 PT 累积提前返回在独立纯 PT 图中验证；训练、更新及 Shader 校验不新增每帧读回，31 个 Shader 文件未修改。
基线最后一个纯 PT 清屏断言修正为框架既有 RGBA `(0, 0, 0, 1)` 后，单独重跑四项纯 PT 检查，
与已通过的主管线结果合并；原始记录及验证脚本修正原因均保留在摘要中。重构后使用修正脚本完整跑通。
验证使用 VeachAjar、D3D12 debug layer 和无窗口脚本，未做跨版本逐像素对比或性能基准，临时脚本和依赖已清理。
见 [每帧接口与状态语义验证](../../../build/vxpg-frame-interface-20261026/verification-summary.json)。

诊断读回与展示分离后，Release 的 RTPT/Mogwai 构建通过；基线 97 项和重构后 102 项运行检查通过。
16 个状态的统计字段集合、15 项模型/容量/诊断元数据及树快照状态和根字段与基线一致。
CPU 对照程序将相同输入送入重构前实现和新实现，191 项检查通过，覆盖统计属性、UI 文本、
观测统计、树快照 JSON、重复 Morton/树深统计及无效结构/上下文分支；格式化结果逐字符串核对。
验证使用主入口配置、VeachAjar、D3D12 debug layer，覆盖 1080p/128 帧 Stop、奇数分辨率、
冻结与诊断切换、独立训练、引导/VXPG 开关、手动重置、预算回退恢复和场景卸载。
GPU 算法、资源布局和调度未修改，普通帧不增加读回。未做逐像素对比或性能基准；临时脚本、
CPU 对照程序和依赖在交付前清理。见 [诊断分层验证](../../../build/vxpg-diagnostics-20261026/verification-summary.json)。

2026-10-28 固定开启 PG SHaRC 后，Release RTPT 构建通过（零警告、零错误）。
D3D12 debug layer 下 104 项运行检查通过，包含生产 MIS 函数的 8192 组 GPU 数值检查、
1080p 完整主管线与 128 帧 Stop、全局 SHaRC/查询关闭及恢复、冻结、空缓存、反弹资格拦截、
VXPG 关闭恢复及单/双 Pass；13 个状态均无无效样本或几何/分布溢出。
旧属性 true/false 均被拒绝，配对缓存读取和 MIS 函数保持原样；积分器与原开启路径的源码契约检查通过。
640×360、三个种子在 16/64/128 帧对照七路输出，共 63 组对照、126 份数组全部有限；
128 帧最终 HDR 平均亮度与原开启状态的相对差均小于 0.05%。这是独立随机运行对照，不要求逐像素一致。
实际通过 `RTPR_START.cmd` 打开 VeachAjar，确认默认 `ToneMapper.dst` 及 PG SHaRC 固定状态说明，独立 Enabled 已移除。
见 [运行检查](../../../build/pg-sharc-fixed-20261028/runtime.json)、
[图像对照](../../../build/pg-sharc-fixed-20261028/comparison.json) 和
[MIS 源码契约](../../../build/pg-sharc-fixed-20261028/mis-source-contract.json)。临时验证脚本与图像数组已清理。

历史实验、已删除功能与旧测试数量见 [历史记录](README_HISTORY.md)，不代表当前可用功能。
