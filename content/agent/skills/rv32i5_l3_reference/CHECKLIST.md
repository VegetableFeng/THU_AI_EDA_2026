# RV32I L3 乱序核 · 16 类高频硬件 Bug 模式清单

> 来源：参考实现（本目录）从全挂到教师 TB 全 PASS 过程中确认的 16 类真实 bug。
> 用途：注入 Coder/Diagnoser/Patch 的模式库与检查清单。**只注入本清单，不要让 agent 拷贝参考 RTL。**
> 每条 = 症状 → 根因模式 → 检查方法。

## A. 顶层集成类（agent 事故率最高）

1. **悬空驱动线**（症状：信号恒 X、can_alloc=X 全机冻结）
   - 模式：声明了 `logic A; logic B;`，模块输出接 A、消费方也接 A，但另一处输入接了无人驱动的 B。
   - 例：rename 输出 `rename_stop_fetch` vs 前端输入 `out_stop_fetch`；`rob_commit_has_dest` vs `commit_has_dest`。
   - 检查：对每个内部 wire 统计出现次数，≤2 次必为死线；连接前逐 port 核对驱动方。

2. **输出 port 漏接**（症状：X 传播、功能静默失效）
   - 例：ROB 实例漏接 `.rob_alloc_ready`/`.rob_alloc_idx` → rename 的 can_alloc=X。
   - 检查：实例化后逐一对照模块 port 列表，输出 port 未接 = 悬空。

3. **隐式 1-bit 网线**（症状：宽信号被截断、X）
   - 例：`dmem_resp_valid` 未声明直接使用。
   - 检查：`\`default_nettype none` 或全量显式声明。

4. **总线mux接错来源**（症状：指令/地址错乱）
   - 例：IQ 的 `iq_alloc_instr` 接到悬空的 `rob_alloc_insn` 而非 `disp_instr`；外部 `imem_addr` 接到从未驱动的 `imem_addr_w` 而非 `ic_mem_req_addr`。

## B. 等待状态与握手协议类（dbg_features[0]=1 时必查）

5. **在途外部请求被撤回**（症状："request changed before ready" 协议违例）
   - 模式：`mem_req_valid = ... && !halted`（或 flush/异常）——一旦 valid 发出，必须保持到握手完成；halt/flush 只能抑制**响应**，不能撤**请求**。
6. **halt 后地址不稳定**（症状："停机期间 imem_addr 不稳定"）
   - 模式：halt 时继续推进 refill 会让外部地址变化；正确做法=完成当前字握手后冻结（frozen 锁存）。
7. **cache 状态机 halt 即跳 IDLE**（症状：丢外部写）
   - 模式：`else if (halted) state <= S_IDLE` 会丢弃在途 refill/write-through；必须条件化（仅无在途操作时才回 IDLE）。

## C. NBA/时序语义类（iverilog 下高发）

8. **同向量多条 NBA 后者胜**（症状：置位永远失效）
   - 例：PRF `ready_r[waddr] <= 1` 被后面的 `ready_r <= ready_r & ~clear` 整体赋值覆盖 → 写回置位每拍被清。
   - 检查：同一 always 块内对同一向量的赋值顺序；置位语句必须放在掩码/整体赋值**之后**。
9. **读旧值判断**（症状：需要两次事件才推进）
   - 例：`if (resp_fire && ent_done[head])` 读旧 done → 单响应永不完成。同拍事件用当拍条件判断。

## D. 队列/链表控制类

10. **优先级+搬移双机制冲突**（症状：随机丢表项）
    - 例：2 槽 LSQ 同时有"优先级 head_sel"和"槽间搬移"逻辑，搬移的 `valid[1]<=0` 覆盖同拍 alloc 的 `valid[1]<=1`。重写为显式 head/tail 指针 + count 的 FIFO。
11. **环形队列指针/窗口不一致**（症状：空闲表项重复分配、ready 被错误清除）
    - 例：free list 从 head 出队、向 tail 入队，但成员掩码从 tail 枚举 → 刚出队的 prd 仍在掩码内被清 ready。成员窗口必须与出队端一致（head..head+count）。
12. **`>` 比较不处理环绕**（症状：分支回绕时年轻指令逃过冲刷、被错误提交）
    - 例：squash 条件 `rob_idx > squash_rob_idx` 在 3-bit 回绕时漏杀。改环形开区间：`((i - sq - 1) & 7) < ((tail - sq - 1) & 7)`，ROB 导出 tail 给 IQ/LSQ 共用。

## E. 乱序核心架构语义类

13. **checkpoint 时点错误**（症状：分支自己的 rd 映射被恢复吞掉 → 依赖者永不发射）
    - 模式：squash 只杀**比分支年轻**的指令，checkpoint 必须保存**分支自身分配之后**的状态（RAT 覆盖 fe_rd、free list 计入自身出队）。
14. **恢复拍与分配拍竞争**（症状：偶发映射回卷、地址基址丢失）
    - 模式：restore 整表回写 spec_rat，同拍 alloc 的更新会被覆盖。mispredict 当拍必须抑制 can_alloc（该指令必被重取）。
15. **流水级寄存器无反压写入**（症状：随机丢指令、retire 数短缺、值错——本参考的最大主犯）
    - 例：IF/ID 收取指响应用 `if (resp_valid && req_pending) if2id <= resp`，无 `!if2id_valid || fe_advance` 检查 → rename 停顿时指令被覆盖。**取指请求仅在 IF/ID 空或当拍排空时发出**（单请求在飞）。
16. **ECALL/exit_code 语义**（症状：exit_code 错、与 halted 不同拍）
    - 模式：exit_code=最终 x10，须在 ECALL **提交沿**读 committed RAT 映射的 PRF 值并锁存到 pending，下一拍与 halted **同时**输出（提前一拍即违 spec）。

## 附：dbg 特性信号语义（spec_l3_ooo §242）

- `dbg_ooo_issue`：指令被 **IQ 或 LSU 接受**那拍，ALU+load/store 每条恰一次，ECALL 不算（= `iq_accept && !is_ecall || lsq_accept`）。
- `dbg_ooo_bypass`：更老 load 的外部 D 等待拍（dmem_valid&&!dmem_ready）期间，年轻 ALU 独立发射/完成，每条最多一次。
- `dbg_retire_*`：每条**提交**指令恰一个单周期脉冲，pc/insn 必须与 imem 程序一致。
