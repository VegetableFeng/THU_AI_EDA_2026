module hazard_unit (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       id_valid,
    input  logic [4:0] id_rs1,
    input  logic [4:0] id_rs2,
    input  logic       id_uses_rs1,
    input  logic       id_uses_rs2,
    input  logic       ex_load_valid,
    input  logic [4:0] ex_load_rd,
    input  logic       redirect_valid,
    input  logic       ecall_in_id,
    output logic       load_use_stall,
    output logic       flush_id_ex,
    output logic       flush,
    output logic [1:0] flush_epoch
);

    logic load_use_raw;

    always_comb begin
        load_use_raw = 1'b0;
        if (id_valid && ex_load_valid && (ex_load_rd != 5'd0)) begin
            if (id_uses_rs1 && (id_rs1 == ex_load_rd))
                load_use_raw = 1'b1;
            else if (id_uses_rs2 && (id_rs2 == ex_load_rd))
                load_use_raw = 1'b1;
        end
    end

    assign load_use_stall = load_use_raw && !redirect_valid;

    // ECALL must NOT flush ID/EX: the ECALL itself must continue through
    // EX -> MEM -> WB to commit and set halted. Only redirects flush ID/EX.
    assign flush_id_ex = redirect_valid;

    // Only real control-flow redirects invalidate in-flight cache refills.
    // ECALL is not a control transfer; incrementing flush_epoch on ECALL
    // would discard an in-flight I-cache refill and stall fetch forever.
    assign flush = redirect_valid;

    always_ff @(posedge clk) begin
        if (!rst_n)
            flush_epoch <= 2'b00;
        else if (flush)
            flush_epoch <= flush_epoch + 2'b01;
    end

endmodule
