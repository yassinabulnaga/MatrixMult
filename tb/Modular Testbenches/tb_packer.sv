`timescale 1ns/1ps

module tb_packer;

  // Parameters
  localparam int W          = 16;
  localparam int BEAT_W     = 128;
  localparam bit LSB_FIRST  = 1;

  localparam int BYTES_PER_ELEM = W/8;
  localparam int BYTES_PER_BEAT = BEAT_W/8;
  localparam int ELS_PER_BEAT   = BEAT_W / W;

  // DUT I/O
  logic                     clk;
  logic                     rst_n;

  logic                     s_valid;
  logic                     s_ready;
  logic [W-1:0]             s_data;
  logic                     s_last;

  logic                     m_valid;
  logic                     m_ready;
  logic [BEAT_W-1:0]        m_data;
  logic [BYTES_PER_BEAT-1:0] m_strb;
  logic                     m_last;

  // Expected beat model
  typedef struct packed {
    logic [BEAT_W-1:0]         data;
    logic [BYTES_PER_BEAT-1:0] strb;
    logic                      last;
  } beat_t;

  beat_t exp_queue [0:2047];
  int    exp_head;
  int    exp_tail;

  // Reference accumulators
  logic [BEAT_W-1:0]          ref_data;
  logic [BYTES_PER_BEAT-1:0]  ref_strb;
  int                         ref_cnt;

  // =============== TASKS ===============

  // Push expected beat into queue
  task push_expected_beat(
    input logic [BEAT_W-1:0]         data,
    input logic [BYTES_PER_BEAT-1:0] strb,
    input logic                      last
  );
    begin
      if (exp_tail > 2047)
        $fatal(1, "Expected queue overflow");
      exp_queue[exp_tail].data = data;
      exp_queue[exp_tail].strb = strb;
      exp_queue[exp_tail].last = last;
      exp_tail = exp_tail + 1;
    end
  endtask

  // Reference model: consume 1 element (call only when s_valid && s_ready)
  task ref_accept_elem(
    input logic [W-1:0] elem,
    input logic         is_last
  );
    int slot;
    int bit_base;
    int byte_base;
    logic [BEAT_W-1:0]          next_data;
    logic [BYTES_PER_BEAT-1:0]  next_strb;
    int                         next_cnt;
    begin
      next_data = ref_data;
      next_strb = ref_strb;
      next_cnt  = ref_cnt;

      slot = next_cnt;

      // bit base
      if (LSB_FIRST)
        bit_base = slot * W;
      else
        bit_base = BEAT_W - (slot+1)*W;

      // place data
      next_data[bit_base +: W] = elem;

      // byte base
      if (LSB_FIRST)
        byte_base = slot * BYTES_PER_ELEM;
      else
        byte_base = BYTES_PER_BEAT - (slot+1)*BYTES_PER_ELEM;

      // set strb slice
      next_strb[byte_base +: BYTES_PER_ELEM] = {BYTES_PER_ELEM{1'b1}};

      // advance count
      next_cnt = next_cnt + 1;

      // full beat
      if (next_cnt == ELS_PER_BEAT) begin
        push_expected_beat(next_data, next_strb, is_last ? 1'b1 : 1'b0);
        next_data = '0;
        next_strb = '0;
        next_cnt  = 0;
      end
      else if (is_last) begin
        // partial final beat
        push_expected_beat(next_data, next_strb, 1'b1);
        next_data = '0;
        next_strb = '0;
        next_cnt  = 0;
      end

      ref_data = next_data;
      ref_strb = next_strb;
      ref_cnt  = next_cnt;
    end
  endtask

  // Drive one burst of num_elems elements
  task drive_burst(input int num_elems, input int seed);
    int i;
    logic [W-1:0] elem;
    bit accepted;
    begin
      for (i = 0; i < num_elems; i = i + 1) begin
        elem      = (W)'(seed + i);
        s_data    = elem;
        s_last    = (i == num_elems-1);
        s_valid   = 1'b1;
        accepted  = 0;

        // wait until accepted
        while (!accepted) begin
          @(posedge clk);
          if (s_valid && s_ready) begin
            ref_accept_elem(elem, s_last);
            accepted = 1;
          end
        end

        // drop valid after accept
        s_valid = 1'b0;
        s_last  = 1'b0;
        @(posedge clk);
      end
    end
  endtask

  // =============== DUT INSTANTIATION ===============

  packer #(
    .W         (W),
    .BEAT_W    (BEAT_W),
    .LSB_FIRST (LSB_FIRST)
  ) dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_valid (s_valid),
    .s_ready (s_ready),
    .s_data  (s_data),
    .s_last  (s_last),
    .m_valid (m_valid),
    .m_ready (m_ready),
    .m_data  (m_data),
    .m_strb  (m_strb),
    .m_last  (m_last)
  );

  // =============== PROCESSES ===============

  // Clock
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  // Random m_ready (with reset-safe init)
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
      m_ready <= 1'b0;
    else if ($urandom_range(0,3) == 0)
      m_ready <= 1'b0;
    else
      m_ready <= 1'b1;
  end

  // Scoreboard
  always @(posedge clk or negedge rst_n) begin
    beat_t exp_local;
    if (!rst_n) begin
      exp_head <= 0;
    end else begin
      if (m_valid && m_ready) begin
        if (exp_head == exp_tail) begin
          $fatal(1, "DUT produced extra beat (no expected entry)");
        end

        exp_local = exp_queue[exp_head];

        if (m_data !== exp_local.data) begin
          $display("EXP_DATA = %h", exp_local.data);
          $display("GOT_DATA = %h", m_data);
          $fatal(1, "Data mismatch at beat %0d", exp_head);
        end

        if (m_strb !== exp_local.strb) begin
          $display("EXP_STRB = %b", exp_local.strb);
          $display("GOT_STRB = %b", m_strb);
          $fatal(1, "STRB mismatch at beat %0d", exp_head);
        end

        if (m_last !== exp_local.last) begin
          $display("EXP_LAST = %b", exp_local.last);
          $display("GOT_LAST = %b", m_last);
          $fatal(1, "LAST mismatch at beat %0d", exp_head);
        end

        exp_head <= exp_head + 1;
      end
    end
  end

  // Main stimulus
  initial begin
    int t;
    int n;

    // init
    s_valid  = 1'b0;
    s_last   = 1'b0;
    s_data   = '0;
    ref_data = '0;
    ref_strb = '0;
    ref_cnt  = 0;
    exp_head = 0;
    exp_tail = 0;

    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);

    // 1) Exact full beat
    drive_burst(ELS_PER_BEAT, 32'h1000);

    // 2) Pure partial (3 elems)
    drive_burst(3, 32'h2000);

    // 3) Full + partial
    drive_burst(ELS_PER_BEAT + 5, 32'h3000);

    // 4) Random bursts
    for (t = 0; t < 10; t = t + 1) begin
      n = $urandom_range(1, 20);
      drive_burst(n, 32'h4000 + t*16);
    end

    // Let remaining beats drain
    repeat (100) @(posedge clk);

    if (exp_head != exp_tail) begin
      $display("Expected beats remaining: head=%0d tail=%0d", exp_head, exp_tail);
      $fatal(1, "Simulation ended with unmatched expected beats");
    end

    if (m_valid) begin
      $fatal(1, "DUT still asserting m_valid at end of sim");
    end

    $display("PACKER TB: ALL TESTS PASSED.");
    $finish;
  end

endmodule
