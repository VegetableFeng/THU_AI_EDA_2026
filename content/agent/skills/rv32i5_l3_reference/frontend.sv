module frontend (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        stop_fetch,
    input  logic        redirect,
    input  logic [31:0] redirect_pc,
    input  logic [1:0]  flush_epoch,
    output logic        cpu_req_valid,
    output logic [31:0] cpu_req_addr,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_data,
    output logic [31:0] bp_lookup_pc,
    input  logic        bp_pred_valid,
    input  logic [31:0] bp_pred_next_pc,
    output logic        fe_valid,
    input  logic        fe_ready,
    output logic [31:0] fe_pc,
    output logic [31:0] fe_instr,
    output logic        fe_pred_valid,
    output logic [31:0] fe_pred_next_pc,
    output logic [4:0]  fe_rs1,
    output logic [4:0]  fe_rs2,
    output logic [4:0]  fe_rd,
    output logic [31:0] fe_imm,
    output logic [3:0]  fe_alu_op,
    output logic [1:0]  fe_wb_sel,
    output logic        fe_reg_write,
    output logic        fe_mem_read,
    output logic        fe_mem_write,
    output logic        fe_branch,
    output logic [1:0]  fe_jump,
    output logic        fe_ecall,
    output logic [2:0]  fe_funct3,
    output logic        fe_use_rs1,
    output logic        fe_use_rs2,
    output logic        fe_src_a_pc,
    output logic        fe_src_b_imm
);

    // PC and request state
    logic [31:0] pc;
    logic        req_pending;
    logic [31:0] req_pc;
    logic        req_pred_valid;
    logic [31:0] req_pred_next_pc;
    logic [1:0]  inflight_epoch;

    // Decoded instruction buffer (IF/ID)
    logic        if2id_valid;
    logic [31:0] if2id_pc;
    logic [31:0] if2id_instr;
    logic        if2id_pred_valid;
    logic [31:0] if2id_pred_next_pc;

    // Decode combinational signals
    logic [6:0]  d_opcode;
    logic [2:0]  d_funct3;
    logic [6:0]  d_funct7;
    logic [4:0]  d_rs1;
    logic [4:0]  d_rs2;
    logic [4:0]  d_rd;
    logic [31:0] d_imm;
    logic [3:0]  d_alu_op;
    logic [1:0]  d_wb_sel;
    logic        d_reg_write;
    logic        d_mem_read;
    logic        d_mem_write;
    logic        d_branch;
    logic [1:0]  d_jump;
    logic        d_ecall;
    logic        d_use_rs1;
    logic        d_use_rs2;
    logic        d_src_a_pc;
    logic        d_src_b_imm;

    // Fetch control
    logic        fetch_stopped;
    logic        can_issue_req;
    logic        resp_accept;
    logic        resp_stale;
    logic        fe_advance;

    assign fetch_stopped = halted | stop_fetch;
    // 仅在 IF/ID 空或当拍排空时发新请求：保证响应落地时 IF/ID 必空，
    // 否则响应会无条件覆盖尚未被 rename 取走的指令（指令静默丢失）
    assign can_issue_req  = !fetch_stopped & !req_pending & !redirect & (!if2id_valid | fe_advance);
    assign resp_accept    = cpu_resp_valid & req_pending & (inflight_epoch == flush_epoch);
    assign resp_stale     = cpu_resp_valid & req_pending & (inflight_epoch != flush_epoch);
    assign fe_advance     = if2id_valid & fe_ready;

    // Decode function
    function automatic logic [31:0] decode_imm(
        input logic [6:0] opcode,
        input logic [31:0] instr
    );
        logic [31:0] imm;
        begin
            imm = 32'b0;
            case (opcode)
                7'b0010011, 7'b0000011, 7'b1100111: begin
                    imm = {{20{instr[31]}}, instr[31:20]};
                end
                7'b0100011: begin
                    imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
                end
                7'b1100011: begin
                    imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
                end
                7'b0110111, 7'b0010111: begin
                    imm = {instr[31:12], 12'b0};
                end
                7'b1101111: begin
                    imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
                end
                default: begin
                    imm = 32'b0;
                end
            endcase
            decode_imm = imm;
        end
    endfunction

    always_comb begin
        d_opcode    = if2id_instr[6:0];
        d_funct3    = if2id_instr[14:12];
        d_funct7    = if2id_instr[31:25];
        d_rs1       = if2id_instr[19:15];
        d_rs2       = if2id_instr[24:20];
        d_rd        = if2id_instr[11:7];
        d_imm       = decode_imm(d_opcode, if2id_instr);
        d_alu_op    = 4'd0;
        d_wb_sel    = 2'b00;
        d_reg_write = 1'b0;
        d_mem_read  = 1'b0;
        d_mem_write = 1'b0;
        d_branch    = 1'b0;
        d_jump      = 2'b00;
        d_ecall     = 1'b0;
        d_use_rs1   = 1'b0;
        d_use_rs2   = 1'b0;
        d_src_a_pc  = 1'b0;
        d_src_b_imm = 1'b0;

        case (d_opcode)
            7'b0110011: begin // R-type
                d_reg_write = 1'b1;
                d_use_rs1   = 1'b1;
                d_use_rs2   = 1'b1;
                d_wb_sel    = 2'b00;
                case (d_funct3)
                    3'b000: d_alu_op = d_funct7[5] ? 4'd1 : 4'd0;
                    3'b001: d_alu_op = 4'd2;
                    3'b010: d_alu_op = 4'd3;
                    3'b011: d_alu_op = 4'd4;
                    3'b100: d_alu_op = 4'd5;
                    3'b101: d_alu_op = d_funct7[5] ? 4'd7 : 4'd6;
                    3'b110: d_alu_op = 4'd8;
                    3'b111: d_alu_op = 4'd9;
                    default: d_alu_op = 4'd0;
                endcase
            end
            7'b0010011: begin // I-type ALU
                d_reg_write = 1'b1;
                d_use_rs1   = 1'b1;
                d_src_b_imm = 1'b1;
                d_wb_sel    = 2'b00;
                case (d_funct3)
                    3'b000: d_alu_op = 4'd0;
                    3'b010: d_alu_op = 4'd3;
                    3'b011: d_alu_op = 4'd4;
                    3'b100: d_alu_op = 4'd5;
                    3'b110: d_alu_op = 4'd8;
                    3'b111: d_alu_op = 4'd9;
                    3'b001: d_alu_op = 4'd2;
                    3'b101: d_alu_op = d_funct7[5] ? 4'd7 : 4'd6;
                    default: d_alu_op = 4'd0;
                endcase
            end
            7'b0000011: begin // Load
                d_reg_write = 1'b1;
                d_mem_read  = 1'b1;
                d_use_rs1   = 1'b1;
                d_src_b_imm = 1'b1;
                d_wb_sel    = 2'b10;
                d_alu_op    = 4'd0;
            end
            7'b0100011: begin // Store
                d_mem_write = 1'b1;
                d_use_rs1   = 1'b1;
                d_use_rs2   = 1'b1;
                d_src_b_imm = 1'b1;
                d_alu_op    = 4'd0;
            end
            7'b1100011: begin // Branch
                d_branch    = 1'b1;
                d_use_rs1   = 1'b1;
                d_use_rs2   = 1'b1;
                d_src_b_imm = 1'b1;
                d_alu_op    = 4'd0;
            end
            7'b1101111: begin // JAL
                d_reg_write = 1'b1;
                d_jump      = 2'b01;
                d_src_a_pc  = 1'b1;
                d_src_b_imm = 1'b1;
                d_wb_sel    = 2'b01;
                d_alu_op    = 4'd0;
            end
            7'b1100111: begin // JALR
                d_reg_write = 1'b1;
                d_jump      = 2'b10;
                d_use_rs1   = 1'b1;
                d_src_b_imm = 1'b1;
                d_wb_sel    = 2'b01;
                d_alu_op    = 4'd0;
            end
            7'b0110111: begin // LUI
                d_reg_write = 1'b1;
                d_src_b_imm = 1'b1;
                d_wb_sel    = 2'b00;
                d_alu_op    = 4'd10;
            end
            7'b0010111: begin // AUIPC
                d_reg_write = 1'b1;
                d_src_a_pc  = 1'b1;
                d_src_b_imm = 1'b1;
                d_wb_sel    = 2'b00;
                d_alu_op    = 4'd0;
            end
            7'b1110011: begin // ECALL
                if (if2id_instr == 32'h0000_0073) begin
                    d_ecall = 1'b1;
                end
            end
            default: begin
                d_alu_op    = 4'd0;
                d_wb_sel    = 2'b00;
                d_reg_write = 1'b0;
            end
        endcase
    end

    // Outputs
    assign cpu_req_valid = req_pending;
    assign cpu_req_addr  = req_pc;
    assign bp_lookup_pc  = pc;

    assign fe_valid         = if2id_valid;
    assign fe_pc            = if2id_pc;
    assign fe_instr         = if2id_instr;
    assign fe_pred_valid    = if2id_pred_valid;
    assign fe_pred_next_pc  = if2id_pred_next_pc;
    assign fe_rs1           = d_rs1;
    assign fe_rs2           = d_rs2;
    assign fe_rd            = d_rd;
    assign fe_imm           = d_imm;
    assign fe_alu_op        = d_alu_op;
    assign fe_wb_sel        = d_wb_sel;
    assign fe_reg_write     = d_reg_write;
    assign fe_mem_read      = d_mem_read;
    assign fe_mem_write     = d_mem_write;
    assign fe_branch        = d_branch;
    assign fe_jump          = d_jump;
    assign fe_ecall         = d_ecall;
    assign fe_funct3        = d_funct3;
    assign fe_use_rs1       = d_use_rs1;
    assign fe_use_rs2       = d_use_rs2;
    assign fe_src_a_pc      = d_src_a_pc;
    assign fe_src_b_imm     = d_src_b_imm;

    // Sequential state
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc                <= 32'b0;
            req_pending       <= 1'b1;
            req_pc            <= 32'b0;
            req_pred_valid    <= 1'b0;
            req_pred_next_pc  <= 32'b0;
            inflight_epoch    <= 2'b0;
            if2id_valid       <= 1'b0;
            if2id_pc          <= 32'b0;
            if2id_instr       <= 32'b0;
            if2id_pred_valid  <= 1'b0;
            if2id_pred_next_pc<= 32'b0;
        end else if (redirect) begin
            pc                <= redirect_pc;
            req_pending       <= 1'b0;
            req_pc            <= 32'b0;
            req_pred_valid    <= 1'b0;
            req_pred_next_pc  <= 32'b0;
            if2id_valid       <= 1'b0;
            if2id_pc          <= 32'b0;
            if2id_instr       <= 32'b0;
            if2id_pred_valid  <= 1'b0;
            if2id_pred_next_pc<= 32'b0;
        end else if (halted) begin
            // freeze everything
            pc                <= pc;
            req_pending       <= req_pending;
            req_pc            <= req_pc;
            req_pred_valid    <= req_pred_valid;
            req_pred_next_pc  <= req_pred_next_pc;
            inflight_epoch    <= inflight_epoch;
            if2id_valid       <= if2id_valid;
            if2id_pc          <= if2id_pc;
            if2id_instr       <= if2id_instr;
            if2id_pred_valid  <= if2id_pred_valid;
            if2id_pred_next_pc<= if2id_pred_next_pc;
        end else begin
            // Response handling (unconditional capture of one-cycle resp_valid)
            if (cpu_resp_valid && req_pending) begin
                if (inflight_epoch != flush_epoch) begin
                    // stale response: drop, refetch
                    if2id_valid <= 1'b0;
                    req_pending <= 1'b1;
                end else begin
                    if2id_valid        <= 1'b1;
                    if2id_pc           <= req_pc;
                    if2id_instr        <= cpu_resp_data;
                    if2id_pred_valid   <= req_pred_valid;
                    if2id_pred_next_pc <= req_pred_next_pc;
                    req_pending        <= 1'b0;
                    if (req_pred_valid) begin
                        pc <= req_pred_next_pc;
                    end else begin
                        pc <= req_pc + 32'd4;
                    end
                end
            end else if (fe_advance) begin
                // Consumed by downstream; clear IF/ID
                if2id_valid <= 1'b0;
            end

            // Issue new request
            if (can_issue_req) begin
                req_pending      <= 1'b1;
                req_pc           <= pc;
                req_pred_valid   <= bp_pred_valid;
                req_pred_next_pc <= bp_pred_next_pc;
                inflight_epoch   <= flush_epoch;
            end
        end
    end

endmodule
