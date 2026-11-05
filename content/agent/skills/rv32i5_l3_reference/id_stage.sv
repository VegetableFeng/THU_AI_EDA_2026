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
