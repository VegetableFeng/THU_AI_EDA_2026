module dcache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [1:0]  flush_epoch,
    input  logic [3:0]  flush_rob_index,
    input  logic        halted,
    input  logic        cpu_req_valid,
    input  logic        cpu_req_we,
    input  logic [31:0] cpu_req_addr,
    input  logic [31:0] cpu_req_wdata,
    input  logic [3:0]  cpu_req_be,
    input  logic [3:0]  cpu_req_rob_index,
    input  logic [1:0]  cpu_req_epoch,
    output logic        cpu_req_ready,
    output logic        cpu_resp_valid,
    output logic [31:0] cpu_resp_rdata,
    output logic [1:0]  cpu_resp_epoch,
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic        mem_req_we,
    output logic [31:0] mem_req_addr,
    output logic [31:0] mem_req_wdata,
    output logic [3:0]  mem_req_be,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data,
    output logic        dcache_mem_wait,
    output logic        idle
);

    localparam logic [2:0] ST_IDLE  = 3'd0;
    localparam logic [2:0] ST_REFILL= 3'd1;
    localparam logic [2:0] ST_WT    = 3'd2;
    localparam logic [2:0] ST_RESP  = 3'd3;

    logic [2:0]  state;
    logic [127:0] line_data [0:3];
    logic [25:0]  line_tag  [0:3];
    logic [3:0]   line_valid;

    logic [31:0] req_addr;
    logic [31:0] req_wdata;
    logic [3:0]  req_be;
    logic        req_we;
    logic [3:0]  req_rob;
    logic [1:0]  req_epoch;

    logic [31:0] refill_base;
    logic [1:0]  refill_word;
    logic [127:0] refill_data;
    logic [127:0] refill_data_next;
    logic [25:0] refill_tag;
    logic [1:0]  refill_idx;

    logic [31:0] wt_addr;
    logic [31:0] wt_wdata;
    logic [3:0]  wt_be;

    logic [31:0] resp_rdata;
    logic [1:0]  resp_epoch;

    logic [31:0] lookup_addr;
    logic [1:0]  idx;
    logic [25:0] tag;
    logic [1:0]  wsel;
    logic        hit;
    logic [127:0] hit_line;
    logic [31:0] hit_word;
    logic [31:0] be_mask;
    logic [31:0] merged_word;

    assign lookup_addr = (state == ST_IDLE) ? cpu_req_addr : req_addr;
    assign idx  = lookup_addr[5:4];
    assign tag  = lookup_addr[31:6];
    assign wsel = lookup_addr[3:2];
    assign hit  = line_valid[idx] && (line_tag[idx] == tag);
    assign hit_line = line_data[idx];

    always_comb begin
        case (wsel)
            2'd0:    hit_word = hit_line[31:0];
            2'd1:    hit_word = hit_line[63:32];
            2'd2:    hit_word = hit_line[95:64];
            default: hit_word = hit_line[127:96];
        endcase
    end

    assign be_mask = {{8{cpu_req_be[3]}}, {8{cpu_req_be[2]}}, {8{cpu_req_be[1]}}, {8{cpu_req_be[0]}}};
    assign merged_word = (hit_word & ~be_mask) | (cpu_req_wdata & be_mask);

    assign cpu_req_ready = rst_n && (state == ST_IDLE) && !halted;

    assign mem_req_valid = rst_n && ((state == ST_REFILL) || (state == ST_WT));
    assign mem_req_we    = (state == ST_WT);
    assign mem_req_addr  = (state == ST_WT) ? wt_addr : (refill_base + {refill_word, 2'b00});
    assign mem_req_wdata = (state == ST_WT) ? wt_wdata : 32'b0;
    assign mem_req_be    = (state == ST_WT) ? wt_be : 4'b1111;

    assign dcache_mem_wait = mem_req_valid && !mem_req_ready;
    assign idle = rst_n && (state == ST_IDLE) && !cpu_req_valid;

    assign cpu_resp_valid = rst_n && (state == ST_RESP);
    assign cpu_resp_rdata = resp_rdata;
    assign cpu_resp_epoch = resp_epoch;

    always_comb begin
        refill_data_next = refill_data;
        if ((state == ST_REFILL) && mem_req_ready) begin
            case (refill_word)
                2'd0: refill_data_next[31:0]   = mem_resp_data;
                2'd1: refill_data_next[63:32]  = mem_resp_data;
                2'd2: refill_data_next[95:64]  = mem_resp_data;
                2'd3: refill_data_next[127:96] = mem_resp_data;
                default: refill_data_next = refill_data;
            endcase
        end
    end

    always_ff @(posedge clk) begin : dcache_state
        integer r;
        if (!rst_n) begin
            state       <= ST_IDLE;
            line_valid  <= 4'b0;
            req_addr    <= 32'b0;
            req_wdata   <= 32'b0;
            req_be      <= 4'b0;
            req_we      <= 1'b0;
            req_rob     <= 4'b0;
            req_epoch   <= 2'b0;
            refill_base <= 32'b0;
            refill_word <= 2'b0;
            refill_data <= 128'b0;
            refill_tag  <= 26'b0;
            refill_idx  <= 2'b0;
            wt_addr     <= 32'b0;
            wt_wdata    <= 32'b0;
            wt_be       <= 4'b0;
            resp_rdata  <= 32'b0;
            resp_epoch  <= 2'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (cpu_req_valid && cpu_req_ready) begin
                        req_addr  <= cpu_req_addr;
                        req_wdata <= cpu_req_wdata;
                        req_be    <= cpu_req_be;
                        req_we    <= cpu_req_we;
                        req_rob   <= cpu_req_rob_index;
                        req_epoch <= cpu_req_epoch;
                        if (cpu_req_we) begin
                            if (hit) begin
                                for (r = 0; r < 4; r = r + 1) begin
                                    if (idx == r[1:0]) begin
                                        case (wsel)
                                            2'd0: line_data[r][31:0]    <= merged_word;
                                            2'd1: line_data[r][63:32]   <= merged_word;
                                            2'd2: line_data[r][95:64]   <= merged_word;
                                            default: line_data[r][127:96] <= merged_word;
                                        endcase
                                    end
                                end
                            end
                            wt_addr  <= cpu_req_addr;
                            wt_wdata <= cpu_req_wdata;
                            wt_be    <= cpu_req_be;
                            state    <= ST_WT;
                        end else if (hit) begin
                            resp_rdata <= hit_word;
                            resp_epoch <= cpu_req_epoch;
                            state      <= ST_RESP;
                        end else begin
                            refill_base <= {cpu_req_addr[31:4], 4'b0000};
                            refill_tag  <= cpu_req_addr[31:6];
                            refill_idx  <= cpu_req_addr[5:4];
                            refill_word <= 2'b0;
                            refill_data <= 128'b0;
                            state       <= ST_REFILL;
                        end
                    end
                end
                ST_REFILL: begin
                    if (mem_req_ready) begin
                        if (refill_word == 2'b11) begin
                            for (r = 0; r < 4; r = r + 1) begin
                                if (refill_idx == r[1:0]) begin
                                    line_data[r]  <= refill_data_next;
                                    line_tag[r]   <= refill_tag;
                                    line_valid[r] <= 1'b1;
                                end
                            end
                            case (wsel)
                                2'd0:    resp_rdata <= refill_data_next[31:0];
                                2'd1:    resp_rdata <= refill_data_next[63:32];
                                2'd2:    resp_rdata <= refill_data_next[95:64];
                                default: resp_rdata <= refill_data_next[127:96];
                            endcase
                            resp_epoch <= req_epoch;
                            state      <= ST_RESP;
                        end else begin
                            refill_data <= refill_data_next;
                            refill_word <= refill_word + 2'b01;
                        end
                    end
                end
                ST_WT: begin
                    if (mem_req_ready) begin
                        resp_rdata <= 32'b0;
                        resp_epoch <= req_epoch;
                        state      <= ST_RESP;
                    end
                end
                ST_RESP: begin
                    state <= ST_IDLE;
                end
                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
