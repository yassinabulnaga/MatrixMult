`timescale 1ns/1ps

module packer #(
    parameter int W         = 16,
    parameter int BEAT_W    = 128,
    parameter bit LSB_FIRST = 1
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // FIFO element stream
    input  logic                     s_valid,
    output logic                     s_ready,
    input  logic [W-1:0]             s_data,
    input  logic                     s_last,

    // Avalon downstream
    output logic                     m_valid,
    input  logic                     m_ready,
    output logic [BEAT_W-1:0]        m_data,
    output logic [BEAT_W/8-1:0]      m_strb,
    output logic                     m_last
);

  // Sim-time sanity checks
  initial begin
    if (W % 8 != 0)        $fatal(1, "packer: W must be a multiple of 8");
    if (BEAT_W % 8 != 0)   $fatal(1, "packer: BEAT_W must be a multiple of 8");
    if ((BEAT_W % W) != 0) $fatal(1, "packer: BEAT_W must be a multiple of W");
  end

  localparam int BYTES_PER_ELEM = W/8;
  localparam int BYTES_PER_BEAT = BEAT_W/8;
  localparam int ELS_PER_BEAT   = BEAT_W / W;

  // Accumulators
  logic [BEAT_W-1:0]               acc_data_q, acc_data_d;
  logic [BYTES_PER_BEAT-1:0]       acc_strb_q, acc_strb_d;
  logic [$clog2(ELS_PER_BEAT+1)-1:0] cnt_q, cnt_d;
  logic                            hold_full_q, hold_full_d;
  logic                            eot_seen_q, eot_seen_d;

  // State registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_data_q  <= '0;
      acc_strb_q  <= '0;
      cnt_q       <= '0;
      hold_full_q <= 1'b0;
      eot_seen_q  <= 1'b0;
    end else begin
      acc_data_q  <= acc_data_d;
      acc_strb_q  <= acc_strb_d;
      cnt_q       <= cnt_d;
      hold_full_q <= hold_full_d;
      eot_seen_q  <= eot_seen_d;
    end
  end

  // Combinational
  always_comb begin
    // locals (declared at top for ModelSim 2016)
    int slot;
    int bit_base;
    int byte_base;

    // defaults
    s_ready     = 1'b0;
    m_valid     = 1'b0;
    m_data      = acc_data_q;
    m_strb      = acc_strb_q;
    m_last      = 1'b0;

    acc_data_d  = acc_data_q;
    acc_strb_d  = acc_strb_q;
    cnt_d       = cnt_q;
    hold_full_d = hold_full_q;
    eot_seen_d  = eot_seen_q;

    // If holding a completed beat, present it
    if (hold_full_q) begin
      m_valid = 1'b1;
      m_data  = acc_data_q;
      m_strb  = acc_strb_q;
      m_last  = eot_seen_q;

      if (m_ready) begin
        hold_full_d = 1'b0;
        cnt_d       = '0;
        acc_data_d  = '0;
        acc_strb_d  = '0;
        eot_seen_d  = 1'b0;
      end

    end else begin
      // Free to accept upstream
      s_ready = 1'b1;

      // Accept an element
      if (s_valid && s_ready) begin
        slot = cnt_q;

        // Compute base bit index for this element
        if (LSB_FIRST) begin
          bit_base = slot * W;
        end else begin
          bit_base = BEAT_W - (slot+1)*W;
        end

        // Indexed part-select: width is constant W
        acc_data_d[bit_base +: W] = s_data;

        // Compute base byte index for this element
        if (LSB_FIRST) begin
          byte_base = slot * BYTES_PER_ELEM;
        end else begin
          byte_base = BYTES_PER_BEAT - (slot+1)*BYTES_PER_ELEM;
        end

        // Indexed part-select for byte enables
        acc_strb_d[byte_base +: BYTES_PER_ELEM] = {BYTES_PER_ELEM{1'b1}};

        // Advance count
        cnt_d = cnt_q + 1;

        // Full beat just completed
        if (cnt_d == ELS_PER_BEAT) begin
          hold_full_d = 1'b1;
          if (s_last)
            eot_seen_d = 1'b1;
        end else begin
          // Not full; record end-of-transfer if this was last element
          if (s_last)
            eot_seen_d = 1'b1;
        end
      end

      // Partial-beat flush when end-of-transfer seen
      if (!hold_full_q && eot_seen_q && (cnt_q > 0)) begin
        m_valid = 1'b1;
        m_data  = acc_data_q;
        m_strb  = acc_strb_q;
        m_last  = 1'b1;

        // Block new input while we’re flushing
        s_ready = 1'b0;

        if (m_ready) begin
          hold_full_d = 1'b0;
          cnt_d       = '0;
          acc_data_d  = '0;
          acc_strb_d  = '0;
          eot_seen_d  = 1'b0;
        end
      end
    end
  end

endmodule
