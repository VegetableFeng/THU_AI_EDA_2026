// file: rtl/rv32i5.sv
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
    assign dbg_features = 3'b011;

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


// file: rtl/if_stage.sv
module if_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        redirect_valid,
    input  logic [31:0] redirect_target,
    input  logic        load_use_stall,
    input  logic        mem_stall,
    input  logic        halted,
    input  logic        ecall_in_id,
    output logic        cpu_req_valid,
    output logic [31:0] cpu_req_addr,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_data,
    output logic        if2id_valid,
    output logic [31:0] if2id_pc,
    output logic [31:0] if2id_pc4,
    output logic [31:0] if2id_insn,
    output logic [31:0] bp_lookup_pc,
    input  logic        bp_pred_valid,
    input  logic [31:0] bp_pred_next_pc,
    output logic        ifid_pred_valid,
    output logic [31:0] ifid_pred_next_pc
);

    logic [31:0] pc;
    logic        req_pending;
    logic        halt_pending;

    logic        inflight_pred_valid;
    logic [31:0] inflight_pred_next_pc;
    logic [31:0] next_pc;

    assign bp_lookup_pc = pc;
    assign next_pc      = bp_pred_valid ? bp_pred_next_pc : (pc + 32'd4);

    logic        stall;

    assign stall = load_use_stall | mem_stall;

    // Request is issued whenever we have a pending fetch and are not frozen.
    assign cpu_req_valid = req_pending & ~halted & ~halt_pending & ~stall;
    assign cpu_req_addr  = pc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc           <= 32'h0000_0000;
            req_pending  <= 1'b1;
            halt_pending <= 1'b0;
            if2id_valid  <= 1'b0;
            if2id_pc     <= 32'h0000_0000;
            if2id_pc4    <= 32'h0000_0000;
            if2id_insn   <= 32'h0000_0000;
            inflight_pred_valid   <= 1'b0;
            inflight_pred_next_pc <= 32'h0000_0000;
            ifid_pred_valid       <= 1'b0;
            ifid_pred_next_pc     <= 32'h0000_0000;
        end else if (halted) begin
            req_pending <= 1'b0;
            if2id_valid <= 1'b0;
        end else begin
            if (redirect_valid) begin
                pc           <= redirect_target;
                req_pending  <= 1'b1;
                halt_pending <= 1'b0;
                if2id_valid  <= 1'b0;
            end else if (ecall_in_id && !halt_pending && !mem_stall) begin
                halt_pending <= 1'b1;
                req_pending  <= 1'b0;
                // 不要在这里清掉 IF/ID valid：ECALL 还可能要等
                // load-use/mem_stall 结束后才进入 ID/EX。
            end else if (halt_pending) begin
                req_pending <= 1'b0;
                // 同理，保持 IF/ID valid，直到流水线消费掉 ECALL。
            end else if (cpu_resp_valid) begin
                // I-Cache 的响应可能只保持一个周期；即使在 mem_stall 或
                // load-use stall 期间也必须锁存，否则响应会永久丢失。
                if2id_valid <= 1'b1;
                if2id_pc    <= pc;
                if2id_pc4   <= pc + 32'd4;
                if2id_insn  <= cpu_resp_data;
                ifid_pred_valid     <= inflight_pred_valid;
                ifid_pred_next_pc   <= inflight_pred_next_pc;
                pc          <= next_pc;
                req_pending <= 1'b1;
                inflight_pred_valid   <= bp_pred_valid;
                inflight_pred_next_pc <= next_pc;
            end else if (stall) begin
                // 流水线暂停时 IF/ID 必须保持，不能在 stall 分支丢弃
                // 已经取到的指令，否则 load-use/mem_stall 后的指令会消失。
                if2id_valid <= if2id_valid;
            end else begin
                if (req_pending && cpu_req_ready) begin
                    req_pending <= 1'b0;
                    if2id_valid <= 1'b0;
                    inflight_pred_valid   <= bp_pred_valid;
                    inflight_pred_next_pc <= next_pc;
                end else begin
                    if2id_valid <= 1'b0;
                end
            end
        end
    end

endmodule


// file: rtl/icache.sv
module icache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        flush,
    input  logic [1:0]  flush_epoch,
    input  logic        cpu_req_valid,
    input  logic [31:0] cpu_req_addr,
    output logic        cpu_req_ready,
    output logic        cpu_resp_valid,
    output logic [31:0] cpu_resp_data,
    output logic        mem_req_valid,
    output logic [31:0] mem_req_addr,
    input  logic        mem_req_ready,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data
);

    localparam logic [1:0] S_IDLE   = 2'd0;
    localparam logic [1:0] S_REFILL = 2'd1;

    logic [31:0]  tag_arr   [0:15];
    logic [127:0] data_arr  [0:15];
    logic         valid_arr [0:15];

    logic [1:0]   state;
    logic [1:0]   refill_cnt;
    logic [31:0]  refill_base;
    logic [31:0]  refill_tag;
    logic [3:0]   refill_idx;
    logic [1:0]   refill_epoch;
    logic [127:0] refill_data;
    logic [1:0]   refill_word;

    logic         resp_valid_r;
    logic [31:0]  resp_data_r;

    logic [3:0]   req_idx;
    logic [31:0]  req_tag;
    logic [1:0]   req_word;
    logic         hit;
    logic [31:0]  hit_data;

    assign req_idx  = cpu_req_addr[7:4];
    assign req_tag  = cpu_req_addr[31:8];
    assign req_word = cpu_req_addr[3:2];

    assign hit = valid_arr[req_idx] && (tag_arr[req_idx] == req_tag);

    always_comb begin
        hit_data = 32'b0;
        case (req_word)
            2'd0: hit_data = data_arr[req_idx][31:0];
            2'd1: hit_data = data_arr[req_idx][63:32];
            2'd2: hit_data = data_arr[req_idx][95:64];
            2'd3: hit_data = data_arr[req_idx][127:96];
            default: hit_data = 32'b0;
        endcase
    end

    assign cpu_req_ready = rst_n && !halted && (state == S_IDLE) && !resp_valid_r;

    assign mem_req_valid = rst_n && !halted && (state == S_REFILL);
    assign mem_req_addr  = refill_base + {refill_cnt, 2'b00};

    assign cpu_resp_valid = resp_valid_r;
    assign cpu_resp_data  = resp_data_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            refill_cnt   <= 2'd0;
            refill_base  <= 32'b0;
            refill_tag   <= 32'b0;
            refill_idx   <= 4'b0;
            refill_epoch <= 2'b0;
            refill_data  <= 128'b0;
            refill_word  <= 2'b0;
            resp_valid_r <= 1'b0;
            resp_data_r  <= 32'b0;
            for (int i = 0; i < 16; i = i + 1) begin
                valid_arr[i] <= 1'b0;
                tag_arr[i]   <= 32'b0;
                data_arr[i]  <= 128'b0;
            end
        end else if (halted) begin
            resp_valid_r <= 1'b0;
        end else begin
            resp_valid_r <= 1'b0;

            // flush 不能打断已经发出的外部 refill 请求，否则 imem_addr/
            // imem_valid 会在 imem_ready 前变化。让 refill 完成，仅通过
            // refill_epoch 丢弃过期数据。
            case (state)
                S_IDLE: begin
                    if (cpu_req_valid && cpu_req_ready) begin
                        if (hit) begin
                            resp_valid_r <= 1'b1;
                            resp_data_r  <= hit_data;
                        end else begin
                            state        <= S_REFILL;
                            refill_cnt   <= 2'd0;
                            refill_base  <= {cpu_req_addr[31:4], 4'b0000};
                            refill_tag   <= req_tag;
                            refill_idx   <= req_idx;
                            refill_epoch <= flush_epoch;
                            refill_data  <= 128'b0;
                            refill_word  <= req_word;
                        end
                    end
                end
                S_REFILL: begin
                    if (mem_req_valid && mem_req_ready) begin
                        case (refill_cnt)
                            2'd0: refill_data[31:0]   <= mem_resp_data;
                            2'd1: refill_data[63:32]  <= mem_resp_data;
                            2'd2: refill_data[95:64]  <= mem_resp_data;
                            2'd3: refill_data[127:96] <= mem_resp_data;
                            default: ;
                        endcase
                        if (refill_cnt == 2'd3) begin
                            // 即使期间发生 redirect，也把有效行安装进 I-Cache；
                            // 仅抑制过期 refill 的响应。否则每次分支都会丢掉
                            // 正在填充的行，循环永远无法 reuse。
                            valid_arr[refill_idx] <= 1'b1;
                            tag_arr[refill_idx]   <= refill_tag;
                            data_arr[refill_idx]  <= refill_data |
                                ({96'b0, mem_resp_data} << {refill_cnt, 5'b00000});
                            if (flush_epoch == refill_epoch) begin
                                resp_valid_r <= 1'b1;
                                case (refill_word)
                                    2'd0: resp_data_r <= refill_data[31:0];
                                    2'd1: resp_data_r <= refill_data[63:32];
                                    2'd2: resp_data_r <= refill_data[95:64];
                                    default: resp_data_r <= mem_resp_data;
                                endcase
                            end
                            state <= S_IDLE;
                        end else begin
                            refill_cnt <= refill_cnt + 2'd1;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// file: rtl/id_stage.sv
module id_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        if2id_valid,
    input  logic [31:0] if2id_pc,
    input  logic [31:0] if2id_pc4,
    input  logic [31:0] if2id_insn,
    input  logic        wb_reg_write,
    input  logic [4:0]  wb_rd,
    input  logic [31:0] wb_data,
    input  logic        flush_id_ex,
    input  logic        mem_stall,
    input  logic        ifid_pred_valid,
    input  logic [31:0] ifid_pred_next_pc,
    output logic        idex_pred_valid,
    output logic [31:0] idex_pred_next_pc,
    output logic        id_uses_rs1,
    output logic        id_uses_rs2,
    output logic [4:0]  id_rs1,
    output logic [4:0]  id_rs2,
    output logic        ecall_in_id,
    input  logic [4:0]  dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    output logic [31:0] reg_x10,
    output logic        id2ex_valid,
    output logic [31:0] id2ex_pc,
    output logic [31:0] id2ex_pc4,
    output logic [31:0] id2ex_insn,
    output logic [31:0] id2ex_rs1_val,
    output logic [31:0] id2ex_rs2_val,
    output logic [31:0] id2ex_imm,
    output logic [4:0]  id2ex_rs1,
    output logic [4:0]  id2ex_rs2,
    output logic [4:0]  id2ex_rd,
    output logic [3:0]  id2ex_alu_op,
    output logic        id2ex_op_a_pc,
    output logic        id2ex_op_b_imm,
    output logic        id2ex_reg_write,
    output logic        id2ex_mem_read,
    output logic        id2ex_mem_write,
    output logic        id2ex_branch,
    output logic        id2ex_jump,
    output logic [1:0]  id2ex_wb_sel,
    output logic [2:0]  id2ex_funct3,
    output logic        id2ex_is_ecall
);

    localparam logic [3:0] ALU_ADD  = 4'd0;
    localparam logic [3:0] ALU_SUB  = 4'd1;
    localparam logic [3:0] ALU_SLL  = 4'd2;
    localparam logic [3:0] ALU_SLT  = 4'd3;
    localparam logic [3:0] ALU_SLTU = 4'd4;
    localparam logic [3:0] ALU_XOR  = 4'd5;
    localparam logic [3:0] ALU_SRL  = 4'd6;
    localparam logic [3:0] ALU_SRA  = 4'd7;
    localparam logic [3:0] ALU_OR   = 4'd8;
    localparam logic [3:0] ALU_AND  = 4'd9;

    localparam logic [1:0] WB_ALU  = 2'd0;
    localparam logic [1:0] WB_MEM  = 2'd1;
    localparam logic [1:0] WB_PC4  = 2'd2;

    logic [31:0] regs [1:31];

    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;

    logic [31:0] imm_i;
    logic [31:0] imm_s;
    logic [31:0] imm_b;
    logic [31:0] imm_u;
    logic [31:0] imm_j;
    logic [31:0] imm;

    logic [31:0] rs1_val;
    logic [31:0] rs2_val;

    logic        is_ecall;
    logic        is_rtype;
    logic        is_itype;
    logic        is_shift_imm;
    logic        is_load;
    logic        is_store;
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_lui;
    logic        is_auipc;

    logic [3:0]  alu_op;
    logic        op_a_pc;
    logic        op_b_imm;
    logic        reg_write;
    logic        mem_read;
    logic        mem_write;
    logic        branch;
    logic        jump;
    logic [1:0]  wb_sel;

    logic        uses_rs1;
    logic        uses_rs2;

    assign opcode = if2id_insn[6:0];
    assign funct3 = if2id_insn[14:12];
    assign funct7 = if2id_insn[31:25];
    assign rs1    = if2id_insn[19:15];
    assign rs2    = if2id_insn[24:20];
    assign rd     = if2id_insn[11:7];

    assign imm_i = {{20{if2id_insn[31]}}, if2id_insn[31:20]};
    assign imm_s = {{20{if2id_insn[31]}}, if2id_insn[31:25], if2id_insn[11:7]};
    assign imm_b = {{19{if2id_insn[31]}}, if2id_insn[31], if2id_insn[7],
                    if2id_insn[30:25], if2id_insn[11:8], 1'b0};
    assign imm_u = {if2id_insn[31:12], 12'b0};
    assign imm_j = {{11{if2id_insn[31]}}, if2id_insn[31], if2id_insn[19:12],
                    if2id_insn[20], if2id_insn[30:21], 1'b0};

    assign is_ecall    = (if2id_insn == 32'h0000_0073);
    assign is_rtype    = (opcode == 7'b0110011);
    assign is_itype    = (opcode == 7'b0010011);
    assign is_shift_imm= is_itype && ((funct3 == 3'b001) || (funct3 == 3'b101));
    assign is_load     = (opcode == 7'b0000011);
    assign is_store    = (opcode == 7'b0100011);
    assign is_branch   = (opcode == 7'b1100011);
    assign is_jal      = (opcode == 7'b1101111);
    assign is_jalr     = (opcode == 7'b1100111);
    assign is_lui      = (opcode == 7'b0110111);
    assign is_auipc    = (opcode == 7'b0010111);

    always_comb begin
        imm = 32'b0;
        if (is_itype || is_load || is_jalr)
            imm = imm_i;
        else if (is_store)
            imm = imm_s;
        else if (is_branch)
            imm = imm_b;
        else if (is_lui || is_auipc)
            imm = imm_u;
        else if (is_jal)
            imm = imm_j;
    end

    always_comb begin
        alu_op    = ALU_ADD;
        op_a_pc   = 1'b0;
        op_b_imm  = 1'b0;
        reg_write = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        branch    = 1'b0;
        jump      = 1'b0;
        wb_sel    = WB_ALU;
        uses_rs1  = 1'b0;
        uses_rs2  = 1'b0;

        if (is_rtype) begin
            reg_write = 1'b1;
            uses_rs1  = 1'b1;
            uses_rs2  = 1'b1;
            case (funct3)
                3'b000: alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                3'b001: alu_op = ALU_SLL;
                3'b010: alu_op = ALU_SLT;
                3'b011: alu_op = ALU_SLTU;
                3'b100: alu_op = ALU_XOR;
                3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                3'b110: alu_op = ALU_OR;
                3'b111: alu_op = ALU_AND;
                default: alu_op = ALU_ADD;
            endcase
        end else if (is_itype) begin
            reg_write = 1'b1;
            uses_rs1  = 1'b1;
            op_b_imm  = 1'b1;
            case (funct3)
                3'b000: alu_op = ALU_ADD;
                3'b001: alu_op = ALU_SLL;
                3'b010: alu_op = ALU_SLT;
                3'b011: alu_op = ALU_SLTU;
                3'b100: alu_op = ALU_XOR;
                3'b101: alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                3'b110: alu_op = ALU_OR;
                3'b111: alu_op = ALU_AND;
                default: alu_op = ALU_ADD;
            endcase
        end else if (is_load) begin
            reg_write = 1'b1;
            mem_read  = 1'b1;
            uses_rs1  = 1'b1;
            op_b_imm  = 1'b1;
            alu_op    = ALU_ADD;
            wb_sel    = WB_MEM;
        end else if (is_store) begin
            mem_write = 1'b1;
            uses_rs1  = 1'b1;
            uses_rs2  = 1'b1;
            op_b_imm  = 1'b1;
            alu_op    = ALU_ADD;
        end else if (is_branch) begin
            branch    = 1'b1;
            uses_rs1  = 1'b1;
            uses_rs2  = 1'b1;
            alu_op    = ALU_SUB;
        end else if (is_jal) begin
            reg_write = 1'b1;
            jump      = 1'b1;
            wb_sel    = WB_PC4;
        end else if (is_jalr) begin
            reg_write = 1'b1;
            jump      = 1'b1;
            uses_rs1  = 1'b1;
            op_b_imm  = 1'b1;
            alu_op    = ALU_ADD;
            wb_sel    = WB_PC4;
        end else if (is_lui) begin
            reg_write = 1'b1;
            op_b_imm  = 1'b1;
            alu_op    = ALU_ADD;
        end else if (is_auipc) begin
            reg_write = 1'b1;
            op_a_pc   = 1'b1;
            op_b_imm  = 1'b1;
            alu_op    = ALU_ADD;
        end
    end

    assign id_rs1       = rs1;
    assign id_rs2       = rs2;
    assign id_uses_rs1  = uses_rs1;
    assign id_uses_rs2  = uses_rs2;
    assign ecall_in_id  = if2id_valid && is_ecall;

    always_comb begin
        rs1_val = 32'b0;
        if (rs1 != 5'd0) begin
            if (wb_reg_write && (wb_rd == rs1) && (wb_rd != 5'd0))
                rs1_val = wb_data;
            else
                rs1_val = regs[rs1];
        end
    end

    always_comb begin
        rs2_val = 32'b0;
        if (rs2 != 5'd0) begin
            if (wb_reg_write && (wb_rd == rs2) && (wb_rd != 5'd0))
                rs2_val = wb_data;
            else
                rs2_val = regs[rs2];
        end
    end

    always_comb begin
        dbg_reg_data = 32'b0;
        if (dbg_reg_addr != 5'd0)
            dbg_reg_data = regs[dbg_reg_addr];
    end

    assign reg_x10 = regs[10];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 1; i < 32; i++)
                regs[i] <= 32'b0;
        end else if (wb_reg_write && (wb_rd != 5'd0)) begin
            regs[wb_rd] <= wb_data;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            id2ex_valid     <= 1'b0;
            id2ex_pc        <= 32'b0;
            id2ex_pc4       <= 32'b0;
            id2ex_insn      <= 32'b0;
            id2ex_rs1_val   <= 32'b0;
            id2ex_rs2_val   <= 32'b0;
            id2ex_imm       <= 32'b0;
            id2ex_rs1       <= 5'b0;
            id2ex_rs2       <= 5'b0;
            id2ex_rd        <= 5'b0;
            id2ex_alu_op    <= ALU_ADD;
            id2ex_op_a_pc   <= 1'b0;
            id2ex_op_b_imm  <= 1'b0;
            id2ex_reg_write <= 1'b0;
            id2ex_mem_read  <= 1'b0;
            id2ex_mem_write <= 1'b0;
            id2ex_branch    <= 1'b0;
            id2ex_jump      <= 1'b0;
            id2ex_wb_sel    <= WB_ALU;
            id2ex_funct3    <= 3'b0;
            id2ex_is_ecall  <= 1'b0;
            idex_pred_valid    <= 1'b0;
            idex_pred_next_pc  <= 32'b0;
        end else if (mem_stall) begin
            id2ex_valid     <= id2ex_valid;
        end else if (flush_id_ex) begin
            id2ex_valid     <= 1'b0;
            id2ex_pc        <= 32'b0;
            id2ex_pc4       <= 32'b0;
            id2ex_insn      <= 32'b0;
            id2ex_rs1_val   <= 32'b0;
            id2ex_rs2_val   <= 32'b0;
            id2ex_imm       <= 32'b0;
            id2ex_rs1       <= 5'b0;
            id2ex_rs2       <= 5'b0;
            id2ex_rd        <= 5'b0;
            id2ex_alu_op    <= ALU_ADD;
            id2ex_op_a_pc   <= 1'b0;
            id2ex_op_b_imm  <= 1'b0;
            id2ex_reg_write <= 1'b0;
            id2ex_mem_read  <= 1'b0;
            id2ex_mem_write <= 1'b0;
            id2ex_branch    <= 1'b0;
            id2ex_jump      <= 1'b0;
            id2ex_wb_sel    <= WB_ALU;
            id2ex_funct3    <= 3'b0;
            id2ex_is_ecall  <= 1'b0;
            idex_pred_valid    <= 1'b0;
            idex_pred_next_pc  <= 32'b0;
        end else begin
            id2ex_valid     <= if2id_valid;
            id2ex_pc        <= if2id_pc;
            id2ex_pc4       <= if2id_pc4;
            id2ex_insn      <= if2id_insn;
            id2ex_rs1_val   <= rs1_val;
            id2ex_rs2_val   <= rs2_val;
            id2ex_imm       <= imm;
            id2ex_rs1       <= rs1;
            id2ex_rs2       <= rs2;
            id2ex_rd        <= rd;
            id2ex_alu_op    <= alu_op;
            id2ex_op_a_pc   <= op_a_pc;
            id2ex_op_b_imm  <= op_b_imm;
            id2ex_reg_write <= reg_write;
            id2ex_mem_read  <= mem_read;
            id2ex_mem_write <= mem_write;
            id2ex_branch    <= branch;
            id2ex_jump      <= jump;
            id2ex_wb_sel    <= wb_sel;
            id2ex_funct3    <= funct3;
            id2ex_is_ecall  <= is_ecall;
            idex_pred_valid    <= ifid_pred_valid;
            idex_pred_next_pc  <= ifid_pred_next_pc;
        end
    end

endmodule


// file: rtl/ex_stage.sv
module ex_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        mem_stall,
    input  logic        id2ex_valid,
    input  logic [31:0] id2ex_pc,
    input  logic [31:0] id2ex_pc4,
    input  logic [31:0] id2ex_insn,
    input  logic [31:0] id2ex_rs1_val,
    input  logic [31:0] id2ex_rs2_val,
    input  logic [31:0] id2ex_imm,
    input  logic [4:0]  id2ex_rs1,
    input  logic [4:0]  id2ex_rs2,
    input  logic [4:0]  id2ex_rd,
    input  logic [3:0]  id2ex_alu_op,
    input  logic        id2ex_op_a_pc,
    input  logic        id2ex_op_b_imm,
    input  logic        id2ex_reg_write,
    input  logic        id2ex_mem_read,
    input  logic        id2ex_mem_write,
    input  logic        id2ex_branch,
    input  logic        id2ex_jump,
    input  logic [1:0]  id2ex_wb_sel,
    input  logic [2:0]  id2ex_funct3,
    input  logic        id2ex_is_ecall,
    input  logic [1:0]  fwd_a,
    input  logic [1:0]  fwd_b,
    input  logic [31:0] mem2wb_wdata,
    input  logic [31:0] wb_wdata,
    input  logic [31:0] ex2mem_forward_data,
    output logic        redirect_valid,
    output logic [31:0] redirect_target,
    output logic        ex_load_valid,
    output logic [4:0]  ex_load_rd,
    output logic        ex2mem_valid,
    output logic [31:0] ex2mem_pc,
    output logic [31:0] ex2mem_pc4,
    output logic [31:0] ex2mem_insn,
    output logic [31:0] ex2mem_alu_result,
    output logic [31:0] ex2mem_store_data,
    output logic [4:0]  ex2mem_rd,
    output logic        ex2mem_reg_write,
    output logic        ex2mem_mem_read,
    output logic        ex2mem_mem_write,
    output logic [1:0]  ex2mem_wb_sel,
    output logic [2:0]  ex2mem_funct3,
    output logic        ex2mem_is_ecall
);

    logic [31:0] alu_a;
    logic [31:0] alu_b;
    logic [31:0] alu_y;
    logic [31:0] rs1_fwd;
    logic [31:0] rs2_fwd;
    logic        branch_taken;
    logic        jump_taken;
    logic [31:0] branch_target;
    logic [31:0] jump_target;

    always_comb begin
        rs1_fwd = id2ex_rs1_val;
        if (fwd_a == 2'b10) begin
            rs1_fwd = ex2mem_forward_data;
        end else if (fwd_a == 2'b01) begin
            rs1_fwd = mem2wb_wdata;
        end
        rs2_fwd = id2ex_rs2_val;
        if (fwd_b == 2'b10) begin
            rs2_fwd = ex2mem_forward_data;
        end else if (fwd_b == 2'b01) begin
            rs2_fwd = mem2wb_wdata;
        end
    end

    always_comb begin
        alu_a = id2ex_op_a_pc ? id2ex_pc : rs1_fwd;
        alu_b = id2ex_op_b_imm ? id2ex_imm : rs2_fwd;
    end

    alu u_alu (
        .alu_op (id2ex_alu_op),
        .a      (alu_a),
        .b      (alu_b),
        .y      (alu_y)
    );

    always_comb begin
        branch_taken = 1'b0;
        if (id2ex_valid && id2ex_branch) begin
            case (id2ex_funct3)
                3'b000: branch_taken = (rs1_fwd == rs2_fwd);
                3'b001: branch_taken = (rs1_fwd != rs2_fwd);
                3'b100: branch_taken = ($signed(rs1_fwd) < $signed(rs2_fwd));
                3'b101: branch_taken = ($signed(rs1_fwd) >= $signed(rs2_fwd));
                3'b110: branch_taken = (rs1_fwd < rs2_fwd);
                3'b111: branch_taken = (rs1_fwd >= rs2_fwd);
                default: branch_taken = 1'b0;
            endcase
        end
    end

    always_comb begin
        jump_taken = id2ex_valid && id2ex_jump;
    end

    always_comb begin
        branch_target = id2ex_pc + id2ex_imm;
        if (id2ex_insn[6:0] == 7'b1100111) begin
            jump_target = (rs1_fwd + id2ex_imm) & 32'hFFFF_FFFE;
        end else begin
            jump_target = id2ex_pc + id2ex_imm;
        end
    end

    // Redirect on ANY resolved control transfer: taken branch, not-taken
    // branch (fall-through), JAL, JALR. A not-taken branch must still
    // redirect to pc+4 so a predicted-taken fetch is flushed.
    always_comb begin
        redirect_valid = 1'b0;
        redirect_target = 32'h0000_0000;
        if (id2ex_valid && id2ex_branch) begin
            redirect_valid = 1'b1;
            redirect_target = branch_taken ? branch_target : id2ex_pc4;
        end else if (jump_taken) begin
            redirect_valid = 1'b1;
            redirect_target = jump_target;
        end
    end

    always_comb begin
        ex_load_valid = id2ex_valid && id2ex_mem_read && (id2ex_rd != 5'd0);
        ex_load_rd = id2ex_rd;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex2mem_valid <= 1'b0;
            ex2mem_pc <= 32'h0000_0000;
            ex2mem_pc4 <= 32'h0000_0000;
            ex2mem_insn <= 32'h0000_0000;
            ex2mem_alu_result <= 32'h0000_0000;
            ex2mem_store_data <= 32'h0000_0000;
            ex2mem_rd <= 5'd0;
            ex2mem_reg_write <= 1'b0;
            ex2mem_mem_read <= 1'b0;
            ex2mem_mem_write <= 1'b0;
            ex2mem_wb_sel <= 2'b00;
            ex2mem_funct3 <= 3'b000;
            ex2mem_is_ecall <= 1'b0;
        end else if (!mem_stall) begin
            ex2mem_valid <= id2ex_valid;
            ex2mem_pc <= id2ex_pc;
            ex2mem_pc4 <= id2ex_pc4;
            ex2mem_insn <= id2ex_insn;
            ex2mem_alu_result <= alu_y;
            ex2mem_store_data <= rs2_fwd;
            ex2mem_rd <= id2ex_rd;
            ex2mem_reg_write <= id2ex_reg_write;
            ex2mem_mem_read <= id2ex_mem_read;
            ex2mem_mem_write <= id2ex_mem_write;
            ex2mem_wb_sel <= id2ex_wb_sel;
            ex2mem_funct3 <= id2ex_funct3;
            ex2mem_is_ecall <= id2ex_is_ecall;
        end
    end

endmodule


// file: rtl/dcache.sv
module dcache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        flush,
    input  logic [1:0]  flush_epoch,
    input  logic        cpu_req_valid,
    input  logic        cpu_req_we,
    input  logic [31:0] cpu_req_addr,
    input  logic [31:0] cpu_req_wdata,
    input  logic [3:0]  cpu_req_be,
    output logic        cpu_req_ready,
    output logic        cpu_resp_valid,
    output logic [31:0] cpu_resp_rdata,
    output logic        mem_req_valid,
    output logic        mem_req_we,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_wdata,
    output logic [3:0]  mem_req_be,
    input  logic        mem_req_ready,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data
);

    localparam logic [1:0] S_IDLE  = 2'd0;
    localparam logic [1:0] S_REFILL = 2'd1;
    localparam logic [1:0] S_WT     = 2'd2;
    localparam logic [1:0] S_RESP   = 2'd3;

    logic [1:0]  state;
    logic [127:0] data_arr [0:15];
    logic [23:0]  tag_arr  [0:15];
    logic [15:0]  valid_arr;

    logic [3:0]  idx;
    logic [23:0] tag;
    logic [1:0]  wsel;
    logic        hit;
    logic [127:0] line_data;
    logic [31:0] hit_word;

    logic [1:0]  refill_cnt;
    logic [31:0] refill_base;
    logic [23:0] refill_tag;
    logic [3:0]  refill_idx;
    logic [127:0] refill_data;
    logic [1:0]  refill_epoch;
    logic [1:0]  refill_word;

    logic [31:0] store_word;

    logic [31:0] wt_addr;
    logic [31:0] wt_wdata;
    logic [3:0]  wt_be;
    logic [1:0]  wt_epoch;

    logic [31:0] resp_rdata;

    logic        req_is_store;
    logic        req_hit;
    logic        req_miss;
    logic        req_accept;

    assign idx  = cpu_req_addr[7:4];
    assign tag  = cpu_req_addr[31:8];
    assign wsel = cpu_req_addr[3:2];

    assign hit = valid_arr[idx] && (tag_arr[idx] == tag);
    assign line_data = data_arr[idx];
    assign hit_word = line_data[{wsel, 5'b00000} +: 32];

    always_comb begin
        store_word = hit_word;
        if (cpu_req_be[0]) store_word[7:0]   = cpu_req_wdata[7:0];
        if (cpu_req_be[1]) store_word[15:8]  = cpu_req_wdata[15:8];
        if (cpu_req_be[2]) store_word[23:16] = cpu_req_wdata[23:16];
        if (cpu_req_be[3]) store_word[31:24] = cpu_req_wdata[31:24];
    end

    assign req_is_store = cpu_req_we;
    assign req_hit  = hit;
    assign req_miss = !hit;
    assign req_accept = cpu_req_valid && cpu_req_ready;

    always_comb begin
        cpu_req_ready = 1'b0;
        if (rst_n && !halted) begin
            case (state)
                S_IDLE:  cpu_req_ready = 1'b1;
                S_RESP:  cpu_req_ready = 1'b1;
                default: cpu_req_ready = 1'b0;
            endcase
        end
    end

    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_we    = 1'b0;
        mem_req_addr  = 32'b0;
        mem_req_wdata = 32'b0;
        mem_req_be    = 4'b0000;
        if (rst_n && !halted) begin
            case (state)
                S_REFILL: begin
                    mem_req_valid = 1'b1;
                    mem_req_we    = 1'b0;
                    mem_req_addr  = refill_base + {refill_cnt, 2'b00};
                    mem_req_wdata = 32'b0;
                    mem_req_be    = 4'b0000;
                end
                S_WT: begin
                    mem_req_valid = 1'b1;
                    mem_req_we    = 1'b1;
                    mem_req_addr  = wt_addr;
                    mem_req_wdata = wt_wdata;
                    mem_req_be    = wt_be;
                end
                default: begin
                    mem_req_valid = 1'b0;
                end
            endcase
        end
    end

    always_comb begin
        cpu_resp_valid = 1'b0;
        cpu_resp_rdata = resp_rdata;
        if (rst_n && !halted && (state == S_RESP)) begin
            cpu_resp_valid = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            valid_arr    <= 16'b0;
            refill_cnt   <= 2'd0;
            refill_base  <= 32'b0;
            refill_tag   <= 24'b0;
            refill_idx   <= 4'b0;
            refill_data  <= 128'b0;
            refill_epoch <= 2'b0;
            refill_word  <= 2'b0;
            wt_addr      <= 32'b0;
            wt_wdata     <= 32'b0;
            wt_be        <= 4'b0;
            wt_epoch     <= 2'b0;
            resp_rdata   <= 32'b0;
        end else if (halted) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_accept) begin
                        if (req_is_store) begin
                            if (req_hit) begin
                                data_arr[idx] <= (line_data & ~(128'hFFFFFFFF << {wsel, 5'b00000})) |
                                                 ({96'b0, store_word} << {wsel, 5'b00000});
                                wt_addr  <= cpu_req_addr;
                                wt_wdata <= cpu_req_wdata;
                                wt_be    <= cpu_req_be;
                                wt_epoch <= flush_epoch;
                                state    <= S_WT;
                            end else begin
                                refill_base  <= {cpu_req_addr[31:4], 4'b0000};
                                refill_tag   <= tag;
                                refill_idx   <= idx;
                                refill_word  <= wsel;
                                refill_cnt   <= 2'd0;
                                refill_data  <= 128'b0;
                                refill_epoch <= flush_epoch;
                                wt_addr      <= cpu_req_addr;
                                wt_wdata     <= cpu_req_wdata;
                                wt_be        <= cpu_req_be;
                                wt_epoch     <= flush_epoch;
                                state        <= S_REFILL;
                            end
                        end else begin
                            if (req_hit) begin
                                resp_rdata <= hit_word;
                                state      <= S_RESP;
                            end else begin
                                refill_base  <= {cpu_req_addr[31:4], 4'b0000};
                                refill_tag   <= tag;
                                refill_idx   <= idx;
                                refill_word  <= wsel;
                                refill_cnt   <= 2'd0;
                                refill_data  <= 128'b0;
                                refill_epoch <= flush_epoch;
                                state        <= S_REFILL;
                            end
                        end
                    end
                end

                S_REFILL: begin
                    if (mem_req_valid && mem_req_ready) begin
                        refill_data[{refill_cnt, 5'b00000} +: 32] <= mem_resp_data;
                        if (refill_cnt == 2'd3) begin
                            if (req_is_store) begin
                                // Write-through, no-write-allocate: 外部写完成
                                // 后让该行失效，后续 load 从 DMEM 重新 refill，
                                // 避免旧 hit_word 污染 line 中未写字节。
                                data_arr[refill_idx]  <= refill_data |
                                    ({96'b0, mem_resp_data} << {refill_cnt, 5'b00000});
                                tag_arr[refill_idx]   <= refill_tag;
                                valid_arr[refill_idx] <= 1'b0;
                            end else begin
                                data_arr[refill_idx]  <= refill_data |
                                    ({96'b0, mem_resp_data} << {refill_cnt, 5'b00000});
                                tag_arr[refill_idx]   <= refill_tag;
                                valid_arr[refill_idx] <= 1'b1;
                            end
                            if (req_is_store) begin
                                wt_epoch <= flush_epoch;
                                state    <= S_WT;
                            end else begin
                                // 返回请求字而不是 refill 的最后一个字。
                                case (wsel)
                                    2'd0: resp_rdata <= refill_data[31:0];
                                    2'd1: resp_rdata <= refill_data[63:32];
                                    2'd2: resp_rdata <= refill_data[95:64];
                                    default: resp_rdata <= mem_resp_data;
                                endcase
                                state      <= S_RESP;
                            end
                        end else begin
                            refill_cnt <= refill_cnt + 2'd1;
                        end
                    end
                end

                S_WT: begin
                    if (mem_req_valid && mem_req_ready) begin
                        resp_rdata <= 32'b0;
                        state      <= S_RESP;
                    end
                end

                S_RESP: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule


// file: rtl/mem_stage.sv
module mem_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        ex2mem_valid,
    input  logic [31:0] ex2mem_pc,
    input  logic [31:0] ex2mem_pc4,
    input  logic [31:0] ex2mem_insn,
    input  logic [31:0] ex2mem_alu_result,
    input  logic [31:0] ex2mem_store_data,
    input  logic [4:0]  ex2mem_rd,
    input  logic        ex2mem_reg_write,
    input  logic        ex2mem_mem_read,
    input  logic        ex2mem_mem_write,
    input  logic [1:0]  ex2mem_wb_sel,
    input  logic [2:0]  ex2mem_funct3,
    input  logic        ex2mem_is_ecall,
    output logic        cpu_req_valid,
    output logic        cpu_req_we,
    output logic [31:0] cpu_req_addr,
    output logic [31:0] cpu_req_wdata,
    output logic [3:0]  cpu_req_be,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_rdata,
    output logic        mem_stall,
    output logic        mem2wb_valid,
    output logic [31:0] mem2wb_pc,
    output logic [31:0] mem2wb_insn,
    output logic [31:0] mem2wb_wdata,
    output logic [4:0]  mem2wb_rd,
    output logic        mem2wb_reg_write,
    output logic        mem2wb_is_ecall
);

    localparam logic [1:0] WB_SEL_ALU  = 2'b00;
    localparam logic [1:0] WB_SEL_MEM  = 2'b01;
    localparam logic [1:0] WB_SEL_PC4  = 2'b10;
    localparam logic [1:0] WB_SEL_PC   = 2'b11;

    localparam logic [2:0] F3_LB  = 3'b000;
    localparam logic [2:0] F3_LH  = 3'b001;
    localparam logic [2:0] F3_LW  = 3'b010;
    localparam logic [2:0] F3_LBU = 3'b100;
    localparam logic [2:0] F3_LHU = 3'b101;
    localparam logic [2:0] F3_SB  = 3'b000;
    localparam logic [2:0] F3_SH  = 3'b001;
    localparam logic [2:0] F3_SW  = 3'b010;

    logic        mem_active;
    logic        mem_is_load;
    logic        mem_is_store;
    logic        mem_wait_resp;
    logic [31:0] mem_addr;
    logic [31:0] mem_store_data;
    logic [2:0]  mem_funct3;
    logic [31:0] mem_pc;
    logic [31:0] mem_pc4;
    logic [31:0] mem_insn;
    logic [4:0]  mem_rd;
    logic        mem_reg_write;
    logic [1:0]  mem_wb_sel;
    logic        mem_is_ecall;

    logic [31:0] store_wdata;
    logic [3:0]  store_be;

    logic [31:0] load_data;
    logic [31:0] wb_data;

    always_comb begin
        store_wdata = ex2mem_store_data;
        store_be    = 4'b0000;
        case (ex2mem_funct3)
            F3_SB: begin
                store_wdata = {4{ex2mem_store_data[7:0]}};
                store_be    = 4'b0001 << ex2mem_alu_result[1:0];
            end
            F3_SH: begin
                store_wdata = {2{ex2mem_store_data[15:0]}};
                store_be    = ex2mem_alu_result[1] ? 4'b1100 : 4'b0011;
            end
            F3_SW: begin
                store_wdata = ex2mem_store_data;
                store_be    = 4'b1111;
            end
            default: begin
                store_wdata = ex2mem_store_data;
                store_be    = 4'b0000;
            end
        endcase
    end

    always_comb begin
        cpu_req_valid = 1'b0;
        cpu_req_we    = 1'b0;
        cpu_req_addr  = 32'b0;
        cpu_req_wdata = 32'b0;
        cpu_req_be    = 4'b0000;
        if (rst_n && !halted) begin
            if (mem_active) begin
                if (mem_is_load) begin
                    cpu_req_valid = !mem_wait_resp;
                    cpu_req_we    = 1'b0;
                    cpu_req_addr  = mem_addr;
                    cpu_req_wdata = 32'b0;
                    cpu_req_be    = 4'b0000;
                end else if (mem_is_store) begin
                    cpu_req_valid = !mem_wait_resp;
                    cpu_req_we    = 1'b1;
                    cpu_req_addr  = mem_addr;
                    cpu_req_wdata = store_wdata;
                    cpu_req_be    = store_be;
                end
            end else if (ex2mem_valid && (ex2mem_mem_read || ex2mem_mem_write)) begin
                if (ex2mem_mem_read) begin
                    cpu_req_valid = 1'b1;
                    cpu_req_we    = 1'b0;
                    cpu_req_addr  = ex2mem_alu_result;
                    cpu_req_wdata = 32'b0;
                    cpu_req_be    = 4'b0000;
                end else begin
                    cpu_req_valid = 1'b1;
                    cpu_req_we    = 1'b1;
                    cpu_req_addr  = ex2mem_alu_result;
                    cpu_req_wdata = store_wdata;
                    cpu_req_be    = store_be;
                end
            end
        end
    end

    always_comb begin
        mem_stall = 1'b0;
        if (rst_n && !halted) begin
            if (mem_active) begin
                mem_stall = 1'b1;
            end else if (ex2mem_valid && (ex2mem_mem_read || ex2mem_mem_write)) begin
                if (!cpu_req_ready) begin
                    mem_stall = 1'b1;
                end
            end
        end
    end

    always_comb begin
        load_data = 32'b0;
        case (mem_funct3)
            F3_LB: begin
                case (mem_addr[1:0])
                    2'b00: load_data = {{24{cpu_resp_rdata[7]}},  cpu_resp_rdata[7:0]};
                    2'b01: load_data = {{24{cpu_resp_rdata[15]}}, cpu_resp_rdata[15:8]};
                    2'b10: load_data = {{24{cpu_resp_rdata[23]}}, cpu_resp_rdata[23:16]};
                    default: load_data = {{24{cpu_resp_rdata[31]}}, cpu_resp_rdata[31:24]};
                endcase
            end
            F3_LH: begin
                if (mem_addr[1]) begin
                    load_data = {{16{cpu_resp_rdata[31]}}, cpu_resp_rdata[31:16]};
                end else begin
                    load_data = {{16{cpu_resp_rdata[15]}}, cpu_resp_rdata[15:0]};
                end
            end
            F3_LW: begin
                load_data = cpu_resp_rdata;
            end
            F3_LBU: begin
                case (mem_addr[1:0])
                    2'b00: load_data = {24'b0, cpu_resp_rdata[7:0]};
                    2'b01: load_data = {24'b0, cpu_resp_rdata[15:8]};
                    2'b10: load_data = {24'b0, cpu_resp_rdata[23:16]};
                    default: load_data = {24'b0, cpu_resp_rdata[31:24]};
                endcase
            end
            F3_LHU: begin
                if (mem_addr[1]) begin
                    load_data = {16'b0, cpu_resp_rdata[31:16]};
                end else begin
                    load_data = {16'b0, cpu_resp_rdata[15:0]};
                end
            end
            default: begin
                load_data = cpu_resp_rdata;
            end
        endcase
    end

    always_comb begin
        wb_data = mem_pc4;
        case (mem_wb_sel)
            WB_SEL_ALU: wb_data = mem_pc4;
            WB_SEL_MEM: wb_data = load_data;
            WB_SEL_PC4: wb_data = mem_pc4;
            WB_SEL_PC:  wb_data = mem_pc;
            default:    wb_data = mem_pc4;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_active      <= 1'b0;
            mem_is_load     <= 1'b0;
            mem_is_store    <= 1'b0;
            mem_wait_resp   <= 1'b0;
            mem_addr        <= 32'b0;
            mem_store_data  <= 32'b0;
            mem_funct3      <= 3'b0;
            mem_pc          <= 32'b0;
            mem_pc4         <= 32'b0;
            mem_insn        <= 32'b0;
            mem_rd          <= 5'b0;
            mem_reg_write   <= 1'b0;
            mem_wb_sel      <= 2'b0;
            mem_is_ecall    <= 1'b0;
            mem2wb_valid    <= 1'b0;
            mem2wb_pc       <= 32'b0;
            mem2wb_insn     <= 32'b0;
            mem2wb_wdata    <= 32'b0;
            mem2wb_rd       <= 5'b0;
            mem2wb_reg_write<= 1'b0;
            mem2wb_is_ecall <= 1'b0;
        end else if (halted) begin
            mem_active      <= 1'b0;
            mem_is_load     <= 1'b0;
            mem_is_store    <= 1'b0;
            mem_wait_resp   <= 1'b0;
            mem2wb_valid    <= 1'b0;
            mem2wb_reg_write<= 1'b0;
            mem2wb_is_ecall <= 1'b0;
        end else begin
            mem2wb_valid    <= 1'b0;
            mem2wb_reg_write<= 1'b0;
            mem2wb_is_ecall <= 1'b0;

            if (mem_active) begin
                // D-Cache 的响应可能只保持一个周期，甚至在请求被接受的
                // 同一拍就到达。必须先看响应，再看 ready；否则会错过
                // S_RESP 的 resp_valid，导致 MEM 永久等待。
                if (cpu_resp_valid) begin
                    mem2wb_valid     <= 1'b1;
                    mem2wb_pc        <= mem_pc;
                    mem2wb_insn      <= mem_insn;
                    mem2wb_wdata     <= wb_data;
                    mem2wb_rd        <= mem_rd;
                    mem2wb_reg_write <= mem_reg_write;
                    mem2wb_is_ecall  <= mem_is_ecall;
                    mem_active       <= 1'b0;
                    mem_is_load      <= 1'b0;
                    mem_is_store     <= 1'b0;
                    mem_wait_resp    <= 1'b0;
                end else if (!mem_wait_resp && cpu_req_ready) begin
                    mem_wait_resp <= 1'b1;
                end
            end else if (ex2mem_valid) begin
                if (ex2mem_mem_read || ex2mem_mem_write) begin
                    mem_active     <= 1'b1;
                    mem_is_load    <= ex2mem_mem_read;
                    mem_is_store   <= ex2mem_mem_write;
                    mem_wait_resp  <= 1'b0;
                    mem_addr       <= ex2mem_alu_result;
                    mem_store_data <= ex2mem_store_data;
                    mem_funct3     <= ex2mem_funct3;
                    mem_pc         <= ex2mem_pc;
                    mem_pc4        <= ex2mem_pc4;
                    mem_insn       <= ex2mem_insn;
                    mem_rd         <= ex2mem_rd;
                    mem_reg_write  <= ex2mem_reg_write;
                    mem_wb_sel     <= ex2mem_wb_sel;
                    mem_is_ecall   <= ex2mem_is_ecall;
                end else begin
                    mem2wb_valid     <= 1'b1;
                    mem2wb_pc        <= ex2mem_pc;
                    mem2wb_insn      <= ex2mem_insn;
                    mem2wb_wdata     <= (ex2mem_wb_sel == WB_SEL_PC4) ? ex2mem_pc4 :
                                        (ex2mem_wb_sel == WB_SEL_PC)  ? ex2mem_pc  :
                                                                        ex2mem_alu_result;
                    mem2wb_rd        <= ex2mem_rd;
                    mem2wb_reg_write <= ex2mem_reg_write;
                    mem2wb_is_ecall  <= ex2mem_is_ecall;
                end
            end
        end
    end

endmodule


// file: rtl/wb_stage.sv
module wb_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        mem2wb_valid,
    input  logic [31:0] mem2wb_pc,
    input  logic [31:0] mem2wb_insn,
    input  logic [31:0] mem2wb_wdata,
    input  logic [4:0]  mem2wb_rd,
    input  logic        mem2wb_reg_write,
    input  logic        mem2wb_is_ecall,
    input  logic [31:0] reg_x10,
    output logic        wb_reg_write,
    output logic [4:0]  wb_rd,
    output logic [31:0] wb_data,
    output logic        halted,
    output logic [31:0] exit_code,
    output logic        dbg_retire_valid,
    output logic [31:0] dbg_retire_pc,
    output logic [31:0] dbg_retire_insn
);

    logic        halted_q;
    logic [31:0] exit_code_q;

    assign wb_reg_write = mem2wb_valid && mem2wb_reg_write && (mem2wb_rd != 5'd0) && !halted_q;
    assign wb_rd        = mem2wb_rd;
    assign wb_data      = mem2wb_wdata;

    assign dbg_retire_valid = mem2wb_valid && !halted_q;
    assign dbg_retire_pc    = mem2wb_pc;
    assign dbg_retire_insn  = mem2wb_insn;

    assign halted    = halted_q;
    assign exit_code = exit_code_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            halted_q    <= 1'b0;
            exit_code_q <= 32'd0;
        end else if (!halted_q) begin
            if (mem2wb_valid && mem2wb_is_ecall) begin
                halted_q    <= 1'b1;
                exit_code_q <= reg_x10;
            end
        end
    end

endmodule


// file: rtl/hazard_unit.sv
module hazard_unit (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       id_valid,
    input  logic [4:0] id_rs1,
    input  logic [4:0] id_rs2,
    input  logic       id_uses_rs1,
    input  logic       id_uses_rs2,
    input  logic       ex_load_valid,
    input  logic [4:0] ex_load_rd,
    input  logic       redirect_valid,
    input  logic       ecall_in_id,
    output logic       load_use_stall,
    output logic       flush_id_ex,
    output logic       flush,
    output logic [1:0] flush_epoch
);

    logic load_use_raw;

    always_comb begin
        load_use_raw = 1'b0;
        if (id_valid && ex_load_valid && (ex_load_rd != 5'd0)) begin
            if (id_uses_rs1 && (id_rs1 == ex_load_rd))
                load_use_raw = 1'b1;
            else if (id_uses_rs2 && (id_rs2 == ex_load_rd))
                load_use_raw = 1'b1;
        end
    end

    assign load_use_stall = load_use_raw && !redirect_valid;

    // ECALL must NOT flush ID/EX: the ECALL itself must continue through
    // EX -> MEM -> WB to commit and set halted. Only redirects flush ID/EX.
    assign flush_id_ex = redirect_valid;

    // Only real control-flow redirects invalidate in-flight cache refills.
    // ECALL is not a control transfer; incrementing flush_epoch on ECALL
    // would discard an in-flight I-cache refill and stall fetch forever.
    assign flush = redirect_valid;

    always_ff @(posedge clk) begin
        if (!rst_n)
            flush_epoch <= 2'b00;
        else if (flush)
            flush_epoch <= flush_epoch + 2'b01;
    end

endmodule


// file: rtl/forwarding_unit.sv
module forwarding_unit (
    input  logic [4:0] id2ex_rs1,
    input  logic [4:0] id2ex_rs2,
    input  logic       ex2mem_valid,
    input  logic       ex2mem_reg_write,
    input  logic       ex2mem_mem_read,
    input  logic [4:0] ex2mem_rd,
    input  logic       mem2wb_valid,
    input  logic       mem2wb_reg_write,
    input  logic [4:0] mem2wb_rd,
    output logic [1:0] fwd_a,
    output logic [1:0] fwd_b
);

    logic ex2mem_hit_a;
    logic ex2mem_hit_b;
    logic mem2wb_hit_a;
    logic mem2wb_hit_b;

    always_comb begin
        ex2mem_hit_a = ex2mem_valid && ex2mem_reg_write && !ex2mem_mem_read &&
                       (ex2mem_rd != 5'd0) && (ex2mem_rd == id2ex_rs1);
        ex2mem_hit_b = ex2mem_valid && ex2mem_reg_write && !ex2mem_mem_read &&
                       (ex2mem_rd != 5'd0) && (ex2mem_rd == id2ex_rs2);
        mem2wb_hit_a = mem2wb_valid && mem2wb_reg_write &&
                       (mem2wb_rd != 5'd0) && (mem2wb_rd == id2ex_rs1);
        mem2wb_hit_b = mem2wb_valid && mem2wb_reg_write &&
                       (mem2wb_rd != 5'd0) && (mem2wb_rd == id2ex_rs2);

        if (ex2mem_hit_a) begin
            fwd_a = 2'b10;
        end else if (mem2wb_hit_a) begin
            fwd_a = 2'b01;
        end else begin
            fwd_a = 2'b00;
        end

        if (ex2mem_hit_b) begin
            fwd_b = 2'b10;
        end else if (mem2wb_hit_b) begin
            fwd_b = 2'b01;
        end else begin
            fwd_b = 2'b00;
        end
    end

endmodule


// file: rtl/alu.sv
module alu (
    input  logic [3:0]  alu_op,
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] y
);

    localparam logic [3:0] ALU_ADD  = 4'd0;
    localparam logic [3:0] ALU_SUB  = 4'd1;
    localparam logic [3:0] ALU_SLL  = 4'd2;
    localparam logic [3:0] ALU_SLT  = 4'd3;
    localparam logic [3:0] ALU_SLTU = 4'd4;
    localparam logic [3:0] ALU_XOR  = 4'd5;
    localparam logic [3:0] ALU_SRL  = 4'd6;
    localparam logic [3:0] ALU_SRA  = 4'd7;
    localparam logic [3:0] ALU_OR   = 4'd8;
    localparam logic [3:0] ALU_AND  = 4'd9;
    localparam logic [3:0] ALU_PASS_B = 4'd10;

    always_comb begin
        y = 32'h0000_0000;
        case (alu_op)
            ALU_ADD:    y = a + b;
            ALU_SUB:    y = a - b;
            ALU_SLL:    y = a << b[4:0];
            ALU_SLT:    y = ($signed(a) < $signed(b)) ? 32'h0000_0001 : 32'h0000_0000;
            ALU_SLTU:   y = (a < b) ? 32'h0000_0001 : 32'h0000_0000;
            ALU_XOR:    y = a ^ b;
            ALU_SRL:    y = a >> b[4:0];
            ALU_SRA:    y = $signed(a) >>> b[4:0];
            ALU_OR:     y = a | b;
            ALU_AND:    y = a & b;
            ALU_PASS_B: y = b;
            default:    y = 32'h0000_0000;
        endcase
    end

endmodule


// file: rtl/branch_predictor.sv
module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] bp_lookup_pc,
    output logic        bp_pred_valid,
    output logic [31:0] bp_pred_next_pc,
    input  logic        bp_resolve_valid,
    input  logic [31:0] bp_resolve_pc,
    input  logic [1:0]  bp_resolve_type,
    input  logic        bp_resolve_taken,
    input  logic [31:0] bp_resolve_target
);

    localparam logic [1:0] TYPE_BRANCH = 2'b01;
    localparam logic [1:0] TYPE_JAL    = 2'b10;
    localparam logic [1:0] TYPE_JALR   = 2'b11;

    logic        btb_valid [0:15];
    logic [25:0] btb_tag   [0:15];
    logic [31:0] btb_target[0:15];
    logic [1:0]  btb_type  [0:15];

    logic [1:0]  bht [0:15];

    logic [3:0]  lookup_index;
    logic [25:0] lookup_tag;
    logic [3:0]  resolve_index;
    logic [25:0] resolve_tag;

    logic        lookup_hit;
    logic [1:0]  lookup_type;
    logic [1:0]  lookup_bht;
    logic        lookup_bht_taken;

    assign lookup_index = bp_lookup_pc[5:2];
    assign lookup_tag   = bp_lookup_pc[31:6];
    assign resolve_index = bp_resolve_pc[5:2];
    assign resolve_tag   = bp_resolve_pc[31:6];

    assign lookup_hit   = btb_valid[lookup_index] && (btb_tag[lookup_index] == lookup_tag);
    assign lookup_type  = btb_type[lookup_index];
    assign lookup_bht   = bht[lookup_index];
    assign lookup_bht_taken = lookup_bht[1];

    always_comb begin
        bp_pred_valid   = 1'b0;
        bp_pred_next_pc = bp_lookup_pc + 32'd4;
        if (lookup_hit) begin
            if (lookup_type == TYPE_BRANCH) begin
                if (lookup_bht_taken) begin
                    bp_pred_valid   = 1'b1;
                    bp_pred_next_pc = btb_target[lookup_index];
                end
            end else if (lookup_type == TYPE_JAL || lookup_type == TYPE_JALR) begin
                bp_pred_valid   = 1'b1;
                bp_pred_next_pc = btb_target[lookup_index];
            end
        end
    end

    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= 26'd0;
                btb_target[i] <= 32'd0;
                btb_type[i]   <= 2'b00;
                bht[i]        <= 2'b01;
            end
        end else if (bp_resolve_valid) begin
            if (bp_resolve_type == TYPE_BRANCH) begin
                if (bp_resolve_taken) begin
                    if (bht[resolve_index] != 2'b11)
                        bht[resolve_index] <= bht[resolve_index] + 2'b01;
                end else begin
                    if (bht[resolve_index] != 2'b00)
                        bht[resolve_index] <= bht[resolve_index] - 2'b01;
                end

                if (!btb_valid[resolve_index] || (btb_tag[resolve_index] != resolve_tag)) begin
                    if (bp_resolve_taken) begin
                        btb_valid[resolve_index]  <= 1'b1;
                        btb_tag[resolve_index]    <= resolve_tag;
                        btb_target[resolve_index] <= bp_resolve_target;
                        btb_type[resolve_index]   <= TYPE_BRANCH;
                    end
                end else begin
                    if (btb_target[resolve_index] != bp_resolve_target)
                        btb_target[resolve_index] <= bp_resolve_target;
                    if (btb_type[resolve_index] != TYPE_BRANCH)
                        btb_type[resolve_index] <= TYPE_BRANCH;
                end
            end else if (bp_resolve_type == TYPE_JAL || bp_resolve_type == TYPE_JALR) begin
                if (!btb_valid[resolve_index] || (btb_tag[resolve_index] != resolve_tag)) begin
                    btb_valid[resolve_index]  <= 1'b1;
                    btb_tag[resolve_index]    <= resolve_tag;
                    btb_target[resolve_index] <= bp_resolve_target;
                    btb_type[resolve_index]   <= bp_resolve_type;
                end else begin
                    if (btb_target[resolve_index] != bp_resolve_target)
                        btb_target[resolve_index] <= bp_resolve_target;
                    if (btb_type[resolve_index] != bp_resolve_type)
                        btb_type[resolve_index] <= bp_resolve_type;
                end
            end
        end
    end

endmodule

