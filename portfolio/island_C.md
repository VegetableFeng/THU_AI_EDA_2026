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

## 本岛侧重：commit_unit(18.3k)/IQ(21.0k)/ROB(19.0k) 的编码与字段
1. commit_unit 18.3k 审计：内部是否有冗余暂存（store 提交缓冲与 LSU 已有字段重复）？
   能去掉哪个 32-bit 宽寄存器组就去掉。
2. one-hot→binary：任何 one-hot 状态/选择信号改二进制编码。
3. ROB/IQ 的 pred_next_pc/pc 等宽字段：确认消费者；若 IQ 中某字段与 ROB 完全重复
   且只在提交时用，改由 ROB 侧提供。
4. LSU(4.7k)/EX(5.3k) 已很瘦，不动。
5. 全部做完仍不达标，就停在能达标的最小改动集——宁可保守，TB PASS 是硬约束。
注意：预算 area<190000 且 power<0.020。
