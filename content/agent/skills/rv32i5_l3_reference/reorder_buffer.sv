module reorder_buffer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        rob_alloc_valid,
    output logic        rob_alloc_ready,
    input  logic [31:0] rob_alloc_pc,
    input  logic [31:0] rob_alloc_instr,
    input  logic [4:0]  rob_alloc_arch_rd,
    input  logic [5:0]  rob_alloc_new_prd,
    input  logic [5:0]  rob_alloc_old_prd,
    input  logic        rob_alloc_has_dest,
    input  logic        rob_alloc_is_load,
    input  logic        rob_alloc_is_store,
    input  logic        rob_alloc_is_branch,
    input  logic        rob_alloc_is_jump,
    input  logic        rob_alloc_is_ecall,
    output logic [2:0]  rob_alloc_idx,
    input  logic        complete_valid,
    input  logic [2:0]  complete_rob_idx,
    input  logic [31:0] complete_data,
    input  logic        lsu_complete_valid,
    input  logic [2:0]  lsu_complete_rob_idx,
    input  logic [31:0] lsu_complete_data,
    input  logic        squash_valid,
    input  logic [2:0]  squash_rob_idx,
    output logic        rob_commit_valid,
    output logic [2:0]  rob_commit_idx,
    output logic [31:0] rob_commit_pc,
    output logic [31:0] rob_commit_instr,
    output logic [4:0]  rob_commit_arch_rd,
    output logic [5:0]  rob_commit_new_prd,
    output logic [5:0]  rob_commit_old_prd,
    output logic        rob_commit_has_dest,
    output logic        rob_commit_is_store,
    output logic        rob_commit_is_ecall,
    output logic        rob_commit_is_branch,
    output logic        rob_commit_is_jump,
    output logic [31:0] rob_commit_data,
    output logic        rob_head_valid,
    output logic [2:0]  rob_head_idx,
    output logic        rob_head_is_store,
    output logic        rob_head_complete,
    output logic        halted,
    output logic [31:0] exit_code,
    input  logic [31:0] x10_value,
    output logic [2:0]  rob_tail_out
);

    localparam int DEPTH = 8;

    logic [31:0] ent_pc    [0:DEPTH-1];
    logic [31:0] ent_instr [0:DEPTH-1];
    logic [4:0]  ent_arch_rd [0:DEPTH-1];
    logic [5:0]  ent_new_prd [0:DEPTH-1];
    logic [5:0]  ent_old_prd [0:DEPTH-1];
    logic        ent_has_dest [0:DEPTH-1];
    logic        ent_is_load  [0:DEPTH-1];
    logic        ent_is_store [0:DEPTH-1];
    logic        ent_is_branch[0:DEPTH-1];
    logic        ent_is_jump  [0:DEPTH-1];
    logic        ent_is_ecall [0:DEPTH-1];
    logic        ent_valid   [0:DEPTH-1];
    logic        ent_complete[0:DEPTH-1];
    logic [31:0] ent_data    [0:DEPTH-1];

    logic [2:0] head;
    logic [2:0] tail;
    logic [3:0] count;

    logic       halted_r;
    logic [31:0] exit_code_r;
    logic [31:0] exit_code_pend;
    logic       halt_pending;

    logic       head_valid;
    logic       head_complete;
    logic       head_is_store;
    logic       head_is_ecall;
    logic       head_ready;
    logic       do_retire;
    logic       do_alloc;
    logic       do_squash;

    assign rob_alloc_idx = tail;
    assign rob_tail_out  = tail;

    assign head_valid    = ent_valid[head];
    assign head_complete = ent_complete[head];
    assign head_is_store = ent_is_store[head];
    assign head_is_ecall = ent_is_ecall[head];

    assign head_ready = head_valid && head_complete && !halted_r && !halt_pending;

    assign do_retire = head_ready;
    assign do_alloc  = rob_alloc_valid && rob_alloc_ready;
    assign do_squash = squash_valid && !halted_r;

    assign rob_alloc_ready = !halted_r && !halt_pending && (count < DEPTH[3:0]);

    assign rob_commit_valid    = do_retire;
    assign rob_commit_idx      = head;
    assign rob_commit_pc       = ent_pc[head];
    assign rob_commit_instr    = ent_instr[head];
    assign rob_commit_arch_rd  = ent_arch_rd[head];
    assign rob_commit_new_prd  = ent_new_prd[head];
    assign rob_commit_old_prd  = ent_old_prd[head];
    assign rob_commit_has_dest = ent_has_dest[head];
    assign rob_commit_is_store = ent_is_store[head];
    assign rob_commit_is_ecall = ent_is_ecall[head];
    assign rob_commit_is_branch= ent_is_branch[head];
    assign rob_commit_is_jump  = ent_is_jump[head];
    assign rob_commit_data     = ent_data[head];

    assign rob_head_valid    = head_valid;
    assign rob_head_idx      = head;
    assign rob_head_is_store = head_is_store;
    assign rob_head_complete = head_complete;

    assign halted    = halted_r;
    assign exit_code = exit_code_r;

    integer i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head         <= 3'd0;
            tail         <= 3'd0;
            count        <= 4'd0;
            halted_r     <= 1'b0;
            exit_code_r  <= 32'd0;
            exit_code_pend <= 32'd0;
            halt_pending <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                ent_pc[i]       <= 32'd0;
                ent_instr[i]    <= 32'd0;
                ent_arch_rd[i]  <= 5'd0;
                ent_new_prd[i]  <= 6'd0;
                ent_old_prd[i]  <= 6'd0;
                ent_has_dest[i] <= 1'b0;
                ent_is_load[i]  <= 1'b0;
                ent_is_store[i] <= 1'b0;
                ent_is_branch[i]<= 1'b0;
                ent_is_jump[i]  <= 1'b0;
                ent_is_ecall[i] <= 1'b0;
                ent_valid[i]    <= 1'b0;
                ent_complete[i] <= 1'b0;
                ent_data[i]     <= 32'd0;
            end
        end else if (halted_r) begin
            head         <= head;
            tail         <= tail;
            count        <= count;
            halted_r     <= 1'b1;
            exit_code_r  <= exit_code_r;
            halt_pending <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                ent_pc[i]       <= ent_pc[i];
                ent_instr[i]    <= ent_instr[i];
                ent_arch_rd[i]  <= ent_arch_rd[i];
                ent_new_prd[i]  <= ent_new_prd[i];
                ent_old_prd[i]  <= ent_old_prd[i];
                ent_has_dest[i] <= ent_has_dest[i];
                ent_is_load[i]  <= ent_is_load[i];
                ent_is_store[i] <= ent_is_store[i];
                ent_is_branch[i]<= ent_is_branch[i];
                ent_is_jump[i]  <= ent_is_jump[i];
                ent_is_ecall[i] <= ent_is_ecall[i];
                ent_valid[i]    <= ent_valid[i];
                ent_complete[i] <= ent_complete[i];
                ent_data[i]     <= ent_data[i];
            end
        end else begin
            if (halt_pending) begin
                halted_r     <= 1'b1;
                exit_code_r  <= exit_code_pend;
                halt_pending <= 1'b0;
            end

            if (complete_valid) begin
                ent_complete[complete_rob_idx] <= 1'b1;
                ent_data[complete_rob_idx]     <= complete_data;
            end

            if (lsu_complete_valid) begin
                ent_complete[lsu_complete_rob_idx] <= 1'b1;
                ent_data[lsu_complete_rob_idx]     <= lsu_complete_data;
            end

            if (do_squash) begin
                // 冲刷环形开区间 (squash_rob_idx, tail)：3-bit 减法自动 mod 8，
                // 修复环绕时年轻表项（如分支在 slot7、年轻者在 slot0）漏杀
                for (i = 0; i < DEPTH; i = i + 1) begin
                    if (ent_valid[i] &&
                        (((i - squash_rob_idx - 3'd1) & 3'd7) < ((tail - squash_rob_idx - 3'd1) & 3'd7))) begin
                        ent_valid[i]    <= 1'b0;
                        ent_complete[i] <= 1'b0;
                    end
                end
            end

            if (do_alloc && !do_squash) begin
                ent_pc[tail]       <= rob_alloc_pc;
                ent_instr[tail]    <= rob_alloc_instr;
                ent_arch_rd[tail]  <= rob_alloc_arch_rd;
                ent_new_prd[tail]  <= rob_alloc_new_prd;
                ent_old_prd[tail]  <= rob_alloc_old_prd;
                ent_has_dest[tail] <= rob_alloc_has_dest;
                ent_is_load[tail]  <= rob_alloc_is_load;
                ent_is_store[tail] <= rob_alloc_is_store;
                ent_is_branch[tail]<= rob_alloc_is_branch;
                ent_is_jump[tail]  <= rob_alloc_is_jump;
                ent_is_ecall[tail] <= rob_alloc_is_ecall;
                ent_valid[tail]    <= 1'b1;
                ent_complete[tail] <= 1'b0;
                ent_data[tail]     <= 32'd0;
            end

            if (do_retire) begin
                ent_valid[head]    <= 1'b0;
                ent_complete[head] <= 1'b0;
                if (ent_is_ecall[head]) begin
                    halt_pending   <= 1'b1;
                    // ECALL 提交沿锁存最终 x10（所有更老指令已提交），下一拍与 halted 同时输出
                    exit_code_pend <= x10_value;
                end
            end

            // 指针/计数维护：squash 回卷优先（冲刷 squash_rob_idx 之后的全部表项）
            if (do_squash) begin
                head <= do_retire ? (head + 3'd1) : head;
                tail <= squash_rob_idx + 3'd1;
                // 存活 = head..squash_rob_idx（含），同拍 retire 再减一
                count <= do_retire ? {1'b0, (squash_rob_idx - head)}
                                   : {1'b0, (squash_rob_idx - head)} + 4'd1;
            end else if (do_alloc && !do_retire) begin
                tail  <= tail + 3'd1;
                count <= count + 4'd1;
            end else if (!do_alloc && do_retire) begin
                head  <= head + 3'd1;
                count <= count - 4'd1;
            end else if (do_alloc && do_retire) begin
                head  <= head + 3'd1;
                tail  <= tail + 3'd1;
                count <= count;
            end
        end
    end

endmodule
