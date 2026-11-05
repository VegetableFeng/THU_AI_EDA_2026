module icache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        flush,
    input  logic [1:0]  flush_epoch,
    input  logic        cpu_req_valid,
    input  logic [31:0] cpu_req_addr,
    output logic        cpu_req_ready,
    output logic        cpu_resp_valid,
    output logic [31:0] cpu_resp_data,
    output logic        mem_req_valid,
    output logic [31:0] mem_req_addr,
    input  logic        mem_req_ready,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data
);

    localparam logic [1:0] S_IDLE   = 2'd0;
    localparam logic [1:0] S_REFILL = 2'd1;

    logic [31:0]  tag_arr   [0:15];
    logic [127:0] data_arr  [0:15];
    logic         valid_arr [0:15];

    logic [1:0]   state;
    logic [1:0]   refill_cnt;
    logic [31:0]  refill_base;
    logic [31:0]  refill_tag;
    logic [3:0]   refill_idx;
    logic [1:0]   refill_epoch;
    logic [127:0] refill_data;
    logic [1:0]   refill_word;

    logic         resp_valid_r;
    logic         frozen;   // halt 后完成当前字即冻结，不再取后续 refill 字
    logic [31:0]  resp_data_r;

    logic [3:0]   req_idx;
    logic [31:0]  req_tag;
    logic [1:0]   req_word;
    logic         hit;
    logic [31:0]  hit_data;

    assign req_idx  = cpu_req_addr[7:4];
    assign req_tag  = cpu_req_addr[31:8];
    assign req_word = cpu_req_addr[3:2];

    assign hit = valid_arr[req_idx] && (tag_arr[req_idx] == req_tag);

    always_comb begin
        hit_data = 32'b0;
        case (req_word)
            2'd0: hit_data = data_arr[req_idx][31:0];
            2'd1: hit_data = data_arr[req_idx][63:32];
            2'd2: hit_data = data_arr[req_idx][95:64];
            2'd3: hit_data = data_arr[req_idx][127:96];
            default: hit_data = 32'b0;
        endcase
    end

    assign cpu_req_ready = rst_n && !halted && (state == S_IDLE) && !resp_valid_r;

    // 外部请求一经发出必须保持到握手完成（tb 要求等待期间 valid/addr 稳定），
    // halted 只能抑制响应与接收，不能撤在途 refill
    assign mem_req_valid = rst_n && (state == S_REFILL) && !frozen;
    assign mem_req_addr  = refill_base + {refill_cnt, 2'b00};

    assign cpu_resp_valid = resp_valid_r;
    assign cpu_resp_data  = resp_data_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            refill_cnt   <= 2'd0;
            refill_base  <= 32'b0;
            refill_tag   <= 32'b0;
            refill_idx   <= 4'b0;
            refill_epoch <= 2'b0;
            refill_data  <= 128'b0;
            refill_word  <= 2'b0;
            resp_valid_r <= 1'b0;
            resp_data_r  <= 32'b0;
            frozen       <= 1'b0;
            for (int i = 0; i < 16; i = i + 1) begin
                valid_arr[i] <= 1'b0;
                tag_arr[i]   <= 32'b0;
                data_arr[i]  <= 128'b0;
            end
        end else if (halted && (state != S_REFILL)) begin
            // 无在途 refill 时才冻结；有 refill 则走正常分支完成握手
            resp_valid_r <= 1'b0;
        end else begin
            resp_valid_r <= 1'b0;

            // flush 不能打断已经发出的外部 refill 请求，否则 imem_addr/
            // imem_valid 会在 imem_ready 前变化。让 refill 完成，仅通过
            // refill_epoch 丢弃过期数据。
            case (state)
                S_IDLE: begin
                    if (cpu_req_valid && cpu_req_ready) begin
                        if (hit) begin
                            resp_valid_r <= 1'b1;
                            resp_data_r  <= hit_data;
                        end else begin
                            state        <= S_REFILL;
                            refill_cnt   <= 2'd0;
                            refill_base  <= {cpu_req_addr[31:4], 4'b0000};
                            refill_tag   <= req_tag;
                            refill_idx   <= req_idx;
                            refill_epoch <= flush_epoch;
                            refill_data  <= 128'b0;
                            refill_word  <= req_word;
                        end
                    end
                end
                S_REFILL: begin
                    if (mem_req_valid && mem_req_ready) begin
                        case (refill_cnt)
                            2'd0: refill_data[31:0]   <= mem_resp_data;
                            2'd1: refill_data[63:32]  <= mem_resp_data;
                            2'd2: refill_data[95:64]  <= mem_resp_data;
                            2'd3: refill_data[127:96] <= mem_resp_data;
                            default: ;
                        endcase
                        if (refill_cnt == 2'd3) begin
                            // 即使期间发生 redirect，也把有效行安装进 I-Cache；
                            // 仅抑制过期 refill 的响应。否则每次分支都会丢掉
                            // 正在填充的行，循环永远无法 reuse。
                            valid_arr[refill_idx] <= 1'b1;
                            tag_arr[refill_idx]   <= refill_tag;
                            data_arr[refill_idx]  <= refill_data |
                                ({96'b0, mem_resp_data} << {refill_cnt, 5'b00000});
                            if (flush_epoch == refill_epoch && !halted) begin
                                resp_valid_r <= 1'b1;
                                case (refill_word)
                                    2'd0: resp_data_r <= refill_data[31:0];
                                    2'd1: resp_data_r <= refill_data[63:32];
                                    2'd2: resp_data_r <= refill_data[95:64];
                                    default: resp_data_r <= mem_resp_data;
                                endcase
                            end
                            state <= S_IDLE;
                        end else if (halted) begin
                            // 停机：当前字握手已完成，冻结在此，不再取后续字
                            frozen <= 1'b1;
                        end else begin
                            refill_cnt <= refill_cnt + 2'd1;
                        end
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
