module load_store_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [3:0]  flush_rob_index,
    input  logic [1:0]  flush_epoch,
    input  logic        halted,
    input  logic        lsu_disp_valid,
    output logic        lsu_disp_ready,
    input  logic [31:0] lsu_disp_pc,
    input  logic [31:0] lsu_disp_insn,
    input  logic [3:0]  lsu_disp_rob_index,
    input  logic [5:0]  lsu_disp_prs1,
    input  logic [5:0]  lsu_disp_prs2,
    input  logic [5:0]  lsu_disp_pdst,
    input  logic        lsu_disp_rs1_ready,
    input  logic        lsu_disp_rs2_ready,
    input  logic [31:0] lsu_disp_imm,
    input  logic        lsu_disp_is_load,
    input  logic        lsu_disp_is_store,
    input  logic [1:0]  lsu_disp_mem_size,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    output logic [5:0]  lsu_prf_rs1_addr,
    output logic [5:0]  lsu_prf_rs2_addr,
    input  logic [31:0] lsu_prf_rdata1,
    input  logic [31:0] lsu_prf_rdata2,
    input  logic        store_commit_valid,
    input  logic [3:0]  store_commit_rob_index,
    output logic        store_done_valid,
    output logic [3:0]  store_done_rob_index,
    output logic        load_complete_valid,
    output logic [3:0]  load_complete_rob_index,
    output logic [5:0]  load_complete_prd,
    output logic [31:0] load_complete_data,
    output logic        lsu_dcache_req_valid,
    output logic        lsu_dcache_req_we,
    output logic [31:0] lsu_dcache_req_addr,
    output logic [31:0] lsu_dcache_req_wdata,
    output logic [3:0]  lsu_dcache_req_be,
    output logic [3:0]  lsu_dcache_req_rob_index,
    output logic [1:0]  lsu_dcache_req_epoch,
    input  logic        lsu_dcache_req_ready,
    input  logic        lsu_dcache_resp_valid,
    input  logic [31:0] lsu_dcache_resp_rdata,
    input  logic [1:0]  lsu_dcache_resp_epoch,
    output logic        lsu_dcache_wait,
    output logic        lsu_idle
);

    localparam logic [1:0] MEM_BYTE = 2'b00;
    localparam logic [1:0] MEM_HALF = 2'b01;

    logic        ent_valid     [0:1];
    logic [31:0] ent_insn      [0:1];
    logic [3:0]  ent_rob       [0:1];
    logic [5:0]  ent_prs1      [0:1];
    logic [5:0]  ent_prs2      [0:1];
    logic [5:0]  ent_pdst      [0:1];
    logic        ent_rs1_ready [0:1];
    logic        ent_rs2_ready [0:1];
    logic        ent_is_load   [0:1];
    logic        ent_is_store  [0:1];
    logic [1:0]  ent_epoch     [0:1];
    logic        ent_issued    [0:1];
    logic        ent_committed [0:1];

    logic        req_active;
    logic        req_we_q;
    logic [31:0] req_addr_q;
    logic [31:0] req_wdata_q;
    logic [3:0]  req_be_q;
    logic [3:0]  req_rob_q;
    logic [1:0]  req_epoch_q;

    logic        head_valid;
    logic        tail_valid;
    logic        head_rs1_wake;
    logic        head_rs2_wake;
    logic        tail_rs1_wake;
    logic        tail_rs2_wake;
    logic        tail_rs1_ready_eff;
    logic        tail_rs2_ready_eff;
    logic        head_rs1_ok;
    logic        head_rs2_ok;
    logic        head_can_issue;
    logic        head_store_ready;
    logic        head_load_ready;
    logic        head_issue_fire;
    logic        req_accept;
    logic        req_owner_match;
    logic        head_resp_fire;
    logic        head_resp_stale;
    logic        head_load_done;
    logic        head_store_done;
    logic [31:0] head_addr;
    logic [31:0] head_imm;
    logic [3:0]  head_be;
    logic [31:0] head_wdata;
    logic [31:0] load_word;
    logic [31:0] load_data;
    logic [2:0]  head_funct3;
    logic        disp_fire;
    logic        disp_to_head;
    logic        disp_to_tail;
    logic        disp_rs1_eff;
    logic        disp_rs2_eff;
    logic        squash_head;
    logic        squash_tail;
    logic        store_commit_match_head;
    logic        store_commit_match_tail;
    logic        head_remove;
    logic        tail_remove;

    logic        head_rs1_next;
    logic        head_rs2_next;
    logic        tail_rs1_next;
    logic        tail_rs2_next;

    assign head_valid = ent_valid[0];
    assign tail_valid = ent_valid[1];

    assign lsu_prf_rs1_addr = ent_valid[0] ? ent_prs1[0] :
                              (ent_valid[1] ? ent_prs1[1] : 6'd0);
    assign lsu_prf_rs2_addr = ent_valid[0] ? ent_prs2[0] :
                              (ent_valid[1] ? ent_prs2[1] : 6'd0);

    assign head_imm = ent_is_store[0] ?
                      {{20{ent_insn[0][31]}}, ent_insn[0][31:25], ent_insn[0][11:7]} :
                      {{20{ent_insn[0][31]}}, ent_insn[0][31:20]};

    assign head_addr = lsu_prf_rdata1 + head_imm;

    assign head_funct3 = ent_insn[0][14:12];

    always_comb begin
        head_be    = 4'b0000;
        head_wdata = 32'd0;
        case (head_funct3[1:0])
            2'b00: begin
                head_be    = 4'b0001 << head_addr[1:0];
                head_wdata = {4{lsu_prf_rdata2[7:0]}};
            end
            2'b01: begin
                head_be    = head_addr[1] ? 4'b1100 : 4'b0011;
                head_wdata = {2{lsu_prf_rdata2[15:0]}};
            end
            default: begin
                head_be    = 4'b1111;
                head_wdata = lsu_prf_rdata2;
            end
        endcase
    end

    assign head_rs1_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == ent_prs1[0])) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == ent_prs1[0]));
    assign head_rs2_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == ent_prs2[0])) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == ent_prs2[0]));
    assign tail_rs1_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == ent_prs1[1])) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == ent_prs1[1]));
    assign tail_rs2_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == ent_prs2[1])) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == ent_prs2[1]));

    assign tail_rs1_ready_eff = (ent_prs1[1] == 6'd0) ||
                                ent_rs1_ready[1] || tail_rs1_wake;
    assign tail_rs2_ready_eff = (ent_prs2[1] == 6'd0) ||
                                ent_rs2_ready[1] || tail_rs2_wake;

    assign head_rs1_ok = (ent_prs1[0] == 6'd0) || ent_rs1_ready[0] || head_rs1_wake;
    assign head_rs2_ok = (ent_prs2[0] == 6'd0) || ent_rs2_ready[0] || head_rs2_wake;

    assign head_load_ready  = ent_is_load[0] && head_rs1_ok;
    assign head_store_ready = ent_is_store[0] && ent_committed[0] &&
                              head_rs1_ok && head_rs2_ok;

    assign head_can_issue = head_valid && !ent_issued[0] && !halted && !flush &&
                            !req_active && (head_store_ready || head_load_ready);

    assign req_accept = lsu_dcache_req_valid && lsu_dcache_req_ready;
    assign req_owner_match = ent_valid[0] &&
                             (req_rob_q == ent_rob[0]) &&
                             (req_epoch_q == ent_epoch[0]);
    assign head_issue_fire = req_accept &&
                             (req_active ? req_owner_match : 1'b1);

    assign head_resp_fire = (ent_issued[0] || head_issue_fire) &&
                            lsu_dcache_resp_valid &&
                            (lsu_dcache_resp_epoch == ent_epoch[0]) &&
                            !squash_head;
    assign head_resp_stale = (ent_issued[0] || head_issue_fire) &&
                             lsu_dcache_resp_valid &&
                             (lsu_dcache_resp_epoch != ent_epoch[0]) &&
                             !squash_head;

    assign load_word = lsu_dcache_resp_rdata;

    always_comb begin
        load_data = load_word;
        case (head_funct3)
            3'b000: begin
                case (head_addr[1:0])
                    2'd0:    load_data = {{24{load_word[7]}},  load_word[7:0]};
                    2'd1:    load_data = {{24{load_word[15]}}, load_word[15:8]};
                    2'd2:    load_data = {{24{load_word[23]}}, load_word[23:16]};
                    default: load_data = {{24{load_word[31]}}, load_word[31:24]};
                endcase
            end
            3'b100: begin
                case (head_addr[1:0])
                    2'd0:    load_data = {24'd0, load_word[7:0]};
                    2'd1:    load_data = {24'd0, load_word[15:8]};
                    2'd2:    load_data = {24'd0, load_word[23:16]};
                    default: load_data = {24'd0, load_word[31:24]};
                endcase
            end
            3'b001: begin
                if (head_addr[1])
                    load_data = {{16{load_word[31]}}, load_word[31:16]};
                else
                    load_data = {{16{load_word[15]}}, load_word[15:0]};
            end
            3'b101: begin
                if (head_addr[1])
                    load_data = {16'd0, load_word[31:16]};
                else
                    load_data = {16'd0, load_word[15:0]};
            end
            default: load_data = load_word;
        endcase
    end

    assign head_load_done  = head_resp_fire && ent_is_load[0];
    assign head_store_done = head_resp_fire && ent_is_store[0];

    assign load_complete_valid     = head_load_done;
    assign load_complete_rob_index = ent_rob[0];
    assign load_complete_prd       = ent_pdst[0];
    assign load_complete_data      = load_data;

    assign store_done_valid     = head_store_done;
    assign store_done_rob_index = ent_rob[0];

    assign store_commit_match_head = store_commit_valid && ent_valid[0] &&
                                     (store_commit_rob_index == ent_rob[0]);
    assign store_commit_match_tail = store_commit_valid && ent_valid[1] &&
                                     (store_commit_rob_index == ent_rob[1]);

    assign squash_head = flush && ent_valid[0] &&
                         !((ent_rob[0] - flush_rob_index) & 4'h8);
    assign squash_tail = flush && ent_valid[1] &&
                         !((ent_rob[1] - flush_rob_index) & 4'h8);

    assign head_remove = ent_valid[0] &&
                         (head_load_done || head_store_done || squash_head);
    assign tail_remove = ent_valid[1] && squash_tail;

    assign lsu_dcache_req_valid     = req_active || head_can_issue;
    assign lsu_dcache_req_we        = req_active ? req_we_q : ent_is_store[0];
    assign lsu_dcache_req_addr      = req_active ? req_addr_q : head_addr;
    assign lsu_dcache_req_wdata     = req_active ? req_wdata_q : head_wdata;
    assign lsu_dcache_req_be        = req_active ? req_be_q : head_be;
    assign lsu_dcache_req_rob_index = req_active ? req_rob_q : ent_rob[0];
    assign lsu_dcache_req_epoch     = req_active ? req_epoch_q : ent_epoch[0];

    assign lsu_dcache_wait = (req_active || ent_issued[0]) &&
                             !lsu_dcache_resp_valid;

    assign lsu_idle = !ent_valid[0] && !ent_valid[1] && !req_active;

    assign lsu_disp_ready = rst_n && !halted && !flush &&
                            (!ent_valid[0] || !ent_valid[1]);
    assign disp_fire = lsu_disp_valid && lsu_disp_ready;

    assign disp_to_head = disp_fire &&
                          (!ent_valid[0] ||
                           (head_remove && (!ent_valid[1] || tail_remove)));
    assign disp_to_tail = disp_fire && !disp_to_head &&
                          ent_valid[0] && !ent_valid[1];

    assign disp_rs1_eff = (lsu_disp_prs1 == 6'd0) || lsu_disp_rs1_ready ||
                          (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                           (alu_complete_prd == lsu_disp_prs1)) ||
                          (load_complete_valid && (load_complete_prd != 6'd0) &&
                           (load_complete_prd == lsu_disp_prs1));
    assign disp_rs2_eff = (lsu_disp_prs2 == 6'd0) || lsu_disp_rs2_ready ||
                          (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                           (alu_complete_prd == lsu_disp_prs2)) ||
                          (load_complete_valid && (load_complete_prd != 6'd0) &&
                           (load_complete_prd == lsu_disp_prs2));

    always_comb begin
        head_rs1_next = ent_rs1_ready[0];
        head_rs2_next = ent_rs2_ready[0];
        if (ent_valid[0] && !head_remove) begin
            if (head_rs1_wake) head_rs1_next = 1'b1;
            if (head_rs2_wake) head_rs2_next = 1'b1;
        end

        tail_rs1_next = ent_rs1_ready[1];
        tail_rs2_next = ent_rs2_ready[1];
        if (ent_valid[1] && !tail_remove) begin
            if (tail_rs1_wake) tail_rs1_next = 1'b1;
            if (tail_rs2_wake) tail_rs2_next = 1'b1;
        end

        if (disp_to_head) begin
            head_rs1_next = disp_rs1_eff;
            head_rs2_next = disp_rs2_eff;
        end else if (head_remove && ent_valid[1] && !tail_remove) begin
            head_rs1_next = tail_rs1_ready_eff;
            head_rs2_next = tail_rs2_ready_eff;
        end

        if (disp_to_tail) begin
            tail_rs1_next = disp_rs1_eff;
            tail_rs2_next = disp_rs2_eff;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ent_valid[0]      <= 1'b0;
            ent_valid[1]      <= 1'b0;
            ent_insn[0]       <= 32'd0;
            ent_insn[1]       <= 32'd0;
            ent_rob[0]        <= 4'd0;
            ent_rob[1]        <= 4'd0;
            ent_prs1[0]       <= 6'd0;
            ent_prs1[1]       <= 6'd0;
            ent_prs2[0]       <= 6'd0;
            ent_prs2[1]       <= 6'd0;
            ent_pdst[0]       <= 6'd0;
            ent_pdst[1]       <= 6'd0;
            ent_rs1_ready[0]  <= 1'b0;
            ent_rs1_ready[1]  <= 1'b0;
            ent_rs2_ready[0]  <= 1'b0;
            ent_rs2_ready[1]  <= 1'b0;
            ent_is_load[0]    <= 1'b0;
            ent_is_load[1]    <= 1'b0;
            ent_is_store[0]   <= 1'b0;
            ent_is_store[1]   <= 1'b0;
            ent_epoch[0]      <= 2'd0;
            ent_epoch[1]      <= 2'd0;
            ent_issued[0]     <= 1'b0;
            ent_issued[1]     <= 1'b0;
            ent_committed[0]  <= 1'b0;
            ent_committed[1]  <= 1'b0;
            req_active        <= 1'b0;
            req_we_q          <= 1'b0;
            req_addr_q        <= 32'd0;
            req_wdata_q       <= 32'd0;
            req_be_q          <= 4'd0;
            req_rob_q         <= 4'd0;
            req_epoch_q       <= 2'd0;
        end else begin
            ent_rs1_ready[0] <= head_rs1_next;
            ent_rs2_ready[0] <= head_rs2_next;
            ent_rs1_ready[1] <= tail_rs1_next;
            ent_rs2_ready[1] <= tail_rs2_next;

            if (store_commit_match_head) ent_committed[0] <= 1'b1;
            if (store_commit_match_tail) ent_committed[1] <= 1'b1;

            if (head_issue_fire) begin
                ent_issued[0]    <= 1'b1;
            end
            if (head_resp_fire || head_resp_stale) begin
                ent_issued[0] <= 1'b0;
            end
            if (head_resp_stale) begin
                ent_epoch[0]  <= flush_epoch;
            end

            if (!req_active) begin
                if (head_can_issue && !lsu_dcache_req_ready) begin
                    req_active  <= 1'b1;
                    req_we_q    <= ent_is_store[0];
                    req_addr_q  <= head_addr;
                    req_wdata_q <= head_wdata;
                    req_be_q    <= head_be;
                    req_rob_q   <= ent_rob[0];
                    req_epoch_q <= ent_epoch[0];
                end
            end else begin
                if (lsu_dcache_req_ready) begin
                    req_active <= 1'b0;
                end
            end

            if (head_remove) begin
                if (ent_valid[1] && !tail_remove) begin
                    ent_valid[0]      <= 1'b1;
                    ent_insn[0]       <= ent_insn[1];
                    ent_rob[0]        <= ent_rob[1];
                    ent_prs1[0]       <= ent_prs1[1];
                    ent_prs2[0]       <= ent_prs2[1];
                    ent_pdst[0]       <= ent_pdst[1];
                    ent_is_load[0]    <= ent_is_load[1];
                    ent_is_store[0]   <= ent_is_store[1];
                    ent_epoch[0]      <= ent_epoch[1];
                    ent_issued[0]     <= ent_issued[1];
                    ent_committed[0]  <= ent_committed[1] |
                                         store_commit_match_tail;
                    ent_valid[1]      <= 1'b0;
                end else begin
                    ent_valid[0]      <= 1'b0;
                    ent_valid[1]      <= 1'b0;
                end
            end else if (tail_remove) begin
                ent_valid[1] <= 1'b0;
            end

            if (disp_to_head) begin
                ent_valid[0]      <= 1'b1;
                ent_insn[0]       <= lsu_disp_insn;
                ent_rob[0]        <= lsu_disp_rob_index;
                ent_prs1[0]       <= lsu_disp_prs1;
                ent_prs2[0]       <= lsu_disp_prs2;
                ent_pdst[0]       <= lsu_disp_pdst;
                ent_is_load[0]    <= lsu_disp_is_load;
                ent_is_store[0]   <= lsu_disp_is_store;
                ent_epoch[0]      <= flush_epoch;
                ent_issued[0]     <= 1'b0;
                ent_committed[0]  <= lsu_disp_is_store && store_commit_valid &&
                                     (store_commit_rob_index ==
                                      lsu_disp_rob_index);
            end else if (disp_to_tail) begin
                ent_valid[1]      <= 1'b1;
                ent_insn[1]       <= lsu_disp_insn;
                ent_rob[1]        <= lsu_disp_rob_index;
                ent_prs1[1]       <= lsu_disp_prs1;
                ent_prs2[1]       <= lsu_disp_prs2;
                ent_pdst[1]       <= lsu_disp_pdst;
                ent_is_load[1]    <= lsu_disp_is_load;
                ent_is_store[1]   <= lsu_disp_is_store;
                ent_epoch[1]      <= flush_epoch;
                ent_issued[1]     <= 1'b0;
                ent_committed[1]  <= lsu_disp_is_store && store_commit_valid &&
                                     (store_commit_rob_index ==
                                      lsu_disp_rob_index);
            end
        end
    end

endmodule
