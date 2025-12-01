// ======================== pe.sv ========================
module pe #(
  parameter int W        = 8,   // element width
  parameter int ACCW     = 32,  // accumulator width
  parameter bit SIGNED   = 1,   // signed multiply?
  parameter bit PIPE_MUL = 0    // insert 1-cycle pipe between MUL and ADD
)(
  input  logic               clk,
  input  logic               rst_n,

  // streaming operands (forwarded through the mesh)
  input  logic [W-1:0]       a,
  input  logic [W-1:0]       b,
  input  logic               a_valid,
  input  logic               b_valid,

  output logic [W-1:0]       a_out,
  output logic [W-1:0]       b_out,
  output logic               a_valid_out,
  output logic               b_valid_out,

  // control
  input  logic               acc_clear_block, // clear accumulator for new C-tile
  input  logic               drain_in,        // edge-triggered "snapshot/drain" token
  output logic               drain_out,

  // accumulator observation (latched by array on drain edge)
  output logic [ACCW-1:0]    acc_out,
  output logic               acc_out_valid
);

  // ---- sanity ----
  initial if (ACCW < 2*W) $fatal(1, "ACCW must be >= 2*W");

  // ---- forward a/b + valids ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out       <= '0;
      b_out       <= '0;
      a_valid_out <= 1'b0;
      b_valid_out <= 1'b0;
    end else begin
      a_valid_out <= a_valid;
      b_valid_out <= b_valid;
	a_out <= a;  
	b_out <= b; 
    end
  end

  // ---- multiply (optional pipe) ----
  logic [2*W-1:0] prod_c, prod_q, prod_for_add;
  logic           prod_v_c, prod_v_q, prod_v_for_add;

  always_comb begin
    prod_c = SIGNED ? $signed(a) * $signed(b) : a * b;
  end
  assign prod_v_c = a_valid & b_valid;

  generate
    if (PIPE_MUL) begin : g_mulpipe
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          prod_q   <= '0;
          prod_v_q <= 1'b0;
        end else begin
          prod_q   <= prod_c;
          prod_v_q <= prod_v_c;
        end
      end
      assign prod_for_add   = prod_q;
      assign prod_v_for_add = prod_v_q;
    end else begin : g_nopipe
      assign prod_for_add   = prod_c;
      assign prod_v_for_add = prod_v_c;
    end
  endgenerate

  // ---- widen and accumulate ----
  logic [ACCW-1:0] prod_ext, acc_q;
  always_comb begin
    if (SIGNED)
      prod_ext = {{(ACCW-2*W){prod_for_add[2*W-1]}}, prod_for_add};
    else
      prod_ext = {{(ACCW-2*W){1'b0}},               prod_for_add};
  end

  logic draining;
  wire  do_mac = prod_v_for_add & !draining;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)            acc_q <= '0;
    else if (acc_clear_block) acc_q <= '0;
    else if (do_mac)       acc_q <= acc_q + prod_ext;
  end
  assign acc_out = acc_q;

  // ---- drain token: pass-through + edge detect for acc_out_valid ----
  logic drain_in_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      drain_out      <= 1'b0;
      acc_out_valid  <= 1'b0;
      drain_in_q     <= 1'b0;
      draining       <= 1'b0;
    end else begin
      drain_out      <= drain_in;
      acc_out_valid  <= drain_in & ~drain_in_q;  // 1-cycle pulse on rising edge
      drain_in_q     <= drain_in;

      if (drain_in)          draining <= 1'b1;   // freeze MAC until next block
      else if (acc_clear_block) draining <= 1'b0;
    end
  end

endmodule
