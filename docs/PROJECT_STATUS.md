# 项目状态

> 最后更新：2026-10-28 ｜ 当前阶段：作业一已完成（4 次运行取优）；作业二 Agent 改造完成，渐进链 L0/L1 已通过，L2 正在运行

## 1. 项目概览

- **目标**：THU AI EDA 课程两份作业。作业一：为 AES-128 加密核设计 Prompt 并比较 PPA；作业二：改造 EDA Agent 工作流（Diagnoser/Patch 拆分、上下文裁剪、节点级思维链），在 RV32I 处理器 L3 等级上用教师 TB、PPA 与 benchmark 证明改进。
- **当前阶段**：作业二渐进链 L0 ✓ → L1 ✓ → **L2 运行中**（rv32i5_predict，resume 自 L1）。
- **仓库/路径**：`F:\MyDesktop\研一上\人工智能电路设计\THU_AI_EDA_2026`
- **技术栈**：Python 3.12+（无框架，标准库 HTTP 服务）、Icarus Verilog 12.0 + Yosys 0.70 + OpenSTA（WSL）、DeepSeek API（deepseek-flash，OpenAI 兼容客户端）。

## 2. 目录结构

| 路径 | 放什么 |
|------|--------|
| `ai_eda/agent/` | Agent 编排（orchestrator.py 硬编码流水线）与子代理（subagents/：parser/planner/coder/tester/diagnoser/patch） |
| `ai_eda/agent/skills/` | 课程技能：rv32i5_l1_reference（L1 参考实现）、rv32i5_contract、cpu_diagnostics、fifo_area_power |
| `ai_eda/rtl/` | 教师 TB 执行、综合（metrics.py）、基准解析（runner.py 解析 AI_EDA_PERF/SUITE/CAPABILITY） |
| `ai_eda/web/` | 工作台（127.0.0.1:8000）：Prompt 页 / 参数实验页 / Agent 页 |
| `content/agent/simple_eda_agent.json` | Agent 画布可视化定义（**只读展示，不参与调度**） |
| `content/tasks/` | 教师任务：classroom_seq1011、homework_aes128、homework_rv32i5（L0-L3 specs + TB） |
| `content/prompts/` | 课堂 P1-P5 与作业 Prompt 模板 |
| `runs/prompt/`、`runs/agent/` | 运行记录（metadata/events/test_report/activity.vcd/handoffs/artifacts） |
| `作业1_Prompt设计.md` | 作业一报告素材（Prompt 全文 v2 + 设计基本思想 + 运行记录，纯文本可贴 Word） |
| `docs/` | 项目文档（本文件） |

## 3. 项目进展

### 已完成

- **2026-10-27** 作业一 AES-128：4 次运行全部 PASS。最终采用运行 2（11,688.86 µm² / 3.66 mW，tokens 63,394，延迟约 142 拍）；运行 4 面积最小（10,309 µm²）但延迟最短（约 100 拍）导致平均功耗口径偏高（6.13 mW）。完整分析见 `作业1_Prompt设计.md`。
- **2026-10-28** 修复工作台 VCD 缺失问题：iverilog 对中文路径 `$dumpfile` 失败会静默写 dump.vcd，runner.py 改为 ASCII 临时目录中转后复制回 run 目录。
- **2026-10-28** max_tokens 服务端上限修正为 393216（ModelClient 钳制兜底）。
- **2026-10-28** 作业二 Agent 改造（本轮核心）：
  - 拆分修复环节：新增 **Diagnoser**（思维链开：失败简报+文件清单 → failure packet：类别/根因/失败检查/涉及文件≤6/修复约束/已证伪假设）与 **Patch**（思维链关：只读 packet + 涉及文件，无状态单轮）；Modifier 移除。
  - 上下文裁剪：Patch 不再接收全工程快照与 45000 字符 Spec（旧 Modifier 每轮全量塞入）。
  - Tester 日志筛选：`build_failure_brief`（失败检查/suite/trace 失配 ≤8/编译错误尾部，过滤 iverilog 非致命 sorry 警告，内置 MODULE-MISSING / PORT-MISMATCH / HALT-TIMEOUT / ICACHE-REFILL 提示）。
  - 节点级思维链：Agent 页 5 个独立开关（Parser ✓/Planner ✓/Coder ✗/Diagnoser ✓/Patch ✗），`node_thinking` 经 server→orchestrator→base 逐层覆盖（UI 显式 > 类默认 > 运行级）。
  - Coder 每模块 Prompt 五段式（接口约束/微架构要点/时序约束/可综合约束/生成后自查），时序段按项目等级分档注入（L2/L3 追加 dbg_bp_*/dbg_ooo_* 事件约束）。
  - 渐进链进化模式：`resume_from` 指向已 PASS 且不同等级的运行时，复制上档 RTL 为现有工程，按新档 Spec 重跑 Parser/Planner/Coder；Planner 输出 `reuse: true` 标记复用模块，Coder 跳过复用模块。
  - Agent 页：Resume from run ID 输入框（跨等级手填）+ Resume last 按钮支持 passed 运行（语义=进化）+ 跑完自动回填 run ID。
- **2026-10-28** 渐进链 L0 ✓（agent-20261028T054527528613，第 1 轮 PASS，0 修复）→ **L1 ✓**（agent-20261028T124341881041，第 1 轮 PASS，0 修复）。

### 进行中

- **L2（rv32i5_predict）**：四次尝试均失败，根因已定性并完成流程修复（见已完成日志）。手动验证确认：四个"漏接/无驱动"信号修复后 halted 全部置位、base 测试恢复，剩余 105 个 D-Cache 数据通路错误属 Agent 可处理的具体数据错误。待用修复后的流程重跑。

### 下一步

1. 重跑 L2（resume 自 L1）：X-SIGNAL/MULTI-DRIVER 提示 + 顶层强制入 involved + extend 档接口兼容规则生效后的首轮检验。
2. L2 通过后 resume 冲刺 L3（rv32i5_l3_ooo，乱序+重命名，最难档）。
3. 收集各等级 benchmark（t:12）与 PPA（t:11）数据，填入报告。
4. Agent 页截图（改造前后 graph 对比）+ 报告"作业二"各表格成稿。

## 3.1 修复迭代日志（作业二）

- **2026-10-28 Agent L2 首次尝试失败**：`rv32i5_predict` resume 自 L1，6/8 轮修复未收敛（compile 端口混搭 → ECALL 停机超时 → 取指未启动 → PC 跑飞至程序镜像末尾），第 6 轮 Patch 连续返回空修改抛异常中止。tokens（输出估）104282。
- **2026-10-28 针对性修复**：①Patch 无效不再中止运行；②Coder 进化模式新增"进化纪律"。
- **2026-10-28 L2 第二次尝试仍失败**（agent-20261028T141956471840，7 轮，tokens 约 155k）：base suite 先挂（PC=0x0c 冻结），属集成损伤而非预测器能力问题。
- **2026-10-28 L2 第三次尝试失败 + 根因定性**（agent-20261028T145012151390，9 轮打满，tokens 约 158k）：9 轮 Patch 改 7 个文件（打地鼠）。定性：if_stage/rv32i5 每次从零生成，丢弃已验证集成。
- **2026-10-28 进化模式引入 extend 档（核心修复）**：Coder 以上档已验证实现为基线做最小扩展；Planner 三档规则（reuse/extend/new）；Diagnoser 假设史含 patched_files。
- **2026-10-28 L2 第四次尝试失败 + 手动定位根因**（agent-20261028T151620325980，4 轮，tokens 约 127k）：extend 档生效（结构不再洗牌），但四个**顶层信号漏接/无驱动**无法被发现（iverilog 对悬空输入静默产 X，简报不可见）：①`flush_epoch` 无驱动 → icache 响应被永久丢弃、PC 卡 0；②if_stage 缺 halt_pending/ecall_in_id → ECALL 被冲掉；③顶层 `flush` 线无驱动；④**dcache 漏接 `.halted`** → ready 恒 0 → load/store 全卡死。
- **2026-10-28 手动修复验证**：补上四个信号后，25 failures（PC 卡 0）→ 11 → **0 超时**（halted 全部置位、t02-t10 全过），最终暴露 105 个 D-Cache 数据通路错误（load 返回 0、store 数据错）——剩余为具体实现缺陷，交由升级后的 Diagnoser/Patch 处理。修复后工程保留于 run 目录 project/rtl。
- **2026-10-28 修复流程四步（可观测性缺口）**：①Tester 简报新增 MULTI-DRIVER 与 X-SIGNAL 提示（freeze/timeout ⇒ 优先怀疑悬空信号，检查顶层实例端口逐一对齐）；②Diagnoser 圈涉及文件时强制纳入顶层 rv32i5.sv；③Patch 纪律第 7 条（改顶层例化必须逐一对齐全部端口）；④Planner 进化规则第 5 条（extend 档 interfaces 只增不改删既有端口）。
- **2026-10-29 L2 第五次尝试失败 + 双重权威问题**（agent-20261028T160619977728，5 轮后取消，tokens 约 89k）：Plan 三档标记全部正确、Coder 也收到基线，但 Prompt 里"计划 interfaces 为准"与"基线既有端口不变"互相冲突——Planner 重写的 if_stage/hazard interfaces 与参考端口不一致，Coder 两头拉扯后顶层与模块各按一套 → 端口不匹配重演（att1/2），后续仍是 PC 卡 0（X 类）。
- **2026-10-29 端口权威顺序 + yosys 连线检测（最终闭环）**：①Coder 进化 Prompt 明确"基线既有端口 > 计划 interfaces（冲突以基线覆盖），计划只管新增端口"；②Planner 进化规则第 6 条：reuse/extend 模块的 interfaces 必须逐字继承旧计划同名条目，不得凭记忆重写；③**Tester 每轮新增 yosys 静态连线检查**（`find_wiring_faults`：`check` 报告无驱动/多驱动信号写入 report.checks + 简报 UNDRIVEN/MULTI-DRIVEN 提示）——用历史 run 回归验证：第 4/5 次尝试的所有 X bug（ecall_in_id、ex2mem_*、flush 无驱动）均被自动检出，手动修复后的工程无报告。
- **2026-10-29 参数默认值调整**：Agent 思考强度默认 low→**max**，修复轮次默认 8→**4**（server/orchestrator/前端三处同步）。
- **2026-10-30 L2 通过（第 11 次运行）**（agent-20261030T064427086710）：v4-pro + 8 轮预算 + epoch 守卫知识注入后，**3 轮内 PASS**。面积 160,049.6 µm² / 20.6 mW；18 次模型调用、输出 tokens 约 159.6k。benchmark：trained_branch64 误预测 2/64（预测器训练生效）；CPI 2.40–3.34（含 TB 访存等待）。**流程闭环验证**：retire-错位根因（icache 命中响应无 epoch 抑制 + if_stage 缺 inflight_epoch 守卫）的波形级知识注入 Coder 模式库/时序约束/简报提示后由 Agent 自主修复成功。
- **2026-10-30 L3 三次尝试失败（max token 族问题）**：①Planner 在 UI 默认 60000 预算下思维链耗尽（finish_reason=length）/JSON 截断；②Patch/Diagnoser "stop 但空正文"（reasoning 吃光预算）。归因：预算默认值不适合 v4-pro+max 推理；且截断/空正文直接杀死运行无自愈。
- **2026-10-31 取长补短续跑（第 16 次尝试）**：改用**最佳 L3 尝试直接续跑**——resume 自 agent-20261030T151602946743（4/5 suite + capability 已修），起点即 base/cache/predictor/performance 全 ✓，Agent 只需修 ooo 证据。启动脚本已固化为项目根 `_launch_portfolio.sh`（启动服务+提交 job 一条命令）。首次提交因 assistant 后续 pkill 误杀服务而中断（空目录已清理）；重跑只需在 WSL 执行 `bash _launch_portfolio.sh`。
- **2026-10-31 L3 终极根因铁证（13+ 次迭代的终点定性）**：检查 151602 参考核（4/5 suite）的顶层实例清单——**10 个实例全部是 L2 五级流水线模块，rename_unit/issue_queue/reorder_buffer/load_store_unit/physical_regfile 7 个 OoO 模块文件生成了但顶层从未例化（死代码）**。dbg_ooo_issue 恒 0 是必然：处理器实际仍是纯 L2 顺序流水线。此前所有修复轮失败的根本原因：Diagnoser 正确指出"缺发射证据"，但 Patch 修的是死代码或 regfile，**真正的问题是顶层集成缺失**——补丁无法完成"把乱序后端接进数据通路"的大型架构重构。
- **2026-10-31 集成前设计审查（读了全部参考模块内部）——生成的 OoO 模块集有两处架构级缺口需先补**：①rename_unit **没有 commit/squash/flush 输入端口**——spec_rat 永远无法从 checkpoint 恢复（误预测后 RAT 污染）、comm_rat 永不更新（dbg 读错）、free list 永不回收（8 条指令后 free_count=0 全核死锁）；②rename_unit **不输出重命名后的 ps1/ps2**——IQ/LSQ 的 alloc 接口需要它们，但 rename 只出 ROB 分配接口，顶层无法完成 IQ/LSQ 推入。修复方案已定：给 rename_unit 加 4 个输出（ren_ps1/ps2/new_prd/has_dest）+ 3 个输入（commit_valid/commit_new_prd/commit_arch_rd 或复用 ROB head 信号、flush/squash 恢复）；这些是小型机械修改（内部信号已存在），非重新设计。
- **下一轮的唯一任务（新会话）**：**顶层 OoO 集成**——把 L3 参考核的 rename/IQ/ROB/LSU 真正接进数据通路（参考 spec D 节：前端可保留 IF/ID，后端改为 分派→选择发射→执行→ROB 提交；D.5 接口合同已冻结在 spec）。两条路径：a) 直接手写集成后的顶层（对照参考 rename/IQ/ROB 模块接口，一次性重写 rv32i5.sv 的实例化与连线）；b) 为 L3 做完整参考核（像 L1 一样全参考 fallback）。参考模块本身（151602 的 project/rtl 19 文件）质量已验证（单模块编译/逻辑可用），缺的只是集成。
- **2026-10-31 L3 第 17~18 次运行（用户自跑）归因**：R1 均达 base/cache/predictor ✓（参考 fallback 生效），ooo/performance ✗ 且**修复轮全部卡死在 `physical_regfile.sv` 编译门**——模型反复无法产出修复 ooo 发射证据的有效补丁。**根因定性（最终）**：参考核（151602 最终态）本身就是顺序单发射——issue_queue 模块存在但从未产生真实的乱序发射行为，`dbg_ooo_issue` 恒 0。这不是补丁能修的：**需要在参考核中实现真正的乱序发射逻辑**（spec D.1：IQ 中源 PR ready 的 ALU 指令在更老 load 等待时也要发射）。这是唯一剩余的工程缺口，需要为 L3 参考集手写可工作的 issue_queue/rename 逻辑（新会话任务）。
- **2026-10-31 功耗数值物理自洽性审查（重大发现）**：助教公布作业一参考值（约 1000 / 130，单位待确认）后做物理检验——我们的功耗存在**系统性虚高约 100 倍**：等效开关电容 46 pF，而 4000 门设计的物理真实值仅 ~15-20 fF（差 1000 倍量级）；功率密度 31 万 W/mm²（45nm 物理上限 ~1-2 W/mm²）。而泄漏 50.4 µW（4.3 nW/µm²）与面积口径自洽 ✓。**结论：动态功耗计算路径（OpenSTA read_vcd 活动注记）有系统性错误**——prime suspect 是 VCD 时间刻度/活动注记问题或电容单位混淆；泄漏路径（纯库查表）正确。待办：带 unit 注记重跑 OpenSTA report_power 检查原始输出；对照助教参考值的确切单位与流程。助教参考值 1000 µm² 若为 µm² 则对 AES-128 物理不可能（最小已发表 ~1700 GE≈3400 µm²）——需向助教确认单位定义。（预算升档环 + 端口覆盖检查 + 补丁降级阶梯全量实战）**：第 14 次（agent-20261031T012130730550）死于 events.json 原子重命名被 Windows 侧读句柄锁住（PermissionError）——已修 `_write_json` 带退避重试 ×5，且监控改为全 WSL 侧（不从 Windows 读 events.json）。第 15 次（job 2348ae83628b，run agent-20261031T165020205700，flash + 10 轮 + Patch L3 开思维链）：R1 一次生成了含 rename_unit/issue_queue/reorder_buffer/lsu 的完整 OoO 结构（Planner 蓝图完全落地），R2 修复后 base/cache/ooo ✓（predictor/performance 因 capability 常量与 predictor 证据未过）；R3-R6 Patch 反复栽在 **rename_unit.sv 编译门**（rename 单元是 OoO 最难模块，flash+thinking 也无法产出编译干净的实现），checkpoint 回退持续兜底 base/cache。运行在预算内继续。
- **2026-10-30 L3 迭代（第 10~11 次运行，checkpoint 回退首秀）**：第 10 次（agent-20261030T115557686578，8 轮 43.6 万 tok）——**升档环全程零截断**（max-token 族问题根除），R1 一次生成即过 base+predictor；R2 修 ooo 时把 alu_complete_valid 弄成无驱动、base 退化（打地鼠）→ **新增 checkpoint 回退机制**（orchestrator 修复回环：每轮快照 project/，suite 通过数低于历史最佳即恢复最佳快照，restore 事件可见）。第 11 次（agent-20261030T151602946743，9 轮 12.2 万 tok）——回退机制多次实战（restore×3），最终 **base/cache/predictor/performance 四 suite 全 PASS**，capability 常量（dbg_features 3'b011→3'b111）人工辅助修正后正式 retest 确认。
- **2026-10-30 L3 唯一剩余缺口（诚实定性）**：ooo suite——`OoO issued only 0 instructions`：**乱序旁路的架构实现缺失**（load 等待外存时发射队列未并行发射年轻 ALU 指令），这是大架构功能而非连线/预算问题；OOO-BYPASS 提示已加入简报（指向发射队列并行性、ROB 完成握手驱动、旁路计数三处检查）。
- **2026-10-31 L3 第 12~13 次运行（1/2/3 模块信息注入 + checkpoint 回退实战）**：Planner 蓝图完全采纳（D.4 强制的 rename_unit/issue_queue/reorder_buffer/load_store_unit 全部入计划并生成）；第 13 次 R1 即过 base/cache/ooo 三 suite（历史最佳 R1）。剩余卡点集中在两类**重复漏接**：①icache/dcache 的 `cache_idle`（reuse 模块输出，L3 新顶层漏接）；②ex_stage 的新 OoO 接口（halted/id2ex_dest_prd 等）。第 13 次 R2 一轮修复解决三处漏接中的两处+使 ooo ✓，但 R2 收尾死于 /mnt/f 瞬态 Permission denied（OSError 未入回环韧性，已修：except (ValueError, OSError)）。predictor 缺 branch-resolution evidence 未解。
- **2026-10-31 流程修补**：①修复回环韧性扩至 OSError；②Parser L3 预告知（验收阈值/能力位写入 spec_addendum）；③Planner L3 蓝图（D.4 强制模块/D.5 合同/E 阈值/乱序语义）；④Coder OOO 模式库（分派/发射分离、bypass 判据含 dmem_valid=1&&dmem_ready=0 同拍、RAT/free-list、顺序提交）；⑤Patch L3 动态开思维链（`_model_options_for`）。
- **2026-10-30 预算自愈机制（base.py 预算升档环）**：每个模型调用最多 3 档——finish_reason=length → 输出预算翻倍（上限 393216）重试；stop 但空正文且思维链开启 → 关闭思维链重试（正文优先）；空正文以异常抛出时同样接住升档。瞬态网络重试（timeout/connection，2 次）保留。默认 max_tokens 三处 60000→200000（server/orchestrator/UI）。四场景单测通过（length 升档/空正文降思维链/空正文+length 异常升档/正常直通）。
  - **第 7 次**（agent-20261029T170354767419）：补丁式扩展首次全程走通，但顶层实例漏接（icache/dcache 的 halted）导致 PC 卡 0——**yosys check 抓不到"实例输入端口悬空"**（黑盒输入静默 X），是检测盲区。
  - **新增端口覆盖检查**（`find_missing_port_connections`，纯文本解析 module 端口集 vs 实例连接集）：用第 7 次工程回归验证，**精确报出 u_icache/u_dcache 漏接 halted**——盲区堵死。
  - **第 8 次**（agent-20261029T172536573152）：R1 检测点名漏接 → R2 只剩 1 处 → R3 起**编译干净、连线零缺陷**。但 att3/4/5 全部 simulation_timeout——**timeout_seconds=20 对 L2 是刀口配置**（实测 20.1s，被错杀）；手动 240s 验证：TB 完整跑完，失败降至 **42 个**且集中于预测器错误路径副作用。timeout 已改 60s。
  - **第 9 次**（agent-20261029T172536573152 后续 + 60s 配置）：**cache ✓ ooo ✓ performance_correctness ✓**（att4），R2 起仿真完整；剩余失败为 **"retire PC/instruction does not match the loaded program"**（IF 取指数据在 imem 等待周期下与 PC 错位）+ att4 修复使 predictor 回归（打地鼠）。最终 FAIL。
  - **过程 bug 均已修复**：_quick_compile_check 调用方式、extract_json_payload 缺导入、Planner 60000 预算爆（max_tokens→150k）、补丁锚点幻觉（difflib 基线对照反馈）、no-op 补丁摆烂（协议降级阶梯：3 轮补丁 → 第 4 轮完整文件）、逐次补丁输出落盘。
- **2026-10-29 L2 第六次尝试**（agent-20261029T153248067710，5 轮，tokens 约 215k）：**连线检测首次实战成功**——att1 的 undriven（id2ex_bp_pred_valid）被自动检出并修复，att2 起编译干净。剩余失败为全新类型：取指数据错位（前端交付 TB 默认填充字 0xB4B4B4B6，icache→IF/ID 数据对齐 bug）——扩展代码自带的数据通路缺陷；Diagnoser att2 上下文失控（48k tokens）。
- **2026-10-29 流程升级：补丁式扩展 + 编译门（结构性收口）**：①**Coder extend 档改为补丁协议**——不再输出完整文件，输出 JSON edits（expected 锚点/replacement），本地经 patches.py 原子应用，附三重守卫（端口行只增不改 / 新增 ≤400 行 / 补丁重试 ≤3 次），从机制上禁止"重写式扩展"引入变体；②**Patch 编译门**——补丁应用后立即用 iverilog 编译整个工程（不含 TB），确定性错误就地重试（≤2 次）后再进教师 TB，不再用完整 TB 轮次验证语法错误；③Diagnoser previous_hypotheses 上限 3 条（防上下文失控）。
5. 性能门方案（PASS 后对照 spec 的 CPI 验收线做优化回环）已设计未实现——视 L2/L3 战况决定是否需要。

## 4. 测试环境

| 环境 | 地址/端口 | 启动方式 | 版本/备注 |
|------|-----------|----------|-----------|
| 工作台 Web | 127.0.0.1:8000 | WSL 内 `make web`（`.venv/bin/python -m ai_eda serve`） | Python 3.14 (.venv)，改动 Python/前端后需重启 |
| 仿真/综合工具 | WSL | iverilog -g2012 / yosys 0.70 / OpenSTA(sta) | iverilog 12.0（注意：always_comb 内部分选择会报非致命 sorry 警告） |
| 模型 | api.deepseek.com | deepseek-flash | thinking/reasoning_effort 可按节点配置 |

注意事项：
- iverilog 的 `sorry: constant selects` 是**非致命警告**（"all bits will be included" 回退，exit=0），真正错误是其余 error 行；`build_failure_brief` 已过滤。
- iverilog 对**中文路径**的 `$dumpfile` 会静默写错位置——runner.py 已用 ASCII 临时目录中转，勿绕过。
- Agent 改造后必须重启 Web 服务；浏览器强刷（Ctrl+F5）加载新前端。
- 新发现的课程资产问题：`content/agent/skills/rv32i5_l1_reference/` 参考实现编译时有 91 条 sorry 警告（非致命，已确认不阻塞）。

## 5. 测试数据

| 数据 | 位置 | 生成/获取方式 | 规模 |
|------|------|---------------|------|
| 作业一运行记录 | `runs/prompt/classroom_seq1011/`（4 次课堂 + web-p*）与 `runs/prompt/homework_aes128/`（4 次 hw-*） | 工作台运行 | 每次 run 含 metadata/test_report/activity.vcd |
| Agent 渐进链 | `runs/agent/agent-20261028T054527528613`（L0）、`agent-20261028T124341881041`（L1）、`agent-20261028T125945961227`（L2 进行中） | 工作台 Agent 页（resume 链） | 每次含 events.json/test_report/handoffs/artifacts |
| L1 参考实现 | `content/agent/skills/rv32i5_l1_reference/*.sv`（11 文件） | 课程自带 | 91 条 sorry 警告，非致命 |

## 6. 测试情况

- **2026-10-28 作业一 AES**（工作台，deepseek-flash）：4 次生成 + Run TB + Evaluate 全部 PASS。数据：运行 1=11758.31 µm²/5.62 mW/tokens 67288；运行 2=11688.86/3.66 mW/63394；运行 3=11136.02/5.21 mW/59380；运行 4=10309.11/6.13 mW/84548。最终采用运行 2。
- **2026-10-28 Agent L0 基线**：`rv32i5`，PASS（第 1 轮，0 修复）；面积 38783.89 µm²、7.91 mW；tokens（输出估）34906；模型调用 10；CPI 1.25–1.66。
- **2026-10-28 Agent L1 首次失败→修复→通过**：`rv32i5_cache` resume 自 L0，第一次运行（agent-20261028T075806016624）失败于 compile——①plan 缺 alu 模块（参考 ex_stage 例化它）②L0 复用 forwarding_unit 与 L1 参考 ex_stage 端口不一致（11 个 port 错误）③Patch 重试丢失上下文（代码 bug）。三项修复后重跑：**PASS（第 1 轮，0 修复）**，面积 136745.1 µm²、18.8 mW；CPI 2.40–3.34（受 TB 插入的存储器等待周期影响，等级越高访存越多）；tokens 18349；模型调用 3（Coder 全部来自参考集/复用，无生成调用）。
- **2026-10-28 Agent L2**：运行中（rv32i5_predict，resume 自 L1 run agent-20261028T124341881041）。

## 7. 关键决策与风险

- **2026-10-28 助教建议采纳为渐进链策略**：L0→L1→L2→L3 逐级 resume，前级 PASS 输出作为后级输入（进化模式），避免直接攻 L3 烧 token。
- **2026-10-28 reference fallback 全集写入**：Coder 在项目有参考实现时写全参考文件（含 plan 漏列的 alu.sv），且参考优先于上档复用——消除 alu 缺失与端口混搭两类编译失败；代价是 L1 基本由参考实现兜底（模型自主性后移到 L2/L3），报告中如实记录。
- **2026-10-28 功耗口径效应**（作业一）：固定工作量的平均功耗 = 能量/时长，更快的实现数值必然更高；报告比较功耗必须同时给出延迟。
- **风险**：L3（乱序+重命名）难度最高且无参考兜底，Diagnoser/Patch 首次真实作战；若 8 轮修复内不通过，备选：增加 max_repair_attempts、调整 failure packet 模板、或退而提交 L2。
- **风险**：iverilog 12.0 对 always_comb 部分选择报非致命 sorry（语义回退），L2/L3 参考代码/生成代码可能大量触发；已确认不阻塞编译，但生成代码的功能正确性需教师 TB 兜底。

## 8. 待确认

- L1 的 benchmark 分支/乱序列全为 0：系 L1 dbg 能力位（3'b001）不含 BP/OoO 观测所致，报告 t:12 按 N/A 处理——待与助教确认口径。
- 报告 t:11/t:12 的"消耗时间"目前用"运行 ID 时间戳→test_report.json 写盘"推算（Agent 页实时计时器不持久化）；是否需要在前端持久化计时，待定。
- `metadata.json` 尚未记录 `node_thinking` 配置（报告"模型与主要参数"列需要）；待补。
