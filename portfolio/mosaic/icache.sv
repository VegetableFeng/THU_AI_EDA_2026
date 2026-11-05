module icache (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [1:0]  flush_epoch,
    input  logic        halted,
    input  logic        cpu_req_valid,
    input  logic [31:0] cpu_req_addr,
    input  logic [1:0]  cpu_req_epoch,
    output logic        cpu_req_ready,
    output logic        cpu_resp_valid,
    output logic [31:0] cpu_resp_data,
    output logic [1:0]  cpu_resp_epoch,
    output logic        mem_req_valid,
    input  logic        mem_req_ready,
    output logic [31:0] mem_req_addr,
    input  logic        mem_resp_valid,
    input  logic [31:0] mem_resp_data,
    output logic        idle
);

    localparam logic [1:0] ST_IDLE   = 2'd0;
    localparam logic [1:0] ST_REFILL = 2'd1;
    localparam logic [1:0] ST_RESP   = 2'd2;

    logic [1:0]   state;
    logic [127:0] line_data;
    logic [27:0]  line_tag;
    logic         line_valid;

    logic [31:0] req_addr;
    logic [1:0]  req_epoch;

    logic [31:0] refill_base;
    logic [1:0]  refill_word;
    logic [27:0] refill_tag;

    logic [31:0] resp_data_r;
    logic [1:0]  resp_epoch_r;

    logic        cpu_hit;
    logic [31:0] cpu_word;

    assign cpu_hit = line_valid && (line_tag == cpu_req_addr[31:4]);

    always_comb begin
        case (cpu_req_addr[3:2])
            2'd0:    cpu_word = line_data[31:0];
            2'd1:    cpu_word = line_data[63:32];
            2'd2:    cpu_word = line_data[95:64];
            default: cpu_word = line_data[127:96];
        endcase
    end

    assign cpu_req_ready  = rst_n && (state == ST_IDLE) && !halted;
    assign cpu_resp_valid = rst_n && (state == ST_RESP);
    assign cpu_resp_data  = resp_data_r;
    assign cpu_resp_epoch = resp_epoch_r;

    assign mem_req_valid = rst_n && (state == ST_REFILL);
    assign mem_req_addr  = refill_base + {refill_word, 2'b00};

    assign idle = rst_n && (state == ST_IDLE) && !cpu_req_valid;

    always_ff @(posedge clk) begin : icache_state
        if (!rst_n) begin
            state        <= ST_IDLE;
            line_valid   <= 1'b0;
            req_addr     <= 32'b0;
            req_epoch    <= 2'b0;
            refill_base  <= 32'b0;
            refill_word  <= 2'b0;
            refill_tag   <= 28'b0;
            resp_data_r  <= 32'b0;
            resp_epoch_r <= 2'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (cpu_req_valid && !halted) begin
                        req_addr  <= cpu_req_addr;
                        req_epoch <= cpu_req_epoch;
                        if (cpu_hit) begin
                            resp_data_r  <= cpu_word;
                            resp_epoch_r <= cpu_req_epoch;
                            state        <= ST_RESP;
                        end else begin
                            refill_base <= {cpu_req_addr[31:4], 4'b0000};
                            refill_tag  <= cpu_req_addr[31:4];
                            refill_word <= 2'b00;
                            state       <= ST_REFILL;
                        end
                    end
                end
                ST_REFILL: begin
                    if (mem_req_ready && mem_resp_valid) begin
                        case (refill_word)
                            2'd0:    line_data[31:0]    <= mem_resp_data;
                            2'd1:    line_data[63:32]   <= mem_resp_data;
                            2'd2:    line_data[95:64]   <= mem_resp_data;
                            default: line_data[127:96]  <= mem_resp_data;
                        endcase
                        if (refill_word == req_addr[3:2]) begin
                            resp_data_r <= mem_resp_data;
                        end
                        if (refill_word == 2'b11) begin
                            line_tag    <= refill_tag;
                            line_valid  <= 1'b1;
                            resp_epoch_r <= req_epoch;
                            state       <= ST_RESP;
                        end else begin
                            refill_word <= refill_word + 2'b01;
                        end
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