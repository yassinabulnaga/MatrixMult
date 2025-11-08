`timescale 1ns/1ps

module tb_dp_bram;

  // Parameters
  localparam int W     = 128;
  localparam int DEPTH = 1024;
  localparam int AW    = $clog2(DEPTH);

  // DUT signals
  logic                  clk;
  logic                  rst_n;
  logic                  a_en, a_we, b_en, b_we;
  logic [W/8-1:0]        a_be, b_be;
  logic [W-1:0]          a_din, b_din;
  logic [W-1:0]          a_dout, b_dout;
  logic [AW-1:0]         a_addr, b_addr;

  // Local vars
  int i;
  int baseW, baseR, len;
  int r, w;
  int mid;
  int edge_addr[0:2];
  int len3;

  // 100 MHz clock
  initial clk = 0;
  always #5 clk = ~clk;

  function automatic [W-1:0] patt(input int idx);
    patt = '0;
    // LSB = (idx + 1) & 1, like your 1'b(i+1) idea, but well-defined
    patt[0] = (idx + 1) & 1'b1;
  endfunction

  // Reset
  initial begin
    rst_n = 0;
    #20;
    rst_n = 1;
  end

  // DUT
  dp_bram #(
    .W(W),
    .DEPTH(DEPTH),
    .USE_BYTE_EN(1'b0),
    .RDW_MODE(2)
  ) DUT_BRAM (
    .clk   (clk),
    .rst_n (rst_n),

    // Port A
    .a_en   (a_en),
    .a_addr (a_addr),
    .a_din  (a_din),
    .a_we   (a_we),
    .a_be   (a_be),
    .a_dout (a_dout),

    // Port B
    .b_en   (b_en),
    .b_addr (b_addr),
    .b_din  (b_din),
    .b_we   (b_we),
    .b_be   (b_be),
    .b_dout (b_dout)
  );

  initial begin
    // Init
    a_en   = 0;      b_en   = 0;
    a_we   = 0;      b_we   = 0;
    a_addr = '0;     b_addr = '0;
    a_din  = '0;     b_din  = '0;
    a_be   = '1;     b_be   = '1;

    // Wait for reset deassert
    @(posedge rst_n);
    @(posedge clk);
    @(posedge clk);

    $display("=== Basic + Targeted DP-BRAM Tests ===");

    // [1] Single-port write -> read (latency)
    a_en   = 1;
    a_we   = 1;
    a_addr = 10'd5;
    a_din  = {4{32'hDEADBEEF}};  // 128-bit
    @(posedge clk);

    a_we = 0;
    @(posedge clk);
    @(posedge clk);
    @(posedge clk);
    if (a_dout !== {4{32'hDEADBEEF}})
      $fatal(0, "[FAIL][1] A readback mismatch: %h", a_dout);
    else
      $display("[PASS][1] A write->read (1-cycle) OK");

    // [2] Back-to-back writes on A, then reads on B - FIXED VERSION
    // Write data to addresses 0-63
    for (i = 0; i < 64; i++) begin
      a_en   = 1;
      a_we   = 1;
      a_addr = i;
      a_din  = {127'b0, (i+1)};  // Store pattern based on i+1's LSB
      @(posedge clk);
    end
    a_we = 0;
    a_en = 0;  // Disable port A

    // Now read back from port B with proper pipeline handling
    b_en   = 1;
    b_we   = 0;
    
    // Read from addresses 0-63 with 2-cycle pipeline
    for (i = 0; i < 64; i++) begin
      b_addr = i;
      @(posedge clk);  // First pipeline stage: b_q <= mem[i]
      @(posedge clk);  // Second pipeline stage: b_dout <= b_q
   @(posedge clk);
      
      // Check the output
      if (b_dout !== {127'b0, (i+1)}) begin
        $fatal(0, "[FAIL][2] B readback @%0d got %h exp %h", 
               i, b_dout, {127'b0, (i+1)});
      end
    end

    $display("[PASS][2] Back-to-back throughput OK (A writes, B reads)");

    // [3] Overlap: A writes new region while B reads old region
    baseW = 128;
    baseR = 0;
    len3  = 64;

    // First, initialize the "old region" (addresses 0-63) with known data
    a_en = 1;
    a_we = 1;
    for (i = 0; i < len3; i++) begin
      a_addr = baseR + i;
      a_din  = patt(baseR + i);
      @(posedge clk);
    end
    a_we = 0;
    a_en = 0;

    // Wait a few cycles to ensure writes are complete
    @(posedge clk);
    @(posedge clk);

    // Now do overlapped operations: A writes new region while B reads old region
    a_en = 1;
    b_en = 1;
    a_we = 1;
    b_we = 0;

    // Start the pipeline
    b_addr = baseR;        // Start reading from old region
    a_addr = baseW;        // Start writing to new region
    a_din  = patt(baseW);
    @(posedge clk);        // b_q <= mem[baseR]

    // Continue overlapped operations
    for (i = 0; i < len3; i++) begin
      // Set up next addresses (if not at end)
      if (i < len3 - 1) begin
        b_addr = baseR + i + 1;
        a_addr = baseW + i + 1;
        a_din  = patt(baseW + i + 1);
      end
      
      @(posedge clk);  // b_dout gets the value from 2 cycles ago
      
      // Check the read data (with 2-cycle delay)
      if (i >= 1) begin  // Skip first cycle as pipeline is filling
        if (b_dout !== patt(baseR + i - 1)) begin
          $fatal(0,
            "[FAIL][3] Overlap: B read mismatch @%0d got %h exp %h",
            baseR + i - 1, b_dout, patt(baseR + i - 1));
        end
      end
    end
    
    // Check the last value
    @(posedge clk);
    if (b_dout !== patt(baseR + len3 - 1)) begin
      $fatal(0,
        "[FAIL][3] Overlap: B read mismatch @%0d got %h exp %h",
        baseR + len3 - 1, b_dout, patt(baseR + len3 - 1));
    end

    a_we = 0;
    $display("[PASS][3] Overlap OK (A writes new region while B reads old)");

    // [4] Address edges: 0, mid, DEPTH-1
    mid = (DEPTH / 2) - 1;

    edge_addr[0] = 0;
    edge_addr[1] = mid;
    edge_addr[2] = DEPTH - 1;

    // Write edges on A
    a_en = 1;
    a_we = 1;
    for (i = 0; i < 3; i++) begin
      a_addr = edge_addr[i][AW-1:0];
      a_din  = {4{32'h11110000 | i}};
      @(posedge clk);
    end
    a_we = 0;

    // Read edges on B (respect 2-stage pipeline)
    b_en = 1;
    b_we = 0;

    for (i = 0; i < 3; i++) begin
      b_addr = edge_addr[i][AW-1:0];

      // 1st clk: b_q <= mem[addr]
      @(posedge clk);
      // 2nd clk: b_dout <= b_q (now mem[addr])
      @(posedge clk);
    @(posedge clk);


      if (b_dout !== {4{32'h11110000 | i}}) begin
        $fatal(0,
          "[FAIL][4] Edge readback @%0d got %h exp %h",
          edge_addr[i], b_dout, {4{32'h11110000 | i}});
      end
    end

    $display("[PASS][4] Edge addresses OK");

    // [5b] Cross-port: A writes, B reads
    // Write via A
    a_en   = 1;
    a_we   = 1;
    a_addr = 10'd301;
    a_din  = {4{32'h89ABCDEF}};
    @(posedge clk);      // write
    a_we = 0;

    // Read via B with pipelined latency
    b_en   = 1;
    b_we   = 0;
    b_addr = 10'd301;
    @(posedge clk);      // b_q <= mem[301]
    @(posedge clk);      // b_dout <= b_q
  @(posedge clk);

    if (b_dout !== {4{32'h89ABCDEF}}) begin
      $fatal(0,
        "[FAIL][5b] Cross-port write->read mismatch (A->B): got %h",
        b_dout);
    end else begin
      $display("[PASS][5b] Cross-port write->read OK");
    end

    $display("=== All targeted tests completed ===");
    $finish;

  end

endmodule
