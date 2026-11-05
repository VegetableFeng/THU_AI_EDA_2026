`timescale 1ns/1ps
module top;
  tb_agent_rv32i5 tb();
  always @(posedge tb.u_teacher_tb.clk) begin
    if (tb.u_teacher_tb.cur_test == "t01_reset" && tb.u_teacher_tb.cycle_count >= 8
        && tb.u_teacher_tb.cycle_count < 30)
      $display("P|c=%0d rst=%b ireq=%b iaddr=%h irdy=%b iresp=%b pc=%h epoch=%b ifidv=%b",
        tb.u_teacher_tb.cycle_count, tb.u_teacher_tb.rst_n,
        tb.u_teacher_tb.dut.if_cpu_req_valid, tb.u_teacher_tb.dut.if_cpu_req_addr,
        tb.u_teacher_tb.dut.if_cpu_req_ready, tb.u_teacher_tb.dut.if_cpu_resp_valid,
        tb.u_teacher_tb.dut.u_if_stage.pc, tb.u_teacher_tb.dut.flush_epoch,
        tb.u_teacher_tb.dut.if2id_valid);
  end
endmodule
