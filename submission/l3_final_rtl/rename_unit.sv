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

    // -----------------------------------------------------------------
    // Rename / checkpoint state
    // -----------------------------------------------------------------
    logic [191:0] spec_map;
    logic [95:0]  free_list;
    logic [3:0]   free_head;
    logic [3:0]   free_tail;
    logic [4:0]   free_count;
    logic [47:0]  ready_tbl;   // only PRD 0..47 are ever allocated

    logic [47:0]  slot_pdst;
    logic [47:0]  slot_old;
    logic [39:0]  slot_rd;
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

    // -----------------------------------------------------------------
    // Decode / dispatch.  All combinational behaviour of this module is
    // expressed with continuous assignments and constant-index part
    // selects only.  No combinational process and no variable-index
    // write into a 2-D array exists, so nothing special has to be
    // inferred and yosys sees only row-decoded, constant-index flops.
    // -----------------------------------------------------------------
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

    assign do_alloc = id_valid && !halted && !flush && !ecall_pending && rob_alloc_ready &&
                      (!need_pr || free_avail) &&
                      (!is_alu || iq_disp_ready) &&
                      (!is_mem || lsu_disp_ready);
    assign id_ready = !halted && !flush && !ecall_pending && rob_alloc_ready &&
                      (!need_pr || free_avail) &&
                      (!is_alu || iq_disp_ready) &&
                      (!is_mem || lsu_disp_ready);
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

    // -----------------------------------------------------------------
    // Flush / free-list push helpers (constant-index row decode only)
    // -----------------------------------------------------------------
    logic [3:0]  flush_next4;
    logic [3:0]  flush_cnt4;
    logic [7:0]  flush_elig;
    logic [23:0] flush_rank;
    logic [31:0] flush_push_pos;
    logic [3:0]  flush_push_count;
    logic        alloc_push_en;
    logic [5:0]  alloc_push_data;
    logic [5:0]  alloc_slot_pdst;
    logic [5:0]  alloc_slot_old;

    assign flush_next4 = flush_rob_index + 4'd1;
    assign flush_cnt4  = cur_tail - flush_next4;

    // One 3-bit circular distance per checkpoint slot (row-decoded).
    logic [23:0] slot_dist;
    genvar gk;
    generate
        for (gk = 0; gk < 8; gk = gk + 1) begin : gen_dist
            assign slot_dist[3*gk +: 3] = gk[2:0] - flush_next4[2:0];
        end
    endgenerate

    // dist_lt[8*gw + k] = (distance of slot k) < (distance of slot gw)
    logic [63:0] dist_lt;
    genvar gd;
    generate
        for (gd = 0; gd < 8; gd = gd + 1) begin : gen_dist_lt
            assign dist_lt[8*gd + 0] = (slot_dist[2:0]   < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 1] = (slot_dist[5:3]   < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 2] = (slot_dist[8:6]   < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 3] = (slot_dist[11:9]  < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 4] = (slot_dist[14:12] < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 5] = (slot_dist[17:15] < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 6] = (slot_dist[20:18] < slot_dist[3*gd +: 3]);
            assign dist_lt[8*gd + 7] = (slot_dist[23:21] < slot_dist[3*gd +: 3]);
        end
    endgenerate

    assign flush_elig[0] = do_flush && (slot_pdst[0  +: 6] != PR_ZERO) && ({1'b0, slot_dist[2:0]}   < flush_cnt4);
    assign flush_elig[1] = do_flush && (slot_pdst[6  +: 6] != PR_ZERO) && ({1'b0, slot_dist[5:3]}   < flush_cnt4);
    assign flush_elig[2] = do_flush && (slot_pdst[12 +: 6] != PR_ZERO) && ({1'b0, slot_dist[8:6]}   < flush_cnt4);
    assign flush_elig[3] = do_flush && (slot_pdst[18 +: 6] != PR_ZERO) && ({1'b0, slot_dist[11:9]}  < flush_cnt4);
    assign flush_elig[4] = do_flush && (slot_pdst[24 +: 6] != PR_ZERO) && ({1'b0, slot_dist[14:12]} < flush_cnt4);
    assign flush_elig[5] = do_flush && (slot_pdst[30 +: 6] != PR_ZERO) && ({1'b0, slot_dist[17:15]} < flush_cnt4);
    assign flush_elig[6] = do_flush && (slot_pdst[36 +: 6] != PR_ZERO) && ({1'b0, slot_dist[20:18]} < flush_cnt4);
    assign flush_elig[7] = do_flush && (slot_pdst[42 +: 6] != PR_ZERO) && ({1'b0, slot_dist[23:21]} < flush_cnt4);

    assign flush_push_count = {3'd0, flush_elig[0]} + {3'd0, flush_elig[1]} +
                              {3'd0, flush_elig[2]} + {3'd0, flush_elig[3]} +
                              {3'd0, flush_elig[4]} + {3'd0, flush_elig[5]} +
                              {3'd0, flush_elig[6]} + {3'd0, flush_elig[7]};

    genvar gr;
    generate
        for (gr = 0; gr < 8; gr = gr + 1) begin : gen_flush_rank
            assign flush_rank[3*gr +: 3] =
                {2'b0, (flush_elig[0] && dist_lt[8*gr + 0])} +
                {2'b0, (flush_elig[1] && dist_lt[8*gr + 1])} +
                {2'b0, (flush_elig[2] && dist_lt[8*gr + 2])} +
                {2'b0, (flush_elig[3] && dist_lt[8*gr + 3])} +
                {2'b0, (flush_elig[4] && dist_lt[8*gr + 4])} +
                {2'b0, (flush_elig[5] && dist_lt[8*gr + 5])} +
                {2'b0, (flush_elig[6] && dist_lt[8*gr + 6])} +
                {2'b0, (flush_elig[7] && dist_lt[8*gr + 7])};
        end
    endgenerate

    assign flush_push_pos[3:0]   = free_tail + {1'b0, flush_rank[2:0]};
    assign flush_push_pos[7:4]   = free_tail + {1'b0, flush_rank[5:3]};
    assign flush_push_pos[11:8]  = free_tail + {1'b0, flush_rank[8:6]};
    assign flush_push_pos[15:12] = free_tail + {1'b0, flush_rank[11:9]};
    assign flush_push_pos[19:16] = free_tail + {1'b0, flush_rank[14:12]};
    assign flush_push_pos[23:20] = free_tail + {1'b0, flush_rank[17:15]};
    assign flush_push_pos[27:24] = free_tail + {1'b0, flush_rank[20:18]};
    assign flush_push_pos[31:28] = free_tail + {1'b0, flush_rank[23:21]};

    assign alloc_slot_pdst = slot_pdst[(6*alloc_slot[2:0]) +: 6];
    assign alloc_slot_old  = slot_old[(6*alloc_slot[2:0]) +: 6];
    assign alloc_push_en   = (alloc_slot_pdst != PR_ZERO) && (alloc_slot_old != PR_ZERO);
    assign alloc_push_data = alloc_slot_old;

    // -----------------------------------------------------------------
    // Restore winner per checkpoint slot.  At most one slot per
    // architectural register survives (the oldest eligible writer).
    // The slot rd inputs are isolated when no flush is active so the
    // 32 x 8 restore comparators do not toggle on the rename path.
    // -----------------------------------------------------------------
    logic [39:0] slot_rd_iso;
    logic [7:0]  slot_win;

    assign slot_rd_iso = {40{do_flush}} & slot_rd;

    genvar gw;
    generate
        for (gw = 0; gw < 8; gw = gw + 1) begin : gen_slot_win
            assign slot_win[gw] = flush_elig[gw] &&
                !( (flush_elig[0] && (slot_rd_iso[4:0]   == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 0]) ||
                   (flush_elig[1] && (slot_rd_iso[9:5]   == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 1]) ||
                   (flush_elig[2] && (slot_rd_iso[14:10] == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 2]) ||
                   (flush_elig[3] && (slot_rd_iso[19:15] == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 3]) ||
                   (flush_elig[4] && (slot_rd_iso[24:20] == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 4]) ||
                   (flush_elig[5] && (slot_rd_iso[29:25] == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 5]) ||
                   (flush_elig[6] && (slot_rd_iso[34:30] == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 6]) ||
                   (flush_elig[7] && (slot_rd_iso[39:35] == slot_rd_iso[5*gw +: 5]) && dist_lt[8*gw + 7]) );
        end
    endgenerate

    // -----------------------------------------------------------------
    // Next-state values (all continuous, fully driven, constant rows)
    // -----------------------------------------------------------------
    logic [255:0] rd_match;      // rd_match[8*ga + k] = slot k writes arch ga
    logic [191:0] spec_map_nxt;
    logic [95:0]  free_list_nxt;
    logic [47:0]  slot_pdst_nxt;
    logic [47:0]  slot_old_nxt;
    logic [39:0]  slot_rd_nxt;
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
            logic       hit;
            logic [5:0] rval;

            assign rd_match[8*ga + 0] = (slot_rd_iso[4:0]   == ga[4:0]);
            assign rd_match[8*ga + 1] = (slot_rd_iso[9:5]   == ga[4:0]);
            assign rd_match[8*ga + 2] = (slot_rd_iso[14:10] == ga[4:0]);
            assign rd_match[8*ga + 3] = (slot_rd_iso[19:15] == ga[4:0]);
            assign rd_match[8*ga + 4] = (slot_rd_iso[24:20] == ga[4:0]);
            assign rd_match[8*ga + 5] = (slot_rd_iso[29:25] == ga[4:0]);
            assign rd_match[8*ga + 6] = (slot_rd_iso[34:30] == ga[4:0]);
            assign rd_match[8*ga + 7] = (slot_rd_iso[39:35] == ga[4:0]);

            assign hit = |(rd_match[8*ga +: 8] & slot_win);

            assign rval =
                ({6{rd_match[8*ga + 0] & slot_win[0]}} & slot_old[5:0])   |
                ({6{rd_match[8*ga + 1] & slot_win[1]}} & slot_old[11:6])  |
                ({6{rd_match[8*ga + 2] & slot_win[2]}} & slot_old[17:12]) |
                ({6{rd_match[8*ga + 3] & slot_win[3]}} & slot_old[23:18]) |
                ({6{rd_match[8*ga + 4] & slot_win[4]}} & slot_old[29:24]) |
                ({6{rd_match[8*ga + 5] & slot_win[5]}} & slot_old[35:30]) |
                ({6{rd_match[8*ga + 6] & slot_win[6]}} & slot_old[41:36]) |
                ({6{rd_match[8*ga + 7] & slot_win[7]}} & slot_old[47:42]);

            assign spec_map_nxt[6*ga +: 6] =
                (do_alloc && need_pr && (id_rd == ga[4:0])) ? rd_prd :
                (do_flush && hit)                           ? rval   :
                                                              spec_map[6*ga +: 6];
        end
    endgenerate

    // Operand isolation for the free-list push network: the flush push
    // sources are constant zero outside a flush.
    logic [31:0] push_pos_iso;
    logic [47:0] slot_pdst_iso;

    assign push_pos_iso  = {32{do_flush}} & flush_push_pos;
    assign slot_pdst_iso = {48{do_flush}} & slot_pdst;

    genvar gfl;
    generate
        for (gfl = 0; gfl < 16; gfl = gfl + 1) begin : gen_free_list
            assign free_list_nxt[6*gfl +: 6] =
                (do_flush && flush_elig[0] && (push_pos_iso[3:0]   == gfl[3:0])) ? slot_pdst_iso[5:0]   :
                (do_flush && flush_elig[1] && (push_pos_iso[7:4]   == gfl[3:0])) ? slot_pdst_iso[11:6]  :
                (do_flush && flush_elig[2] && (push_pos_iso[11:8]  == gfl[3:0])) ? slot_pdst_iso[17:12] :
                (do_flush && flush_elig[3] && (push_pos_iso[15:12] == gfl[3:0])) ? slot_pdst_iso[23:18] :
                (do_flush && flush_elig[4] && (push_pos_iso[19:16] == gfl[3:0])) ? slot_pdst_iso[29:24] :
                (do_flush && flush_elig[5] && (push_pos_iso[23:20] == gfl[3:0])) ? slot_pdst_iso[35:30] :
                (do_flush && flush_elig[6] && (push_pos_iso[27:24] == gfl[3:0])) ? slot_pdst_iso[41:36] :
                (do_flush && flush_elig[7] && (push_pos_iso[31:28] == gfl[3:0])) ? slot_pdst_iso[47:42] :
                (do_alloc && alloc_push_en && (free_tail == gfl[3:0]))          ? alloc_push_data        :
                                                                                  free_list[6*gfl +: 6];
        end
    endgenerate

    genvar gs;
    generate
        for (gs = 0; gs < 8; gs = gs + 1) begin : gen_slot
            assign slot_pdst_nxt[6*gs +: 6] =
                (do_flush && flush_elig[gs])               ? PR_ZERO :
                (do_alloc && (alloc_slot[2:0] == gs[2:0])) ? pdst_new :
                                                             slot_pdst[6*gs +: 6];

            assign slot_old_nxt[6*gs +: 6] =
                (do_flush && flush_elig[gs])               ? PR_ZERO :
                (do_alloc && (alloc_slot[2:0] == gs[2:0])) ? old_prd :
                                                             slot_old[6*gs +: 6];

            assign slot_rd_nxt[5*gs +: 5] =
                (do_flush && flush_elig[gs])               ? 5'd0 :
                (do_alloc && (alloc_slot[2:0] == gs[2:0])) ? id_rd :
                                                             slot_rd[5*gs +: 5];
        end
    endgenerate

    assign ready_set = (alu_complete_valid  ? (48'd1 << alu_complete_prd)  : 48'd0) |
                       (load_complete_valid ? (48'd1 << load_complete_prd) : 48'd0);
    assign ready_clr = (do_alloc && need_pr) ? (48'd1 << rd_prd) : 48'd0;
    assign ready_nxt = (ready_tbl | ready_set) & ~ready_clr;

    assign free_head_nxt  = free_head + ((do_alloc && need_pr) ? 4'd1 : 4'd0);
    assign free_tail_nxt  = free_tail + ((do_alloc && alloc_push_en) ? 4'd1 :
                                         (do_flush && (|flush_push_count)) ? flush_push_count :
                                         4'd0);
    assign free_count_nxt = free_count +
                            ((do_alloc && alloc_push_en) ? 5'd1 : 5'd0) +
                            ((do_flush && (|flush_push_count)) ? {1'b0, flush_push_count} : 5'd0) -
                            ((do_alloc && need_pr) ? 5'd1 : 5'd0);
    assign cur_tail_nxt   = do_flush ? flush_next4 :
                            do_alloc ? (rob_alloc_index + 4'd1) : cur_tail;

    // -----------------------------------------------------------------
    // Write enables: wide state is only rewritten when its value can
    // actually change, cutting unconditional per-cycle toggling.
    // -----------------------------------------------------------------
    logic spec_map_en;
    logic free_list_en;
    logic free_head_en;
    logic free_tail_en;
    logic free_count_en;
    logic ready_en;
    logic slot_en;
    logic cur_tail_en;

    assign spec_map_en   = (do_alloc && need_pr) || (do_flush && (|slot_win));
    assign free_list_en  = (do_alloc && alloc_push_en) || (do_flush && (|flush_push_count));
    assign free_head_en  = do_alloc && need_pr;
    assign free_tail_en  = (do_alloc && alloc_push_en) || (do_flush && (|flush_push_count));
    assign free_count_en = (do_alloc && (alloc_push_en || need_pr)) ||
                           (do_flush && (|flush_push_count));
    assign ready_en      = (|ready_set) || (|ready_clr);
    assign slot_en       = do_alloc || (|flush_elig);
    assign cur_tail_en   = do_alloc || do_flush;

    // -----------------------------------------------------------------
    // State update
    // -----------------------------------------------------------------
    always_ff @(posedge clk) begin : rename_state
        if (!rst_n) begin
            spec_map   <= SPEC_INIT;
            free_list  <= FREE_INIT;
            free_head  <= 4'd0;
            free_tail  <= 4'd0;
            free_count <= 5'd16;
            ready_tbl  <= {48{1'b1}};
            slot_pdst  <= 48'b0;
            slot_old   <= 48'b0;
            slot_rd    <= 40'b0;
            cur_tail   <= 4'd0;
        end else if (!halted) begin
            if (spec_map_en)   spec_map   <= spec_map_nxt;
            if (free_list_en)  free_list  <= free_list_nxt;
            if (free_head_en)  free_head  <= free_head_nxt;
            if (free_tail_en)  free_tail  <= free_tail_nxt;
            if (free_count_en) free_count <= free_count_nxt;
            if (ready_en)      ready_tbl  <= ready_nxt;
            if (slot_en) begin
                slot_pdst <= slot_pdst_nxt;
                slot_old  <= slot_old_nxt;
                slot_rd   <= slot_rd_nxt;
            end
            if (cur_tail_en)   cur_tail   <= cur_tail_nxt;
        end
    end

endmodule
