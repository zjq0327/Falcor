# GRIS / ReSTIR PT + NRC 第一版接入计划（QueryOnly 修订版）

本版依据当前 NRC QueryOnly 实现修订：训练数据来自 GRIS 重采样前实际追踪的初始候选路径段，复用现有记录、打包和 bootstrap 契约。不恢复 Independent/UpdatePT，不为训练延长路径，也不额外运行一套 NRC QueryPT。按用户最新要求，直接在原 `ReSTIR` 模式上通过 `nrcUseCache` 开关启用，不增加渲染模式；实际验证范围与限制见 `GRIS_NRC_implementation.md`。

日期：2026-09-18。状态：保留设计与验收目标；入口已合并进原 ReSTIR，新入口 23 项 GPU/属性检查与独立 NRC 的 17 项回归均通过，报告见实现说明。旧报告不代替新入口回归；质量/性能结论单独记录，不将全部验收目标视为已覆盖。

## 1. 第一版目标和已确定的历史策略

在现有 GRIS 管线中，用 NRC 预测候选路径的尾部；缓存贡献与显式 emission、NEE 等贡献一起进入初始 reservoir，再参加时间和空间复用。

训练来源固定为 QueryOnly：在追踪前选择部分初始候选记录局部传输，记录选择独立于亮度、RIS 选择和历史复用。训练预算通过训练网格、每路径记录容量和优化迭代数控制；首版每个训练槽只记录一个像素的一条候选，不随每像素候选数线性增加训练槽数。

按用户要求，本版不处理网络在线更新造成的新旧预测差异：

- 保留 TemporalReuse、SpatialReuse 和 StoreHistory；不是关闭时间复用。
- 不因为每次网络训练而清空 reservoir 历史，不用新网络重新查询历史尾部，不做网络版本间的历史权重校正。
- 历史样本保留采样时已写入的缓存后缀。相机/像素变化导致的几何 shift、显式前缀重算、正常重采样和 W/M 更新仍照常进行；并非将整个历史 F/W 永久冻结。
- 继续执行现有的场景变动、resize、模式/重要参数变化、shader 重载等历史失效规则；显式 reset NRC 时也清历史，避免“清空缓存”后仍输出旧缓存尾部。
- 在线更新时允许历史使用旧预测，将其作为本版明确接受的近似。冻结网络仅用于诊断，不作为用户使用时间复用的前提。

第一版完整验收范围建议为：原 ReSTIR 的 NRC 缓存开关、批量 NRC 查询、多初始候选、纯 Reconnection、正常时间/空间复用和在线训练。ReSTIR 默认 `nrcUseCache=False`，显式 True 才启用；独立 NRC 模式默认 True 不变。Hybrid / RandomReplay 接缓存、异步训练、历史重评估放到后续版本。关闭缓存时原有 ReSTIR 的三种 shift 策略保持可用。

## 2. 修改后的每帧顺序

```text
MyPT::execute：选择 ReSTIR，nrcUseCache=True
  │
  ├─ 初始化/配置 NRC context，BeginFrame
  ├─ NRC.PrepareQueryTraining          [训练开启时；适配多候选]
  │     每训练槽选择 owner pixel + candidateIndex，清空路径记录
  │
  ├─ GRIS.GeneratePaths
  │     主表面、方向、种子；沿用现有职责
  │
  ├─ GRIS.TracePaths                  [修改]
  │     逐候选追踪显式前缀
  │     在查询点写 NRC query，完成归属该点的显式直接光
  │     仅 owner 候选记录实际经过的局部传输段，不追加训练射线
  │     保存每棵路径树的未归一化 reservoir 和待补全缓存贡献
  │
  ├─ NRC.BuildTrainingFromQuery        [训练开启时；复用转换 compute]
  │     过滤不完整记录，写 SDK 训练顶点与路径信息
  │     Cache 终止的有效记录追加末端 bootstrap query；不追踪射线
  │
  ├─ NRC.QueryAndTrain                [接入现有后端]
  │     批量推理及训练，供下一阶段读取查询结果
  │
  ├─ GRIS.FinalizeNrcCandidates       [新增 compute pass]
  │     预测 → Cache 贡献 → 加入对应路径树
  │     合并路径树 → finalizeRIS() → gFresh
  │
  ├─ GRIS.ValidateShift（连接调试输出时；移到补全之后）
  ├─ GRIS.TemporalReuse               [沿用；兼容 Cache]
  ├─ GRIS.SpatialReuse × rounds       [沿用；兼容 Cache]
  ├─ GRIS.Resolve                    [仍然 F × W]
  ├─ GRIS.StoreHistory               [仍保存最终 reservoir]
  └─ NRC.EndFrame
```

这张图对应本版启用缓存的纯 Reconnection，因此不执行 Hybrid 的 TemporalPathRetrace / SpatialPathRetrace。关闭缓存时它们在同一 ReSTIR 模式中维持原顺序。本文的“组合配置”均指 ReSTIR 的缓存开关配置，不是新增 Mode 枚举项。

当前 NRC 0.14 的公开入口是 QueryAndTrain，没有独立的 Infer/Train 及中间完成事件；本地 NrcIntegration 还检查同一 NRC frame 使用同一队列。因此本版不承诺训练与后续复用真正重叠，也不推断 SDK 内部推理和训练的精确执行次序。先建立正确的数据依赖，未来换用支持拆分的后端后，再设计异步训练。

训练冻结时跳过 PrepareQueryTraining、记录写入和 BuildTrainingFromQuery，设置 trainTheCache=false，但仍执行渲染查询、QueryAndTrain 和候选补全。只切换训练开关应保留同一网络和兼容的 GRIS 历史；配置变化导致的真实重分配/reset 则按生命周期规则处理。

### 2.1 训练 owner 与多候选映射

设像素数 P=width×height、每像素初始候选数 K、训练槽数 T=trainingWidth×trainingHeight、记录容量 V=nrcQueryTrainingMaxVertices。

1. 保留现有按整数像素块划分训练 cell、每 cell 每帧选择一个 owner pixel 的方式，以及奇数分辨率的精确逆映射。
2. 为每个槽追加 ownerCandidate 字段，在追踪前以独立 hash 流从 [0,K) 近似均匀选择，输入包含槽号、帧号和组合配置 seed。使用无显著取模偏差的区间映射，并验证不同候选索引的覆盖。K=1 时固定为 0。
3. NrcQueryRecording 初始化显式接收 pixel、candidateIndex；只有二者均匹配才获得有效 slot。其他候选不写此槽，也不覆盖其终止原因。每槽只有一个写入者。
4. 不依据 F、路径是否命中光源、是否成功查询、路径长度或 RIS 是否胜出来重新挑选 owner。owner 在背景或产生无效记录时写空训练路径，不在同帧换另一条“更好”的候选。
5. 训练路径缓存规模为 T 条、顶点缓存为 T×V；候选待补全缓存另为 P×K。SDK samplesPerPixel=K 只扩展渲染路径容量，不能把 SDK 训练网格解释为 T×K 条路径。
6. 组合配置训练记录采用当前 GRIS 帧号，与候选生成和 resetSampling 对齐；不得误用在 ReSTIR 分支不更新的普通 PT mFrameCount。普通 NRC 模式保留现有 owner 选择序列，候选索引恒为 0。

这是对原始路径提议分布的记录抽样，不是对 reservoir 分布的训练。记录损失不乘 reservoir.W、M、选择概率或 shift Jacobian；训练覆盖仍会受到相机分布、固定查询深度和无效记录过滤影响。

### 2.2 三类 throughput 和局部记录语义

GRIS tracer 中必须分别维护以下量：

- 相机累计 throughput：用于构造显式 F 和缓存 beta_q。
- 排除重连接点 BSDF 的 suffix throughput：用于 rcIrradiance 和几何 shift。
- recorder 的局部 beta/radiance：仅用于相邻可缓存顶点间的 SDK 训练记录；在新记录顶点处重置，不修改前两类量。

记录 hook 放在 tracePathImpl 的实际传输事件处，不从 PathBuilder 选中的 sample 或累计相机颜色反推标签：

1. 命中表面时先把 BSDF-hit emission（含该事件正确的 MIS）归给上一记录段，再 flush 前一段并创建新表面特征。表面自发光不成为该表面自身的散射目标。
2. 将实际已计算且通过可见性检查的解析灯、发光三角形和环境 NEE 局部贡献加入 recorder；使用 GRIS 的实际局部估计，不重新采样或补发 shadow ray。尤其 GRIS 有环境 NEE，不能照搬普通 NRC PT 无环境 NEE 的权重。
3. 每次散射使用 GRIS 最终确定的 bs.weight 更新 recorder.beta；Standard 连续 BSDF 经过 full-BSDF/mixture-PDF 重算后再记录，不能误用重算前的 selected-lobe 权重。
4. RR 存活对 recorder.beta 施加相同生存补偿；RR 死亡/真实吸收将末端 transport 置零，保留死亡前已观察到的局部光照。数值失败与真实吸收分别处理。
5. SDK 跳过的 delta、透射或不支持表面不创建训练顶点，但真实 BSDF、NEE 和段内权重继续累计，直到下一个支持顶点或路径终止。
6. computeDirect=false 时，从后续具有完整局部观测的支持表面开始记录，避免把被隐藏/未测量的主表面直接光写成零标签。记录代码不得为了补全它而增加可见性测试。

### 2.3 终止原因与 bootstrap

沿用现有 QueryOnly 的严格规则：

- Cache：保留查询点已有的直接光和 direct-probe 观测，末端 recorder.beta 恢复为 1；BuildTrainingFromQuery 从已记录的查询点特征创建一个训练 bootstrap query。
- Miss：计入实际环境命中贡献后，使用零未知尾部，不做 bootstrap。真实 BSDF 吸收、RR 死亡也不做 bootstrap。
- Depth / Overflow / ProbeLimit / Numeric：整条训练记录排除，SDK 路径信息写空，不用零尾部伪装完整观测，不延长射线来补齐。记录容量耗尽只停用该记录，渲染候选继续自己的追踪和查询。
- Background / 无有效记录顶点：写空路径。每槽每帧必须被初始化并转换为有效或空的 SDK 路径，不能残留上一帧数据。

缓存 direct probe 是生成候选本来需要的直接光估计，与训练开关无关。它经过的后继表面不成为新的训练顶点，probe miss 也不能把缓存终点改为真实 Miss。probe 使用独立权重状态；终了恢复缓存 beta_q、suffix_q 和 recorder 末端权重。

每条有效 Cache 训练路径首版独立追加一个 bootstrap query，保留现有打包契约，不与渲染 query 强行去重。渲染 query 使用表面原始特征，bootstrap 可能来自 SDK packed vertex；两者的量化、用途和索引不能默认为相同。组合配置不设置 SDK unbiased 标志，proportionUnbiased 继续固定为 0。

### 2.4 不参与训练的阶段与冻结验证

FinalizeNrcCandidates、TemporalReuse、SpatialReuse、Shift、Replay、ValidateShift 和额外 PT reference 均不写训练记录，也不提交训练 bootstrap。缓存预测通过 SDK bootstrap 进入目标，不由应用层再次加进 recorder.radiance；否则会重复计入同一尾部。历史样本只参与重采样，不当作新的光路观测重复训练。

保证“记录不扰动传输”需要独立诊断开关：在固定同一网络、帧号和种子的情况下，允许记录开/关而 SDK 优化始终关闭。对照候选的射线计数、显式 F、缓存位置、beta_q、suffix_q、传输与选择 RNG 状态；网络预测/最终颜色允许有已解释的批量推理浮点差异。不能拿在线训练后变化的网络与冻结网络做逐位相等测试，也不能直接按并行原子分配的 queryIndex 比较查询内容，应按 pixel/candidate 对齐。

### 2.5 容量、同步和统计

渲染查询最多 P×K 个，训练 bootstrap 最多 T 个。按 SDK 的 buffer allocation 信息验证查询特征/结果容量覆盖 P×K+T，QueryPathInfo 覆盖 P×K，训练顶点覆盖 T×V；这只是首版应用的需求上界，不替代 SDK 实际分配查询。所有乘法先用 64 位检查，限制超预算配置。

建立 Prepare → Trace → BuildTraining → QueryAndTrain → Finalize 的 UAV/资源状态依赖；BeginFrame 在本帧记录和查询之前且只调用一次，BuildTraining 追加查询时不能重置已有渲染查询计数。沿用 native SDK 调用后的 Falcor 状态恢复与同队列约束。

统计包含 owner 路径数、各候选索引覆盖、记录/接受顶点数、各终止和排除原因、渲染查询数、bootstrap 查询数、记录与 pending 显存，以及各阶段 GPU 时间。几何射线分别归于候选生成、终点 direct probe、时空 shift 和诊断；额外训练射线应恒为零。接受顶点数不能表述为独立真值数量。

### 2.6 首版训练能力的边界

固定 queryDepth 与 QueryOnly 是两个独立选择：前者沿用本计划首版的可验证截断策略，后者定义训练来源，不要求照搬普通 NRC 的 path-spread 启发式。训练开关和 owner 选择不改变固定截断条件。

若支持表面上的路径总在同一浅深度截断，查询点后的间接信号可能主要依赖自举；多记录一些初始候选也不会自动产生未追踪尾部的真值。网络权重发生变化不等于尾部已经收敛。需要分别测量不同 queryDepth 下的有效观测、查询点覆盖、冷启动与等时间图像误差。首版不通过独立长路径或训练专用续追踪掩盖此限制；若质量不达标，应将结论和后续方案单独报告。

## 3. GRIS 中逐文件、逐位置的修改

### 3.1 MyPT.cpp / MyPT.h：模式和生命周期

源码锚点：MyPT.h 的 Mode、mNRC、mGRIS；MyPT.cpp 的 execute()、renderUI()、reflect()、属性读写、场景设置和重载处理。

1. Mode 仅保留 PT/ReSTIR/NRC，保持其原枚举值，不新增模式。ReSTIR 默认关闭缓存，独立 NRC 默认开启缓存；同一 nrcUseCache 属性映射到目标模式独立保存的开关，模式切换时互不污染。显式 nrcUseCache 值优先于模式默认值且不依赖属性字典顺序；非法跨模式更新回滚两份开关。
2. GRIS 诊断输出、UI、资源和历史仍归属原 ReSTIR 分支；根据 nrcUseCache 判断是否接入 NRC。覆盖同模式内缓存切换和跨模式切换时的资源/历史清理，不依赖新增 mode 触发生命周期重置。
3. 增加组合配置参数和序列化：保存 mode=ReSTIR、nrcUseCache 的实际值、固定 queryDepth，以及现有 nrcTrainCache、nrcQueryTrainingMaxVertices、nrcTrainingIterations。记录容量不是追踪深度；不恢复 nrcTrainingSource / nrcTrainingMaxBounces / nrcUnbiasedTrainingRatio。ReSTIR 固定查询深度不受普通 NRC 的 nrcTerminationThreshold 控制，UI/统计明确区分。
4. 第一版 ReSTIR 启用缓存时明确使用 Reconnection。选择 Hybrid/RandomReplay 时给出不支持提示，不静默运行错误的 Cache replay；关闭缓存时三种 shift 均保持可用。
5. 缓存关闭、maxBounces=0、GI candidateCount=0 时旁路至原 GRIS，不生成 NRC 查询或训练。SDK 未构建/运行库缺失时显示原因并回退普通 GRIS，转换时清理不兼容历史。
6. 组合缓存路径沿用 NRC 的 MIS 约定；若要求强制开启 MIS，要在 UI/统计中明确。关闭缓存后的旁路仍尊重原 GRIS 的设置。
7. 每次在线训练不设置 mOptionsChanged，不发送每帧刷新标记，不重建 context，不清历史。真实配置和生命周期变化仍按既有逻辑处理。
8. 增加组合配置统计，训练来源为 QueryOnly、记录生产者为 GRISInitialCandidates；现有 getNRCStats() 的 trainingEnabled 只判断 Mode::NRC，需要适配 ReSTIR 缓存开关及真实旁路状态。原 NRC PT 的诊断语义保持兼容。

### 3.2 MyPTGRIS.cpp：核心调度插入点

源码锚点：executeGRIS() 中 defines / create()、结构化 buffer 分配、bind()、GRIS.TracePaths、GRIS.ValidateShift、ref<Buffer> current = mGRIS.fresh、GRIS.StoreHistory。

1. 根据 ReSTIR 的 nrcUseCache 开关及旁路条件确定是否启用 NRC，并添加 GRIS_USE_NRC 编译宏。
2. 创建新增 FinalizeNrcCandidates pass，加入 NRC SDK include 路径和资源绑定。
3. 用 shader reflection 分配每候选临时状态、pending cache contribution 等 buffer；数量为 width × height × candidateCount，检查乘法溢出和资源上限。
4. 在 TracePaths 前准备 NRC，训练开启时执行适配后的 PrepareQueryTraining，分配 T 条训练路径与 T×V 个顶点。TracePaths 的 owner 候选负责填充记录。
5. 在 TracePaths 后、ValidateShift 和任何 Temporal/Spatial 读取 gFresh 前，依次插入 BuildTrainingFromQuery（仅训练时）、QueryAndTrain 与 FinalizeNrcCandidates。
6. 保持 current 从已补全的 gFresh 开始，后续 temporal/spatial ping-pong 和历史拷贝沿用现有结构。
7. 外部 SDK 命令后的 Falcor 绑定恢复、UAV barrier 和提交复用现有桥接机制；不为“保险”在正常每个阶段添加 CPU 等 GPU。
8. getResourceStats() 包含临时候选、QueryOnly 记录和 SDK 公开 buffer；阶段计时包含 PrepareQueryTraining、TracePaths（含记录与 probe）、BuildTrainingFromQuery、QueryAndTrain、Finalize 及所有复用阶段。不得只报告节省的追踪时间。

### 3.3 GRIS/GeneratePaths.cs.slang：保留主表面生成

不增加网络推理。维持 gPrimary、gFresh、gReference 的初始化职责。每候选状态由 TracePaths 完整覆盖；无有效主表面和没有查询的候选也写入明确的无查询状态，避免读取上一帧数据。

### 3.4 GRIS/PathState.slang + 新增 GRIS/NrcQuery.slang：新增贡献类型和查询接口

1. PathTerminal 追加 Cache，不改变现有终端值。Cache 的 surfaceScatters 定义为到达查询表面 q 的散射次数（主表面深度 0），不虚构一条通向光源的连接；light 使用 None。
2. 已完成的 Cache PathSample 沿用 F、rcIrradiance、rcIndex、rcWi、rcSeed 等重连接字段。必要时补充调试深度字段，但不要把本帧 queryIndex 当作跨帧可解引用的数据。
3. 新增独立的每候选临时结构，保存：显式 tree reservoir、tree 选择 RNG 状态、显式 radiance 总和、pending 标记、queryIndex、Cache PathSample 描述，以及到 q 的完整 throughput 和排除 rc BSDF 后的 suffix throughput。
4. gNrcQueryRadiance 只在当前帧补全阶段读取；补全后的历史是数值快照，后续 BeginFrame 重用查询缓冲不能改变历史贡献。
5. 新 GRIS/NrcQuery.slang 接受显式 pixel/candidate 参数，使用固定 SDK 的查询分配、特征编码和打包契约，不引用 DispatchRaysIndex()，不修改 vendor 头文件。
6. SDK samplesPerPixel 与候选容量一致，使用正确的 sampleIndex。SDK 自己的 query-path 索引用 SDK helper 计算，不假定等于自定义临时 buffer 的索引。每候选最多一个渲染查询；训练 bootstrap 查询另按 SDK 容量要求预留。

### 3.5 GRIS/PathTracer.slang：实际截断位置

源码锚点：tracePathImpl() 中 emission 的 builder.add()、depth == maxScatters、本地 NEE、RR 和 sampleMyPTBSDF()。

本版建议采用固定查询深度作为最小可验证策略，例如从 queryDepth=2 开始调试（主表面 x0，固定重连接点 x1，查询点 x2）。在该深度表面不支持查询时，本条路径继续原来的显式追踪，不自动改成另一个依赖前缀的启发式终点。

查询条件包括：组合缓存模式、普通候选生成 traceMode、queryDepth 严格大于 rcIndex、当前表面为受支持的非 delta/不透射 Standard 表面，以及尚未到达显式硬截止。

顺序要求：

1. 保留当前命中 emission 及其原 MIS。
2. 先执行现有硬深度检查，保持零反弹和截止行为。
3. 按第 2.2 节记录上一段并创建当前受支持表面的训练顶点；只有 traceMode 为初始候选且 pixel/candidate 为 owner 时写入。符合查询条件时，保存 beta_q、suffix_q、descriptor 和查询特征，按 SDK 契约提交渲染查询。learnIrradiance=false 的前提保持一致。
4. 查询终点的直接光继续显式估计，之后停止普通尾部追踪；缓存补的是 includeDirectLighting=false 对应的剩余信号。
5. 终点不能只保留 NEE、丢掉与它配对的 BSDF 命中光源项。复用现有 NRC direct-probe 的贡献归属原则，适配 GRIS 的 emission / 环境 NEE / BSDF MIS；经过 SDK 跳过的镜面等顶点时，保持同一段的定义及终止保护。
6. direct-probe 使用独立状态，避免修改已保存的缓存 throughput、rc 描述或发起第二个缓存查询。其有限深度/保护上限语义要记录并验证。
7. RR 默认保留已有配置，验证时先关闭再开启；截断前的生存补偿与 rc BSDF 被排除后的 suffix 定义必须一致。
8. 为所有 break/return 明确分类终止原因；尤其区分硬深度、真实 BSDF 吸收、无效 PDF/非有限量和 probe 上限。nrcRecordFinish 在 owner 候选结束时仅执行一次；记录状态不允许改变普通候选的 break/return 条件。

不直接将整套 NRC_UPDATE 宏套在 GRIS tracer 上。SDK 训练记录函数会重置传入的局部 radiance/throughput，可能破坏 GRIS 的相机累计量。

固定深度是本版建议，不是 NRC SDK 原有开关。新 query adapter 需要按公开契约写查询记录，或使用经过验证的受控入口；不能先让 SDK 在错误深度创建查询，再丢弃返回状态。后续若引入 path-spread 截断，须补充正反向 shift 中终止支持域的一致性验证。

### 3.6 GRIS/PathBuilder.slang / TracePaths.cs.slang：将初始 RIS 分成两段

原 TracePaths 对每棵树调用 tracePathTree()，随后 mergeTree()，并在 dispatch 内 finalizeRIS()。

启用缓存时改为：

1. 每条候选正常把已知的显式贡献加入其 tree reservoir。
2. 返回包含 pending cache 信息的 trace result，保存 tree 和选择 RNG 状态。Cache 不以 0 或虚构预测提前参与选择。
3. 暂不合并到最终 gFresh，不做最终 RIS 归一化。
4. 非缓存编译分支保持原来的采样调用顺序和算法，作为精确旁路。
5. 训练记录与树内选择分离：记录所有已观察的局部贡献，不受 addContribution 是否选中、F 是否为零或当前 reservoir 内容影响。给 tracePathTree 增加显式 pixel/candidate 和记录开关；其余重放/验证入口默认禁用记录。零贡献树仍保留 M=1。

PathBuilder 的 acceptsContribution() 和终端分类中显式识别 Cache，不能落入 Emission/Environment 的“到达光源”分支。第一版不实现 Cache 的全路径 RandomReplay。

### 3.7 新增 GRIS/FinalizeNrcCandidates.cs.slang：把推理结果变成候选

每像素按候选序号读取临时 tree：

```text
C = 按 SDK 契约解码后的预测（恢复 SDK 的 radiance scale）
cache.F            = beta_q   × C
cache.rcIrradiance = suffix_q × C
cache.terminal     = Cache

tree.addContribution(cache, savedTreeSelection)
tree.M = 1
fresh.mergeTree(tree, pixelSelection)

所有 tree 合并后：fresh.finalizeRIS()
写入 gFresh
```

suffix_q 必须排除 rc BSDF，但包含现有定义要求的 RR 和后续采样权重；不能再乘一次 rc 的 f/pdf。网络输出不是直接的 rcIrradiance。

候选中有多个显式终端加一个 Cache 终端时，M 仍为一棵树。没有查询或贡献为零的候选也保留正确的树计数。保持每树选择流与跨树选择流分离。

现有 reservoir 不接受负 RGB。第一版建议对有限的负预测分量显式 clamp 到 0，再一致地构造 F 和 rcIrradiance，记录负预测数量/幅度，并声明这是额外的近似；不依赖 addContribution() 把含负值的整个候选悄悄丢掉。NaN/Inf 在验证中直接判失败，生产处理需有可见错误状态。

原 gReference 在启用缓存时若累加截断路径，只能叫“未重采样的缓存估计”，不能作为真实 PT reference。建议新增 initialEstimate 诊断；若请求原 ptReference，则额外用原始、不查询缓存的路径生成逻辑计算，并把额外成本排除在正式性能配置之外。该 reference trace 不写训练记录，也不用于给在线训练增加长路径真值。

### 3.8 GRIS/PathReservoir.slang：保留核心公式

目标函数、addContribution、mergeTree、mergeWithResamplingMIS、finalizeRIS / finalizeGRIS 的公式本版不改。缓存进入同一贡献集合。必要修改仅为终端兼容和诊断；历史网络版本校正不在本版范围内。

### 3.9 GRIS/Shift.slang：Cache 后缀参与重连接

源码锚点：supportsReconnection()、reconnectPath() 的 neeAtRc / hitAfterRc、F 重建、sameReplaySlot()、replayPath()。

1. Cache 必须满足 queryDepth > rcIndex，并满足现有连接几何、BSDF、可见性和 Jacobian 支持约束；失败仍由已有 canonical proposal 保留本地贡献。
2. 将 hitAfterRc 从“任何非 NEE 终端”改为明确的 Emission/Environment 判断，防止 q=rc+1 时对整个网络尾部错误应用光源命中 MIS。
3. Cache 分支重建 F 时保留连接前 BSDF、rc BSDF、PDF 和几何 Jacobian 的原逻辑，乘已保存的 rcIrradiance；没有额外的缓存终端光源 MIS。
4. 连接只改变 rc 的入射关系，保留 rc 之后的路径和查询方向；网络无需在 shift 中再次执行，历史也继续使用自己的缓存后缀。
5. Cache 全路径 Replay 在第一版明确不支持；通过启用缓存时的策略限制防止进入该分支，不用新 queryIndex 伪装成可重放的 light terminal。
6. 验证固定终止规则和 q 的特征在正反向映射中保持一致。通过 identity / round-trip 并不自动证明整体无偏，本版不作此承诺。

### 3.10 TemporalReuse / SpatialReuse / ReuseHelpers：沿用复用，更新类型与诊断

- TemporalReuse.cs.slang：保留 identicalContext 快捷分支、历史 M 限制及现有 MIS/merge 公式，不加入网络重查询。
- 非 identicalContext 时通过更新后的 Shift 重算几何贡献，缓存后缀仍为旧值。重采样输出的 W/M 正常变化。
- SpatialReuse.cs.slang：保持双向 shift、canonical 权重、邻居计数和各轮 ping-pong，允许 Cache 终端走新的重连接分支。
- ReuseHelpers.slang / ValidateShift.cs.slang：identity、往返和失败统计识别 Cache。纯 Reconnection 的检查也能独立重建缓存贡献，而不是直接返回原 F 冒充验证。
- TemporalPathRetrace.cs.slang / SpatialPathRetrace.cs.slang：本版启用缓存时不走 Hybrid，不修改其核心算法；后续接 Hybrid 时再补 Cache 相关前缀/终止一致性。

### 3.11 GRIS/Resolve.cs.slang / StoreHistory：保持最终估计形式

- color 仍为 reservoir.sample.F × reservoir.W，不在结果上再次加 NRC Resolve 的 cached color。
- 不运行当前逐像素 NRC Resolve 去覆盖 GRIS 输出；缓存补全发生在重采样之前。
- 若输出最终 explicit/cache 分量，按最终选中终端类型拆分 F × W；明确这是经过重采样的分量，不等于初始路径的分量。
- StoreHistory 仍保存最终 spatial reservoir 和 primary。只保存完成后的贡献，不能让历史依赖临时 query 缓冲的寿命。

## 4. NRC 侧配套修改

### MyPTNRC.cpp

抽出可共享的 context 配置、QueryOnly 记录 buffer 分配/绑定、PrepareQueryTraining / BuildTrainingFromQuery compute 创建与 SDK 帧生命周期辅助函数。ReSTIR 启用缓存时调用这些函数，由 GRIS.TracePaths 生产记录；不调用会生成独立图像的整个 executeNRC()，也不额外 dispatch NRC RayGen。原 NRC 模式仍由其 QueryPT 生产记录，保持像素 owner、随机序列、输出和冻结行为兼容。

必须逐项核对 GRIS 与普通 NRC PT 的局部传输差异：Standard BSDF 权重、发光体命中 MIS、环境 NEE、解析灯和 RR。共享数据契约与 recorder，不强制两条 tracer 使用相同采样实现，也不把不同估计器的单帧颜色差异直接判为 NRC 接入错误。

### NRC/NrcQueryTrainingData.slang / NrcPrepareQueryTraining.cs.slang

增加 ownerCandidate 和需要的候选数/种子常量，提供显式像素与候选索引的匹配接口。Prepare 每 cell 只初始化一次，候选索引采用独立选择流。对普通 NRC K=1 保留原来的 owner 像素选择；新字段固定为 0。所有 C++ binding、shader reflection 分配与热重载检查同步适配，避免共享 layout 变化留下旧 buffer。

### NRC/NrcQueryRecording.slang

保留局部段 beta/radiance 与 SDK packed vertex 的契约，初始化增加 candidate 参数。可缓存表面选择和段归属以第 2.2、2.3 节为准。compute tracer 使用显式 pixel，不依赖 DispatchRaysIndex。若需要提供原签名包装，普通 NRC 显式视为 candidate=0。不要让公共文件依赖 GRIS 的 reservoir 类型。

### NRC/NrcBuildTrainingFromQuery.cs.slang

首版复用现有过滤、顶点复制、训练路径打包和 bootstrap 分配逻辑，读取同一扩展后的记录结构。该 pass 仍然按 T 个训练 cell dispatch，不按 P×K；每槽完整写有效/空 SDK 信息。NRC_UPDATE=1 仅用于这里的 SDK 数据 helper，不编译为更新追踪器。

增加组合配置可用的逐槽/owner 诊断，明确 ownerCandidate 和排除原因；诊断纹理先清零，仅槽 owner 写入，避免多个候选覆盖。继续保证此 pass 不绑定加速结构、不发射射线、不读 reservoir 的 F/W/M。

### NRC/NrcIntegration.h/.cpp

复用已有 samplesPerPixel 配置并按候选数量设置；按第 2.5 节核验 SDK 实际分配，覆盖渲染和训练 bootstrap 的合计容量。trainingDimensions 继续使用 SDK 建议并限制在帧尺寸内，候选数不重复乘入训练槽数。保留 includeDirectLighting=false / learnIrradiance=false / proportionUnbiased=0、反射绑定、native command 后状态恢复和帧队列约束。本版不增加未获 SDK 支持的异步并发调用。

### NRC/NrcAdapter.slang

将可共享的表面特征提取抽为与 dispatch 类型无关的函数，或由 GRIS adapter 使用相同实现。保留现有 RayGen 路径的包装入口与仅支持 NRC_QUERY 的约束；GRIS 的查询分配和记录使用独立 compute 适配入口，不能直接包含依赖 DispatchRaysIndex 的整套 adapter。查询与记录使用一致的表面支持判定。

### CMakeLists.txt

注册 GRIS/NrcQuery.slang、GRIS/FinalizeNrcCandidates.cs.slang，以及实际抽出的共享文件；确认两个 QueryOnly compute 和修改后的记录文件均更新到部署目录，源码模式和部署模式均能找到 SDK include。验证 SDK OFF 时 ReSTIR 缓存配置的显式回退。

## 5. 实施里程碑和验收

### M1：调度、资源和严格旁路

在原 ReSTIR 中启用缓存开关，建立资源生命周期，接入 SDK。验证省略开关时三种 shift 默认不使用缓存、独立 NRC 默认开启缓存、属性序列化和同模式缓存开/关。缓存关闭时走原 GRIS 分支；固定种子比较 color、F/W/M 和原诊断。普通 GRIS 对照显式设置 nrcUseCache=False，组合测试显式 True，不通过切换 mode 假定缓存已关闭。覆盖零反弹、零候选、无场景、SDK 不可用、resize、模式切换和热重载。未通过不进入缓存质量评估。

### M2：候选补全与 QueryOnly 记录契约，无复用

先用 1 candidate 验证，再扩展 2/8 candidates。训练 owner 选择与传输、树内选择、树间选择 RNG 分离。确认每候选索引、tree.M、buffer 容量、frame clear 和 pending 生命周期；在固定查询描述/冻结网络下比较直接求和与多次 RIS 输出均值。覆盖 q=rc+1，检查终点 NEE/BSDF 光源配对、环境和 direct-probe。需要时用已知常量的诊断缓存输出隔离候选补全与实际网络质量问题。

按第 2.4 节进行记录开/关且优化关闭的对照，验证射线、显式贡献、截断和 RNG 不变。检查 owner 唯一写入、K=1/2/8 的候选覆盖、奇数分辨率、全背景、空批次、全部终止原因、记录容量小于查询深度、computeDirect=false、RR、镜面/玻璃链与环境 NEE。训练记录溢出不得改变渲染 query 或增加射线。

### M3：QueryOnly 在线训练，无复用

在 M2 数据契约通过后开启优化，验证有效局部记录进入 SDK、Cache 记录生成 bootstrap、真实终止禁用 bootstrap、无效记录整条排除；确认冻结/恢复保持同一网络并按预期停止/恢复更新。区分“网络确实更新”和“预测质量改善”两项结果。

从相同冷启动分别测试多个固定 queryDepth 和种子，比较独立高样本 PT 参考的误差、亮度与训练覆盖；参考只用于评估。检查浅截断自举是否停滞、增加候选数是否仅增加相关样本。总几何射线必须与相同网络状态下关闭记录的组合渲染一致；只有记录、打包和推理/优化成本增加。保存配置、计数、误差曲线和 GPU 阶段时间，禁止用接受顶点数或网络变化代替质量证据。

### M4：纯重连接空间复用

开启一个邻居再扩展多个邻居和多轮。验证同域 J=1、正反向 J 乘积、F 重建、遮挡拒绝与 canonical fallback。对静态场景比较复用前后的能量和误差；固定网络诊断用于区分 shift 问题与在线训练变化，不改变最终在线模式。

### M5：旧缓存快照的时间复用

开启在线训练和 TemporalReuse，确认训练不会每帧清历史，M 可正常增长。追踪一个被保存的 Cache 样本，确认后续帧不会用其过期 queryIndex 读当前查询 buffer；几何相同时保留旧贡献，变化时只按既定 shift 更新。验证相机运动、disocclusion、场景 reset 和原历史失效规则。记录可能的预测滞后，但不将跨版本校正列为本版通过门槛。

固定网络和候选种子，对比关闭/开启时空复用后的训练记录，必须仍来自同一批初始候选；历史 M 增长、空间轮数或验证 pass 不得增加训练顶点或 bootstrap 查询。

### M6：回归和性能测量

回归原 PT、ReSTIR 三种 shift、PT+NRC QueryOnly，复跑现有 QueryOnly 记录不扰动传输、缓存旁路与 SDK Resolve 对照测试。scripts/MyPTGRISNRC.py 演示入口及组合验证脚本均使用 mode=ReSTIR、nrcUseCache=True，显式设置 Reconnection，不沿用现有 MyPT.py 的 Hybrid 配置。

正式计时关闭 PT reference 和高成本诊断，包含 Prepare、带记录的候选追踪与 probe、BuildTraining、SDK QueryAndTrain、候选补全、所有复用阶段和资源成本。报告在线训练/冻结、K=1/2/8、不同 queryDepth 的同时间画质与显存；额外训练射线为零不代表训练免费。公开 SDK 冷启动成本与稳态成本，不预先承诺提速或无偏。

## 6. 完成边界

完成本版意味着：NRC 尾部作为真正的 GRIS 路径贡献参与候选选择和纯重连接的时空复用；训练只使用重采样前选定初始候选的实际局部观测与末端自举，没有额外训练射线；在线训练、冻结/恢复和历史旧预测快照行为可测试。实现验收与质量/性能结论分别记录；若出现浅路径自举停滞，必须如实报告。

不包含：恢复 Independent/UpdatePT、训练专用续追踪、把参考路径用于训练、历史预测刷新/网络版本权重校正、Cache 的 Hybrid 或全路径 RandomReplay、异步训练、使用选中/复用 reservoir 直接训练网络、无偏残差校正。性能收益需由实测决定。

## 7. 本计划依据

- 本仓库 MyPTGRIS.cpp / GRIS/*.slang 的候选生成、终端分解、重连接、时间/空间重采样和历史写回。
- 本仓库 MyPTNRC.cpp / NRC/* / PT/PathTransport.slang 的现有 NRC 训练查询与直接光处理。
- NRC_query_only_implementation.md 和当前 NrcQueryRecording / NrcPrepareQueryTraining / NrcBuildTrainingFromQuery 的记录契约、无效路径过滤与 bootstrap 规则；组合配置使用单独的 gris-query-only 报告验收，不沿用普通 NRC 报告代替。
- 固定 NRC 0.14 本地接口 external/nrc-sdk/Include/NrcD3d12.h、Nrc.hlsli、NrcCommon.h；尤其 QueryAndTrain、sampleIndex、查询 buffer 容量和同队列约束。

实施记录位于 `GRIS_NRC_implementation.md`；本文件保留计划目标，不把尚未实测的场景、收敛性或性能目标当作已完成结果。
