module if_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        redirect_valid,
    input  logic [31:0] redirect_target,
    input  logic        load_use_stall,
    input  logic        mem_stall,
    input  logic        halted,
    input  logic        ecall_in_id,
    output logic        cpu_req_valid,
    output logic [31:0] cpu_req_addr,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_data,
    output logic        if2id_valid,
    output logic [31:0] if2id_pc,
    output logic [31:0] if2id_pc4,
    output logic [31:0] if2id_insn,
    output logic [31:0] bp_lookup_pc,
    input  logic        bp_pred_valid,
    input  logic [31:0] bp_pred_next_pc,
    output logic        ifid_pred_valid,
    output logic [31:0] ifid_pred_next_pc
);

    logic [31:0] pc;
    logic        req_pending;
    logic        halt_pending;

    logic        inflight_pred_valid;
    logic [31:0] inflight_pred_next_pc;
    logic [31:0] next_pc;

    assign bp_lookup_pc = pc;
    assign next_pc      = bp_pred_valid ? bp_pred_next_pc : (pc + 32'd4);

    logic        stall;

    assign stall = load_use_stall | mem_stall;

    // Request is issued whenever we have a pending fetch and are not frozen.
    assign cpu_req_valid = req_pending & ~halted & ~halt_pending & ~stall;
    assign cpu_req_addr  = pc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc           <= 32'h0000_0000;
            req_pending  <= 1'b1;
            halt_pending <= 1'b0;
            if2id_valid  <= 1'b0;
            if2id_pc     <= 32'h0000_0000;
            if2id_pc4    <= 32'h0000_0000;
            if2id_insn   <= 32'h0000_0000;
            inflight_pred_valid   <= 1'b0;
            inflight_pred_next_pc <= 32'h0000_0000;
            ifid_pred_valid       <= 1'b0;
            ifid_pred_next_pc     <= 32'h0000_0000;
        end else if (halted) begin
            req_pending <= 1'b0;
            if2id_valid <= 1'b0;
        end else begin
            if (redirect_valid) begin
                pc           <= redirect_target;
                req_pending  <= 1'b1;
                halt_pending <= 1'b0;
                if2id_valid  <= 1'b0;
            end else if (ecall_in_id && !halt_pending && !mem_stall) begin
                halt_pending <= 1'b1;
                req_pending  <= 1'b0;
                // 不要在这里清掉 IF/ID valid：ECALL 还可能要等
                // load-use/mem_stall 结束后才进入 ID/EX。
            end else if (halt_pending) begin
                req_pending <= 1'b0;
                // 同理，保持 IF/ID valid，直到流水线消费掉 ECALL。
            end else if (cpu_resp_valid) begin
                // I-Cache 的响应可能只保持一个周期；即使在 mem_stall 或
                // load-use stall 期间也必须锁存，否则响应会永久丢失。
                if2id_valid <= 1'b1;
                if2id_pc    <= pc;
                if2id_pc4   <= pc + 32'd4;
                if2id_insn  <= cpu_resp_data;
                ifid_pred_valid     <= inflight_pred_valid;
                ifid_pred_next_pc   <= inflight_pred_next_pc;
                pc          <= next_pc;
                req_pending <= 1'b1;
                inflight_pred_valid   <= bp_pred_valid;
                inflight_pred_next_pc <= next_pc;
            end else if (stall) begin
                // 流水线暂停时 IF/ID 必须保持，不能在 stall 分支丢弃
                // 已经取到的指令，否则 load-use/mem_stall 后的指令会消失。
                if2id_valid <= if2id_valid;
            end else begin
                if (req_pending && cpu_req_ready) begin
                    req_pending <= 1'b0;
                    if2id_valid <= 1'b0;
                    inflight_pred_valid   <= bp_pred_valid;
                    inflight_pred_next_pc <= next_pc;
                end else begin
                    if2id_valid <= 1'b0;
                end
            end
        end
    end

endmodule
