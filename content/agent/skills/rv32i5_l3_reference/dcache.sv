module dcache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        flush,
    input  logic [1:0]  flush_epoch,
    input  logic        cpu_req_valid,
    input  logic        cpu_req_we,
    input  logic [31:0] cpu_req_addr,
    input  logic [31:0] cpu_req_wdata,
    input  logic [3:0]  cpu_req_be,
    output logic        cpu_req_ready,
    output logic        cpu_resp_valid,
    output logic [31:0] cpu_resp_rdata,
    output logic        mem_req_valid,
    output logic        mem_req_we,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_wdata,
    output logic [3:0]  mem_req_be,
    input  logic        mem_req_ready,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data
);

    localparam logic [1:0] S_IDLE  = 2'd0;
    localparam logic [1:0] S_REFILL = 2'd1;
    localparam logic [1:0] S_WT     = 2'd2;
    localparam logic [1:0] S_RESP   = 2'd3;

    logic [1:0]  state;
    logic [127:0] data_arr [0:15];
    logic [23:0]  tag_arr  [0:15];
    logic [15:0]  valid_arr;

    logic [3:0]  idx;
    logic [23:0] tag;
    logic [1:0]  wsel;
    logic        hit;
    logic [127:0] line_data;
    logic [31:0] hit_word;

    logic [1:0]  refill_cnt;
    logic [31:0] refill_base;
    logic [23:0] refill_tag;
    logic [3:0]  refill_idx;
    logic [127:0] refill_data;
    logic [1:0]  refill_epoch;
    logic [1:0]  refill_word;

    logic [31:0] store_word;

    logic [31:0] wt_addr;
    logic [31:0] wt_wdata;
    logic [3:0]  wt_be;
    logic [1:0]  wt_epoch;

    logic [31:0] resp_rdata;

    logic        req_is_store;
    logic        req_hit;
    logic        req_miss;
    logic        req_accept;

    assign idx  = cpu_req_addr[7:4];
    assign tag  = cpu_req_addr[31:8];
    assign wsel = cpu_req_addr[3:2];

    assign hit = valid_arr[idx] && (tag_arr[idx] == tag);
    assign line_data = data_arr[idx];
    assign hit_word = line_data[{wsel, 5'b00000} +: 32];

    always_comb begin
        store_word = hit_word;
        if (cpu_req_be[0]) store_word[7:0]   = cpu_req_wdata[7:0];
        if (cpu_req_be[1]) store_word[15:8]  = cpu_req_wdata[15:8];
        if (cpu_req_be[2]) store_word[23:16] = cpu_req_wdata[23:16];
        if (cpu_req_be[3]) store_word[31:24] = cpu_req_wdata[31:24];
    end

    assign req_is_store = cpu_req_we;
    assign req_hit  = hit;
    assign req_miss = !hit;
    assign req_accept = cpu_req_valid && cpu_req_ready;

    always_comb begin
        cpu_req_ready = 1'b0;
        if (rst_n && !halted) begin
            case (state)
                S_IDLE:  cpu_req_ready = 1'b1;
                S_RESP:  cpu_req_ready = 1'b1;
                default: cpu_req_ready = 1'b0;
            endcase
        end
    end

    always_comb begin
        mem_req_valid = 1'b0;
        mem_req_we    = 1'b0;
        mem_req_addr  = 32'b0;
        mem_req_wdata = 32'b0;
        mem_req_be    = 4'b0000;
        if (rst_n) begin
            case (state)
                S_REFILL: begin
                    mem_req_valid = 1'b1;
                    mem_req_we    = 1'b0;
                    mem_req_addr  = refill_base + {refill_cnt, 2'b00};
                    mem_req_wdata = 32'b0;
                    mem_req_be    = 4'b0000;
                end
                S_WT: begin
                    mem_req_valid = 1'b1;
                    mem_req_we    = 1'b1;
                    mem_req_addr  = wt_addr;
                    mem_req_wdata = wt_wdata;
                    mem_req_be    = wt_be;
                end
                default: begin
                    mem_req_valid = 1'b0;
                end
            endcase
        end
    end

    always_comb begin
        cpu_resp_valid = 1'b0;
        cpu_resp_rdata = resp_rdata;
        if (rst_n && !halted && (state == S_RESP)) begin
            cpu_resp_valid = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            valid_arr    <= 16'b0;
            refill_cnt   <= 2'd0;
            refill_base  <= 32'b0;
            refill_tag   <= 24'b0;
            refill_idx   <= 4'b0;
            refill_data  <= 128'b0;
            refill_epoch <= 2'b0;
            refill_word  <= 2'b0;
            wt_addr      <= 32'b0;
            wt_wdata     <= 32'b0;
            wt_be        <= 4'b0;
            wt_epoch     <= 2'b0;
            resp_rdata   <= 32'b0;
        end else if (halted && (state != S_REFILL) && (state != S_WT)) begin
            // 无在途外部请求时才回 IDLE；refill/write-through 继续完成握手
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_accept) begin
                        if (req_is_store) begin
                            if (req_hit) begin
                                data_arr[idx] <= (line_data & ~(128'hFFFFFFFF << {wsel, 5'b00000})) |
                                                 ({96'b0, store_word} << {wsel, 5'b00000});
                                wt_addr  <= cpu_req_addr;
                                wt_wdata <= cpu_req_wdata;
                                wt_be    <= cpu_req_be;
                                wt_epoch <= flush_epoch;
                                state    <= S_WT;
                            end else begin
                                refill_base  <= {cpu_req_addr[31:4], 4'b0000};
                                refill_tag   <= tag;
                                refill_idx   <= idx;
                                refill_word  <= wsel;
                                refill_cnt   <= 2'd0;
                                refill_data  <= 128'b0;
                                refill_epoch <= flush_epoch;
                                wt_addr      <= cpu_req_addr;
                                wt_wdata     <= cpu_req_wdata;
                                wt_be        <= cpu_req_be;
                                wt_epoch     <= flush_epoch;
                                state        <= S_REFILL;
                            end
                        end else begin
                            if (req_hit) begin
                                resp_rdata <= hit_word;
                                state      <= S_RESP;
                            end else begin
                                refill_base  <= {cpu_req_addr[31:4], 4'b0000};
                                refill_tag   <= tag;
                                refill_idx   <= idx;
                                refill_word  <= wsel;
                                refill_cnt   <= 2'd0;
                                refill_data  <= 128'b0;
                                refill_epoch <= flush_epoch;
                                state        <= S_REFILL;
                            end
                        end
                    end
                end

                S_REFILL: begin
                    if (mem_req_valid && mem_req_ready) begin
                        refill_data[{refill_cnt, 5'b00000} +: 32] <= mem_resp_data;
                        if (refill_cnt == 2'd3) begin
                            if (req_is_store) begin
                                // Write-through, no-write-allocate: 外部写完成
                                // 后让该行失效，后续 load 从 DMEM 重新 refill，
                                // 避免旧 hit_word 污染 line 中未写字节。
                                data_arr[refill_idx]  <= refill_data |
                                    ({96'b0, mem_resp_data} << {refill_cnt, 5'b00000});
                                tag_arr[refill_idx]   <= refill_tag;
                                valid_arr[refill_idx] <= 1'b0;
                            end else begin
                                data_arr[refill_idx]  <= refill_data |
                                    ({96'b0, mem_resp_data} << {refill_cnt, 5'b00000});
                                tag_arr[refill_idx]   <= refill_tag;
                                valid_arr[refill_idx] <= 1'b1;
                            end
                            if (req_is_store) begin
                                wt_epoch <= flush_epoch;
                                state    <= S_WT;
                            end else begin
                                // 返回请求字而不是 refill 的最后一个字。
                                case (wsel)
                                    2'd0: resp_rdata <= refill_data[31:0];
                                    2'd1: resp_rdata <= refill_data[63:32];
                                    2'd2: resp_rdata <= refill_data[95:64];
                                    default: resp_rdata <= mem_resp_data;
                                endcase
                                state      <= S_RESP;
                            end
                        end else begin
                            refill_cnt <= refill_cnt + 2'd1;
                        end
                    end
                end

                S_WT: begin
                    if (mem_req_valid && mem_req_ready) begin
                        resp_rdata <= 32'b0;
                        state      <= S_RESP;
                    end
                end

                S_RESP: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
