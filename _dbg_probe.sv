`timescale 1ns/1ps
module top;
  tb_agent_rv32i5 tb();
  wire [3:0] rh = tb.u_teacher_tb.dut.u_rob.head;
  always @(posedge tb.u_teacher_tb.clk) begin
    if (tb.u_teacher_tb.cycle_count >= 30133 && tb.u_teacher_tb.cycle_count < 30160)
      $display("D|c=%0d pc=%h rob h=%0d vc=%b%b | lreq=%b ret=%b",
        tb.u_teacher_tb.cycle_count, tb.u_teacher_tb.imem_addr, rh,
        tb.u_teacher_tb.dut.u_rob.ent_valid[rh], tb.u_teacher_tb.dut.u_rob.ent_complete[rh],
        tb.u_teacher_tb.dut.lsu_cpu_req_valid, tb.u_teacher_tb.dut.commit_valid);
  end
endmodule
