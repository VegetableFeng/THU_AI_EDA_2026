module forwarding_unit (
    input  logic [4:0] id2ex_rs1,
    input  logic [4:0] id2ex_rs2,
    input  logic       ex2mem_valid,
    input  logic       ex2mem_reg_write,
    input  logic       ex2mem_mem_read,
    input  logic [4:0] ex2mem_rd,
    input  logic       mem2wb_valid,
    input  logic       mem2wb_reg_write,
    input  logic [4:0] mem2wb_rd,
    output logic [1:0] fwd_a,
    output logic [1:0] fwd_b
);

    logic ex2mem_hit_a;
    logic ex2mem_hit_b;
    logic mem2wb_hit_a;
    logic mem2wb_hit_b;

    always_comb begin
        ex2mem_hit_a = ex2mem_valid && ex2mem_reg_write && !ex2mem_mem_read &&
                       (ex2mem_rd != 5'd0) && (ex2mem_rd == id2ex_rs1);
        ex2mem_hit_b = ex2mem_valid && ex2mem_reg_write && !ex2mem_mem_read &&
                       (ex2mem_rd != 5'd0) && (ex2mem_rd == id2ex_rs2);
        mem2wb_hit_a = mem2wb_valid && mem2wb_reg_write &&
                       (mem2wb_rd != 5'd0) && (mem2wb_rd == id2ex_rs1);
        mem2wb_hit_b = mem2wb_valid && mem2wb_reg_write &&
                       (mem2wb_rd != 5'd0) && (mem2wb_rd == id2ex_rs2);

        if (ex2mem_hit_a) begin
            fwd_a = 2'b10;
        end else if (mem2wb_hit_a) begin
            fwd_a = 2'b01;
        end else begin
            fwd_a = 2'b00;
        end

        if (ex2mem_hit_b) begin
            fwd_b = 2'b10;
        end else if (mem2wb_hit_b) begin
            fwd_b = 2'b01;
        end else begin
            fwd_b = 2'b00;
        end
    end

endmodule
