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

    integer i;

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

                if (commit_is_ecall) begin
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

    localparam logic [2:0] ST_IDLE  = 3'd0;
    localparam logic [2:0] ST_REFILL= 3'd1;
    localparam logic [2:0] ST_WT    = 3'd2;
    localparam logic [2:0] ST_RESP  = 3'd3;

    logic [2:0]  state;
    logic [127:0] line_data [0:15];
    logic [23:0]  line_tag  [0:15];
    logic [15:0]  line_valid;

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
    logic [23:0] refill_tag;
    logic [3:0]  refill_idx;

    logic [31:0] wt_addr;
    logic [31:0] wt_wdata;
    logic [3:0]  wt_be;

    logic [31:0] resp_rdata;
    logic [1:0]  resp_epoch;

    logic [31:0] lookup_addr;
    logic [3:0]  idx;
    logic [23:0] tag;
    logic [1:0]  wsel;
    logic        hit;
    logic [31:0] hit_word;
    logic [31:0] be_mask;
    logic [31:0] merged_word;

    assign lookup_addr = (state == ST_IDLE) ? cpu_req_addr : req_addr;
    assign idx  = lookup_addr[7:4];
    assign tag  = lookup_addr[31:8];
    assign wsel = lookup_addr[3:2];
    assign hit  = line_valid[idx] && (line_tag[idx] == tag);
    assign hit_word = line_data[idx][{wsel, 5'b00000} +: 32];

    assign be_mask = {{8{cpu_req_be[3]}}, {8{cpu_req_be[2]}}, {8{cpu_req_be[1]}}, {8{cpu_req_be[0]}}};
    assign merged_word = (hit_word & ~be_mask) | (cpu_req_wdata & be_mask);

    assign cpu_req_ready = (state == ST_IDLE) && !halted;

    assign mem_req_valid = (state == ST_REFILL) || (state == ST_WT);
    assign mem_req_we    = (state == ST_WT);
    assign mem_req_addr  = (state == ST_WT) ? wt_addr : (refill_base + {refill_word, 2'b00});
    assign mem_req_wdata = (state == ST_WT) ? wt_wdata : 32'b0;
    assign mem_req_be    = (state == ST_WT) ? wt_be : 4'b0000;

    assign dcache_mem_wait = mem_req_valid && !mem_req_ready;
    assign idle = (state == ST_IDLE) && !cpu_req_valid;

    assign cpu_resp_valid = (state == ST_RESP);
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

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            line_valid  <= 16'b0;
            req_addr    <= 32'b0;
            req_wdata   <= 32'b0;
            req_be      <= 4'b0;
            req_we      <= 1'b0;
            req_rob     <= 4'b0;
            req_epoch   <= 2'b0;
            refill_base <= 32'b0;
            refill_word <= 2'b0;
            refill_data <= 128'b0;
            refill_tag  <= 24'b0;
            refill_idx  <= 4'b0;
            wt_addr     <= 32'b0;
            wt_wdata    <= 32'b0;
            wt_be       <= 4'b0;
            resp_rdata  <= 32'b0;
            resp_epoch  <= 2'b0;
        end else if (halted) begin
            state <= ST_IDLE;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (cpu_req_valid) begin
                        req_addr  <= cpu_req_addr;
                        req_wdata <= cpu_req_wdata;
                        req_be    <= cpu_req_be;
                        req_we    <= cpu_req_we;
                        req_rob   <= cpu_req_rob_index;
                        req_epoch <= cpu_req_epoch;
                        if (cpu_req_we) begin
                            if (hit) begin
                                line_data[idx][{wsel, 5'b00000} +: 32] <= merged_word;
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
                            refill_tag  <= cpu_req_addr[31:8];
                            refill_idx  <= cpu_req_addr[7:4];
                            refill_word <= 2'b0;
                            refill_data <= 128'b0;
                            state       <= ST_REFILL;
                        end
                    end
                end
                ST_REFILL: begin
                    if (mem_req_ready) begin
                        if (refill_word == 2'b11) begin
                            line_data[refill_idx]  <= refill_data_next;
                            line_tag[refill_idx]   <= refill_tag;
                            line_valid[refill_idx] <= 1'b1;
                            resp_rdata <= refill_data_next[{wsel, 5'b00000} +: 32];
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

    assign op_a = issue_operand1;
    assign op_b = issue_use_imm ? issue_imm : issue_operand2;

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
            ALU_LUI:   alu_result = issue_imm;
            ALU_AUIPC: alu_result = issue_pc + issue_imm;
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
    end

    assign pc_plus4      = issue_pc + 32'd4;
    assign branch_target = issue_pc + issue_imm;
    assign jal_target    = issue_pc + issue_imm;
    assign jalr_target   = (op_a + issue_imm) & 32'hFFFF_FFFE;

    always_comb begin
        ctrl_target = issue_pc + 32'd4;
        if (issue_is_branch) begin
            ctrl_target = branch_target;
        end else if (issue_is_jal) begin
            ctrl_target = jal_target;
        end else if (issue_is_jalr) begin
            ctrl_target = jalr_target;
        end
    end

    assign is_control = issue_is_branch | issue_is_jal | issue_is_jalr;

    always_comb begin
        actual_taken = 1'b0;
        if (issue_is_branch) begin
            actual_taken = branch_taken;
        end else if (issue_is_jal || issue_is_jalr) begin
            actual_taken = 1'b1;
        end
    end

    assign actual_next_pc = actual_taken ? ctrl_target : pc_plus4;

    always_comb begin
        wb_data = alu_result;
        case (issue_wb_sel)
            WB_ALU:   wb_data = alu_result;
            WB_PC4:   wb_data = pc_plus4;
            WB_LOAD:  wb_data = alu_result;
            WB_IMM:   wb_data = issue_imm;
            WB_AUIPC: wb_data = issue_pc + issue_imm;
            default:  wb_data = alu_result;
        endcase
    end

    assign issue_ready = rst_n & ~halted & ~flush;

    assign alu_complete_valid    = issue_valid & issue_ready;
    assign alu_complete_rob_index= issue_rob_index;
    assign alu_complete_prd      = issue_pdst;
    assign alu_complete_data     = wb_data;

    assign resolve_valid     = issue_valid & issue_ready & is_control;
    assign resolve_rob_index = issue_rob_index;
    assign resolve_pc        = issue_pc;
    assign resolve_actual    = actual_next_pc;

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

    // Line storage uses unpacked arrays so variable word selection is a plain
    // case mux (no variable part-select on a packed 2-D array).
    logic [127:0] line_data [0:15];
    logic [23:0]  line_tag  [0:15];
    logic [15:0]  line_valid;

    logic         refill_active;
    logic [1:0]   refill_word;
    logic [31:0]  refill_base;
    logic [23:0]  refill_tag;
    logic [3:0]   refill_index;
    logic [1:0]   refill_epoch;
    logic [127:0] refill_data;
    logic [127:0] refill_data_next;

    logic         resp_valid_r;
    logic [31:0]  resp_data_r;
    logic [1:0]   resp_epoch_r;

    logic         req_pending;
    logic [31:0]  req_addr_r;
    logic [1:0]   req_epoch_r;
    logic [3:0]   req_index_r;
    logic [23:0]  req_tag_r;
    logic [1:0]   req_wsel_r;

    logic [3:0]   cpu_index;
    logic [23:0]  cpu_tag;
    logic [1:0]   cpu_wsel;

    logic         req_hit;
    logic [127:0] req_line;
    logic [31:0]  req_word;
    logic [31:0]  refill_word_data;

    assign cpu_index = cpu_req_addr[7:4];
    assign cpu_tag   = cpu_req_addr[31:8];
    assign cpu_wsel  = cpu_req_addr[3:2];

    assign req_line = line_data[req_index_r];
    assign req_hit  = line_valid[req_index_r] && (line_tag[req_index_r] == req_tag_r);

    always_comb begin
        case (req_wsel_r)
            2'd0:    req_word = req_line[31:0];
            2'd1:    req_word = req_line[63:32];
            2'd2:    req_word = req_line[95:64];
            default: req_word = req_line[127:96];
        endcase
    end

    // Word returned by the refill uses the CURRENT bus response (lane 3
    // included), never an old refill register.
    always_comb begin
        case (req_wsel_r)
            2'd0:    refill_word_data = refill_data_next[31:0];
            2'd1:    refill_word_data = refill_data_next[63:32];
            2'd2:    refill_word_data = refill_data_next[95:64];
            default: refill_word_data = refill_data_next[127:96];
        endcase
    end

    always_comb begin
        refill_data_next = refill_data;
        if (refill_active && mem_resp_valid) begin
            case (refill_word)
                2'd0:    refill_data_next[31:0]   = mem_resp_data;
                2'd1:    refill_data_next[63:32]  = mem_resp_data;
                2'd2:    refill_data_next[95:64]  = mem_resp_data;
                default: refill_data_next[127:96] = mem_resp_data;
            endcase
        end
    end

    assign cpu_req_ready = rst_n && !halted && !req_pending && !resp_valid_r &&
                           !refill_active;

    // An in-flight refill keeps its valid/address stable until ready: the word
    // counter only advances on the accepted response, so nothing is aborted.
    assign mem_req_valid = rst_n && refill_active;
    assign mem_req_addr  = refill_base + {refill_word, 2'b00};

    assign cpu_resp_valid = resp_valid_r;
    assign cpu_resp_data  = resp_data_r;
    assign cpu_resp_epoch = resp_epoch_r;

    assign idle = rst_n && !halted && !refill_active &&
                  !req_pending && !resp_valid_r && !mem_req_valid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            line_valid    <= 16'b0;
            refill_active <= 1'b0;
            refill_word   <= 2'd0;
            refill_base   <= 32'b0;
            refill_tag    <= 24'b0;
            refill_index  <= 4'b0;
            refill_epoch  <= 2'b0;
            refill_data   <= 128'b0;
            resp_valid_r  <= 1'b0;
            resp_data_r   <= 32'b0;
            resp_epoch_r  <= 2'b0;
            req_pending   <= 1'b0;
            req_addr_r    <= 32'b0;
            req_epoch_r   <= 2'b0;
            req_index_r   <= 4'b0;
            req_tag_r     <= 24'b0;
            req_wsel_r    <= 2'b0;
        end else begin
            resp_valid_r <= 1'b0;

            if (refill_active) begin
                if (mem_resp_valid) begin
                    if (refill_word == 2'd3) begin
                        // Always finish and install the line; a redirect may
                        // only suppress the response through the epoch tag.
                        line_valid[refill_index] <= 1'b1;
                        line_tag[refill_index]   <= refill_tag;
                        line_data[refill_index]  <= refill_data_next;
                        if (!halted) begin
                            resp_valid_r <= 1'b1;
                            resp_data_r  <= refill_word_data;
                            resp_epoch_r <= refill_epoch;
                        end
                        refill_active <= 1'b0;
                        refill_word   <= 2'd0;
                        refill_data   <= 128'b0;
                    end else begin
                        refill_data <= refill_data_next;
                        refill_word <= refill_word + 2'd1;
                    end
                end
            end else if (req_pending) begin
                if (!halted) begin
                    if (req_hit) begin
                        resp_valid_r <= 1'b1;
                        resp_data_r  <= req_word;
                        resp_epoch_r <= req_epoch_r;
                        req_pending  <= 1'b0;
                    end else begin
                        refill_active <= 1'b1;
                        refill_word   <= 2'd0;
                        refill_base   <= {req_addr_r[31:4], 4'b0000};
                        refill_tag    <= req_tag_r;
                        refill_index  <= req_index_r;
                        refill_epoch  <= req_epoch_r;
                        refill_data   <= 128'b0;
                        req_pending   <= 1'b0;
                    end
                end
            end else if (!halted) begin
                if (cpu_req_valid && cpu_req_ready) begin
                    req_pending <= 1'b1;
                    req_addr_r  <= cpu_req_addr;
                    req_epoch_r <= cpu_req_epoch;
                    req_index_r <= cpu_index;
                    req_tag_r   <= cpu_tag;
                    req_wsel_r  <= cpu_wsel;
                end
            end
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
                use_imm_c   = 1'b1;
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
                    // The response belongs to an older epoch.  Drop it and let
                    // the normal issue path restart from pc if the front end
                    // is still running.
                    if2id_valid <= 1'b0;
                    req_pending <= 1'b0;
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

    localparam int IQ_DEPTH = 8;

    logic        ent_valid   [0:IQ_DEPTH-1];
    logic [31:0] ent_pc      [0:IQ_DEPTH-1];
    logic [31:0] ent_insn    [0:IQ_DEPTH-1];
    logic [3:0]  ent_rob     [0:IQ_DEPTH-1];
    logic [5:0]  ent_prs1    [0:IQ_DEPTH-1];
    logic [5:0]  ent_prs2    [0:IQ_DEPTH-1];
    logic [5:0]  ent_pdst    [0:IQ_DEPTH-1];
    logic        ent_r1rdy   [0:IQ_DEPTH-1];
    logic        ent_r2rdy   [0:IQ_DEPTH-1];
    logic [31:0] ent_imm     [0:IQ_DEPTH-1];
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
    logic [IQ_DEPTH-1:0] ent_is_load;
    logic [IQ_DEPTH-1:0] ent_is_alu;
    logic [IQ_DEPTH-1:0] ent_older_load_pending;

    logic        free_exist;
    logic [2:0]  free_idx;
    logic        sel_exist;
    logic [2:0]  sel_idx;
    logic        disp_fire;
    logic        issue_fire;
    logic        bypass_fire;

    logic [IQ_DEPTH-1:0] flush_mask;
    logic [IQ_DEPTH-1:0] valid_next;
    logic [IQ_DEPTH-1:0] r1rdy_next;
    logic [IQ_DEPTH-1:0] r2rdy_next;

    logic [3:0] ent_age;
    logic [3:0] flush_age;

    integer fi;
    integer li;
    integer ai;
    integer opi;
    integer opj;
    integer rei;
    integer si;
    integer sei;
    integer fmi;
    integer rni;
    integer vni;
    integer rsti;

    always_comb begin
        free_exist = 1'b0;
        free_idx   = 3'd0;
        for (fi = 0; fi < IQ_DEPTH; fi = fi + 1) begin
            if (!ent_valid[fi] && !free_exist) begin
                free_exist = 1'b1;
                free_idx   = fi[2:0];
            end
        end
    end

    always_comb begin
        for (li = 0; li < IQ_DEPTH; li = li + 1) begin
            ent_is_load[li] = ent_valid[li] &&
                             ((ent_wb_sel[li] == 3'b010) ||
                              (ent_alu_op[li] == 5'd10 && ent_useimm[li] && !ent_br[li] && !ent_jal[li] && !ent_jalr[li] && !ent_auipc[li] && (ent_wb_sel[li] == 3'b010)));
        end
    end

    always_comb begin
        for (ai = 0; ai < IQ_DEPTH; ai = ai + 1) begin
            ent_is_alu[ai] = ent_valid[ai] && !ent_is_load[ai] && !ent_br[ai] && !ent_jal[ai] && !ent_jalr[ai];
        end
    end

    always_comb begin
        for (opi = 0; opi < IQ_DEPTH; opi = opi + 1) begin
            ent_older_load_pending[opi] = 1'b0;
            for (opj = 0; opj < IQ_DEPTH; opj = opj + 1) begin
                if (ent_valid[opj] && ent_is_load[opj] &&
                    (ent_rob[opj] < ent_rob[opi]) &&
                    (ent_rob[opj] != ent_rob[opi])) begin
                    ent_older_load_pending[opi] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (rei = 0; rei < IQ_DEPTH; rei = rei + 1) begin
            ent_ready[rei] = ent_valid[rei] &&
                             ((ent_prs1[rei] == 6'd0) || ent_r1rdy[rei]) &&
                             ((ent_prs2[rei] == 6'd0) || ent_r2rdy[rei]);
        end
    end

    always_comb begin
        sel_exist = 1'b0;
        sel_idx   = 3'd0;
        for (si = 0; si < IQ_DEPTH; si = si + 1) begin
            if (ent_ready[si] && !sel_exist) begin
                if (!ent_older_load_pending[si] || ent_is_alu[si]) begin
                    sel_exist = 1'b1;
                    sel_idx   = si[2:0];
                end
            end
        end
    end

    always_comb begin
        for (sei = 0; sei < IQ_DEPTH; sei = sei + 1) begin
            ent_sel[sei] = sel_exist && (sel_idx == sei[2:0]);
        end
    end

    always_comb begin
        flush_mask = '0;
        for (fmi = 0; fmi < IQ_DEPTH; fmi = fmi + 1) begin
            if (flush && ent_valid[fmi]) begin
                // Full 4-bit head-relative ages.  The ROB window is 16
                // entries; truncating the age to 3 bits makes entries that
                // are OLDER than the flush point look younger and squash
                // them, so their ROB entries never receive a completion and
                // the ROB head freezes forever (simulation timeout).
                ent_age   = ent_rob[fmi] - rob_head_index;
                flush_age = flush_rob_index - rob_head_index;
                if (ent_age >= flush_age) begin
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
                if (alu_complete_valid && (ent_prs1[rni] == alu_complete_prd) && (ent_prs1[rni] != 6'd0)) begin
                    r1rdy_next[rni] = 1'b1;
                end
                if (load_complete_valid && (ent_prs1[rni] == load_complete_prd) && (ent_prs1[rni] != 6'd0)) begin
                    r1rdy_next[rni] = 1'b1;
                end
                if (alu_complete_valid && (ent_prs2[rni] == alu_complete_prd) && (ent_prs2[rni] != 6'd0)) begin
                    r2rdy_next[rni] = 1'b1;
                end
                if (load_complete_valid && (ent_prs2[rni] == load_complete_prd) && (ent_prs2[rni] != 6'd0)) begin
                    r2rdy_next[rni] = 1'b1;
                end
            end
        end
    end

    always_comb begin
        for (vni = 0; vni < IQ_DEPTH; vni = vni + 1) begin
            valid_next[vni] = ent_valid[vni];
            if (flush_mask[vni]) begin
                valid_next[vni] = 1'b0;
            end
        end
        if (issue_fire) begin
            valid_next[sel_idx] = 1'b0;
        end
        if (disp_fire) begin
            valid_next[free_idx] = 1'b1;
        end
    end

    assign disp_fire  = iq_disp_valid && iq_disp_ready && !halted;
    assign issue_fire = issue_valid && issue_ready && !halted;
    assign bypass_fire = issue_fire && ent_is_alu[sel_idx] && ent_older_load_pending[sel_idx];

    // Do not insert a new entry while the redirect is being applied: such an
    // instruction is younger than the flush point (it is still in ID), and the
    // flush_mask can never retroactively clear it, so a zombie would later
    // resolve/flush the ROB with a stale index and the core could livelock.
    assign iq_disp_ready = free_exist && !halted && !flush;

    assign issue_valid = sel_exist && !halted;

    assign issue_pc          = ent_pc[sel_idx];
    assign issue_insn        = ent_insn[sel_idx];
    assign issue_rob_index   = ent_rob[sel_idx];
    assign issue_prs1        = ent_prs1[sel_idx];
    assign issue_prs2        = ent_prs2[sel_idx];
    assign issue_pdst        = ent_pdst[sel_idx];
    assign issue_operand1    = iq_prf_rdata1;
    assign issue_operand2    = iq_prf_rdata2;
    assign issue_imm         = ent_imm[sel_idx];
    assign issue_alu_op      = ent_alu_op[sel_idx];
    assign issue_wb_sel      = ent_wb_sel[sel_idx];
    assign issue_is_branch   = ent_br[sel_idx];
    assign issue_is_jal      = ent_jal[sel_idx];
    assign issue_is_jalr     = ent_jalr[sel_idx];
    assign issue_use_imm     = ent_useimm[sel_idx];
    assign issue_is_auipc    = ent_auipc[sel_idx];
    assign issue_pred_next_pc= ent_prednpc[sel_idx];
    assign issue_pred_taken  = ent_predtk[sel_idx];
    assign issue_pred_type   = ent_predty[sel_idx];

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
                ent_imm[rsti]     <= 32'd0;
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
            for (rsti = 0; rsti < IQ_DEPTH; rsti = rsti + 1) begin
                ent_valid[rsti] <= valid_next[rsti];
                if (valid_next[rsti]) begin
                    ent_r1rdy[rsti] <= r1rdy_next[rsti];
                    ent_r2rdy[rsti] <= r2rdy_next[rsti];
                end else begin
                    ent_r1rdy[rsti] <= 1'b0;
                    ent_r2rdy[rsti] <= 1'b0;
                end
            end
            if (disp_fire) begin
                ent_pc[free_idx]      <= iq_disp_pc;
                ent_insn[free_idx]    <= iq_disp_insn;
                ent_rob[free_idx]     <= iq_disp_rob_index;
                ent_prs1[free_idx]    <= iq_disp_prs1;
                ent_prs2[free_idx]    <= iq_disp_prs2;
                ent_pdst[free_idx]    <= iq_disp_pdst;
                ent_r1rdy[free_idx]   <= (iq_disp_prs1 == 6'd0) || iq_disp_rs1_ready ||
                                         (alu_complete_valid && (iq_disp_prs1 == alu_complete_prd) && (iq_disp_prs1 != 6'd0)) ||
                                         (load_complete_valid && (iq_disp_prs1 == load_complete_prd) && (iq_disp_prs1 != 6'd0));
                ent_r2rdy[free_idx]   <= (iq_disp_prs2 == 6'd0) || iq_disp_rs2_ready ||
                                         (alu_complete_valid && (iq_disp_prs2 == alu_complete_prd) && (iq_disp_prs2 != 6'd0)) ||
                                         (load_complete_valid && (iq_disp_prs2 == load_complete_prd) && (iq_disp_prs2 != 6'd0));
                ent_imm[free_idx]     <= iq_disp_imm;
                ent_alu_op[free_idx]  <= iq_disp_alu_op;
                ent_wb_sel[free_idx]  <= iq_disp_wb_sel;
                ent_br[free_idx]      <= iq_disp_is_branch;
                ent_jal[free_idx]     <= iq_disp_is_jal;
                ent_jalr[free_idx]    <= iq_disp_is_jalr;
                ent_useimm[free_idx]  <= iq_disp_use_imm;
                ent_auipc[free_idx]   <= iq_disp_is_auipc;
                ent_prednpc[free_idx] <= iq_disp_pred_next_pc;
                ent_predtk[free_idx]  <= iq_disp_pred_taken;
                ent_predty[free_idx]  <= iq_disp_pred_type;
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

    localparam logic [1:0] MEM_BYTE = 2'b00;
    localparam logic [1:0] MEM_HALF = 2'b01;

    logic        ent_valid [0:1];
    logic [31:0] ent_pc [0:1];
    logic [31:0] ent_insn [0:1];
    logic [3:0]  ent_rob [0:1];
    logic [5:0]  ent_prs1 [0:1];
    logic [5:0]  ent_prs2 [0:1];
    logic [5:0]  ent_pdst [0:1];
    logic        ent_rs1_ready [0:1];
    logic        ent_rs2_ready [0:1];
    logic [31:0] ent_imm [0:1];
    logic        ent_is_load [0:1];
    logic        ent_is_store [0:1];
    logic [1:0]  ent_mem_size [0:1];
    logic [1:0]  ent_epoch [0:1];
    logic        ent_issued [0:1];
    logic        ent_wait_resp [0:1];
    logic        ent_committed [0:1];

    logic        head_sel;
    logic        tail_sel;

    logic        head_valid;
    logic        head_rs1_ready;
    logic        head_rs2_ready;
    logic        head_is_load;
    logic        head_is_store;
    logic        head_issued;
    logic        head_wait_resp;
    logic        head_committed;
    logic [1:0]  head_mem_size;
    logic [31:0] head_imm;
    logic [31:0] head_pc;
    logic [3:0]  head_rob;
    logic [5:0]  head_prs1;
    logic [5:0]  head_prs2;
    logic [5:0]  head_pdst;
    logic [1:0]  head_epoch;

    logic        tail_valid;
    logic        tail_rs1_ready;
    logic        tail_rs2_ready;
    logic        tail_is_load;
    logic        tail_is_store;
    logic        tail_issued;
    logic        tail_wait_resp;
    logic        tail_committed;
    logic [1:0]  tail_mem_size;
    logic [31:0] tail_imm;
    logic [31:0] tail_pc;
    logic [3:0]  tail_rob;
    logic [5:0]  tail_prs1;
    logic [5:0]  tail_prs2;
    logic [5:0]  tail_pdst;
    logic [1:0]  tail_epoch;

    logic        head_rs1_wake;
    logic        head_rs2_wake;
    logic        tail_rs1_wake;
    logic        tail_rs2_wake;
    logic        tail_rs1_ready_eff;
    logic        tail_rs2_ready_eff;

    logic        head_can_issue;
    logic        head_store_ready;
    logic        head_load_ready;
    logic        head_issue_fire;
    logic        head_resp_fire;
    logic        head_resp_stale;
    logic        head_load_done;
    logic        head_store_done;

    logic [31:0] head_addr;
    logic [3:0]  head_be;
    logic [31:0] head_wdata;

    logic [31:0] load_word;
    logic [31:0] load_data;

    logic        disp_fire;
    logic        disp_to_head;
    logic        disp_to_tail;

    logic        squash_head;
    logic        squash_tail;

    logic        store_commit_match_head;
    logic        store_commit_match_tail;

    logic        head_remove;
    logic        tail_remove;

    assign head_sel = ent_valid[0];
    assign tail_sel = ent_valid[0] & ent_valid[1];

    assign head_valid       = ent_valid[head_sel];
    assign head_pc          = ent_pc[head_sel];
    assign head_insn        = 0;
    assign head_rob         = ent_rob[head_sel];
    assign head_prs1        = ent_prs1[head_sel];
    assign head_prs2        = ent_prs2[head_sel];
    assign head_pdst        = ent_pdst[head_sel];
    assign head_rs1_ready   = ent_rs1_ready[head_sel];
    assign head_rs2_ready   = ent_rs2_ready[head_sel];
    assign head_imm         = ent_imm[head_sel];
    assign head_is_load     = ent_is_load[head_sel];
    assign head_is_store    = ent_is_store[head_sel];
    assign head_mem_size    = ent_mem_size[head_sel];
    assign head_epoch       = ent_epoch[head_sel];
    assign head_issued      = ent_issued[head_sel];
    assign head_wait_resp   = ent_wait_resp[head_sel];
    assign head_committed   = ent_committed[head_sel];

    assign tail_valid       = ent_valid[tail_sel];
    assign tail_pc          = ent_pc[tail_sel];
    assign tail_rob         = ent_rob[tail_sel];
    assign tail_prs1        = ent_prs1[tail_sel];
    assign tail_prs2        = ent_prs2[tail_sel];
    assign tail_pdst        = ent_pdst[tail_sel];
    assign tail_rs1_ready   = ent_rs1_ready[tail_sel];
    assign tail_rs2_ready   = ent_rs2_ready[tail_sel];
    assign tail_imm         = ent_imm[tail_sel];
    assign tail_is_load     = ent_is_load[tail_sel];
    assign tail_is_store    = ent_is_store[tail_sel];
    assign tail_mem_size    = ent_mem_size[tail_sel];
    assign tail_epoch       = ent_epoch[tail_sel];
    assign tail_issued      = ent_issued[tail_sel];
    assign tail_wait_resp   = ent_wait_resp[tail_sel];
    assign tail_committed   = ent_committed[tail_sel];

    assign lsu_prf_rs1_addr = head_valid ? head_prs1 : (tail_valid ? tail_prs1 : 6'd0);
    assign lsu_prf_rs2_addr = head_valid ? head_prs2 : (tail_valid ? tail_prs2 : 6'd0);

    assign head_addr = lsu_prf_rdata1 + head_imm;

    always_comb begin
        head_be = 4'b0000;
        head_wdata = 32'd0;
        case (head_mem_size)
            MEM_BYTE: begin
                head_be = 4'b0001 << head_addr[1:0];
                head_wdata = {4{lsu_prf_rdata2[7:0]}};
            end
            MEM_HALF: begin
                head_be = head_addr[1] ? 4'b1100 : 4'b0011;
                head_wdata = {2{lsu_prf_rdata2[15:0]}};
            end
            default: begin
                head_be = 4'b1111;
                head_wdata = lsu_prf_rdata2;
            end
        endcase
    end

    assign head_rs1_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == head_prs1)) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == head_prs1));
    assign head_rs2_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == head_prs2)) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == head_prs2));
    assign tail_rs1_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == tail_prs1)) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == tail_prs1));
    assign tail_rs2_wake = (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                            (alu_complete_prd == tail_prs2)) ||
                           (load_complete_valid && (load_complete_prd != 6'd0) &&
                            (load_complete_prd == tail_prs2));

    // Only the tail's wake-inclusive readiness is used (when the tail is
    // shifted into the head slot it cannot execute in that same cycle, and
    // the producer's PRF write lands on the very same clock edge).
    assign tail_rs1_ready_eff = (tail_prs1 == 6'd0) || tail_rs1_ready || tail_rs1_wake;
    assign tail_rs2_ready_eff = (tail_prs2 == 6'd0) || tail_rs2_ready || tail_rs2_wake;

    // Issue only with the REGISTERED per-entry operand-ready bits.  Issuing in
    // the same cycle as an ALU/load completion would drive the load/store
    // address (and store data) from the PRF read that is sampled before the
    // producer's non-blocking write lands, i.e. a stale/wild bus request that
    // can send the core off the rails and hang the simulation.  A one-cycle
    // stall after the wake always sees the updated PRF contents.
    assign head_store_ready = head_is_store && head_committed &&
                              ((head_prs1 == 6'd0) || head_rs1_ready) &&
                              ((head_prs2 == 6'd0) || head_rs2_ready);
    assign head_load_ready  = head_is_load &&
                              ((head_prs1 == 6'd0) || head_rs1_ready);

    assign head_can_issue = head_valid && !head_issued && !halted && !flush &&
                            (head_store_ready || head_load_ready);

    assign head_issue_fire = head_can_issue && lsu_dcache_req_ready;

    // A flush squashes the contiguous younger range [flush_rob_index, tail].
    // A raw 4-bit >= comparison is wrong whenever the ROB window wraps past
    // index 15 (e.g. flush at 15, entry at 0 is YOUNGER but 0 >= 15 is false).
    // Use the modular distance instead: an entry is in the squashed range when
    // it is 0..7 slots ahead of the flush point.  A younger store left behind
    // can never receive store_commit_valid and would block the LSU and the ROB
    // head forever (simulation timeout).
    assign squash_head = flush && head_valid &&
                         !((head_rob - flush_rob_index) & 4'h8);
    assign squash_tail = flush && tail_valid &&
                         !((tail_rob - flush_rob_index) & 4'h8);

    assign head_resp_fire = head_issued && lsu_dcache_resp_valid &&
                            (lsu_dcache_resp_epoch == head_epoch) && !squash_head;

    assign head_resp_stale = head_issued && lsu_dcache_resp_valid &&
                             (lsu_dcache_resp_epoch != head_epoch) && !squash_head;

    assign load_word = lsu_dcache_resp_rdata;

    always_comb begin
        load_data = load_word;
        case (head_mem_size)
            MEM_BYTE: begin
                case (head_addr[1:0])
                    2'd0: load_data = {{24{load_word[7]}},  load_word[7:0]};
                    2'd1: load_data = {{24{load_word[15]}}, load_word[15:8]};
                    2'd2: load_data = {{24{load_word[23]}}, load_word[23:16]};
                    default: load_data = {{24{load_word[31]}}, load_word[31:24]};
                endcase
            end
            MEM_HALF: begin
                if (head_addr[1])
                    load_data = {{16{load_word[31]}}, load_word[31:16]};
                else
                    load_data = {{16{load_word[15]}}, load_word[15:0]};
            end
            default: load_data = load_word;
        endcase
    end

    assign head_load_done  = head_resp_fire && head_is_load;
    assign head_store_done = head_resp_fire && head_is_store;

    assign load_complete_valid     = head_load_done;
    assign load_complete_rob_index = head_rob;
    assign load_complete_prd       = head_pdst;
    assign load_complete_data      = load_data;

    assign store_done_valid     = head_store_done;
    assign store_done_rob_index = head_rob;

    assign lsu_dcache_req_valid     = head_can_issue;
    assign lsu_dcache_req_we        = head_is_store;
    assign lsu_dcache_req_addr      = head_addr;
    assign lsu_dcache_req_wdata     = head_wdata;
    assign lsu_dcache_req_be        = head_be;
    assign lsu_dcache_req_rob_index = head_rob;
    assign lsu_dcache_req_epoch     = head_epoch;

    assign lsu_dcache_wait = head_issued && !lsu_dcache_resp_valid;

    assign lsu_idle = !ent_valid[0] && !ent_valid[1];

    assign lsu_disp_ready = !halted && !flush && (!ent_valid[0] || !ent_valid[1]);

    assign disp_fire = lsu_disp_valid && lsu_disp_ready;

    assign store_commit_match_head = store_commit_valid && head_valid &&
                                     (store_commit_rob_index == head_rob);
    assign store_commit_match_tail = store_commit_valid && tail_valid &&
                                     (store_commit_rob_index == tail_rob);

    assign head_remove = head_valid && (head_load_done || head_store_done || squash_head);
    assign tail_remove = tail_valid && squash_tail;

    assign disp_to_head = disp_fire && (!ent_valid[0] ||
                                         (head_remove && (tail_remove || !ent_valid[1])));
    assign disp_to_tail = disp_fire && ent_valid[0] && !disp_to_head;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ent_valid[0]     <= 1'b0;
            ent_valid[1]     <= 1'b0;
            ent_pc[0]        <= 32'd0;
            ent_pc[1]        <= 32'd0;
            ent_insn[0]      <= 32'd0;
            ent_insn[1]      <= 32'd0;
            ent_rob[0]       <= 4'd0;
            ent_rob[1]       <= 4'd0;
            ent_prs1[0]      <= 6'd0;
            ent_prs1[1]      <= 6'd0;
            ent_prs2[0]      <= 6'd0;
            ent_prs2[1]      <= 6'd0;
            ent_pdst[0]      <= 6'd0;
            ent_pdst[1]      <= 6'd0;
            ent_rs1_ready[0] <= 1'b0;
            ent_rs1_ready[1] <= 1'b0;
            ent_rs2_ready[0] <= 1'b0;
            ent_rs2_ready[1] <= 1'b0;
            ent_imm[0]       <= 32'd0;
            ent_imm[1]       <= 32'd0;
            ent_is_load[0]   <= 1'b0;
            ent_is_load[1]   <= 1'b0;
            ent_is_store[0]  <= 1'b0;
            ent_is_store[1]  <= 1'b0;
            ent_mem_size[0]  <= 2'd0;
            ent_mem_size[1]  <= 2'd0;
            ent_epoch[0]     <= 2'd0;
            ent_epoch[1]     <= 2'd0;
            ent_issued[0]    <= 1'b0;
            ent_issued[1]    <= 1'b0;
            ent_wait_resp[0] <= 1'b0;
            ent_wait_resp[1] <= 1'b0;
            ent_committed[0] <= 1'b0;
            ent_committed[1] <= 1'b0;
        end else begin
            if (head_issue_fire) begin
                ent_issued[head_sel]    <= 1'b1;
                ent_wait_resp[head_sel] <= 1'b1;
            end
            if (head_resp_fire || head_resp_stale) begin
                ent_wait_resp[head_sel] <= 1'b0;
            end
            if (head_resp_stale) begin
                ent_issued[head_sel] <= 1'b0;
            end
            if (store_commit_match_head) begin
                ent_committed[head_sel] <= 1'b1;
            end
            if (store_commit_match_tail) begin
                ent_committed[tail_sel] <= 1'b1;
            end

            if (head_remove && !tail_remove) begin
                ent_valid[0]     <= ent_valid[1];
                ent_pc[0]        <= ent_pc[1];
                ent_insn[0]      <= ent_insn[1];
                ent_rob[0]       <= ent_rob[1];
                ent_prs1[0]      <= ent_prs1[1];
                ent_prs2[0]      <= ent_prs2[1];
                ent_pdst[0]      <= ent_pdst[1];
                ent_rs1_ready[0] <= tail_rs1_ready_eff;
                ent_rs2_ready[0] <= tail_rs2_ready_eff;
                ent_imm[0]       <= ent_imm[1];
                ent_is_load[0]   <= ent_is_load[1];
                ent_is_store[0]  <= ent_is_store[1];
                ent_mem_size[0]  <= ent_mem_size[1];
                ent_epoch[0]     <= ent_epoch[1];
                ent_issued[0]    <= ent_issued[1];
                ent_wait_resp[0] <= ent_wait_resp[1];
                // Preserve a store-commit that lands on the tail in the same
                // cycle the tail is shifted up; otherwise the committed store
                // lands in entry 0 with committed=0 and can never issue.
                ent_committed[0] <= ent_committed[1] | store_commit_match_tail;
                ent_valid[1]     <= 1'b0;
            end else if (head_remove && tail_remove) begin
                ent_valid[0] <= 1'b0;
                ent_valid[1] <= 1'b0;
            end else if (tail_remove) begin
                ent_valid[1] <= 1'b0;
            end

            if (!head_remove && ent_valid[0]) begin
                if (head_rs1_wake) ent_rs1_ready[0] <= 1'b1;
                if (head_rs2_wake) ent_rs2_ready[0] <= 1'b1;
            end
            if (!tail_remove && ent_valid[1]) begin
                if (tail_rs1_wake) ent_rs1_ready[1] <= 1'b1;
                if (tail_rs2_wake) ent_rs2_ready[1] <= 1'b1;
            end

            if (disp_to_head) begin
                ent_valid[0]     <= 1'b1;
                ent_pc[0]        <= lsu_disp_pc;
                ent_insn[0]      <= lsu_disp_insn;
                ent_rob[0]       <= lsu_disp_rob_index;
                ent_prs1[0]      <= lsu_disp_prs1;
                ent_prs2[0]      <= lsu_disp_prs2;
                ent_pdst[0]      <= lsu_disp_pdst;
                ent_rs1_ready[0] <= (lsu_disp_prs1 == 6'd0) || lsu_disp_rs1_ready ||
                                    (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                                     (alu_complete_prd == lsu_disp_prs1)) ||
                                    (load_complete_valid && (load_complete_prd != 6'd0) &&
                                     (load_complete_prd == lsu_disp_prs1));
                ent_rs2_ready[0] <= (lsu_disp_prs2 == 6'd0) || lsu_disp_rs2_ready ||
                                    (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                                     (alu_complete_prd == lsu_disp_prs2)) ||
                                    (load_complete_valid && (load_complete_prd != 6'd0) &&
                                     (load_complete_prd == lsu_disp_prs2));
                ent_imm[0]       <= lsu_disp_imm;
                ent_is_load[0]   <= lsu_disp_is_load;
                ent_is_store[0]  <= lsu_disp_is_store;
                ent_mem_size[0]  <= lsu_disp_mem_size;
                ent_epoch[0]     <= flush_epoch;
                ent_issued[0]    <= 1'b0;
                ent_wait_resp[0] <= 1'b0;
                ent_committed[0] <= 1'b0;
            end else if (disp_to_tail) begin
                ent_valid[1]     <= 1'b1;
                ent_pc[1]        <= lsu_disp_pc;
                ent_insn[1]      <= lsu_disp_insn;
                ent_rob[1]       <= lsu_disp_rob_index;
                ent_prs1[1]      <= lsu_disp_prs1;
                ent_prs2[1]      <= lsu_disp_prs2;
                ent_pdst[1]      <= lsu_disp_pdst;
                ent_rs1_ready[1] <= (lsu_disp_prs1 == 6'd0) || lsu_disp_rs1_ready ||
                                    (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                                     (alu_complete_prd == lsu_disp_prs1)) ||
                                    (load_complete_valid && (load_complete_prd != 6'd0) &&
                                     (load_complete_prd == lsu_disp_prs1));
                ent_rs2_ready[1] <= (lsu_disp_prs2 == 6'd0) || lsu_disp_rs2_ready ||
                                    (alu_complete_valid && (alu_complete_prd != 6'd0) &&
                                     (alu_complete_prd == lsu_disp_prs2)) ||
                                    (load_complete_valid && (load_complete_prd != 6'd0) &&
                                     (load_complete_prd == lsu_disp_prs2));
                ent_imm[1]       <= lsu_disp_imm;
                ent_is_load[1]   <= lsu_disp_is_load;
                ent_is_store[1]  <= lsu_disp_is_store;
                ent_mem_size[1]  <= lsu_disp_mem_size;
                ent_epoch[1]     <= flush_epoch;
                ent_issued[1]    <= 1'b0;
                ent_wait_resp[1] <= 1'b0;
                ent_committed[1] <= 1'b0;
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

    logic [31:0] prf [0:39];

    logic [31:0] iq_rdata1_r;
    logic [31:0] iq_rdata2_r;
    logic [31:0] lsu_rdata1_r;
    logic [31:0] lsu_rdata2_r;

    integer i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 40; i = i + 1) begin
                prf[i] <= 32'h0000_0000;
            end
        end else begin
            prf[0] <= 32'h0000_0000;
            if (alu_complete_valid && (alu_complete_prd != 6'd0)) begin
                prf[alu_complete_prd] <= alu_complete_data;
            end
            if (load_complete_valid && (load_complete_prd != 6'd0)) begin
                prf[load_complete_prd] <= load_complete_data;
            end
        end
    end

    always_comb begin
        iq_rdata1_r = (iq_prf_rs1_addr == 6'd0) ? 32'h0000_0000 : prf[iq_prf_rs1_addr];
        iq_rdata2_r = (iq_prf_rs2_addr == 6'd0) ? 32'h0000_0000 : prf[iq_prf_rs2_addr];
        lsu_rdata1_r = (lsu_prf_rs1_addr == 6'd0) ? 32'h0000_0000 : prf[lsu_prf_rs1_addr];
        lsu_rdata2_r = (lsu_prf_rs2_addr == 6'd0) ? 32'h0000_0000 : prf[lsu_prf_rs2_addr];
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
    localparam integer FREE_DEPTH = 32;

    // speculative / architectural rename state
    logic [5:0]  spec_map [0:31];

    // free list of physical registers
    logic [5:0]  free_list [0:FREE_DEPTH-1];
    logic [4:0]  free_head;
    logic [4:0]  free_tail;
    logic [5:0]  free_count;

    // 64 physical registers, full-width ready table
    logic [63:0] ready_tbl;

    // checkpoint of the speculative map at every control instruction
    logic [5:0]  ckpt_map  [0:7][0:31];
    logic [7:0]  ckpt_valid;

    // per-ROB-slot tracking used to reclaim physical registers at commit time
    // (a slot is reused only after its previous occupant left the ROB).
    logic        slot_live [0:7];
    logic [5:0]  slot_pdst [0:7];
    logic [5:0]  slot_old  [0:7];
    logic [3:0]  cur_tail;

    logic [5:0] rs1_prd;
    logic [5:0] rs2_prd;
    logic [5:0] rd_prd;
    logic [5:0] old_prd;
    logic       rs1_rdy;
    logic       rs2_rdy;
    logic       need_pr;
    logic       free_avail;
    logic       disp_ok;
    logic       is_ctrl;
    logic       is_mem;
    logic       is_alu;
    logic       do_alloc;
    logic       do_flush;
    logic       do_ckpt_restore;
    logic       do_ckpt_save;
    logic [2:0] alloc_slot;
    logic [3:0] flush_next4;

    // next-state
    logic [5:0]  spec_map_nxt [0:31];
    logic [5:0]  free_list_nxt [0:FREE_DEPTH-1];
    logic [4:0]  free_head_nxt;
    logic [4:0]  free_tail_nxt;
    logic [5:0]  free_count_nxt;
    logic [63:0] ready_nxt;
    logic [5:0]  ckpt_map_nxt  [0:7][0:31];
    logic [7:0]  ckpt_valid_nxt;
    logic        slot_live_nxt [0:7];
    logic [5:0]  slot_pdst_nxt [0:7];
    logic [5:0]  slot_old_nxt  [0:7];

    integer i;
    integer j;
    integer d;
    logic [3:0] squash_cnt;
    logic [2:0] sq_idx;
    logic [3:0] sq_idx4;

    assign flush_next4 = flush_rob_index + 4'd1;

    always_comb begin
        rs1_prd = (id_rs1 == 5'd0) ? PR_ZERO : spec_map[id_rs1];
        rs2_prd = (id_rs2 == 5'd0) ? PR_ZERO : spec_map[id_rs2];
        // include same-cycle completions so a producer that finishes in the
        // very cycle its consumer is renamed does not get lost.
        rs1_rdy = (rs1_prd == PR_ZERO) ? 1'b1 :
                  (ready_tbl[rs1_prd] ||
                   (alu_complete_valid  && (alu_complete_prd  == rs1_prd)) ||
                   (load_complete_valid && (load_complete_prd == rs1_prd)));
        rs2_rdy = (rs2_prd == PR_ZERO) ? 1'b1 :
                  (ready_tbl[rs2_prd] ||
                   (alu_complete_valid  && (alu_complete_prd  == rs2_prd)) ||
                   (load_complete_valid && (load_complete_prd == rs2_prd)));
        need_pr = id_reg_write && (id_rd != 5'd0);
        free_avail = (free_count != 6'd0);
        is_ctrl = id_is_branch || id_is_jal || id_is_jalr;
        is_mem  = id_is_load || id_is_store;
        is_alu  = !is_mem && !id_is_ecall;
        disp_ok = id_valid && !halted && !ecall_pending && rob_alloc_ready &&
                  (!need_pr || free_avail) &&
                  (!is_alu || iq_disp_ready) &&
                  (!is_mem || lsu_disp_ready);
        id_ready = !halted && !ecall_pending && rob_alloc_ready &&
                   (!need_pr || free_avail) &&
                   (!is_alu || iq_disp_ready) &&
                   (!is_mem || lsu_disp_ready);
        do_alloc = disp_ok;
        do_flush = flush && !halted;
        do_ckpt_restore = do_flush && ckpt_valid[flush_rob_index[2:0]];
        do_ckpt_save = do_alloc && is_ctrl;

        rd_prd  = need_pr ? free_list[free_head] : PR_ZERO;
        old_prd = need_pr ? spec_map[id_rd] : PR_ZERO;
        alloc_slot = rob_alloc_index[2:0];

        rob_alloc_valid = do_alloc;
        rob_alloc_pc = id_pc;
        rob_alloc_insn = id_insn;
        rob_alloc_pdst = rd_prd;
        rob_alloc_old_prd = old_prd;
        rob_alloc_arch_rd = id_rd;
        rob_alloc_is_control = is_ctrl;
        rob_alloc_is_store = id_is_store;
        rob_alloc_is_ecall = id_is_ecall;
        rob_alloc_reg_write = need_pr;

        iq_disp_valid = do_alloc && is_alu;
        iq_disp_pc = id_pc;
        iq_disp_insn = id_insn;
        iq_disp_rob_index = rob_alloc_index;
        iq_disp_prs1 = rs1_prd;
        iq_disp_prs2 = rs2_prd;
        iq_disp_pdst = rd_prd;
        iq_disp_rs1_ready = rs1_rdy;
        iq_disp_rs2_ready = rs2_rdy;
        iq_disp_imm = id_imm;
        iq_disp_alu_op = id_alu_op;
        iq_disp_wb_sel = id_wb_sel;
        iq_disp_is_branch = id_is_branch;
        iq_disp_is_jal = id_is_jal;
        iq_disp_is_jalr = id_is_jalr;
        iq_disp_use_imm = id_use_imm;
        iq_disp_is_auipc = id_is_auipc;
        iq_disp_pred_next_pc = id_pred_next_pc;
        iq_disp_pred_taken = id_pred_taken;
        iq_disp_pred_type = id_pred_type;

        lsu_disp_valid = do_alloc && is_mem;
        lsu_disp_pc = id_pc;
        lsu_disp_insn = id_insn;
        lsu_disp_rob_index = rob_alloc_index;
        lsu_disp_prs1 = rs1_prd;
        lsu_disp_prs2 = rs2_prd;
        lsu_disp_pdst = rd_prd;
        lsu_disp_rs1_ready = rs1_rdy;
        lsu_disp_rs2_ready = rs2_rdy;
        lsu_disp_imm = id_imm;
        lsu_disp_is_load = id_is_load;
        lsu_disp_is_store = id_is_store;
        lsu_disp_mem_size = id_mem_size;
    end

    always_comb begin
        for (i = 0; i < 32; i = i + 1) begin
            spec_map_nxt[i] = spec_map[i];
        end
        for (i = 0; i < FREE_DEPTH; i = i + 1) begin
            free_list_nxt[i] = free_list[i];
        end
        free_head_nxt  = free_head;
        free_tail_nxt  = free_tail;
        free_count_nxt = free_count;
        ready_nxt      = ready_tbl;
        ckpt_valid_nxt = ckpt_valid;
        for (i = 0; i < 8; i = i + 1) begin
            slot_live_nxt[i] = slot_live[i];
            slot_pdst_nxt[i] = slot_pdst[i];
            slot_old_nxt[i]  = slot_old[i];
            for (j = 0; j < 32; j = j + 1) begin
                ckpt_map_nxt[i][j] = ckpt_map[i][j];
            end
        end

        // same-cycle wakeups
        if (alu_complete_valid && (alu_complete_prd != PR_ZERO)) begin
            ready_nxt[alu_complete_prd] = 1'b1;
        end
        if (load_complete_valid && (load_complete_prd != PR_ZERO)) begin
            ready_nxt[load_complete_prd] = 1'b1;
        end

        // flush recovery: the redirecting control instruction survives in the
        // ROB, so its checkpoint stores the map AFTER that control.  Return
        // only younger instructions' destination registers to the free list.
        if (do_flush) begin
            if (do_ckpt_restore) begin
                for (i = 0; i < 32; i = i + 1) begin
                    spec_map_nxt[i] = ckpt_map[flush_rob_index[2:0]][i];
                end
            end
            squash_cnt = cur_tail - flush_next4;
            for (d = 0; d < 8; d = d + 1) begin
                if (d[3:0] < squash_cnt) begin
                    sq_idx4 = flush_next4 + d[3:0];
                    sq_idx = sq_idx4[2:0];
                    if (slot_live[sq_idx]) begin
                        if (slot_pdst[sq_idx] != PR_ZERO) begin
                            free_list_nxt[free_tail_nxt] = slot_pdst[sq_idx];
                            free_tail_nxt  = free_tail_nxt + 5'd1;
                            free_count_nxt = free_count_nxt + 6'd1;
                        end
                        slot_live_nxt[sq_idx] = 1'b0;
                    end
                    ckpt_valid_nxt[sq_idx] = 1'b0;
                end
            end
        end

        // allocation
        if (do_alloc) begin
            // reclaim the old mapping of the instruction that previously
            // occupied this ROB slot (it has committed).
            if (slot_live[alloc_slot] && (slot_old[alloc_slot] != PR_ZERO)) begin
                free_list_nxt[free_tail_nxt] = slot_old[alloc_slot];
                free_tail_nxt  = free_tail_nxt + 5'd1;
                free_count_nxt = free_count_nxt + 6'd1;
            end
            if (need_pr) begin
                free_head_nxt  = free_head_nxt + 5'd1;
                free_count_nxt = free_count_nxt - 6'd1;
                spec_map_nxt[id_rd] = rd_prd;
                ready_nxt[rd_prd]   = 1'b0;
            end
            slot_live_nxt[alloc_slot] = 1'b1;
            slot_pdst_nxt[alloc_slot] = need_pr ? rd_prd : PR_ZERO;
            slot_old_nxt[alloc_slot]  = old_prd;
            if (do_ckpt_save) begin
                // checkpoint AFTER the control instruction takes effect, so
                // redirect can keep that control and preserve its rd mapping
                for (i = 0; i < 32; i = i + 1) begin
                    ckpt_map_nxt[alloc_slot][i] = spec_map_nxt[i];
                end
                ckpt_valid_nxt[alloc_slot] = 1'b1;
            end else begin
                ckpt_valid_nxt[alloc_slot] = 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) begin
                spec_map[i] <= (i == 0) ? PR_ZERO : i[5:0];
            end
            for (i = 0; i < FREE_DEPTH; i = i + 1) begin
                free_list[i] <= 6'd32 + i[5:0];
            end
            free_head  <= 5'd0;
            free_tail  <= 5'd0;
            free_count <= 6'd32;
            ready_tbl  <= {64{1'b1}};
            for (i = 0; i < 8; i = i + 1) begin
                ckpt_valid[i] <= 1'b0;
                slot_live[i]  <= 1'b0;
                slot_pdst[i]  <= PR_ZERO;
                slot_old[i]   <= PR_ZERO;
                for (j = 0; j < 32; j = j + 1) begin
                    ckpt_map[i][j] <= (j == 0) ? PR_ZERO : j[5:0];
                end
            end
            cur_tail <= 4'd0;
        end else if (halted) begin
            // freeze all rename state while halted
        end else begin
            for (i = 0; i < 32; i = i + 1) begin
                spec_map[i] <= spec_map_nxt[i];
            end
            for (i = 0; i < FREE_DEPTH; i = i + 1) begin
                free_list[i] <= free_list_nxt[i];
            end
            free_head  <= free_head_nxt;
            free_tail  <= free_tail_nxt;
            free_count <= free_count_nxt;
            ready_tbl  <= ready_nxt;
            for (i = 0; i < 8; i = i + 1) begin
                ckpt_valid[i] <= ckpt_valid_nxt[i];
                slot_live[i]  <= slot_live_nxt[i];
                slot_pdst[i]  <= slot_pdst_nxt[i];
                slot_old[i]   <= slot_old_nxt[i];
                for (j = 0; j < 32; j = j + 1) begin
                    ckpt_map[i][j] <= ckpt_map_nxt[i][j];
                end
            end
            if (do_flush) begin
                cur_tail <= flush_next4;
            end else if (do_alloc) begin
                cur_tail <= rob_alloc_index + 4'd1;
            end
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

    localparam integer ROB_DEPTH = 8;

    logic [3:0] head;
    logic [3:0] tail;
    logic [3:0] count;

    logic        ent_valid    [0:7];
    logic [3:0]  ent_index    [0:7];
    logic        ent_complete [0:7];
    logic        ent_is_store [0:7];
    logic        ent_is_ecall [0:7];
    logic        ent_is_ctrl  [0:7];
    logic        ent_store_done [0:7];
    logic        ent_ctrl_resolved [0:7];
    logic        ent_ctrl_mispredict [0:7];
    logic [31:0] ent_pc     [0:7];
    logic [31:0] ent_insn   [0:7];
    logic [31:0] ent_value  [0:7];
    logic [5:0]  ent_pdst   [0:7];
    logic [5:0]  ent_old_prd[0:7];
    logic [4:0]  ent_arch_rd[0:7];
    logic        ent_reg_write [0:7];
    logic [31:0] ent_actual_next_pc [0:7];

    logic [2:0] head_slot;
    logic [2:0] tail_slot;
    assign head_slot = head[2:0];
    assign tail_slot = tail[2:0];

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

    logic       flush_fire;
    logic [3:0] flush_idx4;
    logic [3:0] flush_next4;
    logic [3:0] flush_pos4;
    logic [3:0] flush_keep4;
    logic [3:0] flush_cnt4;

    logic       any_mispredict;
    logic [3:0] oldest_mispredict_idx;
    logic [2:0] oldest_mispredict_slot;

    logic [3:0] mp_d;
    logic [3:0] mp_o;

    logic [3:0] clear_idx;

    integer mp_i;
    integer ec_i;
    integer sq_i;

    assign tail_plus1 = tail + 4'd1;
    assign head_plus1 = head + 4'd1;
    assign full  = (count == 4'd8);
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

    assign commit_valid      = commit_fire;
    assign commit_pc         = ent_pc[head_slot];
    assign commit_insn       = ent_insn[head_slot];
    assign commit_value      = ent_value[head_slot];
    assign commit_arch_rd    = ent_arch_rd[head_slot];
    assign commit_reg_write  = ent_reg_write[head_slot];
    assign commit_is_ecall   = ent_is_ecall[head_slot];
    assign commit_old_prd_valid = ent_reg_write[head_slot];
    assign commit_old_prd    = ent_old_prd[head_slot];

    assign store_commit_valid     = head_valid && head_is_store && !halted && !flush_fire;
    assign store_commit_rob_index = head;

    always_comb begin
        any_mispredict = 1'b0;
        oldest_mispredict_idx = 4'd0;
        oldest_mispredict_slot = 3'd0;
        for (mp_i = 0; mp_i < 8; mp_i = mp_i + 1) begin
            if (ent_valid[mp_i] && ent_is_ctrl[mp_i] && ent_ctrl_resolved[mp_i] &&
                ent_ctrl_mispredict[mp_i]) begin
                if (!any_mispredict) begin
                    any_mispredict = 1'b1;
                    oldest_mispredict_idx = ent_index[mp_i];
                    oldest_mispredict_slot = mp_i[2:0];
                end else begin
                    mp_d = ent_index[mp_i] - head;
                    mp_o = ent_index[oldest_mispredict_slot] - head;
                    if (mp_d < mp_o) begin
                        oldest_mispredict_idx = ent_index[mp_i];
                        oldest_mispredict_slot = mp_i[2:0];
                    end
                end
            end
        end
    end

    assign flush_fire = any_mispredict && !halted;
    assign flush_idx4 = oldest_mispredict_idx;
    assign flush_next4 = flush_idx4 + 4'd1;
    assign flush_pos4 = flush_idx4 - head;
    assign flush_keep4 = flush_pos4 + 4'd1;
    assign flush_cnt4 = count - flush_keep4;
    assign flush_valid = flush_fire;
    assign flush_rob_index = flush_idx4;
    assign flush_pc = ent_actual_next_pc[oldest_mispredict_slot];

    always_comb begin
        ecall_pending = 1'b0;
        for (ec_i = 0; ec_i < 8; ec_i = ec_i + 1) begin
            if (ent_valid[ec_i] && ent_is_ecall[ec_i]) begin
                ecall_pending = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            head <= 4'd0;
            tail <= 4'd0;
            count <= 4'd0;
            for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                ent_valid[sq_i]          <= 1'b0;
                ent_index[sq_i]          <= 4'd0;
                ent_complete[sq_i]       <= 1'b0;
                ent_is_store[sq_i]       <= 1'b0;
                ent_is_ecall[sq_i]       <= 1'b0;
                ent_is_ctrl[sq_i]        <= 1'b0;
                ent_store_done[sq_i]     <= 1'b0;
                ent_ctrl_resolved[sq_i]  <= 1'b0;
                ent_ctrl_mispredict[sq_i]<= 1'b0;
                ent_pc[sq_i]             <= 32'd0;
                ent_insn[sq_i]           <= 32'd0;
                ent_value[sq_i]          <= 32'd0;
                ent_pdst[sq_i]           <= 6'd0;
                ent_old_prd[sq_i]        <= 6'd0;
                ent_arch_rd[sq_i]        <= 5'd0;
                ent_reg_write[sq_i]      <= 1'b0;
                ent_actual_next_pc[sq_i] <= 32'd0;
            end
        end else if (halted) begin
            head  <= head;
            tail  <= tail;
            count <= count;
        end else begin
            if (flush_fire) begin
                for (sq_i = 0; sq_i < 8; sq_i = sq_i + 1) begin
                    if (sq_i[3:0] < flush_cnt4) begin
                        clear_idx = flush_next4 + sq_i[3:0];
                        ent_valid[clear_idx[2:0]] <= 1'b0;
                        ent_complete[clear_idx[2:0]] <= 1'b0;
                        ent_is_store[clear_idx[2:0]] <= 1'b0;
                        ent_is_ecall[clear_idx[2:0]] <= 1'b0;
                        ent_is_ctrl[clear_idx[2:0]] <= 1'b0;
                        ent_store_done[clear_idx[2:0]] <= 1'b0;
                        ent_ctrl_resolved[clear_idx[2:0]] <= 1'b0;
                        ent_ctrl_mispredict[clear_idx[2:0]] <= 1'b0;
                    end
                end
                if (ent_valid[oldest_mispredict_slot] && ent_is_ctrl[oldest_mispredict_slot]) begin
                    ent_ctrl_mispredict[oldest_mispredict_slot] <= 1'b0;
                end
                tail <= flush_next4;
                count <= flush_keep4;
            end else begin
                if (commit_fire) begin
                    ent_valid[head_slot] <= 1'b0;
                    ent_complete[head_slot] <= 1'b0;
                    ent_is_store[head_slot] <= 1'b0;
                    ent_is_ecall[head_slot] <= 1'b0;
                    ent_is_ctrl[head_slot] <= 1'b0;
                    ent_store_done[head_slot] <= 1'b0;
                    ent_ctrl_resolved[head_slot] <= 1'b0;
                    ent_ctrl_mispredict[head_slot] <= 1'b0;
                    head <= head_plus1;
                end

                if (alloc_fire) begin
                    ent_valid[tail_slot]           <= 1'b1;
                    ent_index[tail_slot]           <= tail;
                    ent_complete[tail_slot]        <= rob_alloc_is_ecall;
                    ent_is_store[tail_slot]        <= rob_alloc_is_store;
                    ent_is_ecall[tail_slot]        <= rob_alloc_is_ecall;
                    ent_is_ctrl[tail_slot]         <= rob_alloc_is_control;
                    ent_store_done[tail_slot]      <= 1'b0;
                    ent_ctrl_resolved[tail_slot]   <= 1'b0;
                    ent_ctrl_mispredict[tail_slot] <= 1'b0;
                    ent_pc[tail_slot]              <= rob_alloc_pc;
                    ent_insn[tail_slot]            <= rob_alloc_insn;
                    ent_value[tail_slot]           <= 32'd0;
                    ent_pdst[tail_slot]            <= rob_alloc_pdst;
                    ent_old_prd[tail_slot]         <= rob_alloc_old_prd;
                    ent_arch_rd[tail_slot]         <= rob_alloc_arch_rd;
                    ent_reg_write[tail_slot]       <= rob_alloc_reg_write;
                    ent_actual_next_pc[tail_slot]  <= 32'd0;
                    tail <= tail_plus1;
                end

                if (commit_fire && alloc_fire) begin
                    count <= count;
                end else if (commit_fire) begin
                    count <= count - 4'd1;
                end else if (alloc_fire) begin
                    count <= count + 4'd1;
                end
            end

            if (alu_complete_valid) begin
                if (ent_valid[alu_complete_rob_index[2:0]] &&
                    (ent_index[alu_complete_rob_index[2:0]] == alu_complete_rob_index)) begin
                    ent_complete[alu_complete_rob_index[2:0]] <= 1'b1;
                    ent_value[alu_complete_rob_index[2:0]]    <= alu_complete_data;
                end
            end

            if (load_complete_valid) begin
                if (ent_valid[load_complete_rob_index[2:0]] &&
                    (ent_index[load_complete_rob_index[2:0]] == load_complete_rob_index)) begin
                    ent_complete[load_complete_rob_index[2:0]] <= 1'b1;
                    ent_value[load_complete_rob_index[2:0]]    <= load_complete_data;
                end
            end

            if (store_done_valid) begin
                if (ent_valid[store_done_rob_index[2:0]] &&
                    (ent_index[store_done_rob_index[2:0]] == store_done_rob_index)) begin
                    ent_store_done[store_done_rob_index[2:0]] <= 1'b1;
                    ent_complete[store_done_rob_index[2:0]]   <= 1'b1;
                end
            end

            if (resolve_valid) begin
                if (ent_valid[resolve_rob_index[2:0]] &&
                    (ent_index[resolve_rob_index[2:0]] == resolve_rob_index) &&
                    ent_is_ctrl[resolve_rob_index[2:0]]) begin
                    ent_ctrl_resolved[resolve_rob_index[2:0]]   <= 1'b1;
                    ent_ctrl_mispredict[resolve_rob_index[2:0]] <= resolve_mispredict;
                    ent_actual_next_pc[resolve_rob_index[2:0]]  <= resolve_actual_next_pc;
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

    // ---------------- global control ----------------
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

    // ---------------- IF <-> ICache ----------------
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

    // ---------------- IF <-> predictor ----------------
    logic        pred_req_valid;
    logic [31:0] pred_req_pc;
    logic [31:0] pred_next_pc;
    logic        pred_taken;
    logic [1:0]  pred_type;
    logic        pred_hit;

    // ---------------- IF -> ID ----------------
    logic        fetch_valid;
    logic [31:0] fetch_pc;
    logic [31:0] fetch_insn;
    logic [31:0] fetch_pred_next_pc;
    logic        fetch_pred_taken;
    logic [1:0]  fetch_pred_type;
    logic        fetch_pred_hit;

    // ---------------- ID ----------------
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

    // ---------------- rename -> ROB ----------------
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

    // ---------------- rename -> IQ ----------------
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

    // ---------------- rename -> LSU ----------------
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

    // ---------------- PRF ----------------
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

    // ---------------- IQ -> ALU ----------------
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

    // ---------------- ALU -> ROB / rename / predictor ----------------
    logic [3:0]  alu_complete_rob_index;
    logic        resolve_valid;
    logic [3:0]  resolve_rob_index;
    logic [31:0] resolve_pc;
    logic [31:0] resolve_actual;
    logic [31:0] resolve_actual_next_pc;
    logic        resolve_mispredict;
    logic        resolve_taken;
    logic [1:0]  resolve_type;

    // ---------------- LSU <-> DCache ----------------
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

    // ---------------- LSU -> ROB ----------------
    logic        store_commit_valid;
    logic [3:0]  store_commit_rob_index;
    logic        store_done_valid;
    logic [3:0]  store_done_rob_index;
    logic [3:0]  load_complete_rob_index;

    // ---------------- ROB -> commit ----------------
    logic        commit_valid;
    logic [31:0] commit_pc;
    logic [31:0] commit_insn;
    logic [31:0] commit_value;
    logic [4:0]  commit_arch_rd;
    logic        commit_reg_write;
    logic        commit_is_ecall;
    logic        commit_old_prd_valid;
    logic [5:0]  commit_old_prd;

    // ---------------- debug masks ----------------
    logic        evt_en;
    logic        bp_resolve_raw;
    logic        bp_mispredict_raw;
    logic        ooo_issue_raw;
    logic        ooo_bypass_raw;
    logic        iq_dbg_ooo_issue;
    logic        iq_dbg_ooo_bypass;

    assign bus_idle = (!ic_mem_req_valid) && (!dc_mem_req_valid);
    assign evt_en   = rst_n && !halted;

    // ---------------- external bus handshake ----------------
    assign ic_mem_req_ready  = imem_ready;
    assign ic_mem_resp_valid = ic_mem_req_valid && imem_ready;
    assign ic_mem_resp_data  = imem_rdata;

    assign dc_mem_req_ready  = dmem_ready;
    assign dc_mem_resp_valid = dc_mem_req_valid && dmem_ready;
    assign dc_mem_resp_data  = dmem_rdata;

    // ---------------- flush / epoch ----------------
    assign flush           = rob_flush_valid;
    assign flush_rob_index = rob_flush_rob_index;
    assign redirect_pc     = rob_flush_pc;

    assign ecall_pending = rob_ecall_pending || ecall_seen;
    // Keep the front end stopped from the moment an ECALL actually enters the
    // ROB until halt, so no younger instruction can allocate or start a bus
    // transaction after the ECALL has committed.  The stop is armed only on a
    // real ECALL acceptance (ID handshake AND ROB allocation handshake):
    // arming it while the ECALL is still waiting in ID behind a full ROB or a
    // full dispatch queue would clear id_valid on the next cycle and silently
    // drop the ECALL before it is ever allocated, so the core could never
    // commit the ECALL and never halt (simulation timeout).
    // Arm the stop in the very cycle the ECALL is accepted as well: otherwise
    // the IF stage launches one more fetch for the instruction after the ECALL
    // in that cycle, and its I-Cache refill can still be in flight when the
    // ECALL reaches the ROB head, holding bus_idle low and making the commit
    // unit miss the single-cycle ECALL retire.
    assign if_ecall_stop = ecall_pending || ecall_accept;

    assign ecall_accept = id_valid && id_ready && id_is_ecall &&
                          rob_alloc_valid && rob_alloc_ready && rob_alloc_is_ecall;

    // The epoch must only change on a real redirect.  Bumping it on ECALL
    // acceptance used to invalidate in-flight data-cache transactions of
    // OLDER loads/stores (they are not squashed by an ECALL), leaving the
    // LSU waiting for a response that was tagged with the old epoch and
    // therefore stalling the ROB head forever (no ECALL commit, no halt,
    // simulation timeout).  Stopping the front end does not require an
    // epoch change: id_valid is already gated by ecall_pending.
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

    // ---------------- predictor resolve ----------------
    assign resolve_actual_next_pc = resolve_actual;
    assign resolve_mispredict     = resolve_valid && (resolve_actual != issue_pred_next_pc);
    assign resolve_taken          = resolve_valid && (resolve_actual != (resolve_pc + 32'd4));
    assign resolve_type           = issue_is_branch ? PT_COND :
                                    issue_is_jal    ? PT_JAL  :
                                    issue_is_jalr   ? PT_JALR : PT_NONE;

    // ---------------- debug events ----------------
    assign bp_resolve_raw    = resolve_valid;
    assign bp_mispredict_raw = resolve_mispredict;
    assign ooo_issue_raw     = iq_dbg_ooo_issue;
    assign ooo_bypass_raw    = iq_dbg_ooo_bypass;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dbg_bp_resolve    <= 1'b0;
            dbg_bp_mispredict <= 1'b0;
            dbg_ooo_issue     <= 1'b0;
            dbg_ooo_bypass    <= 1'b0;
        end else begin
            dbg_bp_resolve    <= evt_en && bp_resolve_raw;
            dbg_bp_mispredict <= evt_en && bp_mispredict_raw;
            dbg_ooo_issue     <= evt_en && ooo_issue_raw;
            dbg_ooo_bypass    <= evt_en && ooo_bypass_raw;
        end
    end

    assign dbg_features = 3'b111;

    // ---------------- external bus ----------------
    assign imem_valid = rst_n && ic_mem_req_valid;
    assign imem_addr  = ic_mem_req_addr;

    assign dmem_valid = rst_n && dc_mem_req_valid;
    assign dmem_we    = dc_mem_req_we;
    assign dmem_addr  = dc_mem_req_addr;
    assign dmem_wdata = dc_mem_req_wdata;
    assign dmem_be    = dc_mem_req_be;

    // ---------------- instances ----------------
    rv32i5_icache u_icache (
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

// -----------------------------------------------------------------------------
// Local direct-mapped instruction cache, same port contract as plan `icache`.
// -----------------------------------------------------------------------------
module rv32i5_icache (
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

    logic [127:0] line_data  [0:15];
    logic [23:0]  line_tag   [0:15];
    logic [15:0]  line_valid;

    logic [31:0] req_addr;
    logic [1:0]  req_epoch;

    logic [31:0]  refill_base;
    logic [1:0]   refill_word;
    logic [127:0] refill_data;
    logic [127:0] refill_next;
    logic [23:0]  refill_tag;
    logic [3:0]   refill_idx;

    logic [31:0] resp_data_r;
    logic [1:0]  resp_epoch_r;

    logic [3:0]  cpu_idx;
    logic [23:0] cpu_tag;
    logic [1:0]  cpu_wsel;
    logic        cpu_hit;
    logic [31:0] cpu_word;
    logic [127:0] cpu_line;

    logic [1:0]  ref_wsel;
    logic [31:0] ref_word;

    assign cpu_idx  = cpu_req_addr[7:4];
    assign cpu_tag  = cpu_req_addr[31:8];
    assign cpu_wsel = cpu_req_addr[3:2];

    always_comb begin
        cpu_line = line_data[cpu_idx];
        cpu_hit  = line_valid[cpu_idx] && (line_tag[cpu_idx] == cpu_tag);
        case (cpu_wsel)
            2'd0:    cpu_word = cpu_line[31:0];
            2'd1:    cpu_word = cpu_line[63:32];
            2'd2:    cpu_word = cpu_line[95:64];
            default: cpu_word = cpu_line[127:96];
        endcase
    end

    assign ref_wsel = req_addr[3:2];
    always_comb begin
        case (ref_wsel)
            2'd0:    ref_word = refill_next[31:0];
            2'd1:    ref_word = refill_next[63:32];
            2'd2:    ref_word = refill_next[95:64];
            default: ref_word = refill_next[127:96];
        endcase
    end

    always_comb begin
        refill_next = refill_data;
        case (refill_word)
            2'd0:    refill_next[31:0]    = mem_resp_data;
            2'd1:    refill_next[63:32]   = mem_resp_data;
            2'd2:    refill_next[95:64]   = mem_resp_data;
            default: refill_next[127:96]  = mem_resp_data;
        endcase
    end

    assign cpu_req_ready  = (state == ST_IDLE) && !halted;

    assign cpu_resp_valid = (state == ST_RESP);
    assign cpu_resp_data  = resp_data_r;
    assign cpu_resp_epoch = resp_epoch_r;

    assign mem_req_valid = (state == ST_REFILL);
    assign mem_req_addr  = refill_base + {refill_word, 2'b00};

    assign idle = (state == ST_IDLE) && !cpu_req_valid;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            line_valid   <= 16'b0;
            req_addr     <= 32'b0;
            req_epoch    <= 2'b0;
            refill_base  <= 32'b0;
            refill_word  <= 2'b0;
            refill_data  <= 128'b0;
            refill_tag   <= 24'b0;
            refill_idx   <= 4'b0;
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
                            refill_tag  <= cpu_req_addr[31:8];
                            refill_idx  <= cpu_req_addr[7:4];
                            refill_word <= 2'b00;
                            refill_data <= 128'b0;
                            state       <= ST_REFILL;
                        end
                    end
                end
                ST_REFILL: begin
                    if (mem_req_ready) begin
                        refill_data <= refill_next;
                        if (refill_word == 2'b11) begin
                            line_data[refill_idx]  <= refill_next;
                            line_tag[refill_idx]   <= refill_tag;
                            line_valid[refill_idx] <= 1'b1;
                            resp_data_r  <= ref_word;
                            resp_epoch_r <= req_epoch;
                            state        <= ST_RESP;
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

