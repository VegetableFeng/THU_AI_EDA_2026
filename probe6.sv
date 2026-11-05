`timescale 1ns/1ps
module top;
  tb_agent_rv32i5 tb();
  always @(posedge tb.u_teacher_tb.clk) begin
    if (tb.u_teacher_tb.cur_test == "t11_halt" && tb.u_teacher_tb.cycle_count > 0
        && (tb.u_teacher_tb.dut.u_id_stage.is_ecall === 1'b1
            || tb.u_teacher_tb.dut.halted === 1'b1
            || tb.u_teacher_tb.cycle_count % 40 == 0))
      $display("PROBE|c=%0d insn=%h isecall=%b ecalldone=%b id2execall=%b halted=%b pc=%h ifidv=%b",
        tb.u_teacher_tb.cycle_count, tb.u_teacher_tb.dut.if2id_insn,
        tb.u_teacher_tb.dut.u_id_stage.is_ecall, tb.u_teacher_tb.dut.u_id_stage.ecall_hit,
        tb.u_teacher_tb.dut.u_id_stage.idex_ecall, tb.u_teacher_tb.dut.halted,
        tb.u_teacher_tb.dut.u_if_stage.pc, tb.u_teacher_tb.dut.if2id_valid);
  end
endmodule
