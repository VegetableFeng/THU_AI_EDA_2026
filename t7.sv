module t7(input logic [31:0] a, input logic [31:0] b, input logic clk, output logic [31:0] y);
  always_ff @(posedge clk) begin
    y <= a << b[4:0];
  end
endmodule
