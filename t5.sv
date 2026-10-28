module t5(input logic [31:0] b, output logic [31:0] y);
  always_comb begin
    y = b[4:0];
  end
endmodule
