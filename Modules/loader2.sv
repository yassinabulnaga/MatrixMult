module tile_loader #(
  parameter int W            = 8,
  parameter int BUSW         = 128,
  parameter int T            = 16,
  parameter int AW           = 10,
  parameter bit ADDR_IS_WORD = 1
)(
  input  logic                   clk,
  input  logic                   rst_n,

  // Control
  input  logic                   start,
  output logic                   busy,
  output logic                   done,

  // Tile config
  input  logic [31:0]            base_addr_bytes,
  input  logic [15:0]            tile_rows,
  input  logic [15:0]            tile_cols,
  input  logic [15:0]            tile_len_k,
  input  logic                   bankset_sel,
  input  logic                   col_major_mode, // 0=A-like, 1=B-like

  // Avalon-MM master
  output logic [31:0]            avm_address,
  output logic                   avm_read,
  input  logic [BUSW-1:0]        avm_readdata,
  input  logic                   avm_readdatavalid,
  input  logic                   avm_waitrequest,
  output logic [7:0]             avm_burstcount,

  // BRAM Port B (per bank)
  output logic [T-1:0]           b_en,
  output logic [T-1:0][AW-1:0]   b_addr,
  output logic [T-1:0][W-1:0]    b_din,
  output logic [T-1:0]           b_we
);

  localparam int BYTES_PER_BEAT = BUSW / 8;
  localparam int EPP            = BUSW / W;

  // Sanity check
  initial begin
    if (BUSW % W != 0)
      $fatal(1, "BUSW must be multiple of W");
  end

  // Total elements
  logic [31:0] elems_total;
  always_comb begin
    elems_total = (!col_major_mode)
                ? (tile_rows * tile_len_k)
                : (tile_cols * tile_len_k);
  end

  // Beats = ceil(elems_total / EPP)
  logic [31:0] beats_expected;
  always_comb begin
    beats_expected = (elems_total + EPP - 1) / EPP;
  end

  // FSM
  typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_FILL, S_DONE} st_t;
  st_t st, st_n;

  // State
  logic [31:0] beats_seen;
  logic [31:0] k_idx;
  logic [31:0] outer_idx;

  // Beat buffer + unpack
  logic [BUSW-1:0] beat_q;
  logic [7:0]      unpack_ptr;
  logic            have_beat;

  // Temps (no inline decls)
  int          base;
  logic [W-1:0] elem;
  logic [31:0]  row_i, col_i;
  int           bank;

  // Burstcount clamp
  assign avm_burstcount =
      (beats_expected == 0)   ? 8'd1   :
      (beats_expected > 255)  ? 8'd255 :
                                beats_expected[7:0];

  // Address alignment
  logic [31:0] addr_aligned;
  always_comb begin
    addr_aligned = {
      base_addr_bytes[31:$clog2(BYTES_PER_BEAT)],
      {($clog2(BYTES_PER_BEAT)){1'b0}}
    };
  end

  assign avm_address =
      (ADDR_IS_WORD)
        ? (addr_aligned >> $clog2(BYTES_PER_BEAT))
        :  addr_aligned;

  // Busy
  assign busy = (st != S_IDLE) && (st != S_DONE);

  // State reg
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      st <= S_IDLE;
    else
      st <= st_n;
  end

  // Main sequential
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      avm_read    <= 1'b0;
      beats_seen  <= '0;
      k_idx       <= '0;
      outer_idx   <= '0;
      have_beat   <= 1'b0;
      unpack_ptr  <= '0;
      beat_q      <= '0;
      done        <= 1'b0;

      b_en        <= '0;
      b_we        <= '0;
      b_addr      <= '0;
      b_din       <= '0;
    end
    else begin
      done   <= 1'b0;

      // Default BRAM outputs each cycle
      b_en   <= '0;
      b_we   <= '0;
      b_addr <= '0;
      b_din  <= '0;

      case (st)
 S_IDLE: begin
          avm_read <= 1'b0;
          if (start) begin
            $display("[%0t] LOADER: Starting load", $time);
            beats_seen <= 0;
            k_idx      <= 0;
            outer_idx  <= 0;
            have_beat  <= 0;
            unpack_ptr <= 0;
          end
        end

        S_ISSUE: begin
          avm_read <= 1'b1;
          if (!avm_waitrequest)
            $display("[%0t] LOADER: Request accepted", $time);
        end

        S_FILL: begin
          avm_read <= 1'b0;

          // Capture returning beat
          if (avm_readdatavalid) begin
            beat_q     <= avm_readdata;
            have_beat  <= 1'b1;
            unpack_ptr <= 0;
            beats_seen <= beats_seen + 1;
          end

          // Unpack one element per cycle
          if (have_beat) begin
            base = unpack_ptr * W;
            elem = beat_q[base +: W];  // variable part-select (SV style)

            // Map to row/col
            if (!col_major_mode) begin
              row_i = outer_idx;
              col_i = k_idx;
            end else begin
              row_i = k_idx;
              col_i = outer_idx;
            end

            // Bank select
            bank = (!col_major_mode) ? (row_i % T) : (col_i % T);

            if (bank >= 0 && bank < T) begin
              b_en  [bank] <= 1'b1;
              b_we  [bank] <= 1'b1;
              b_din [bank] <= elem;
              b_addr[bank] <= {bankset_sel, k_idx[AW-2:0]};
            end

            // Advance within beat
            unpack_ptr <= unpack_ptr + 1;
            if (unpack_ptr + 1 == EPP)
              have_beat <= 1'b0;

            // Advance k / outer
            if (k_idx + 1 == tile_len_k) begin
              k_idx     <= 0;
              outer_idx <= outer_idx + 1;
            end else begin
              k_idx <= k_idx + 1;
            end
          end

          // Done condition
  if ((outer_idx == ((!col_major_mode) ? tile_rows : tile_cols)) &&
              (k_idx == 0) &&
              (beats_seen == beats_expected) &&
              !have_beat) begin
            done <= 1'b1;
            $display("[%0t] LOADER: Done! beats_seen=%0d expected=%0d", $time, beats_seen, beats_expected);
          end
        end

        S_DONE: begin
          avm_read <= 1'b0;
        end
      endcase
    end
  end

  // Next-state
  always_comb begin
    st_n = st;
    unique case (st)
      S_IDLE:  if (start)            st_n = S_ISSUE;
      S_ISSUE: if (!avm_waitrequest) st_n = S_FILL;
      S_FILL:  if (done)             st_n = S_DONE;
      S_DONE:                        st_n = S_IDLE;
      default:                       st_n = S_IDLE;
    endcase
  end

endmodule
