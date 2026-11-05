// file: rtl/if_stage.sv
module if_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        stall,
    input  logic        flush,
    input  logic        redirect,
    input  logic [31:0] redirect_pc,
    input  logic [31:0] imem_rdata,
    output logic [31:0] imem_addr,
    output logic        ifid_valid,
    output logic [31:0] ifid_pc,
    output logic [31:0] ifid_pc_plus4,
    output logic [31:0] ifid_instr
);

    logic [31:0] pc;

    assign imem_addr = pc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc            <= 32'h0000_0000;
            ifid_valid    <= 1'b0;
            ifid_pc       <= 32'h0000_0000;
            ifid_pc_plus4 <= 32'h0000_0000;
            ifid_instr    <= 32'h0000_0000;
        end else if (redirect) begin
            pc            <= redirect_pc;
            ifid_valid    <= 1'b0;
            ifid_pc       <= 32'h0000_0000;
            ifid_pc_plus4 <= 32'h0000_0000;
            ifid_instr    <= 32'h0000_0000;
        end else if (stall) begin
            pc            <= pc;
            ifid_valid    <= ifid_valid;
            ifid_pc       <= ifid_pc;
            ifid_pc_plus4 <= ifid_pc_plus4;
            ifid_instr    <= ifid_instr;
        end else begin
            pc            <= pc + 32'd4;
            ifid_valid    <= !flush;
            ifid_pc       <= pc;
            ifid_pc_plus4 <= pc + 32'd4;
            ifid_instr    <= imem_rdata;
        end
    end

endmodule


// file: rtl/id_stage.sv
module id_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic        redirect,
    input  logic        ifid_valid,
    input  logic [31:0] ifid_pc,
    input  logic [31:0] ifid_pc_plus4,
    input  logic [31:0] ifid_instr,
    input  logic        wb_we,
    input  logic [4:0]  wb_rd,
    input  logic [31:0] wb_data,
    input  logic [4:0]  dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    output logic [31:0] reg_x10,
    output logic        ecall_pending,
    output logic        idex_valid,
    output logic [31:0] idex_pc,
    output logic [31:0] idex_pc_plus4,
    output logic [4:0]  idex_rs1,
    output logic [4:0]  idex_rs2,
    output logic [4:0]  idex_rd,
    output logic [31:0] idex_rs1_data,
    output logic [31:0] idex_rs2_data,
    output logic [31:0] idex_imm,
    output logic [2:0]  idex_funct3,
    output logic        idex_reg_write,
    output logic        idex_mem_read,
    output logic        idex_mem_write,
    output logic        idex_src_a_pc,
    output logic        idex_src_b_imm,
    output logic [3:0]  idex_alu_op,
    output logic [1:0]  idex_wb_sel,
    output logic        idex_branch,
    output logic [1:0]  idex_jump,
    output logic        idex_ecall
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
    localparam logic [3:0] ALU_PASSB= 4'd10;

    localparam logic [1:0] WB_ALU  = 2'd0;
    localparam logic [1:0] WB_LOAD = 2'd1;
    localparam logic [1:0] WB_PC4  = 2'd2;

    logic [31:0] regs [1:31];

    logic [4:0]  rs1_idx;
    logic [4:0]  rs2_idx;
    logic [4:0]  rd_idx;
    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [6:0]  funct7;

    logic [31:0] rs1_val;
    logic [31:0] rs2_val;

    logic [31:0] imm_i;
    logic [31:0] imm_s;
    logic [31:0] imm_b;
    logic [31:0] imm_u;
    logic [31:0] imm_j;
    logic [31:0] imm_out;

    logic        dec_reg_write;
    logic        dec_mem_read;
    logic        dec_mem_write;
    logic        dec_src_a_pc;
    logic        dec_src_b_imm;
    logic [3:0]  dec_alu_op;
    logic [1:0]  dec_wb_sel;
    logic        dec_branch;
    logic [1:0]  dec_jump;
    logic        dec_ecall;

    logic        ecall_hit;
    logic        ecall_pending_r;

    assign rs1_idx = ifid_instr[19:15];
    assign rs2_idx = ifid_instr[24:20];
    assign rd_idx  = ifid_instr[11:7];
    assign opcode  = ifid_instr[6:0];
    assign funct3  = ifid_instr[14:12];
    assign funct7  = ifid_instr[31:25];

    assign imm_i = {{20{ifid_instr[31]}}, ifid_instr[31:20]};
    assign imm_s = {{20{ifid_instr[31]}}, ifid_instr[31:25], ifid_instr[11:7]};
    assign imm_b = {{19{ifid_instr[31]}}, ifid_instr[31], ifid_instr[7],
                    ifid_instr[30:25], ifid_instr[11:8], 1'b0};
    assign imm_u = {ifid_instr[31:12], 12'b0};
    assign imm_j = {{11{ifid_instr[31]}}, ifid_instr[31], ifid_instr[19:12],
                    ifid_instr[20], ifid_instr[30:21], 1'b0};

    always_comb begin
        rs1_val = 32'b0;
        if (rs1_idx != 5'd0) begin
            if (wb_we && (wb_rd == rs1_idx) && (wb_rd != 5'd0))
                rs1_val = wb_data;
            else
                rs1_val = regs[rs1_idx];
        end
    end

    always_comb begin
        rs2_val = 32'b0;
        if (rs2_idx != 5'd0) begin
            if (wb_we && (wb_rd == rs2_idx) && (wb_rd != 5'd0))
                rs2_val = wb_data;
            else
                rs2_val = regs[rs2_idx];
        end
    end

    always_comb begin
        dec_reg_write = 1'b0;
        dec_mem_read  = 1'b0;
        dec_mem_write = 1'b0;
        dec_src_a_pc  = 1'b0;
        dec_src_b_imm = 1'b0;
        dec_alu_op    = ALU_ADD;
        dec_wb_sel    = WB_ALU;
        dec_branch    = 1'b0;
        dec_jump      = 2'd0;
        dec_ecall     = 1'b0;
        imm_out       = 32'b0;

        case (opcode)
            7'b0110011: begin
                dec_reg_write = 1'b1;
                dec_wb_sel    = WB_ALU;
                case (funct3)
                    3'b000: dec_alu_op = funct7[5] ? ALU_SUB : ALU_ADD;
                    3'b001: dec_alu_op = ALU_SLL;
                    3'b010: dec_alu_op = ALU_SLT;
                    3'b011: dec_alu_op = ALU_SLTU;
                    3'b100: dec_alu_op = ALU_XOR;
                    3'b101: dec_alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: dec_alu_op = ALU_OR;
                    3'b111: dec_alu_op = ALU_AND;
                    default: dec_alu_op = ALU_ADD;
                endcase
            end
            7'b0010011: begin
                dec_reg_write = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_wb_sel    = WB_ALU;
                imm_out       = imm_i;
                case (funct3)
                    3'b000: dec_alu_op = ALU_ADD;
                    3'b001: dec_alu_op = ALU_SLL;
                    3'b010: dec_alu_op = ALU_SLT;
                    3'b011: dec_alu_op = ALU_SLTU;
                    3'b100: dec_alu_op = ALU_XOR;
                    3'b101: dec_alu_op = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: dec_alu_op = ALU_OR;
                    3'b111: dec_alu_op = ALU_AND;
                    default: dec_alu_op = ALU_ADD;
                endcase
            end
            7'b0000011: begin
                dec_reg_write = 1'b1;
                dec_mem_read  = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_ADD;
                dec_wb_sel    = WB_LOAD;
                imm_out       = imm_i;
            end
            7'b0100011: begin
                dec_mem_write = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_ADD;
                imm_out       = imm_s;
            end
            7'b1100011: begin
                dec_branch    = 1'b1;
                dec_src_a_pc  = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_ADD;
                imm_out       = imm_b;
            end
            7'b1101111: begin
                dec_reg_write = 1'b1;
                dec_src_a_pc  = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_ADD;
                dec_wb_sel    = WB_PC4;
                dec_jump      = 2'd1;
                imm_out       = imm_j;
            end
            7'b1100111: begin
                dec_reg_write = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_ADD;
                dec_wb_sel    = WB_PC4;
                dec_jump      = 2'd2;
                imm_out       = imm_i;
            end
            7'b0110111: begin
                dec_reg_write = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_PASSB;
                dec_wb_sel    = WB_ALU;
                imm_out       = imm_u;
            end
            7'b0010111: begin
                dec_reg_write = 1'b1;
                dec_src_a_pc  = 1'b1;
                dec_src_b_imm = 1'b1;
                dec_alu_op    = ALU_ADD;
                dec_wb_sel    = WB_ALU;
                imm_out       = imm_u;
            end
            7'b1110011: begin
                if (ifid_instr == 32'h0000_0073)
                    dec_ecall = 1'b1;
            end
            default: begin
            end
        endcase
    end

    assign ecall_hit = ifid_valid && dec_ecall && !redirect;
    assign ecall_pending = ecall_pending_r | ecall_hit;

    always_ff @(posedge clk) begin
        if (!rst_n)
            ecall_pending_r <= 1'b0;
        else if (ecall_hit)
            ecall_pending_r <= 1'b1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int i = 1; i < 32; i++)
                regs[i] <= 32'b0;
        end else if (wb_we && (wb_rd != 5'd0)) begin
            regs[wb_rd] <= wb_data;
        end
    end

    assign reg_x10 = regs[10];

    always_comb begin
        if (dbg_reg_addr == 5'd0)
            dbg_reg_data = 32'b0;
        else
            dbg_reg_data = regs[dbg_reg_addr];
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            idex_valid     <= 1'b0;
            idex_pc        <= 32'b0;
            idex_pc_plus4  <= 32'b0;
            idex_rs1       <= 5'd0;
            idex_rs2       <= 5'd0;
            idex_rd        <= 5'd0;
            idex_rs1_data  <= 32'b0;
            idex_rs2_data  <= 32'b0;
            idex_imm       <= 32'b0;
            idex_funct3    <= 3'd0;
            idex_reg_write <= 1'b0;
            idex_mem_read  <= 1'b0;
            idex_mem_write <= 1'b0;
            idex_src_a_pc  <= 1'b0;
            idex_src_b_imm <= 1'b0;
            idex_alu_op    <= ALU_ADD;
            idex_wb_sel    <= WB_ALU;
            idex_branch    <= 1'b0;
            idex_jump      <= 2'd0;
            idex_ecall     <= 1'b0;
        end else if (flush) begin
            idex_valid     <= 1'b0;
        end else begin
            idex_valid     <= ifid_valid;
            idex_pc        <= ifid_pc;
            idex_pc_plus4  <= ifid_pc_plus4;
            idex_rs1       <= rs1_idx;
            idex_rs2       <= rs2_idx;
            idex_rd        <= rd_idx;
            idex_rs1_data  <= rs1_val;
            idex_rs2_data  <= rs2_val;
            idex_imm       <= imm_out;
            idex_funct3    <= funct3;
            idex_reg_write <= dec_reg_write;
            idex_mem_read  <= dec_mem_read;
            idex_mem_write <= dec_mem_write;
            idex_src_a_pc  <= dec_src_a_pc;
            idex_src_b_imm <= dec_src_b_imm;
            idex_alu_op    <= dec_alu_op;
            idex_wb_sel    <= dec_wb_sel;
            idex_branch    <= dec_branch;
            idex_jump      <= dec_jump;
            idex_ecall     <= dec_ecall;
        end
    end

endmodule


// file: rtl/ex_stage.sv
module ex_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        idex_valid,
    input  logic [31:0] idex_pc,
    input  logic [31:0] idex_pc_plus4,
    input  logic [4:0]  idex_rs1,
    input  logic [4:0]  idex_rs2,
    input  logic [4:0]  idex_rd,
    input  logic [31:0] idex_rs1_data,
    input  logic [31:0] idex_rs2_data,
    input  logic [31:0] idex_imm,
    input  logic [2:0]  idex_funct3,
    input  logic        idex_reg_write,
    input  logic        idex_mem_read,
    input  logic        idex_mem_write,
    input  logic        idex_src_a_pc,
    input  logic        idex_src_b_imm,
    input  logic [3:0]  idex_alu_op,
    input  logic [1:0]  idex_wb_sel,
    input  logic        idex_branch,
    input  logic [1:0]  idex_jump,
    input  logic        idex_ecall,
    input  logic [1:0]  fwd_a_sel,
    input  logic [1:0]  fwd_b_sel,
    input  logic [31:0] wb_data,
    output logic        redirect,
    output logic [31:0] redirect_pc,
    output logic        exmem_valid,
    output logic [31:0] exmem_pc_plus4,
    output logic [31:0] exmem_alu_result,
    output logic [31:0] exmem_store_data,
    output logic [4:0]  exmem_rs2,
    output logic [4:0]  exmem_rd,
    output logic [2:0]  exmem_funct3,
    output logic        exmem_reg_write,
    output logic        exmem_mem_read,
    output logic        exmem_mem_write,
    output logic [1:0]  exmem_wb_sel,
    output logic        exmem_ecall
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
    localparam logic [3:0] ALU_PASSB= 4'd10;

    logic [31:0] rs1_fwd;
    logic [31:0] rs2_fwd;
    logic [31:0] alu_a;
    logic [31:0] alu_b;
    logic [31:0] alu_result;
    logic [31:0] branch_target;
    logic [31:0] jump_target;
    logic        branch_taken;
    logic        jump_taken;
    logic        do_redirect;
    logic [31:0] do_redirect_pc;
    logic [31:0] link_value;
    logic [31:0] result_to_mem;

    always_comb begin
        rs1_fwd = idex_rs1_data;
        if (fwd_a_sel == 2'b10) begin
            rs1_fwd = exmem_alu_result;
        end else if (fwd_a_sel == 2'b01) begin
            rs1_fwd = wb_data;
        end
    end

    always_comb begin
        rs2_fwd = idex_rs2_data;
        if (fwd_b_sel == 2'b10) begin
            rs2_fwd = exmem_alu_result;
        end else if (fwd_b_sel == 2'b01) begin
            rs2_fwd = wb_data;
        end
    end

    always_comb begin
        alu_a = idex_src_a_pc ? idex_pc : rs1_fwd;
        alu_b = idex_src_b_imm ? idex_imm : rs2_fwd;
    end

    always_comb begin
        alu_result = 32'b0;
        case (idex_alu_op)
            ALU_ADD:   alu_result = alu_a + alu_b;
            ALU_SUB:   alu_result = alu_a - alu_b;
            ALU_SLL:   alu_result = alu_a << alu_b[4:0];
            ALU_SLT:   alu_result = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            ALU_SLTU:  alu_result = (alu_a < alu_b) ? 32'd1 : 32'd0;
            ALU_XOR:   alu_result = alu_a ^ alu_b;
            ALU_SRL:   alu_result = alu_a >> alu_b[4:0];
            ALU_SRA:   alu_result = $signed(alu_a) >>> alu_b[4:0];
            ALU_OR:    alu_result = alu_a | alu_b;
            ALU_AND:   alu_result = alu_a & alu_b;
            ALU_PASSB: alu_result = alu_b;
            default:   alu_result = 32'b0;
        endcase
    end

    always_comb begin
        branch_taken = 1'b0;
        if (idex_branch) begin
            case (idex_funct3)
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
        branch_target = idex_pc + idex_imm;
        jump_target = (idex_jump == 2'b10) ? {alu_result[31:1], 1'b0} : alu_result;
        jump_taken = (idex_jump != 2'b00);
        link_value = idex_pc_plus4;

        do_redirect = 1'b0;
        do_redirect_pc = 32'b0;
        if (idex_valid) begin
            if (idex_jump != 2'b00) begin
                do_redirect = 1'b1;
                do_redirect_pc = jump_target;
            end else if (branch_taken) begin
                do_redirect = 1'b1;
                do_redirect_pc = branch_target;
            end
        end
    end

    always_comb begin
        if (idex_jump != 2'b00) begin
            result_to_mem = link_value;
        end else begin
            result_to_mem = alu_result;
        end
    end

    assign redirect = do_redirect;
    assign redirect_pc = do_redirect_pc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            exmem_valid      <= 1'b0;
            exmem_pc_plus4   <= 32'b0;
            exmem_alu_result <= 32'b0;
            exmem_store_data <= 32'b0;
            exmem_rs2        <= 5'b0;
            exmem_rd         <= 5'b0;
            exmem_funct3     <= 3'b0;
            exmem_reg_write  <= 1'b0;
            exmem_mem_read   <= 1'b0;
            exmem_mem_write  <= 1'b0;
            exmem_wb_sel     <= 2'b0;
            exmem_ecall      <= 1'b0;
        end else begin
            exmem_valid      <= idex_valid;
            exmem_pc_plus4   <= idex_pc_plus4;
            exmem_alu_result <= result_to_mem;
            exmem_store_data <= rs2_fwd;
            exmem_rs2        <= idex_rs2;
            exmem_rd         <= idex_rd;
            exmem_funct3     <= idex_funct3;
            exmem_reg_write  <= idex_reg_write;
            exmem_mem_read   <= idex_mem_read;
            exmem_mem_write  <= idex_mem_write;
            exmem_wb_sel     <= idex_wb_sel;
            exmem_ecall      <= idex_ecall;
        end
    end

endmodule


// file: rtl/mem_stage.sv
module mem_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        exmem_valid,
    input  logic [31:0] exmem_pc_plus4,
    input  logic [31:0] exmem_alu_result,
    input  logic [31:0] exmem_store_data,
    input  logic [4:0]  exmem_rs2,
    input  logic [4:0]  exmem_rd,
    input  logic [2:0]  exmem_funct3,
    input  logic        exmem_reg_write,
    input  logic        exmem_mem_read,
    input  logic        exmem_mem_write,
    input  logic [1:0]  exmem_wb_sel,
    input  logic        exmem_ecall,
    input  logic [31:0] wb_data,
    input  logic        halted,
    input  logic [31:0] dmem_rdata,
    output logic        dmem_valid,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,
    output logic        memwb_valid,
    output logic [31:0] memwb_pc_plus4,
    output logic [31:0] memwb_alu_result,
    output logic [31:0] memwb_load_data,
    output logic [4:0]  memwb_rd,
    output logic        memwb_reg_write,
    output logic [1:0]  memwb_wb_sel,
    output logic        memwb_ecall
);

    logic [31:0] store_data_fwd;
    logic [31:0] load_data_ext;
    logic [7:0]  load_byte;
    logic [15:0] load_half;

    // MEM-stage store-data forwarding from MEM/WB
    always_comb begin
        if (memwb_valid && memwb_reg_write && (memwb_rd != 5'd0) &&
            (memwb_rd == exmem_rs2))
            store_data_fwd = wb_data;
        else
            store_data_fwd = exmem_store_data;
    end

    // dmem interface
    always_comb begin
        dmem_valid = exmem_valid && (exmem_mem_read || exmem_mem_write) &&
                     rst_n && !halted;
        dmem_we    = exmem_mem_write;
        dmem_addr  = exmem_alu_result;
        dmem_wdata = store_data_fwd;
        dmem_be    = 4'b0000;
        if (exmem_mem_write) begin
            case (exmem_funct3)
                3'b000: begin // SB
                    dmem_wdata = {4{store_data_fwd[7:0]}};
                    dmem_be    = 4'b0001 << exmem_alu_result[1:0];
                end
                3'b001: begin // SH
                    dmem_wdata = {2{store_data_fwd[15:0]}};
                    dmem_be    = exmem_alu_result[1] ? 4'b1100 : 4'b0011;
                end
                default: begin // SW
                    dmem_wdata = store_data_fwd;
                    dmem_be    = 4'b1111;
                end
            endcase
        end
    end

    // Load data selection and extension
    always_comb begin
        load_byte = dmem_rdata[{exmem_alu_result[1:0], 3'b000} +: 8];
        load_half = exmem_alu_result[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
        case (exmem_funct3)
            3'b000:  load_data_ext = {{24{load_byte[7]}}, load_byte};   // LB
            3'b001:  load_data_ext = {{16{load_half[15]}}, load_half}; // LH
            3'b100:  load_data_ext = {24'b0, load_byte};               // LBU
            3'b101:  load_data_ext = {16'b0, load_half};               // LHU
            default: load_data_ext = dmem_rdata;                       // LW
        endcase
    end

    // MEM/WB pipeline register
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            memwb_valid      <= 1'b0;
            memwb_pc_plus4   <= 32'b0;
            memwb_alu_result <= 32'b0;
            memwb_load_data  <= 32'b0;
            memwb_rd         <= 5'b0;
            memwb_reg_write  <= 1'b0;
            memwb_wb_sel     <= 2'b0;
            memwb_ecall      <= 1'b0;
        end else begin
            memwb_valid      <= exmem_valid;
            memwb_pc_plus4   <= exmem_pc_plus4;
            memwb_alu_result <= exmem_alu_result;
            memwb_load_data  <= load_data_ext;
            memwb_rd         <= exmem_rd;
            memwb_reg_write  <= exmem_reg_write;
            memwb_wb_sel     <= exmem_wb_sel;
            memwb_ecall      <= exmem_ecall;
        end
    end

endmodule


// file: rtl/wb_stage.sv
module wb_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        memwb_valid,
    input  logic [31:0] memwb_pc_plus4,
    input  logic [31:0] memwb_alu_result,
    input  logic [31:0] memwb_load_data,
    input  logic [4:0]  memwb_rd,
    input  logic        memwb_reg_write,
    input  logic [1:0]  memwb_wb_sel,
    input  logic        memwb_ecall,
    input  logic [31:0] reg_x10,
    output logic        wb_we,
    output logic [4:0]  wb_rd,
    output logic [31:0] wb_data,
    output logic        halted,
    output logic [31:0] exit_code
);

    logic [31:0] wb_data_sel;

    always_comb begin
        wb_data_sel = memwb_alu_result;
        case (memwb_wb_sel)
            2'b00:   wb_data_sel = memwb_alu_result;
            2'b01:   wb_data_sel = memwb_load_data;
            2'b10:   wb_data_sel = memwb_pc_plus4;
            default: wb_data_sel = memwb_alu_result;
        endcase
    end

    assign wb_we   = memwb_valid & memwb_reg_write & (memwb_rd != 5'd0) & ~halted;
    assign wb_rd   = memwb_rd;
    assign wb_data = wb_data_sel;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            halted    <= 1'b0;
            exit_code <= 32'd0;
        end else if (!halted) begin
            if (memwb_valid && memwb_ecall) begin
                halted    <= 1'b1;
                exit_code <= reg_x10;
            end
        end
    end

endmodule


// file: rtl/hazard_unit.sv
module hazard_unit (
    input  logic        idex_valid,
    input  logic        idex_mem_read,
    input  logic [4:0]  idex_rd,
    input  logic        ifid_valid,
    input  logic [31:0] ifid_instr,
    input  logic        redirect,
    input  logic        ecall_pending,
    input  logic        halted,
    output logic        load_use_stall,
    output logic        pc_stall,
    output logic        if_flush,
    output logic        id_flush
);

    logic [6:0] opcode;
    logic [4:0] rs1;
    logic [4:0] rs2;
    logic       uses_rs1;
    logic       uses_rs2;
    logic       load_use_hit;

    always_comb begin
        opcode = ifid_instr[6:0];
        rs1    = ifid_instr[19:15];
        rs2    = ifid_instr[24:20];

        uses_rs1 = 1'b0;
        uses_rs2 = 1'b0;

        case (opcode)
            7'b0110011: begin // R-type
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
            end
            7'b0010011: begin // I-type ALU
                uses_rs1 = 1'b1;
            end
            7'b0000011: begin // Load
                uses_rs1 = 1'b1;
            end
            7'b0100011: begin // Store
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
            end
            7'b1100011: begin // Branch
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
            end
            7'b1100111: begin // JALR
                uses_rs1 = 1'b1;
            end
            7'b1101111: begin // JAL
                uses_rs1 = 1'b0;
                uses_rs2 = 1'b0;
            end
            7'b0110111: begin // LUI
                uses_rs1 = 1'b0;
                uses_rs2 = 1'b0;
            end
            7'b0010111: begin // AUIPC
                uses_rs1 = 1'b0;
                uses_rs2 = 1'b0;
            end
            default: begin
                uses_rs1 = 1'b0;
                uses_rs2 = 1'b0;
            end
        endcase

        load_use_hit = idex_valid & idex_mem_read & (idex_rd != 5'd0) &
                       ifid_valid & !redirect &
                       (((idex_rd == rs1) & uses_rs1) |
                        ((idex_rd == rs2) & uses_rs2));

        load_use_stall = load_use_hit;
        pc_stall       = load_use_stall | ecall_pending | halted;
        if_flush       = redirect | ecall_pending | halted;
        id_flush       = redirect | load_use_stall;
    end

endmodule


// file: rtl/forwarding_unit.sv
module forwarding_unit (
    input  logic       idex_valid,
    input  logic [4:0] idex_rs1,
    input  logic [4:0] idex_rs2,
    input  logic       exmem_valid,
    input  logic       exmem_reg_write,
    input  logic [4:0] exmem_rd,
    input  logic       exmem_mem_read,
    input  logic       memwb_valid,
    input  logic       memwb_reg_write,
    input  logic [4:0] memwb_rd,
    output logic [1:0] fwd_a_sel,
    output logic [1:0] fwd_b_sel
);

    logic exmem_hit_a;
    logic exmem_hit_b;
    logic memwb_hit_a;
    logic memwb_hit_b;

    always_comb begin
        exmem_hit_a = exmem_valid && exmem_reg_write && !exmem_mem_read &&
                      (exmem_rd != 5'd0) && (exmem_rd == idex_rs1);
        exmem_hit_b = exmem_valid && exmem_reg_write && !exmem_mem_read &&
                      (exmem_rd != 5'd0) && (exmem_rd == idex_rs2);
        memwb_hit_a = memwb_valid && memwb_reg_write &&
                      (memwb_rd != 5'd0) && (memwb_rd == idex_rs1);
        memwb_hit_b = memwb_valid && memwb_reg_write &&
                      (memwb_rd != 5'd0) && (memwb_rd == idex_rs2);

        if (!idex_valid) begin
            fwd_a_sel = 2'b00;
            fwd_b_sel = 2'b00;
        end else begin
            if (exmem_hit_a)
                fwd_a_sel = 2'b10;
            else if (memwb_hit_a)
                fwd_a_sel = 2'b01;
            else
                fwd_a_sel = 2'b00;

            if (exmem_hit_b)
                fwd_b_sel = 2'b10;
            else if (memwb_hit_b)
                fwd_b_sel = 2'b01;
            else
                fwd_b_sel = 2'b00;
        end
    end

endmodule


// file: rtl/rv32i5.sv
module rv32i5 (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        dmem_valid,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,
    input  logic [31:0] dmem_rdata,
    input  logic [4:0]  dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    output logic        halted,
    output logic [31:0] exit_code
);

    // IF/ID pipeline register signals
    logic        ifid_valid;
    logic [31:0] ifid_pc;
    logic [31:0] ifid_pc_plus4;
    logic [31:0] ifid_instr;

    // ID/EX pipeline register signals
    logic        idex_valid;
    logic [31:0] idex_pc;
    logic [31:0] idex_pc_plus4;
    logic [4:0]  idex_rs1;
    logic [4:0]  idex_rs2;
    logic [4:0]  idex_rd;
    logic [31:0] idex_rs1_data;
    logic [31:0] idex_rs2_data;
    logic [31:0] idex_imm;
    logic [2:0]  idex_funct3;
    logic        idex_reg_write;
    logic        idex_mem_read;
    logic        idex_mem_write;
    logic        idex_src_a_pc;
    logic        idex_src_b_imm;
    logic [3:0]  idex_alu_op;
    logic [1:0]  idex_wb_sel;
    logic        idex_branch;
    logic [1:0]  idex_jump;
    logic        idex_ecall;

    // EX/MEM pipeline register signals
    logic        exmem_valid;
    logic [31:0] exmem_pc_plus4;
    logic [31:0] exmem_alu_result;
    logic [31:0] exmem_store_data;
    logic [4:0]  exmem_rs2;
    logic [4:0]  exmem_rd;
    logic [2:0]  exmem_funct3;
    logic        exmem_reg_write;
    logic        exmem_mem_read;
    logic        exmem_mem_write;
    logic [1:0]  exmem_wb_sel;
    logic        exmem_ecall;

    // MEM/WB pipeline register signals
    logic        memwb_valid;
    logic [31:0] memwb_pc_plus4;
    logic [31:0] memwb_alu_result;
    logic [31:0] memwb_load_data;
    logic [4:0]  memwb_rd;
    logic        memwb_reg_write;
    logic [1:0]  memwb_wb_sel;
    logic        memwb_ecall;

    // WB signals
    logic        wb_we;
    logic [4:0]  wb_rd;
    logic [31:0] wb_data;

    // Hazard / forwarding signals
    logic        redirect;
    logic [31:0] redirect_pc;
    logic        load_use_stall;
    logic        pc_stall;
    logic        if_flush;
    logic        id_flush;
    logic [1:0]  fwd_a_sel;
    logic [1:0]  fwd_b_sel;

    // ECALL / debug
    logic        ecall_pending;
    logic [31:0] reg_x10;

    if_stage u_if_stage (
        .clk           (clk),
        .rst_n         (rst_n),
        .stall         (pc_stall),
        .flush         (if_flush),
        .redirect      (redirect),
        .redirect_pc   (redirect_pc),
        .imem_rdata    (imem_rdata),
        .imem_addr     (imem_addr),
        .ifid_valid    (ifid_valid),
        .ifid_pc       (ifid_pc),
        .ifid_pc_plus4 (ifid_pc_plus4),
        .ifid_instr    (ifid_instr)
    );

    id_stage u_id_stage (
        .clk           (clk),
        .rst_n         (rst_n),
        .flush         (id_flush),
        .redirect      (redirect),
        .ifid_valid    (ifid_valid),
        .ifid_pc       (ifid_pc),
        .ifid_pc_plus4 (ifid_pc_plus4),
        .ifid_instr    (ifid_instr),
        .wb_we         (wb_we),
        .wb_rd         (wb_rd),
        .wb_data       (wb_data),
        .dbg_reg_addr  (dbg_reg_addr),
        .dbg_reg_data  (dbg_reg_data),
        .reg_x10       (reg_x10),
        .ecall_pending (ecall_pending),
        .idex_valid    (idex_valid),
        .idex_pc       (idex_pc),
        .idex_pc_plus4 (idex_pc_plus4),
        .idex_rs1      (idex_rs1),
        .idex_rs2      (idex_rs2),
        .idex_rd       (idex_rd),
        .idex_rs1_data (idex_rs1_data),
        .idex_rs2_data (idex_rs2_data),
        .idex_imm      (idex_imm),
        .idex_funct3   (idex_funct3),
        .idex_reg_write(idex_reg_write),
        .idex_mem_read (idex_mem_read),
        .idex_mem_write(idex_mem_write),
        .idex_src_a_pc (idex_src_a_pc),
        .idex_src_b_imm(idex_src_b_imm),
        .idex_alu_op   (idex_alu_op),
        .idex_wb_sel   (idex_wb_sel),
        .idex_branch   (idex_branch),
        .idex_jump     (idex_jump),
        .idex_ecall    (idex_ecall)
    );

    ex_stage u_ex_stage (
        .clk            (clk),
        .rst_n          (rst_n),
        .idex_valid     (idex_valid),
        .idex_pc        (idex_pc),
        .idex_pc_plus4  (idex_pc_plus4),
        .idex_rs1       (idex_rs1),
        .idex_rs2       (idex_rs2),
        .idex_rd        (idex_rd),
        .idex_rs1_data  (idex_rs1_data),
        .idex_rs2_data  (idex_rs2_data),
        .idex_imm       (idex_imm),
        .idex_funct3    (idex_funct3),
        .idex_reg_write (idex_reg_write),
        .idex_mem_read  (idex_mem_read),
        .idex_mem_write (idex_mem_write),
        .idex_src_a_pc  (idex_src_a_pc),
        .idex_src_b_imm (idex_src_b_imm),
        .idex_alu_op    (idex_alu_op),
        .idex_wb_sel    (idex_wb_sel),
        .idex_branch    (idex_branch),
        .idex_jump      (idex_jump),
        .idex_ecall     (idex_ecall),
        .fwd_a_sel      (fwd_a_sel),
        .fwd_b_sel      (fwd_b_sel),
        .wb_data        (wb_data),
        .redirect       (redirect),
        .redirect_pc    (redirect_pc),
        .exmem_valid    (exmem_valid),
        .exmem_pc_plus4 (exmem_pc_plus4),
        .exmem_alu_result(exmem_alu_result),
        .exmem_store_data(exmem_store_data),
        .exmem_rs2      (exmem_rs2),
        .exmem_rd       (exmem_rd),
        .exmem_funct3   (exmem_funct3),
        .exmem_reg_write(exmem_reg_write),
        .exmem_mem_read (exmem_mem_read),
        .exmem_mem_write(exmem_mem_write),
        .exmem_wb_sel   (exmem_wb_sel),
        .exmem_ecall    (exmem_ecall)
    );

    mem_stage u_mem_stage (
        .clk             (clk),
        .rst_n           (rst_n),
        .exmem_valid     (exmem_valid),
        .exmem_pc_plus4  (exmem_pc_plus4),
        .exmem_alu_result(exmem_alu_result),
        .exmem_store_data(exmem_store_data),
        .exmem_rs2       (exmem_rs2),
        .exmem_rd        (exmem_rd),
        .exmem_funct3    (exmem_funct3),
        .exmem_reg_write (exmem_reg_write),
        .exmem_mem_read  (exmem_mem_read),
        .exmem_mem_write (exmem_mem_write),
        .exmem_wb_sel    (exmem_wb_sel),
        .exmem_ecall     (exmem_ecall),
        .wb_data         (wb_data),
        .halted          (halted),
        .dmem_rdata      (dmem_rdata),
        .dmem_valid      (dmem_valid),
        .dmem_we         (dmem_we),
        .dmem_addr       (dmem_addr),
        .dmem_wdata      (dmem_wdata),
        .dmem_be         (dmem_be),
        .memwb_valid     (memwb_valid),
        .memwb_pc_plus4  (memwb_pc_plus4),
        .memwb_alu_result(memwb_alu_result),
        .memwb_load_data (memwb_load_data),
        .memwb_rd        (memwb_rd),
        .memwb_reg_write (memwb_reg_write),
        .memwb_wb_sel    (memwb_wb_sel),
        .memwb_ecall     (memwb_ecall)
    );

    wb_stage u_wb_stage (
        .clk             (clk),
        .rst_n           (rst_n),
        .memwb_valid     (memwb_valid),
        .memwb_pc_plus4  (memwb_pc_plus4),
        .memwb_alu_result(memwb_alu_result),
        .memwb_load_data (memwb_load_data),
        .memwb_rd        (memwb_rd),
        .memwb_reg_write (memwb_reg_write),
        .memwb_wb_sel    (memwb_wb_sel),
        .memwb_ecall     (memwb_ecall),
        .reg_x10         (reg_x10),
        .wb_we           (wb_we),
        .wb_rd           (wb_rd),
        .wb_data         (wb_data),
        .halted          (halted),
        .exit_code       (exit_code)
    );

    hazard_unit u_hazard_unit (
        .idex_valid    (idex_valid),
        .idex_mem_read (idex_mem_read),
        .idex_rd       (idex_rd),
        .ifid_valid    (ifid_valid),
        .ifid_instr    (ifid_instr),
        .redirect      (redirect),
        .ecall_pending (ecall_pending),
        .halted        (halted),
        .load_use_stall(load_use_stall),
        .pc_stall      (pc_stall),
        .if_flush      (if_flush),
        .id_flush      (id_flush)
    );

    forwarding_unit u_forwarding_unit (
        .idex_valid     (idex_valid),
        .idex_rs1       (idex_rs1),
        .idex_rs2       (idex_rs2),
        .exmem_valid    (exmem_valid),
        .exmem_reg_write(exmem_reg_write),
        .exmem_rd       (exmem_rd),
        .exmem_mem_read (exmem_mem_read),
        .memwb_valid    (memwb_valid),
        .memwb_reg_write(memwb_reg_write),
        .memwb_rd       (memwb_rd),
        .fwd_a_sel      (fwd_a_sel),
        .fwd_b_sel      (fwd_b_sel)
    );

endmodule

