# 运行记录（Run Records）——助教验收指引

本目录是作业二 Agent 全部里程碑运行的**证据固化包**（从本地 `runs/agent/` 精选拷贝，与报告《作业2_报告填写草稿.md》中的编号一一对应）。

## 一键复验（30 秒出核心证据）

```bash
bash submission/verify_l3.sh
# 预期输出（本仓库提交时实测，见 submission/verify_l3_output.txt）：
#   LAB_RESULT: PASS (21 tests, 372633 checks)
#   AI_EDA_CAPABILITY|level=3|declared=3|verified=3
#   Chip area for top module 'rv32i5': 215236.936200
```

## 目录结构

```
run_records/<运行编号>/
├── tester-0N/test_report.json   # 每轮验收：教师 TB 完整日志（stdout 字段）+ 全部检查项
│                                #   + 连线/可综合性门禁 + PPA 指标（area / total_power_w）
├── artifacts/                   # 该 run 的关键产物
│   ├── effective_spec.md        #   Parser 输出的结构化规格
│   ├── plan.json                #   Planner 的模块契约（端口/命名冻结）
│   ├── rtl_manifest*.json       #   Coder→Tester 的文件清单
│   ├── failure_packet_attemptN.json  # Diagnoser 的失败压缩包（每修复轮一份）
│   └── generated_attemptN.sv    #   每轮 RTL 快照（= 该轮实际验收内容，可独立复跑）
├── events.json                  # （精选 PASS run）全程 LLM 对话留痕
└── metadata.json                # resume 谱系（本 run 继承自哪个 run）
```

## 里程碑运行一览（与报告表格对应）

| 运行编号 | 等级 | 结果 | 面积/功耗 | 备注 |
|---|---|---|---|---|
| agent-20261028T054527528613 | L0 | PASS | — | 五级流水线首跑通过 |
| agent-20261028T124341881041 | L1 | PASS | — | I/D Cache |
| agent-20261030T064427086710 | L2 | PASS | 160,050 µm² / 20.6 mW | 20 轮修复 |
| agent-20261101T014821459172 | L3 | FAIL(冻结) | — | 8 轮全冻结（bug 模式库的来源） |
| agent-20261101T053325440352 | L3 | FAIL(冻结) | — | 续跑仍冻（累计 23 轮） |
| agent-20261102T034020497959 | L3 | **PASS** | — | 首次 verified=3（resume 上述失败 run） |
| agent-20261102T235619729328 | L3 | FAIL(综合门禁) | — | 发现"能仿≠能综合"，FIFO→位向量 |
| agent-20261103T152338088874 | L3 | **PASS** | 350,942 µm² / 76.3 mW | 重构后 PASS，PPA 首次产出 |
| agent-20261103T155135456546 | L3 | **PASS** | 215,820 µm² / 21.8 mW | 8 轮 PPA 优化（-38.5%/-71.4%） |
| agent-20261103T172733151244 | L3 | FAIL(面积预算) | **215,237 µm² / 17.0 mW** | 岛屿A冠军；功耗达标，面积预算 190k 未达（实验性预算） |
| agent-20261104T153840912803 | L3 | FAIL(面积预算) | 151,942 µm² 突变体被 bench 检查拦截 | 岛屿B |
| agent-20261104T165552175590 | L3 | FAIL(面积预算) | 探索至 151,102 µm² / 16.5 mW | 岛屿C：面积-功能强耦合实证 |
| agent-20261105T005710448730 | L3 | **PASS** | **215,237 µm² / 17.0 mW** | **最终提交物确认跑（零失败检查）** |

## 核对要点

1. 最终 RTL 与 `submission/l3_final_rtl/` 完全一致（md5 见提交说明）；
2. 任一 `test_report.json` 的 `stdout` 字段内含当轮完整教师 TB 日志（含 `LAB_RESULT` 与 `AI_EDA_CAPABILITY` 行）；
3. 岛屿 run 的 FAIL 状态均为**实验性 PPA 预算未达成**（`ppa_area_budget` 检查），其功能验收（`LAB_RESULT`）与可综合性门禁均为通过——这正是报告"面积合法下限"结论的证据；
4. `artifacts/manifest.jsonl`（最后阶段 run）记录每个产物的 sha256，可校验报告引用与仓库内容一致。
