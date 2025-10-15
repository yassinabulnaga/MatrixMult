module tile_loader #(

        parameter int W = 8,
        parameter int BUSW = 128,
        parameter int T = 16,
        parameter int AW =10,
        parameter bit ADDR_IS_WORD = 1
)(

        input logic clk,
        input logic rst_n,

//Control Configurations

input logic start, //Pulse to begin loading
output logic busy, //loader active
output logic done, //Tile Finished + Valid in Bram


input logic [31:0]          base_addr_bytes, // byte adder for tile
input  logic [15:0]         tile_rows,      // rows in this tile (<= T)
input  logic [15:0]         tile_cols,      // columns in this tile (<= T)
input  logic [15:0]         tile_len_k,     // K extent consumed by this tile (usually T)
input  logic                bankset_sel,    // 0/1: select BRAM half for double-buffering
input  logic                col_major_mode, // 0=A_loader, 1=B_loader

  // ---- Avalon-MM master (f2sdram) ----
  output logic [31:0]            avm_address,     // word or byte addr (see ADDR_IS_WORD)
  output logic                   avm_read,
  input  logic [BUSW-1:0]        avm_readdata,
  input  logic                   avm_readdatavalid,
  input  logic                   avm_waitrequest,
  output logic [7:0]             avm_burstcount,  // beats per burst (1..256 typical)

  // ---- BRAM Port-B (write) per bank ----
  output logic [T-1:0]           b_en,
  output logic [T-1:0][AW-1:0]   b_addr,
  output logic [T-1:0][W-1:0]    b_din,
  output logic [T-1:0]           b_we
);

 localparam int BYTES_PER_BEAT = BUSW/8; // checks bytes per beat
 localparam int EPP            = BUSW / W;    // elements per beat

   initial begin
    if (BUSW % W != 0) $fatal(1, "BUSW must be multiple of W"); // checks if integer number of elements
  end

    // How many elements are we fetching?
  logic [31:0] elems_total;
  always_comb begin
    elems_total = (!col_major_mode) ? (tile_rows * tile_len_k)   // A-like
                                    : (tile_cols * tile_len_k);  // B-like
  end

  // Beats = ceil(elems_total / EPP) EX: 31 Elements, EPP = 16, 45/16 = 2.81.. = 2 beats expected
  logic [31:0] beats_expected;
  always_comb begin
    beats_expected = (elems_total + EPP - 1) / EPP;
  end

// FSM
  typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_FILL, S_DONE} st_t;
  st_t st, st_n;

  // Counters / cursors
  logic [31:0] beats_seen;
  logic [31:0] k_idx;
  logic [31:0] outer_idx;     // row (A-like) or col (B-like)

  // Beat unpack
  logic [BUSW-1:0] beat_q;
  logic [7:0]      unpack_ptr;   // 0..EPP-1
  logic            have_beat;

  // Default BRAM outputs (To Prevent multi-bank writes)
  always_comb begin
    b_en   = '0;
    b_we   = '0;
    b_addr = '0;
    b_din  = '0;
  end


  // Avalon defaults: How many beats we will request
  assign avm_burstcount = (beats_expected == 0) ? 8'd1
                                                : (beats_expected > 255 ? 8'd255
                                                                        : beats_expected[7:0]);

  // Address alignment/format
  wire [31:0] addr_aligned = { base_addr_bytes[31:($clog2(BYTES_PER_BEAT))],  // zero last bits 
                               {($clog2(BYTES_PER_BEAT)){1'b0}} };
  assign avm_address = (ADDR_IS_WORD)
                      ? (addr_aligned >> $clog2(BYTES_PER_BEAT)) // If the bus counts in words, divide the byte address by the number of bytes per word.
                      :  addr_aligned;

  assign busy = (st != S_IDLE) && (st != S_DONE);

  // FSM regs
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) st <= S_IDLE; else st <= st_n;
  end

  // Control & counters
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      avm_read    <= 1'b0;
      beats_seen  <= '0;
      k_idx       <= '0;
      outer_idx   <= '0;
      have_beat   <= 1'b0;
      unpack_ptr  <= '0;
      done        <= 1'b0;
    end else begin
      done <= 1'b0;

      case (st)
        S_IDLE: begin
          if (start) begin
            beats_seen <= 0;
            k_idx      <= 0;
            outer_idx  <= 0;
            have_beat  <= 0;
            unpack_ptr <= 0;
          end
        end
       S_ISSUE: begin
          // Hold read high until accepted (waitrequest deasserts)
          if (!avm_waitrequest) begin
            avm_read <= 1'b1;
          end
        end
             S_FILL: begin
          // Accept returning beats
          if (avm_readdatavalid) begin
            beat_q     <= avm_readdata;
            have_beat  <= 1'b1;
            unpack_ptr <= 0;
            beats_seen <= beats_seen + 1;
          end

          // Unpack one element per cycle → write to bank
          if (have_beat) begin
            automatic int lo = unpack_ptr*W;
            automatic int hi = lo + W - 1;
            logic [W-1:0] elem = beat_q[hi:lo];

            // Choose row/col for this element
            logic [31:0] row_i, col_i;
            if (!col_major_mode) begin
              // A-like: (outer=row, inner=k)
              row_i = outer_idx;
              col_i = k_idx;
            end else begin
              // B-like: (outer=col, inner=k)
              row_i = k_idx;
              col_i = outer_idx;
            end

            int bank = (!col_major_mode) ? (row_i % T) : (col_i % T);
            b_en [bank] <= 1'b1;
            b_we [bank] <= 1'b1;
            b_din[bank] <= elem;
            b_addr[bank]<= {bankset_sel, k_idx[AW-2:0]};

            // Advance unpack pointer
            unpack_ptr <= unpack_ptr + 1;
            if (unpack_ptr + 1 == EPP) begin
              have_beat <= 1'b0; // consumed this beat
            end

            // Advance K then outer
            k_idx <= k_idx + 1;
            if (k_idx + 1 == tile_len_k) begin
              k_idx     <= 0;
              outer_idx <= outer_idx + 1;
            end
          end

          // End condition: all elems consumed and last beat seen/used
          if ((outer_idx == ((!col_major_mode) ? tile_rows : tile_cols)) &&
              (k_idx == 0) &&
              (beats_seen == beats_expected) &&
              !have_beat) begin
            done <= 1'b1;
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
      S_IDLE:  if (start)                     st_n = S_ISSUE;
      S_ISSUE: if (!avm_waitrequest)          st_n = S_FILL;
      S_FILL:  if (done)                      st_n = S_DONE;
      S_DONE:                                   st_n = S_IDLE;
      default:                                  st_n = S_IDLE;
    endcase
  end

endmodule