module load_store_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        lsq_alloc_valid,
    output logic        lsq_alloc_ready,
    input  logic [2:0]  lsq_alloc_rob_idx,
    input  logic [5:0]  lsq_alloc_prd,
    input  logic        lsq_alloc_has_dest,
    input  logic [5:0]  lsq_alloc_ps1,
    input  logic [5:0]  lsq_alloc_ps2,
    input  logic [31:0] lsq_alloc_imm,
    input  logic        lsq_alloc_mem_read,
    input  logic        lsq_alloc_mem_write,
    input  logic [2:0]  lsq_alloc_funct3,
    input  logic        lsq_alloc_use_rs2,
    output logic        lsq_accept,
    input  logic [39:0] prf_ready,
    output logic [5:0]  lsu_raddr0,
    output logic [5:0]  lsu_raddr1,
    input  logic [31:0] lsu_rdata0,
    input  logic [31:0] lsu_rdata1,
    output logic        lsu_issue_valid,
    input  logic        lsu_issue_ready,
    output logic [2:0]  lsu_issue_rob_idx,
    output logic        cpu_req_valid,
    output logic        cpu_req_we,
    output logic [31:0] cpu_req_addr,
    output logic [31:0] cpu_req_wdata,
    output logic [3:0]  cpu_req_be,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_rdata,
    input  logic        rob_head_valid,
    input  logic        rob_head_is_store,
    input  logic [2:0]  rob_head_idx,
    input  logic        squash_valid,
    input  logic [2:0]  squash_rob_idx,
    input  logic [2:0]  rob_tail_in,
    output logic        lsu_complete_valid,
    output logic [2:0]  lsu_complete_rob_idx,
    output logic [31:0] lsu_complete_data,
    output logic        older_load_pending
);

    localparam logic [2:0] F3_LB  = 3'b000;
    localparam logic [2:0] F3_LH  = 3'b001;
    localparam logic [2:0] F3_LW  = 3'b010;
    localparam logic [2:0] F3_LBU = 3'b100;
    localparam logic [2:0] F3_LHU = 3'b101;
    localparam logic [2:0] F3_SB  = 3'b000;
    localparam logic [2:0] F3_SH  = 3'b001;
    localparam logic [2:0] F3_SW  = 3'b010;

    logic        ent_valid [0:1];
    logic [2:0]  ent_rob   [0:1];
    logic [5:0]  ent_prd   [0:1];
    logic        ent_has_dest [0:1];
    logic [5:0]  ent_ps1   [0:1];
    logic [5:0]  ent_ps2   [0:1];
    logic [31:0] ent_imm   [0:1];
    logic        ent_read  [0:1];
    logic        ent_write [0:1];
    logic [2:0]  ent_funct3[0:1];
    logic        ent_use_rs2 [0:1];
    logic        ent_issued[0:1];
    logic        ent_req_sent [0:1];
    logic        ent_done  [0:1];

    logic        head_sel;
    logic        head_valid;
    logic        head_ready;
    logic        head_is_store;
    logic        head_issued;
    logic        head_req_sent;
    logic        head_done;

    // 2 深 FIFO：显式 head/tail 指针（避免优先级+搬移双机制的 NBA 冲突）
    logic        head_ptr;
    logic        tail_ptr;
    logic [1:0]  lq_count;

    logic        alloc_fire;

    logic        issue_fire;
    logic        start_op;
    logic        req_fire;
    logic        resp_fire;

    logic [31:0] head_addr;
    logic [31:0] head_store_data;
    logic [3:0]  head_be;
    logic [31:0] head_load_data;

    logic        req_active;
    logic [2:0]  req_rob;
    logic        req_we;
    logic [31:0] req_addr;
    logic [31:0] req_wdata;
    logic [3:0]  req_be;

    logic        store_eligible;

    integer i;

    always_comb begin
        head_sel = head_ptr;
        head_valid = ent_valid[head_ptr];
        head_is_store = head_valid ? ent_write[head_ptr] : 1'b0;
        head_issued = head_valid ? ent_issued[head_ptr] : 1'b0;
        head_req_sent = head_valid ? ent_req_sent[head_ptr] : 1'b0;
        head_done = head_valid ? ent_done[head_ptr] : 1'b0;
        head_ready = 1'b0;
        if (head_valid) begin
            if (ent_read[head_ptr]) begin
                head_ready = prf_ready[ent_ps1[head_ptr]];
            end else begin
                head_ready = prf_ready[ent_ps1[head_ptr]] &&
                             (!ent_use_rs2[head_ptr] || prf_ready[ent_ps2[head_ptr]]);
            end
        end
    end

    always_comb begin
        lsq_alloc_ready = rst_n && !halted && (lq_count < 2'd2);
        lsq_accept = lsq_alloc_valid && lsq_alloc_ready;
        alloc_fire = lsq_accept;
    end

    // squash 后存活条目数：从队头起的连续前缀（rob <= squash_rob_idx），
    // 本拍 resp 完成的队头视为已释放
    logic [1:0] surv_cnt;
    wire        sq_younger0 = (((ent_rob[head_ptr]  - squash_rob_idx - 3'd1) & 3'd7) <
                               ((rob_tail_in - squash_rob_idx - 3'd1) & 3'd7));
    wire        sq_younger1 = (((ent_rob[~head_ptr] - squash_rob_idx - 3'd1) & 3'd7) <
                               ((rob_tail_in - squash_rob_idx - 3'd1) & 3'd7));
    always_comb begin
        surv_cnt = 2'd0;
        if (ent_valid[head_ptr] && !sq_younger0 && !resp_fire) begin
            surv_cnt = 2'd1;
            if (lq_count > 2'd1 && ent_valid[~head_ptr] && !sq_younger1) begin
                surv_cnt = 2'd2;
            end
        end
    end

    always_comb begin
        lsu_raddr0 = 6'd0;
        lsu_raddr1 = 6'd0;
        if (head_valid) begin
            lsu_raddr0 = ent_ps1[head_sel];
            lsu_raddr1 = ent_ps2[head_sel];
        end
    end

    always_comb begin
        lsu_issue_valid = 1'b0;
        lsu_issue_rob_idx = 3'd0;
        if (head_valid && !head_issued && head_ready && !halted) begin
            if (!ent_write[head_sel]) begin
                lsu_issue_valid = 1'b1;
                lsu_issue_rob_idx = ent_rob[head_sel];
            end
        end
    end

    always_comb begin
        issue_fire = lsu_issue_valid && lsu_issue_ready;
    end

    always_comb begin
        store_eligible = head_valid && head_is_store && !head_done &&
                         rob_head_valid && rob_head_is_store &&
                         (rob_head_idx == ent_rob[head_sel]);
    end

    always_comb begin
        start_op = 1'b0;
        if (head_valid && !head_req_sent && !head_done && !halted) begin
            if (ent_read[head_sel]) begin
                start_op = head_issued;
            end else begin
                start_op = store_eligible;
            end
        end
    end

    always_comb begin
        head_addr = 32'd0;
        head_store_data = 32'd0;
        head_be = 4'd0;
        if (head_valid) begin
            head_addr = lsu_rdata0 + ent_imm[head_sel];
            head_store_data = lsu_rdata1;
            case (ent_funct3[head_sel])
                F3_SB: begin
                    head_be = 4'b0001 << head_addr[1:0];
                end
                F3_SH: begin
                    head_be = head_addr[1] ? 4'b1100 : 4'b0011;
                end
                default: begin
                    head_be = 4'b1111;
                end
            endcase
        end
    end

    always_comb begin
        cpu_req_valid = 1'b0;
        cpu_req_we = 1'b0;
        cpu_req_addr = 32'd0;
        cpu_req_wdata = 32'd0;
        cpu_req_be = 4'd0;
        if (req_active) begin
            cpu_req_valid = 1'b1;
            cpu_req_we = req_we;
            cpu_req_addr = req_addr;
            cpu_req_wdata = req_wdata;
            cpu_req_be = req_be;
        end else if (start_op) begin
            cpu_req_valid = 1'b1;
            cpu_req_we = ent_write[head_sel];
            cpu_req_addr = head_addr;
            if (ent_write[head_sel]) begin
                case (ent_funct3[head_sel])
                    F3_SB: begin
                        cpu_req_wdata = {4{head_store_data[7:0]}};
                    end
                    F3_SH: begin
                        cpu_req_wdata = {2{head_store_data[15:0]}};
                    end
                    default: begin
                        cpu_req_wdata = head_store_data;
                    end
                endcase
                cpu_req_be = head_be;
            end else begin
                cpu_req_wdata = 32'd0;
                cpu_req_be = 4'd0;
            end
        end
    end

    always_comb begin
        req_fire = cpu_req_valid && cpu_req_ready;
        resp_fire = cpu_resp_valid && req_active;
    end

    always_comb begin
        head_load_data = 32'd0;
        if (head_valid && ent_read[head_sel]) begin
            case (ent_funct3[head_sel])
                F3_LB: begin
                    case (head_addr[1:0])
                        2'd0: head_load_data = {{24{cpu_resp_rdata[7]}},  cpu_resp_rdata[7:0]};
                        2'd1: head_load_data = {{24{cpu_resp_rdata[15]}}, cpu_resp_rdata[15:8]};
                        2'd2: head_load_data = {{24{cpu_resp_rdata[23]}}, cpu_resp_rdata[23:16]};
                        default: head_load_data = {{24{cpu_resp_rdata[31]}}, cpu_resp_rdata[31:24]};
                    endcase
                end
                F3_LH: begin
                    if (head_addr[1]) begin
                        head_load_data = {{16{cpu_resp_rdata[31]}}, cpu_resp_rdata[31:16]};
                    end else begin
                        head_load_data = {{16{cpu_resp_rdata[15]}}, cpu_resp_rdata[15:0]};
                    end
                end
                F3_LW: begin
                    head_load_data = cpu_resp_rdata;
                end
                F3_LBU: begin
                    case (head_addr[1:0])
                        2'd0: head_load_data = {24'd0, cpu_resp_rdata[7:0]};
                        2'd1: head_load_data = {24'd0, cpu_resp_rdata[15:8]};
                        2'd2: head_load_data = {24'd0, cpu_resp_rdata[23:16]};
                        default: head_load_data = {24'd0, cpu_resp_rdata[31:24]};
                    endcase
                end
                F3_LHU: begin
                    if (head_addr[1]) begin
                        head_load_data = {16'd0, cpu_resp_rdata[31:16]};
                    end else begin
                        head_load_data = {16'd0, cpu_resp_rdata[15:0]};
                    end
                end
                default: begin
                    head_load_data = cpu_resp_rdata;
                end
            endcase
        end
    end

    always_comb begin
        lsu_complete_valid = 1'b0;
        lsu_complete_rob_idx = 3'd0;
        lsu_complete_data = 32'd0;
        if (resp_fire) begin
            lsu_complete_valid = 1'b1;
            lsu_complete_rob_idx = req_rob;
            lsu_complete_data = req_we ? 32'd0 : head_load_data;
        end
    end

    always_comb begin
        older_load_pending = 1'b0;
        if (head_valid && ent_read[head_sel] && !head_done) begin
            older_load_pending = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 2; i = i + 1) begin
                ent_valid[i]    <= 1'b0;
                ent_rob[i]      <= 3'd0;
                ent_prd[i]      <= 6'd0;
                ent_has_dest[i] <= 1'b0;
                ent_ps1[i]      <= 6'd0;
                ent_ps2[i]      <= 6'd0;
                ent_imm[i]      <= 32'd0;
                ent_read[i]     <= 1'b0;
                ent_write[i]    <= 1'b0;
                ent_funct3[i]   <= 3'd0;
                ent_use_rs2[i]  <= 1'b0;
                ent_issued[i]   <= 1'b0;
                ent_req_sent[i] <= 1'b0;
                ent_done[i]     <= 1'b0;
            end
            req_active <= 1'b0;
            req_rob    <= 3'd0;
            req_we     <= 1'b0;
            req_addr   <= 32'd0;
            req_wdata  <= 32'd0;
            req_be     <= 4'd0;
            head_ptr   <= 1'b0;
            tail_ptr   <= 1'b0;
            lq_count   <= 2'd0;
        end else if (halted) begin
            req_active <= 1'b0;
        end else begin
            if (req_active) begin
                if (req_fire) begin
                    req_active <= 1'b0;
                end
            end

            if (resp_fire) begin
                // 单次响应即完成：置 done 并释放条目（若读旧值判断会要求二次响应，永堵队头）
                ent_done[head_sel]  <= 1'b1;
                ent_valid[head_sel] <= 1'b0;
            end

            if (issue_fire) begin
                ent_issued[head_sel] <= 1'b1;
            end

            if (start_op && req_fire) begin
                ent_req_sent[head_sel] <= 1'b1;
                req_active <= 1'b1;
                req_rob    <= ent_rob[head_sel];
                req_we     <= ent_write[head_sel];
                req_addr   <= head_addr;
                if (ent_write[head_sel]) begin
                    case (ent_funct3[head_sel])
                        F3_SB: begin
                            req_wdata <= {4{head_store_data[7:0]}};
                        end
                        F3_SH: begin
                            req_wdata <= {2{head_store_data[15:0]}};
                        end
                        default: begin
                            req_wdata <= head_store_data;
                        end
                    endcase
                    req_be <= head_be;
                end else begin
                    req_wdata <= 32'd0;
                    req_be    <= 4'd0;
                end
            end

            if (alloc_fire) begin
                ent_valid[tail_ptr]    <= 1'b1;
                ent_rob[tail_ptr]      <= lsq_alloc_rob_idx;
                ent_prd[tail_ptr]      <= lsq_alloc_prd;
                ent_has_dest[tail_ptr] <= lsq_alloc_has_dest;
                ent_ps1[tail_ptr]      <= lsq_alloc_ps1;
                ent_ps2[tail_ptr]      <= lsq_alloc_ps2;
                ent_imm[tail_ptr]      <= lsq_alloc_imm;
                ent_read[tail_ptr]     <= lsq_alloc_mem_read;
                ent_write[tail_ptr]    <= lsq_alloc_mem_write;
                ent_funct3[tail_ptr]   <= lsq_alloc_funct3;
                ent_use_rs2[tail_ptr]  <= lsq_alloc_use_rs2;
                ent_issued[tail_ptr]   <= 1'b0;
                ent_req_sent[tail_ptr] <= 1'b0;
                ent_done[tail_ptr]     <= 1'b0;
            end

            // squash：冲刷 FIFO 后缀（环形区间，修复 wrap 漏杀）
            if (squash_valid) begin
                for (i = 0; i < 2; i = i + 1) begin
                    if (ent_valid[i] &&
                        (((ent_rob[i] - squash_rob_idx - 3'd1) & 3'd7) <
                         ((rob_tail_in - squash_rob_idx - 3'd1) & 3'd7))) begin
                        ent_valid[i] <= 1'b0;
                    end
                end
            end

            // 指针/计数维护（置于末尾，同拍多事件时以本块为准）
            if (squash_valid) begin
                tail_ptr <= head_ptr ^ surv_cnt[0];
                lq_count <= surv_cnt;
            end else begin
                if (alloc_fire && !resp_fire) begin
                    tail_ptr <= ~tail_ptr;
                    lq_count <= lq_count + 2'd1;
                end else if (!alloc_fire && resp_fire) begin
                    head_ptr <= ~head_ptr;
                    lq_count <= lq_count - 2'd1;
                end else if (alloc_fire && resp_fire) begin
                    tail_ptr <= ~tail_ptr;
                    head_ptr <= ~head_ptr;
                end
            end
        end
    end

endmodule
