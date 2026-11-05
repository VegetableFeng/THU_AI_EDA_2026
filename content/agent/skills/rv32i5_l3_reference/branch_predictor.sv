module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,
    input  logic [31:0] bp_lookup_pc,
    output logic        bp_pred_valid,
    output logic [31:0] bp_pred_next_pc,
    input  logic        bp_resolve_valid,
    input  logic [31:0] bp_resolve_pc,
    input  logic [1:0]  bp_resolve_type,
    input  logic        bp_resolve_taken,
    input  logic [31:0] bp_resolve_target
);

    localparam logic [1:0] TYPE_BRANCH = 2'b01;
    localparam logic [1:0] TYPE_JAL    = 2'b10;
    localparam logic [1:0] TYPE_JALR   = 2'b11;

    logic        btb_valid [0:15];
    logic [25:0] btb_tag   [0:15];
    logic [31:0] btb_target[0:15];
    logic [1:0]  btb_type  [0:15];

    logic [1:0]  bht [0:15];

    logic [3:0]  lookup_index;
    logic [25:0] lookup_tag;
    logic [3:0]  resolve_index;
    logic [25:0] resolve_tag;

    logic        lookup_hit;
    logic [1:0]  lookup_type;
    logic [1:0]  lookup_bht;
    logic        lookup_bht_taken;

    assign lookup_index = bp_lookup_pc[5:2];
    assign lookup_tag   = bp_lookup_pc[31:6];
    assign resolve_index = bp_resolve_pc[5:2];
    assign resolve_tag   = bp_resolve_pc[31:6];

    assign lookup_hit   = btb_valid[lookup_index] && (btb_tag[lookup_index] == lookup_tag);
    assign lookup_type  = btb_type[lookup_index];
    assign lookup_bht   = bht[lookup_index];
    assign lookup_bht_taken = lookup_bht[1];

    always_comb begin
        bp_pred_valid   = 1'b0;
        bp_pred_next_pc = bp_lookup_pc + 32'd4;
        if (lookup_hit) begin
            if (lookup_type == TYPE_BRANCH) begin
                if (lookup_bht_taken) begin
                    bp_pred_valid   = 1'b1;
                    bp_pred_next_pc = btb_target[lookup_index];
                end
            end else if (lookup_type == TYPE_JAL || lookup_type == TYPE_JALR) begin
                bp_pred_valid   = 1'b1;
                bp_pred_next_pc = btb_target[lookup_index];
            end
        end
    end

    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= 26'd0;
                btb_target[i] <= 32'd0;
                btb_type[i]   <= 2'b00;
                bht[i]        <= 2'b01;
            end
        end else if (bp_resolve_valid) begin
            if (bp_resolve_type == TYPE_BRANCH) begin
                if (bp_resolve_taken) begin
                    if (bht[resolve_index] != 2'b11)
                        bht[resolve_index] <= bht[resolve_index] + 2'b01;
                end else begin
                    if (bht[resolve_index] != 2'b00)
                        bht[resolve_index] <= bht[resolve_index] - 2'b01;
                end

                if (!btb_valid[resolve_index] || (btb_tag[resolve_index] != resolve_tag)) begin
                    if (bp_resolve_taken) begin
                        btb_valid[resolve_index]  <= 1'b1;
                        btb_tag[resolve_index]    <= resolve_tag;
                        btb_target[resolve_index] <= bp_resolve_target;
                        btb_type[resolve_index]   <= TYPE_BRANCH;
                    end
                end else begin
                    if (btb_target[resolve_index] != bp_resolve_target)
                        btb_target[resolve_index] <= bp_resolve_target;
                    if (btb_type[resolve_index] != TYPE_BRANCH)
                        btb_type[resolve_index] <= TYPE_BRANCH;
                end
            end else if (bp_resolve_type == TYPE_JAL || bp_resolve_type == TYPE_JALR) begin
                if (!btb_valid[resolve_index] || (btb_tag[resolve_index] != resolve_tag)) begin
                    btb_valid[resolve_index]  <= 1'b1;
                    btb_tag[resolve_index]    <= resolve_tag;
                    btb_target[resolve_index] <= bp_resolve_target;
                    btb_type[resolve_index]   <= bp_resolve_type;
                end else begin
                    if (btb_target[resolve_index] != bp_resolve_target)
                        btb_target[resolve_index] <= bp_resolve_target;
                    if (btb_type[resolve_index] != bp_resolve_type)
                        btb_type[resolve_index] <= bp_resolve_type;
                end
            end
        end
    end

endmodule
