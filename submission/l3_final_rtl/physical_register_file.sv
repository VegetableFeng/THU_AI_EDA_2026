module physical_register_file (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [5:0]  iq_prf_rs1_addr,
    input  logic [5:0]  iq_prf_rs2_addr,
    output logic [31:0] iq_prf_rdata1,
    output logic [31:0] iq_prf_rdata2,
    input  logic [5:0]  lsu_prf_rs1_addr,
    input  logic [5:0]  lsu_prf_rs2_addr,
    output logic [31:0] lsu_prf_rdata1,
    output logic [31:0] lsu_prf_rdata2,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    input  logic [31:0] alu_complete_data,
    input  logic        load_complete_valid,
    input  logic [5:0]  load_complete_prd,
    input  logic [31:0] load_complete_data
);

    // The physical-register address is 6 bits wide, so the file must cover
    // all 64 physical registers.  With only 40 entries, writes to allocated
    // physical registers 40..63 were silently dropped and reads returned X.
    // Those X operands propagate into branch/JALR targets and memory
    // addresses, poisoning the predictor BTB and stalling the cache/bus
    // handshakes (the simulation watchdog timeout with no retire mismatches).
    logic [31:0] prf [0:63];

    logic [31:0] iq_rdata1_r;
    logic [31:0] iq_rdata2_r;
    logic [31:0] lsu_rdata1_r;
    logic [31:0] lsu_rdata2_r;

    integer i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 64; i = i + 1) begin
                prf[i] <= 32'h0000_0000;
            end
        end else begin
            // Physical register 0 is the architectural x0 and is hardwired.
            prf[0] <= 32'h0000_0000;
            if (alu_complete_valid && (alu_complete_prd != 6'd0)) begin
                prf[alu_complete_prd] <= alu_complete_data;
            end
            if (load_complete_valid && (load_complete_prd != 6'd0)) begin
                prf[load_complete_prd] <= load_complete_data;
            end
        end
    end

    // Write-first (read-during-write) behaviour.  A consumer that is woken by
    // a completion and issues in the same cycle must observe the newly
    // produced value, not the old register-array contents.  Without this the
    // LSU/IQ would compute operands (and memory addresses) from stale data in
    // exactly the cycle the producing ALU/load completes.  The load write
    // port has priority, matching the array write order above.
    always_comb begin
        iq_rdata1_r = (iq_prf_rs1_addr == 6'd0) ? 32'h0000_0000 :
                      (load_complete_valid && (load_complete_prd == iq_prf_rs1_addr)) ?
                          load_complete_data :
                      (alu_complete_valid && (alu_complete_prd == iq_prf_rs1_addr)) ?
                          alu_complete_data :
                      prf[iq_prf_rs1_addr];
        iq_rdata2_r = (iq_prf_rs2_addr == 6'd0) ? 32'h0000_0000 :
                      (load_complete_valid && (load_complete_prd == iq_prf_rs2_addr)) ?
                          load_complete_data :
                      (alu_complete_valid && (alu_complete_prd == iq_prf_rs2_addr)) ?
                          alu_complete_data :
                      prf[iq_prf_rs2_addr];
        lsu_rdata1_r = (lsu_prf_rs1_addr == 6'd0) ? 32'h0000_0000 :
                       (load_complete_valid && (load_complete_prd == lsu_prf_rs1_addr)) ?
                           load_complete_data :
                       (alu_complete_valid && (alu_complete_prd == lsu_prf_rs1_addr)) ?
                           alu_complete_data :
                       prf[lsu_prf_rs1_addr];
        lsu_rdata2_r = (lsu_prf_rs2_addr == 6'd0) ? 32'h0000_0000 :
                       (load_complete_valid && (load_complete_prd == lsu_prf_rs2_addr)) ?
                           load_complete_data :
                       (alu_complete_valid && (alu_complete_prd == lsu_prf_rs2_addr)) ?
                           alu_complete_data :
                       prf[lsu_prf_rs2_addr];
    end

    assign iq_prf_rdata1  = iq_rdata1_r;
    assign iq_prf_rdata2  = iq_rdata2_r;
    assign lsu_prf_rdata1 = lsu_rdata1_r;
    assign lsu_prf_rdata2 = lsu_rdata2_r;

endmodule
