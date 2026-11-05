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

    // ---------------------------------------------------------------
    // IF stage <-> I-Cache
    // ---------------------------------------------------------------
    logic        if_cpu_req_valid;
    logic [31:0] if_cpu_req_addr;
    logic        if_cpu_req_ready;
    logic        if_cpu_resp_valid;
    logic [31:0] if_cpu_resp_data;

    // IF/ID pipeline register
    logic        if2id_valid;
    logic [31:0] if2id_pc;
    logic [31:0] if2id_pc4;
    logic [31:0] if2id_insn;
    logic        if2id_pred_valid;
    logic [31:0] if2id_pred_next_pc;

    // ---------------------------------------------------------------
    // ID stage
    // ---------------------------------------------------------------
    logic        id_uses_rs1;
    logic        id_uses_rs2;
    logic [4:0]  id_rs1;
    logic [4:0]  id_rs2;
    logic        ecall_in_id;
    logic [31:0] reg_x10;

    logic        id2ex_valid;
    logic [31:0] id2ex_pc;
    logic [31:0] id2ex_pc4;
    logic [31:0] id2ex_insn;
    logic [31:0] id2ex_rs1_val;
    logic [31:0] id2ex_rs2_val;
    logic [31:0] id2ex_imm;
    logic [4:0]  id2ex_rs1;
    logic [4:0]  id2ex_rs2;
    logic [4:0]  id2ex_rd;
    logic [3:0]  id2ex_alu_op;
    logic        id2ex_op_a_pc;
    logic        id2ex_op_b_imm;
    logic        id2ex_reg_write;
    logic        id2ex_mem_read;
    logic        id2ex_mem_write;
    logic        id2ex_branch;
    logic        id2ex_jump;
    logic [1:0]  id2ex_wb_sel;
    logic [2:0]  id2ex_funct3;
    logic        id2ex_is_ecall;
    logic        idex_pred_valid;
    logic [31:0] idex_pred_next_pc;

    // ---------------------------------------------------------------
    // EX stage
    // ---------------------------------------------------------------
    logic        redirect_valid;
    logic [31:0] redirect_target;
    logic        ex_load_valid;
    logic [4:0]  ex_load_rd;

    logic        ex2mem_valid;
    logic [31:0] ex2mem_pc;
    logic [31:0] ex2mem_pc4;
    logic [31:0] ex2mem_insn;
    logic [31:0] ex2mem_alu_result;
    logic [31:0] ex2mem_store_data;
    logic [4:0]  ex2mem_rd;
    logic        ex2mem_reg_write;
    logic        ex2mem_mem_read;
    logic        ex2mem_mem_write;
    logic [1:0]  ex2mem_wb_sel;
    logic [2:0]  ex2mem_funct3;
    logic        ex2mem_is_ecall;

    logic [1:0]  fwd_a;
    logic [1:0]  fwd_b;
    logic [31:0] ex2mem_forward_data;

    // ---------------------------------------------------------------
    // MEM stage <-> D-Cache
    // ---------------------------------------------------------------
    logic        mem_cpu_req_valid;
    logic        mem_cpu_req_we;
    logic [31:0] mem_cpu_req_addr;
    logic [31:0] mem_cpu_req_wdata;
    logic [3:0]  mem_cpu_req_be;
    logic        mem_cpu_req_ready;
    logic        mem_cpu_resp_valid;
    logic [31:0] mem_cpu_resp_rdata;

    logic        mem_stall;

    logic        mem2wb_valid;
    logic [31:0] mem2wb_pc;
    logic [31:0] mem2wb_insn;
    logic [31:0] mem2wb_wdata;
    logic [4:0]  mem2wb_rd;
    logic        mem2wb_reg_write;
    logic        mem2wb_is_ecall;

    // ---------------------------------------------------------------
    // WB stage
    // ---------------------------------------------------------------
    logic        wb_reg_write;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;

    // ---------------------------------------------------------------
    // Hazard / flush
    // ---------------------------------------------------------------
    logic        load_use_stall;
    logic        flush_id_ex;
    logic        flush;
    logic [1:0]  flush_epoch;

    // ---------------------------------------------------------------
    // I-Cache external bus
    // ---------------------------------------------------------------
    logic        ic_mem_req_valid;
    logic [31:0] ic_mem_req_addr;
    logic        ic_mem_req_ready;
    logic        ic_mem_resp_valid;
    logic [31:0] ic_mem_resp_data;

    // ---------------------------------------------------------------
    // D-Cache external bus
    // ---------------------------------------------------------------
    logic        dc_mem_req_valid;
    logic        dc_mem_req_we;
    logic [31:0] dc_mem_req_addr;
    logic [31:0] dc_mem_req_wdata;
    logic [3:0]  dc_mem_req_be;
    logic        dc_mem_req_ready;
    logic        dc_mem_resp_valid;
    logic [31:0] dc_mem_resp_data;

    // ---------------------------------------------------------------
    // Branch predictor interface
    // ---------------------------------------------------------------
    logic [31:0] bp_lookup_pc;
    logic        bp_pred_valid;
    logic [31:0] bp_pred_next_pc;
    logic        bp_resolve_valid;
    logic [31:0] bp_resolve_pc;
    logic [1:0]  bp_resolve_type;
    logic        bp_resolve_taken;
    logic [31:0] bp_resolve_target;
    logic        bp_mispredict;

    // ---------------------------------------------------------------
    // Feature constant
    // ---------------------------------------------------------------
    localparam bit FEAT_MULDIV = 1'b1;
    localparam bit FEAT_CSR    = 1'b1;
    assign dbg_features = 3'b111;

    // ---------------------------------------------------------------
    // IF stage
    // ---------------------------------------------------------------
    if_stage u_if_stage (
        .clk             (clk),
        .rst_n           (rst_n),
        .redirect_valid  (redirect_valid),
        .redirect_target (redirect_target),
        .load_use_stall  (load_use_stall),
        .mem_stall       (mem_stall),
        .halted          (halted),
        .ecall_in_id     (ecall_in_id),
        .cpu_req_valid   (if_cpu_req_valid),
        .cpu_req_addr    (if_cpu_req_addr),
        .cpu_req_ready   (if_cpu_req_ready),
        .cpu_resp_valid  (if_cpu_resp_valid),
        .cpu_resp_data   (if_cpu_resp_data),
        .if2id_valid     (if2id_valid),
        .if2id_pc        (if2id_pc),
        .if2id_pc4       (if2id_pc4),
        .if2id_insn      (if2id_insn),
        .bp_lookup_pc    (bp_lookup_pc),
        .bp_pred_valid   (bp_pred_valid),
        .bp_pred_next_pc (bp_pred_next_pc),
        .ifid_pred_valid    (if2id_pred_valid),
        .ifid_pred_next_pc  (if2id_pred_next_pc)
    );

    // ---------------------------------------------------------------
    // ID stage
    // ---------------------------------------------------------------
    id_stage u_id_stage (
        .clk           (clk),
        .rst_n         (rst_n),
        .if2id_valid   (if2id_valid),
        .if2id_pc      (if2id_pc),
        .if2id_pc4     (if2id_pc4),
        .if2id_insn    (if2id_insn),
        .wb_reg_write  (wb_reg_write),
        .wb_rd         (wb_rd),
        .wb_data       (wb_data),
        .flush_id_ex   (flush_id_ex),
        .mem_stall     (mem_stall),
        .ifid_pred_valid    (if2id_pred_valid),
        .ifid_pred_next_pc  (if2id_pred_next_pc),
        .idex_pred_valid    (idex_pred_valid),
        .idex_pred_next_pc  (idex_pred_next_pc),
        .id_uses_rs1   (id_uses_rs1),
        .id_uses_rs2   (id_uses_rs2),
        .id_rs1        (id_rs1),
        .id_rs2        (id_rs2),
        .ecall_in_id   (ecall_in_id),
        .dbg_reg_addr  (dbg_reg_addr),
        .dbg_reg_data  (dbg_reg_data),
        .reg_x10       (reg_x10),
        .id2ex_valid   (id2ex_valid),
        .id2ex_pc      (id2ex_pc),
        .id2ex_pc4     (id2ex_pc4),
        .id2ex_insn    (id2ex_insn),
        .id2ex_rs1_val (id2ex_rs1_val),
        .id2ex_rs2_val (id2ex_rs2_val),
        .id2ex_imm     (id2ex_imm),
        .id2ex_rs1     (id2ex_rs1),
        .id2ex_rs2     (id2ex_rs2),
        .id2ex_rd      (id2ex_rd),
        .id2ex_alu_op  (id2ex_alu_op),
        .id2ex_op_a_pc (id2ex_op_a_pc),
        .id2ex_op_b_imm(id2ex_op_b_imm),
        .id2ex_reg_write(id2ex_reg_write),
        .id2ex_mem_read(id2ex_mem_read),
        .id2ex_mem_write(id2ex_mem_write),
        .id2ex_branch  (id2ex_branch),
        .id2ex_jump    (id2ex_jump),
        .id2ex_wb_sel  (id2ex_wb_sel),
        .id2ex_funct3  (id2ex_funct3),
        .id2ex_is_ecall(id2ex_is_ecall)
    );

    // EX/MEM 前递数据必须按写回选择选择 PC 值，JAL/JALR 不能前递 ALU 结果。
    assign ex2mem_forward_data = (ex2mem_wb_sel == 2'b10) ? ex2mem_pc4 :
                                 (ex2mem_wb_sel == 2'b11) ? ex2mem_pc  :
                                                            ex2mem_alu_result;

    // ---------------------------------------------------------------
    // EX stage
    // ---------------------------------------------------------------
    ex_stage u_ex_stage (
        .clk             (clk),
        .rst_n           (rst_n),
        .mem_stall       (mem_stall),
        .id2ex_valid     (id2ex_valid),
        .id2ex_pc        (id2ex_pc),
        .id2ex_pc4       (id2ex_pc4),
        .id2ex_insn      (id2ex_insn),
        .id2ex_rs1_val   (id2ex_rs1_val),
        .id2ex_rs2_val   (id2ex_rs2_val),
        .id2ex_imm       (id2ex_imm),
        .id2ex_rs1       (id2ex_rs1),
        .id2ex_rs2       (id2ex_rs2),
        .id2ex_rd        (id2ex_rd),
        .id2ex_alu_op    (id2ex_alu_op),
        .id2ex_op_a_pc   (id2ex_op_a_pc),
        .id2ex_op_b_imm  (id2ex_op_b_imm),
        .id2ex_reg_write (id2ex_reg_write),
        .id2ex_mem_read  (id2ex_mem_read),
        .id2ex_mem_write (id2ex_mem_write),
        .id2ex_branch    (id2ex_branch),
        .id2ex_jump      (id2ex_jump),
        .id2ex_wb_sel    (id2ex_wb_sel),
        .id2ex_funct3    (id2ex_funct3),
        .id2ex_is_ecall  (id2ex_is_ecall),
        .fwd_a           (fwd_a),
        .fwd_b           (fwd_b),
        .mem2wb_wdata    (mem2wb_wdata),
        .wb_wdata        (wb_data),
        .ex2mem_forward_data(ex2mem_forward_data),
        .redirect_valid  (redirect_valid),
        .redirect_target (redirect_target),
        .ex_load_valid   (ex_load_valid),
        .ex_load_rd      (ex_load_rd),
        .ex2mem_valid    (ex2mem_valid),
        .ex2mem_pc       (ex2mem_pc),
        .ex2mem_pc4      (ex2mem_pc4),
        .ex2mem_insn     (ex2mem_insn),
        .ex2mem_alu_result(ex2mem_alu_result),
        .ex2mem_store_data(ex2mem_store_data),
        .ex2mem_rd       (ex2mem_rd),
        .ex2mem_reg_write(ex2mem_reg_write),
        .ex2mem_mem_read (ex2mem_mem_read),
        .ex2mem_mem_write(ex2mem_mem_write),
        .ex2mem_wb_sel   (ex2mem_wb_sel),
        .ex2mem_funct3   (ex2mem_funct3),
        .ex2mem_is_ecall (ex2mem_is_ecall)
    );

    // ---------------------------------------------------------------
    // Branch resolve state (owned at top level, driven from EX stage)
    // ---------------------------------------------------------------
    // A resolve event fires for every valid control transfer (taken or
    // not-taken branch, JAL, JALR). Mispredict is asserted only when the
    // actual next PC differs from the predicted next PC.
    assign bp_resolve_valid  = id2ex_valid && (id2ex_branch || id2ex_jump);
    assign bp_resolve_pc     = id2ex_pc;
    assign bp_resolve_type   = id2ex_jump ? (id2ex_insn[6:0] == 7'b1100111 ? 2'b11 : 2'b10)
                                          : 2'b01;
    assign bp_resolve_taken  = id2ex_branch ? redirect_valid : 1'b1;
    assign bp_resolve_target = redirect_target;
    assign bp_mispredict     = bp_resolve_valid &&
                               (idex_pred_valid ? (idex_pred_next_pc != redirect_target)
                                                : (redirect_target != (id2ex_pc + 32'd4)));

    // ---------------------------------------------------------------
    // MEM stage
    // ---------------------------------------------------------------
    mem_stage u_mem_stage (
        .clk             (clk),
        .rst_n           (rst_n),
        .halted          (halted),
        .ex2mem_valid    (ex2mem_valid),
        .ex2mem_pc       (ex2mem_pc),
        .ex2mem_pc4      (ex2mem_pc4),
        .ex2mem_insn     (ex2mem_insn),
        .ex2mem_alu_result(ex2mem_alu_result),
        .ex2mem_store_data(ex2mem_store_data),
        .ex2mem_rd       (ex2mem_rd),
        .ex2mem_reg_write(ex2mem_reg_write),
        .ex2mem_mem_read (ex2mem_mem_read),
        .ex2mem_mem_write(ex2mem_mem_write),
        .ex2mem_wb_sel   (ex2mem_wb_sel),
        .ex2mem_funct3   (ex2mem_funct3),
        .ex2mem_is_ecall (ex2mem_is_ecall),
        .cpu_req_valid   (mem_cpu_req_valid),
        .cpu_req_we      (mem_cpu_req_we),
        .cpu_req_addr    (mem_cpu_req_addr),
        .cpu_req_wdata   (mem_cpu_req_wdata),
        .cpu_req_be      (mem_cpu_req_be),
        .cpu_req_ready   (mem_cpu_req_ready),
        .cpu_resp_valid  (mem_cpu_resp_valid),
        .cpu_resp_rdata  (mem_cpu_resp_rdata),
        .mem_stall       (mem_stall),
        .mem2wb_valid    (mem2wb_valid),
        .mem2wb_pc       (mem2wb_pc),
        .mem2wb_insn     (mem2wb_insn),
        .mem2wb_wdata    (mem2wb_wdata),
        .mem2wb_rd       (mem2wb_rd),
        .mem2wb_reg_write(mem2wb_reg_write),
        .mem2wb_is_ecall (mem2wb_is_ecall)
    );

    // ---------------------------------------------------------------
    // WB stage
    // ---------------------------------------------------------------
    wb_stage u_wb_stage (
        .clk             (clk),
        .rst_n           (rst_n),
        .mem2wb_valid    (mem2wb_valid),
        .mem2wb_pc       (mem2wb_pc),
        .mem2wb_insn     (mem2wb_insn),
        .mem2wb_wdata    (mem2wb_wdata),
        .mem2wb_rd       (mem2wb_rd),
        .mem2wb_reg_write(mem2wb_reg_write),
        .mem2wb_is_ecall (mem2wb_is_ecall),
        .reg_x10         (reg_x10),
        .wb_reg_write    (wb_reg_write),
        .wb_rd           (wb_rd),
        .wb_data         (wb_data),
        .halted          (halted),
        .exit_code       (exit_code),
        .dbg_retire_valid(dbg_retire_valid),
        .dbg_retire_pc   (dbg_retire_pc),
        .dbg_retire_insn (dbg_retire_insn)
    );

    // ---------------------------------------------------------------
    // Hazard unit
    // ---------------------------------------------------------------
    hazard_unit u_hazard_unit (
        .clk            (clk),
        .rst_n          (rst_n),
        .id_valid       (if2id_valid),
        .id_rs1         (id_rs1),
        .id_rs2         (id_rs2),
        .id_uses_rs1    (id_uses_rs1),
        .id_uses_rs2    (id_uses_rs2),
        .ex_load_valid  (ex_load_valid),
        .ex_load_rd     (ex_load_rd),
        .redirect_valid (redirect_valid),
        .ecall_in_id    (ecall_in_id),
        .load_use_stall (load_use_stall),
        .flush_id_ex    (flush_id_ex),
        .flush          (flush),
        .flush_epoch    (flush_epoch)
    );

    // ---------------------------------------------------------------
    // Forwarding unit
    // ---------------------------------------------------------------
    forwarding_unit u_forwarding_unit (
        .id2ex_rs1       (id2ex_rs1),
        .id2ex_rs2       (id2ex_rs2),
        .ex2mem_valid    (ex2mem_valid),
        .ex2mem_reg_write(ex2mem_reg_write),
        .ex2mem_mem_read (ex2mem_mem_read),
        .ex2mem_rd       (ex2mem_rd),
        .mem2wb_valid    (mem2wb_valid),
        .mem2wb_reg_write(mem2wb_reg_write),
        .mem2wb_rd       (mem2wb_rd),
        .fwd_a           (fwd_a),
        .fwd_b           (fwd_b)
    );

    // ---------------------------------------------------------------
    // I-Cache
    // ---------------------------------------------------------------
    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .halted         (halted),
        .flush          (flush),
        .flush_epoch    (flush_epoch),
        .cpu_req_valid  (if_cpu_req_valid),
        .cpu_req_addr   (if_cpu_req_addr),
        .cpu_req_ready  (if_cpu_req_ready),
        .cpu_resp_valid (if_cpu_resp_valid),
        .cpu_resp_data  (if_cpu_resp_data),
        .mem_req_valid  (ic_mem_req_valid),
        .mem_req_addr   (ic_mem_req_addr),
        .mem_req_ready  (ic_mem_req_ready),
        .mem_resp_valid (ic_mem_resp_valid),
        .mem_resp_data  (ic_mem_resp_data)
    );

    // ---------------------------------------------------------------
    // D-Cache
    // ---------------------------------------------------------------
    dcache u_dcache (
        .clk            (clk),
        .rst_n          (rst_n),
        .halted         (halted),
        .flush          (flush),
        .flush_epoch    (flush_epoch),
        .cpu_req_valid  (mem_cpu_req_valid),
        .cpu_req_we     (mem_cpu_req_we),
        .cpu_req_addr   (mem_cpu_req_addr),
        .cpu_req_wdata  (mem_cpu_req_wdata),
        .cpu_req_be     (mem_cpu_req_be),
        .cpu_req_ready  (mem_cpu_req_ready),
        .cpu_resp_valid (mem_cpu_resp_valid),
        .cpu_resp_rdata (mem_cpu_resp_rdata),
        .mem_req_valid  (dc_mem_req_valid),
        .mem_req_we     (dc_mem_req_we),
        .mem_req_addr   (dc_mem_req_addr),
        .mem_req_wdata  (dc_mem_req_wdata),
        .mem_req_be     (dc_mem_req_be),
        .mem_req_ready  (dc_mem_req_ready),
        .mem_resp_valid (dc_mem_resp_valid),
        .mem_resp_data  (dc_mem_resp_data)
    );

    // ---------------------------------------------------------------
    // External bus arbitration: I-Cache and D-Cache share the
    // external word memory ports. I-Cache has priority; D-Cache
    // requests are held until the I bus is idle.
    // ---------------------------------------------------------------
    logic ic_bus_active;

    assign ic_bus_active = ic_mem_req_valid;

    assign imem_valid    = ic_mem_req_valid;
    assign imem_addr     = ic_mem_req_addr;
    assign ic_mem_req_ready = imem_ready;
    assign ic_mem_resp_valid = imem_valid & imem_ready;
    assign ic_mem_resp_data  = imem_rdata;

    assign dmem_valid    = dc_mem_req_valid & ~ic_bus_active;
    assign dmem_we       = dc_mem_req_we;
    assign dmem_addr     = dc_mem_req_addr;
    assign dmem_wdata    = dc_mem_req_wdata;
    assign dmem_be       = dc_mem_req_be;
    assign dc_mem_req_ready = dmem_ready & ~ic_bus_active;
    assign dc_mem_resp_valid = dmem_valid & dmem_ready;
    assign dc_mem_resp_data  = dmem_rdata;

    // ---------------------------------------------------------------
    // Branch predictor
    // ---------------------------------------------------------------
    branch_predictor u_branch_predictor (
        .clk              (clk),
        .rst_n            (rst_n),
        .bp_lookup_pc     (bp_lookup_pc),
        .bp_pred_valid    (bp_pred_valid),
        .bp_pred_next_pc  (bp_pred_next_pc),
        .bp_resolve_valid (bp_resolve_valid),
        .bp_resolve_pc    (bp_resolve_pc),
        .bp_resolve_type  (bp_resolve_type),
        .bp_resolve_taken (bp_resolve_taken),
        .bp_resolve_target(bp_resolve_target)
    );

    // ---------------------------------------------------------------
    // Capability outputs (L2)
    // ---------------------------------------------------------------
    assign dbg_bp_resolve    = bp_resolve_valid & rst_n & ~halted;
    assign dbg_bp_mispredict = bp_mispredict    & rst_n & ~halted;
    assign dbg_ooo_issue     = 1'b0;
    assign dbg_ooo_bypass    = 1'b0;

endmodule
