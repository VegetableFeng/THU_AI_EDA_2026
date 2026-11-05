module execute_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        older_load_pending,
    input  logic        dmem_wait,
    input  logic        iq_issue_valid,
    input  logic        iq_issue_ready,
    input  logic [2:0]  iq_issue_rob_idx,
    input  logic [31:0] iq_issue_pc,
    input  logic [31:0] iq_issue_instr,
    input  logic [5:0]  iq_issue_prd,
    input  logic        iq_issue_has_dest,
    input  logic [31:0] iq_issue_rs1,
    input  logic [31:0] iq_issue_rs2,
    input  logic [31:0] iq_issue_imm,
    input  logic [3:0]  iq_issue_alu_op,
    input  logic        iq_issue_src_a_pc,
    input  logic        iq_issue_src_b_imm,
    input  logic [1:0]  iq_issue_wb_sel,
    input  logic        iq_issue_is_branch,
    input  logic [1:0]  iq_issue_jump,
    input  logic [2:0]  iq_issue_funct3,
    input  logic [31:0] iq_issue_pred_next_pc,
    input  logic        iq_issue_pred_valid,
    output logic        complete_valid,
    output logic [2:0]  complete_rob_idx,
    output logic [31:0] complete_data,
    output logic        we0,
    output logic [5:0]  waddr0,
    output logic [31:0] wdata0,
    output logic        bp_resolve_valid,
    output logic [31:0] bp_resolve_pc,
    output logic [1:0]  bp_resolve_type,
    output logic        bp_resolve_taken,
    output logic [31:0] bp_resolve_target,
    output logic        resolve_mispredict,
    output logic        redirect,
    output logic [31:0] redirect_pc,
    output logic        squash_valid,
    output logic [2:0]  squash_rob_idx,
    output logic        ooo_bypass
);

    logic        accept;
    logic [31:0] src_a;
    logic [31:0] src_b;
    logic [31:0] alu_result;
    logic [31:0] pc_plus4;
    logic [31:0] link_val;
    logic [31:0] wb_data;
    logic        br_taken;
    logic [31:0] br_target;
    logic [31:0] jump_target;
    logic [31:0] actual_next_pc;
    logic [31:0] predicted_next_pc;
    logic        is_ctrl;
    logic [1:0]  ctrl_type;
    logic        mispredict;

    assign accept = iq_issue_valid && iq_issue_ready && !halted;

    assign src_a = iq_issue_src_a_pc ? iq_issue_pc : iq_issue_rs1;
    assign src_b = iq_issue_src_b_imm ? iq_issue_imm : iq_issue_rs2;

    always_comb begin
        alu_result = 32'b0;
        case (iq_issue_alu_op)
            4'd0: alu_result = src_a + src_b;
            4'd1: alu_result = src_a - src_b;
            4'd2: alu_result = src_a << src_b[4:0];
            4'd3: alu_result = ($signed(src_a) < $signed(src_b)) ? 32'd1 : 32'd0;
            4'd4: alu_result = (src_a < src_b) ? 32'd1 : 32'd0;
            4'd5: alu_result = src_a ^ src_b;
            4'd6: alu_result = src_a >> src_b[4:0];
            4'd7: alu_result = $signed(src_a) >>> src_b[4:0];
            4'd8: alu_result = src_a | src_b;
            4'd9: alu_result = src_a & src_b;
            4'd10: alu_result = src_b;
            4'd11: alu_result = src_a;
            default: alu_result = 32'b0;
        endcase
    end

    assign pc_plus4 = iq_issue_pc + 32'd4;
    assign link_val = pc_plus4;

    always_comb begin
        br_taken = 1'b0;
        case (iq_issue_funct3)
            3'b000: br_taken = (iq_issue_rs1 == iq_issue_rs2);
            3'b001: br_taken = (iq_issue_rs1 != iq_issue_rs2);
            3'b100: br_taken = ($signed(iq_issue_rs1) < $signed(iq_issue_rs2));
            3'b101: br_taken = ($signed(iq_issue_rs1) >= $signed(iq_issue_rs2));
            3'b110: br_taken = (iq_issue_rs1 < iq_issue_rs2);
            3'b111: br_taken = (iq_issue_rs1 >= iq_issue_rs2);
            default: br_taken = 1'b0;
        endcase
    end

    assign br_target = iq_issue_pc + iq_issue_imm;
    assign jump_target = (iq_issue_jump == 2'b10) ?
                         ((iq_issue_rs1 + iq_issue_imm) & 32'hFFFF_FFFE) :
                         br_target;

    always_comb begin
        is_ctrl = 1'b0;
        ctrl_type = 2'b00;
        actual_next_pc = pc_plus4;
        if (iq_issue_is_branch) begin
            is_ctrl = 1'b1;
            ctrl_type = 2'b01;
            actual_next_pc = br_taken ? br_target : pc_plus4;
        end else if (iq_issue_jump == 2'b01) begin
            is_ctrl = 1'b1;
            ctrl_type = 2'b10;
            actual_next_pc = jump_target;
        end else if (iq_issue_jump == 2'b10) begin
            is_ctrl = 1'b1;
            ctrl_type = 2'b11;
            actual_next_pc = jump_target;
        end
    end

    assign predicted_next_pc = iq_issue_pred_valid ? iq_issue_pred_next_pc : pc_plus4;
    assign mispredict = is_ctrl && (actual_next_pc != predicted_next_pc);

    always_comb begin
        wb_data = alu_result;
        case (iq_issue_wb_sel)
            2'b00: wb_data = alu_result;
            2'b01: wb_data = link_val;
            2'b10: wb_data = alu_result;
            default: wb_data = alu_result;
        endcase
    end

    assign complete_valid = accept;
    assign complete_rob_idx = iq_issue_rob_idx;
    assign complete_data = wb_data;

    assign we0 = accept && iq_issue_has_dest && (iq_issue_prd != 6'd0);
    assign waddr0 = iq_issue_prd;
    assign wdata0 = wb_data;

    assign bp_resolve_valid = accept && is_ctrl;
    assign bp_resolve_pc = iq_issue_pc;
    assign bp_resolve_type = ctrl_type;
    assign bp_resolve_taken = (ctrl_type == 2'b01) ? br_taken : 1'b1;
    assign bp_resolve_target = actual_next_pc;

    assign resolve_mispredict = bp_resolve_valid && mispredict;
    assign redirect = resolve_mispredict;
    assign redirect_pc = actual_next_pc;
    assign squash_valid = resolve_mispredict;
    assign squash_rob_idx = iq_issue_rob_idx;

    assign ooo_bypass = accept && older_load_pending && dmem_wait &&
                        !iq_issue_is_branch && (iq_issue_jump == 2'b00);

endmodule
