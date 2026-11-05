module execute_alu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic        halted,
    input  logic        issue_valid,
    output logic        issue_ready,
    input  logic [31:0] issue_pc,
    input  logic [31:0] issue_insn,
    input  logic [3:0]  issue_rob_index,
    input  logic [5:0]  issue_prs1,
    input  logic [5:0]  issue_prs2,
    input  logic [5:0]  issue_pdst,
    input  logic [31:0] issue_operand1,
    input  logic [31:0] issue_operand2,
    input  logic [31:0] issue_imm,
    input  logic [4:0]  issue_alu_op,
    input  logic [2:0]  issue_wb_sel,
    input  logic        issue_is_branch,
    input  logic        issue_is_jal,
    input  logic        issue_is_jalr,
    input  logic        issue_use_imm,
    input  logic        issue_is_auipc,
    input  logic [31:0] issue_pred_next_pc,
    input  logic        issue_pred_taken,
    input  logic [1:0]  issue_pred_type,
    output logic        alu_complete_valid,
    output logic [3:0]  alu_complete_rob_index,
    output logic [5:0]  alu_complete_prd,
    output logic [31:0] alu_complete_data,
    output logic        resolve_valid,
    output logic [3:0]  resolve_rob_index,
    output logic [31:0] resolve_pc,
    output logic [31:0] resolve_actual
);

    localparam logic [4:0] ALU_ADD  = 5'd0;
    localparam logic [4:0] ALU_SUB  = 5'd1;
    localparam logic [4:0] ALU_SLL  = 5'd2;
    localparam logic [4:0] ALU_SLT  = 5'd3;
    localparam logic [4:0] ALU_SLTU = 5'd4;
    localparam logic [4:0] ALU_XOR  = 5'd5;
    localparam logic [4:0] ALU_SRL  = 5'd6;
    localparam logic [4:0] ALU_SRA  = 5'd7;
    localparam logic [4:0] ALU_OR   = 5'd8;
    localparam logic [4:0] ALU_AND  = 5'd9;
    localparam logic [4:0] ALU_PASSB= 5'd10;
    localparam logic [4:0] ALU_BEQ  = 5'd11;
    localparam logic [4:0] ALU_BNE  = 5'd12;
    localparam logic [4:0] ALU_BLT  = 5'd13;
    localparam logic [4:0] ALU_BGE  = 5'd14;
    localparam logic [4:0] ALU_BLTU = 5'd15;
    localparam logic [4:0] ALU_BGEU = 5'd16;
    localparam logic [4:0] ALU_JAL  = 5'd17;
    localparam logic [4:0] ALU_JALR = 5'd18;
    localparam logic [4:0] ALU_LUI  = 5'd19;
    localparam logic [4:0] ALU_AUIPC= 5'd20;

    localparam logic [2:0] WB_ALU  = 3'b000;
    localparam logic [2:0] WB_PC4  = 3'b001;
    localparam logic [2:0] WB_LOAD = 3'b010;
    localparam logic [2:0] WB_IMM  = 3'b011;
    localparam logic [2:0] WB_AUIPC= 3'b100;

    logic [31:0] op_a;
    logic [31:0] op_b;
    logic [31:0] alu_result;
    logic [31:0] pc_plus4;
    logic [31:0] branch_target;
    logic [31:0] jal_target;
    logic [31:0] jalr_target;
    logic [31:0] ctrl_target;
    logic        branch_taken;
    logic        is_control;
    logic        actual_taken;
    logic [31:0] actual_next_pc;
    logic [31:0] wb_data;

    assign op_a = issue_operand1;
    assign op_b = issue_use_imm ? issue_imm : issue_operand2;

    always_comb begin
        alu_result = 32'd0;
        case (issue_alu_op)
            ALU_ADD:   alu_result = op_a + op_b;
            ALU_SUB:   alu_result = op_a - op_b;
            ALU_SLL:   alu_result = op_a << op_b[4:0];
            ALU_SLT:   alu_result = ($signed(op_a) < $signed(op_b)) ? 32'd1 : 32'd0;
            ALU_SLTU:  alu_result = (op_a < op_b) ? 32'd1 : 32'd0;
            ALU_XOR:   alu_result = op_a ^ op_b;
            ALU_SRL:   alu_result = op_a >> op_b[4:0];
            ALU_SRA:   alu_result = $signed(op_a) >>> op_b[4:0];
            ALU_OR:    alu_result = op_a | op_b;
            ALU_AND:   alu_result = op_a & op_b;
            ALU_PASSB: alu_result = op_b;
            ALU_LUI:   alu_result = issue_imm;
            ALU_AUIPC: alu_result = issue_pc + issue_imm;
            default:   alu_result = op_a + op_b;
        endcase
    end

    always_comb begin
        branch_taken = 1'b0;
        case (issue_alu_op)
            ALU_BEQ:  branch_taken = (issue_operand1 == issue_operand2);
            ALU_BNE:  branch_taken = (issue_operand1 != issue_operand2);
            ALU_BLT:  branch_taken = ($signed(issue_operand1) < $signed(issue_operand2));
            ALU_BGE:  branch_taken = ($signed(issue_operand1) >= $signed(issue_operand2));
            ALU_BLTU: branch_taken = (issue_operand1 < issue_operand2);
            ALU_BGEU: branch_taken = (issue_operand1 >= issue_operand2);
            default:  branch_taken = 1'b0;
        endcase
    end

    assign pc_plus4      = issue_pc + 32'd4;
    assign branch_target = issue_pc + issue_imm;
    assign jal_target    = issue_pc + issue_imm;
    assign jalr_target   = (op_a + issue_imm) & 32'hFFFF_FFFE;

    always_comb begin
        ctrl_target = issue_pc + 32'd4;
        if (issue_is_branch) begin
            ctrl_target = branch_target;
        end else if (issue_is_jal) begin
            ctrl_target = jal_target;
        end else if (issue_is_jalr) begin
            ctrl_target = jalr_target;
        end
    end

    assign is_control = issue_is_branch | issue_is_jal | issue_is_jalr;

    always_comb begin
        actual_taken = 1'b0;
        if (issue_is_branch) begin
            actual_taken = branch_taken;
        end else if (issue_is_jal || issue_is_jalr) begin
            actual_taken = 1'b1;
        end
    end

    assign actual_next_pc = actual_taken ? ctrl_target : pc_plus4;

    always_comb begin
        wb_data = alu_result;
        case (issue_wb_sel)
            WB_ALU:   wb_data = alu_result;
            WB_PC4:   wb_data = pc_plus4;
            WB_LOAD:  wb_data = alu_result;
            WB_IMM:   wb_data = issue_imm;
            WB_AUIPC: wb_data = issue_pc + issue_imm;
            default:  wb_data = alu_result;
        endcase
    end

    assign issue_ready = rst_n & ~halted & ~flush;

    assign alu_complete_valid    = issue_valid & issue_ready;
    assign alu_complete_rob_index= issue_rob_index;
    assign alu_complete_prd      = issue_pdst;
    assign alu_complete_data     = wb_data;

    assign resolve_valid     = issue_valid & issue_ready & is_control;
    assign resolve_rob_index = issue_rob_index;
    assign resolve_pc        = issue_pc;
    assign resolve_actual    = actual_next_pc;

endmodule
