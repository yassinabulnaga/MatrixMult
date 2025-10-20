module fifo_wrapper#(parameter int W=16, LGFLEN=7)(
  input  logic clk, rst_n,
  input  logic [W-1:0] s_data,
  input  logic         s_valid,
  output logic         s_ready,
  output logic [W-1:0] m_data,
  output logic         m_valid,
  input  logic         m_ready
);
  wire full, empty;
  wire do_wr = s_valid && !full;
  wire do_rd = !empty && m_ready;

  sfifo #(
    .BW(W), .LGFLEN(LGFLEN),
    .OPT_ASYNC_READ(1'b0),        // sync read → BRAM
    .OPT_WRITE_ON_FULL(1'b0),
    .OPT_READ_ON_EMPTY(1'b0)
  ) u (
    .i_clk(clk), .i_reset(!rst_n),// note active-high
    .i_wr(do_wr), .i_data(s_data), .o_full(full), .o_fill(),
    .i_rd(do_rd), .o_data(m_data), .o_empty(empty)
  );

  assign s_ready = !full;
  assign m_valid = !empty;
endmodule