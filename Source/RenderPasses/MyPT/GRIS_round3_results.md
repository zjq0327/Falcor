# 第三轮：时间 Talbot 与历史管理

日期：2026-09-09。本轮在现有 MyPT 的 ReSTIR 模式中完成 M4，PT / ReSTIR 两种 UI 模式不变。时间 Talbot、重投影和历史管理已通过本轮验收；M5 Hybrid 和跨版本 GRIS 画质对齐不在本轮完成声明中。

## 与参考实现对应

执行顺序为 `GeneratePaths → TracePaths → TemporalReuse → SpatialReuse × rounds → Resolve → StoreHistory`。最后一步是 GPU 资源复制，保存当前 primary 和最终 reservoir，不另建追踪器。纯 Reconnection 无需 TemporalPathRetrace；它属于后续 Hybrid 的前缀重放阶段。

- [TemporalReuse.cs.slang](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/GRIS/TemporalReuse.cs.slang) 对照 [参考 Talbot 分支](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/TemporalReuse.cs.slang:143)，复用第二轮 Shift 和 reservoir 合并函数。
- [MyPTGRIS.cpp](C:/Users/13243/Desktop/Restir/Falcor/Source/RenderPasses/MyPT/MyPTGRIS.cpp) 对照 [参考执行顺序和帧末保存](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/ReSTIRPTPass.cpp:741)：空间复用后的最终结果成为下一帧历史。fresh 和时间输出均独立保留，便于逐阶段对照。
- 历史 primary 保存 PackedHitInfo 与当时真实 direction，通过现有 loadShadingData 恢复旧主表面。对应 [参考旧 VBuffer / 旧相机光线](C:/Users/13243/Desktop/Restir/ReSTIR_PT/Source/RenderPasses/ReSTIRPTPass/TemporalReuse.cs.slang:63)，也保留原入口实际使用的抖动采样方向。

记当前为 `(Fc,Wc,Mc)`、历史为 `(Fh,Wh,Mh)`，读取历史时只改 `Mh = min(Mh, historyLength × Mc)`，保留 Wh。两个方向的 shifted F 和 Jacobian 分别为 `(Fch,Jch)`、`(Fhc,Jhc)`：

```text
currentMIS = p(Fc) Mc / [p(Fc) Mc + p(Fch) Jch Mh]
historyMIS = p(Fh) Mh / [p(Fh) Mh + p(Fhc) Jhc Mc]
currentWeight = p(Fc) Wc currentMIS
historyWeight = p(Fhc) Jhc Wh historyMIS
Mout = Mc + Mh
Wout = weightSum / p(selected F)
```

最后使用 `finalizeGRIS(0)`，不再除 2 或 M。有效历史的零贡献/失败 shift 仍累计 M；首帧、禁用、越界、无历史命中或几何不相符时完整保留 fresh。只有 hit 和实际 direction 完全相同才用解析恒等映射 J=1；仅屏幕像素相同不足以判定恒等。

## 重投影与历史失效

已有 mvec 输入是 current→previous 的归一化屏幕偏移，按参考随机选择附近历史像素；缺 mvec 时使用缓存的上一帧无抖动 VP 投影当前静态世界坐标。浮点坐标经过 finite、屏幕边界检查后 floor，避免负数截断到屏幕边缘。主表面用材质、法线及同一历史相机空间中的相对深度过滤。

场景切换、参数/尺寸变化、灯光/材质/环境改变、几何移动/形变、相机实质属性变化以及外部刷新会使历史失效。额外消费 RenderGraph 累计的场景更新，避免切换图期间发生的变化丢失。相机正常移动允许重投影；Jitter 和 History 标记不会逐帧清空历史。若相机报告的上一帧矩阵与缓存历史不对应，则清空历史，避免使用跨越未执行帧的 mvec。

本轮沿用第二轮 StandardMaterial 重连端点、delta/local-only canonical 保留及约 11 倍的对称 Jacobian 支持范围。DOF 下时间复用旁路。变化后的几何、材质或光照后缀不继续复用；拓扑变化/需要 shader 重编译的场景变更仍受原 pass 的异常限制，不宣称已实现任意动态场景更新。

## 原入口与诊断

原启动命令继续使用 `scripts/MyPT.py` 与 `media/test_scenes/tutorial.pyscene`。该脚本显式打开时间复用、重投影和空间复用，历史上限 20，保留 1 个候选、3 个空间邻居、20 像素半径、1 轮及原 Accumulate/ToneMapper。

类默认 temporalReuse=false，保证未声明此参数的第二轮脚本仍执行 spatial-only；用户原 MyPT.py 显式设为 true。现有 ReSTIR UI 内提供 Temporal reuse / Temporal reprojection、History length 和深度/法线阈值，历史长度 0 旁路。

- `initialColor`：fresh 初始 RIS。
- `temporalColor`：时间后、空间前；时间旁路时等于 initialColor。
- `temporalDebug`：状态、实际参与的 clamped history M、是否存在正贡献的历史候选、最大双向往返误差。状态 0=首帧/旁路/全局失效，1=当前背景，2=重投影无效或越界，3=历史无命中，4=表面不相符，5=合法历史。
- `spatialDebug` 和最终 `color` 保留第二轮语义。不接诊断纹理时不执行额外往返检查射线。

## 验证

Release / MyPT 编译通过；四帧基础检查已验证首帧逐位旁路与 M 的增长/饱和。首轮完整验证使用 96×64、Center/1、每组 4 个独立 seed × 1024 帧，共 16,384 个能量测试帧。25 项边界检查和全部逐帧数值检查通过；tutorial / Cornell 间接光的 temporal-only 通过能量检查，两组 temporal+spatial 的置信区间仍超出 ±1%，首轮报告如实保留为 `energy_not_accepted`，不作通过声明。

确认测试在执行前固定为：只重测两组精度不足的 temporal+spatial，使用 16 个未用于首轮的新 seed，每个序列 2048 帧，共 65,536 帧。参数、ROI 和 ±1% 门槛不变，Student t 改用 15 个自由度；不依据运行中的区间提前停止，不与首轮 seed 混合。两组确认测试均通过全部比较；由于只重测两组，其独立报告保留 `partial_pass`。

首轮和确认运行合计执行 81,920 个能量测试帧。[汇总验收](C:/Users/13243/Desktop/Restir/Falcor/build/gris-temporal-confirmation/acceptance_summary.json) 的 `acceptance_pass=true`：首轮提供 25 项边界检查及两个 temporal-only 的通过证据，确认运行提供两个 temporal+spatial 的通过证据。原始 [首轮报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-temporal-validation/report.json) 和 [确认报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-temporal-confirmation/report.json) 均保留，不能将任一份单独称为全套能量通过。

四组配置分别检查 temporalColor 和最终 color，对照 initialColor / ptReference 的每个 RGB 通道。下列数字取四种比较中的最大绝对相对均值差，以及离零最远的 95% CI 端点：

- tutorial temporal-only，N=1、H=20：均值差 **0.0813%**，CI 端点 **0.8392%**。
- Cornell 间接光 temporal-only，N=4、H=20：均值差 **0.0902%**，CI 端点 **0.5974%**。
- tutorial temporal+spatial，N=4、H=20、4 邻居、1 轮：均值差 **0.0251%**，CI 端点 **0.1507%**。
- Cornell 间接光 temporal+spatial，N=4、H=20、4 邻居、2 轮：均值差 **0.2121%**，CI 端点 **0.6499%**。

全长序列的最大时间往返误差为 **8.272×10⁻⁶**，最大空间同位重建误差为 **2.054×10⁻⁴**，最大空间往返误差为 **2.866×10⁻⁴**，均小于 0.001。所有输出有限且非负，invalid contribution 计数为 0，M 和历史 M 均满足上限。每组均实际接受了时间候选，组合组均实际接受空间候选；Cornell 零初始贡献像素也实际获得了复用贡献，没有因复用始终失败而空通过。

25 项边界包含：禁用/历史长度 0、spatial-only、静态恒等与关闭重投影、历史饱和、零候选/零间接深度/全零贡献、最大历史设置、最终空间 reservoir 入历史、参数重置和可重复性、PT/ReSTIR 往返、尺寸/场景变化、缺 mvec 的矩阵回退及小幅移动、可选 viewW、小幅/大幅相机移动与显露区域、视场角变化、Stratified 抖动、灯光变化、未激活渲染图期间的灯光/相机变化、DOF 时间旁路。相机测试验证历史处理与映射的数值安全，不代替动态场景长序列能量或拖影验收。

实测使用 NVIDIA GeForce RTX 5070、驱动 610.88、D3D12。Release DLL 已编译通过；运行目录的 13 个 shader 与源码逐字节一致。两个能量报告包含初始化、读回和诊断开销，不能用其总耗时代表正常渲染的 GPU 性能。

原 `MyPT.py` 已实际运行 tutorial 场景，640×360 累积 16 帧，并通过 83×47 尺寸和可选 viewW 回归。保存 [入口报告](C:/Users/13243/Desktop/Restir/Falcor/build/gris-entry-round3/entry_checks.json) 与 [入口预览](C:/Users/13243/Desktop/Restir/Falcor/build/gris-entry-round3/MyPT-entry.ToneMapper.dst.0.png)。预览仍有低样本噪声，不作为完整 GRIS 画质对拍结论。

```powershell
& tools/.packman/cmake/bin/cmake.exe --build build/windows-vs2022 --config Release --target MyPT -- /m:4 /nologo
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTGRISTemporalValidate.py --verbosity 2
```

首轮命令使用未设置 `MYPT_TEMPORAL_*` 的默认环境。确认运行命令如下；该运行只覆盖两组组合配置，因此其报告仍标记为 partial suite：

```powershell
$env:MYPT_TEMPORAL_SEED_PROFILE = "confirmation"
$env:MYPT_TEMPORAL_FRAMES = "2048"
$env:MYPT_TEMPORAL_CASES = "tutorial_temporal_spatial,cornell_indirect_temporal_spatial"
$env:MYPT_TEMPORAL_SKIP_BOUNDARIES = "1"
$env:MYPT_TEMPORAL_BOUNDARY_ONLY = "0"
$env:MYPT_TEMPORAL_OUT = "build/gris-temporal-confirmation"
& build/windows-vs2022/bin/Release/Mogwai.exe --headless --script scripts/MyPTGRISTemporalValidate.py --verbosity 2
```

统计单位为独立重置后的完整 seed 序列；时间历史使相邻帧相关，不能把每一帧当成独立样本。数值脚本对 temporalColor 和最终 color 分别与 initialColor / 同树 ptReference 做逐 RGB 配对 95% CI 检查。两者共享候选追踪器，不能代替独立高样本 PT 或参考 GRIS 程序的跨版本 HDR 对拍。

脚本保存在 [MyPTGRISTemporalValidate.py](C:/Users/13243/Desktop/Restir/Falcor/scripts/MyPTGRISTemporalValidate.py)，两个结果目录分别保存各自的 validation_script.py 快照。当前源码、参考实现、场景脚本、DLL 及报告哈希见 [source_state.json](C:/Users/13243/Desktop/Restir/Falcor/build/gris-temporal-confirmation/source_state.json)；汇总与哈希生成脚本为 [gris-round3-provenance.py](C:/Users/13243/Desktop/Restir/Falcor/build/gris-round3-provenance.py)。首轮与确认之间没有修改生产代码。参考项目仍为 `8d12332228eb64bc234e27c6f7e0913a926285ab`，本轮开始时 MyPT 项目 HEAD 为 `d99833cd`，本轮修改尚未提交。

## 后续范围

下一阶段为 M5：Random Replay、Hybrid Shift、双向前缀重放和可逆性约束。本轮没有 TemporalPathRetrace / SpatialPathRetrace，也没有完整镜面/透射链路的 Hybrid 复用。M6 继续负责参考 GRIS 原始 HDR、DI 分工、动态稳定性与逐 pass 性能对齐；第二轮记录的均匀透射小预算精度不足项也没有因本轮完成而自动消除。
