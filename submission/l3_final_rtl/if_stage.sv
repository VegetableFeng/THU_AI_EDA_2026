module if_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [31:0] redirect_pc,
    input  logic [1:0]  flush_epoch,
    input  logic        halted,
    input  logic        ecall_pending,
    input  logic        id_ready,
    output logic        fetch_valid,
    output logic [31:0] fetch_pc,
    output logic [31:0] fetch_insn,
    output logic [31:0] fetch_pred_next_pc,
    output logic        fetch_pred_taken,
    output logic [1:0]  fetch_pred_type,
    output logic        fetch_pred_hit,
    output logic        cpu_req_valid,
    output logic [31:0] cpu_req_addr,
    output logic [1:0]  cpu_req_epoch,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_data,
    input  logic [1:0]  cpu_resp_epoch,
    output logic        pred_req_valid,
    output logic [31:0] pred_req_pc,
    input  logic [31:0] pred_next_pc,
    input  logic        pred_taken,
    input  logic [1:0]  pred_type,
    input  logic        pred_hit
);

    logic [31:0] pc;
    logic        req_pending;
    logic [31:0] req_pc;
    logic [1:0]  req_epoch;

    logic        if2id_valid;
    logic [31:0] if2id_pc;
    logic [31:0] if2id_insn;
    logic [31:0] if2id_pred_next_pc;
    logic        if2id_pred_taken;
    logic [1:0]  if2id_pred_type;
    logic        if2id_pred_hit;

    logic [31:0] req_pred_next_pc;
    logic        req_pred_taken;
    logic [1:0]  req_pred_type;
    logic        req_pred_hit;
    logic        req_pred_valid;

    logic [31:0] pred_next_eff;
    logic        pred_taken_eff;
    logic [1:0]  pred_type_eff;
    logic        pred_hit_eff;

    logic        fetch_accept;
    logic        issue_req;
    logic        resp_accept;
    logic        resp_stale;
    logic        req_accept;
    logic        front_stop;

    assign front_stop = halted | ecall_pending;

    assign fetch_valid        = if2id_valid;
    assign fetch_pc           = if2id_pc;
    assign fetch_insn         = if2id_insn;
    assign fetch_pred_next_pc = if2id_pred_next_pc;
    assign fetch_pred_taken   = if2id_pred_taken;
    assign fetch_pred_type    = if2id_pred_type;
    assign fetch_pred_hit     = if2id_pred_hit;

    assign cpu_req_valid = req_pending;
    assign cpu_req_addr  = req_pc;
    assign cpu_req_epoch = req_epoch;

    assign fetch_accept = if2id_valid && id_ready;
    assign issue_req    = !front_stop && !req_pending && (!if2id_valid || fetch_accept);
    assign resp_accept  = cpu_resp_valid && req_pending;
    assign resp_stale   = resp_accept && (cpu_resp_epoch != flush_epoch);
    assign req_accept   = req_pending && cpu_req_ready;

    // Ask for a prediction whenever a new fetch is launched, including the
    // prefetch that is launched while IF/ID drains.  Keep asserting it until
    // the I-Cache accepts the request so registered predictors hold the right
    // prediction.
    assign pred_req_valid = issue_req || (req_pending && !req_pred_valid);
    assign pred_req_pc    = pc;

    always_comb begin
        if (req_pred_valid) begin
            pred_next_eff  = req_pred_next_pc;
            pred_taken_eff = req_pred_taken;
            pred_type_eff  = req_pred_type;
            pred_hit_eff   = req_pred_hit;
        end else begin
            pred_next_eff  = pred_next_pc;
            pred_taken_eff = pred_taken;
            pred_type_eff  = pred_type;
            pred_hit_eff   = pred_hit;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pc                 <= 32'h0000_0000;
            req_pending        <= 1'b0;
            req_pc             <= 32'h0000_0000;
            req_epoch          <= 2'b00;
            if2id_valid        <= 1'b0;
            if2id_pc           <= 32'h0000_0000;
            if2id_insn         <= 32'h0000_0013;
            if2id_pred_next_pc <= 32'h0000_0000;
            if2id_pred_taken   <= 1'b0;
            if2id_pred_type    <= 2'b00;
            if2id_pred_hit     <= 1'b0;
            req_pred_next_pc   <= 32'h0000_0000;
            req_pred_taken     <= 1'b0;
            req_pred_type      <= 2'b00;
            req_pred_hit       <= 1'b0;
            req_pred_valid     <= 1'b0;
        end else begin
            if (req_accept) begin
                req_pred_next_pc <= pred_next_pc;
                req_pred_taken   <= pred_taken;
                req_pred_type    <= pred_type;
                req_pred_hit     <= pred_hit;
                req_pred_valid   <= 1'b1;
            end

            if (flush) begin
                pc                 <= redirect_pc;
                req_pending        <= 1'b0;
                req_pc             <= redirect_pc;
                req_epoch          <= flush_epoch;
                if2id_valid        <= 1'b0;
                if2id_pc           <= redirect_pc;
                if2id_insn         <= 32'h0000_0013;
                if2id_pred_next_pc <= redirect_pc + 32'd4;
                if2id_pred_taken   <= 1'b0;
                if2id_pred_type    <= 2'b00;
                if2id_pred_hit     <= 1'b0;
                req_pred_valid     <= 1'b0;
            end else if (halted) begin
                req_pending    <= 1'b0;
                if2id_valid    <= 1'b0;
                req_pred_valid <= 1'b0;
            end else if (resp_accept) begin
                req_pred_valid <= 1'b0;
                if (resp_stale) begin
                    // The response belongs to an older epoch.  Drop it, but
                    // keep the current request pending: the I-Cache has only
                    // one request slot, so re-presenting it without a bubble
                    // lets the cache accept the desired redirect fetch as
                    // soon as the stale transaction drains.
                    if2id_valid <= 1'b0;
                end else begin
                    if2id_valid        <= 1'b1;
                    if2id_pc           <= req_pc;
                    if2id_insn         <= cpu_resp_data;
                    if2id_pred_next_pc <= pred_next_eff;
                    if2id_pred_taken   <= pred_taken_eff;
                    if2id_pred_type    <= pred_type_eff;
                    if2id_pred_hit     <= pred_hit_eff;
                    pc                 <= pred_next_eff;
                    req_pending        <= 1'b0;
                end
            end else if (issue_req) begin
                req_pending    <= 1'b1;
                req_pc         <= pc;
                req_epoch      <= flush_epoch;
                req_pred_valid <= 1'b0;
                if (fetch_accept) begin
                    if2id_valid <= 1'b0;
                end
            end else if (fetch_accept) begin
                if2id_valid <= 1'b0;
            end
        end
    end

endmodule
