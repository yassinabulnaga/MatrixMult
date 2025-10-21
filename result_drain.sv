// result_drain.sv
// Drains a C tile from row-banked BRAMs (bank=row, addr={bankset_sel, col})
// One element per cycle with ready/valid; 1-cycle BRAM read latency.
// Emits `flush` on the final (possibly partial) beat boundary trigger for packer.
// Emits `done` when the last element is handed to the stream.
module result_drain #(
  parameter int W  = 8,     // element width
  parameter int T  = 16,    // number of banks (rows)
  parameter int AW = 10     // per-bank address width (must fit {bankset_sel, col})
)(
  input  logic                 clk,
  input  logic                 rst_n,

  // Control
  input  logic                 start,        // pulse to begin draining this tile
  output logic                 busy,
  output logic                 done,         // 1-cycle pulse when tile drained

  // Tile shape / selection
  input  logic [15:0]          tile_rows,    // <= T
  input  logic [15:0]          tile_cols,    // <= 2**(AW-1)
  input  logic                 bankset_sel,  // MSB of address

  // BRAM Port-A (READ) per bank (connect to C_banks Port-A)
  output logic [T-1:0]         a_en,
  output logic [T-1:0][AW-1:0] a_addr,
  input  logic [T-1:0][W-1:0]  a_dout,

  // Stream out (to elem FIFO)
  output logic                 out_valid,
  output logic [W-1:0]         out_data,
  input  logic                 out_ready,

  // Packer assist
  output logic                 flush         // 1-cycle pulse on last element
);

  typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_EMIT, S_DONE} st_t;
  st_t st, st_n;

logic [15:0] row_i, col_i; //indices

  // ── Pipeline registers to cover 1-cycle BRAM latency ─────────────────
  // We issue read for (row_i, col_i) in S_ISSUE or while advancing in S_EMIT.
  // Data returns next cycle and is presented on out_*.
  logic        rd_valid_q;
  logic [W-1:0]rd_data_q;
  logic [15:0] rd_row_q;   // the bank (row) we sampled last cycle (for a_dout index)

//defaults
  always_comb begin
    a_en   = '0;
    a_addr = '0;
  end

assign busy = (st != S_IDLE) && (st != S_DONE); // busy control signal

 always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) st <= S_IDLE; else st <= st_n;
  end

  //Control

    // ── Control & datapath ───────────────────────────────────────────────
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      row_i      <= '0;
      col_i      <= '0;
      rd_valid_q <= 1'b0;
      rd_data_q  <= '0;
      rd_row_q   <= '0;
      done       <= 1'b0;
      flush      <= 1'b0;
    end else begin
      done  <= 1'b0;
      flush <= 1'b0;
 unique case (st)
        // Initialize indices
        S_IDLE: begin
          rd_valid_q <= 1'b0;
          if (start) begin
            row_i <= 16'd0;
            col_i <= 16'd0;
          end
        end

                S_ISSUE: begin
          if (row_i < tile_rows && col_i < tile_cols) begin
            a_en  [row_i]   = 1'b1;
            a_addr[row_i]   = {bankset_sel, col_i[AW-2:0]};
            rd_valid_q      <= 1'b1;         // expect data next cycle
            rd_row_q        <= row_i;        // remember which bank we drove
          end else begin
            rd_valid_q <= 1'b0;              // empty tile guard
          end
        end

        // Data return + stream handshake + next read issuance
        S_EMIT: begin
          // Capture the returning data (from prior issued address)
          if (rd_valid_q) begin
            rd_data_q <= a_dout[rd_row_q];
          end

          // When downstream is ready (or no valid), advance indices and issue next read
          if (out_ready || !rd_valid_q) begin
            // Compute next row/col (row-major)
            logic [15:0] next_row = row_i;
            logic [15:0] next_col = col_i;

            if (rd_valid_q) begin
              // We just consumed one element; move to the next
              if (col_i + 1 == tile_cols) begin
                next_col = 16'd0;
                next_row = (row_i + 1);
              end else begin
                next_col = col_i + 1;
                next_row = row_i;
              end

              // Last-element detection: if we just consumed the last element
              if ((row_i == tile_rows-1) && (col_i == tile_cols-1)) begin
                // Tell packer to flush partial (if any) and mark completion
                flush      <= 1'b1;   // one-cycle pulse aligned with last send
                rd_valid_q <= 1'b0;   // no next read
              end else begin
                // Issue next read (if still within bounds)
                if (next_row < tile_rows && next_col < tile_cols) begin
                  a_en  [next_row] = 1'b1;
                  a_addr[next_row] = {bankset_sel, next_col[AW-2:0]};
                  rd_valid_q       <= 1'b1;
                  rd_row_q         <= next_row;
                end else begin
                  rd_valid_q <= 1'b0;
                end
              end

              // Commit new indices (only when we actually advanced)
              row_i <= next_row;
              col_i <= next_col;
            end
          end
        end

                S_DONE: begin
          done <= 1'b1;   // 1-cycle pulse after final element is accepted
        end
      endcase
    end
  end

  // Enter DONE once the last element has been accepted by downstream.
  always_comb begin
    st_n = st;
    unique case (st)
      S_IDLE:   if (start)                      st_n = S_ISSUE;
      S_ISSUE:                                  st_n = S_EMIT;  // data returns next cycle
      S_EMIT:   if ((row_i == tile_rows) ||
                    ((row_i == tile_rows-1) && (col_i == tile_cols-1) &&
                     rd_valid_q && out_ready)) st_n = S_DONE;
      S_DONE:                                   st_n = S_IDLE;
      default:                                  st_n = S_IDLE;
    endcase
  end

 // ── Stream outputs ───────────────────────────────────────────────────
  assign out_valid = rd_valid_q;
  assign out_data  = rd_data_q;

  // ── Synthesis-time sanity checks (optional) ──────────────────────────
  //pragma translate_off
  initial begin
    if (T < 1)  $fatal(1, "T must be >= 1");
    if (AW < 2) $fatal(1, "AW must be >= 2 (needs bankset_sel + col bits)");
  end
  //pragma translate_on

endmodule