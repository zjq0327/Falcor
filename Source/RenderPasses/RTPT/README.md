# RTPT 与 NRD

RTPT 使用 Compute Shader 和 RayQuery 完成蒙特卡洛路径追踪、NEE 和 MIS。NRD 管线为 `RTPT → NRD → ModulateIllumination → ToneMapper`。

**日常统一入口是仓库根目录的 `RTPR_START.cmd`**：双击后使用 D3D12 加载 `scripts/RTPTSHARCNRD.py` 和 `Source/Data/VeachAjar/VeachAjarRTPT.pyscene`，同时启用 RayQuery PT、SHaRC 缓存查询和 NRD 降噪，默认显示 `ToneMapper.dst`。后续新增渲染功能须同步集成到这一入口使用的管线；独立脚本用于对照与调试。VeachAjar 兼容入口仅关闭 `Pot1` 的玻璃透射，以适配当前反射积分器。

主入口的完整显示流程为 `RTPT（SHaRC）→ NRD → ModulateIllumination → FrameAccumulation → ToneMapper`。展开 **FrameAccumulation** 面板设置 **Max Frames**（默认 `128`，`0` 为不限），**Overflow Mode** 保持 **Stop**；**Frames accumulated** 显示当前已累计的帧数与目标，达到上限后保留最终显示结果。**Reset** 重新累计，默认开启 **Auto Reset**，相机、场景或 RTPT 参数变化后自动重新计数。这一层平均的是 NRD 合成后的线性 HDR 图像，可进一步平均残余噪声；达到上限后 SHaRC/NRD 仍继续更新，原始输出及未额外累计的 NRD 合成输出仍可用于对照。仅对照 NRD 降噪前后的效果时，可关闭 **FrameAccumulation → Enabled**。

`RTPR_START.cmd` 顶部提供四个启动开关，`1` 开启、`0` 关闭，默认全部为 `1`：

- `RTPT_SHARC_ENABLED`：SHaRC 缓存更新与路径终止查询；窗口中对应 **RTPT → SHaRC → Enabled**。
- `RTPT_NRD_ENABLED`：NRD 降噪；对应 **NRD → Enabled**。关闭时直接传递当前帧光照信号，再由 ModulateIllumination 乘回材质；RTPT 仍生成相同布局的 NRD 输入。
- `RTPT_ACCUMULATION_ENABLED`：最终 HDR 画面累积；对应 **FrameAccumulation → Enabled**，重新开启后从第 1 帧累计，保留 Max Frames 设置。
- `RTPT_TONEMAPPER_ENABLED`：色调映射；对应 **ToneMapper → Enabled**。关闭时直接显示线性 HDR，亮部可能超出显示范围；启动开关同时设置 ToneMapperReference，运行时两个面板各自控制。

窗口中的开关立即生效，切换 SHaRC 或 NRD 会清空降噪历史与最终累积，达到 Max Frames 后也能查看变化。启动设置在下次启动生效，窗口中的临时调整不回写 CMD。开关保留图的资源连线，不会卸载对应模块。后续新增可选模块也须接入同一主入口，并提供启动与运行时开关。

在仓库根目录运行已构建的 Release 版 Mogwai：

```powershell
.\build\windows-vs2022\bin\Release\Mogwai.exe --script scripts/RTPTNRD.py --scene test_scenes/cornell_box.pyscene
```

当前接入使用仓库内的 NRD 3.1、RELAX diffuse/specular 降噪器和 D3D12。`enableNRD=True` 要求 `samplesPerPixel=1`、`accumulate=False`，时域历史由 NRD 管理。一个像素共享一个主射线采样，各有效 diffuse/specular 波瓣独立追踪延续路径，因此 1 SPP 不代表只有一条完整路径。

图中可选输出：

- `ToneMapper.dst`：降噪、乘回材质并合成后的显示结果，默认输出。
- `ToneMapperReference.dst`：当前帧原始结果经过相同 ToneMapper 后的对照图。
- `ModulateIllumination.output`：降噪合成后的线性 HDR，适合保存和比较。
- `FrameAccumulation.output`：组合主入口中额外累计后的线性 HDR。
- `RTPT.noisyColor`：独立的当前帧原始线性 HDR，适合检查采样噪声。

RTPT 导出第一命中的法线、粗糙度、线性深度和世界空间运动向量，以及分离、去材质化后的 diffuse/specular 光照。NRD 后通过 `ModulateIllumination` 乘回材质，并加入 emission 和 residual。理想镜面（delta reflection）及 `viewZ >= 10000` 的表面通过 residual 保留，不做 NRD 降噪。

`maxIntensity=250` 仅限制送入 NRD 的信号亮度，避免 RELAX 的 FP16 统计溢出；独立原始图不裁剪，因此极亮区域的降噪结果可能与原始图存在差异。两个 ToneMapper 使用相同设置，并禁用场景元数据曝光覆盖。

参数变化、相机切换、分辨率变化及相关场景变化会清空 NRD 历史。普通相机与物体运动使用重投影；同一个相机大幅瞬移后，应点击 RTPT 的 **Reset NRD history**。

原有 `scripts/RTPT.py` 仍可使用，提供单 Pass 路径追踪和渐进累积。将启动命令的脚本参数改为 `--script scripts/RTPT.py` 即可。

基础 PT 的 **Progressive accumulation** 下提供 **Max frames**（脚本属性 `maxAccumulationFrames`）：`0` 表示不限，设为 `128` 则累计 128 个渲染帧后停止追踪并保持输出。**Accumulated frames** 显示当前帧数与目标，**Accumulated samples** 显示每像素总采样数；每帧 4 SPP 累计 128 帧即 512 samples。达到上限时 `RTPT.color` 保持累计结果，`RTPT.noisyColor` 保持最后一次追踪的单帧结果。移动相机、修改参数、调整分辨率或点击 **Reset accumulation** 会重新累计。该上限仅用于基础 PT 的渐进累积，NRD 历史和 SHaRC 缓存历史仍由各自算法管理。

## SHaRC 缓存与可视化

双击仓库根目录的 `RTPT_SHARC_GRID_START.cmd` 可打开静态 VeachAjar 的体素分格视图，使用 `scripts/RTPTSHARCGrid.py`，默认输出 `RTPT.sharcDebug` 和 `Voxel grid` 模式。色块显示世界空间体素与可见表面的对应关系；颜色包含格子层级与表面朝向的哈希信息，不表示该格子已有有效缓存。展开 **RTPT → SHaRC** 调整 **Grid scene scale**：数值越大，格子越小。将输出切换到 `ToneMapper.dst` 可查看同一配置下的渲染结果。此入口使用 `VeachAjarRTPT.pyscene`，仅关闭原场景 `Pot1` 的玻璃透射以适配当前反射积分器。

在仓库根目录启动 SHaRC，或 SHaRC + NRD：

```powershell
.\build\windows-vs2022\bin\Release\Mogwai.exe --script scripts/RTPTSHARC.py --scene test_scenes/cornell_box.pyscene
.\build\windows-vs2022\bin\Release\Mogwai.exe --script scripts/RTPTSHARCNRD.py --scene test_scenes/cornell_box.pyscene
```

SHaRC 在同一个 RTPT Pass 中依次执行稀疏路径 Update、缓存 Resolve 和完整分辨率 Render/Query。默认在每个 `5×5` 区域选一个像素更新，约占屏幕像素的 4%，更新位置随帧变化；更新路径最多 8 次散射，渲染路径最多 4 次。默认缓存为 `1048576` 个条目，hash、accumulation 和 resolved 三个核心 buffer 共约 **40 MiB**，调试纹理等资源另计。当前使用 64 位原子操作，无需锁 buffer。

两个图默认显示 `ToneMapper.dst`，通过 Mogwai 的输出选择器可切换 `RTPT.sharcDebug`。在 RTPT 的 SHaRC UI 中选择 `sharcDebugMode`：

- `0 Voxel grid`：世界空间 voxel/hash 分格，显示格子划分，不代表缓存有效。
- `1 Cached radiance`：缓存辐射值的显示视图。
- `2 Sample count`：条目的累计有效样本数。
- `3 Entry age`：自条目上次更新以来的 stale 帧龄，用于观察淘汰条件。
- `4 Actual cache hits`：渲染路径实际命中缓存并提前终止的情况。
- `5 Traced rays`：像素追踪的渲染辐射射线数；NRD 各波瓣的延续射线相加，不表示单条路径的深度。
- `6 Update coverage`：当前帧稀疏更新覆盖。
- `7 Hash occupancy`：完整 hash 表的占用情况，每个像素聚合一段缓存槽；绿色强度表示局部占用密度。

这些调试图直接显示，不经过 NRD。`RTPT.sharcCacheRadiance` 保留缓存辐射的原始 HDR；`RTPT.sharcStats` 的 RGBA 分别记录实际缓存终止数、渲染辐射射线数、符合筛选条件的查询尝试数和首个主采样命中条目的累计有效样本数，供数值检查。稀疏 Update 射线不属于渲染射线统计。

`RTPT.noisyColor` 和 `ToneMapperReference.dst`（NRD 图）仍包含 SHaRC 查询得到的当前帧结果，适合检查降噪前后变化。要比较缓存与纯 PT，在 UI 关闭 `sharcUseCache`；此时继续更新缓存，只停用渲染查询。关闭与开启查询作 A/B 时，应等待各自时域历史稳定。

`sharcFreeze` 冻结缓存更新、Resolve 和条目年龄；**Clear radiance cache** 用于重新建立缓存。显示模式切换不清缓存。普通相机运动保留世界空间缓存；当前材质、灯光变化及几何移动会保守清空缓存。

默认 `sharcSceneScale=64`、累积历史 32 帧、过期阈值 128 帧，从第 1 次散射后的命中开始允许查询，并使用 `sharcMinRoughness=0.4` 保守筛选。缓存建立初期，条目的累计有效样本数必须超过阈值 4 才允许命中。格子尺度应按场景调整；缓存不足或查询不满足条件时继续 PT。

缓存采用击中材质的 radiance 解耦，查询时乘回该材质因子，以减少纹理颜色被平均的问题；这与 NRD 对第一可见表面的解耦属于不同顶点。空间平均仍可能损失遮挡、法线和高频方向细节，因此不能保证恢复尖锐高光或镜面细节，理想镜面与过窄波瓣继续追踪。SHaRC 查询属于近似路径终止；无缓存 PT 用于检查能量和细节差异。

第三方实现来自 [NVIDIA SHaRC SDK](https://github.com/NVIDIA-RTX/SHARC)，集成流程参考其[官方说明](https://github.com/NVIDIA-RTX/SHARC/blob/main/docs/Integration.md)。SDK 按 [NVIDIA RTX SDKs License](ThirdParty/SHARC/License.md) 使用，其许可证独立于 Falcor。
