module rv32i5 (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        imem_valid,
    input  logic        imem_ready,
    output logic        dmem_valid,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,
    input  logic [31:0] dmem_rdata,
    input  logic        dmem_ready,
    input  logic [4:0]  dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    output logic        halted,
    output logic [31:0] exit_code,
    output logic [2:0]  dbg_features,
    output logic        dbg_retire_valid,
    output logic [31:0] dbg_retire_pc,
    output logic [31:0] dbg_retire_insn,
    output logic        dbg_bp_resolve,
    output logic        dbg_bp_mispredict,
    output logic        dbg_ooo_issue,
    output logic        dbg_ooo_bypass
);

    assign dbg_features = 3'b111;

    // ---------------------------------------------------------------
    // Branch predictor
    // ---------------------------------------------------------------
    logic [31:0] bp_lookup_pc;
    logic        bp_pred_valid;
    logic [31:0] bp_pred_next_pc;

    // 显式连线声明（防 1-bit 隐式 wire 宽度截断）
    logic [2:0]  rob_commit_idx;
    logic [31:0] dbg_retire_pc_w;
    logic [31:0] dbg_retire_insn_w;
    logic [31:0] dbg_reg_data_w;
    logic        dbg_retire_valid_w;

    branch_predictor u_branch_predictor (
        .clk             (clk),
        .rst_n           (rst_n),
        .bp_lookup_pc    (bp_lookup_pc),
        .bp_pred_valid   (bp_pred_valid),
        .bp_pred_next_pc (bp_pred_next_pc),
        .bp_resolve_valid (bp_resolve_valid),
        .bp_resolve_pc    (bp_resolve_pc),
        .bp_resolve_type  (bp_resolve_type),
        .bp_resolve_taken (bp_resolve_taken),
        .bp_resolve_target(bp_resolve_target)
    );

    // ---------------------------------------------------------------
    // Frontend：取指 + icache 请求 + 预测 + 解码
    // ---------------------------------------------------------------
    logic        fe_cpu_req_valid;
    logic [31:0] fe_cpu_req_addr;
    logic        fe_cpu_req_ready;
    logic        fe_cpu_resp_valid;
    logic [31:0] fe_cpu_resp_data;
    logic        fe_valid;
    logic        fe_ready;
    logic [31:0] fe_pc;
    logic [31:0] fe_instr;
    logic        fe_pred_valid;
    logic [31:0] fe_pred_next_pc;
    logic [4:0]  fe_rs1;
    logic [4:0]  fe_rs2;
    logic [4:0]  fe_rd;
    logic [31:0] fe_imm;
    logic [3:0]  fe_alu_op;
    logic [1:0]  fe_wb_sel;
    logic        fe_reg_write;
    logic        fe_mem_read;
    logic        fe_mem_write;
    logic        fe_branch;
    logic [1:0]  fe_jump;
    logic        fe_ecall;
    logic [2:0]  fe_funct3;
    logic        fe_use_rs1;
    logic        fe_use_rs2;
    logic        fe_src_a_pc;
    logic        fe_src_b_imm;
    logic        rob_commit_valid;
    logic [31:0] rob_commit_pc;
    logic [31:0] rob_commit_insn;
    logic [31:0] rob_commit_data;

    frontend u_frontend (
        .clk             (clk),
        .rst_n           (rst_n),
        .halted          (halted),
        .stop_fetch      (rename_stop_fetch),
        .redirect        (redirect_valid),
        .redirect_pc     (redirect_target),
        .flush_epoch     (flush_epoch),
        .cpu_req_valid   (fe_cpu_req_valid),
        .cpu_req_addr    (fe_cpu_req_addr),
        .cpu_req_ready   (fe_cpu_req_ready),
        .cpu_resp_valid  (fe_cpu_resp_valid),
        .cpu_resp_data   (fe_cpu_resp_data),
        .bp_lookup_pc    (bp_lookup_pc),
        .bp_pred_valid   (bp_pred_valid),
        .bp_pred_next_pc (bp_pred_next_pc),
        .fe_valid        (fe_valid),
        .fe_ready        (fe_ready),
        .fe_pc           (fe_pc),
        .fe_instr        (fe_instr),
        .fe_pred_valid   (fe_pred_valid),
        .fe_pred_next_pc (fe_pred_next_pc),
        .fe_rs1          (fe_rs1),
        .fe_rs2          (fe_rs2),
        .fe_rd           (fe_rd),
        .fe_imm          (fe_imm),
        .fe_alu_op       (fe_alu_op),
        .fe_wb_sel       (fe_wb_sel),
        .fe_reg_write    (fe_reg_write),
        .fe_mem_read     (fe_mem_read),
        .fe_mem_write    (fe_mem_write),
        .fe_branch       (fe_branch),
        .fe_jump         (fe_jump),
        .fe_ecall        (fe_ecall),
        .fe_funct3       (fe_funct3),
        .fe_use_rs1      (fe_use_rs1),
        .fe_use_rs2      (fe_use_rs2),
        .fe_src_a_pc     (fe_src_a_pc),
        .fe_src_b_imm    (fe_src_b_imm)
    );

    // ---------------------------------------------------------------
    // Rename：RAT 重命名 + ROB 分配 + 分派输出
    // ---------------------------------------------------------------
    logic        rob_alloc_valid;
    logic        rob_alloc_ready;
    logic [2:0]  rob_alloc_idx;
    logic [31:0] rob_alloc_pc;
    logic [31:0] rob_alloc_instr;
    logic [4:0]  rob_alloc_arch_rd;
    logic [5:0]  rob_alloc_new_prd;
    logic [5:0]  rob_alloc_old_prd;
    logic        rob_alloc_has_dest;
    logic        disp_iq_valid;
    logic        disp_lsq_valid;
    logic        disp_stall;
    logic [5:0]  disp_ps1;
    logic [5:0]  disp_ps2;
    logic [5:0]  disp_dest_prd;
    logic        disp_has_dest;
    logic [31:0] disp_imm;
    logic [3:0]  disp_alu_op;
    logic [1:0]  disp_wb_sel;
    logic [2:0]  disp_funct3;
    logic        disp_is_load;
    logic        disp_is_store;
    logic        disp_is_branch;
    logic [1:0]  disp_is_jump;
    logic        disp_is_ecall;
    logic [31:0] disp_pc;
    logic [31:0] disp_instr;
    logic        disp_pred_valid;
    logic [31:0] disp_pred_next_pc;
    logic        disp_src_a_pc;
    logic        disp_src_b_imm;
    logic        disp_use_rs1;
    logic        disp_use_rs2;
    logic [39:0] free_mask;
    logic        rename_stop_fetch;
    logic [5:0]  dbg_read_prd;
    logic        commit_en;
    logic [5:0]  commit_new_prd;
    logic [5:0]  commit_old_prd;
    logic [4:0]  commit_arch_rd;
    logic        commit_has_dest;
    logic        restore_en;
    logic [2:0]  restore_rob_idx;

    rename_unit u_rename_unit (
        .clk             (clk),
        .rst_n           (rst_n),
        .halted          (halted),
        .dbg_reg_addr    (dbg_reg_addr),
        .fe_valid        (fe_valid),
        .fe_ready        (fe_ready),
        .fe_pc           (fe_pc),
        .fe_instr        (fe_instr),
        .fe_pred_valid   (fe_pred_valid),
        .fe_pred_next_pc (fe_pred_next_pc),
        .fe_rs1          (fe_rs1),
        .fe_rs2          (fe_rs2),
        .fe_rd           (fe_rd),
        .fe_imm          (fe_imm),
        .fe_alu_op       (fe_alu_op),
        .fe_wb_sel       (fe_wb_sel),
        .fe_reg_write    (fe_reg_write),
        .fe_mem_read     (fe_mem_read),
        .fe_mem_write    (fe_mem_write),
        .fe_branch       (fe_branch),
        .fe_jump         (fe_jump),
        .fe_ecall        (fe_ecall),
        .fe_funct3       (fe_funct3),
        .fe_use_rs1      (fe_use_rs1),
        .fe_use_rs2      (fe_use_rs2),
        .fe_src_a_pc     (fe_src_a_pc),
        .fe_src_b_imm    (fe_src_b_imm),
        .rob_alloc_valid (rob_alloc_valid),
        .rob_alloc_ready (rob_alloc_ready),
        .rob_alloc_idx   (rob_alloc_idx),
        .rob_alloc_pc    (rob_alloc_pc),
        .rob_alloc_instr (rob_alloc_instr),
        .rob_alloc_arch_rd (rob_alloc_arch_rd),
        .rob_alloc_new_prd (rob_alloc_new_prd),
        .rob_alloc_old_prd (rob_alloc_old_prd),
        .rob_alloc_has_dest (rob_alloc_has_dest),
        .disp_iq_valid   (disp_iq_valid),
        .disp_lsq_valid  (disp_lsq_valid),
        .disp_stall      (disp_stall),
        .disp_ps1        (disp_ps1),
        .disp_ps2        (disp_ps2),
        .disp_dest_prd   (disp_dest_prd),
        .disp_has_dest   (disp_has_dest),
        .disp_imm        (disp_imm),
        .disp_alu_op     (disp_alu_op),
        .disp_wb_sel     (disp_wb_sel),
        .disp_funct3     (disp_funct3),
        .disp_is_load    (disp_is_load),
        .disp_is_store   (disp_is_store),
        .disp_is_branch  (disp_is_branch),
        .disp_is_jump    (disp_is_jump),
        .disp_is_ecall   (disp_is_ecall),
        .disp_pc         (disp_pc),
        .disp_instr      (disp_instr),
        .disp_pred_valid (disp_pred_valid),
        .disp_pred_next_pc (disp_pred_next_pc),
        .disp_src_a_pc   (disp_src_a_pc),
        .disp_src_b_imm  (disp_src_b_imm),
        .disp_use_rs1    (disp_use_rs1),
        .disp_use_rs2    (disp_use_rs2),
        .free_mask       (free_mask),
        .out_stop_fetch  (rename_stop_fetch),
        .x10_prd         (x10_prd),
        .dbg_read_prd    (dbg_read_prd),
        .commit_en       (commit_en),
        .commit_new_prd  (commit_new_prd),
        .commit_old_prd  (commit_old_prd),
        .commit_arch_rd  (commit_arch_rd),
        .commit_has_dest (commit_has_dest),
        .restore_en      (restore_en),
        .restore_rob_idx (restore_rob_idx),
        .dispatch_stall  (dispatch_stall)
    );

    // ---------------------------------------------------------------
    // Reorder Buffer：顺序提交 + halted/exit_code
    // ---------------------------------------------------------------
    logic        rob_head_valid;
    logic [2:0]  rob_head_idx;
    logic        rob_head_is_store;
    logic        rob_head_complete;

    reorder_buffer u_reorder_buffer (
        .clk                (clk),
        .rst_n              (rst_n),
        .rob_alloc_valid    (rob_alloc_valid),
        .rob_alloc_ready    (rob_alloc_ready),
        .rob_alloc_idx      (rob_alloc_idx),
        .rob_alloc_pc       (rob_alloc_pc),
        .rob_alloc_instr    (rob_alloc_instr),
        .rob_alloc_arch_rd  (rob_alloc_arch_rd),
        .rob_alloc_new_prd  (rob_alloc_new_prd),
        .rob_alloc_old_prd  (rob_alloc_old_prd),
        .rob_alloc_has_dest (rob_alloc_has_dest),
        .rob_alloc_is_load  (disp_is_load),
        .rob_alloc_is_store (disp_is_store),
        .rob_alloc_is_branch(disp_is_branch),
        .rob_alloc_is_jump  (disp_is_jump[0]),
        .rob_alloc_is_ecall (disp_is_ecall),
        .complete_valid     (ex_complete_valid),
        .complete_rob_idx   (ex_complete_rob_idx),
        .complete_data      (ex_complete_data),
        .lsu_complete_valid (lsu_complete_valid),
        .lsu_complete_rob_idx (lsu_complete_rob_idx),
        .lsu_complete_data  (lsu_complete_data),
        .squash_valid       (squash_valid),
        .squash_rob_idx     (squash_rob_idx),
        .rob_commit_valid   (rob_commit_valid),
        .rob_commit_idx     (rob_commit_idx),
        .rob_commit_pc      (rob_commit_pc),
        .rob_commit_instr   (rob_commit_insn),
        .rob_commit_arch_rd (commit_arch_rd),
        .rob_commit_new_prd (commit_new_prd),
        .rob_commit_old_prd (commit_old_prd),
        .rob_commit_has_dest (commit_has_dest),
        .rob_commit_is_store (rob_commit_is_store),
        .rob_commit_is_ecall (rob_commit_is_ecall),
        .rob_commit_is_branch (rob_commit_is_branch),
        .rob_commit_is_jump (rob_commit_is_jump),
        .rob_commit_data    (rob_commit_data),
        .x10_value          (x10_rdata),
        .rob_tail_out       (rob_tail_w),
        .rob_head_valid     (rob_head_valid),
        .rob_head_idx       (rob_head_idx),
        .rob_head_is_store  (rob_head_is_store),
        .rob_head_complete  (rob_head_complete),
        .halted             (halted),
        .exit_code          (exit_code)
    );

    assign commit_en       = rob_commit_valid;
    assign restore_en      = resolve_mispredict;
    assign restore_rob_idx = squash_rob_idx;

    // ---------------------------------------------------------------
    // Issue Queue：乱序发射（load 等待时 ALU 照常发射）
    // ---------------------------------------------------------------
    logic [39:0] prf_ready;
    logic [5:0]  iq_raddr0;
    logic [5:0]  iq_raddr1;
    logic [31:0] iq_rdata0;
    logic [31:0] iq_rdata1;
    logic        iq_issue_valid;
    logic [2:0]  iq_issue_rob_idx;
    logic [31:0] iq_issue_pc;
    logic [31:0] iq_issue_insn;
    logic [5:0]  iq_issue_prd;
    logic        iq_issue_has_dest;
    logic [31:0] iq_issue_rs1;
    logic [31:0] iq_issue_rs2;
    logic [31:0] iq_issue_imm;
    logic [3:0]  iq_issue_alu_op;
    logic        iq_issue_src_a_pc;
    logic        iq_issue_src_b_imm;
    logic [1:0]  iq_issue_wb_sel;
    logic        iq_issue_is_branch;
    logic [1:0]  iq_issue_jump;
    logic [2:0]  iq_issue_funct3;
    logic [31:0] iq_issue_pred_next_pc;
    logic        iq_issue_pred_valid;
    logic [2:0]  squash_rob_idx;
    logic [2:0]  rob_tail_w;
    logic        iq_accept;

    issue_queue u_issue_queue (
        .clk                (clk),
        .rst_n              (rst_n),
        .halted             (halted),
        .iq_alloc_valid     (disp_iq_valid),
        .iq_alloc_ready     (iq_alloc_ready),
        .iq_alloc_rob_idx   (rob_alloc_idx),
        .iq_alloc_pc        (rob_alloc_pc),
        .iq_alloc_instr     (rob_alloc_instr),
        .iq_alloc_prd       (disp_dest_prd),
        .iq_alloc_has_dest  (disp_has_dest),
        .iq_alloc_ps1       (disp_ps1),
        .iq_alloc_ps2       (disp_ps2),
        .iq_alloc_alu_op    (disp_alu_op),
        .iq_alloc_imm       (disp_imm),
        .iq_alloc_src_a_pc  (disp_src_a_pc),
        .iq_alloc_src_b_imm (disp_src_b_imm),
        .iq_alloc_wb_sel    (disp_wb_sel),
        .iq_alloc_is_branch (disp_is_branch),
        .iq_alloc_jump      (disp_is_jump),
        .iq_alloc_funct3    (disp_funct3),
        .iq_alloc_pred_next_pc (disp_pred_next_pc),
        .iq_alloc_pred_valid(disp_pred_valid),
        .iq_accept          (iq_accept),
        .prf_ready          (prf_ready),
        .iq_raddr0          (iq_raddr0),
        .iq_raddr1          (iq_raddr1),
        .iq_rdata0          (iq_rdata0),
        .iq_rdata1          (iq_rdata1),
        .iq_issue_valid     (iq_issue_valid),
        .iq_issue_ready     (iq_issue_ready),
        .iq_issue_rob_idx   (iq_issue_rob_idx),
        .iq_issue_pc        (iq_issue_pc),
        .iq_issue_instr     (iq_issue_insn),
        .iq_issue_prd       (iq_issue_prd),
        .iq_issue_has_dest  (iq_issue_has_dest),
        .iq_issue_rs1       (iq_issue_rs1),
        .iq_issue_rs2       (iq_issue_rs2),
        .iq_issue_imm       (iq_issue_imm),
        .iq_issue_alu_op    (iq_issue_alu_op),
        .iq_issue_src_a_pc  (iq_issue_src_a_pc),
        .iq_issue_src_b_imm (iq_issue_src_b_imm),
        .iq_issue_wb_sel    (iq_issue_wb_sel),
        .iq_issue_is_branch (iq_issue_is_branch),
        .iq_issue_jump      (iq_issue_jump),
        .iq_issue_funct3    (iq_issue_funct3),
        .iq_issue_pred_next_pc (iq_issue_pred_next_pc),
        .iq_issue_pred_valid (iq_issue_pred_valid),
        .squash_valid       (squash_valid),
        .squash_rob_idx     (squash_rob_idx),
        .rob_tail_in        (rob_tail_w)
    );

    // 分派反压：目标队列满时停止 rename 分派（LSQ 仅 2 项，必须反压）
    logic dispatch_stall;
    assign dispatch_stall = (fe_mem_read || fe_mem_write) ? !lsq_alloc_ready
                                                          : !iq_alloc_ready;

    // dbg_ooo_issue：指令被 IQ 或 LSU 接受的那拍（spec_l3_ooo §dbg）：
    // 含 ALU 与 load/store，每条有效指令恰一次，ECALL 不算
    assign dbg_ooo_issue = (iq_accept && !disp_is_ecall) || lsq_accept;

    // ---------------------------------------------------------------
    // Physical Register File
    // ---------------------------------------------------------------
    logic [31:0] x10_rdata;
    logic [5:0]  x10_prd;
    logic [31:0] dbg_prf_data;

    physical_regfile u_physical_regfile (
        .clk         (clk),
        .rst_n       (rst_n),
        .iq_raddr0   (iq_raddr0),
        .iq_raddr1   (iq_raddr1),
        .iq_rdata0   (iq_rdata0),
        .iq_rdata1   (iq_rdata1),
        .lsu_raddr0  (lsu_raddr0),
        .lsu_raddr1  (lsu_raddr1),
        .lsu_rdata0  (lsu_rdata0),
        .lsu_rdata1  (lsu_rdata1),
        .x10_raddr   (x10_prd),
        .x10_rdata   (x10_rdata),
        .dbg_raddr   (dbg_read_prd),
        .dbg_rdata   (dbg_prf_data),
        .prf_ready   (prf_ready),
        .we0         (ex_we0),
        .waddr0      (ex_waddr0),
        .wdata0      (ex_wdata0),
        .we1         (commit_we1),
        .waddr1      (commit_waddr1),
        .wdata1      (commit_wdata1),
        .clear_ready (free_mask)
    );

    // dbg 读出和 retire 中间连线
    assign dbg_reg_data_w     = dbg_prf_data;
    assign dbg_retire_valid_w = rob_commit_valid;
    assign dbg_retire_pc_w    = rob_commit_pc;
    assign dbg_retire_insn_w  = rob_commit_insn;
    assign dbg_retire_valid   = dbg_retire_valid_w;
    assign dbg_retire_pc      = dbg_retire_pc_w;
    assign dbg_retire_insn    = dbg_retire_insn_w;

    // 提交时把 load 结果写入 PRF（ALU 结果在 execute 完成时已写）
    // 注意接 ROB 实际驱动的 commit_* 线（rob_commit_has_dest/new_prd 是无人驱动的死线）
    logic        commit_we1;
    logic [5:0]  commit_waddr1;
    logic [31:0] commit_wdata1;
    assign commit_we1    = rob_commit_valid && commit_has_dest;
    assign commit_waddr1 = commit_new_prd;
    assign commit_wdata1 = rob_commit_data;

    // ---------------------------------------------------------------
    // Execute Unit：ALU/分支/访存地址，完成写回，误预测恢复
    // ---------------------------------------------------------------
    logic        ex_complete_valid;
    logic [2:0]  ex_complete_rob_idx;
    logic [31:0] ex_complete_data;
    logic        ex_we0;
    logic [5:0]  ex_waddr0;
    logic [31:0] ex_wdata0;
    logic        bp_resolve_valid;
    logic [31:0] bp_resolve_pc;
    logic [1:0]  bp_resolve_type;
    logic        bp_resolve_taken;
    logic [31:0] bp_resolve_target;
    logic        resolve_mispredict;
    logic        redirect_valid;
    logic [31:0] redirect_target;

    execute_unit u_execute_unit (
        .clk                (clk),
        .rst_n              (rst_n),
        .halted             (halted),
        .older_load_pending (older_load_pending),
        .dmem_wait          (dmem_wait),
        .iq_issue_valid     (iq_issue_valid),
        .iq_issue_ready     (iq_issue_ready),
        .iq_issue_rob_idx   (iq_issue_rob_idx),
        .iq_issue_pc        (iq_issue_pc),
        .iq_issue_instr     (iq_issue_insn),
        .iq_issue_prd       (iq_issue_prd),
        .iq_issue_has_dest  (iq_issue_has_dest),
        .iq_issue_rs1       (iq_issue_rs1),
        .iq_issue_rs2       (iq_issue_rs2),
        .iq_issue_imm       (iq_issue_imm),
        .iq_issue_alu_op    (iq_issue_alu_op),
        .iq_issue_src_a_pc  (iq_issue_src_a_pc),
        .iq_issue_src_b_imm (iq_issue_src_b_imm),
        .iq_issue_wb_sel    (iq_issue_wb_sel),
        .iq_issue_is_branch (iq_issue_is_branch),
        .iq_issue_jump      (iq_issue_jump),
        .iq_issue_funct3    (iq_issue_funct3),
        .iq_issue_pred_next_pc (iq_issue_pred_next_pc),
        .iq_issue_pred_valid (iq_issue_pred_valid),
        .complete_valid     (ex_complete_valid),
        .complete_rob_idx   (ex_complete_rob_idx),
        .complete_data      (ex_complete_data),
        .we0                (ex_we0),
        .waddr0             (ex_waddr0),
        .wdata0             (ex_wdata0),
        .bp_resolve_valid   (bp_resolve_valid),
        .bp_resolve_pc      (bp_resolve_pc),
        .bp_resolve_type    (bp_resolve_type),
        .bp_resolve_taken   (bp_resolve_taken),
        .bp_resolve_target  (bp_resolve_target),
        .resolve_mispredict (resolve_mispredict),
        .redirect           (redirect_valid),
        .redirect_pc        (redirect_target),
        .squash_valid       (squash_valid),
        .squash_rob_idx     (squash_rob_idx),
        .ooo_bypass         (dbg_ooo_bypass)
    );

    assign iq_issue_ready = !halted;
    // LSU 发射握手无外部消费者（dcache 握手在 LSU 内部完成反压），恒可发射
    assign lsu_issue_ready = 1'b1;

    assign dbg_bp_resolve    = bp_resolve_valid & rst_n & ~halted;
    assign dbg_bp_mispredict = resolve_mispredict & rst_n & ~halted;

    // ---------------------------------------------------------------
    // Load/Store Unit：LSQ 顺序访存，连 D-Cache
    // ---------------------------------------------------------------
    logic        lsq_alloc_valid;
    logic        lsq_alloc_ready;
    logic [2:0]  lsq_alloc_rob_idx;
    logic [5:0]  lsq_alloc_prd;
    logic        lsq_alloc_has_dest;
    logic [5:0]  lsq_alloc_ps1;
    logic [5:0]  lsq_alloc_ps2;
    logic [31:0] lsq_alloc_imm;
    logic        lsq_alloc_mem_read;
    logic        lsq_alloc_mem_write;
    logic [2:0]  lsq_alloc_funct3;
    logic        lsq_alloc_use_rs2;
    logic        lsq_accept;
    logic [5:0]  lsu_raddr0;
    logic [5:0]  lsu_raddr1;
    logic [31:0] lsu_rdata0;
    logic [31:0] lsu_rdata1;
    logic        lsu_issue_valid;
    logic        lsu_issue_ready;
    logic [2:0]  lsu_issue_rob_idx;
    logic        dc_cpu_req_valid;
    logic        dc_cpu_req_we;
    logic [31:0] dc_cpu_req_addr;
    logic [31:0] dc_cpu_req_wdata;
    logic [3:0]  dc_cpu_req_be;
    logic        dc_cpu_req_ready;
    logic        dc_cpu_resp_valid;
    logic [31:0] dc_cpu_resp_rdata;
    logic [31:0] lsu_complete_data;
    logic        lsu_complete_valid;
    logic [2:0]  lsu_complete_rob_idx;
    logic        older_load_pending;

    load_store_unit u_load_store_unit (
        .clk                 (clk),
        .rst_n               (rst_n),
        .halted              (halted),
        .lsq_alloc_valid     (disp_lsq_valid),
        .lsq_alloc_ready     (lsq_alloc_ready),
        .lsq_alloc_rob_idx   (rob_alloc_idx),
        .lsq_alloc_prd       (disp_dest_prd),
        .lsq_alloc_has_dest  (disp_has_dest),
        .lsq_alloc_ps1       (disp_ps1),
        .lsq_alloc_ps2       (disp_ps2),
        .lsq_alloc_imm       (disp_imm),
        .lsq_alloc_mem_read  (disp_is_load),
        .lsq_alloc_mem_write (disp_is_store),
        .lsq_alloc_funct3    (disp_funct3),
        .lsq_alloc_use_rs2   (disp_use_rs2),
        .lsq_accept          (lsq_accept),
        .prf_ready           (prf_ready),
        .lsu_raddr0          (lsu_raddr0),
        .lsu_raddr1          (lsu_raddr1),
        .lsu_rdata0          (lsu_rdata0),
        .lsu_rdata1          (lsu_rdata1),
        .lsu_issue_valid     (lsu_issue_valid),
        .lsu_issue_ready     (lsu_issue_ready),
        .lsu_issue_rob_idx   (lsu_issue_rob_idx),
        .cpu_req_valid       (dc_cpu_req_valid),
        .cpu_req_we          (dc_cpu_req_we),
        .cpu_req_addr        (dc_cpu_req_addr),
        .cpu_req_wdata       (dc_cpu_req_wdata),
        .cpu_req_be          (dc_cpu_req_be),
        .cpu_req_ready       (dc_cpu_req_ready),
        .cpu_resp_valid      (dc_cpu_resp_valid),
        .cpu_resp_rdata      (dc_cpu_resp_rdata),
        .rob_head_valid      (rob_head_valid),
        .rob_head_is_store   (rob_head_is_store),
        .rob_head_idx        (rob_head_idx),
        .squash_valid        (squash_valid),
        .squash_rob_idx      (squash_rob_idx),
        .rob_tail_in         (rob_tail_w),
        .lsu_complete_valid  (lsu_complete_valid),
        .lsu_complete_rob_idx (lsu_complete_rob_idx),
        .lsu_complete_data   (lsu_complete_data),
        .older_load_pending  (older_load_pending)
    );

    // ---------------------------------------------------------------
    // D-Cache
    // ---------------------------------------------------------------
    logic        dmem_wait;
    logic        ic_flush;
    logic [1:0]  flush_epoch;

    dcache u_dcache (
        .clk            (clk),
        .rst_n          (rst_n),
        .halted         (halted),
        .flush          (ic_flush),
        .flush_epoch    (flush_epoch),
        .cpu_req_valid  (dc_cpu_req_valid),
        .cpu_req_we     (dc_cpu_req_we),
        .cpu_req_addr   (dc_cpu_req_addr),
        .cpu_req_wdata  (dc_cpu_req_wdata),
        .cpu_req_be     (dc_cpu_req_be),
        .cpu_req_ready  (dc_cpu_req_ready),
        .cpu_resp_valid (dc_cpu_resp_valid),
        .cpu_resp_rdata (dc_cpu_resp_rdata),
        .mem_req_valid  (dmem_valid),
        .mem_req_we     (dmem_we),
        .mem_req_addr   (dmem_addr),
        .mem_req_wdata  (dmem_wdata),
        .mem_req_be     (dmem_be),
        .mem_req_ready  (dmem_ready),
        .mem_resp_valid (dmem_resp_valid),
        .mem_resp_data  (dmem_rdata)
    );

    assign dmem_wait = dmem_valid && !dmem_ready;
    // dcache 的外部访存响应：组合存储模型下 req 被 ready 接受当拍即返回数据
    logic dmem_resp_valid;
    assign dmem_resp_valid = dmem_valid & dmem_ready;

    // ---------------------------------------------------------------
    // I-Cache
    // ---------------------------------------------------------------
    logic        ic_mem_req_valid;
    logic [31:0] ic_mem_req_addr;
    logic        ic_mem_req_ready;
    logic        ic_mem_resp_valid;
    logic [31:0] ic_mem_resp_data;

    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .halted         (halted),
        .flush          (ic_flush),
        .flush_epoch    (flush_epoch),
        .cpu_req_valid  (fe_cpu_req_valid),
        .cpu_req_addr   (fe_cpu_req_addr),
        .cpu_req_ready  (fe_cpu_req_ready),
        .cpu_resp_valid (fe_cpu_resp_valid),
        .cpu_resp_data  (fe_cpu_resp_data),
        .mem_req_valid  (ic_mem_req_valid),
        .mem_req_addr   (ic_mem_req_addr),
        .mem_req_ready  (ic_mem_req_ready),
        .mem_resp_valid (ic_mem_resp_valid),
        .mem_resp_data  (ic_mem_resp_data)
    );

    assign imem_valid = ic_mem_req_valid;
    assign imem_addr  = ic_mem_req_addr;
    assign ic_mem_req_ready = imem_ready;
    assign ic_mem_resp_valid = imem_valid & imem_ready;
    assign ic_mem_resp_data  = imem_rdata;

    // 误预测时 icache/dcache 的在途 refill 作废：epoch 递增
    always_ff @(posedge clk) begin
        if (!rst_n)
            flush_epoch <= 2'd0;
        else if (resolve_mispredict)
            flush_epoch <= flush_epoch + 2'd1;
    end
    assign ic_flush = resolve_mispredict;

    // ---------------------------------------------------------------
    // 调试读出：committed 值（经 rename 的 comm_rat 选择 PRF 读地址）
    // ---------------------------------------------------------------
    assign dbg_reg_data = dbg_reg_data_w;

endmodule
