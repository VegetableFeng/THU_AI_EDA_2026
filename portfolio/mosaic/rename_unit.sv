module rename_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [3:0]  flush_rob_index,
    input  logic        halted,
    input  logic        ecall_pending,
    input  logic        id_valid,
    output logic        id_ready,
    input  logic [31:0] id_pc,
    input  logic [31:0] id_insn,
    input  logic [4:0]  id_rs1,
    input  logic [4:0]  id_rs2,
    input  logic [4:0]  id_rd,
    input  logic [31:0] id_imm,
    input  logic [4:0]  id_alu_op,
    input  logic [2:0]  id_wb_sel,
    input  logic        id_is_load,
    input  logic        id_is_store,
    input  logic [1:0]  id_mem_size,
    input  logic        id_is_branch,
    input  logic        id_is_jal,
    input  logic        id_is_jalr,
    input  logic        id_is_ecall,
    input  logic        id_reg_write,
    input  logic        id_use_imm,
    input  logic        id_is_auipc,
    input  logic [31:0] id_pred_next_pc,
    input  logic        id_pred_taken,
    input  logic [1:0]  id_pred_type,
    input  logic        id_pred_hit,
    output logic        rob_alloc_valid,
    input  logic        rob_alloc_ready,
    input  logic [3:0]  rob_alloc_index,
    output logic [31:0] rob_alloc_pc,
    output logic [31:0] rob_alloc_insn,
    output logic [5:0]  rob_alloc_pdst,
    output logic [5:0]  rob_alloc_old_prd,
    output logic [4:0]  rob_alloc_arch_rd,
    output logic        rob_alloc_is_control,
    output logic        rob_alloc_is_store,
    output logic        rob_alloc_is_ecall,
    output logic        rob_alloc_reg_write,
    output logic        iq_disp_valid,
    input  logic        iq_disp_ready,
    output logic [31:0] iq_disp_pc,
    output logic [31:0] iq_disp_insn,
    output logic [3:0]  iq_disp_rob_index,
    output logic [5:0]  iq_disp_prs1,
    output logic [5:0]  iq_disp_prs2,
    output logic [5:0]  iq_disp_pdst,
    output logic        iq_disp_rs1_ready,
    output logic        iq_disp_rs2_ready,
    output logic [31:0] iq_disp_imm,
    output logic [4:0]  iq_disp_alu_op,
    output logic [2:0]  iq_disp_wb_sel,
    output logic        iq_disp_is_branch,
    output logic        iq_disp_is_jal,
    output logic        iq_disp_is_jalr,
    output logic        iq_disp_use_imm,
    output logic        iq_disp_is_auipc,
    output logic [31:0] iq_disp_pred_next_pc,
    output logic        iq_disp_pred_taken,
    output logic [1:0]  iq_disp_pred_type,
    output logic        lsu_disp_valid,
    input  logic        lsu_disp_ready,
    output logic [31:0] lsu_disp_pc,
    output logic [31:0] lsu_disp_insn,
    output logic [3:0]  lsu_disp_rob_index,
    output logic [5:0]  lsu_disp_prs1,
    output logic [5:0]  lsu_disp_prs2,
    output logic [5:0]  lsu_disp_pdst,
    output logic        lsu_disp_rs1_ready,
    output logic        lsu_disp_rs2_ready,
    output logic [31:0] lsu_disp_imm,
    output logic        lsu_disp_is_load,
    output logic        lsu_disp_is_store,
    output logic [1:0]  lsu_disp_mem_size,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    input  logic        load_complete_valid,
    input  logic [5:0]  load_complete_prd
);

    localparam logic [5:0] PR_ZERO = 6'd0;

    logic [191:0] spec_map;
    logic [95:0]  free_list;
    logic [3:0]   free_head;
    logic [3:0]   free_tail;
    logic [4:0]   free_count;
    logic [47:0]  ready_tbl;

    // Checkpoint slot table held as two explicit constant-index rows (row 0 /
    // row 1).  All writes below are constant-index row writes; there is no
    // variable-row (2D unpacked array) write anywhere in this module.
    logic [5:0]   slot0_pdst;
    logic [5:0]   slot1_pdst;
    logic [5:0]   slot0_old;
    logic [5:0]   slot1_old;
    logic [4:0]   slot0_rd;
    logic [4:0]   slot1_rd;
    logic [3:0]   cur_tail;

    localparam logic [191:0] SPEC_INIT = {
        6'd31, 6'd30, 6'd29, 6'd28, 6'd27, 6'd26, 6'd25, 6'd24,
        6'd23, 6'd22, 6'd21, 6'd20, 6'd19, 6'd18, 6'd17, 6'd16,
        6'd15, 6'd14, 6'd13, 6'd12, 6'd11, 6'd10, 6'd9,  6'd8,
        6'd7,  6'd6,  6'd5,  6'd4,  6'd3,  6'd2,  6'd1,  6'd0
    };

    localparam logic [95:0] FREE_INIT = {
        6'd47, 6'd46, 6'd45, 6'd44, 6'd43, 6'd42, 6'd41, 6'd40,
        6'd39, 6'd38, 6'd37, 6'd36, 6'd35, 6'd34, 6'd33, 6'd32
    };

    logic [5:0]  rs1_prd;
    logic [5:0]  rs2_prd;
    logic [5:0]  rd_prd;
    logic [5:0]  old_prd;
    logic        rs1_rdy;
    logic        rs2_rdy;
    logic        need_pr;
    logic        free_avail;
    logic        is_ctrl;
    logic        is_mem;
    logic        is_alu;
    logic        do_alloc;
    logic        do_flush;
    logic        id_slot_ready;
    logic [3:0]  alloc_slot;
    logic [5:0]  pdst_new;
    logic [5:0]  spec_rs1;
    logic [5:0]  spec_rs2;
    logic [5:0]  spec_old;
    logic [5:0]  free_head_data;

    assign spec_rs1       = spec_map[6*id_rs1 +: 6];
    assign spec_rs2       = spec_map[6*id_rs2 +: 6];
    assign spec_old       = spec_map[6*id_rd  +: 6];
    assign free_head_data = free_list[6*free_head +: 6];

    assign rs1_prd = (id_rs1 == 5'd0) ? PR_ZERO : spec_rs1;
    assign rs2_prd = (id_rs2 == 5'd0) ? PR_ZERO : spec_rs2;

    assign rs1_rdy = (rs1_prd == PR_ZERO) ? 1'b1 :
                     (ready_tbl[rs1_prd] ||
                      (alu_complete_valid  && (alu_complete_prd  == rs1_prd)) ||
                      (load_complete_valid && (load_complete_prd == rs1_prd)));
    assign rs2_rdy = (rs2_prd == PR_ZERO) ? 1'b1 :
                     (ready_tbl[rs2_prd] ||
                      (alu_complete_valid  && (alu_complete_prd  == rs2_prd)) ||
                      (load_complete_valid && (load_complete_prd == rs2_prd)));

    assign need_pr    = id_reg_write && (id_rd != 5'd0);
    assign free_avail = (free_count != 5'd0);
    assign is_ctrl    = id_is_branch || id_is_jal || id_is_jalr;
    assign is_mem     = id_is_load || id_is_store;
    assign is_alu     = !is_mem && !id_is_ecall;

    // Per-instruction dispatch readiness: ALU dispatch is gated only by the
    // issue-queue readiness, memory dispatch only by the LSU readiness.  When
    // the ID stage is empty, its stale instruction flags must not globally
    // block the IF stage; otherwise a pending LSU load can deadlock fetch and
    // prevent a younger independent ALU from ever reaching the issue queue.
    assign id_slot_ready = rob_alloc_ready &&
                           (!need_pr || free_avail) &&
                           (!is_alu || iq_disp_ready) &&
                           (!is_mem || lsu_disp_ready);

    assign do_alloc = id_valid && !halted && !flush && !ecall_pending &&
                      id_slot_ready;
    assign id_ready = rst_n && !halted && !flush && !ecall_pending &&
                      (id_valid ? id_slot_ready : rob_alloc_ready);
    assign do_flush   = flush && !halted;
    assign alloc_slot = rob_alloc_index;

    assign rd_prd   = need_pr ? free_head_data : PR_ZERO;
    assign old_prd  = need_pr ? spec_old       : PR_ZERO;
    assign pdst_new = need_pr ? rd_prd         : PR_ZERO;

    assign rob_alloc_valid        = do_alloc;
    assign rob_alloc_pc           = id_pc;
    assign rob_alloc_insn         = id_insn;
    assign rob_alloc_pdst         = rd_prd;
    assign rob_alloc_old_prd      = old_prd;
    assign rob_alloc_arch_rd      = id_rd;
    assign rob_alloc_is_control   = is_ctrl;
    assign rob_alloc_is_store     = id_is_store;
    assign rob_alloc_is_ecall     = id_is_ecall;
    assign rob_alloc_reg_write    = need_pr;

    assign iq_disp_valid          = do_alloc && is_alu;
    assign iq_disp_pc             = id_pc;
    assign iq_disp_insn           = id_insn;
    assign iq_disp_rob_index      = rob_alloc_index;
    assign iq_disp_prs1           = rs1_prd;
    assign iq_disp_prs2           = rs2_prd;
    assign iq_disp_pdst           = rd_prd;
    assign iq_disp_rs1_ready      = rs1_rdy;
    assign iq_disp_rs2_ready      = rs2_rdy;
    assign iq_disp_imm            = id_imm;
    assign iq_disp_alu_op         = id_alu_op;
    assign iq_disp_wb_sel         = id_wb_sel;
    assign iq_disp_is_branch      = id_is_branch;
    assign iq_disp_is_jal         = id_is_jal;
    assign iq_disp_is_jalr        = id_is_jalr;
    assign iq_disp_use_imm        = id_use_imm;
    assign iq_disp_is_auipc       = id_is_auipc;
    assign iq_disp_pred_next_pc   = id_pred_next_pc;
    assign iq_disp_pred_taken     = id_pred_taken;
    assign iq_disp_pred_type      = id_pred_type;

    assign lsu_disp_valid         = do_alloc && is_mem;
    assign lsu_disp_pc            = id_pc;
    assign lsu_disp_insn          = id_insn;
    assign lsu_disp_rob_index     = rob_alloc_index;
    assign lsu_disp_prs1          = rs1_prd;
    assign lsu_disp_prs2          = rs2_prd;
    assign lsu_disp_pdst          = rd_prd;
    assign lsu_disp_rs1_ready     = rs1_rdy;
    assign lsu_disp_rs2_ready     = rs2_rdy;
    assign lsu_disp_imm           = id_imm;
    assign lsu_disp_is_load       = id_is_load;
    assign lsu_disp_is_store      = id_is_store;
    assign lsu_disp_mem_size      = id_mem_size;

    logic [3:0]  flush_next4;
    logic        flush_young;
    logic [1:0]  flush_elig;
    logic        flush_push_en;
    logic [5:0]  flush_push_data;
    logic [4:0]  flush_rd;
    logic [5:0]  flush_old;
    logic        alloc_push_en;
    logic [5:0]  alloc_push_data;
    logic [5:0]  alloc_slot_pdst;
    logic [5:0]  alloc_slot_old;
    logic        free_push_en;
    logic [5:0]  free_push_data;

    assign flush_next4 = flush_rob_index + 4'd1;
    assign flush_young = do_flush && (cur_tail != flush_next4);

    assign flush_elig[0] = flush_young && (flush_next4[0] == 1'b0) &&
                           (slot0_pdst != PR_ZERO);
    assign flush_elig[1] = flush_young && (flush_next4[0] == 1'b1) &&
                           (slot1_pdst != PR_ZERO);

    assign flush_push_en   = flush_elig[0] | flush_elig[1];
    assign flush_push_data = flush_elig[0] ? slot0_old : slot1_old;
    assign flush_rd        = flush_elig[0] ? slot0_rd  : slot1_rd;
    assign flush_old       = flush_elig[0] ? slot0_old : slot1_old;

    assign alloc_slot_pdst = alloc_slot[0] ? slot1_pdst : slot0_pdst;
    assign alloc_slot_old  = alloc_slot[0] ? slot1_old  : slot0_old;
    assign alloc_push_en   = do_alloc && (alloc_slot_pdst != PR_ZERO) &&
                             (alloc_slot_old != PR_ZERO);
    assign alloc_push_data = alloc_slot_old;

    assign free_push_en   = flush_push_en | alloc_push_en;
    assign free_push_data = flush_push_en ? flush_push_data : alloc_push_data;

    logic [191:0] spec_map_nxt;
    logic [95:0]  free_list_nxt;
    logic [5:0]   slot0_pdst_nxt;
    logic [5:0]   slot1_pdst_nxt;
    logic [5:0]   slot0_old_nxt;
    logic [5:0]   slot1_old_nxt;
    logic [4:0]   slot0_rd_nxt;
    logic [4:0]   slot1_rd_nxt;
    logic [3:0]   free_head_nxt;
    logic [3:0]   free_tail_nxt;
    logic [4:0]   free_count_nxt;
    logic [3:0]   cur_tail_nxt;
    logic [47:0]  ready_nxt;
    logic [47:0]  ready_set;
    logic [47:0]  ready_clr;

    genvar ga;
    generate
        for (ga = 0; ga < 32; ga = ga + 1) begin : gen_spec_map
            assign spec_map_nxt[6*ga +: 6] =
                (do_alloc && need_pr && (id_rd == ga[4:0])) ? rd_prd :
                (flush_push_en && (flush_rd == ga[4:0]))   ? flush_old :
                                                              spec_map[6*ga +: 6];
        end
    endgenerate

    genvar gfl;
    generate
        for (gfl = 0; gfl < 16; gfl = gfl + 1) begin : gen_free_list
            assign free_list_nxt[6*gfl +: 6] =
                (free_push_en && (free_tail == gfl[3:0])) ? free_push_data :
                                                            free_list[6*gfl +: 6];
        end
    endgenerate

    // Row-decoded checkpoint slot writes: row 0 and row 1 are written with
    // constant indices; flush restore has priority over allocation, exactly
    // as the previous per-row next-state logic did.
    assign slot0_pdst_nxt = flush_elig[0] ? PR_ZERO :
                            (do_alloc && (alloc_slot[0] == 1'b0)) ? pdst_new :
                                                                    slot0_pdst;
    assign slot1_pdst_nxt = flush_elig[1] ? PR_ZERO :
                            (do_alloc && (alloc_slot[0] == 1'b1)) ? pdst_new :
                                                                    slot1_pdst;
    assign slot0_old_nxt  = flush_elig[0] ? PR_ZERO :
                            (do_alloc && (alloc_slot[0] == 1'b0)) ? old_prd :
                                                                    slot0_old;
    assign slot1_old_nxt  = flush_elig[1] ? PR_ZERO :
                            (do_alloc && (alloc_slot[0] == 1'b1)) ? old_prd :
                                                                    slot1_old;
    assign slot0_rd_nxt   = flush_elig[0] ? 5'd0 :
                            (do_alloc && (alloc_slot[0] == 1'b0)) ? id_rd :
                                                                    slot0_rd;
    assign slot1_rd_nxt   = flush_elig[1] ? 5'd0 :
                            (do_alloc && (alloc_slot[0] == 1'b1)) ? id_rd :
                                                                    slot1_rd;

    assign ready_set = (alu_complete_valid  ? (48'd1 << alu_complete_prd)  : 48'd0) |
                       (load_complete_valid ? (48'd1 << load_complete_prd) : 48'd0);
    assign ready_clr = (do_alloc && need_pr) ? (48'd1 << rd_prd) : 48'd0;
    assign ready_nxt = (ready_tbl | ready_set) & ~ready_clr;

    assign free_head_nxt  = free_head + ((do_alloc && need_pr) ? 4'd1 : 4'd0);
    assign free_tail_nxt  = free_tail + (free_push_en ? 4'd1 : 4'd0);
    assign free_count_nxt = free_count + (free_push_en ? 5'd1 : 5'd0) -
                            ((do_alloc && need_pr) ? 5'd1 : 5'd0);
    assign cur_tail_nxt   = do_flush ? flush_next4 :
                            do_alloc ? (rob_alloc_index + 4'd1) : cur_tail;

    logic spec_map_en;
    logic free_list_en;
    logic free_head_en;
    logic free_tail_en;
    logic free_count_en;
    logic ready_en;
    logic slot_en;
    logic cur_tail_en;

    assign spec_map_en   = (do_alloc && need_pr) || flush_push_en;
    assign free_list_en  = free_push_en;
    assign free_head_en  = do_alloc && need_pr;
    assign free_tail_en  = free_push_en;
    assign free_count_en = (do_alloc && need_pr) || free_push_en;
    assign ready_en      = (|ready_set) || (|ready_clr);
    assign slot_en       = do_alloc || flush_push_en;
    assign cur_tail_en   = do_alloc || do_flush;

    always_ff @(posedge clk) begin : rename_state
        if (!rst_n) begin
            spec_map   <= SPEC_INIT;
            free_list  <= FREE_INIT;
            free_head  <= 4'd0;
            free_tail  <= 4'd0;
            free_count <= 5'd16;
            ready_tbl  <= {48{1'b1}};
            slot0_pdst <= 6'd0;
            slot1_pdst <= 6'd0;
            slot0_old  <= 6'd0;
            slot1_old  <= 6'd0;
            slot0_rd   <= 5'd0;
            slot1_rd   <= 5'd0;
            cur_tail   <= 4'd0;
        end else if (!halted) begin
            if (spec_map_en)   spec_map   <= spec_map_nxt;
            if (free_list_en)  free_list  <= free_list_nxt;
            if (free_head_en)  free_head  <= free_head_nxt;
            if (free_tail_en)  free_tail  <= free_tail_nxt;
            if (free_count_en) free_count <= free_count_nxt;
            if (ready_en)      ready_tbl  <= ready_nxt;
            if (slot_en) begin
                slot0_pdst <= slot0_pdst_nxt;
                slot1_pdst <= slot1_pdst_nxt;
                slot0_old  <= slot0_old_nxt;
                slot1_old  <= slot1_old_nxt;
                slot0_rd   <= slot0_rd_nxt;
                slot1_rd   <= slot1_rd_nxt;
            end
            if (cur_tail_en)   cur_tail   <= cur_tail_nxt;
        end
    end

endmodule