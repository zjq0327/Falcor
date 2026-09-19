# MyPT 的 NRC 模式

NRC 是 MyPT 的第三个模式，与原有 `PT`、`ReSTIR` 并列。它从普通 PT 生成显式路径，使用 NVIDIA Neural Radiance Cache 预测合适终点之后的辐射量。训练固定复用 QueryPT 已有路径（QueryOnly），不发射独立训练射线。NRC 模式使用同一个场景、VBuffer 和 `color` 输出，不运行 GRIS 的 reservoir 或时空重采样。

当前后端面向 Windows、D3D12 和 SDK 支持的 NVIDIA RTX GPU。网络是有近似偏差的辐射缓存；是否改善画质或总耗时，需要在目标场景中测量。

实施范围和测试证据见 [NRC 实施结果](../NRC_implementation_results.md)；本文描述当前使用与集成约定，不代表所有验收项均已通过。

## 构建与 SDK

以下命令从 Falcor 仓库根目录的 PowerShell 执行，使用项目已有的 CMake/Visual Studio 环境。

```powershell
& ./external/nrc-sdk/fetch-sdk.ps1
cmake --preset windows-vs2022 -DFALCOR_ENABLE_NRC=ON
cmake --build build/windows-vs2022 --config Release --target MyPT
```

SDK 默认位于 `external/nrc-sdk`；可通过 `-DNRC_SDK_ROOT=<SDK目录>` 指定其他位置，该目录应包含 `Include`、`Lib` 和 `Bin`。首次准备完整 Falcor 环境时，仍需按项目原有流程构建 Mogwai 及其他依赖。

锁定版本为 NRC **0.14，2025-07-16**：

- NRC commit：`266125db594e6a5a7c543805eaec451a75bef383`。
- 配套 RTXGI commit：`10b5770b8eaddfc1faab82b65f799ac6f47dcc44`。
- `external/nrc-sdk/SDK.lock.json` 记录下载地址、大小和 SHA-256；下载脚本还验证 NRC D3D12 DLL 的 NVIDIA Authenticode 签名。

仅检查已下载文件、不访问网络：

```powershell
& ./external/nrc-sdk/fetch-sdk.ps1 -VerifyOnly
```

关闭 NRC 后端：

```powershell
cmake --preset windows-vs2022 -DFALCOR_ENABLE_NRC=OFF
cmake --build build/windows-vs2022 --config Release --target MyPT
```

未找到匹配的头文件和 import library 时，构建会关闭 NRC 后端并保留 MyPT。启用构建时采用 DLL 延迟加载：普通 PT/ReSTIR 不需要先加载 NRC。NRC 首次使用时检查运行库、设备及 SDK 初始化结果；失败会显示原因，缓存路径输出清零，可以切回 PT/ReSTIR。

构建会将四个 NRC/CUDA DLL 复制到运行目录的 `nrc`，并将 SDK shader headers 复制到 `shaders/RenderPasses/MyPT/NRC/SDK`。运行时优先使用这些目录，开发环境再回退到构建时记录的 SDK 路径。SDK 初始化可能创建自己的 CUDA 缓存目录，应使用具有相应目录访问权限的普通用户环境运行。

`FALCOR_DEVMODE=1`（Visual Studio 调试启动默认设置）会优先读取 Source 中的 shader。NRC shader 通过 pass 提供的 SDK 头文件搜索目录包含 `Nrc.hlsli` / `NrcHelpers.hlsli`，因此源码启动和部署启动使用相同的头文件解析规则；include 名称不能再额外添加 `SDK/` 前缀。

## 启动与常用设置

在原来的 MyPT 界面中，将 `Mode` 选择为 `NRC`；也可直接启动演示图：

```powershell
& ./build/windows-vs2022/bin/Release/Mogwai.exe --script scripts/MyPTNRC.py
```

随后按原有方式加载场景。演示图默认开启 `AccumulatePass`，静态画面在网络训练期间也会累积。要查看未经累积的单帧结果，可取消 `AccumulatePass` 的 `Enabled`，或调用 `render_graph_MyPTNRC(accumulate=False)`。`scripts/MyPTNRC.py` 的 `render_graph_MyPTNRC()` 接受属性覆盖，例如：

```python
g = render_graph_MyPTNRC(
    maxBounces=8,
    nrcQueryTrainingMaxVertices=9,
    nrcTerminationThreshold=0.1,
    nrcTrainingIterations=4,
)
```

MyPT 接受并序列化以下 NRC 属性：

- `mode="NRC"`：选择第三模式；原有字符串 `PT`、`ReSTIR` 保持有效。
- `nrcUseCache`：是否使用缓存，MyPT 默认 `True`。关闭时直接走普通 PT，停止训练和缓存注入。
- `nrcTrainCache`：是否在线训练，默认 `True`。关闭后继续查询当前网络，停止训练记录、准备 compute 和网络训练。
- `nrcQueryTrainingMaxVertices`：QueryOnly 每条所选路径的记录容量，范围 `[2, 65]`，默认 `9`。超出容量时整条训练记录排除，渲染继续；此参数不改变追踪深度。
- `nrcTrainingIterations`：每帧训练迭代预算，范围 `[1, 16]`，默认 `4`。训练分辨率依据 SDK 建议计算，并限制在当前输出尺寸内。
- `nrcTerminationThreshold`：终止启发式阈值，范围 `(0, 10]`，MyPT 默认 `0.1`。较小的值倾向于更早查询网络，改变显式追踪工作量和缓存近似误差。
- `nrcFeatureSize`：世界空间中最小可分辨特征尺度，必须为正有限值，默认 `0.01`；改变它会触发 SDK 重配置。

演示脚本使用 `maxBounces=8`、`nrcQueryTrainingMaxVertices=9`、`nrcTerminationThreshold=0.1`，另外设置 `rrProbability=0`、`computeDirect=True`、`useMIS=True`。测量脚本使用阈值 `0.01` 等更容易触发缓存的测试配置，这些不是产品默认值。

Independent 已删除，界面不再提供 Training source。旧配置中的 `nrcTrainingSource`（包括旧的 `"QueryOnly"` 值）、`nrcTrainingMaxBounces` 和 `nrcUnbiasedTrainingRatio` 需要移除；传入这些旧参数会报告错误。无需指定训练源，记录容量通过 `nrcQueryTrainingMaxVertices` 设置。

NRC 界面将 `maxBounces` 显示为 **Max explicit bounces**。正值限制主路径的显式间接反弹；网络仍可预测更深的传输，所以它不是最终图像光传输深度的严格上限。直接光估计仍可能产生额外的可见性或 BSDF 探测射线。`maxBounces=0` 强制走普通 PT 的直接光路径，完全跳过缓存训练和尾部注入。

实际启用缓存且 `maxBounces>0` 时，NRC 固定启用 MIS，界面显示 `MIS enabled for NRC`。缓存关闭或零反弹的普通 PT 路径仍使用原有 `useMIS` 设置。

## QueryOnly 第一版管线

选择 NRC 模式后即使用此管线。对现有 pass 设置：

```python
pt.set_properties({"mode": "NRC", "nrcTrainCache": True, "nrcQueryTrainingMaxVertices": 9})
```

`scripts/MyPTNRC.py` 与 `scripts/MyPTNRCQueryOnly.py` 两个入口均使用相同的 QueryOnly 管线：

```powershell
& ./build/windows-vs2022/bin/Release/Mogwai.exe --script scripts/MyPTNRCQueryOnly.py
```

```text
BeginFrame
  → PrepareQueryTraining       选择 owner、清空槽状态；compute，无射线
  → QueryPTWithRecords         原有渲染追踪，同时记录选中路径的局部传输
  → BuildTrainingFromQuery     写 SDK 训练记录及末端 bootstrap query；compute，无射线
  → QueryAndTrain              批量推理、传播目标、训练
  → Resolve → EndFrame
```

每个 SDK 训练槽在对应像素块选择一个 owner，每帧轮换。记录器独立累计局部光照和 BSDF/RR 权重，不重置渲染累计量，不消耗渲染随机数。缓存点原有 direct-probe 的结果归入该点，停止后的表面不会变成新的训练顶点。训练冻结时跳过两个新增 compute pass，并使用无记录 QueryPT。

缓存终止使用最后一个已有顶点的独立网络查询做 bootstrap；probe miss 不关闭该尾部。真实 miss、吸收和 RR 死亡关闭训练末端，存活路径保留 RR 补偿。硬深度、记录溢出、探测链上限和非有限记录会排除整条训练样本。`computeDirect=False` 时从后续完整表面开始记录，避免把主表面缺失的直接光当作零标签。

这些短路径没有新增的深层真值；缓存终点对自身的 bootstrap 不属于新的间接光观测。冷启动、深层覆盖和动态恢复仍需测量。零额外射线也不意味着总耗时一定降低：记录、额外 payload、buffer 和网络查询仍有成本。

专项回归入口为 `scripts/nrc_validation/query_only.py`，结果保存在新的 `build/nrc-validation/query-only-*` 目录。实施细节与测量见 [QueryOnly 实施记录](../NRC_query_only_implementation.md)。

## 训练、冻结和重置

首次实际执行 NRC 缓存路径会创建网络，连续帧保留它。关闭 **Train cache** 可以冻结当前网络。**Reset cache** 或 Python 的 `resetNrcCache()` 会请求完整重置：下次实际执行 NRC 缓存路径时，先等待 GPU 完成，再销毁旧 SDK context，并创建、配置新的 context 和网络。这不会自动打开训练；若仍处于冻结状态，新网络也不会训练。在 `nrcUseCache=False` 或 `maxBounces=0` 的旁路期间，重置请求保留到缓存路径恢复执行。

在 Python 中修改同一个 pass，才能保留已训练网络：

```python
pt = g.getPass("MyPT")
pt.set_properties({"nrcTrainCache": False})
print(pt.resourceStats["nrc"])

# 继续训练，或显式重置。
pt.set_properties({"nrcTrainCache": True})
pt.resetNrcCache()
```

`graph.updatePass()` 会重建 pass，不适合用来冻结已有网络。单独调用 `resetSampling(seed)` 只重置采样序列，不清空 NRC 网络。

模式切换会重置下游画面累积。离开 NRC 会释放它的状态，返回时重新初始化；加载场景也会释放旧状态。分辨率、训练尺寸、特征尺度或相关 SDK 配置变化会触发 `Configure` 和公开缓冲重配，网络是否保留取决于 SDK 的配置规则；这与显式重置所保证的新 context 不同。

在线训练本身不再清空累积。保持 `AccumulatePass` 的 `Enabled` 和 `Auto Reset` 开启，即可平均连续训练帧；改变参数、切换训练开关、重置缓存或场景发生变化时重新开始。相机 jitter 不触发重置；graph 不活跃期间的场景、视角和镜头变化在恢复时处理。在线累积会包含不同训练阶段的输出；需要测量固定网络的静态质量时，仍应先训练、再冻结网络并清空累积后采样。

场景位置编码使用有余量的包围盒：每边按场景尺寸约 10% 扩展，最小余量为 `nrcFeatureSize`。普通相机移动和包围盒内的小幅动画不重新配置编码；几何离开这个范围、显式重置或换场景时更新包围盒。灯光和材质数值变化由在线训练逐步适应，冻结状态下网络不会学习这些变化。几何表示或 shader 表示发生需要重新编译的变化时，当前实现会提示重新加载场景。

## Shader 热重载

F5 使用 Falcor 的全局程序重载机制；检测到程序变化后，活动 graph 会收到热重载通知。MyPT 等待 GPU 完成，释放 NRC 状态和旧参数绑定；下次执行缓存路径时重新创建程序与网络。未检测到程序变化的 F5 不会重置网络。此前不活跃的 NRC graph 恢复执行时，也会比较旧参数的反射对象与当前程序，发现重载后重新建立状态。

脚本可对现有 pass 调用强制重载：

```python
pt.reloadShaders()
```

该方法调用同一个全局程序重载接口，即使源文件未改变也强制重载，然后通知当前 MyPT；它不会像 F5 一样通知活动 graph 的其他 pass。此操作会丢弃已训练的 NRC 网络，并在后续渲染时重置下游累积。训练开关和其他用户参数保留。

## 缓存范围和光照合成

主表面保留显式着色，至少向后追踪一个散射段，再由 SDK 启发式决定是否查询。当前可缓存的表面为 **Standard 材质、无透射、无 delta lobe**；其他表面继续使用真实 BSDF 显式追踪。镜面、透射链因此不会被强行转换为缓存特征。当前 NRC 路径支持 MyPT 的三角形几何路径，遇到程序化几何会报告不支持。

SDK 固定使用 `includeDirectLighting=false`。查询终点的直接光仍由显式传输估计，网络贡献经过路径前缀 throughput 调制后加入：

```text
color = nrcExplicit + nrcCached
```

查询终点处的 BSDF 直接光探测会显式穿过 SDK 跳过的表面；该附加探测链有 64 段的保护上限，避免病态镜面循环。

网络冷启动时可能产生少量负辐射预测；实现保留原始 HDR 数值，方便与 SDK 的官方 Resolve 对照，不将负值裁为零，也不将非有限值替换成黑色。验证会直接拒绝非有限值，负预测则按数量和幅度记录为质量指标。负预测、缓存偏差和训练适应过程应单独评估，不能用普通 PT 的有限深度结果要求 NRC 精确逐像素匹配。

## 诊断输出

以下输出按需连接或 `markOutput`；除 `color` 外都是可选资源，开启它们会增加资源和工作量：

- `nrcExplicit`：显式路径的线性辐射量。
- `nrcCached`：经过前缀 throughput 调制后的网络贡献。
- `nrcQueryDebug`：每个查询像素的 `uint4` 统计，依次为实际 scatter rays、shadow rays、访问顶点数、缓存查询数。
- `nrcTrainingDebug`：训练路径的同类 `uint4` 统计，最后一项为写出的训练记录数；记录写入对应的全分辨率 owner 像素。
- `nrcQueryTrainingDebug`：QueryOnly 的 `uint4`，依次为终止原因、记录顶点数、交给 SDK 的有效顶点数、bootstrap query 数；写入 owner 像素。原因编码为 0=空/未结束，1=缓存，2=真实 miss，3=吸收，4=RR，5=硬深度，6=溢出，7=探测上限，8=非有限值。未选像素为零；选中路径的分母为训练尺寸乘积。QueryOnly 的 `nrcTrainingDebug.xyz` 恒为零，`.w` 为有效记录顶点数，不能将记录数当作新发射射线数。
- `nrcSdkReference`：以同一批查询及网络输出调用 SDK Resolve 的结果，用于核对自定义合成；不会额外训练，但会增加一次合成工作。

`render_graph_MyPTNRC(diagnostics=True)` 会标记常用颜色和计数输出。需要官方对照时额外执行：

```python
g.markOutput("MyPT.nrcSdkReference")
```

`pt.resourceStats["nrc"]` 提供构建/可用性状态、失败原因、`cacheGeneration`、帧数、训练尺寸、`trainingSource`、`queryTrainingBufferBytes` 和 SDK 公开 buffer 字节数。冻结后复用记录缓冲，故记录缓冲字节数可以非零。`cacheGeneration` 是缓存生命周期或配置变化的代号，重配置也可能使其增加，不能单凭它证明网络权重已清空。公开 buffer 字节数不包含全部网络或 CUDA 内部显存。

要定位 D3D12 接口问题，可从 PowerShell 启用诊断并启动调试层：

```powershell
$env:MYPT_NRC_DIAGNOSTICS = "1"
& ./build/windows-vs2022/bin/Release/Mogwai.exe --enable-debug-layer --script scripts/MyPTNRC.py
Remove-Item Env:MYPT_NRC_DIAGNOSTICS
```

日志中的 `NRC_DIAG` 标记各 SDK/路径阶段和设备状态，`NRC_D3D12` 输出 InfoQueue 的警告、错误及消息 ID，`NRC_SDK` 输出官方库消息。无调试器时会关闭设备移除的调试断点，让错误能够进入日志。

只有进一步设置 `MYPT_NRC_DIAGNOSTICS_SYNC=1`，诊断检查点才会提交并等待 GPU；它用于故障定位，会改变时间和执行节奏。常规运行和性能测量应移除这两个环境变量。

## D3D12 集成约定

公开缓冲由 Falcor 按 SDK 的 element count、stride、共享 heap、UAV 和初始状态要求创建。QueryPT、训练记录 compute、SDK 推理训练和 Resolve 都使用同一个 Falcor D3D12 队列。

SDK 的原生调用会更改 descriptor heaps、root signatures 和 pipeline 状态。当前 Slang gfx 版本仅关闭 encoder、失效化 descriptor heap 缓存还不够，因此每次原生 SDK 调用后执行 `submit(false)`，让下一段 Falcor 工作使用全新的命令列表。这一步不会让 CPU 等待 GPU；不能为了减少提交次数直接删除，否则可能重新出现错误的状态绑定或设备移除。

`EndFrame` 在本帧相关命令已提交后调用，并检查队列身份。重配置、重置和销毁时等待 GPU 后再替换资源；正常逐帧路径不加入逐阶段 CPU 等待。

验证入口见 `scripts/MyPTNRCValidate.py`、`scripts/MyPTNRCRun.py` 和 `scripts/MyPTNRCEdges.py`。后者的 `shader_reload` 用例覆盖活动与不活跃 graph，并临时修改部署后的 shader 常量布局，在 `finally` 中恢复；运行时必须独占该构建输出目录，避免其他渲染进程或构建同时使用它。

累积专项回归为 `scripts/nrc_validation/accumulation.py`：连续在线训练 32 帧，并检查 11 类参数、场景和模式变化后的自动重置。测试直接对比原始 HDR 的逐帧平均，包括相机 jitter 和不活跃 graph 的场景变化。

应分别评估无缓存等价性、合成、生命周期、动态适应、画质与总 GPU 时间。SDK 开启、显式关闭、构建时缺少 SDK，以及启用构建但缺少运行库已在本机分别验证。结果、适用范围和补充脚本见 [实施结果](../NRC_implementation_results.md)；这些功能检查不代表 NRC 比 PT 更快或更准确。
