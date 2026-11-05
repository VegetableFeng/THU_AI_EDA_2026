module issue_queue (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [3:0]  flush_rob_index,
    input  logic [3:0]  rob_head_index,
    input  logic        halted,
    input  logic        iq_disp_valid,
    output logic        iq_disp_ready,
    input  logic [31:0] iq_disp_pc,
    input  logic [31:0] iq_disp_insn,
    input  logic [3:0]  iq_disp_rob_index,
    input  logic [5:0]  iq_disp_prs1,
    input  logic [5:0]  iq_disp_prs2,
    input  logic [5:0]  iq_disp_pdst,
    input  logic        iq_disp_rs1_ready,
    input  logic        iq_disp_rs2_ready,
    input  logic [31:0] iq_disp_imm,
    input  logic [4:0]  iq_disp_alu_op,
    input  logic [2:0]  iq_disp_wb_sel,
    input  logic        iq_disp_is_branch,
    input  logic        iq_disp_is_jal,
    input  logic        iq_disp_is_jalr,
    input  logic        iq_disp_use_imm,
    input  logic        iq_disp_is_auipc,
    input  logic [31:0] iq_disp_pred_next_pc,
    input  logic        iq_disp_pred_taken,
    input  logic [1:0]  iq_disp_pred_type,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    input  logic        load_complete_valid,
    input  logic [5:0]  load_complete_prd,
    output logic [5:0]  iq_prf_rs1_addr,
    output logic [5:0]  iq_prf_rs2_addr,
    input  logic [31:0] iq_prf_rdata1,
    input  logic [31:0] iq_prf_rdata2,
    output logic        issue_valid,
    input  logic        issue_ready,
    output logic [31:0] issue_pc,
    output logic [31:0] issue_insn,
    output logic [3:0]  issue_rob_index,
    output logic [5:0]  issue_prs1,
    output logic [5:0]  issue_prs2,
    output logic [5:0]  issue_pdst,
    output logic [31:0] issue_operand1,
    output logic [31:0] issue_operand2,
    output logic [31:0] issue_imm,
    output logic [4:0]  issue_alu_op,
    output logic [2:0]  issue_wb_sel,
    output logic        issue_is_branch,
    output logic        issue_is_jal,
    output logic        issue_is_jalr,
    output logic        issue_use_imm,
    output logic        issue_is_auipc,
    output logic [31:0] issue_pred_next_pc,
    output logic        issue_pred_taken,
    output logic [1:0]  issue_pred_type,
    output logic        dbg_ooo_issue,
    output logic        dbg_ooo_bypass
);

    localparam int IQ_DEPTH = 8;

    logic        ent_valid   [0:IQ_DEPTH-1];
    logic [31:0] ent_pc      [0:IQ_DEPTH-1];
    logic [31:0] ent_insn    [0:IQ_DEPTH-1];
    logic [3:0]  ent_rob     [0:IQ_DEPTH-1];
    logic [5:0]  ent_prs1    [0:IQ_DEPTH-1];
    logic [5:0]  ent_prs2    [0:IQ_DEPTH-1];
    logic [5:0]  ent_pdst    [0:IQ_DEPTH-1];
    logic        ent_r1rdy   [0:IQ_DEPTH-1];
    logic        ent_r2rdy   [0:IQ_DEPTH-1];
    logic [4:0]  ent_alu_op  [0:IQ_DEPTH-1];
    logic [2:0]  ent_wb_sel  [0:IQ_DEPTH-1];
    logic        ent_br      [0:IQ_DEPTH-1];
    logic        ent_jal     [0:IQ_DEPTH-1];
    logic        ent_jalr    [0:IQ_DEPTH-1];
    logic        ent_useimm  [0:IQ_DEPTH-1];
    logic        ent_auipc   [0:IQ_DEPTH-1];
    logic [31:0] ent_prednpc [0:IQ_DEPTH-1];
    logic        ent_predtk  [0:IQ_DEPTH-1];
    logic [1:0]  ent_predty  [0:IQ_DEPTH-1];

    logic [IQ_DEPTH-1:0] ent_ready;
    logic [IQ_DEPTH-1:0] ent_sel;
    logic [IQ_DEPTH-1:0] ent_uses1;
    logic [IQ_DEPTH-1:0] ent_uses2;

    logic        free_exist;
    logic [2:0]  free_idx;
    logic        sel_exist;
    logic [2:0]  sel_idx;
    logic        disp_fire;
    logic        issue_fire;
    logic        bypass_fire;
    logic        disp_uses1;
    logic        disp_uses2;

    logic [IQ_DEPTH-1:0] flush_mask;
    logic [IQ_DEPTH-1:0] valid_next;
    logic [IQ_DEPTH-1:0] r1rdy_next;
    logic [IQ_DEPTH-1:0] r2rdy_next;

    logic [31:0] sel_insn;
    logic [31:0] issue_imm_c;

    integer fi;
    integer rei;
    integer si;
    integer sei;
    integer fmi;
    integer rni;
    integer vni;
    integer rsti;
    integer dsi;

    always_comb begin
        free_exist = 1'b0;
        free_idx   = 3'd0;
        for (fi = 0; fi < IQ_DEPTH; fi = fi + 1) begin
            if (!ent_valid[fi] && !free_exist) begin
                free_exist = 1'b1;
                free_idx   = fi[2:0];
            end
        end
    end

    always_comb begin
        for (rei = 0; rei < IQ_DEPTH; rei = rei + 1) begin
            ent_uses1[rei] = ent_br[rei] || ent_jalr[rei] ||
                             (!ent_jal[rei] && !ent_auipc[rei] &&
                              !(ent_useimm[rei] && (ent_wb_sel[rei] == 3'b011)));
            ent_uses2[rei] = ent_br[rei] ||
                             (!ent_useimm[rei] && !ent_jal[rei] &&
                              !ent_jalr[rei] && !ent_auipc[rei]);
        end
    end

    assign disp_uses1 = iq_disp_is_branch || iq_disp_is_jalr ||
                        (!iq_disp_is_jal && !iq_disp_is_auipc &&
                         !(iq_disp_use_imm && (iq_disp_wb_sel == 3'b011)));
    assign disp_uses2 = iq_disp_is_branch ||
                        (!iq_disp_use_imm && !iq_disp_is_jal &&
                         !iq_disp_is_jalr && !iq_disp_is_auipc);

    always_comb begin
        for (rei = 0; rei < IQ_DEPTH; rei = rei + 1) begin
            ent_ready[rei] = ent_valid[rei] &&
                             (!ent_uses1[rei] || (ent_prs1[rei] == 6'd0) || ent_r1rdy[rei]) &&
                             (!ent_uses2[rei] || (ent_prs2[rei] == 6'd0) || ent_r2rdy[rei]);
        end
    end

    always_comb begin
        sel_exist = 1'b0;
        sel_idx   = 3'd0;
        for (si = 0; si < IQ_DEPTH; si = si + 1) begin
            if (ent_ready[si] && !sel_exist) begin
                sel_exist = 1'b1;
                sel_idx   = si[2:0];
            end
        end
    end

    always_comb begin
        for (sei = 0; sei < IQ_DEPTH; sei = sei + 1) begin
            ent_sel[sei] = sel_exist && (sel_idx == sei[2:0]);
        end
    end

    always_comb begin
        flush_mask = '0;
        for (fmi = 0; fmi < IQ_DEPTH; fmi = fmi + 1) begin
            if (flush && ent_valid[fmi]) begin
                if ((ent_rob[fmi] - rob_head_index) >=
                    (flush_rob_index - rob_head_index)) begin
                    flush_mask[fmi] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (rni = 0; rni < IQ_DEPTH; rni = rni + 1) begin
            r1rdy_next[rni] = (ent_prs1[rni] == 6'd0) ? 1'b1 : ent_r1rdy[rni];
            r2rdy_next[rni] = (ent_prs2[rni] == 6'd0) ? 1'b1 : ent_r2rdy[rni];
            if (ent_valid[rni]) begin
                if (alu_complete_valid && (ent_prs1[rni] == alu_complete_prd) && (ent_prs1[rni] != 6'd0)) begin
                    r1rdy_next[rni] = 1'b1;
                end
                if (load_complete_valid && (ent_prs1[rni] == load_complete_prd) && (ent_prs1[rni] != 6'd0)) begin
                    r1rdy_next[rni] = 1'b1;
                end
                if (alu_complete_valid && (ent_prs2[rni] == alu_complete_prd) && (ent_prs2[rni] != 6'd0)) begin
                    r2rdy_next[rni] = 1'b1;
                end
                if (load_complete_valid && (ent_prs2[rni] == load_complete_prd) && (ent_prs2[rni] != 6'd0)) begin
                    r2rdy_next[rni] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (vni = 0; vni < IQ_DEPTH; vni = vni + 1) begin
            valid_next[vni] = ent_valid[vni];
            if (flush_mask[vni]) begin
                valid_next[vni] = 1'b0;
            end
            if (issue_fire && (sel_idx == vni[2:0])) begin
                valid_next[vni] = 1'b0;
            end
            if (disp_fire && (free_idx == vni[2:0])) begin
                valid_next[vni] = 1'b1;
            end
        end
    end

    assign disp_fire  = iq_disp_valid && iq_disp_ready && !halted;
    assign issue_fire = issue_valid && issue_ready && !halted;
    assign bypass_fire = issue_fire && (ent_rob[sel_idx] != rob_head_index);

    assign iq_disp_ready = free_exist && !halted && !flush;
    assign issue_valid = sel_exist && !halted && !flush;

    assign sel_insn = ent_insn[sel_idx];

    always_comb begin
        case (sel_insn[6:0])
            7'b0010011, 7'b0000011, 7'b1100111:
                issue_imm_c = {{20{sel_insn[31]}}, sel_insn[31:20]};
            7'b0100011:
                issue_imm_c = {{20{sel_insn[31]}}, sel_insn[31:25], sel_insn[11:7]};
            7'b1100011:
                issue_imm_c = {{19{sel_insn[31]}}, sel_insn[31], sel_insn[7],
                               sel_insn[30:25], sel_insn[11:8], 1'b0};
            7'b0110111, 7'b0010111:
                issue_imm_c = {sel_insn[31:12], 12'b0};
            7'b1101111:
                issue_imm_c = {{11{sel_insn[31]}}, sel_insn[31], sel_insn[19:12],
                               sel_insn[20], sel_insn[30:21], 1'b0};
            default:
                issue_imm_c = 32'b0;
        endcase
    end

    assign issue_pc          = ent_pc[sel_idx];
    assign issue_insn        = ent_insn[sel_idx];
    assign issue_rob_index   = ent_rob[sel_idx];
    assign issue_prs1        = ent_prs1[sel_idx];
    assign issue_prs2        = ent_prs2[sel_idx];
    assign issue_pdst        = ent_pdst[sel_idx];
    assign issue_operand1    = iq_prf_rdata1;
    assign issue_operand2    = iq_prf_rdata2;
    assign issue_imm         = issue_imm_c;
    assign issue_alu_op      = ent_alu_op[sel_idx];
    assign issue_wb_sel      = ent_wb_sel[sel_idx];
    assign issue_is_branch   = ent_br[sel_idx];
    assign issue_is_jal      = ent_jal[sel_idx];
    assign issue_is_jalr     = ent_jalr[sel_idx];
    assign issue_use_imm     = ent_useimm[sel_idx];
    assign issue_is_auipc    = ent_auipc[sel_idx];
    assign issue_pred_next_pc= ent_prednpc[sel_idx];
    assign issue_pred_taken  = ent_predtk[sel_idx];
    assign issue_pred_type   = ent_predty[sel_idx];

    assign iq_prf_rs1_addr = ent_prs1[sel_idx];
    assign iq_prf_rs2_addr = ent_prs2[sel_idx];

    assign dbg_ooo_issue  = issue_fire;
    assign dbg_ooo_bypass = bypass_fire;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (rsti = 0; rsti < IQ_DEPTH; rsti = rsti + 1) begin
                ent_valid[rsti]   <= 1'b0;
                ent_pc[rsti]      <= 32'd0;
                ent_insn[rsti]    <= 32'd0;
                ent_rob[rsti]     <= 4'd0;
                ent_prs1[rsti]    <= 6'd0;
                ent_prs2[rsti]    <= 6'd0;
                ent_pdst[rsti]    <= 6'd0;
                ent_r1rdy[rsti]   <= 1'b0;
                ent_r2rdy[rsti]   <= 1'b0;
                ent_alu_op[rsti]  <= 5'd0;
                ent_wb_sel[rsti]  <= 3'd0;
                ent_br[rsti]      <= 1'b0;
                ent_jal[rsti]     <= 1'b0;
                ent_jalr[rsti]    <= 1'b0;
                ent_useimm[rsti]  <= 1'b0;
                ent_auipc[rsti]   <= 1'b0;
                ent_prednpc[rsti] <= 32'd0;
                ent_predtk[rsti]  <= 1'b0;
                ent_predty[rsti]  <= 2'd0;
            end
        end else begin
            for (rsti = 0; rsti < IQ_DEPTH; rsti = rsti + 1) begin
                ent_valid[rsti] <= valid_next[rsti];
                if (valid_next[rsti]) begin
                    ent_r1rdy[rsti] <= r1rdy_next[rsti];
                    ent_r2rdy[rsti] <= r2rdy_next[rsti];
                end else begin
                    ent_r1rdy[rsti] <= 1'b0;
                    ent_r2rdy[rsti] <= 1'b0;
                end
            end
            if (disp_fire) begin
                for (dsi = 0; dsi < IQ_DEPTH; dsi = dsi + 1) begin
                    if (free_idx == dsi[2:0]) begin
                        ent_pc[dsi]      <= iq_disp_pc;
                        ent_insn[dsi]    <= iq_disp_insn;
                        ent_rob[dsi]     <= iq_disp_rob_index;
                        ent_prs1[dsi]    <= iq_disp_prs1;
                        ent_prs2[dsi]    <= iq_disp_prs2;
                        ent_pdst[dsi]    <= iq_disp_pdst;
                        ent_r1rdy[dsi]   <= !disp_uses1 || (iq_disp_prs1 == 6'd0) || iq_disp_rs1_ready ||
                                             (alu_complete_valid && (iq_disp_prs1 == alu_complete_prd) && (iq_disp_prs1 != 6'd0)) ||
                                             (load_complete_valid && (iq_disp_prs1 == load_complete_prd) && (iq_disp_prs1 != 6'd0));
                        ent_r2rdy[dsi]   <= !disp_uses2 || (iq_disp_prs2 == 6'd0) || iq_disp_rs2_ready ||
                                             (alu_complete_valid && (iq_disp_prs2 == alu_complete_prd) && (iq_disp_prs2 != 6'd0)) ||
                                             (load_complete_valid && (iq_disp_prs2 == load_complete_prd) && (iq_disp_prs2 != 6'd0));
                        ent_alu_op[dsi]  <= iq_disp_alu_op;
                        ent_wb_sel[dsi]  <= iq_disp_wb_sel;
                        ent_br[dsi]      <= iq_disp_is_branch;
                        ent_jal[dsi]     <= iq_disp_is_jal;
                        ent_jalr[dsi]    <= iq_disp_is_jalr;
                        ent_useimm[dsi]  <= iq_disp_use_imm;
                        ent_auipc[dsi]   <= iq_disp_is_auipc;
                        ent_prednpc[dsi] <= iq_disp_pred_next_pc;
                        ent_predtk[dsi]  <= iq_disp_pred_taken;
                        ent_predty[dsi]  <= iq_disp_pred_type;
                    end
                end
            end
        end
    end

endmodule
