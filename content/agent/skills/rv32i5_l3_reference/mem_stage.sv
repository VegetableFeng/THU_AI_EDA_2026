module mem_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        halted,
    input  logic        ex2mem_valid,
    input  logic [31:0] ex2mem_pc,
    input  logic [31:0] ex2mem_pc4,
    input  logic [31:0] ex2mem_insn,
    input  logic [31:0] ex2mem_alu_result,
    input  logic [31:0] ex2mem_store_data,
    input  logic [4:0]  ex2mem_rd,
    input  logic        ex2mem_reg_write,
    input  logic        ex2mem_mem_read,
    input  logic        ex2mem_mem_write,
    input  logic [1:0]  ex2mem_wb_sel,
    input  logic [2:0]  ex2mem_funct3,
    input  logic        ex2mem_is_ecall,
    output logic        cpu_req_valid,
    output logic        cpu_req_we,
    output logic [31:0] cpu_req_addr,
    output logic [31:0] cpu_req_wdata,
    output logic [3:0]  cpu_req_be,
    input  logic        cpu_req_ready,
    input  logic        cpu_resp_valid,
    input  logic [31:0] cpu_resp_rdata,
    output logic        mem_stall,
    output logic        mem2wb_valid,
    output logic [31:0] mem2wb_pc,
    output logic [31:0] mem2wb_insn,
    output logic [31:0] mem2wb_wdata,
    output logic [4:0]  mem2wb_rd,
    output logic        mem2wb_reg_write,
    output logic        mem2wb_is_ecall
);

    localparam logic [1:0] WB_SEL_ALU  = 2'b00;
    localparam logic [1:0] WB_SEL_MEM  = 2'b01;
    localparam logic [1:0] WB_SEL_PC4  = 2'b10;
    localparam logic [1:0] WB_SEL_PC   = 2'b11;

    localparam logic [2:0] F3_LB  = 3'b000;
    localparam logic [2:0] F3_LH  = 3'b001;
    localparam logic [2:0] F3_LW  = 3'b010;
    localparam logic [2:0] F3_LBU = 3'b100;
    localparam logic [2:0] F3_LHU = 3'b101;
    localparam logic [2:0] F3_SB  = 3'b000;
    localparam logic [2:0] F3_SH  = 3'b001;
    localparam logic [2:0] F3_SW  = 3'b010;

    logic        mem_active;
    logic        mem_is_load;
    logic        mem_is_store;
    logic        mem_wait_resp;
    logic [31:0] mem_addr;
    logic [31:0] mem_store_data;
    logic [2:0]  mem_funct3;
    logic [31:0] mem_pc;
    logic [31:0] mem_pc4;
    logic [31:0] mem_insn;
    logic [4:0]  mem_rd;
    logic        mem_reg_write;
    logic [1:0]  mem_wb_sel;
    logic        mem_is_ecall;

    logic [31:0] store_wdata;
    logic [3:0]  store_be;

    logic [31:0] load_data;
    logic [31:0] wb_data;

    always_comb begin
        store_wdata = ex2mem_store_data;
        store_be    = 4'b0000;
        case (ex2mem_funct3)
            F3_SB: begin
                store_wdata = {4{ex2mem_store_data[7:0]}};
                store_be    = 4'b0001 << ex2mem_alu_result[1:0];
            end
            F3_SH: begin
                store_wdata = {2{ex2mem_store_data[15:0]}};
                store_be    = ex2mem_alu_result[1] ? 4'b1100 : 4'b0011;
            end
            F3_SW: begin
                store_wdata = ex2mem_store_data;
                store_be    = 4'b1111;
            end
            default: begin
                store_wdata = ex2mem_store_data;
                store_be    = 4'b0000;
            end
        endcase
    end

    always_comb begin
        cpu_req_valid = 1'b0;
        cpu_req_we    = 1'b0;
        cpu_req_addr  = 32'b0;
        cpu_req_wdata = 32'b0;
        cpu_req_be    = 4'b0000;
        if (rst_n && !halted) begin
            if (mem_active) begin
                if (mem_is_load) begin
                    cpu_req_valid = !mem_wait_resp;
                    cpu_req_we    = 1'b0;
                    cpu_req_addr  = mem_addr;
                    cpu_req_wdata = 32'b0;
                    cpu_req_be    = 4'b0000;
                end else if (mem_is_store) begin
                    cpu_req_valid = !mem_wait_resp;
                    cpu_req_we    = 1'b1;
                    cpu_req_addr  = mem_addr;
                    cpu_req_wdata = store_wdata;
                    cpu_req_be    = store_be;
                end
            end else if (ex2mem_valid && (ex2mem_mem_read || ex2mem_mem_write)) begin
                if (ex2mem_mem_read) begin
                    cpu_req_valid = 1'b1;
                    cpu_req_we    = 1'b0;
                    cpu_req_addr  = ex2mem_alu_result;
                    cpu_req_wdata = 32'b0;
                    cpu_req_be    = 4'b0000;
                end else begin
                    cpu_req_valid = 1'b1;
                    cpu_req_we    = 1'b1;
                    cpu_req_addr  = ex2mem_alu_result;
                    cpu_req_wdata = store_wdata;
                    cpu_req_be    = store_be;
                end
            end
        end
    end

    always_comb begin
        mem_stall = 1'b0;
        if (rst_n && !halted) begin
            if (mem_active) begin
                mem_stall = 1'b1;
            end else if (ex2mem_valid && (ex2mem_mem_read || ex2mem_mem_write)) begin
                if (!cpu_req_ready) begin
                    mem_stall = 1'b1;
                end
            end
        end
    end

    always_comb begin
        load_data = 32'b0;
        case (mem_funct3)
            F3_LB: begin
                case (mem_addr[1:0])
                    2'b00: load_data = {{24{cpu_resp_rdata[7]}},  cpu_resp_rdata[7:0]};
                    2'b01: load_data = {{24{cpu_resp_rdata[15]}}, cpu_resp_rdata[15:8]};
                    2'b10: load_data = {{24{cpu_resp_rdata[23]}}, cpu_resp_rdata[23:16]};
                    default: load_data = {{24{cpu_resp_rdata[31]}}, cpu_resp_rdata[31:24]};
                endcase
            end
            F3_LH: begin
                if (mem_addr[1]) begin
                    load_data = {{16{cpu_resp_rdata[31]}}, cpu_resp_rdata[31:16]};
                end else begin
                    load_data = {{16{cpu_resp_rdata[15]}}, cpu_resp_rdata[15:0]};
                end
            end
            F3_LW: begin
                load_data = cpu_resp_rdata;
            end
            F3_LBU: begin
                case (mem_addr[1:0])
                    2'b00: load_data = {24'b0, cpu_resp_rdata[7:0]};
                    2'b01: load_data = {24'b0, cpu_resp_rdata[15:8]};
                    2'b10: load_data = {24'b0, cpu_resp_rdata[23:16]};
                    default: load_data = {24'b0, cpu_resp_rdata[31:24]};
                endcase
            end
            F3_LHU: begin
                if (mem_addr[1]) begin
                    load_data = {16'b0, cpu_resp_rdata[31:16]};
                end else begin
                    load_data = {16'b0, cpu_resp_rdata[15:0]};
                end
            end
            default: begin
                load_data = cpu_resp_rdata;
            end
        endcase
    end

    always_comb begin
        wb_data = mem_pc4;
        case (mem_wb_sel)
            WB_SEL_ALU: wb_data = mem_pc4;
            WB_SEL_MEM: wb_data = load_data;
            WB_SEL_PC4: wb_data = mem_pc4;
            WB_SEL_PC:  wb_data = mem_pc;
            default:    wb_data = mem_pc4;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_active      <= 1'b0;
            mem_is_load     <= 1'b0;
            mem_is_store    <= 1'b0;
            mem_wait_resp   <= 1'b0;
            mem_addr        <= 32'b0;
            mem_store_data  <= 32'b0;
            mem_funct3      <= 3'b0;
            mem_pc          <= 32'b0;
            mem_pc4         <= 32'b0;
            mem_insn        <= 32'b0;
            mem_rd          <= 5'b0;
            mem_reg_write   <= 1'b0;
            mem_wb_sel      <= 2'b0;
            mem_is_ecall    <= 1'b0;
            mem2wb_valid    <= 1'b0;
            mem2wb_pc       <= 32'b0;
            mem2wb_insn     <= 32'b0;
            mem2wb_wdata    <= 32'b0;
            mem2wb_rd       <= 5'b0;
            mem2wb_reg_write<= 1'b0;
            mem2wb_is_ecall <= 1'b0;
        end else if (halted) begin
            mem_active      <= 1'b0;
            mem_is_load     <= 1'b0;
            mem_is_store    <= 1'b0;
            mem_wait_resp   <= 1'b0;
            mem2wb_valid    <= 1'b0;
            mem2wb_reg_write<= 1'b0;
            mem2wb_is_ecall <= 1'b0;
        end else begin
            mem2wb_valid    <= 1'b0;
            mem2wb_reg_write<= 1'b0;
            mem2wb_is_ecall <= 1'b0;

            if (mem_active) begin
                // D-Cache 的响应可能只保持一个周期，甚至在请求被接受的
                // 同一拍就到达。必须先看响应，再看 ready；否则会错过
                // S_RESP 的 resp_valid，导致 MEM 永久等待。
                if (cpu_resp_valid) begin
                    mem2wb_valid     <= 1'b1;
                    mem2wb_pc        <= mem_pc;
                    mem2wb_insn      <= mem_insn;
                    mem2wb_wdata     <= wb_data;
                    mem2wb_rd        <= mem_rd;
                    mem2wb_reg_write <= mem_reg_write;
                    mem2wb_is_ecall  <= mem_is_ecall;
                    mem_active       <= 1'b0;
                    mem_is_load      <= 1'b0;
                    mem_is_store     <= 1'b0;
                    mem_wait_resp    <= 1'b0;
                end else if (!mem_wait_resp && cpu_req_ready) begin
                    mem_wait_resp <= 1'b1;
                end
            end else if (ex2mem_valid) begin
                if (ex2mem_mem_read || ex2mem_mem_write) begin
                    mem_active     <= 1'b1;
                    mem_is_load    <= ex2mem_mem_read;
                    mem_is_store   <= ex2mem_mem_write;
                    mem_wait_resp  <= 1'b0;
                    mem_addr       <= ex2mem_alu_result;
                    mem_store_data <= ex2mem_store_data;
                    mem_funct3     <= ex2mem_funct3;
                    mem_pc         <= ex2mem_pc;
                    mem_pc4        <= ex2mem_pc4;
                    mem_insn       <= ex2mem_insn;
                    mem_rd         <= ex2mem_rd;
                    mem_reg_write  <= ex2mem_reg_write;
                    mem_wb_sel     <= ex2mem_wb_sel;
                    mem_is_ecall   <= ex2mem_is_ecall;
                end else begin
                    mem2wb_valid     <= 1'b1;
                    mem2wb_pc        <= ex2mem_pc;
                    mem2wb_insn      <= ex2mem_insn;
                    mem2wb_wdata     <= (ex2mem_wb_sel == WB_SEL_PC4) ? ex2mem_pc4 :
                                        (ex2mem_wb_sel == WB_SEL_PC)  ? ex2mem_pc  :
                                                                        ex2mem_alu_result;
                    mem2wb_rd        <= ex2mem_rd;
                    mem2wb_reg_write <= ex2mem_reg_write;
                    mem2wb_is_ecall  <= ex2mem_is_ecall;
                end
            end
        end
    end

endmodule
