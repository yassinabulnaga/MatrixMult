// ====================== pe_array.sv ======================
// Wires a T×T mesh of PEs.
// - A streams in from WEST (one element per row) and moves EAST.
// - B streams in from NORTH (one element per column) and moves SOUTH.
// - drain_pulse snakes (serpentine) across all PEs so every tile sees the edge.
// - On each PE's drain edge, we latch its accumulator into acc_mat and raise acc_v_mat.

import mm_pkg::*;

module pe_array #(
  parameter int W        = mm_pkg::W,
  parameter int ACCW     = mm_pkg::ACCW,
  parameter int T        = mm_pkg::T,
  parameter bit SIGNED_M = mm_pkg::SIGNED_M,
  parameter bit PIPE_MUL = mm_pkg::PIPE_MUL
)(
  input  logic                     clk,
  input  logic                     rst_n,

  // WEST ingress: A for each row (row i drives column 0)
  input  logic [T-1:0][W-1:0]      a_in_row,
  input  logic [T-1:0]             a_in_valid,

  // NORTH ingress: B for each column (column j drives row 0)
  input  logic [T-1:0][W-1:0]      b_in_col,
  input  logic [T-1:0]             b_in_valid,

  // control
  input  logic                     acc_clear_block,  // broadcast clear
  input  logic                     drain_pulse,      // inject at [0][0]

  // accumulator snapshot grid
  output logic [T-1:0][T-1:0][ACCW-1:0] acc_mat,
  output logic [T-1:0][T-1:0]           acc_v_mat
);

  // internal wave signals
  logic [T-1:0][T-1:0][W-1:0] a_sig, b_sig;
  logic [T-1:0][T-1:0]        av_sig, bv_sig;
  logic [T-1:0][T-1:0]        drain_sig;

  // border injection (correct orientation)
  for (genvar i = 0; i < T; i++) begin : g_west_in
    assign a_sig[i][0]  = a_in_row[i];
    assign av_sig[i][0] = a_in_valid[i];
  end
  for (genvar j = 0; j < T; j++) begin : g_north_in
    assign b_sig[0][j]  = b_in_col[j];
    assign bv_sig[0][j] = b_in_valid[j];
  end

  // drain injection at origin
  assign drain_sig[0][0] = drain_pulse;

  // grid
  for (genvar i = 0; i < T; i++) begin : g_row
    for (genvar j = 0; j < T; j++) begin : g_col
      localparam bit EVEN_ROW = ((i % 2) == 0);

      // PE hookups
      logic [W-1:0]    a_out_w, b_out_w;
      logic            av_out_w, bv_out_w;
      logic [ACCW-1:0] acc_w;
      logic            acc_v_w;
      logic            drain_out_w;
      wire             drain_in_w =
        (EVEN_ROW) ?
          // even rows: left -> right
          ((i==0 && j==0) ? drain_sig[0][0] :
           (j>0)          ? drain_sig[i][j-1] :
                            drain_sig[i-1][j]) :
          // odd rows: right -> left
          ((i==0 && j==T-1) ? drain_sig[0][0] :
           (j+1 < T)        ? drain_sig[i][j+1] :
                              drain_sig[i-1][j]);

      pe #(
        .W(W), .ACCW(ACCW), .SIGNED(SIGNED_M), .PIPE_MUL(PIPE_MUL)
      ) u_pe (
        .clk            (clk),
        .rst_n          (rst_n),
        .a              (a_sig[i][j]),
        .b              (b_sig[i][j]),
        .a_valid        (av_sig[i][j]),
        .b_valid        (bv_sig[i][j]),
        .a_out          (a_out_w),
        .b_out          (b_out_w),
        .a_valid_out    (av_out_w),
        .b_valid_out    (bv_out_w),
        .acc_clear_block(acc_clear_block),
        .drain_in       (drain_in_w),
        .drain_out      (drain_out_w),
        .acc_out        (acc_w),
        .acc_out_valid  (acc_v_w)
      );

      // snapshot on this PE's drain edge
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          acc_mat[i][j]   <= '0;
          acc_v_mat[i][j] <= 1'b0;
        end else begin
          if (acc_v_w)           begin acc_mat[i][j] <= acc_w; acc_v_mat[i][j] <= 1'b1; end
          else if (acc_clear_block) acc_v_mat[i][j] <= 1'b0;
        end
      end

      // data forwarding: A east, B south
      if (j+1 < T) begin
        assign a_sig[i][j+1]  = a_out_w;
        assign av_sig[i][j+1] = av_out_w;
      end
      if (i+1 < T) begin
        assign b_sig[i+1][j]  = b_out_w;
        assign bv_sig[i+1][j] = bv_out_w;
      end

      // drain serpentine propagation
      if (EVEN_ROW) begin
        if (j+1 < T)      assign drain_sig[i][j+1] = drain_out_w; // move east
        else if (i+1 < T) assign drain_sig[i+1][j] = drain_out_w; // drop south at row end
      end else begin
        if (j > 0)        assign drain_sig[i][j-1] = drain_out_w; // move west
        else if (i+1 < T) assign drain_sig[i+1][j] = drain_out_w; // drop south at row start
      end

    end
  end

endmodule
