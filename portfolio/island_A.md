# L3 岛屿优化指令（运行时注入；预算门禁已在 tester 强制）

## 铁律（违反 = 锁存器硬错误或 TB 回退，前几轮的血泪）
1. 写使能只加在 always_ff 的时钟更新（`else if (we) cur <= nxt;`）；
   always_comb 的 nxt 必须每拍无条件全量默认赋值 + 条件覆盖。
2. 循环变量一律块作用域 `for (int i = ...)`，模块级 integer 一个不留。
3. 数组一律打包形式（`[N-1:0][W-1:0]`），禁止未打包数组。
4. 每完成一小步就自测：TB 全量 + synthesis_gate；一次只动一个模块。
5. 端口/模块/文件名不改；dbg_* 语义不变；TB PASS + 门禁过 + 双预算达标才收工。

## 当前冠军（必须超越的线）
- 全设计：面积 215,820 µm² / 功耗 21.8 mW（本岛预算更紧，达标线见 tester 报告）
- 每模块面积基线：PRF 67.2k | rename 26.0k | commit 18.3k | BP 17.8k | dcache 18.3k |
  icache 13.7k | IQ 21.0k | ROB 19.0k | LSU 4.7k | EX 5.3k | IF 3.5k | id 0.4k | top 0.7k

## 本岛侧重：PRF（67.2k，全设计 31%）与读端口
按期望收益排序，做一条验一条：
1. dbg 读口复用：dbg_raddr/dbg_rdata 是低频调试读，与 lsu_raddr1/rdata1 共享同一组
   40:1 读 mux（2:1 地址 mux 选择），省一整棵读树（预期 -4~6k）。
2. x10 读口复用：x10_raddr/x10_rdata 只在 ECALL 提交沿需要，可与 iq_raddr0 复用
   （提交周期 IQ 必然不发射——halt 前提下成立；若不确定就用 2:1 mux 方案）。
3. PRF ready 位与 clear_ready：ready 位已门控则跳过；确认无每拍重写。
4. IQ payload 审计：iq_issue_pc 仅分支/JAL/JALR 需要（用 is_branch||is_jump 门控存储？
   不可行——字段必须常驻，跳过）；iq_issue_pred_next_pc 确认被误预测比较消费，保留。
5. ROB：ent_data 仅 load 提交需要——不可省（字段必须常驻）。ent_instr 供 dbg_retire_insn
   必须保留。审慎，若无收益就停在 1-3。
注意：预算 area<190000 且 power<0.020，双达标才算本岛成功。
