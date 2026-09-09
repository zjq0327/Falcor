# MyPT 第一轮开发与验收记录

日期：2026-09-08。第一轮已接通现有 ReSTIR 的完整路径初始 RIS；UI 仍然只有 **PT / ReSTIR**。未接入时间复用、空间复用或 Hybrid Shift，不能将本轮结果称为完整 GRIS 的最终效果。

## 1. 按用户反馈修订的集成方式

先修订了[开发计划](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS_ReSTIRPT_development_plan.md)，再将开发中的额外模式撤回。没有保留 ReSTIRPT / PTReference UI 模式，也没有保留独立的一套 `grisCandidateCount` / `grisMaxSurfaceBounces` 配置。

- 保留原 PT 的 ray-generation / closest-hit 路径追踪入口。
- 在原 ReSTIR 分支中顺序执行 GeneratePaths → TracePaths → Resolve；仍是一个对外的 MyPT RenderPass。
- 从原 shader 提取材质加载、analytic / emissive light sampling、BSDF sampling 和 MIS 辅助函数到 [MyPTCommon.slang](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/MyPTCommon.slang)。PT 和 ReSTIR 共用这些函数。
- 删除被替代的 `restirGen`、一跳 GI payload / hit shaders、DI/GI 历史缓冲及旧近似合并模块 `MyPTRestir.slang` / `MyPTRestirGI.slang`。实施前代码可从 Git 基线恢复；没有增加 Legacy 模式。
- 沿用原 GI 候选数、Max bounces、直接光、importance sampling、MIS 和 RR 参数。新增 `seed` 用于 ReSTIR 的可重复采样。
- 旧历史长度、空间邻居数等属性保留读取/保存兼容性，本轮不执行其算法，也不在 UI 中展示为有效控制。

## 2. 每个 Pass 与参考实现的对应

**GeneratePaths**：建立每像素 primary hit / 视线 / 随机种子，初始化当前帧缓冲。对应参考 [GeneratePaths](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/GeneratePaths.cs.slang:100) 的起点准备职责。背景像素也被显式处理，奇数尺寸线程使用 `any(pixel >= dimensions)` 排除越界。

**TracePaths**：一个 dispatch 内逐棵候选树追踪到有限路径长度，沿途处理发光面、环境和 NEE 贡献；不按每个 bounce 重新 dispatch。对应参考 [TracePass::tracePath](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/TracePass.cs.slang:19)。原 MyPT 的“只在第二顶点取 Lout”已替换为完整候选流。

树内对每个非零贡献执行 reservoir 更新，结束后置 `M=1`，再合并多个树。对应参考 [PathBuilder::finalize](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathBuilder.slang:44)、[mergeInSamplePixel / finalizeRIS](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathReservoir.slang:393)；没有将一棵树中的 NEE/emission 次数误计为候选树数量。

**Resolve**：输出选中贡献 `F × W`，另可输出同一候选流直接求和的 `ptReference`。对应参考 [PathTracer::writeOutput](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathTracer.slang:1852)。这张参考纹理仅供验收，不是新的 UI PT 模式。

调度、scene modules / type conformances、sampler 绑定和资源生命周期在 [MyPTGRIS.cpp](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/MyPTGRIS.cpp:9)。三个实际 Pass 均有 profiling 名称。结构化缓冲直接从 GeneratePaths 的 ShaderVar 反射创建，没有新增硬编码字节大小或空的 ReflectTypes pass。

## 3. 本轮数学和参数约定

- `F` 是 PSS 贡献，已包含光源/BSDF 采样倒数与 MIS。标量目标沿用参考 `dot(F, (0.299, 0.587, 0.114))`。
- `weightSum` 始终保存原始权重和；`W = weightSum / (M × pHat(F_selected))` 单独保存。树内贡献数不改变最终 `M`；零贡献候选树仍计入 `M`。
- 最终一个 reservoir / pixel。`giRISCandidateCount=1/4/8` 表示候选树数，不是输出 reservoir 数。
- 按参考 PathBuilder 的思路对选择流种子再做哈希，与 transport 和像素合并流区分。选择过程不推进 transport RNG；固定相机/seed/重置条件下可重复。
- `maxBounces=0` 保持原 UI 的直接光语义；内部最多发生 `maxBounces+1` 次表面散射。达到上限后仍处理终端 emission / miss，再停止。`giRISCandidateCount=0` 保留直接光模式，以一棵直接光树实现。
- `computeDirect=false` 排除长度 0/1 的贡献；`maxBounces=0` 时因此输出黑色间接光。
- RR 基线为 0；启用 RR 时倒数进入路径 throughput / F，reservoir 不再重复除 RR PDF。这与参考将 RR PDF 单列存储的方式不同，但第一轮无复用时的估计量一致。
- ReSTIR 采用参考的 balance MIS。原 PT 保持其 power MIS；关闭 ReSTIR MIS 时，NEE 负责可采样的非 delta 光路，避免与 BSDF 命中重复累计。analytic lights 没有可被当前 BSDF ray 直接命中的几何端点，单独采样。
- 当前每类光源分别采样一次；参考按光源类型分布组织 NEE。本轮验证能量，不声称相同候选数具有相同射线成本或噪声。
- 初始种子、终端采样种子、路径长度/终止类型、固定第二顶点、rc 方向/prefix/suffix 等随选中样本保存。完整可逆 shift、双向 BSDF/PDF、Jacobian 和 Hybrid eligibility 仍属于 M3–M5。

本轮独立计算完整光照，没有外部 DI 输入。没有照搬参考 [首次非 delta 发光面抑制分支](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathTracer.slang:1022)；该分支依赖参考演示的独立 DI，否则会漏光。

## 4. 在当前 Falcor 中修复的资源问题

实际 shader 编译发现原 MyPT 将 EmissivePowerSampler 当作无状态对象，在 shader 中以 `{}` 局部初始化。当前 Falcor 的 [EmissivePowerSampler](C:/Users/13243/Desktop/Restir/Falcor/Source/Falcor/Rendering/Lights/EmissivePowerSampler.slang:32) 包含 alias-table buffer，必须由 CPU 绑定。

现在 PT / ReSTIR 共用 sampler ParameterBlock，每帧绑定 alias table 和权重归一化数据。环境 sampler 同样使用 ParameterBlock。GPU 调试还确认了将有常量字段的 sampler 裸放全局时的 root-signature / CBV 不匹配问题；正式实现已经消除该错误，临时 D3D12 诊断代码已移除。

## 5. 已执行的验收

运行环境：Falcor 8.0，Release，D3D12，NVIDIA GeForce RTX 5070。C++ 编译通过，三个实际 shader 已在 GPU 上执行；`git diff --check` 通过。Smoke 阶段使用过 D3D12 debug layer。

数值数据：[report.json](C:/Users/13243/Desktop/Restir/Falcor/build/gris-validation/report.json)、[候选数量比较](C:/Users/13243/Desktop/Restir/Falcor/build/gris-validation/candidate_counts.json)、[源码版本与哈希](C:/Users/13243/Desktop/Restir/Falcor/build/gris-validation/source_state.json)。各案例的每种子平均原始 RGB 保存在同目录 `.npz`，未经过累积 Pass、去噪或 ToneMapper。

统计配置：96×64、VBuffer Center/1、固定相机、四个 seed：11 / 101 / 1009 / 10007。ROI 为行 `[12,56)`、列 `[8,88)`。逐种子形成 ROI RGB 均值，以 4 组配对差计算 Student-t 95% 区间（df=3）。通过要求是“绝对平均差 + 区间半宽”落在参考均值的 1% 内；不是只比较单张图，也不是只检查按构造恒等的目标亮度。

最终哈希随机流版本的 13 组 RIS / 同候选 PTReference 比较均通过，观测到的最大逐通道相对均值差约 0.211%；通过判断仍使用上述包含置信区间的门槛：

- tutorial：候选树 1 / 4 / 8、Max bounces=8，每 seed 256 帧。
- tutorial：直接光、Max bounces=2、RR=0.2、关闭 MIS，各每 seed 32 帧。
- tutorial：均匀 BSDF 采样，每 seed 128 帧。首次 32 帧的置信区间不足以确认 1%，增加样本后通过。
- Cornell Box：候选树 1 / 4 / 8、Max bounces=8，每 seed 32 帧。
- alpha_test：环境光和 alpha-test，每 seed 32 帧。
- material_test：包含 delta / transmission 的材质及环境光，每 seed 32 帧。

另比较 N=4、N=8 与 N=1 的亮度稳定性：tutorial 和 Cornell 的 RIS 输出及未重采样输出，各 RGB 通道的配对区间均落在 1% 内。tutorial 的首次 32 帧预算不足，按预设 ROI 增至每 seed 256 帧后通过；没有修改曝光或增加 radiance clamp 来满足阈值。

其他已通过的运行检查：固定 seed 重建后逐像素一致；PT → ReSTIR 模式切换后重置一致；分辨率变化后重新初始化；`M` 等于候选树数；路径长度不越界；非有限贡献计数为 0；零候选维持直接光；关闭直接光且无间接 bounce 时为黑；原 PT 可编译执行并输出非黑有限图像。

针对场景开关另做了 Cornell 回归：关闭 emissive lights 后，间接光输出全黑。相机直接看到的发光面仍属于直接显示项，沿用 MyPT 的原有区分。

[实际入口与边界检查](C:/Users/13243/Desktop/Restir/Falcor/build/gris-validation/entry_checks.json)还覆盖了用户原 `scripts/MyPT.py` + tutorial 场景的 640×360 / 16 帧执行、83×47 非线程组整数倍尺寸，以及不接 viewW 时的 pinhole 分支。

## 6. 如何运行

用户原有启动方式继续可用：

```powershell
--script "C:\Users\13243\Desktop\Restir\Falcor\scripts\MyPT.py" --scene "C:\Users\13243\Desktop\Restir\Falcor\media\test_scenes\tutorial.pyscene"
```

脚本默认仍使用现有 `ReSTIR` 名称，配置为 GI 候选树 1、Max bounces 8、importance sampling/MIS 开启、RR=0、seed=0。保留原 VBuffer Stratified/16、累积和 ToneMapper 作为交互查看入口；严格的能量比较使用辅助脚本。

在项目根目录编译与运行验收：

```powershell
& tools/.packman/cmake/bin/cmake.exe --build build/windows-vs2022 --config Release --target MyPT -- /m:4 /nologo
& tools/.packman/python/python.exe -m pip install --target build/gris-python numpy==1.26.4
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTGRISSmoke.py --verbosity 2
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTEntrySmoke.py --verbosity 2
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTGRISValidate.py --verbosity 2
```

NumPy 只安装在项目 `build/gris-python`，用于 Falcor 内置 Python 3.10 的 GPU 读回统计；不改变用户的系统 Python。辅助脚本 [MyPTGRIS.py](C:/Users/13243/Desktop/Restir/Falcor/scripts/MyPTGRIS.py) 只是诊断 render graph，不增加 UI 模式。

可选输出：`ptReference` 为同候选流的路径树求和；`reservoirF.rgb` 为选中的 F、alpha 为终止类型；`reservoirDebug` 四通道依次为 W、M、surface-scatter count、invalid contribution count。PT 模式的诊断纹理显式清零。

## 7. 尚未验收的范围与下一轮

上述测试验证当前完整路径候选与初始 RIS 的一致性，不能排除两种输出共享的追踪错误。材质测试说明相关分支能运行且重采样保持能量，不等于已经验证嵌套介质、色散或复杂玻璃的物理正确性。

参考源码在实现期间反复核对，未修改参考工程。参考 Mogwai 的 `--help` 已运行成功；**尚未完成参考 Falcor 4.4 与当前 Falcor 8 的同场景原始 HDR 对拍**，也没有同时间图像质量、动态稳定性或性能对齐数据。原始 PT / 旧 ReSTIR 的改动前截图未采集；代码和脚本基线保存在 Git `901e4e96a40e3a27a6a9d9f34a9e0718381984e9` 及 [只读快照目录](C:/Users/13243/Desktop/Restir/Falcor/build/gris-baseline)。因此 M0 的跨版本图像基线项仍保留未完成状态。

当前只支持 triangle geometry；RR 关闭是严格对照默认。完整路径 shift、时间/空间 reuse、重投影、历史截断和 Hybrid replay 尚未实现；本轮 UI 已隐藏其未生效控件。

下一轮先实现计划 M3：在已有完整路径 reservoir 上补齐纯 Reconnection 的双向求值、可见性与 PSS Jacobian，再接 SpatialReuse / Pairwise MIS。不要在未验证 shift 支持域与归一化前恢复旧的一跳近似时空合并。
