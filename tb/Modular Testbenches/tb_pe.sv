// ====================== mm_tb.sv ======================
// Testbench for PE array, PE module, and result_drain
// Module instantiations at module level (not in tasks) for ModelSim compatibility

`timescale 1ns/1ps

module mm_tb;

  import mm_pkg::*;

  // Clock and reset
  logic clk;
  logic rst_n;

  // Clock generation
  initial begin
    clk = 0;
    forever #5 clk = ~clk;  // 100MHz clock
  end

  // ============================================================
  // PE Module Test Signals
  // ============================================================
  logic [W-1:0] pe_a, pe_b, pe_a_out, pe_b_out;
  logic pe_a_valid, pe_b_valid, pe_a_valid_out, pe_b_valid_out;
  logic pe_acc_clear_block, pe_drain_in, pe_drain_out;
  logic [ACCW-1:0] pe_acc_out;
  logic pe_acc_out_valid;

  pe #(
    .W(W),
    .ACCW(ACCW),
    .SIGNED(SIGNED_M),
    .PIPE_MUL(PIPE_MUL)
  ) dut_pe (
    .clk(clk),
    .rst_n(rst_n),
    .a(pe_a),
    .b(pe_b),
    .a_valid(pe_a_valid),
    .b_valid(pe_b_valid),
    .a_out(pe_a_out),
    .b_out(pe_b_out),
    .a_valid_out(pe_a_valid_out),
    .b_valid_out(pe_b_valid_out),
    .acc_clear_block(pe_acc_clear_block),
    .drain_in(pe_drain_in),
    .drain_out(pe_drain_out),
    .acc_out(pe_acc_out),
    .acc_out_valid(pe_acc_out_valid)
  );

  // ============================================================
  // PE Array Test Signals
  // ============================================================
  logic [T-1:0][W-1:0] arr_a_in_row, arr_b_in_col;
  logic [T-1:0] arr_a_in_valid, arr_b_in_valid;
  logic arr_acc_clear_block, arr_drain_pulse;
  logic [T-1:0][T-1:0][ACCW-1:0] arr_acc_mat;
  logic [T-1:0][T-1:0] arr_acc_v_mat;

  pe_array #(
    .W(W),
    .ACCW(ACCW),
    .T(T),
    .SIGNED_M(SIGNED_M),
    .PIPE_MUL(PIPE_MUL)
  ) dut_array (
    .clk(clk),
    .rst_n(rst_n),
    .a_in_row(arr_a_in_row),
    .a_in_valid(arr_a_in_valid),
    .b_in_col(arr_b_in_col),
    .b_in_valid(arr_b_in_valid),
    .acc_clear_block(arr_acc_clear_block),
    .drain_pulse(arr_drain_pulse),
    .acc_mat(arr_acc_mat),
    .acc_v_mat(arr_acc_v_mat)
  );

  // ============================================================
  // Result Drain Test Signals
  // ============================================================
  parameter int RD_W = 32;
  parameter int RD_T = 4;
  parameter int RD_AW = 8;

  logic drain_start, drain_busy, drain_done;
  logic [15:0] drain_tile_rows, drain_tile_cols;
  logic drain_bankset_sel;
  logic [RD_T-1:0] drain_a_en;
  logic [RD_T-1:0][RD_AW-1:0] drain_a_addr;
  logic [RD_T-1:0][RD_W-1:0] drain_a_dout;
  logic drain_out_valid, drain_out_ready, drain_flush;
  logic [RD_W-1:0] drain_out_data;

  // Mock BRAM for result_drain
  logic [RD_T-1:0][127:0][RD_W-1:0] bram;
  int bram_i;

  result_drain #(
    .W(RD_W),
    .T(RD_T),
    .AW(RD_AW)
  ) dut_drain (
    .clk(clk),
    .rst_n(rst_n),
    .start(drain_start),
    .busy(drain_busy),
    .done(drain_done),
    .tile_rows(drain_tile_rows),
    .tile_cols(drain_tile_cols),
    .bankset_sel(drain_bankset_sel),
    .a_en(drain_a_en),
    .a_addr(drain_a_addr),
    .a_dout(drain_a_dout),
    .out_valid(drain_out_valid),
    .out_data(drain_out_data),
    .out_ready(drain_out_ready),
    .flush(drain_flush)
  );

  // Mock BRAM read behavior
  always_ff @(posedge clk) begin
    for (bram_i = 0; bram_i < RD_T; bram_i++) begin
      if (drain_a_en[bram_i])
        drain_a_dout[bram_i] <= bram[bram_i][drain_a_addr[bram_i][RD_AW-2:0]];
    end
  end

  // ============================================================
  // TEST 1: PE Module Tests
  // ============================================================
  task automatic test_pe_module();
    $display("\n=== Testing PE Module ===");

    // Initialize
    pe_a = 0; pe_b = 0;
    pe_a_valid = 0; pe_b_valid = 0;
    pe_acc_clear_block = 0;
    pe_drain_in = 0;

    @(posedge clk);
    
    // Test 1: Simple MAC operations
    $display("Test 1.1: MAC operations (2*3 + 4*5 = 26)");
    pe_acc_clear_block = 1;
    @(posedge clk);
    pe_acc_clear_block = 0;
    @(posedge clk);
    
    pe_a = 8'd2; pe_b = 8'd3;
    pe_a_valid = 1; pe_b_valid = 1;
    @(posedge clk);
    
    pe_a = 8'd4; pe_b = 8'd5;
    @(posedge clk);
    
    pe_a_valid = 0; pe_b_valid = 0;
    repeat(2) @(posedge clk);
    
    if (pe_acc_out == 32'd26)
      $display("  PASS: Accumulator = %0d", pe_acc_out);
    else
      $display("  FAIL: Expected 26, got %0d", pe_acc_out);

    // Test 2: Drain functionality
    $display("Test 1.2: Drain signal propagation");
    pe_drain_in = 1;
    @(posedge clk);
    @(posedge clk);  // Wait one more cycle for edge detection
    
    if (pe_drain_out)
      $display("  PASS: Drain signal propagated");
    else
      $display("  FAIL: Drain signal not propagated");
    
    pe_drain_in = 0;
    @(posedge clk);

    // Test 3: Data forwarding
    $display("Test 1.3: A/B forwarding");
    pe_a = 8'd10; pe_b = 8'd20;
    pe_a_valid = 1; pe_b_valid = 1;
    @(posedge clk);
    @(posedge clk);
    
    if (pe_a_out == 8'd10 && pe_b_out == 8'd20)
      $display("  PASS: Data forwarded correctly");
    else
      $display("  FAIL: Expected A=10, B=20, got A=%0d, B=%0d", pe_a_out, pe_b_out);

    pe_a_valid = 0; pe_b_valid = 0;
    repeat(3) @(posedge clk);

  endtask

  // ============================================================
  // TEST 2: PE Array Tests
  // ============================================================
  task automatic test_pe_array();
    int i, j;
    logic test_pass;

    $display("\n=== Testing PE Array ===");

    // Initialize
    arr_a_in_row = '0;
    arr_b_in_col = '0;
    arr_a_in_valid = '0;
    arr_b_in_valid = '0;
    arr_acc_clear_block = 0;
    arr_drain_pulse = 0;

    @(posedge clk);

    // Test 1: Small matrix multiplication
    // A = [1 2]  B = [5 6]  => C = [19 22]
    //     [3 4]      [7 8]         [43 50]
    $display("Test 2.1: 2x2 Matrix Multiplication");
    
    arr_acc_clear_block = 1;
    @(posedge clk);
    arr_acc_clear_block = 0;
    @(posedge clk);

    // Feed matrices in systolic fashion
    // Cycle 0: A[0,0]=1, B[0,0]=5
    arr_a_in_row[0] = 8'd1;
    arr_b_in_col[0] = 8'd5;
    arr_a_in_valid[0] = 1;
    arr_b_in_valid[0] = 1;
    @(posedge clk);

    // Cycle 1: A[0,1]=2, A[1,0]=3, B[0,1]=6, B[1,0]=7
    arr_a_in_row[0] = 8'd2;
    arr_a_in_row[1] = 8'd3;
    arr_b_in_col[0] = 8'd7;
    arr_b_in_col[1] = 8'd6;
    arr_a_in_valid[1] = 1;
    arr_b_in_valid[1] = 1;
    @(posedge clk);

    // Cycle 2: A[1,1]=4, B[1,1]=8
    arr_a_in_row[0] = 8'd0;
    arr_a_in_row[1] = 8'd4;
    arr_b_in_col[0] = 8'd0;
    arr_b_in_col[1] = 8'd8;
    arr_a_in_valid[0] = 0;
    arr_b_in_valid[0] = 0;
    @(posedge clk);

    // Stop feeding
    arr_a_in_valid = '0;
    arr_b_in_valid = '0;
    
    // Wait for accumulation
    repeat(10) @(posedge clk);

    // Drain results
    $display("  Draining results...");
    arr_drain_pulse = 1;
    @(posedge clk);
    arr_drain_pulse = 0;
    
    // Wait for drain to propagate through array
    repeat(T*T + 5) @(posedge clk);

    // Check results
    $display("  Result Matrix:");
    for (i = 0; i < 2; i++) begin
      for (j = 0; j < 2; j++) begin
        if (arr_acc_v_mat[i][j])
          $display("    C[%0d][%0d] = %0d (valid)", i, j, arr_acc_mat[i][j]);
        else
          $display("    C[%0d][%0d] = invalid", i, j);
      end
    end

    // Verify expected values
    test_pass = 1;
    if (arr_acc_mat[0][0] != 32'd19) begin
      $display("  FAIL: C[0][0] expected 19, got %0d", arr_acc_mat[0][0]);
      test_pass = 0;
    end
    if (arr_acc_mat[0][1] != 32'd22) begin
      $display("  FAIL: C[0][1] expected 22, got %0d", arr_acc_mat[0][1]);
      test_pass = 0;
    end
    if (arr_acc_mat[1][0] != 32'd43) begin
      $display("  FAIL: C[1][0] expected 43, got %0d", arr_acc_mat[1][0]);
      test_pass = 0;
    end
    if (arr_acc_mat[1][1] != 32'd50) begin
      $display("  FAIL: C[1][1] expected 50, got %0d", arr_acc_mat[1][1]);
      test_pass = 0;
    end
    
    if (test_pass)
      $display("  PASS: Matrix multiplication correct");

    repeat(5) @(posedge clk);

  endtask

  // ============================================================
  // TEST 3: Result Drain Tests
  // ============================================================
  task automatic test_result_drain();
    int count, expected_count, cycle;
    int i, j;

    $display("\n=== Testing Result Drain ===");

    // Initialize
    drain_start = 0;
    drain_tile_rows = 0;
    drain_tile_cols = 0;
    drain_bankset_sel = 0;
    drain_out_ready = 1;  // Always ready

    @(posedge clk);

    // Test 1: Drain 2x3 tile
    $display("Test 3.1: Drain 2x3 tile");
    drain_tile_rows = 16'd2;
    drain_tile_cols = 16'd3;
    drain_bankset_sel = 0;
    
    drain_start = 1;
    @(posedge clk);
    drain_start = 0;

    // Collect outputs
    count = 0;
    expected_count = 6;  // 2 rows * 3 cols
    
    while (!drain_done && count < 20) begin
      @(posedge clk);
      if (drain_out_valid && drain_out_ready) begin
        $display("  Output[%0d] = %0d", count, drain_out_data);
        count++;
      end
    end

    // Wait for done signal
    while (!drain_done && count < 25) begin
      @(posedge clk);
    end
    
    if (count == expected_count)
      $display("  PASS: Drained %0d elements", count);
    else
      $display("  FAIL: Expected %0d elements, got %0d", expected_count, count);

    if (drain_done)
      $display("  PASS: Done signal asserted");
    else
      $display("  FAIL: Done signal not asserted");

    repeat(3) @(posedge clk);

    // Test 2: Full 4x4 tile
    $display("Test 3.2: Drain 4x4 tile");
    drain_tile_rows = 16'd4;
    drain_tile_cols = 16'd4;
    
    drain_start = 1;
    @(posedge clk);
    drain_start = 0;

    count = 0;
    expected_count = 16;
    
    while (!drain_done && count < 30) begin
      @(posedge clk);
      if (drain_out_valid) begin
        count++;
      end
    end

    @(posedge clk);
    
    if (count == expected_count)
      $display("  PASS: Drained %0d elements", count);
    else
      $display("  FAIL: Expected %0d elements, got %0d", expected_count, count);

    repeat(3) @(posedge clk);

    // Test 3: Backpressure handling
    $display("Test 3.3: Backpressure (out_ready toggling)");
    drain_tile_rows = 16'd2;
    drain_tile_cols = 16'd2;
    
    drain_start = 1;
    @(posedge clk);
    drain_start = 0;

    count = 0;
    expected_count = 4;
    cycle = 0;
    
    while (!drain_done && cycle < 30) begin
      drain_out_ready = (cycle % 3 != 0);  // Ready 2 out of 3 cycles
      @(posedge clk);
      if (drain_out_valid && drain_out_ready) begin
        count++;
      end
      cycle++;
    end

    drain_out_ready = 1;
    @(posedge clk);
    
    if (count == expected_count)
      $display("  PASS: Handled backpressure, drained %0d elements", count);
    else
      $display("  FAIL: Expected %0d elements, got %0d", expected_count, count);

    repeat(3) @(posedge clk);

  endtask

  // ============================================================
  // Main Test Execution
  // ============================================================
  initial begin
    int i, j;
    
    // Initialize BRAM with test pattern (before reset)
    for (i = 0; i < RD_T; i++) begin
      for (j = 0; j < 128; j++) begin
        bram[i][j] = (i * 1000) + j;
      end
    end
    
    $display("========================================");
    $display("Matrix Multiplication Testbench");
    $display("========================================");

    // Reset sequence
    rst_n = 0;
    repeat(3) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    // Run tests
    test_pe_module();
    test_pe_array();
    test_result_drain();

    $display("\n========================================");
    $display("All Tests Complete");
    $display("========================================\n");

    repeat(10) @(posedge clk);
    $finish;
  end

  // Timeout watchdog
  initial begin
    #100000;  // 100us timeout
    $display("\nERROR: Testbench timeout!");
    $finish;
  end

  // Waveform dumping (optional)
  initial begin
    $dumpfile("mm_tb.vcd");
    $dumpvars(0, mm_tb);
  end

endmodule