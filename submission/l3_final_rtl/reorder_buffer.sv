module reorder_buffer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        rob_alloc_valid,
    output logic        rob_alloc_ready,
    output logic [3:0]  rob_alloc_index,
    input  logic [31:0] rob_alloc_pc,
    input  logic [31:0] rob_alloc_insn,
    input  logic [5:0]  rob_alloc_pdst,
    input  logic [5:0]  rob_alloc_old_prd,
    input  logic [4:0]  rob_alloc_arch_rd,
    input  logic        rob_alloc_is_control,
    input  logic        rob_alloc_is_store,
    input  logic        rob_alloc_is_ecall,
    input  logic        rob_alloc_reg_write,
    output logic [3:0]  rob_head_index,
    input  logic        alu_complete_valid,
    input  logic [3:0]  alu_complete_rob_index,
    input  logic [31:0] alu_complete_data,
    input  logic        load_complete_valid,
    input  logic [3:0]  load_complete_rob_index,
    input  logic [31:0] load_complete_data,
    input  logic        resolve_valid,
    input  logic [3:0]  resolve_rob_index,
    input  logic        resolve_mispredict,
    input  logic [31:0] resolve_actual_next_pc,
    output logic        store_commit_valid,
    output logic [3:0]  store_commit_rob_index,
    input  logic        store_done_valid,
    input  logic [3:0]  store_done_rob_index,
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic [31:0] commit_value,
    output logic [4:0]  commit_arch_rd,
    output logic        commit_reg_write,
    output logic        commit_is_ecall,
    output logic        commit_old_prd_valid,
    output logic [5:0]  commit_old_prd,
    output logic        flush_valid,
    output logic [3:0]  flush_rob_index,
    output logic [31:0] flush_pc,
    output logic        ecall_pending
);

    localparam integer ROB_DEPTH = 8;

    logic [3:0] head;
    logic [3:0] tail;
    logic [3:0] count;

    logic        ent_valid    [0:7];
    logic [3:0]  ent_index    [0:7];
    logic        ent_complete [0:7];
    logic        ent_is_store [0:7];
    logic        ent_is_ecall [0:7];
    logic        ent_is_ctrl  [0:7];
    logic        ent_store_done [0:7];
    logic [31:0] ent_pc     [0:7];
    logic [31:0] ent_insn   [0:7];
    logic [31:0] ent_value  [0:7];
    logic [4:0]  ent_arch_rd[0:7];
    logic        ent_reg_write [0:7];

    logic [2:0] head_slot;
    logic [2:0] tail_slot;
    assign head_slot = head[2:0];
    assign tail_slot = tail[2:0];

    logic [3:0] tail_plus1;
    logic [3:0] head_plus1;
    logic       alloc_fire;
    logic       full;
    logic       empty;

    logic       head_valid;
    logic       head_complete;
    logic       head_is_store;
    logic       head_is_ecall;
    logic       head_store_done;
    logic       head_ready;
    logic       commit_fire;
    logic       commit_pop;

    logic       flush_fire;
    logic [3:0] flush_idx4;
    logic [3:0] flush_next4;
    logic [3:0] flush_pos4;
    logic [3:0] flush_keep4;
    logic [3:0] flush_cnt4;

    logic       pending_flush;
    logic [3:0] pending_flush_idx;
    logic [31:0] pending_flush_pc;

    integer ec_i;
    integer sq_i;

    assign tail_plus1 = tail + 4'd1;
    assign head_plus1 = head + 4'd1;
    assign full  = (count == 4'd8);
    assign empty = (count == 4'd0);

    assign alloc_fire = rob_alloc_valid && rob_alloc_ready;
    assign rob_alloc_ready = rst_n && !halted && !full && !ecall_pending && !flush_fire;
    assign rob_alloc_index = tail;

    assign rob_head_index = head;

    assign head_valid      = ent_valid[head_slot];
    assign head_complete   = ent_complete[head_slot];
    assign head_is_store   = ent_is_store[head_slot];
    assign head_is_ecall   = ent_is_ecall[head_slot];
    assign head_store_done = ent_store_done[head_slot];

    assign head_ready = head_valid && head_complete &&
                        (!head_is_store || head_store_done);

    assign commit_fire = head_ready && !halted && !flush_fire;

    assign commit_pop = commit_fire && !head_is_ecall;

    assign commit_valid      = commit_fire;
    assign commit_pc         = ent_pc[head_slot];
    assign commit_insn       = ent_insn[head_slot];
    assign commit_value      = ent_value[head_slot];
    assign commit_arch_rd    = ent_arch_rd[head_slot];
    assign commit_reg_write  = ent_reg_write[head_slot];
    assign commit_is_ecall   = ent_is_ecall[head_slot];
    assign commit_old_prd_valid = ent_reg_write[head_slot];
    assign commit_old_prd    = 6'd0;

    assign store_commit_valid     = head_valid && head_is_store && !halted && !flush_fire;
    assign store_commit_rob_index = head;

    assign flush_fire = pending_flush && !halted;
    assign flush_idx4 = pending_flush_idx;
    assign flush_next4 = flush_idx4 + 4'd1;
    assign flush_pos4 = flush_idx4 - head;
    assign flush_keep4 = flush_pos4 + 4'd1;
    assign flush_cnt4 = count - flush_keep4;
    assign flush_valid = flush_fire;
    assign flush_rob_index = flush_idx4;
    assign flush_pc = pending_flush_pc;

    always_comb begin
        ecall_pending = 1'b0;
        for (ec_i = 0; ec_i < 8; ec_i = ec_i + 1) begin
            if (ent_valid[ec_i] && ent_is_ecall[ec_i]) begin
                ecall_pending = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= 4'd0;
            tail <= 4'd0;
            count <= 4'd0;
            pending_flush <= 1'b0;
            pending_flush_idx <= 4'd0;
            pending_flush_pc <= 32'd0;
            for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                ent_valid[sq_i]          <= 1'b0;
                ent_index[sq_i]          <= 4'd0;
                ent_complete[sq_i]       <= 1'b0;
                ent_is_store[sq_i]       <= 1'b0;
                ent_is_ecall[sq_i]       <= 1'b0;
                ent_is_ctrl[sq_i]        <= 1'b0;
                ent_store_done[sq_i]     <= 1'b0;
                ent_pc[sq_i]             <= 32'd0;
                ent_insn[sq_i]           <= 32'd0;
                ent_value[sq_i]          <= 32'd0;
                ent_arch_rd[sq_i]        <= 5'd0;
                ent_reg_write[sq_i]      <= 1'b0;
            end
        end else if (halted) begin
            head  <= head;
            tail  <= tail;
            count <= count;
            pending_flush <= pending_flush;
            pending_flush_idx <= pending_flush_idx;
            pending_flush_pc <= pending_flush_pc;
        end else begin
            if (flush_fire) begin
                for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                    if ({1'b0, (sq_i[2:0] - flush_next4[2:0])} < flush_cnt4) begin
                        ent_valid[sq_i]          <= 1'b0;
                        ent_complete[sq_i]       <= 1'b0;
                        ent_is_store[sq_i]       <= 1'b0;
                        ent_is_ecall[sq_i]       <= 1'b0;
                        ent_is_ctrl[sq_i]        <= 1'b0;
                        ent_store_done[sq_i]     <= 1'b0;
                    end
                end
                tail <= flush_next4;
                count <= flush_keep4;
                pending_flush <= 1'b0;
            end else begin
                if (commit_pop) begin
                    for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                        if (head_slot == sq_i[2:0]) begin
                            ent_valid[sq_i]          <= 1'b0;
                            ent_complete[sq_i]       <= 1'b0;
                            ent_is_store[sq_i]       <= 1'b0;
                            ent_is_ecall[sq_i]       <= 1'b0;
                            ent_is_ctrl[sq_i]        <= 1'b0;
                            ent_store_done[sq_i]     <= 1'b0;
                        end
                    end
                    head <= head_plus1;
                end

                if (alloc_fire) begin
                    for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                        if (tail_slot == sq_i[2:0]) begin
                            ent_valid[sq_i]           <= 1'b1;
                            ent_index[sq_i]           <= tail;
                            ent_complete[sq_i]        <= rob_alloc_is_ecall;
                            ent_is_store[sq_i]        <= rob_alloc_is_store;
                            ent_is_ecall[sq_i]        <= rob_alloc_is_ecall;
                            ent_is_ctrl[sq_i]         <= rob_alloc_is_control;
                            ent_store_done[sq_i]      <= 1'b0;
                            ent_pc[sq_i]              <= rob_alloc_pc;
                            ent_insn[sq_i]            <= rob_alloc_insn;
                            ent_value[sq_i]           <= 32'd0;
                            ent_arch_rd[sq_i]         <= rob_alloc_arch_rd;
                            ent_reg_write[sq_i]       <= rob_alloc_reg_write;
                        end
                    end
                    tail <= tail_plus1;
                end

                if (commit_pop && alloc_fire) begin
                    count <= count;
                end else if (commit_pop) begin
                    count <= count - 4'd1;
                end else if (alloc_fire) begin
                    count <= count + 4'd1;
                end
            end

            if (alu_complete_valid) begin
                for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                    if (alu_complete_rob_index[2:0] == sq_i[2:0]) begin
                        if (ent_valid[sq_i] &&
                            (ent_index[sq_i] == alu_complete_rob_index)) begin
                            ent_complete[sq_i] <= 1'b1;
                            ent_value[sq_i]    <= alu_complete_data;
                        end
                    end
                end
            end

            if (load_complete_valid) begin
                for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                    if (load_complete_rob_index[2:0] == sq_i[2:0]) begin
                        if (ent_valid[sq_i] &&
                            (ent_index[sq_i] == load_complete_rob_index)) begin
                            ent_complete[sq_i] <= 1'b1;
                            ent_value[sq_i]    <= load_complete_data;
                        end
                    end
                end
            end

            if (store_done_valid) begin
                for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                    if (store_done_rob_index[2:0] == sq_i[2:0]) begin
                        if (ent_valid[sq_i] &&
                            (ent_index[sq_i] == store_done_rob_index)) begin
                            ent_store_done[sq_i] <= 1'b1;
                            ent_complete[sq_i]   <= 1'b1;
                        end
                    end
                end
            end

            if (resolve_valid && !flush_fire) begin
                for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                    if (resolve_rob_index[2:0] == sq_i[2:0]) begin
                        if (ent_valid[sq_i] &&
                            (ent_index[sq_i] == resolve_rob_index) &&
                            ent_is_ctrl[sq_i]) begin
                            if (resolve_mispredict && !pending_flush) begin
                                pending_flush     <= 1'b1;
                                pending_flush_idx <= resolve_rob_index;
                                pending_flush_pc  <= resolve_actual_next_pc;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
