module issue_queue (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        iq_alloc_valid,
    output logic        iq_alloc_ready,
    input  logic [2:0]  iq_alloc_rob_idx,
    input  logic [31:0] iq_alloc_pc,
    input  logic [31:0] iq_alloc_instr,
    input  logic [5:0]  iq_alloc_prd,
    input  logic        iq_alloc_has_dest,
    input  logic [5:0]  iq_alloc_ps1,
    input  logic [5:0]  iq_alloc_ps2,
    input  logic [3:0]  iq_alloc_alu_op,
    input  logic [31:0] iq_alloc_imm,
    input  logic        iq_alloc_src_a_pc,
    input  logic        iq_alloc_src_b_imm,
    input  logic [1:0]  iq_alloc_wb_sel,
    input  logic        iq_alloc_is_branch,
    input  logic [1:0]  iq_alloc_jump,
    input  logic [2:0]  iq_alloc_funct3,
    input  logic [31:0] iq_alloc_pred_next_pc,
    input  logic        iq_alloc_pred_valid,
    output logic        iq_accept,
    input  logic [39:0] prf_ready,
    output logic [5:0]  iq_raddr0,
    output logic [5:0]  iq_raddr1,
    input  logic [31:0] iq_rdata0,
    input  logic [31:0] iq_rdata1,
    output logic        iq_issue_valid,
    input  logic        iq_issue_ready,
    output logic [2:0]  iq_issue_rob_idx,
    output logic [31:0] iq_issue_pc,
    output logic [31:0] iq_issue_instr,
    output logic [5:0]  iq_issue_prd,
    output logic        iq_issue_has_dest,
    output logic [31:0] iq_issue_rs1,
    output logic [31:0] iq_issue_rs2,
    output logic [31:0] iq_issue_imm,
    output logic [3:0]  iq_issue_alu_op,
    output logic        iq_issue_src_a_pc,
    output logic        iq_issue_src_b_imm,
    output logic [1:0]  iq_issue_wb_sel,
    output logic        iq_issue_is_branch,
    output logic [1:0]  iq_issue_jump,
    output logic [2:0]  iq_issue_funct3,
    output logic [31:0] iq_issue_pred_next_pc,
    output logic        iq_issue_pred_valid,
    input  logic        squash_valid,
    input  logic [2:0]  squash_rob_idx,
    input  logic [2:0]  rob_tail_in
);

    localparam int DEPTH = 8;

    logic [DEPTH-1:0] ent_valid;
    logic [2:0]       ent_rob_idx [0:DEPTH-1];
    logic [31:0]      ent_pc [0:DEPTH-1];
    logic [31:0]      ent_instr [0:DEPTH-1];
    logic [5:0]       ent_prd [0:DEPTH-1];
    logic             ent_has_dest [0:DEPTH-1];
    logic [5:0]       ent_ps1 [0:DEPTH-1];
    logic [5:0]       ent_ps2 [0:DEPTH-1];
    logic [3:0]       ent_alu_op [0:DEPTH-1];
    logic [31:0]      ent_imm [0:DEPTH-1];
    logic             ent_src_a_pc [0:DEPTH-1];
    logic             ent_src_b_imm [0:DEPTH-1];
    logic [1:0]       ent_wb_sel [0:DEPTH-1];
    logic             ent_is_branch [0:DEPTH-1];
    logic [1:0]       ent_jump [0:DEPTH-1];
    logic [2:0]       ent_funct3 [0:DEPTH-1];
    logic [31:0]      ent_pred_next_pc [0:DEPTH-1];
    logic             ent_pred_valid [0:DEPTH-1];

    logic [DEPTH-1:0] ent_ready;
    logic [DEPTH-1:0] ent_sel;
    logic [DEPTH-1:0] free_vec;
    logic [2:0]       free_idx;
    logic             has_free;
    logic             issue_fire;
    logic             alloc_fire;

    always_comb begin
        integer i;
        for (i = 0; i < DEPTH; i = i + 1) begin
            ent_ready[i] = ent_valid[i] &&
                           (ent_ps1[i] == 6'd0 || prf_ready[ent_ps1[i]]) &&
                           (ent_ps2[i] == 6'd0 || prf_ready[ent_ps2[i]]);
        end
    end

    always_comb begin
        integer i;
        ent_sel = {DEPTH{1'b0}};
        for (i = DEPTH - 1; i >= 0; i = i - 1) begin
            if (ent_ready[i] && !halted) begin
                ent_sel = {DEPTH{1'b0}};
                ent_sel[i] = 1'b1;
            end
        end
    end

    always_comb begin
        integer i;
        free_vec = {DEPTH{1'b0}};
        for (i = 0; i < DEPTH; i = i + 1) begin
            free_vec[i] = ~ent_valid[i];
        end
    end

    always_comb begin
        integer i;
        free_idx = 3'd0;
        has_free = 1'b0;
        for (i = DEPTH - 1; i >= 0; i = i - 1) begin
            if (free_vec[i]) begin
                free_idx = i[2:0];
                has_free = 1'b1;
            end
        end
    end

    assign iq_alloc_ready = has_free && !halted;
    assign alloc_fire     = iq_alloc_valid && iq_alloc_ready;
    assign iq_accept      = alloc_fire;

    assign issue_fire     = iq_issue_valid && iq_issue_ready;

    always_comb begin
        iq_issue_valid       = |ent_sel;
        iq_issue_rob_idx     = 3'd0;
        iq_issue_pc          = 32'd0;
        iq_issue_instr       = 32'd0;
        iq_issue_prd         = 6'd0;
        iq_issue_has_dest    = 1'b0;
        iq_issue_imm         = 32'd0;
        iq_issue_alu_op      = 4'd0;
        iq_issue_src_a_pc    = 1'b0;
        iq_issue_src_b_imm   = 1'b0;
        iq_issue_wb_sel      = 2'd0;
        iq_issue_is_branch   = 1'b0;
        iq_issue_jump        = 2'd0;
        iq_issue_funct3      = 3'd0;
        iq_issue_pred_next_pc = 32'd0;
        iq_issue_pred_valid  = 1'b0;
        iq_raddr0            = 6'd0;
        iq_raddr1            = 6'd0;
        for (int i = 0; i < DEPTH; i = i + 1) begin
            if (ent_sel[i]) begin
                iq_issue_rob_idx      = ent_rob_idx[i];
                iq_issue_pc           = ent_pc[i];
                iq_issue_instr        = ent_instr[i];
                iq_issue_prd          = ent_prd[i];
                iq_issue_has_dest     = ent_has_dest[i];
                iq_issue_imm          = ent_imm[i];
                iq_issue_alu_op       = ent_alu_op[i];
                iq_issue_src_a_pc     = ent_src_a_pc[i];
                iq_issue_src_b_imm    = ent_src_b_imm[i];
                iq_issue_wb_sel       = ent_wb_sel[i];
                iq_issue_is_branch    = ent_is_branch[i];
                iq_issue_jump         = ent_jump[i];
                iq_issue_funct3       = ent_funct3[i];
                iq_issue_pred_next_pc = ent_pred_next_pc[i];
                iq_issue_pred_valid   = ent_pred_valid[i];
                iq_raddr0             = ent_ps1[i];
                iq_raddr1             = ent_ps2[i];
            end
        end
    end

    assign iq_issue_rs1 = iq_rdata0;
    assign iq_issue_rs2 = iq_rdata1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ent_valid <= {DEPTH{1'b0}};
            for (int i = 0; i < DEPTH; i = i + 1) begin
                ent_rob_idx[i]      <= 3'd0;
                ent_pc[i]           <= 32'd0;
                ent_instr[i]        <= 32'd0;
                ent_prd[i]          <= 6'd0;
                ent_has_dest[i]     <= 1'b0;
                ent_ps1[i]          <= 6'd0;
                ent_ps2[i]          <= 6'd0;
                ent_alu_op[i]       <= 4'd0;
                ent_imm[i]          <= 32'd0;
                ent_src_a_pc[i]     <= 1'b0;
                ent_src_b_imm[i]    <= 1'b0;
                ent_wb_sel[i]       <= 2'd0;
                ent_is_branch[i]    <= 1'b0;
                ent_jump[i]         <= 2'd0;
                ent_funct3[i]       <= 3'd0;
                ent_pred_next_pc[i] <= 32'd0;
                ent_pred_valid[i]   <= 1'b0;
            end
        end else begin
            if (squash_valid) begin
                // 环形区间冲刷（同 ROB，修复 wrap 漏杀）
                for (int i = 0; i < DEPTH; i = i + 1) begin
                    if (ent_valid[i] &&
                        (((ent_rob_idx[i] - squash_rob_idx - 3'd1) & 3'd7) <
                         ((rob_tail_in - squash_rob_idx - 3'd1) & 3'd7))) begin
                        ent_valid[i] <= 1'b0;
                    end
                end
            end
            if (issue_fire) begin
                for (int i = 0; i < DEPTH; i = i + 1) begin
                    if (ent_sel[i]) begin
                        ent_valid[i] <= 1'b0;
                    end
                end
            end
            if (alloc_fire) begin
                ent_valid[free_idx]      <= 1'b1;
                ent_rob_idx[free_idx]    <= iq_alloc_rob_idx;
                ent_pc[free_idx]         <= iq_alloc_pc;
                ent_instr[free_idx]      <= iq_alloc_instr;
                ent_prd[free_idx]        <= iq_alloc_prd;
                ent_has_dest[free_idx]   <= iq_alloc_has_dest;
                ent_ps1[free_idx]        <= iq_alloc_ps1;
                ent_ps2[free_idx]        <= iq_alloc_ps2;
                ent_alu_op[free_idx]     <= iq_alloc_alu_op;
                ent_imm[free_idx]        <= iq_alloc_imm;
                ent_src_a_pc[free_idx]   <= iq_alloc_src_a_pc;
                ent_src_b_imm[free_idx]  <= iq_alloc_src_b_imm;
                ent_wb_sel[free_idx]     <= iq_alloc_wb_sel;
                ent_is_branch[free_idx]  <= iq_alloc_is_branch;
                ent_jump[free_idx]       <= iq_alloc_jump;
                ent_funct3[free_idx]     <= iq_alloc_funct3;
                ent_pred_next_pc[free_idx] <= iq_alloc_pred_next_pc;
                ent_pred_valid[free_idx] <= iq_alloc_pred_valid;
            end
        end
    end

endmodule
