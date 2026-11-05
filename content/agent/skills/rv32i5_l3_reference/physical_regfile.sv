module physical_regfile (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [5:0]  iq_raddr0,
    input  logic [5:0]  iq_raddr1,
    output logic [31:0] iq_rdata0,
    output logic [31:0] iq_rdata1,
    input  logic [5:0]  lsu_raddr0,
    input  logic [5:0]  lsu_raddr1,
    output logic [31:0] lsu_rdata0,
    output logic [31:0] lsu_rdata1,
    input  logic [5:0]  x10_raddr,
    output logic [31:0] x10_rdata,
    input  logic [5:0]  dbg_raddr,
    output logic [31:0] dbg_rdata,
    output logic [39:0] prf_ready,
    input  logic        we0,
    input  logic [5:0]  waddr0,
    input  logic [31:0] wdata0,
    input  logic        we1,
    input  logic [5:0]  waddr1,
    input  logic [31:0] wdata1,
    input  logic [39:0] clear_ready
);

    logic [31:0] prf_val [0:39];
    logic [39:0] ready_r;

    integer i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 40; i = i + 1) begin
                prf_val[i] <= 32'd0;
            end
            ready_r <= {8'b0, 32'hFFFF_FFFF};
        end else begin
            // 先应用 free-list 掩码清零，再让写回置位覆盖（NBA 后者胜）
            ready_r <= ready_r & ~clear_ready;
            if (we0 && (waddr0 != 6'd0)) begin
                prf_val[waddr0] <= wdata0;
                ready_r[waddr0] <= 1'b1;
            end
            if (we1 && (waddr1 != 6'd0)) begin
                prf_val[waddr1] <= wdata1;
                ready_r[waddr1] <= 1'b1;
            end
            ready_r[0] <= 1'b1;
        end
    end

    assign prf_ready = ready_r;

    assign iq_rdata0  = (iq_raddr0  == 6'd0) ? 32'd0 : prf_val[iq_raddr0];
    assign iq_rdata1  = (iq_raddr1  == 6'd0) ? 32'd0 : prf_val[iq_raddr1];
    assign lsu_rdata0 = (lsu_raddr0 == 6'd0) ? 32'd0 : prf_val[lsu_raddr0];
    assign lsu_rdata1 = (lsu_raddr1 == 6'd0) ? 32'd0 : prf_val[lsu_raddr1];
    assign x10_rdata  = (x10_raddr  == 6'd0) ? 32'd0 : prf_val[x10_raddr];
    assign dbg_rdata  = (dbg_raddr  == 6'd0) ? 32'd0 : prf_val[dbg_raddr];

endmodule
