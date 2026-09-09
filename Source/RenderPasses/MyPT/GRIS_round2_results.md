# 第二轮：纯重连与空间 Pairwise MIS

日期：2026-09-09。第二轮在现有 MyPT 的 ReSTIR 模式中实现 M3，UI 仍只有 PT / ReSTIR。纯重连、空间 Pairwise MIS 和多轮缓冲交换已通过本轮 GPU 验收；尚不代表完整 GRIS 的跨版本画面对齐。

## 实现与参考对应

现有调度扩展为 `GeneratePaths → TracePaths → SpatialReuse × rounds → Resolve`。纯重连固定第二个表面顶点，不需要额外的 SpatialPathRetrace。普通 PT 继续使用原有 ray-tracing 入口。

- [Shift.slang](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/Shift.slang) 对照 [参考 computeShiftedIntegrandReconnection](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/Shift.slang:383)：重新构造重连点的入射方向和材质实例，求连接两端完整 BSDF/PDF、几何比例、PSS Jacobian 和可见性。
- [SpatialReuse.cs.slang](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/SpatialReuse.cs.slang) 对照 [参考 Pairwise 分支](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/SpatialReuse.cs.slang:340)：冻结中心样本，逐邻居计算双向重连，独立累计几何有效邻居数与合并置信度。
- [PathReservoir.slang](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/PathReservoir.slang) 对照 [参考 mergeWithResamplingMIS](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/PathReservoir.slang:356)：权重为 `pHat(Fshift) × J × Wsrc × MIS`，最终除选中目标值和 `validNeighborCount + 1`，不重复乘除 M。M 改为浮点置信度，避免多轮累计整数溢出。
- [MyPTGRIS.cpp](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/MyPTGRIS.cpp) 负责每轮只读输入、独立输出和缓冲交换；fresh 单独保留。空间关闭、邻居数为零或轮次为零，Resolve 直接读取 fresh。

主表面自发光、主表面 NEE、短路径及重连点两侧的 delta 事件继续保留在原 reservoir 中。它们不参与跨像素重连，由 defensive canonical 权重保护本像素贡献；不能根据中心抽中的路径类别跳过整轮。这样保持现有直接光照分工，不需要重写候选生成器或接入尚未验证的外部 DI。

## 本轮纠正的接口与数值差异

1. 参考路径长度与本项目 `surfaceScatters` 相差一个终止连接。重连点 NEE 对应 `surfaceScatters == 2`；重连点 BSDF 后立即命中光源/环境也为 2，需缓存不含终止 MIS 的后缀，再按新的 rc BSDF PDF 计算 MIS。更远端的后缀保留原终止 MIS。
2. 保存独立的 rc 前后 delta/transmission 事件，以及 `cachedJacobian = {primaryPdf, rcPdf, geometry}`；每次选入重连样本均写回目的空间的元数据。源 PDF 和几何项按存储顶点重建的连接方向求值，匹配参考纯重连重新评估源端的做法，避免采样方向与浮点顶点重建方向的差异污染 Jacobian。
3. Falcor 8 的 `StandardBSDF.sample()` 返回选中 lobe 的 weight，但 PDF 已是混合 PDF。ReSTIR 对 StandardMaterial 连续事件统一使用完整 `eval/pdf`，使候选与重连求值一致；delta 保留原 weight。该调整保持期望值，但会改变第一轮历史单帧图。`ptReference` 与初始 RIS 同步采用此候选定义。分层等其他材质仍用原 weight；其 `evalPdf` 可能是近似值，因此本轮不作为重连两端，以 canonical 保留本像素贡献。它们位于不变的深层后缀时可保留后缀追踪结果。
4. Falcor 8 的 StandardMaterial reference BSDF sampling 在透射求值时返回带符号的 PDF，采样时却返回正数。MyPT 的共享 PDF helper 对这一材质在关闭 importance sampling 时取绝对值，GRIS 的 NEE 与 shift 共用该修正，没有修改 Falcor 材质源码。
5. 可见性射线对连接两端作法线偏移，避免端点自遮挡。初始树还检查存储顶点重建的源连接：被邻接几何遮挡的数值边界样本标为本地保留，不扩大射线终点容差，也不进入单向成立的映射。自身像素采用精确的恒等映射；同位诊断重新求值 BSDF 贡献，Jacobian 使用恒等映射的解析值 1。跨像素诊断独立检查往返贡献与 Jacobian 乘积。
6. 本轮启用 [参考 Shift 的对称 Jacobian 拒绝规则](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/Shift.slang:556)，采用阈值 10，即 `max(J, 1/J) <= 11`，边界比较另留 `1e-5` 相对浮点容差。这样真实比例为 11 时，正反向浮点舍入不会一侧接受、一侧拒绝。这是比参考静态默认更保守的设置：极端粗糙透射在本版本重复求 PDF 时出现数值不一致，限制重连支持域后由 canonical 保留其原贡献，不裁剪辐射值。Jacobian 用对数比例计算，Pairwise 的质量乘积在中间溢出/下溢时使用对数计算；不可表示的最终质量仍计入无效诊断。支持域收窄会降低极端 glossy/透射的复用率。

## 用户入口与诊断

继续使用原启动参数：

```text
--script "C:\Users\13243\Desktop\Restir\Falcor\scripts\MyPT.py" --scene "C:\Users\13243\Desktop\Restir\Falcor\media\test_scenes\tutorial.pyscene"
```

[MyPT.py](C:/Users/13243/Desktop/Restir/Falcor/scripts/MyPT.py) 显式采用 1 个候选、3 个空间邻居、20 像素半径、1 轮、8 次间接 bounce，RR=0；保持原来的累积与 ToneMapper。空间参数在原 ReSTIR UI 内调整，关闭 Spatial reuse 可查看当前初始 RIS。

新增可选图输出 `initialColor`（空间复用前的结果）及 `spatialDebug`（末轮几何有效邻居数、成功重连数、所有轮次的最大同位贡献误差、最大往返误差）。它们是诊断纹理，不是新的渲染模式；不接诊断纹理时，不执行额外的同位/往返检查射线。

`spatialNeighborOffset` 是脚本专用的固定邻居测试参数，默认 `(0,0)` 使用随机圆盘；非零偏移固定邻居，重复邻居按重复提案计数。`spatialRadius=0` 取自身像素。

## 验证

编译与 GPU 命令：

```powershell
& tools/.packman/cmake/bin/cmake.exe --build build/windows-vs2022 --config Release --target MyPT -- /m:4 /nologo
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTGRISSpatialValidate.py --verbosity 2
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTGRISLayeredValidate.py --verbosity 2
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTEntrySmoke.py --verbosity 2
```

验证使用 Falcor 内置 Python 与项目 `build/gris-python` 中的 NumPy。空间验收以 96×64、Center/1、无累积/色调映射、固定相机和四个独立 seed 运行；逐 RGB 的配对 95% 置信区间须完整落在 ±1% 内，同时对照同帧初始 RIS 和同树 PTReference。漫反射/遮挡能量测试为必需项，材质/光照小预算回归另行记录统计精度，不以噪声大冒充通过。

实测环境：NVIDIA GeForce RTX 5070，驱动 610.88，D3D12。Release / MyPT 编译通过。最终完整空间验收耗时约 347 秒（含场景与 shader 初始化，不能当作单帧性能指标）。

- [完整报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-spatial-validation/report.json)：`status=passed`、`acceptance_pass=true`。17 项边界检查全部通过，包含关闭/零邻居/零轮次、越界、重复自身、最大候选与八轮 M 累计、重置、PT/ReSTIR 切换、83×47 分辨率和可选 view 输入。
- 11 组配置、4 个独立 seed，共 10,496 个能量测试帧。五组必需场景同时通过 initialColor 和 ptReference 的逐 RGB 配对 95% CI 验收；两个对照合计的最大均值相对差为 **0.0549%**，最远 CI 端点为 **0.3762%**，均在 ±1% 内。
- 五组分别为 tutorial 固定单邻居、重复邻居、随机两轮，以及 Cornell 间接光固定单邻居、随机两轮。相对 ptReference 的最大 RGB 均值差依次为 0.0549%、0.0456%、0.0312%、0.0177%、0.0431%。零初始贡献像素也实际接收到了邻居贡献，测试没有因空间复用从未成功而空通过。
- RR、关闭 MIS、均匀 BSDF、Alpha/环境以及重要性采样 glossy/delta/transmission 回归的能量对照均通过。**均匀采样透射组统计精度不足**：最大 RGB 均值差约 0.390%，最远 CI 端点约 1.694%，因此不宣称该组已达到 ±1%；未检测到持续偏差。所有配置的数值检查均通过：最大同位贡献重建误差和最大跨像素往返误差均约 **2.786×10⁻⁴**，小于 0.001；没有非有限贡献被无效计数悄悄丢弃。误差诊断包含每一空间轮次。
- [分层材质兼容报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-layered-check/report.json)：32×24、2 个 seed、8 帧、3 轮固定邻居。场景具有非零间接照明和几何有效邻居，但不接受分层材质端点的重连；开启空间复用后仍与初始 RIS 一致。
- [原入口检查](C:/Users/13243/Desktop/Restir/Falcor/build/gris-entry-validation/entry_checks.json)：实际加载 `scripts/MyPT.py` 与 `tutorial.pyscene`，640×360 累积 16 帧，输出非黑且有限；保存 [入口预览](C:/Users/13243/Desktop/Restir/Falcor/build/gris-entry-validation/MyPT-entry.ToneMapper.dst.0.png)。83×47 分辨率与不接 viewW 的分支也通过。该低样本预览仍有噪声，不作为 GRIS 画质对拍结论。
- `scripts/MyPTGRISSmoke.py` 再次通过初始 RIS 冒烟与关闭 emissive light 后间接光归零检查。普通 PT 入口继续使用原有实现；本轮没有新增渲染模式或重写它。

源文件、参考文件与 DLL 的哈希记录在 [source_state.json](C:/Users/13243/Desktop/Restir/Falcor/build/gris-spatial-validation/source_state.json)。数值脚本和小型分层场景均保存在 `scripts/MyPTGRISSpatialValidate.py`、`scripts/MyPTGRISLayeredValidate.py`、`scripts/MyPTGRISLayered.pyscene` 中，可按上述命令复跑。历史探针/失败捕获用于定位问题，最终验收以完整报告为准。

## 后续范围

M4 时间 Talbot/历史、M5 Hybrid/Random Replay 尚未实现。当前仍只支持三角形；跨 Falcor 版本同场景 HDR、参考外部 DI 分工及完整 GRIS 的性能/画质对拍仍未完成。同树 PTReference 能验证复用阶段的一致性，不能排除候选追踪器与参考实现共有或不同的误差。
