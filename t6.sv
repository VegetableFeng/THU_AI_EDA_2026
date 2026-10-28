module t6(input logic [31:0] a, input logic [31:0] b, output logic [31:0] y);
  always_comb begin
    y = a + b[4:0];
  end
endmodule
