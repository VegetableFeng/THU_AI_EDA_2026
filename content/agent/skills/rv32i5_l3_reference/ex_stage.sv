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
