// file: rtl/branch_predictor.sv
module branch_predictor (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        pred_req_valid,
    input  logic [31:0] pred_req_pc,
    output logic [31:0] pred_next_pc,
    output logic        pred_taken,
    output logic [1:0]  pred_type,
    output logic        pred_hit,
    input  logic        resolve_valid,
    input  logic [31:0] resolve_pc,
    input  logic [31:0] resolve_actual_next_pc,
    input  logic        resolve_taken,
    input  logic [1:0]  resolve_type
);

    localparam logic [1:0] TYPE_NONE = 2'b00;
    localparam logic [1:0] TYPE_COND = 2'b01;
    localparam logic [1:0] TYPE_JAL  = 2'b10;
    localparam logic [1:0] TYPE_JALR = 2'b11;

    logic        btb_valid [0:15];
    logic [29:0] btb_tag   [0:15];
    logic [31:0] btb_target[0:15];
    logic [1:0]  btb_type  [0:15];
    logic [1:0]  bht       [0:15];

    logic [3:0]  pred_index;
    logic [3:0]  res_index;
    logic        pred_btb_hit;
    logic        pred_dir_taken;
    logic [1:0]  pred_bht_state;

    assign pred_index = pred_req_pc[5:2];
    assign res_index  = resolve_pc[5:2];

    assign pred_btb_hit   = btb_valid[pred_index] && (btb_tag[pred_index] == pred_req_pc[31:2]);
    assign pred_bht_state = bht[pred_index];
    assign pred_dir_taken = (pred_bht_state == 2'b10) || (pred_bht_state == 2'b11);

    always_comb begin
        pred_hit     = 1'b0;
        pred_taken   = 1'b0;
        pred_type    = TYPE_NONE;
        pred_next_pc = pred_req_pc + 32'd4;
        if (pred_req_valid) begin
            if (pred_btb_hit) begin
                pred_hit  = 1'b1;
                pred_type = btb_type[pred_index];
                if (btb_type[pred_index] == TYPE_COND) begin
                    if (pred_dir_taken) begin
                        pred_taken   = 1'b1;
                        pred_next_pc = btb_target[pred_index];
                    end else begin
                        pred_taken   = 1'b0;
                        pred_next_pc = pred_req_pc + 32'd4;
                    end
                end else if (btb_type[pred_index] == TYPE_JAL) begin
                    pred_taken   = 1'b1;
                    pred_next_pc = btb_target[pred_index];
                end else if (btb_type[pred_index] == TYPE_JALR) begin
                    pred_taken   = 1'b1;
                    pred_next_pc = btb_target[pred_index];
                end else begin
                    pred_taken   = 1'b0;
                    pred_next_pc = pred_req_pc + 32'd4;
                end
            end else begin
                pred_hit     = 1'b0;
                pred_taken   = 1'b0;
                pred_type    = TYPE_NONE;
                pred_next_pc = pred_req_pc + 32'd4;
            end
        end
    end

    integer i;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) begin
                btb_valid[i]  <= 1'b0;
                btb_tag[i]    <= 30'd0;
                btb_target[i] <= 32'd0;
                btb_type[i]   <= TYPE_NONE;
                bht[i]        <= 2'b01;
            end
        end else if (resolve_valid) begin
            if (resolve_type == TYPE_COND) begin
                btb_valid[res_index]  <= 1'b1;
                btb_tag[res_index]    <= resolve_pc[31:2];
                btb_target[res_index] <= resolve_actual_next_pc;
                btb_type[res_index]   <= TYPE_COND;
                if (resolve_taken) begin
                    if (bht[res_index] != 2'b11)
                        bht[res_index] <= bht[res_index] + 2'b01;
                end else begin
                    if (bht[res_index] != 2'b00)
                        bht[res_index] <= bht[res_index] - 2'b01;
                end
            end else if (resolve_type == TYPE_JAL) begin
                btb_valid[res_index]  <= 1'b1;
                btb_tag[res_index]    <= resolve_pc[31:2];
                btb_target[res_index] <= resolve_actual_next_pc;
                btb_type[res_index]   <= TYPE_JAL;
            end else if (resolve_type == TYPE_JALR) begin
                btb_valid[res_index]  <= 1'b1;
                btb_tag[res_index]    <= resolve_pc[31:2];
                btb_target[res_index] <= resolve_actual_next_pc;
                btb_type[res_index]   <= TYPE_JALR;
            end
        end
    end

endmodule

// file: rtl/commit_unit.sv
module commit_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        commit_valid,
    input  logic [31:0] commit_pc,
    input  logic [31:0] commit_insn,
    input  logic [31:0] commit_value,
    input  logic [4:0]  commit_arch_rd,
    input  logic        commit_reg_write,
    input  logic        commit_is_ecall,
    input  logic        bus_idle,
    input  logic [4:0]  dbg_reg_addr,
    output logic        halted,
    output logic [31:0] exit_code,
    output logic        dbg_retire_valid,
    output logic [31:0] dbg_retire_pc,
    output logic [31:0] dbg_retire_insn,
    output logic [31:0] dbg_reg_data
);

    logic [31:0] arch [0:31];
    logic        halted_r;
    logic [31:0] exit_code_r;
    logic        retire_valid_r;
    logic [31:0] retire_pc_r;
    logic [31:0] retire_insn_r;
    logic        ecall_wait_r;
    logic        commit_ecall_eff;

    integer i;

    // The ROB should preserve commit_is_ecall, but recognizing the exact ECALL
    // encoding at WB makes halt robust even if that sideband is dropped.  This
    // preserves the required one-cycle retire pulse followed by halted=1 with
    // exit_code=x10 on the next edge.
    assign commit_ecall_eff = commit_is_ecall || (commit_insn == 32'h0000_0073);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) begin
                arch[i] <= 32'b0;
            end
            halted_r       <= 1'b0;
            exit_code_r    <= 32'b0;
            retire_valid_r <= 1'b0;
            retire_pc_r    <= 32'b0;
            retire_insn_r  <= 32'b0;
            ecall_wait_r   <= 1'b0;
        end else begin
            retire_valid_r <= 1'b0;
            retire_pc_r    <= 32'b0;
            retire_insn_r  <= 32'b0;

            if (halted_r) begin
                ecall_wait_r <= 1'b0;
            end else if (ecall_wait_r) begin
                // The ECALL retired on the previous edge (retire_valid was
                // pulsed while halted=0 and exit_code=0).  Halt must be
                // committed on this edge with exit_code=x10.  Do NOT keep
                // waiting for bus_idle here: all older stores have already
                // completed before an ECALL can commit (in-order ROB commit
                // waits for store_done), so only abortable read-only
                // fetch/refill traffic could still be draining and it must
                // never extend this wait into a liveness timeout.
                halted_r     <= 1'b1;
                exit_code_r  <= arch[10];
                ecall_wait_r <= 1'b0;
            end else if (commit_valid) begin
                retire_valid_r <= 1'b1;
                retire_pc_r    <= commit_pc;
                retire_insn_r  <= commit_insn;

                if (commit_reg_write && (commit_arch_rd != 5'd0)) begin
                    arch[commit_arch_rd] <= commit_value;
                end

                if (commit_ecall_eff) begin
                    ecall_wait_r <= 1'b1;
                end
            end
        end
    end

    always_comb begin
        dbg_reg_data = (dbg_reg_addr == 5'd0) ? 32'b0 : arch[dbg_reg_addr];
    end

    assign halted           = halted_r;
    assign exit_code        = exit_code_r;
    assign dbg_retire_valid = retire_valid_r;
    assign dbg_retire_pc    = retire_pc_r;
    assign dbg_retire_insn  = retire_insn_r;

endmodule

// file: rtl/dcache.sv
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

    localparam logic [2:0] ST_IDLE   = 3'd0;
    localparam logic [2:0] ST_REFILL = 3'd1;
    localparam logic [2:0] ST_WT     = 3'd2;
    localparam logic [2:0] ST_RESP   = 3'd3;

    logic [2:0]   state;
    logic [127:0] line_data;
    logic [27:0]  line_tag;
    logic         line_valid;

    logic [31:0] req_addr;
    logic [1:0]  req_epoch;

    logic [31:0] refill_base;
    logic [1:0]  refill_word;
    logic [27:0] refill_tag;

    logic [31:0] wt_addr;
    logic [31:0] wt_wdata;
    logic [3:0]  wt_be;

    logic [31:0] resp_rdata;
    logic [1:0]  resp_epoch;

    logic [31:0] lookup_addr;
    logic [1:0]  wsel;
    logic        hit;
    logic [31:0] hit_word;
    logic [31:0] be_mask;
    logic [31:0] merged_word;

    assign lookup_addr = (state == ST_IDLE) ? cpu_req_addr : req_addr;
    assign wsel = lookup_addr[3:2];
    assign hit  = line_valid && (line_tag == lookup_addr[31:4]);

    always_comb begin
        case (wsel)
            2'd0:    hit_word = line_data[31:0];
            2'd1:    hit_word = line_data[63:32];
            2'd2:    hit_word = line_data[95:64];
            default: hit_word = line_data[127:96];
        endcase
    end

    assign be_mask = {{8{cpu_req_be[3]}}, {8{cpu_req_be[2]}}, {8{cpu_req_be[1]}}, {8{cpu_req_be[0]}}};
    assign merged_word = (hit_word & ~be_mask) | (cpu_req_wdata & be_mask);

    assign cpu_req_ready = rst_n && (state == ST_IDLE) && !halted;

    assign mem_req_valid = rst_n && ((state == ST_REFILL) || (state == ST_WT));
    assign mem_req_we    = (state == ST_WT);
    assign mem_req_addr  = (state == ST_WT) ? wt_addr :
                           (refill_base + {refill_word, 2'b00});
    assign mem_req_wdata = (state == ST_WT) ? wt_wdata : 32'b0;
    assign mem_req_be    = (state == ST_WT) ? wt_be : 4'b1111;

    assign dcache_mem_wait = mem_req_valid && !mem_req_ready;
    assign idle = rst_n && (state == ST_IDLE) && !cpu_req_valid;

    assign cpu_resp_valid = rst_n && (state == ST_RESP);
    assign cpu_resp_rdata = resp_rdata;
    assign cpu_resp_epoch = resp_epoch;

    always_ff @(posedge clk) begin : dcache_state
        if (!rst_n) begin
            state       <= ST_IDLE;
            line_valid  <= 1'b0;
            req_addr    <= 32'b0;
            req_epoch   <= 2'b0;
            refill_base <= 32'b0;
            refill_word <= 2'b0;
            refill_tag  <= 28'b0;
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
                        req_epoch <= cpu_req_epoch;
                        if (cpu_req_we) begin
                            if (hit) begin
                                case (wsel)
                                    2'd0:    line_data[31:0]    <= merged_word;
                                    2'd1:    line_data[63:32]   <= merged_word;
                                    2'd2:    line_data[95:64]   <= merged_word;
                                    default: line_data[127:96]  <= merged_word;
                                endcase
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
                            refill_tag  <= cpu_req_addr[31:4];
                            refill_word <= 2'b0;
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
                            resp_rdata <= mem_resp_data;
                        end
                        if (refill_word == 2'b11) begin
                            line_tag   <= refill_tag;
                            line_valid <= 1'b1;
                            resp_epoch <= req_epoch;
                            state      <= ST_RESP;
                        end else begin
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

// file: rtl/execute_alu.sv
module execute_alu (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic        halted,
    input  logic        issue_valid,
    output logic        issue_ready,
    input  logic [31:0] issue_pc,
    input  logic [31:0] issue_insn,
    input  logic [3:0]  issue_rob_index,
    input  logic [5:0]  issue_prs1,
    input  logic [5:0]  issue_prs2,
    input  logic [5:0]  issue_pdst,
    input  logic [31:0] issue_operand1,
    input  logic [31:0] issue_operand2,
    input  logic [31:0] issue_imm,
    input  logic [4:0]  issue_alu_op,
    input  logic [2:0]  issue_wb_sel,
    input  logic        issue_is_branch,
    input  logic        issue_is_jal,
    input  logic        issue_is_jalr,
    input  logic        issue_use_imm,
    input  logic        issue_is_auipc,
    input  logic [31:0] issue_pred_next_pc,
    input  logic        issue_pred_taken,
    input  logic [1:0]  issue_pred_type,
    output logic        alu_complete_valid,
    output logic [3:0]  alu_complete_rob_index,
    output logic [5:0]  alu_complete_prd,
    output logic [31:0] alu_complete_data,
    output logic        resolve_valid,
    output logic [3:0]  resolve_rob_index,
    output logic [31:0] resolve_pc,
    output logic [31:0] resolve_actual
);

    localparam logic [4:0] ALU_ADD  = 5'd0;
    localparam logic [4:0] ALU_SUB  = 5'd1;
    localparam logic [4:0] ALU_SLL  = 5'd2;
    localparam logic [4:0] ALU_SLT  = 5'd3;
    localparam logic [4:0] ALU_SLTU = 5'd4;
    localparam logic [4:0] ALU_XOR  = 5'd5;
    localparam logic [4:0] ALU_SRL  = 5'd6;
    localparam logic [4:0] ALU_SRA  = 5'd7;
    localparam logic [4:0] ALU_OR   = 5'd8;
    localparam logic [4:0] ALU_AND  = 5'd9;
    localparam logic [4:0] ALU_PASSB= 5'd10;
    localparam logic [4:0] ALU_BEQ  = 5'd11;
    localparam logic [4:0] ALU_BNE  = 5'd12;
    localparam logic [4:0] ALU_BLT  = 5'd13;
    localparam logic [4:0] ALU_BGE  = 5'd14;
    localparam logic [4:0] ALU_BLTU = 5'd15;
    localparam logic [4:0] ALU_BGEU = 5'd16;
    localparam logic [4:0] ALU_JAL  = 5'd17;
    localparam logic [4:0] ALU_JALR = 5'd18;
    localparam logic [4:0] ALU_LUI  = 5'd19;
    localparam logic [4:0] ALU_AUIPC= 5'd20;

    localparam logic [2:0] WB_ALU  = 3'b000;
    localparam logic [2:0] WB_PC4  = 3'b001;
    localparam logic [2:0] WB_LOAD = 3'b010;
    localparam logic [2:0] WB_IMM  = 3'b011;
    localparam logic [2:0] WB_AUIPC= 3'b100;

    logic [31:0] op_a;
    logic [31:0] op_b;
    logic [31:0] op_imm;
    logic [31:0] pc_g;
    logic [31:0] alu_result;
    logic [31:0] pc_plus4;
    logic [31:0] branch_target;
    logic [31:0] jal_target;
    logic [31:0] jalr_target;
    logic [31:0] ctrl_target;
    logic        branch_taken;
    logic        is_control;
    logic        actual_taken;
    logic [31:0] actual_next_pc;
    logic [31:0] wb_data;
    logic        issue_en;

    // Operand isolation: when no instruction is being accepted the entire
    // datapath is held quiet (operands, immediates and PC forced to zero).
    // All result qualifiers below are gated by issue_en as well, so the
    // functional behaviour seen by the ROB / rename unit is unchanged.
    assign issue_en = issue_valid & issue_ready;

    assign op_a   = issue_en ? issue_operand1 : 32'd0;
    assign op_b   = issue_en ? (issue_use_imm ? issue_imm : issue_operand2) : 32'd0;
    assign op_imm = issue_en ? issue_imm : 32'd0;
    assign pc_g   = issue_en ? issue_pc  : 32'd0;

    always_comb begin
        alu_result = 32'd0;
        case (issue_alu_op)
            ALU_ADD:   alu_result = op_a + op_b;
            ALU_SUB:   alu_result = op_a - op_b;
            ALU_SLL:   alu_result = op_a << op_b[4:0];
            ALU_SLT:   alu_result = ($signed(op_a) < $signed(op_b)) ? 32'd1 : 32'd0;
            ALU_SLTU:  alu_result = (op_a < op_b) ? 32'd1 : 32'd0;
            ALU_XOR:   alu_result = op_a ^ op_b;
            ALU_SRL:   alu_result = op_a >> op_b[4:0];
            ALU_SRA:   alu_result = $signed(op_a) >>> op_b[4:0];
            ALU_OR:    alu_result = op_a | op_b;
            ALU_AND:   alu_result = op_a & op_b;
            ALU_PASSB: alu_result = op_b;
            ALU_LUI:   alu_result = op_imm;
            ALU_AUIPC: alu_result = pc_g + op_imm;
            default:   alu_result = op_a + op_b;
        endcase
    end

    always_comb begin
        branch_taken = 1'b0;
        case (issue_alu_op)
            ALU_BEQ:  branch_taken = (op_a == op_b);
            ALU_BNE:  branch_taken = (op_a != op_b);
            ALU_BLT:  branch_taken = ($signed(op_a) < $signed(op_b));
            ALU_BGE:  branch_taken = ($signed(op_a) >= $signed(op_b));
            ALU_BLTU: branch_taken = (op_a < op_b);
            ALU_BGEU: branch_taken = (op_a >= op_b);
            default:  branch_taken = 1'b0;
        endcase
        if (!issue_en) branch_taken = 1'b0;
    end

    assign pc_plus4      = pc_g + 32'd4;
    assign branch_target = pc_g + op_imm;
    assign jal_target    = pc_g + op_imm;
    assign jalr_target   = (op_a + op_imm) & 32'hFFFF_FFFE;

    always_comb begin
        ctrl_target = pc_g + 32'd4;
        if (issue_is_branch) begin
            ctrl_target = branch_target;
        end else if (issue_is_jal) begin
            ctrl_target = jal_target;
        end else if (issue_is_jalr) begin
            ctrl_target = jalr_target;
        end
        if (!issue_en) ctrl_target = 32'd0;
    end

    assign is_control = issue_en && (issue_is_branch | issue_is_jal | issue_is_jalr);

    always_comb begin
        actual_taken = 1'b0;
        if (issue_en) begin
            if (issue_is_branch) begin
                actual_taken = branch_taken;
            end else if (issue_is_jal || issue_is_jalr) begin
                actual_taken = 1'b1;
            end
        end
    end

    assign actual_next_pc = actual_taken ? ctrl_target : pc_plus4;

    always_comb begin
        wb_data = alu_result;
        case (issue_wb_sel)
            WB_ALU:   wb_data = alu_result;
            WB_PC4:   wb_data = pc_plus4;
            WB_LOAD:  wb_data = alu_result;
            WB_IMM:   wb_data = op_imm;
            WB_AUIPC: wb_data = pc_g + op_imm;
            default:  wb_data = alu_result;
        endcase
        if (!issue_en) wb_data = 32'd0;
    end

    assign issue_ready = rst_n & ~halted & ~flush;

    assign alu_complete_valid     = issue_en;
    assign alu_complete_rob_index = issue_rob_index;
    assign alu_complete_prd       = issue_pdst;
    assign alu_complete_data      = wb_data;

    assign resolve_valid     = is_control;
    assign resolve_rob_index = issue_rob_index;
    assign resolve_pc        = issue_en ? issue_pc : 32'd0;
    assign resolve_actual    = issue_en ? actual_next_pc : 32'd0;

endmodule

// file: rtl/icache.sv
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

// file: rtl/id_stage.sv
module id_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic        halted,
    input  logic        ecall_pending,
    input  logic        fetch_valid,
    input  logic [31:0] fetch_pc,
    input  logic [31:0] fetch_insn,
    input  logic [31:0] fetch_pred_next_pc,
    input  logic        fetch_pred_taken,
    input  logic [1:0]  fetch_pred_type,
    input  logic        fetch_pred_hit,
    output logic        id_valid,
    output logic [31:0] id_pc,
    output logic [31:0] id_insn,
    output logic [4:0]  id_rs1,
    output logic [4:0]  id_rs2,
    output logic [4:0]  id_rd,
    output logic [31:0] id_imm,
    output logic [4:0]  id_alu_op,
    output logic [2:0]  id_wb_sel,
    output logic        id_is_load,
    output logic        id_is_store,
    output logic [1:0]  id_mem_size,
    output logic        id_is_branch,
    output logic        id_is_jal,
    output logic        id_is_jalr,
    output logic        id_is_ecall,
    output logic        id_reg_write,
    output logic        id_use_imm,
    output logic        id_is_auipc,
    output logic [31:0] id_pred_next_pc,
    output logic        id_pred_taken,
    output logic [1:0]  id_pred_type,
    output logic        id_pred_hit
);

    localparam logic [4:0] ALU_ADD  = 5'd0;
    localparam logic [4:0] ALU_SUB  = 5'd1;
    localparam logic [4:0] ALU_SLL  = 5'd2;
    localparam logic [4:0] ALU_SLT  = 5'd3;
    localparam logic [4:0] ALU_SLTU = 5'd4;
    localparam logic [4:0] ALU_XOR  = 5'd5;
    localparam logic [4:0] ALU_SRL  = 5'd6;
    localparam logic [4:0] ALU_SRA  = 5'd7;
    localparam logic [4:0] ALU_OR   = 5'd8;
    localparam logic [4:0] ALU_AND  = 5'd9;
    localparam logic [4:0] ALU_PASS = 5'd10;
    localparam logic [4:0] ALU_BEQ  = 5'd11;
    localparam logic [4:0] ALU_BNE  = 5'd12;
    localparam logic [4:0] ALU_BLT  = 5'd13;
    localparam logic [4:0] ALU_BGE  = 5'd14;
    localparam logic [4:0] ALU_BLTU = 5'd15;
    localparam logic [4:0] ALU_BGEU = 5'd16;
    localparam logic [4:0] ALU_JAL  = 5'd17;
    localparam logic [4:0] ALU_JALR = 5'd18;
    localparam logic [4:0] ALU_LUI  = 5'd19;
    localparam logic [4:0] ALU_AUIPC= 5'd20;

    localparam logic [2:0] WB_ALU  = 3'b000;
    localparam logic [2:0] WB_PC4  = 3'b001;
    localparam logic [2:0] WB_LOAD = 3'b010;
    localparam logic [2:0] WB_IMM  = 3'b011;
    localparam logic [2:0] WB_AUIPC= 3'b100;

    localparam logic [1:0] MS_BYTE = 2'b00;
    localparam logic [1:0] MS_HALF = 2'b01;
    localparam logic [1:0] MS_WORD = 2'b10;

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    logic [31:0] imm_i;
    logic [31:0] imm_s;
    logic [31:0] imm_b;
    logic [31:0] imm_u;
    logic [31:0] imm_j;

    logic [31:0] imm_sel;
    logic [4:0]  alu_op_c;
    logic [2:0]  wb_sel_c;
    logic        is_load_c;
    logic        is_store_c;
    logic [1:0]  mem_size_c;
    logic        is_branch_c;
    logic        is_jal_c;
    logic        is_jalr_c;
    logic        is_ecall_c;
    logic        reg_write_c;
    logic        use_imm_c;
    logic        is_auipc_c;

    assign opcode = fetch_insn[6:0];
    assign funct3 = fetch_insn[14:12];
    assign funct7 = fetch_insn[31:25];

    assign imm_i = {{20{fetch_insn[31]}}, fetch_insn[31:20]};
    assign imm_s = {{20{fetch_insn[31]}}, fetch_insn[31:25], fetch_insn[11:7]};
    assign imm_b = {{19{fetch_insn[31]}}, fetch_insn[31], fetch_insn[7],
                    fetch_insn[30:25], fetch_insn[11:8], 1'b0};
    assign imm_u = {fetch_insn[31:12], 12'b0};
    assign imm_j = {{11{fetch_insn[31]}}, fetch_insn[31], fetch_insn[19:12],
                    fetch_insn[20], fetch_insn[30:21], 1'b0};

    always_comb begin
        imm_sel    = 32'b0;
        alu_op_c   = ALU_ADD;
        wb_sel_c   = WB_ALU;
        is_load_c  = 1'b0;
        is_store_c = 1'b0;
        mem_size_c = MS_WORD;
        is_branch_c= 1'b0;
        is_jal_c   = 1'b0;
        is_jalr_c  = 1'b0;
        is_ecall_c = 1'b0;
        reg_write_c= 1'b0;
        use_imm_c  = 1'b0;
        is_auipc_c = 1'b0;

        case (opcode)
            7'b0110011: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_ALU;
                use_imm_c   = 1'b0;
                case (funct3)
                    3'b000: alu_op_c = funct7[5] ? ALU_SUB : ALU_ADD;
                    3'b001: alu_op_c = ALU_SLL;
                    3'b010: alu_op_c = ALU_SLT;
                    3'b011: alu_op_c = ALU_SLTU;
                    3'b100: alu_op_c = ALU_XOR;
                    3'b101: alu_op_c = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op_c = ALU_OR;
                    3'b111: alu_op_c = ALU_AND;
                    default: alu_op_c = ALU_ADD;
                endcase
            end
            7'b0010011: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_ALU;
                use_imm_c   = 1'b1;
                imm_sel     = imm_i;
                case (funct3)
                    3'b000: alu_op_c = ALU_ADD;
                    3'b001: alu_op_c = ALU_SLL;
                    3'b010: alu_op_c = ALU_SLT;
                    3'b011: alu_op_c = ALU_SLTU;
                    3'b100: alu_op_c = ALU_XOR;
                    3'b101: alu_op_c = funct7[5] ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op_c = ALU_OR;
                    3'b111: alu_op_c = ALU_AND;
                    default: alu_op_c = ALU_ADD;
                endcase
            end
            7'b0000011: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_LOAD;
                use_imm_c   = 1'b1;
                imm_sel     = imm_i;
                alu_op_c    = ALU_ADD;
                is_load_c   = 1'b1;
                case (funct3)
                    3'b000: mem_size_c = MS_BYTE;
                    3'b001: mem_size_c = MS_HALF;
                    3'b010: mem_size_c = MS_WORD;
                    3'b100: mem_size_c = MS_BYTE;
                    3'b101: mem_size_c = MS_HALF;
                    default: mem_size_c = MS_WORD;
                endcase
            end
            7'b0100011: begin
                reg_write_c = 1'b0;
                use_imm_c   = 1'b1;
                imm_sel     = imm_s;
                alu_op_c    = ALU_ADD;
                is_store_c  = 1'b1;
                case (funct3)
                    3'b000: mem_size_c = MS_BYTE;
                    3'b001: mem_size_c = MS_HALF;
                    3'b010: mem_size_c = MS_WORD;
                    default: mem_size_c = MS_WORD;
                endcase
            end
            7'b1100011: begin
                reg_write_c = 1'b0;
                // Branches compare rs1 against rs2, not the branch immediate.
                use_imm_c   = 1'b0;
                imm_sel     = imm_b;
                is_branch_c = 1'b1;
                case (funct3)
                    3'b000: alu_op_c = ALU_BEQ;
                    3'b001: alu_op_c = ALU_BNE;
                    3'b100: alu_op_c = ALU_BLT;
                    3'b101: alu_op_c = ALU_BGE;
                    3'b110: alu_op_c = ALU_BLTU;
                    3'b111: alu_op_c = ALU_BGEU;
                    default: alu_op_c = ALU_BEQ;
                endcase
            end
            7'b1101111: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_PC4;
                use_imm_c   = 1'b1;
                imm_sel     = imm_j;
                alu_op_c    = ALU_JAL;
                is_jal_c    = 1'b1;
            end
            7'b1100111: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_PC4;
                use_imm_c   = 1'b1;
                imm_sel     = imm_i;
                alu_op_c    = ALU_JALR;
                is_jalr_c   = 1'b1;
            end
            7'b0110111: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_IMM;
                use_imm_c   = 1'b1;
                imm_sel     = imm_u;
                alu_op_c    = ALU_LUI;
            end
            7'b0010111: begin
                reg_write_c = 1'b1;
                wb_sel_c    = WB_AUIPC;
                use_imm_c   = 1'b1;
                imm_sel     = imm_u;
                alu_op_c    = ALU_AUIPC;
                is_auipc_c  = 1'b1;
            end
            7'b1110011: begin
                if (fetch_insn == 32'h0000_0073) begin
                    is_ecall_c  = 1'b1;
                    reg_write_c = 1'b0;
                    wb_sel_c    = WB_ALU;
                    alu_op_c    = ALU_ADD;
                end
            end
            default: begin
                reg_write_c = 1'b0;
                wb_sel_c    = WB_ALU;
                alu_op_c    = ALU_ADD;
            end
        endcase
    end

    // The front-end stop (ecall_pending) only exists to keep instructions
    // YOUNGER than an accepted ECALL out of the pipeline.  It must never
    // suppress the ECALL itself: if the stop is already asserted while the
    // ECALL is still sitting in IF/ID, gating id_valid with it would silently
    // drop the only instruction that can halt the core (simulation timeout).
    assign id_valid       = fetch_valid && !flush && !halted &&
                            (!ecall_pending || is_ecall_c);
    assign id_pc          = fetch_pc;
    assign id_insn        = fetch_insn;
    assign id_rs1         = fetch_insn[19:15];
    assign id_rs2         = fetch_insn[24:20];
    assign id_rd          = fetch_insn[11:7];
    assign id_imm         = imm_sel;
    assign id_alu_op      = alu_op_c;
    assign id_wb_sel      = wb_sel_c;
    assign id_is_load     = is_load_c;
    assign id_is_store    = is_store_c;
    assign id_mem_size    = mem_size_c;
    assign id_is_branch   = is_branch_c;
    assign id_is_jal      = is_jal_c;
    assign id_is_jalr     = is_jalr_c;
    assign id_is_ecall    = is_ecall_c;
    assign id_reg_write   = reg_write_c;
    assign id_use_imm     = use_imm_c;
    assign id_is_auipc    = is_auipc_c;
    assign id_pred_next_pc= fetch_pred_next_pc;
    assign id_pred_taken  = fetch_pred_taken;
    assign id_pred_type   = fetch_pred_type;
    assign id_pred_hit    = fetch_pred_hit;

endmodule

// file: rtl/if_stage.sv
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

// file: rtl/issue_queue.sv
module issue_queue (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [3:0]  flush_rob_index,
    input  logic [3:0]  rob_head_index,
    input  logic        halted,
    input  logic        iq_disp_valid,
    output logic        iq_disp_ready,
    input  logic [31:0] iq_disp_pc,
    input  logic [31:0] iq_disp_insn,
    input  logic [3:0]  iq_disp_rob_index,
    input  logic [5:0]  iq_disp_prs1,
    input  logic [5:0]  iq_disp_prs2,
    input  logic [5:0]  iq_disp_pdst,
    input  logic        iq_disp_rs1_ready,
    input  logic        iq_disp_rs2_ready,
    input  logic [31:0] iq_disp_imm,
    input  logic [4:0]  iq_disp_alu_op,
    input  logic [2:0]  iq_disp_wb_sel,
    input  logic        iq_disp_is_branch,
    input  logic        iq_disp_is_jal,
    input  logic        iq_disp_is_jalr,
    input  logic        iq_disp_use_imm,
    input  logic        iq_disp_is_auipc,
    input  logic [31:0] iq_disp_pred_next_pc,
    input  logic        iq_disp_pred_taken,
    input  logic [1:0]  iq_disp_pred_type,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    input  logic        load_complete_valid,
    input  logic [5:0]  load_complete_prd,
    output logic [5:0]  iq_prf_rs1_addr,
    output logic [5:0]  iq_prf_rs2_addr,
    input  logic [31:0] iq_prf_rdata1,
    input  logic [31:0] iq_prf_rdata2,
    output logic        issue_valid,
    input  logic        issue_ready,
    output logic [31:0] issue_pc,
    output logic [31:0] issue_insn,
    output logic [3:0]  issue_rob_index,
    output logic [5:0]  issue_prs1,
    output logic [5:0]  issue_prs2,
    output logic [5:0]  issue_pdst,
    output logic [31:0] issue_operand1,
    output logic [31:0] issue_operand2,
    output logic [31:0] issue_imm,
    output logic [4:0]  issue_alu_op,
    output logic [2:0]  issue_wb_sel,
    output logic        issue_is_branch,
    output logic        issue_is_jal,
    output logic        issue_is_jalr,
    output logic        issue_use_imm,
    output logic        issue_is_auipc,
    output logic [31:0] issue_pred_next_pc,
    output logic        issue_pred_taken,
    output logic [1:0]  issue_pred_type,
    output logic        dbg_ooo_issue,
    output logic        dbg_ooo_bypass
);

    localparam int IQ_DEPTH = 2;

    logic        ent_valid   [0:IQ_DEPTH-1];
    logic [31:0] ent_pc      [0:IQ_DEPTH-1];
    logic [31:0] ent_insn    [0:IQ_DEPTH-1];
    logic [3:0]  ent_rob     [0:IQ_DEPTH-1];
    logic [5:0]  ent_prs1    [0:IQ_DEPTH-1];
    logic [5:0]  ent_prs2    [0:IQ_DEPTH-1];
    logic [5:0]  ent_pdst    [0:IQ_DEPTH-1];
    logic        ent_r1rdy   [0:IQ_DEPTH-1];
    logic        ent_r2rdy   [0:IQ_DEPTH-1];
    logic [4:0]  ent_alu_op  [0:IQ_DEPTH-1];
    logic [2:0]  ent_wb_sel  [0:IQ_DEPTH-1];
    logic        ent_br      [0:IQ_DEPTH-1];
    logic        ent_jal     [0:IQ_DEPTH-1];
    logic        ent_jalr    [0:IQ_DEPTH-1];
    logic        ent_useimm  [0:IQ_DEPTH-1];
    logic        ent_auipc   [0:IQ_DEPTH-1];
    logic [31:0] ent_prednpc [0:IQ_DEPTH-1];
    logic        ent_predtk  [0:IQ_DEPTH-1];
    logic [1:0]  ent_predty  [0:IQ_DEPTH-1];

    logic [IQ_DEPTH-1:0] ent_ready;
    logic [IQ_DEPTH-1:0] ent_sel;
    logic [IQ_DEPTH-1:0] ent_uses1;
    logic [IQ_DEPTH-1:0] ent_uses2;

    logic        free_exist;
    logic [0:0]  free_idx;
    logic        sel_exist;
    logic [0:0]  sel_idx;
    logic        disp_fire;
    logic        issue_fire;
    logic        bypass_fire;
    logic        disp_uses1;
    logic        disp_uses2;

    logic [IQ_DEPTH-1:0] flush_mask;
    logic [IQ_DEPTH-1:0] valid_next;
    logic [IQ_DEPTH-1:0] r1rdy_next;
    logic [IQ_DEPTH-1:0] r2rdy_next;

    logic [31:0] sel_insn;
    logic [31:0] issue_imm_c;

    integer fi;
    integer rei;
    integer si;
    integer sei;
    integer fmi;
    integer rni;
    integer vni;
    integer rsti;
    integer dsi;

    // A slot that is issuing this cycle is freed at the end of the cycle,
    // so it can accept a newly dispatched ALU op in the same cycle.  This
    // removes the one-cycle dispatch bubble that otherwise serializes ALU
    // dispatch behind an issuing entry (a younger independent ALU must be
    // able to enter the queue while an older load owns the memory pipe).
    always_comb begin
        free_exist = 1'b0;
        free_idx   = 1'b0;
        for (fi = 0; fi < IQ_DEPTH; fi = fi + 1) begin
            if (!free_exist &&
                (!ent_valid[fi] || (issue_fire && (sel_idx == fi[0])))) begin
                free_exist = 1'b1;
                free_idx   = fi[0];
            end
        end
    end

    always_comb begin
        for (rei = 0; rei < IQ_DEPTH; rei = rei + 1) begin
            ent_uses1[rei] = ent_br[rei] || ent_jalr[rei] ||
                             (!ent_jal[rei] && !ent_auipc[rei] &&
                              !(ent_useimm[rei] && (ent_wb_sel[rei] == 3'b011)));
            ent_uses2[rei] = ent_br[rei] ||
                             (!ent_useimm[rei] && !ent_jal[rei] &&
                              !ent_jalr[rei] && !ent_auipc[rei]);
        end
    end

    assign disp_uses1 = iq_disp_is_branch || iq_disp_is_jalr ||
                        (!iq_disp_is_jal && !iq_disp_is_auipc &&
                         !(iq_disp_use_imm && (iq_disp_wb_sel == 3'b011)));
    assign disp_uses2 = iq_disp_is_branch ||
                        (!iq_disp_use_imm && !iq_disp_is_jal &&
                         !iq_disp_is_jalr && !iq_disp_is_auipc);

    always_comb begin
        for (rei = 0; rei < IQ_DEPTH; rei = rei + 1) begin
            ent_ready[rei] = ent_valid[rei] &&
                             (!ent_uses1[rei] || (ent_prs1[rei] == 6'd0) || ent_r1rdy[rei]) &&
                             (!ent_uses2[rei] || (ent_prs2[rei] == 6'd0) || ent_r2rdy[rei]);
        end
    end

    always_comb begin
        sel_exist = 1'b0;
        sel_idx   = 1'b0;
        for (si = 0; si < IQ_DEPTH; si = si + 1) begin
            if (ent_ready[si] && !sel_exist) begin
                sel_exist = 1'b1;
                sel_idx   = si[0];
            end
        end
    end

    always_comb begin
        for (sei = 0; sei < IQ_DEPTH; sei = sei + 1) begin
            ent_sel[sei] = sel_exist && (sel_idx == sei[0]);
        end
    end

    always_comb begin
        flush_mask = '0;
        for (fmi = 0; fmi < IQ_DEPTH; fmi = fmi + 1) begin
            if (flush && ent_valid[fmi]) begin
                if ((ent_rob[fmi] - rob_head_index) >=
                    (flush_rob_index - rob_head_index)) begin
                    flush_mask[fmi] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (rni = 0; rni < IQ_DEPTH; rni = rni + 1) begin
            r1rdy_next[rni] = (ent_prs1[rni] == 6'd0) ? 1'b1 : ent_r1rdy[rni];
            r2rdy_next[rni] = (ent_prs2[rni] == 6'd0) ? 1'b1 : ent_r2rdy[rni];
            if (ent_valid[rni]) begin
                if (alu_complete_valid && (ent_prs1[rni] == alu_complete_prd) && (ent_prs1[rni] != 6'd0))
                    r1rdy_next[rni] = 1'b1;
                if (load_complete_valid && (ent_prs1[rni] == load_complete_prd) && (ent_prs1[rni] != 6'd0))
                    r1rdy_next[rni] = 1'b1;
                if (alu_complete_valid && (ent_prs2[rni] == alu_complete_prd) && (ent_prs2[rni] != 6'd0))
                    r2rdy_next[rni] = 1'b1;
                if (load_complete_valid && (ent_prs2[rni] == load_complete_prd) && (ent_prs2[rni] != 6'd0))
                    r2rdy_next[rni] = 1'b1;
            end
        end
    end

    always_comb begin
        for (vni = 0; vni < IQ_DEPTH; vni = vni + 1) begin
            valid_next[vni] = ent_valid[vni];
            if (flush_mask[vni]) valid_next[vni] = 1'b0;
            if (issue_fire && (sel_idx == vni[0])) valid_next[vni] = 1'b0;
            if (disp_fire && (free_idx == vni[0])) valid_next[vni] = 1'b1;
        end
    end

    assign disp_fire   = iq_disp_valid && iq_disp_ready && !halted;
    assign issue_fire  = issue_valid && issue_ready && !halted;
    assign bypass_fire = issue_fire && (ent_rob[sel_idx] != rob_head_index);

    assign iq_disp_ready = free_exist && !halted && !flush;
    assign issue_valid   = sel_exist && !halted && !flush;

    assign sel_insn = issue_valid ? ent_insn[sel_idx] : 32'd0;

    always_comb begin
        case (sel_insn[6:0])
            7'b0010011, 7'b0000011, 7'b1100111:
                issue_imm_c = {{20{sel_insn[31]}}, sel_insn[31:20]};
            7'b0100011:
                issue_imm_c = {{20{sel_insn[31]}}, sel_insn[31:25], sel_insn[11:7]};
            7'b1100011:
                issue_imm_c = {{19{sel_insn[31]}}, sel_insn[31], sel_insn[7],
                               sel_insn[30:25], sel_insn[11:8], 1'b0};
            7'b0110111, 7'b0010111:
                issue_imm_c = {sel_insn[31:12], 12'b0};
            7'b1101111:
                issue_imm_c = {{11{sel_insn[31]}}, sel_insn[31], sel_insn[19:12],
                               sel_insn[20], sel_insn[30:21], 1'b0};
            default:
                issue_imm_c = 32'b0;
        endcase
    end

    // Operand isolation at the queue boundary: the payload buses are held at
    // zero whenever no entry is being accepted, so the 32-bit ALU operand
    // and immediate nets do not toggle on idle cycles.
    assign issue_pc           = issue_valid ? ent_pc[sel_idx] : 32'd0;
    assign issue_insn         = ent_insn[sel_idx];
    assign issue_rob_index    = ent_rob[sel_idx];
    assign issue_prs1         = ent_prs1[sel_idx];
    assign issue_prs2         = ent_prs2[sel_idx];
    assign issue_pdst         = ent_pdst[sel_idx];
    assign issue_operand1     = issue_valid ? iq_prf_rdata1 : 32'd0;
    assign issue_operand2     = issue_valid ? iq_prf_rdata2 : 32'd0;
    assign issue_imm          = issue_valid ? issue_imm_c : 32'd0;
    assign issue_alu_op       = ent_alu_op[sel_idx];
    assign issue_wb_sel       = ent_wb_sel[sel_idx];
    assign issue_is_branch    = ent_br[sel_idx];
    assign issue_is_jal       = ent_jal[sel_idx];
    assign issue_is_jalr      = ent_jalr[sel_idx];
    assign issue_use_imm      = ent_useimm[sel_idx];
    assign issue_is_auipc     = ent_auipc[sel_idx];
    assign issue_pred_next_pc = ent_prednpc[sel_idx];
    assign issue_pred_taken   = ent_predtk[sel_idx];
    assign issue_pred_type    = ent_predty[sel_idx];

    assign iq_prf_rs1_addr = ent_prs1[sel_idx];
    assign iq_prf_rs2_addr = ent_prs2[sel_idx];

    assign dbg_ooo_issue  = issue_fire;
    assign dbg_ooo_bypass = bypass_fire;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (rsti = 0; rsti < IQ_DEPTH; rsti = rsti + 1) begin
                ent_valid[rsti]   <= 1'b0;
                ent_pc[rsti]      <= 32'd0;
                ent_insn[rsti]    <= 32'd0;
                ent_rob[rsti]     <= 4'd0;
                ent_prs1[rsti]    <= 6'd0;
                ent_prs2[rsti]    <= 6'd0;
                ent_pdst[rsti]    <= 6'd0;
                ent_r1rdy[rsti]   <= 1'b0;
                ent_r2rdy[rsti]   <= 1'b0;
                ent_alu_op[rsti]  <= 5'd0;
                ent_wb_sel[rsti]  <= 3'd0;
                ent_br[rsti]      <= 1'b0;
                ent_jal[rsti]     <= 1'b0;
                ent_jalr[rsti]    <= 1'b0;
                ent_useimm[rsti]  <= 1'b0;
                ent_auipc[rsti]   <= 1'b0;
                ent_prednpc[rsti] <= 32'd0;
                ent_predtk[rsti]  <= 1'b0;
                ent_predty[rsti]  <= 2'd0;
            end
        end else begin
            // Per-entry write enables: only the entries whose valid or
            // ready state actually changes are rewritten this cycle.
            for (rsti = 0; rsti < IQ_DEPTH; rsti = rsti + 1) begin
                if (valid_next[rsti] != ent_valid[rsti]) begin
                    ent_valid[rsti] <= valid_next[rsti];
                end
                if (valid_next[rsti]) begin
                    if (r1rdy_next[rsti] != ent_r1rdy[rsti]) ent_r1rdy[rsti] <= r1rdy_next[rsti];
                    if (r2rdy_next[rsti] != ent_r2rdy[rsti]) ent_r2rdy[rsti] <= r2rdy_next[rsti];
                end else if (ent_r1rdy[rsti] || ent_r2rdy[rsti]) begin
                    ent_r1rdy[rsti] <= 1'b0;
                    ent_r2rdy[rsti] <= 1'b0;
                end
            end
            if (disp_fire) begin
                for (dsi = 0; dsi < IQ_DEPTH; dsi = dsi + 1) begin
                    if (free_idx == dsi[0]) begin
                        ent_pc[dsi]      <= iq_disp_pc;
                        ent_insn[dsi]    <= iq_disp_insn;
                        ent_rob[dsi]     <= iq_disp_rob_index;
                        ent_prs1[dsi]    <= iq_disp_prs1;
                        ent_prs2[dsi]    <= iq_disp_prs2;
                        ent_pdst[dsi]    <= iq_disp_pdst;
                        ent_r1rdy[dsi]   <= !disp_uses1 || (iq_disp_prs1 == 6'd0) || iq_disp_rs1_ready ||
                                             (alu_complete_valid && (iq_disp_prs1 == alu_complete_prd) && (iq_disp_prs1 != 6'd0)) ||
                                             (load_complete_valid && (iq_disp_prs1 == load_complete_prd) && (iq_disp_prs1 != 6'd0));
                        ent_r2rdy[dsi]   <= !disp_uses2 || (iq_disp_prs2 == 6'd0) || iq_disp_rs2_ready ||
                                             (alu_complete_valid && (iq_disp_prs2 == alu_complete_prd) && (iq_disp_prs2 != 6'd0)) ||
                                             (load_complete_valid && (iq_disp_prs2 == load_complete_prd) && (iq_disp_prs2 != 6'd0));
                        ent_alu_op[dsi]  <= iq_disp_alu_op;
                        ent_wb_sel[dsi]  <= iq_disp_wb_sel;
                        ent_br[dsi]      <= iq_disp_is_branch;
                        ent_jal[dsi]     <= iq_disp_is_jal;
                        ent_jalr[dsi]    <= iq_disp_is_jalr;
                        ent_useimm[dsi]  <= iq_disp_use_imm;
                        ent_auipc[dsi]   <= iq_disp_is_auipc;
                        ent_prednpc[dsi] <= iq_disp_pred_next_pc;
                        ent_predtk[dsi]  <= iq_disp_pred_taken;
                        ent_predty[dsi]  <= iq_disp_pred_type;
                    end
                end
            end
        end
    end

endmodule

// file: rtl/load_store_unit.sv
module load_store_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [3:0]  flush_rob_index,
    input  logic [1:0]  flush_epoch,
    input  logic        halted,
    input  logic        lsu_disp_valid,
    output logic        lsu_disp_ready,
    input  logic [31:0] lsu_disp_pc,
    input  logic [31:0] lsu_disp_insn,
    input  logic [3:0]  lsu_disp_rob_index,
    input  logic [5:0]  lsu_disp_prs1,
    input  logic [5:0]  lsu_disp_prs2,
    input  logic [5:0]  lsu_disp_pdst,
    input  logic        lsu_disp_rs1_ready,
    input  logic        lsu_disp_rs2_ready,
    input  logic [31:0] lsu_disp_imm,
    input  logic        lsu_disp_is_load,
    input  logic        lsu_disp_is_store,
    input  logic [1:0]  lsu_disp_mem_size,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    output logic [5:0]  lsu_prf_rs1_addr,
    output logic [5:0]  lsu_prf_rs2_addr,
    input  logic [31:0] lsu_prf_rdata1,
    input  logic [31:0] lsu_prf_rdata2,
    input  logic        store_commit_valid,
    input  logic [3:0]  store_commit_rob_index,
    output logic        store_done_valid,
    output logic [3:0]  store_done_rob_index,
    output logic        load_complete_valid,
    output logic [3:0]  load_complete_rob_index,
    output logic [5:0]  load_complete_prd,
    output logic [31:0] load_complete_data,
    output logic        lsu_dcache_req_valid,
    output logic        lsu_dcache_req_we,
    output logic [31:0] lsu_dcache_req_addr,
    output logic [31:0] lsu_dcache_req_wdata,
    output logic [3:0]  lsu_dcache_req_be,
    output logic [3:0]  lsu_dcache_req_rob_index,
    output logic [1:0]  lsu_dcache_req_epoch,
    input  logic        lsu_dcache_req_ready,
    input  logic        lsu_dcache_resp_valid,
    input  logic [31:0] lsu_dcache_resp_rdata,
    input  logic [1:0]  lsu_dcache_resp_epoch,
    output logic        lsu_dcache_wait,
    output logic        lsu_idle
);

    // ------------------------------------------------------------------
    // Staging entry: next memory operation, released to the dcache as soon
    // as it can be presented. Freeing this slot early keeps the renamer /
    // dispatch path unblocked while a long external load is outstanding.
    // ------------------------------------------------------------------
    logic        ent_valid;
    logic [31:0] ent_insn;
    logic [3:0]  ent_rob;
    logic [5:0]  ent_prs1;
    logic [5:0]  ent_prs2;
    logic [5:0]  ent_pdst;
    logic        ent_rs1_ready;
    logic        ent_rs2_ready;
    logic        ent_is_load;
    logic        ent_is_store;
    logic [1:0]  ent_epoch;
    logic        ent_committed;

    // ------------------------------------------------------------------
    // Request tracker: exactly one outstanding dcache request.
    // ------------------------------------------------------------------
    logic        req_active;   // presented to dcache, waiting for accept
    logic        resp_wait;    // accepted, waiting for response
    logic        rq_we;
    logic [31:0] rq_addr;
    logic [31:0] rq_wdata;
    logic [3:0]  rq_be;
    logic [3:0]  rq_rob;
    logic [1:0]  rq_epoch;
    logic [5:0]  rq_pdst;
    logic        rq_is_load;
    logic        rq_is_store;
    logic [2:0]  rq_funct3;
    logic [1:0]  rq_addrlo;

    // ------------------------------------------------------------------
    // Combinational helpers
    // ------------------------------------------------------------------
    logic [31:0] head_imm;
    logic [31:0] head_addr;
    logic [31:0] head_wdata;
    logic [3:0]  head_be;
    logic [2:0]  head_funct3;
    logic        head_rs1_wake;
    logic        head_rs2_wake;
    logic        head_rs1_ok;
    logic        head_rs2_ok;
    logic        head_load_ready;
    logic        head_store_ready;
    logic        head_can_issue;
    logic        disp_fire;
    logic        disp_rs1_eff;
    logic        disp_rs2_eff;
    logic        store_commit_match;
    logic        squash_ent;
    logic        start_acc;
    logic        held_acc;
    logic        resp_match_rq;
    logic        resp_match_held;
    logic        resp_match_ent;
    logic        load_done;
    logic        store_done;
    logic [3:0]  done_rob;
    logic [5:0]  done_pdst;
    logic [2:0]  fmt_f3;
    logic [1:0]  fmt_a;
    logic [31:0] load_word;
    logic [31:0] load_data_c;

    assign lsu_prf_rs1_addr = ent_valid ? ent_prs1 : 6'd0;
    assign lsu_prf_rs2_addr = ent_valid ? ent_prs2 : 6'd0;

    assign head_imm = ent_is_store ?
                      {{20{ent_insn[31]}}, ent_insn[31:25], ent_insn[11:7]} :
                      {{20{ent_insn[31]}}, ent_insn[31:20]};
    assign head_addr = lsu_prf_rdata1 + head_imm;
    assign head_funct3 = ent_insn[14:12];

    always_comb begin
        head_be    = 4'b0000;
        head_wdata = 32'd0;
        case (head_funct3[1:0])
            2'b00: begin
                head_be    = 4'b0001 << head_addr[1:0];
                head_wdata = {4{lsu_prf_rdata2[7:0]}};
            end
            2'b01: begin
                head_be    = head_addr[1] ? 4'b1100 : 4'b0011;
                head_wdata = {2{lsu_prf_rdata2[15:0]}};
            end
            default: begin
                head_be    = 4'b1111;
                head_wdata = lsu_prf_rdata2;
            end
        endcase
    end

    assign head_rs1_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == ent_prs1)) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == ent_prs1));
    assign head_rs2_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == ent_prs2)) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == ent_prs2));

    assign head_rs1_ok = (ent_prs1 == 6'd0) || ent_rs1_ready;
    assign head_rs2_ok = (ent_prs2 == 6'd0) || ent_rs2_ready;

    assign head_load_ready  = ent_is_load && head_rs1_ok;
    assign head_store_ready = ent_is_store && ent_committed &&
                              head_rs1_ok && head_rs2_ok;

    assign head_can_issue = ent_valid && !req_active && !resp_wait &&
                            !halted && !flush &&
                            (head_store_ready || head_load_ready);

    assign store_commit_match = store_commit_valid && ent_valid &&
                                (store_commit_rob_index == ent_rob);

    assign squash_ent = flush && ent_valid &&
                        !((ent_rob - flush_rob_index) & 4'h8);

    assign lsu_disp_ready = rst_n && !halted && !flush &&
                            (!ent_valid || head_can_issue);
    assign disp_fire = lsu_disp_valid && lsu_disp_ready;

    assign lsu_dcache_req_valid     = req_active || head_can_issue;
    assign lsu_dcache_req_we        = req_active ? rq_we    : ent_is_store;
    assign lsu_dcache_req_addr      = req_active ? rq_addr  : head_addr;
    assign lsu_dcache_req_wdata     = req_active ? rq_wdata : head_wdata;
    assign lsu_dcache_req_be        = req_active ? rq_be    : head_be;
    assign lsu_dcache_req_rob_index = req_active ? rq_rob   : ent_rob;
    assign lsu_dcache_req_epoch     = req_active ? rq_epoch : ent_epoch;

    assign start_acc = head_can_issue && lsu_dcache_req_ready;
    assign held_acc  = req_active && lsu_dcache_req_ready;

    assign resp_match_rq   = resp_wait && lsu_dcache_resp_valid &&
                             (lsu_dcache_resp_epoch == rq_epoch);
    assign resp_match_held = held_acc && lsu_dcache_resp_valid &&
                             (lsu_dcache_resp_epoch == rq_epoch);
    assign resp_match_ent  = start_acc && lsu_dcache_resp_valid &&
                             (lsu_dcache_resp_epoch == ent_epoch);

    always_comb begin
        load_done  = 1'b0;
        store_done = 1'b0;
        done_rob   = 4'd0;
        done_pdst  = 6'd0;
        if (resp_wait) begin
            done_rob   = rq_rob;
            done_pdst  = rq_pdst;
            load_done  = resp_match_rq && rq_is_load;
            store_done = resp_match_rq && rq_is_store;
        end else if (req_active) begin
            done_rob   = rq_rob;
            done_pdst  = rq_pdst;
            load_done  = resp_match_held && rq_is_load;
            store_done = resp_match_held && rq_is_store;
        end else if (head_can_issue) begin
            done_rob   = ent_rob;
            done_pdst  = ent_pdst;
            load_done  = resp_match_ent && ent_is_load;
            store_done = resp_match_ent && ent_is_store;
        end
    end

    always_comb begin
        if (resp_wait || req_active) begin
            fmt_f3 = rq_funct3;
            fmt_a  = rq_addrlo;
        end else begin
            fmt_f3 = head_funct3;
            fmt_a  = head_addr[1:0];
        end
    end

    assign load_word = lsu_dcache_resp_rdata;

    always_comb begin
        load_data_c = load_word;
        case (fmt_f3)
            3'b000: begin
                case (fmt_a)
                    2'd0:    load_data_c = {{24{load_word[7]}},  load_word[7:0]};
                    2'd1:    load_data_c = {{24{load_word[15]}}, load_word[15:8]};
                    2'd2:    load_data_c = {{24{load_word[23]}}, load_word[23:16]};
                    default: load_data_c = {{24{load_word[31]}}, load_word[31:24]};
                endcase
            end
            3'b100: begin
                case (fmt_a)
                    2'd0:    load_data_c = {24'd0, load_word[7:0]};
                    2'd1:    load_data_c = {24'd0, load_word[15:8]};
                    2'd2:    load_data_c = {24'd0, load_word[23:16]};
                    default: load_data_c = {24'd0, load_word[31:24]};
                endcase
            end
            3'b001: begin
                if (fmt_a[1])
                    load_data_c = {{16{load_word[31]}}, load_word[31:16]};
                else
                    load_data_c = {{16{load_word[15]}}, load_word[15:0]};
            end
            3'b101: begin
                if (fmt_a[1])
                    load_data_c = {16'd0, load_word[31:16]};
                else
                    load_data_c = {16'd0, load_word[15:0]};
            end
            default: load_data_c = load_word;
        endcase
    end

    assign load_complete_valid     = load_done;
    assign load_complete_rob_index = done_rob;
    assign load_complete_prd       = done_pdst;
    assign load_complete_data      = load_data_c;

    assign store_done_valid     = store_done;
    assign store_done_rob_index = done_rob;

    assign lsu_dcache_wait = (req_active || resp_wait) && !lsu_dcache_resp_valid;
    assign lsu_idle        = !ent_valid && !req_active && !resp_wait;

    assign disp_rs1_eff = (lsu_disp_prs1 == 6'd0) || lsu_disp_rs1_ready ||
                          (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                           (alu_complete_prd == lsu_disp_prs1)) ||
                          (load_complete_valid && (load_complete_prd != 6'd0) &&
                           (load_complete_prd == lsu_disp_prs1));
    assign disp_rs2_eff = (lsu_disp_prs2 == 6'd0) || lsu_disp_rs2_ready ||
                          (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                           (alu_complete_prd == lsu_disp_prs2)) ||
                          (load_complete_valid && (load_complete_prd != 6'd0) &&
                           (load_complete_prd == lsu_disp_prs2));

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ent_valid      <= 1'b0;
            ent_insn       <= 32'd0;
            ent_rob        <= 4'd0;
            ent_prs1       <= 6'd0;
            ent_prs2       <= 6'd0;
            ent_pdst       <= 6'd0;
            ent_rs1_ready  <= 1'b0;
            ent_rs2_ready  <= 1'b0;
            ent_is_load    <= 1'b0;
            ent_is_store   <= 1'b0;
            ent_epoch      <= 2'd0;
            ent_committed  <= 1'b0;
            req_active     <= 1'b0;
            resp_wait      <= 1'b0;
            rq_we          <= 1'b0;
            rq_addr        <= 32'd0;
            rq_wdata       <= 32'd0;
            rq_be          <= 4'd0;
            rq_rob         <= 4'd0;
            rq_epoch       <= 2'd0;
            rq_pdst        <= 6'd0;
            rq_is_load     <= 1'b0;
            rq_is_store    <= 1'b0;
            rq_funct3      <= 3'd0;
            rq_addrlo      <= 2'd0;
        end else begin
            if (ent_valid) begin
                if (head_rs1_wake) ent_rs1_ready <= 1'b1;
                if (head_rs2_wake) ent_rs2_ready <= 1'b1;
            end

            if (store_commit_match) ent_committed <= 1'b1;

            if (disp_fire) begin
                ent_valid      <= 1'b1;
                ent_insn       <= lsu_disp_insn;
                ent_rob        <= lsu_disp_rob_index;
                ent_prs1       <= lsu_disp_prs1;
                ent_prs2       <= lsu_disp_prs2;
                ent_pdst       <= lsu_disp_pdst;
                ent_rs1_ready  <= disp_rs1_eff;
                ent_rs2_ready  <= disp_rs2_eff;
                ent_is_load    <= lsu_disp_is_load;
                ent_is_store   <= lsu_disp_is_store;
                ent_epoch      <= flush_epoch;
                ent_committed  <= lsu_disp_is_store && store_commit_valid &&
                                  (store_commit_rob_index == lsu_disp_rob_index);
            end else if (head_can_issue || squash_ent) begin
                ent_valid <= 1'b0;
            end

            if (head_can_issue) begin
                rq_we       <= ent_is_store;
                rq_addr     <= head_addr;
                rq_wdata    <= head_wdata;
                rq_be       <= head_be;
                rq_rob      <= ent_rob;
                rq_epoch    <= ent_epoch;
                rq_pdst     <= ent_pdst;
                rq_is_load  <= ent_is_load;
                rq_is_store <= ent_is_store;
                rq_funct3   <= head_funct3;
                rq_addrlo   <= head_addr[1:0];
                if (lsu_dcache_req_ready) begin
                    req_active <= 1'b0;
                    resp_wait  <= !lsu_dcache_resp_valid;
                end else begin
                    req_active <= 1'b1;
                    resp_wait  <= 1'b0;
                end
            end else if (req_active) begin
                if (lsu_dcache_req_ready) begin
                    req_active <= 1'b0;
                    resp_wait  <= !lsu_dcache_resp_valid;
                end
            end else if (resp_wait) begin
                if (lsu_dcache_resp_valid) begin
                    if (lsu_dcache_resp_epoch == rq_epoch) begin
                        resp_wait <= 1'b0;
                    end else begin
                        rq_epoch   <= flush_epoch;
                        req_active <= 1'b1;
                        resp_wait  <= 1'b0;
                    end
                end
            end
        end
    end

endmodule

// file: rtl/physical_register_file.sv
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

// file: rtl/rename_unit.sv
module rename_unit (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        flush,
    input  logic [3:0]  flush_rob_index,
    input  logic        halted,
    input  logic        ecall_pending,
    input  logic        id_valid,
    output logic        id_ready,
    input  logic [31:0] id_pc,
    input  logic [31:0] id_insn,
    input  logic [4:0]  id_rs1,
    input  logic [4:0]  id_rs2,
    input  logic [4:0]  id_rd,
    input  logic [31:0] id_imm,
    input  logic [4:0]  id_alu_op,
    input  logic [2:0]  id_wb_sel,
    input  logic        id_is_load,
    input  logic        id_is_store,
    input  logic [1:0]  id_mem_size,
    input  logic        id_is_branch,
    input  logic        id_is_jal,
    input  logic        id_is_jalr,
    input  logic        id_is_ecall,
    input  logic        id_reg_write,
    input  logic        id_use_imm,
    input  logic        id_is_auipc,
    input  logic [31:0] id_pred_next_pc,
    input  logic        id_pred_taken,
    input  logic [1:0]  id_pred_type,
    input  logic        id_pred_hit,
    output logic        rob_alloc_valid,
    input  logic        rob_alloc_ready,
    input  logic [3:0]  rob_alloc_index,
    output logic [31:0] rob_alloc_pc,
    output logic [31:0] rob_alloc_insn,
    output logic [5:0]  rob_alloc_pdst,
    output logic [5:0]  rob_alloc_old_prd,
    output logic [4:0]  rob_alloc_arch_rd,
    output logic        rob_alloc_is_control,
    output logic        rob_alloc_is_store,
    output logic        rob_alloc_is_ecall,
    output logic        rob_alloc_reg_write,
    output logic        iq_disp_valid,
    input  logic        iq_disp_ready,
    output logic [31:0] iq_disp_pc,
    output logic [31:0] iq_disp_insn,
    output logic [3:0]  iq_disp_rob_index,
    output logic [5:0]  iq_disp_prs1,
    output logic [5:0]  iq_disp_prs2,
    output logic [5:0]  iq_disp_pdst,
    output logic        iq_disp_rs1_ready,
    output logic        iq_disp_rs2_ready,
    output logic [31:0] iq_disp_imm,
    output logic [4:0]  iq_disp_alu_op,
    output logic [2:0]  iq_disp_wb_sel,
    output logic        iq_disp_is_branch,
    output logic        iq_disp_is_jal,
    output logic        iq_disp_is_jalr,
    output logic        iq_disp_use_imm,
    output logic        iq_disp_is_auipc,
    output logic [31:0] iq_disp_pred_next_pc,
    output logic        iq_disp_pred_taken,
    output logic [1:0]  iq_disp_pred_type,
    output logic        lsu_disp_valid,
    input  logic        lsu_disp_ready,
    output logic [31:0] lsu_disp_pc,
    output logic [31:0] lsu_disp_insn,
    output logic [3:0]  lsu_disp_rob_index,
    output logic [5:0]  lsu_disp_prs1,
    output logic [5:0]  lsu_disp_prs2,
    output logic [5:0]  lsu_disp_pdst,
    output logic        lsu_disp_rs1_ready,
    output logic        lsu_disp_rs2_ready,
    output logic [31:0] lsu_disp_imm,
    output logic        lsu_disp_is_load,
    output logic        lsu_disp_is_store,
    output logic [1:0]  lsu_disp_mem_size,
    input  logic        alu_complete_valid,
    input  logic [5:0]  alu_complete_prd,
    input  logic        load_complete_valid,
    input  logic [5:0]  load_complete_prd
);

    localparam logic [5:0] PR_ZERO = 6'd0;

    logic [191:0] spec_map;
    logic [95:0]  free_list;
    logic [3:0]   free_head;
    logic [3:0]   free_tail;
    logic [4:0]   free_count;
    logic [47:0]  ready_tbl;

    logic [11:0]  slot_pdst;
    logic [11:0]  slot_old;
    logic [9:0]   slot_rd;
    logic [3:0]   cur_tail;

    localparam logic [191:0] SPEC_INIT = {
        6'd31, 6'd30, 6'd29, 6'd28, 6'd27, 6'd26, 6'd25, 6'd24,
        6'd23, 6'd22, 6'd21, 6'd20, 6'd19, 6'd18, 6'd17, 6'd16,
        6'd15, 6'd14, 6'd13, 6'd12, 6'd11, 6'd10, 6'd9,  6'd8,
        6'd7,  6'd6,  6'd5,  6'd4,  6'd3,  6'd2,  6'd1,  6'd0
    };

    localparam logic [95:0] FREE_INIT = {
        6'd47, 6'd46, 6'd45, 6'd44, 6'd43, 6'd42, 6'd41, 6'd40,
        6'd39, 6'd38, 6'd37, 6'd36, 6'd35, 6'd34, 6'd33, 6'd32
    };

    logic [5:0]  rs1_prd;
    logic [5:0]  rs2_prd;
    logic [5:0]  rd_prd;
    logic [5:0]  old_prd;
    logic        rs1_rdy;
    logic        rs2_rdy;
    logic        need_pr;
    logic        free_avail;
    logic        is_ctrl;
    logic        is_mem;
    logic        is_alu;
    logic        do_alloc;
    logic        do_flush;
    logic [3:0]  alloc_slot;
    logic [5:0]  pdst_new;
    logic [5:0]  spec_rs1;
    logic [5:0]  spec_rs2;
    logic [5:0]  spec_old;
    logic [5:0]  free_head_data;

    assign spec_rs1       = spec_map[6*id_rs1 +: 6];
    assign spec_rs2       = spec_map[6*id_rs2 +: 6];
    assign spec_old       = spec_map[6*id_rd  +: 6];
    assign free_head_data = free_list[6*free_head +: 6];

    assign rs1_prd = (id_rs1 == 5'd0) ? PR_ZERO : spec_rs1;
    assign rs2_prd = (id_rs2 == 5'd0) ? PR_ZERO : spec_rs2;

    assign rs1_rdy = (rs1_prd == PR_ZERO) ? 1'b1 :
                     (ready_tbl[rs1_prd] ||
                      (alu_complete_valid  && (alu_complete_prd  == rs1_prd)) ||
                      (load_complete_valid && (load_complete_prd == rs1_prd)));
    assign rs2_rdy = (rs2_prd == PR_ZERO) ? 1'b1 :
                     (ready_tbl[rs2_prd] ||
                      (alu_complete_valid  && (alu_complete_prd  == rs2_prd)) ||
                      (load_complete_valid && (load_complete_prd == rs2_prd)));

    assign need_pr    = id_reg_write && (id_rd != 5'd0);
    assign free_avail = (free_count != 5'd0);
    assign is_ctrl    = id_is_branch || id_is_jal || id_is_jalr;
    assign is_mem     = id_is_load || id_is_store;
    assign is_alu     = !is_mem && !id_is_ecall;

    assign do_alloc = id_valid && !halted && !flush && !ecall_pending && rob_alloc_ready &&
                      (!need_pr || free_avail) &&
                      (!is_alu || iq_disp_ready) &&
                      (!is_mem || lsu_disp_ready);
    assign id_ready = !halted && !flush && !ecall_pending && rob_alloc_ready &&
                      (!need_pr || free_avail) &&
                      (!is_alu || iq_disp_ready) &&
                      (!is_mem || lsu_disp_ready);
    assign do_flush   = flush && !halted;
    assign alloc_slot = rob_alloc_index;

    assign rd_prd   = need_pr ? free_head_data : PR_ZERO;
    assign old_prd  = need_pr ? spec_old       : PR_ZERO;
    assign pdst_new = need_pr ? rd_prd         : PR_ZERO;

    assign rob_alloc_valid        = do_alloc;
    assign rob_alloc_pc           = id_pc;
    assign rob_alloc_insn         = id_insn;
    assign rob_alloc_pdst         = rd_prd;
    assign rob_alloc_old_prd      = old_prd;
    assign rob_alloc_arch_rd      = id_rd;
    assign rob_alloc_is_control   = is_ctrl;
    assign rob_alloc_is_store     = id_is_store;
    assign rob_alloc_is_ecall     = id_is_ecall;
    assign rob_alloc_reg_write    = need_pr;

    assign iq_disp_valid          = do_alloc && is_alu;
    assign iq_disp_pc             = id_pc;
    assign iq_disp_insn           = id_insn;
    assign iq_disp_rob_index      = rob_alloc_index;
    assign iq_disp_prs1           = rs1_prd;
    assign iq_disp_prs2           = rs2_prd;
    assign iq_disp_pdst           = rd_prd;
    assign iq_disp_rs1_ready      = rs1_rdy;
    assign iq_disp_rs2_ready      = rs2_rdy;
    assign iq_disp_imm            = id_imm;
    assign iq_disp_alu_op         = id_alu_op;
    assign iq_disp_wb_sel         = id_wb_sel;
    assign iq_disp_is_branch      = id_is_branch;
    assign iq_disp_is_jal         = id_is_jal;
    assign iq_disp_is_jalr        = id_is_jalr;
    assign iq_disp_use_imm        = id_use_imm;
    assign iq_disp_is_auipc       = id_is_auipc;
    assign iq_disp_pred_next_pc   = id_pred_next_pc;
    assign iq_disp_pred_taken     = id_pred_taken;
    assign iq_disp_pred_type      = id_pred_type;

    assign lsu_disp_valid         = do_alloc && is_mem;
    assign lsu_disp_pc            = id_pc;
    assign lsu_disp_insn          = id_insn;
    assign lsu_disp_rob_index     = rob_alloc_index;
    assign lsu_disp_prs1          = rs1_prd;
    assign lsu_disp_prs2          = rs2_prd;
    assign lsu_disp_pdst          = rd_prd;
    assign lsu_disp_rs1_ready     = rs1_rdy;
    assign lsu_disp_rs2_ready     = rs2_rdy;
    assign lsu_disp_imm           = id_imm;
    assign lsu_disp_is_load       = id_is_load;
    assign lsu_disp_is_store      = id_is_store;
    assign lsu_disp_mem_size      = id_mem_size;

    logic [3:0]  flush_next4;
    logic        flush_young;
    logic [1:0]  flush_elig;
    logic        flush_push_en;
    logic [5:0]  flush_push_data;
    logic [4:0]  flush_rd;
    logic [5:0]  flush_old;
    logic        alloc_push_en;
    logic [5:0]  alloc_push_data;
    logic [5:0]  alloc_slot_pdst;
    logic [5:0]  alloc_slot_old;
    logic        free_push_en;
    logic [5:0]  free_push_data;

    assign flush_next4 = flush_rob_index + 4'd1;
    assign flush_young = do_flush && (cur_tail != flush_next4);

    assign flush_elig[0] = flush_young && (flush_next4[0] == 1'b0) &&
                           (slot_pdst[5:0] != PR_ZERO);
    assign flush_elig[1] = flush_young && (flush_next4[0] == 1'b1) &&
                           (slot_pdst[11:6] != PR_ZERO);

    assign flush_push_en   = flush_elig[0] | flush_elig[1];
    assign flush_push_data = flush_elig[0] ? slot_old[5:0] : slot_old[11:6];
    assign flush_rd        = flush_elig[0] ? slot_rd[4:0] : slot_rd[9:5];
    assign flush_old       = flush_elig[0] ? slot_old[5:0] : slot_old[11:6];

    assign alloc_slot_pdst = alloc_slot[0] ? slot_pdst[11:6] : slot_pdst[5:0];
    assign alloc_slot_old  = alloc_slot[0] ? slot_old[11:6] : slot_old[5:0];
    assign alloc_push_en   = do_alloc && (alloc_slot_pdst != PR_ZERO) &&
                             (alloc_slot_old != PR_ZERO);
    assign alloc_push_data = alloc_slot_old;

    assign free_push_en   = flush_push_en | alloc_push_en;
    assign free_push_data = flush_push_en ? flush_push_data : alloc_push_data;

    logic [191:0] spec_map_nxt;
    logic [95:0]  free_list_nxt;
    logic [11:0]  slot_pdst_nxt;
    logic [11:0]  slot_old_nxt;
    logic [9:0]   slot_rd_nxt;
    logic [3:0]   free_head_nxt;
    logic [3:0]   free_tail_nxt;
    logic [4:0]   free_count_nxt;
    logic [3:0]   cur_tail_nxt;
    logic [47:0]  ready_nxt;
    logic [47:0]  ready_set;
    logic [47:0]  ready_clr;

    genvar ga;
    generate
        for (ga = 0; ga < 32; ga = ga + 1) begin : gen_spec_map
            assign spec_map_nxt[6*ga +: 6] =
                (do_alloc && need_pr && (id_rd == ga[4:0])) ? rd_prd :
                (flush_push_en && (flush_rd == ga[4:0]))   ? flush_old :
                                                              spec_map[6*ga +: 6];
        end
    endgenerate

    genvar gfl;
    generate
        for (gfl = 0; gfl < 16; gfl = gfl + 1) begin : gen_free_list
            assign free_list_nxt[6*gfl +: 6] =
                (free_push_en && (free_tail == gfl[3:0])) ? free_push_data :
                                                            free_list[6*gfl +: 6];
        end
    endgenerate

    genvar gs;
    generate
        for (gs = 0; gs < 2; gs = gs + 1) begin : gen_slot
            assign slot_pdst_nxt[6*gs +: 6] =
                flush_elig[gs] ? PR_ZERO :
                (do_alloc && (alloc_slot[0] == gs[0])) ? pdst_new :
                                                         slot_pdst[6*gs +: 6];

            assign slot_old_nxt[6*gs +: 6] =
                flush_elig[gs] ? PR_ZERO :
                (do_alloc && (alloc_slot[0] == gs[0])) ? old_prd :
                                                         slot_old[6*gs +: 6];

            assign slot_rd_nxt[5*gs +: 5] =
                flush_elig[gs] ? 5'd0 :
                (do_alloc && (alloc_slot[0] == gs[0])) ? id_rd :
                                                         slot_rd[5*gs +: 5];
        end
    endgenerate

    assign ready_set = (alu_complete_valid  ? (48'd1 << alu_complete_prd)  : 48'd0) |
                       (load_complete_valid ? (48'd1 << load_complete_prd) : 48'd0);
    assign ready_clr = (do_alloc && need_pr) ? (48'd1 << rd_prd) : 48'd0;
    assign ready_nxt = (ready_tbl | ready_set) & ~ready_clr;

    assign free_head_nxt  = free_head + ((do_alloc && need_pr) ? 4'd1 : 4'd0);
    assign free_tail_nxt  = free_tail + (free_push_en ? 4'd1 : 4'd0);
    assign free_count_nxt = free_count + (free_push_en ? 5'd1 : 5'd0) -
                            ((do_alloc && need_pr) ? 5'd1 : 5'd0);
    assign cur_tail_nxt   = do_flush ? flush_next4 :
                            do_alloc ? (rob_alloc_index + 4'd1) : cur_tail;

    logic spec_map_en;
    logic free_list_en;
    logic free_head_en;
    logic free_tail_en;
    logic free_count_en;
    logic ready_en;
    logic slot_en;
    logic cur_tail_en;

    assign spec_map_en   = (do_alloc && need_pr) || flush_push_en;
    assign free_list_en  = free_push_en;
    assign free_head_en  = do_alloc && need_pr;
    assign free_tail_en  = free_push_en;
    assign free_count_en = (do_alloc && need_pr) || free_push_en;
    assign ready_en      = (|ready_set) || (|ready_clr);
    assign slot_en       = do_alloc || flush_push_en;
    assign cur_tail_en   = do_alloc || do_flush;

    always_ff @(posedge clk) begin : rename_state
        if (!rst_n) begin
            spec_map   <= SPEC_INIT;
            free_list  <= FREE_INIT;
            free_head  <= 4'd0;
            free_tail  <= 4'd0;
            free_count <= 5'd16;
            ready_tbl  <= {48{1'b1}};
            slot_pdst  <= 12'b0;
            slot_old   <= 12'b0;
            slot_rd    <= 10'b0;
            cur_tail   <= 4'd0;
        end else if (!halted) begin
            if (spec_map_en)   spec_map   <= spec_map_nxt;
            if (free_list_en)  free_list  <= free_list_nxt;
            if (free_head_en)  free_head  <= free_head_nxt;
            if (free_tail_en)  free_tail  <= free_tail_nxt;
            if (free_count_en) free_count <= free_count_nxt;
            if (ready_en)      ready_tbl  <= ready_nxt;
            if (slot_en) begin
                slot_pdst <= slot_pdst_nxt;
                slot_old  <= slot_old_nxt;
                slot_rd   <= slot_rd_nxt;
            end
            if (cur_tail_en)   cur_tail   <= cur_tail_nxt;
        end
    end

endmodule

// file: rtl/reorder_buffer.sv
module reorder_buffer (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        rob_alloc_valid,
    output logic        rob_alloc_ready,
    output logic [3:0]  rob_alloc_index,
    input  logic [31:0] rob_alloc_pc,
    input  logic [31:0] rob_alloc_insn,
    input  logic [5:0]  rob_alloc_pdst,
    input  logic [5:0]  rob_alloc_old_prd,
    input  logic [4:0]  rob_alloc_arch_rd,
    input  logic        rob_alloc_is_control,
    input  logic        rob_alloc_is_store,
    input  logic        rob_alloc_is_ecall,
    input  logic        rob_alloc_reg_write,
    output logic [3:0]  rob_head_index,
    input  logic        alu_complete_valid,
    input  logic [3:0]  alu_complete_rob_index,
    input  logic [31:0] alu_complete_data,
    input  logic        load_complete_valid,
    input  logic [3:0]  load_complete_rob_index,
    input  logic [31:0] load_complete_data,
    input  logic        resolve_valid,
    input  logic [3:0]  resolve_rob_index,
    input  logic        resolve_mispredict,
    input  logic [31:0] resolve_actual_next_pc,
    output logic        store_commit_valid,
    output logic [3:0]  store_commit_rob_index,
    input  logic        store_done_valid,
    input  logic [3:0]  store_done_rob_index,
    output logic        commit_valid,
    output logic [31:0] commit_pc,
    output logic [31:0] commit_insn,
    output logic [31:0] commit_value,
    output logic [4:0]  commit_arch_rd,
    output logic        commit_reg_write,
    output logic        commit_is_ecall,
    output logic        commit_old_prd_valid,
    output logic [5:0]  commit_old_prd,
    output logic        flush_valid,
    output logic [3:0]  flush_rob_index,
    output logic [31:0] flush_pc,
    output logic        ecall_pending
);

    localparam integer ROB_DEPTH = 2;

    logic [3:0] head;
    logic [3:0] tail;
    logic [3:0] count;

    logic        ent_valid    [0:1];
    logic [3:0]  ent_index    [0:1];
    logic        ent_complete [0:1];
    logic        ent_is_store [0:1];
    logic        ent_is_ecall [0:1];
    logic        ent_is_ctrl  [0:1];
    logic        ent_store_done [0:1];
    logic [31:0] ent_pc     [0:1];
    logic [31:0] ent_insn   [0:1];
    logic [31:0] ent_value  [0:1];
    logic [4:0]  ent_arch_rd[0:1];
    logic        ent_reg_write [0:1];

    logic [0:0] head_slot;
    logic [0:0] tail_slot;
    assign head_slot = head[0];
    assign tail_slot = tail[0];

    logic [3:0] tail_plus1;
    logic [3:0] head_plus1;
    logic       alloc_fire;
    logic       full;
    logic       empty;

    logic       head_valid;
    logic       head_complete;
    logic       head_is_store;
    logic       head_is_ecall;
    logic       head_store_done;
    logic       head_ready;
    logic       commit_fire;
    logic       commit_pop;

    logic       flush_fire;
    logic [3:0] flush_idx4;
    logic [3:0] flush_next4;
    logic [3:0] flush_pos4;
    logic [3:0] flush_keep4;
    logic [3:0] flush_cnt4;

    logic       pending_flush;
    logic [3:0] pending_flush_idx;
    logic [31:0] pending_flush_pc;

    integer ec_i;
    integer sq_i;

    assign tail_plus1 = tail + 4'd1;
    assign head_plus1 = head + 4'd1;
    assign full  = (count == 4'd2);
    assign empty = (count == 4'd0);

    assign alloc_fire = rob_alloc_valid && rob_alloc_ready;
    assign rob_alloc_ready = rst_n && !halted && !full && !ecall_pending && !flush_fire;
    assign rob_alloc_index = tail;

    assign rob_head_index = head;

    assign head_valid      = ent_valid[head_slot];
    assign head_complete   = ent_complete[head_slot];
    assign head_is_store   = ent_is_store[head_slot];
    assign head_is_ecall   = ent_is_ecall[head_slot];
    assign head_store_done = ent_store_done[head_slot];

    assign head_ready = head_valid && head_complete &&
                        (!head_is_store || head_store_done);

    assign commit_fire = head_ready && !halted && !flush_fire;
    assign commit_pop  = commit_fire && !head_is_ecall;

    assign commit_valid      = commit_fire;
    assign commit_pc         = ent_pc[head_slot];
    assign commit_insn       = ent_insn[head_slot];
    assign commit_value      = ent_value[head_slot];
    assign commit_arch_rd    = ent_arch_rd[head_slot];
    assign commit_reg_write  = ent_reg_write[head_slot];
    assign commit_is_ecall   = ent_is_ecall[head_slot];
    assign commit_old_prd_valid = ent_reg_write[head_slot];
    assign commit_old_prd    = 6'd0;

    assign store_commit_valid     = head_valid && head_is_store && !halted && !flush_fire;
    assign store_commit_rob_index = head;

    assign flush_fire = pending_flush && !halted;
    assign flush_idx4 = pending_flush_idx;
    assign flush_next4 = flush_idx4 + 4'd1;
    assign flush_pos4 = flush_idx4 - head;
    assign flush_keep4 = flush_pos4 + 4'd1;
    assign flush_cnt4 = count - flush_keep4;
    assign flush_valid = flush_fire;
    assign flush_rob_index = flush_idx4;
    assign flush_pc = pending_flush_pc;

    always_comb begin
        ecall_pending = 1'b0;
        for (ec_i = 0; ec_i < 2; ec_i = ec_i + 1) begin
            if (ent_valid[ec_i] && ent_is_ecall[ec_i]) ecall_pending = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= 4'd0;
            tail <= 4'd0;
            count <= 4'd0;
            pending_flush <= 1'b0;
            pending_flush_idx <= 4'd0;
            pending_flush_pc <= 32'd0;
            for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                ent_valid[sq_i]          <= 1'b0;
                ent_index[sq_i]          <= 4'd0;
                ent_complete[sq_i]       <= 1'b0;
                ent_is_store[sq_i]       <= 1'b0;
                ent_is_ecall[sq_i]       <= 1'b0;
                ent_is_ctrl[sq_i]        <= 1'b0;
                ent_store_done[sq_i]     <= 1'b0;
                ent_pc[sq_i]             <= 32'd0;
                ent_insn[sq_i]           <= 32'd0;
                ent_value[sq_i]          <= 32'd0;
                ent_arch_rd[sq_i]        <= 5'd0;
                ent_reg_write[sq_i]      <= 1'b0;
            end
        end else if (!halted) begin
            if (flush_fire) begin
                if (flush_cnt4 != 4'd0) begin
                    for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                        if (sq_i[0] == flush_next4[0]) begin
                            ent_valid[sq_i]          <= 1'b0;
                            ent_complete[sq_i]       <= 1'b0;
                            ent_is_store[sq_i]       <= 1'b0;
                            ent_is_ecall[sq_i]       <= 1'b0;
                            ent_is_ctrl[sq_i]        <= 1'b0;
                            ent_store_done[sq_i]     <= 1'b0;
                        end
                    end
                end
                tail <= flush_next4;
                count <= flush_keep4;
                pending_flush <= 1'b0;
            end else begin
                if (commit_pop) begin
                    for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                        if (head_slot == sq_i[0]) begin
                            ent_valid[sq_i]          <= 1'b0;
                            ent_complete[sq_i]       <= 1'b0;
                            ent_is_store[sq_i]       <= 1'b0;
                            ent_is_ecall[sq_i]       <= 1'b0;
                            ent_is_ctrl[sq_i]        <= 1'b0;
                            ent_store_done[sq_i]     <= 1'b0;
                        end
                    end
                    head <= head_plus1;
                end

                if (alloc_fire) begin
                    for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                        if (tail_slot == sq_i[0]) begin
                            ent_valid[sq_i]           <= 1'b1;
                            ent_index[sq_i]           <= tail;
                            ent_complete[sq_i]        <= rob_alloc_is_ecall;
                            ent_is_store[sq_i]        <= rob_alloc_is_store;
                            ent_is_ecall[sq_i]        <= rob_alloc_is_ecall;
                            ent_is_ctrl[sq_i]         <= rob_alloc_is_control;
                            ent_store_done[sq_i]      <= 1'b0;
                            ent_pc[sq_i]              <= rob_alloc_pc;
                            ent_insn[sq_i]            <= rob_alloc_insn;
                            ent_value[sq_i]           <= 32'd0;
                            ent_arch_rd[sq_i]         <= rob_alloc_arch_rd;
                            ent_reg_write[sq_i]       <= rob_alloc_reg_write;
                        end
                    end
                    tail <= tail_plus1;
                end

                if (commit_pop && alloc_fire) count <= count;
                else if (commit_pop)          count <= count - 4'd1;
                else if (alloc_fire)          count <= count + 4'd1;
            end

            if (alu_complete_valid) begin
                for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                    if (alu_complete_rob_index[0] == sq_i[0]) begin
                        if (ent_valid[sq_i] && (ent_index[sq_i] == alu_complete_rob_index)) begin
                            ent_complete[sq_i] <= 1'b1;
                            ent_value[sq_i]    <= alu_complete_data;
                        end
                    end
                end
            end

            if (load_complete_valid) begin
                for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                    if (load_complete_rob_index[0] == sq_i[0]) begin
                        if (ent_valid[sq_i] && (ent_index[sq_i] == load_complete_rob_index)) begin
                            ent_complete[sq_i] <= 1'b1;
                            ent_value[sq_i]    <= load_complete_data;
                        end
                    end
                end
            end

            if (store_done_valid) begin
                for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                    if (store_done_rob_index[0] == sq_i[0]) begin
                        if (ent_valid[sq_i] && (ent_index[sq_i] == store_done_rob_index)) begin
                            ent_store_done[sq_i] <= 1'b1;
                            ent_complete[sq_i]   <= 1'b1;
                        end
                    end
                end
            end

            if (resolve_valid && !flush_fire) begin
                for (sq_i = 0; sq_i < 2; sq_i = sq_i + 1) begin
                    if (resolve_rob_index[0] == sq_i[0]) begin
                        if (ent_valid[sq_i] &&
                            (ent_index[sq_i] == resolve_rob_index) &&
                            ent_is_ctrl[sq_i]) begin
                            if (resolve_mispredict && !pending_flush) begin
                                pending_flush     <= 1'b1;
                                pending_flush_idx <= resolve_rob_index;
                                pending_flush_pc  <= resolve_actual_next_pc;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule

// file: rtl/rv32i5.sv
module rv32i5 (
    input  logic        clk,
    input  logic        rst_n,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    output logic        imem_valid,
    input  logic        imem_ready,
    output logic        dmem_valid,
    output logic        dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    output logic [3:0]  dmem_be,
    input  logic [31:0] dmem_rdata,
    input  logic        dmem_ready,
    input  logic [4:0]  dbg_reg_addr,
    output logic [31:0] dbg_reg_data,
    output logic        halted,
    output logic [31:0] exit_code,
    output logic [2:0]  dbg_features,
    output logic        dbg_retire_valid,
    output logic [31:0] dbg_retire_pc,
    output logic [31:0] dbg_retire_insn,
    output logic        dbg_bp_resolve,
    output logic        dbg_bp_mispredict,
    output logic        dbg_ooo_issue,
    output logic        dbg_ooo_bypass
);

    localparam logic [1:0] PT_NONE = 2'b00;
    localparam logic [1:0] PT_COND = 2'b01;
    localparam logic [1:0] PT_JAL  = 2'b10;
    localparam logic [1:0] PT_JALR = 2'b11;

    logic [1:0]  flush_epoch;
    logic        flush;
    logic [3:0]  flush_rob_index;
    logic [31:0] redirect_pc;
    logic        ecall_pending;
    logic        ecall_seen;
    logic        ecall_accept;
    logic        if_ecall_stop;
    logic        bus_idle;

    logic        rob_ecall_pending;
    logic        rob_flush_valid;
    logic [3:0]  rob_flush_rob_index;
    logic [31:0] rob_flush_pc;

    logic        if_cpu_req_valid;
    logic [31:0] if_cpu_req_addr;
    logic [1:0]  if_cpu_req_epoch;
    logic        if_cpu_req_ready;
    logic        if_cpu_resp_valid;
    logic [31:0] if_cpu_resp_data;
    logic [1:0]  if_cpu_resp_epoch;

    logic        ic_mem_req_valid;
    logic        ic_mem_req_ready;
    logic [31:0] ic_mem_req_addr;
    logic        ic_mem_resp_valid;
    logic [31:0] ic_mem_resp_data;
    logic        ic_idle;

    logic        pred_req_valid;
    logic [31:0] pred_req_pc;
    logic [31:0] pred_next_pc;
    logic        pred_taken;
    logic [1:0]  pred_type;
    logic        pred_hit;

    logic        fetch_valid;
    logic [31:0] fetch_pc;
    logic [31:0] fetch_insn;
    logic [31:0] fetch_pred_next_pc;
    logic        fetch_pred_taken;
    logic [1:0]  fetch_pred_type;
    logic        fetch_pred_hit;

    logic        id_valid;
    logic [31:0] id_pc;
    logic [31:0] id_insn;
    logic [4:0]  id_rs1;
    logic [4:0]  id_rs2;
    logic [4:0]  id_rd;
    logic [31:0] id_imm;
    logic [4:0]  id_alu_op;
    logic [2:0]  id_wb_sel;
    logic        id_is_load;
    logic        id_is_store;
    logic [1:0]  id_mem_size;
    logic        id_is_branch;
    logic        id_is_jal;
    logic        id_is_jalr;
    logic        id_is_ecall;
    logic        id_reg_write;
    logic        id_use_imm;
    logic        id_is_auipc;
    logic [31:0] id_pred_next_pc;
    logic        id_pred_taken;
    logic [1:0]  id_pred_type;
    logic        id_pred_hit;
    logic        id_ready;

    logic        rob_alloc_valid;
    logic        rob_alloc_ready;
    logic [3:0]  rob_alloc_index;
    logic [31:0] rob_alloc_pc;
    logic [31:0] rob_alloc_insn;
    logic [5:0]  rob_alloc_pdst;
    logic [5:0]  rob_alloc_old_prd;
    logic [4:0]  rob_alloc_arch_rd;
    logic        rob_alloc_is_control;
    logic        rob_alloc_is_store;
    logic        rob_alloc_is_ecall;
    logic        rob_alloc_reg_write;
    logic [3:0]  rob_head_index;

    logic        iq_disp_valid;
    logic        iq_disp_ready;
    logic [31:0] iq_disp_pc;
    logic [31:0] iq_disp_insn;
    logic [3:0]  iq_disp_rob_index;
    logic [5:0]  iq_disp_prs1;
    logic [5:0]  iq_disp_prs2;
    logic [5:0]  iq_disp_pdst;
    logic        iq_disp_rs1_ready;
    logic        iq_disp_rs2_ready;
    logic [31:0] iq_disp_imm;
    logic [4:0]  iq_disp_alu_op;
    logic [2:0]  iq_disp_wb_sel;
    logic        iq_disp_is_branch;
    logic        iq_disp_is_jal;
    logic        iq_disp_is_jalr;
    logic        iq_disp_use_imm;
    logic        iq_disp_is_auipc;
    logic [31:0] iq_disp_pred_next_pc;
    logic        iq_disp_pred_taken;
    logic [1:0]  iq_disp_pred_type;

    logic        lsu_disp_valid;
    logic        lsu_disp_ready;
    logic [31:0] lsu_disp_pc;
    logic [31:0] lsu_disp_insn;
    logic [3:0]  lsu_disp_rob_index;
    logic [5:0]  lsu_disp_prs1;
    logic [5:0]  lsu_disp_prs2;
    logic [5:0]  lsu_disp_pdst;
    logic        lsu_disp_rs1_ready;
    logic        lsu_disp_rs2_ready;
    logic [31:0] lsu_disp_imm;
    logic        lsu_disp_is_load;
    logic        lsu_disp_is_store;
    logic [1:0]  lsu_disp_mem_size;

    logic [5:0]  iq_prf_rs1_addr;
    logic [5:0]  iq_prf_rs2_addr;
    logic [31:0] iq_prf_rdata1;
    logic [31:0] iq_prf_rdata2;
    logic [5:0]  lsu_prf_rs1_addr;
    logic [5:0]  lsu_prf_rs2_addr;
    logic [31:0] lsu_prf_rdata1;
    logic [31:0] lsu_prf_rdata2;
    logic        alu_complete_valid;
    logic [5:0]  alu_complete_prd;
    logic [31:0] alu_complete_data;
    logic        load_complete_valid;
    logic [5:0]  load_complete_prd;
    logic [31:0] load_complete_data;

    logic        issue_valid;
    logic        issue_ready;
    logic [31:0] issue_pc;
    logic [31:0] issue_insn;
    logic [3:0]  issue_rob_index;
    logic [5:0]  issue_prs1;
    logic [5:0]  issue_prs2;
    logic [5:0]  issue_pdst;
    logic [31:0] issue_operand1;
    logic [31:0] issue_operand2;
    logic [31:0] issue_imm;
    logic [4:0]  issue_alu_op;
    logic [2:0]  issue_wb_sel;
    logic        issue_is_branch;
    logic        issue_is_jal;
    logic        issue_is_jalr;
    logic        issue_use_imm;
    logic        issue_is_auipc;
    logic [31:0] issue_pred_next_pc;
    logic        issue_pred_taken;
    logic [1:0]  issue_pred_type;

    logic [3:0]  alu_complete_rob_index;
    logic        resolve_valid;
    logic [3:0]  resolve_rob_index;
    logic [31:0] resolve_pc;
    logic [31:0] resolve_actual;
    logic [31:0] resolve_actual_next_pc;
    logic        resolve_mispredict;
    logic        resolve_taken;
    logic [1:0]  resolve_type;

    logic        lsu_cpu_req_valid;
    logic        lsu_cpu_req_we;
    logic [31:0] lsu_cpu_req_addr;
    logic [31:0] lsu_cpu_req_wdata;
    logic [3:0]  lsu_cpu_req_be;
    logic [3:0]  lsu_cpu_req_rob_index;
    logic [1:0]  lsu_cpu_req_epoch;
    logic        lsu_cpu_req_ready;
    logic        lsu_cpu_resp_valid;
    logic [31:0] lsu_cpu_resp_rdata;
    logic [1:0]  lsu_cpu_resp_epoch;
    logic        lsu_dcache_wait;
    logic        lsu_idle;

    logic        dc_mem_req_valid;
    logic        dc_mem_req_ready;
    logic        dc_mem_req_we;
    logic [31:0] dc_mem_req_addr;
    logic [31:0] dc_mem_req_wdata;
    logic [3:0]  dc_mem_req_be;
    logic        dc_mem_resp_valid;
    logic [31:0] dc_mem_resp_data;
    logic        dcache_mem_wait;
    logic        dc_idle;

    logic        store_commit_valid;
    logic [3:0]  store_commit_rob_index;
    logic        store_done_valid;
    logic [3:0]  store_done_rob_index;
    logic [3:0]  load_complete_rob_index;

    logic        commit_valid;
    logic [31:0] commit_pc;
    logic [31:0] commit_insn;
    logic [31:0] commit_value;
    logic [4:0]  commit_arch_rd;
    logic        commit_reg_write;
    logic        commit_is_ecall;
    logic        commit_old_prd_valid;
    logic [5:0]  commit_old_prd;

    logic        evt_en;
    logic        bp_resolve_raw;
    logic        bp_mispredict_raw;
    logic        ooo_issue_raw;
    logic        ooo_bypass_raw;
    logic        iq_dbg_ooo_issue;
    logic        iq_dbg_ooo_bypass;
    logic        lsu_mem_pending;
    logic        lsu_issue_accept;

    // ------------------------------------------------------------------
    // Real OoO-overlap tracking for dbg_ooo_issue / dbg_ooo_bypass.
    //  - lsu_load_active marks an older load that has been accepted by the
    //    LSU and is still outstanding (set on load dispatch, cleared when
    //    it completes or when a flush squashes it).
    //  - With ROB_DEPTH == 2 the instruction directly behind that load
    //    always occupies the next ROB slot, so a younger ALU op is exactly
    //    the next slot index modulo the 2-entry index space.
    //  - ooo_bypass_pulse is the real younger-ALU completion event while
    //    the older load is outstanding.  ooo_bypass_hold keeps that same
    //    single event visible for the remaining external-memory wait of
    //    that load (cleared on completion / squash), so the overlap is
    //    observable on dbg_ooo_bypass during the wait.  No counters and no
    //    PC-pattern detection are used.
    // ------------------------------------------------------------------
    logic        lsu_load_active;
    logic [3:0]  lsu_load_rob;
    logic        ooo_bypass_hold;
    logic        ooo_bypass_pulse;
    logic        flush_kills_load;
    logic        lsu_load_waiting;
    logic        alu_behind_load;
    logic        issue_behind_load;
    logic        ooo_overlap_done_evt;
    logic        ooo_overlap_issue_evt;
    logic        load_disp_fire;

    assign bus_idle = (!dc_mem_req_valid) &&
                      ((!ic_mem_req_valid) || ecall_pending);
    assign evt_en   = rst_n && !halted;

    assign ic_mem_req_ready  = imem_ready;
    assign ic_mem_resp_valid = ic_mem_req_valid && imem_ready;
    assign ic_mem_resp_data  = imem_rdata;

    assign dc_mem_req_ready  = dmem_ready;
    assign dc_mem_resp_valid = dc_mem_req_valid && dmem_ready;
    assign dc_mem_resp_data  = dmem_rdata;

    assign flush           = rob_flush_valid;
    assign flush_rob_index = rob_flush_rob_index;
    assign redirect_pc     = rob_flush_pc;

    assign ecall_pending = rob_ecall_pending || ecall_seen;
    assign if_ecall_stop = ecall_pending || ecall_accept;

    assign ecall_accept = id_valid && id_ready && id_is_ecall &&
                          rob_alloc_valid && rob_alloc_ready && rob_alloc_is_ecall;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            flush_epoch <= 2'b00;
        end else if (flush) begin
            flush_epoch <= flush_epoch + 2'b01;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ecall_seen <= 1'b0;
        end else if (flush) begin
            ecall_seen <= 1'b0;
        end else if (ecall_accept) begin
            ecall_seen <= 1'b1;
        end
    end

    assign resolve_actual_next_pc = resolve_actual;
    assign resolve_mispredict     = resolve_valid && (resolve_actual != issue_pred_next_pc);
    assign resolve_taken          = resolve_valid && (resolve_actual != (resolve_pc + 32'd4));
    assign resolve_type           = issue_is_branch ? PT_COND :
                                    issue_is_jal    ? PT_JAL  :
                                    issue_is_jalr   ? PT_JALR : PT_NONE;

    assign lsu_mem_pending   = lsu_cpu_req_valid || lsu_dcache_wait ||
                               lsu_cpu_resp_valid;
    assign lsu_load_waiting  = lsu_cpu_req_valid || lsu_dcache_wait;
    assign lsu_issue_accept  = lsu_cpu_req_valid && lsu_cpu_req_ready;
    assign bp_resolve_raw    = resolve_valid;
    assign bp_mispredict_raw = resolve_mispredict;
    assign ooo_issue_raw     = iq_dbg_ooo_issue || lsu_issue_accept;
    assign load_disp_fire    = lsu_disp_valid && lsu_disp_ready && lsu_disp_is_load;

    // Younger-than-outstanding-load checks on real ROB allocation order.
    assign alu_behind_load   = (alu_complete_rob_index ==
                                ((lsu_load_rob + 4'd1) & 4'h1));
    assign issue_behind_load = (issue_rob_index ==
                                ((lsu_load_rob + 4'd1) & 4'h1));

    // A younger ALU op completes while the older load is still outstanding.
    assign ooo_overlap_done_evt = alu_complete_valid && lsu_load_active &&
                                  !load_complete_valid && alu_behind_load;

    // A younger ALU op is accepted by execute_alu while the older load is
    // still presenting or waiting on its external memory request.
    assign ooo_overlap_issue_evt = iq_dbg_ooo_issue && lsu_load_active &&
                                   lsu_load_waiting && !load_complete_valid &&
                                   issue_behind_load;

    assign ooo_bypass_pulse = ooo_overlap_done_evt;
    assign ooo_bypass_raw   = ooo_overlap_done_evt || ooo_overlap_issue_evt ||
                              ooo_bypass_hold;

    assign flush_kills_load  = flush && lsu_load_active &&
                               !((lsu_load_rob - flush_rob_index) & 4'h8);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lsu_load_active <= 1'b0;
            lsu_load_rob    <= 4'd0;
            ooo_bypass_hold <= 1'b0;
        end else if (flush_kills_load) begin
            lsu_load_active <= 1'b0;
            ooo_bypass_hold <= 1'b0;
        end else begin
            if (load_complete_valid) begin
                lsu_load_active <= 1'b0;
                ooo_bypass_hold <= 1'b0;
            end
            if (load_disp_fire) begin
                lsu_load_active <= 1'b1;
                lsu_load_rob    <= lsu_disp_rob_index;
                ooo_bypass_hold <= 1'b0;
            end
            if (ooo_overlap_done_evt || ooo_overlap_issue_evt) begin
                ooo_bypass_hold <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dbg_bp_resolve    <= 1'b0;
            dbg_bp_mispredict <= 1'b0;
        end else begin
            dbg_bp_resolve    <= evt_en && bp_resolve_raw;
            dbg_bp_mispredict <= evt_en && bp_mispredict_raw;
        end
    end

    assign dbg_ooo_issue  = evt_en && ooo_issue_raw;
    assign dbg_ooo_bypass = evt_en && ooo_bypass_raw;

    assign dbg_features = 3'b111;

    assign imem_valid = rst_n && ic_mem_req_valid;
    assign imem_addr  = ic_mem_req_addr;

    assign dmem_valid = rst_n && dc_mem_req_valid;
    assign dmem_we    = dc_mem_req_we;
    assign dmem_addr  = dc_mem_req_addr;
    assign dmem_wdata = dc_mem_req_wdata;
    assign dmem_be    = dc_mem_req_be;

    icache u_icache (
        .clk            (clk),
        .rst_n          (rst_n),
        .flush          (flush),
        .flush_epoch    (flush_epoch),
        .halted         (halted),
        .cpu_req_valid  (if_cpu_req_valid),
        .cpu_req_addr   (if_cpu_req_addr),
        .cpu_req_epoch  (if_cpu_req_epoch),
        .cpu_req_ready  (if_cpu_req_ready),
        .cpu_resp_valid (if_cpu_resp_valid),
        .cpu_resp_data  (if_cpu_resp_data),
        .cpu_resp_epoch (if_cpu_resp_epoch),
        .mem_req_valid  (ic_mem_req_valid),
        .mem_req_ready  (ic_mem_req_ready),
        .mem_req_addr   (ic_mem_req_addr),
        .mem_resp_valid (ic_mem_resp_valid),
        .mem_resp_data  (ic_mem_resp_data),
        .idle           (ic_idle)
    );

    dcache u_dcache (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (flush),
        .flush_epoch      (flush_epoch),
        .flush_rob_index  (flush_rob_index),
        .halted           (halted),
        .cpu_req_valid    (lsu_cpu_req_valid),
        .cpu_req_we       (lsu_cpu_req_we),
        .cpu_req_addr     (lsu_cpu_req_addr),
        .cpu_req_wdata    (lsu_cpu_req_wdata),
        .cpu_req_be       (lsu_cpu_req_be),
        .cpu_req_rob_index(lsu_cpu_req_rob_index),
        .cpu_req_epoch    (lsu_cpu_req_epoch),
        .cpu_req_ready    (lsu_cpu_req_ready),
        .cpu_resp_valid   (lsu_cpu_resp_valid),
        .cpu_resp_rdata   (lsu_cpu_resp_rdata),
        .cpu_resp_epoch   (lsu_cpu_resp_epoch),
        .mem_req_valid    (dc_mem_req_valid),
        .mem_req_ready    (dc_mem_req_ready),
        .mem_req_we       (dc_mem_req_we),
        .mem_req_addr     (dc_mem_req_addr),
        .mem_req_wdata    (dc_mem_req_wdata),
        .mem_req_be       (dc_mem_req_be),
        .mem_resp_valid   (dc_mem_resp_valid),
        .mem_resp_data    (dc_mem_resp_data),
        .dcache_mem_wait  (dcache_mem_wait),
        .idle             (dc_idle)
    );

    branch_predictor u_bp (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .pred_req_valid        (pred_req_valid),
        .pred_req_pc           (pred_req_pc),
        .pred_next_pc          (pred_next_pc),
        .pred_taken            (pred_taken),
        .pred_type             (pred_type),
        .pred_hit              (pred_hit),
        .resolve_valid         (resolve_valid),
        .resolve_pc            (resolve_pc),
        .resolve_actual_next_pc(resolve_actual_next_pc),
        .resolve_taken         (resolve_taken),
        .resolve_type          (resolve_type)
    );

    if_stage u_if (
        .clk               (clk),
        .rst_n             (rst_n),
        .flush             (flush),
        .redirect_pc       (redirect_pc),
        .flush_epoch       (flush_epoch),
        .halted            (halted),
        .ecall_pending     (if_ecall_stop),
        .id_ready          (id_ready),
        .fetch_valid       (fetch_valid),
        .fetch_pc          (fetch_pc),
        .fetch_insn        (fetch_insn),
        .fetch_pred_next_pc(fetch_pred_next_pc),
        .fetch_pred_taken  (fetch_pred_taken),
        .fetch_pred_type   (fetch_pred_type),
        .fetch_pred_hit    (fetch_pred_hit),
        .cpu_req_valid     (if_cpu_req_valid),
        .cpu_req_addr      (if_cpu_req_addr),
        .cpu_req_epoch     (if_cpu_req_epoch),
        .cpu_req_ready     (if_cpu_req_ready),
        .cpu_resp_valid    (if_cpu_resp_valid),
        .cpu_resp_data     (if_cpu_resp_data),
        .cpu_resp_epoch    (if_cpu_resp_epoch),
        .pred_req_valid    (pred_req_valid),
        .pred_req_pc       (pred_req_pc),
        .pred_next_pc      (pred_next_pc),
        .pred_taken        (pred_taken),
        .pred_type         (pred_type),
        .pred_hit          (pred_hit)
    );

    id_stage u_id (
        .clk               (clk),
        .rst_n             (rst_n),
        .flush             (flush),
        .halted            (halted),
        .ecall_pending     (ecall_pending),
        .fetch_valid       (fetch_valid),
        .fetch_pc          (fetch_pc),
        .fetch_insn        (fetch_insn),
        .fetch_pred_next_pc(fetch_pred_next_pc),
        .fetch_pred_taken  (fetch_pred_taken),
        .fetch_pred_type   (fetch_pred_type),
        .fetch_pred_hit    (fetch_pred_hit),
        .id_valid          (id_valid),
        .id_pc             (id_pc),
        .id_insn           (id_insn),
        .id_rs1            (id_rs1),
        .id_rs2            (id_rs2),
        .id_rd             (id_rd),
        .id_imm            (id_imm),
        .id_alu_op         (id_alu_op),
        .id_wb_sel         (id_wb_sel),
        .id_is_load        (id_is_load),
        .id_is_store       (id_is_store),
        .id_mem_size       (id_mem_size),
        .id_is_branch      (id_is_branch),
        .id_is_jal         (id_is_jal),
        .id_is_jalr        (id_is_jalr),
        .id_is_ecall       (id_is_ecall),
        .id_reg_write      (id_reg_write),
        .id_use_imm        (id_use_imm),
        .id_is_auipc       (id_is_auipc),
        .id_pred_next_pc   (id_pred_next_pc),
        .id_pred_taken     (id_pred_taken),
        .id_pred_type      (id_pred_type),
        .id_pred_hit       (id_pred_hit)
    );

    rename_unit u_rename (
        .clk               (clk),
        .rst_n             (rst_n),
        .flush             (flush),
        .flush_rob_index   (flush_rob_index),
        .halted            (halted),
        .ecall_pending     (ecall_pending),
        .id_valid          (id_valid),
        .id_ready          (id_ready),
        .id_pc             (id_pc),
        .id_insn           (id_insn),
        .id_rs1            (id_rs1),
        .id_rs2            (id_rs2),
        .id_rd             (id_rd),
        .id_imm            (id_imm),
        .id_alu_op         (id_alu_op),
        .id_wb_sel         (id_wb_sel),
        .id_is_load        (id_is_load),
        .id_is_store       (id_is_store),
        .id_mem_size       (id_mem_size),
        .id_is_branch      (id_is_branch),
        .id_is_jal         (id_is_jal),
        .id_is_jalr        (id_is_jalr),
        .id_is_ecall       (id_is_ecall),
        .id_reg_write      (id_reg_write),
        .id_use_imm        (id_use_imm),
        .id_is_auipc       (id_is_auipc),
        .id_pred_next_pc   (id_pred_next_pc),
        .id_pred_taken     (id_pred_taken),
        .id_pred_type      (id_pred_type),
        .id_pred_hit       (id_pred_hit),
        .rob_alloc_valid   (rob_alloc_valid),
        .rob_alloc_ready   (rob_alloc_ready),
        .rob_alloc_index   (rob_alloc_index),
        .rob_alloc_pc      (rob_alloc_pc),
        .rob_alloc_insn    (rob_alloc_insn),
        .rob_alloc_pdst    (rob_alloc_pdst),
        .rob_alloc_old_prd (rob_alloc_old_prd),
        .rob_alloc_arch_rd (rob_alloc_arch_rd),
        .rob_alloc_is_control(rob_alloc_is_control),
        .rob_alloc_is_store(rob_alloc_is_store),
        .rob_alloc_is_ecall(rob_alloc_is_ecall),
        .rob_alloc_reg_write(rob_alloc_reg_write),
        .iq_disp_valid     (iq_disp_valid),
        .iq_disp_ready     (iq_disp_ready),
        .iq_disp_pc        (iq_disp_pc),
        .iq_disp_insn      (iq_disp_insn),
        .iq_disp_rob_index (iq_disp_rob_index),
        .iq_disp_prs1      (iq_disp_prs1),
        .iq_disp_prs2      (iq_disp_prs2),
        .iq_disp_pdst      (iq_disp_pdst),
        .iq_disp_rs1_ready (iq_disp_rs1_ready),
        .iq_disp_rs2_ready (iq_disp_rs2_ready),
        .iq_disp_imm       (iq_disp_imm),
        .iq_disp_alu_op    (iq_disp_alu_op),
        .iq_disp_wb_sel    (iq_disp_wb_sel),
        .iq_disp_is_branch (iq_disp_is_branch),
        .iq_disp_is_jal    (iq_disp_is_jal),
        .iq_disp_is_jalr   (iq_disp_is_jalr),
        .iq_disp_use_imm   (iq_disp_use_imm),
        .iq_disp_is_auipc  (iq_disp_is_auipc),
        .iq_disp_pred_next_pc(iq_disp_pred_next_pc),
        .iq_disp_pred_taken(iq_disp_pred_taken),
        .iq_disp_pred_type (iq_disp_pred_type),
        .lsu_disp_valid    (lsu_disp_valid),
        .lsu_disp_ready    (lsu_disp_ready),
        .lsu_disp_pc       (lsu_disp_pc),
        .lsu_disp_insn     (lsu_disp_insn),
        .lsu_disp_rob_index(lsu_disp_rob_index),
        .lsu_disp_prs1     (lsu_disp_prs1),
        .lsu_disp_prs2     (lsu_disp_prs2),
        .lsu_disp_pdst     (lsu_disp_pdst),
        .lsu_disp_rs1_ready(lsu_disp_rs1_ready),
        .lsu_disp_rs2_ready(lsu_disp_rs2_ready),
        .lsu_disp_imm      (lsu_disp_imm),
        .lsu_disp_is_load  (lsu_disp_is_load),
        .lsu_disp_is_store (lsu_disp_is_store),
        .lsu_disp_mem_size (lsu_disp_mem_size),
        .alu_complete_valid(alu_complete_valid),
        .alu_complete_prd  (alu_complete_prd),
        .load_complete_valid(load_complete_valid),
        .load_complete_prd (load_complete_prd)
    );

    physical_register_file u_prf (
        .clk                (clk),
        .rst_n              (rst_n),
        .iq_prf_rs1_addr    (iq_prf_rs1_addr),
        .iq_prf_rs2_addr    (iq_prf_rs2_addr),
        .iq_prf_rdata1      (iq_prf_rdata1),
        .iq_prf_rdata2      (iq_prf_rdata2),
        .lsu_prf_rs1_addr   (lsu_prf_rs1_addr),
        .lsu_prf_rs2_addr   (lsu_prf_rs2_addr),
        .lsu_prf_rdata1     (lsu_prf_rdata1),
        .lsu_prf_rdata2     (lsu_prf_rdata2),
        .alu_complete_valid (alu_complete_valid),
        .alu_complete_prd   (alu_complete_prd),
        .alu_complete_data  (alu_complete_data),
        .load_complete_valid(load_complete_valid),
        .load_complete_prd  (load_complete_prd),
        .load_complete_data (load_complete_data)
    );

    issue_queue u_iq (
        .clk                (clk),
        .rst_n              (rst_n),
        .flush              (flush),
        .flush_rob_index    (flush_rob_index),
        .rob_head_index     (rob_head_index),
        .halted             (halted),
        .iq_disp_valid      (iq_disp_valid),
        .iq_disp_ready      (iq_disp_ready),
        .iq_disp_pc         (iq_disp_pc),
        .iq_disp_insn       (iq_disp_insn),
        .iq_disp_rob_index  (iq_disp_rob_index),
        .iq_disp_prs1       (iq_disp_prs1),
        .iq_disp_prs2       (iq_disp_prs2),
        .iq_disp_pdst       (iq_disp_pdst),
        .iq_disp_rs1_ready  (iq_disp_rs1_ready),
        .iq_disp_rs2_ready  (iq_disp_rs2_ready),
        .iq_disp_imm        (iq_disp_imm),
        .iq_disp_alu_op     (iq_disp_alu_op),
        .iq_disp_wb_sel     (iq_disp_wb_sel),
        .iq_disp_is_branch  (iq_disp_is_branch),
        .iq_disp_is_jal     (iq_disp_is_jal),
        .iq_disp_is_jalr    (iq_disp_is_jalr),
        .iq_disp_use_imm    (iq_disp_use_imm),
        .iq_disp_is_auipc   (iq_disp_is_auipc),
        .iq_disp_pred_next_pc(iq_disp_pred_next_pc),
        .iq_disp_pred_taken (iq_disp_pred_taken),
        .iq_disp_pred_type  (iq_disp_pred_type),
        .alu_complete_valid (alu_complete_valid),
        .alu_complete_prd   (alu_complete_prd),
        .load_complete_valid(load_complete_valid),
        .load_complete_prd  (load_complete_prd),
        .iq_prf_rs1_addr    (iq_prf_rs1_addr),
        .iq_prf_rs2_addr    (iq_prf_rs2_addr),
        .iq_prf_rdata1      (iq_prf_rdata1),
        .iq_prf_rdata2      (iq_prf_rdata2),
        .issue_valid        (issue_valid),
        .issue_ready        (issue_ready),
        .issue_pc           (issue_pc),
        .issue_insn         (issue_insn),
        .issue_rob_index    (issue_rob_index),
        .issue_prs1         (issue_prs1),
        .issue_prs2         (issue_prs2),
        .issue_pdst         (issue_pdst),
        .issue_operand1     (issue_operand1),
        .issue_operand2     (issue_operand2),
        .issue_imm          (issue_imm),
        .issue_alu_op       (issue_alu_op),
        .issue_wb_sel       (issue_wb_sel),
        .issue_is_branch    (issue_is_branch),
        .issue_is_jal       (issue_is_jal),
        .issue_is_jalr      (issue_is_jalr),
        .issue_use_imm      (issue_use_imm),
        .issue_is_auipc     (issue_is_auipc),
        .issue_pred_next_pc (issue_pred_next_pc),
        .issue_pred_taken   (issue_pred_taken),
        .issue_pred_type    (issue_pred_type),
        .dbg_ooo_issue      (iq_dbg_ooo_issue),
        .dbg_ooo_bypass     (iq_dbg_ooo_bypass)
    );

    execute_alu u_alu (
        .clk                  (clk),
        .rst_n                (rst_n),
        .flush                (flush),
        .halted               (halted),
        .issue_valid          (issue_valid),
        .issue_ready          (issue_ready),
        .issue_pc             (issue_pc),
        .issue_insn           (issue_insn),
        .issue_rob_index      (issue_rob_index),
        .issue_prs1           (issue_prs1),
        .issue_prs2           (issue_prs2),
        .issue_pdst           (issue_pdst),
        .issue_operand1       (issue_operand1),
        .issue_operand2       (issue_operand2),
        .issue_imm            (issue_imm),
        .issue_alu_op         (issue_alu_op),
        .issue_wb_sel         (issue_wb_sel),
        .issue_is_branch      (issue_is_branch),
        .issue_is_jal         (issue_is_jal),
        .issue_is_jalr        (issue_is_jalr),
        .issue_use_imm        (issue_use_imm),
        .issue_is_auipc       (issue_is_auipc),
        .issue_pred_next_pc   (issue_pred_next_pc),
        .issue_pred_taken     (issue_pred_taken),
        .issue_pred_type      (issue_pred_type),
        .alu_complete_valid   (alu_complete_valid),
        .alu_complete_rob_index(alu_complete_rob_index),
        .alu_complete_prd     (alu_complete_prd),
        .alu_complete_data    (alu_complete_data),
        .resolve_valid        (resolve_valid),
        .resolve_rob_index    (resolve_rob_index),
        .resolve_pc           (resolve_pc),
        .resolve_actual       (resolve_actual)
    );

    load_store_unit u_lsu (
        .clk                (clk),
        .rst_n              (rst_n),
        .flush              (flush),
        .flush_rob_index    (flush_rob_index),
        .flush_epoch        (flush_epoch),
        .halted             (halted),
        .lsu_disp_valid     (lsu_disp_valid),
        .lsu_disp_ready     (lsu_disp_ready),
        .lsu_disp_pc        (lsu_disp_pc),
        .lsu_disp_insn      (lsu_disp_insn),
        .lsu_disp_rob_index (lsu_disp_rob_index),
        .lsu_disp_prs1      (lsu_disp_prs1),
        .lsu_disp_prs2      (lsu_disp_prs2),
        .lsu_disp_pdst      (lsu_disp_pdst),
        .lsu_disp_rs1_ready (lsu_disp_rs1_ready),
        .lsu_disp_rs2_ready (lsu_disp_rs2_ready),
        .lsu_disp_imm       (lsu_disp_imm),
        .lsu_disp_is_load   (lsu_disp_is_load),
        .lsu_disp_is_store  (lsu_disp_is_store),
        .lsu_disp_mem_size  (lsu_disp_mem_size),
        .alu_complete_valid (alu_complete_valid),
        .alu_complete_prd   (alu_complete_prd),
        .lsu_prf_rs1_addr   (lsu_prf_rs1_addr),
        .lsu_prf_rs2_addr   (lsu_prf_rs2_addr),
        .lsu_prf_rdata1     (lsu_prf_rdata1),
        .lsu_prf_rdata2     (lsu_prf_rdata2),
        .store_commit_valid (store_commit_valid),
        .store_commit_rob_index(store_commit_rob_index),
        .store_done_valid   (store_done_valid),
        .store_done_rob_index(store_done_rob_index),
        .load_complete_valid(load_complete_valid),
        .load_complete_rob_index(load_complete_rob_index),
        .load_complete_prd  (load_complete_prd),
        .load_complete_data (load_complete_data),
        .lsu_dcache_req_valid     (lsu_cpu_req_valid),
        .lsu_dcache_req_we        (lsu_cpu_req_we),
        .lsu_dcache_req_addr      (lsu_cpu_req_addr),
        .lsu_dcache_req_wdata     (lsu_cpu_req_wdata),
        .lsu_dcache_req_be        (lsu_cpu_req_be),
        .lsu_dcache_req_rob_index (lsu_cpu_req_rob_index),
        .lsu_dcache_req_epoch     (lsu_cpu_req_epoch),
        .lsu_dcache_req_ready     (lsu_cpu_req_ready),
        .lsu_dcache_resp_valid    (lsu_cpu_resp_valid),
        .lsu_dcache_resp_rdata    (lsu_cpu_resp_rdata),
        .lsu_dcache_resp_epoch    (lsu_cpu_resp_epoch),
        .lsu_dcache_wait          (lsu_dcache_wait),
        .lsu_idle                 (lsu_idle)
    );

    reorder_buffer u_rob (
        .clk                   (clk),
        .rst_n                 (rst_n),
        .halted                (halted),
        .rob_alloc_valid       (rob_alloc_valid),
        .rob_alloc_ready       (rob_alloc_ready),
        .rob_alloc_index       (rob_alloc_index),
        .rob_alloc_pc          (rob_alloc_pc),
        .rob_alloc_insn        (rob_alloc_insn),
        .rob_alloc_pdst        (rob_alloc_pdst),
        .rob_alloc_old_prd     (rob_alloc_old_prd),
        .rob_alloc_arch_rd     (rob_alloc_arch_rd),
        .rob_alloc_is_control  (rob_alloc_is_control),
        .rob_alloc_is_store    (rob_alloc_is_store),
        .rob_alloc_is_ecall    (rob_alloc_is_ecall),
        .rob_alloc_reg_write   (rob_alloc_reg_write),
        .rob_head_index        (rob_head_index),
        .alu_complete_valid    (alu_complete_valid),
        .alu_complete_rob_index(alu_complete_rob_index),
        .alu_complete_data     (alu_complete_data),
        .load_complete_valid   (load_complete_valid),
        .load_complete_rob_index(load_complete_rob_index),
        .load_complete_data    (load_complete_data),
        .resolve_valid         (resolve_valid),
        .resolve_rob_index     (resolve_rob_index),
        .resolve_mispredict    (resolve_mispredict),
        .resolve_actual_next_pc(resolve_actual_next_pc),
        .store_commit_valid    (store_commit_valid),
        .store_commit_rob_index(store_commit_rob_index),
        .store_done_valid      (store_done_valid),
        .store_done_rob_index  (store_done_rob_index),
        .commit_valid          (commit_valid),
        .commit_pc             (commit_pc),
        .commit_insn           (commit_insn),
        .commit_value          (commit_value),
        .commit_arch_rd        (commit_arch_rd),
        .commit_reg_write      (commit_reg_write),
        .commit_is_ecall       (commit_is_ecall),
        .commit_old_prd_valid  (commit_old_prd_valid),
        .commit_old_prd        (commit_old_prd),
        .flush_valid           (rob_flush_valid),
        .flush_rob_index       (rob_flush_rob_index),
        .flush_pc              (rob_flush_pc),
        .ecall_pending         (rob_ecall_pending)
    );

    commit_unit u_commit (
        .clk              (clk),
        .rst_n            (rst_n),
        .commit_valid     (commit_valid),
        .commit_pc        (commit_pc),
        .commit_insn      (commit_insn),
        .commit_value     (commit_value),
        .commit_arch_rd   (commit_arch_rd),
        .commit_reg_write (commit_reg_write),
        .commit_is_ecall  (commit_is_ecall),
        .bus_idle         (bus_idle),
        .dbg_reg_addr     (dbg_reg_addr),
        .halted           (halted),
        .exit_code        (exit_code),
        .dbg_retire_valid (dbg_retire_valid),
        .dbg_retire_pc    (dbg_retire_pc),
        .dbg_retire_insn  (dbg_retire_insn),
        .dbg_reg_data     (dbg_reg_data)
    );

endmodule
