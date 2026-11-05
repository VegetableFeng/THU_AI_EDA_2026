module rename_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic [4:0]  dbg_reg_addr,
    input  logic        fe_valid,
    output logic        fe_ready,
    input  logic [31:0] fe_pc,
    input  logic [31:0] fe_instr,
    input  logic        fe_pred_valid,
    input  logic [31:0] fe_pred_next_pc,
    input  logic [4:0]  fe_rs1,
    input  logic [4:0]  fe_rs2,
    input  logic [4:0]  fe_rd,
    input  logic [31:0] fe_imm,
    input  logic [3:0]  fe_alu_op,
    input  logic [1:0]  fe_wb_sel,
    input  logic        fe_reg_write,
    input  logic        fe_mem_read,
    input  logic        fe_mem_write,
    input  logic        fe_branch,
    input  logic [1:0]  fe_jump,
    input  logic        fe_ecall,
    input  logic [2:0]  fe_funct3,
    input  logic        fe_use_rs1,
    input  logic        fe_use_rs2,
    input  logic        fe_src_a_pc,
    input  logic        fe_src_b_imm,
    output logic        rob_alloc_valid,
    input  logic        rob_alloc_ready,
    input  logic [2:0]  rob_alloc_idx,
    output logic [31:0] rob_alloc_pc,
    output logic [31:0] rob_alloc_instr,
    output logic [4:0]  rob_alloc_arch_rd,
    output logic [5:0]  rob_alloc_new_prd,
    output logic [5:0]  rob_alloc_old_prd,
    output logic        rob_alloc_has_dest,
    // 分派接口：重命名结果供顶层推入 IQ/LSQ
    output logic        disp_iq_valid,
    output logic        disp_lsq_valid,
    input  logic        disp_stall,
    output logic [5:0]  disp_ps1,
    output logic [5:0]  disp_ps2,
    output logic [5:0]  disp_dest_prd,
    output logic        disp_has_dest,
    output logic [31:0] disp_imm,
    output logic [3:0]  disp_alu_op,
    output logic [1:0]  disp_wb_sel,
    output logic [2:0]  disp_funct3,
    output logic        disp_is_load,
    output logic        disp_is_store,
    output logic        disp_is_branch,
    output logic [1:0]  disp_is_jump,
    output logic        disp_is_ecall,
    output logic [31:0] disp_pc,
    output logic [31:0] disp_instr,
    output logic        disp_pred_valid,
    output logic [31:0] disp_pred_next_pc,
    output logic        disp_src_a_pc,
    output logic        disp_src_b_imm,
    output logic        disp_use_rs1,
    output logic        disp_use_rs2,
    output logic [39:0] free_mask,
    output logic        out_stop_fetch,
    output logic [5:0]  x10_prd,
    output logic [5:0]  dbg_read_prd,
    // 提交/恢复接口（由 ROB 驱动）
    input  logic        commit_en,
    input  logic [5:0]  commit_new_prd,
    input  logic [5:0]  commit_old_prd,
    input  logic [4:0]  commit_arch_rd,
    input  logic        commit_has_dest,
    input  logic        restore_en,
    input  logic [2:0]  restore_rob_idx,
    input  logic        dispatch_stall
);

    localparam int NREG = 40;
    localparam int NROB = 8;

    logic [5:0] spec_rat [0:31];
    logic [5:0] comm_rat [0:31];
    logic [5:0] free_list [0:NREG-1];
    logic [5:0] free_head;
    logic [5:0] free_tail;
    logic [5:0] free_count;

    logic [5:0] ckpt_rat [0:NROB-1][0:31];
    logic [5:0] ckpt_free_head [0:NROB-1];
    logic [5:0] ckpt_free_tail [0:NROB-1];
    logic [5:0] ckpt_free_count [0:NROB-1];
    logic       ckpt_valid [0:NROB-1];

    logic       stop_fetch;
    logic [2:0] ecall_rob_idx;
    logic       ecall_pending;

    logic [5:0] ps1;
    logic [5:0] ps2;
    logic [5:0] new_prd;
    logic [5:0] old_prd;
    logic       has_dest;
    logic       is_ctrl;
    logic       free_avail;
    logic       can_alloc;

    integer i;
    integer j;

    always_comb begin
        ps1 = spec_rat[fe_rs1];
        ps2 = spec_rat[fe_rs2];
        has_dest = fe_reg_write && (fe_rd != 5'd0);
        old_prd = spec_rat[fe_rd];
        new_prd = free_list[free_head];
        is_ctrl = fe_branch || (fe_jump != 2'b00);
        free_avail = (free_count != 6'd0);
        // mispredict 恢复当拍必须抑制分配：恢复块会整表回写 spec_rat，
        // 同拍 alloc 的映射更新会被覆盖丢失（squash 区间内的指令会被重取）
        can_alloc = fe_valid && !halted && !stop_fetch && free_avail && rob_alloc_ready && !dispatch_stall && !restore_en;
        fe_ready = !halted && !stop_fetch && free_avail && rob_alloc_ready && !dispatch_stall && !restore_en;
    end

    assign rob_alloc_valid   = can_alloc;
    assign rob_alloc_pc      = fe_pc;
    assign rob_alloc_instr   = fe_instr;
    assign rob_alloc_arch_rd = fe_rd;
    assign rob_alloc_new_prd = has_dest ? new_prd : 6'd0;
    assign rob_alloc_old_prd = has_dest ? old_prd : 6'd0;
    assign rob_alloc_has_dest = has_dest;

    // 分派接口：重命名结果由顶层推入 IQ（ALU）或 LSQ（load/store）。
    // 只有 rob_alloc 真正被 ROB 接受（can_alloc）才有效。
    assign disp_iq_valid   = can_alloc && !fe_mem_read && !fe_mem_write;
    assign disp_lsq_valid  = can_alloc && (fe_mem_read || fe_mem_write);
    assign disp_stall      = 1'b0;
    assign disp_ps1        = ps1;
    assign disp_ps2        = ps2;
    assign disp_dest_prd   = has_dest ? new_prd : 6'd0;
    assign disp_has_dest   = has_dest;
    assign disp_imm        = fe_imm;
    assign disp_alu_op     = fe_alu_op;
    assign disp_wb_sel     = fe_wb_sel;
    assign disp_funct3     = fe_funct3;
    assign disp_is_load    = fe_mem_read;
    assign disp_is_store   = fe_mem_write;
    assign disp_is_branch  = fe_branch;
    assign disp_is_jump    = fe_jump;
    assign disp_is_ecall   = fe_ecall;
    assign disp_pc         = fe_pc;
    assign disp_instr      = fe_instr;
    assign disp_pred_valid = fe_pred_valid;
    assign disp_pred_next_pc = fe_pred_next_pc;
    assign disp_src_a_pc   = fe_src_a_pc;
    assign disp_src_b_imm  = fe_src_b_imm;
    assign disp_use_rs1    = fe_use_rs1;
    assign disp_use_rs2    = fe_use_rs2;

    // free-list 成员掩码（电平输出）：free list 中的 PR 保持 ready=0
    always_comb begin
        integer k;
        free_mask = {40{1'b0}};
        // 成员 = 从 free_head 起的 free_count 个（与 alloc 出队端一致）
        for (k = 0; k < 8 && k < NREG; k = k + 1) begin
            if (k < free_count) begin
                free_mask[free_list[(free_head + k) % NREG]] = 1'b1;
            end
        end
    end

    assign out_stop_fetch = stop_fetch;
    // x10 的 committed 物理寄存器号：ECALL 提交沿由 ROB 经 PRF 读出作 exit_code
    assign x10_prd        = comm_rat[5'd10];
    assign dbg_read_prd   = comm_rat[dbg_reg_addr];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) begin
                spec_rat[i] <= i[5:0];
                comm_rat[i] <= i[5:0];
            end
            for (i = 0; i < NREG; i = i + 1) begin
                free_list[i] <= i[5:0];
            end
            free_head <= 6'd32;
            free_tail <= 6'd32;
            free_count <= 6'd8;
            for (i = 0; i < NROB; i = i + 1) begin
                ckpt_valid[i] <= 1'b0;
                ckpt_free_head[i] <= 6'd0;
                ckpt_free_tail[i] <= 6'd0;
                ckpt_free_count[i] <= 6'd0;
                for (j = 0; j < 32; j = j + 1) begin
                    ckpt_rat[i][j] <= j[5:0];
                end
            end
            stop_fetch <= 1'b0;
            ecall_rob_idx <= 3'd0;
            ecall_pending <= 1'b0;
        end else if (!halted) begin
            if (can_alloc) begin
                if (has_dest) begin
                    spec_rat[fe_rd] <= new_prd;
                    free_head <= (free_head == (NREG-1)) ? 6'd0 : (free_head + 6'd1);
                    free_count <= free_count - 6'd1;
                end
                if (is_ctrl) begin
                    // checkpoint 必须保存"本分支自身分配之后"的状态：
                    // squash 只回收比分支年轻的指令，分支自己的 rd 映射与
                    // free-list 出队都要保留，否则恢复后分支的 dest 所在
                    // PRD 会同时出现在 RAT 与 free list 中（ready 被清，
                    // 依赖者永不发射）。
                    ckpt_valid[rob_alloc_idx] <= 1'b1;
                    ckpt_free_head[rob_alloc_idx] <= has_dest ?
                        ((free_head == (NREG-1)) ? 6'd0 : (free_head + 6'd1)) : free_head;
                    ckpt_free_tail[rob_alloc_idx] <= free_tail;
                    ckpt_free_count[rob_alloc_idx] <= has_dest ? (free_count - 6'd1) : free_count;
                    for (i = 0; i < 32; i = i + 1) begin
                        ckpt_rat[rob_alloc_idx][i] <= spec_rat[i];
                    end
                    if (has_dest) begin
                        ckpt_rat[rob_alloc_idx][fe_rd] <= new_prd;
                    end
                end
                if (fe_ecall) begin
                    stop_fetch <= 1'b1;
                    ecall_rob_idx <= rob_alloc_idx;
                    ecall_pending <= 1'b1;
                end
            end
            // ROB 顺序提交：更新 committed RAT、回收 old_prd 入 free list 尾部
            // 尾部位置 = (free_head + free_count) % NREG，与掩码窗口一致；
            // 同拍既有 alloc 又有 commit 时 count 净变化为 0
            if (commit_en && commit_has_dest && (commit_arch_rd != 5'd0)) begin
                comm_rat[commit_arch_rd] <= commit_new_prd;
                free_list[(free_head + free_count) % NREG] <= commit_old_prd;
                free_tail <= (free_head + free_count) % NREG + 6'd1;
                if (!(can_alloc && has_dest)) begin
                    free_count <= free_count + 6'd1;
                end
            end
            // 误预测恢复：从分支对应的 checkpoint 恢复 speculative RAT 与 free list
            if (restore_en) begin
                for (i = 0; i < 32; i = i + 1) begin
                    spec_rat[i] <= ckpt_rat[restore_rob_idx][i];
                end
                free_head <= ckpt_free_head[restore_rob_idx];
                free_tail <= ckpt_free_tail[restore_rob_idx];
                free_count <= ckpt_free_count[restore_rob_idx];
                for (i = 0; i < NROB; i = i + 1) begin
                    if (i != restore_rob_idx && ckpt_valid[i]) begin
                        ckpt_valid[i] <= 1'b0;
                    end
                end
                stop_fetch <= 1'b0;
                ecall_pending <= 1'b0;
            end
        end
    end

endmodule
