

module systolicarray 
#( parameter int N = 16)
(
    input logic                          clk,
    input logic                          rst,

    input logic                          process,

    input logic  [N-1:0][(2*N)-2:0][7:0] in_row,  
    input logic  [N-1:0][(2*N)-2:0][7:0] in_col,  

    output logic [N-1:0][N-1:0][31:0]    out_c

);

  logic [N-1:0][N:0][7:0] rowInterConnect; // N + 1 row interconnect wires 
  logic [N:0][N-1:0][7:0] colInterConnect; // N + 1 column interconnect wires 

  // Attach Matrix Inputs to First Col/Row PE input 
  for (genvar i = 0; i < N; i++ ) begin: interconnect

  assign rowInterConnect [i][0] = in_row [i][0]; //First Col PE's
  assign colInterConnect [0][i] = in_col [i][0]; //First Row PE's

  end:interconnect

  for (genvar i = 0; i < N; i++) begin: PerRow
    for (genvar j = 0; j < N; j++) begin: PerCol

      pe u_pe
      ( 
        .clk,
        .rst,
        .process,

        .in_a (rowInterConnect[i][j]),
        .in_b (colInterConnect[i][j]),

        .out_a (rowInterConnect[i][j+1]),
        .out_b (colInterConnect[i+1][j]),
        .out (out_c[i][j])
      );

    end: PerCol
  end: PerRow


endmodule