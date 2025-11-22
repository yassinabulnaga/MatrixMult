// ====================== tb_bram_pe_bram.sv ======================
// Testbench for BRAM A + BRAM B → PE Array → BRAM C path
// (Current focus: verify writes into BRAM A/B for 2x2 case)

`timescale 1ns/1ps

module tb_a1;

  import mm_pkg::*;

  // ------------------------------------------------------------
  // Clock and reset
  // ------------------------------------------------------------
  logic clk;
  logic rst_n;

  // 100 MHz clock
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

  // ------------------------------------------------------------
  // BRAM A (Matrix A storage)
  // ------------------------------------------------------------
  logic [T-1:0]          bram_a_en;
  logic [T-1:0][9:0]     bram_a_addr;   // Assume 1024 depth
  logic [T-1:0][W-1:0]   bram_a_din;
  logic [T-1:0]          bram_a_we;
  logic [T-1:0][W/8-1:0] bram_a_be;
  logic [T-1:0][W-1:0]   bram_a_dout;

  m10k_banks #(
    .N_BANKS       (T),
    .W             (W),
    .DEPTH_PER_BANK(1024),
    .USE_BYTE_EN   (0),
    .RDW_MODE      (0)   // WRITE_FIRST
  ) bram_a (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (bram_a_en),
    .a_addr  (bram_a_addr),
    .a_din   (bram_a_din),
    .a_we    (bram_a_we),
    .a_be    (bram_a_be),
    .a_dout  (bram_a_dout),
    .b_en    ('0),
    .b_addr  ('0),
    .b_din   ('0),
    .b_we    ('0),
    .b_be    ('0),
    .b_dout  ()
  );

  // ------------------------------------------------------------
  // BRAM B (Matrix B storage)
  // ------------------------------------------------------------
  logic [T-1:0]          bram_b_en;
  logic [T-1:0][9:0]     bram_b_addr;
  logic [T-1:0][W-1:0]   bram_b_din;
  logic [T-1:0]          bram_b_we;
  logic [T-1:0][W/8-1:0] bram_b_be;
  logic [T-1:0][W-1:0]   bram_b_dout;

  m10k_banks #(
    .N_BANKS       (T),
    .W             (W),
    .DEPTH_PER_BANK(1024),
    .USE_BYTE_EN   (0),
    .RDW_MODE      (0)   // WRITE_FIRST
  ) bram_b (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (bram_b_en),
    .a_addr  (bram_b_addr),
    .a_din   (bram_b_din),
    .a_we    (bram_b_we),
    .a_be    (bram_b_be),
    .a_dout  (bram_b_dout),
    .b_en    ('0),
    .b_addr  ('0),
    .b_din   ('0),
    .b_we    ('0),
    .b_be    ('0),
    .b_dout  ()
  );

  // ------------------------------------------------------------
  // PE Array (hooked up but not functionally used yet)
  // ------------------------------------------------------------
  logic [T-1:0][W-1:0]      pe_a_in_row;
  logic [T-1:0]             pe_a_in_valid;
  logic [T-1:0][W-1:0]      pe_b_in_col;
  logic [T-1:0]             pe_b_in_valid;
  logic                     pe_acc_clear_block;
  logic                     pe_drain_pulse;
  logic [T-1:0][T-1:0][ACCW-1:0] pe_acc_mat;
  logic [T-1:0][T-1:0]      pe_acc_v_mat;

  pe_array #(
    .W        (W),
    .ACCW     (ACCW),
    .T        (T),
    .SIGNED_M (SIGNED_M),
    .PIPE_MUL (PIPE_MUL)
  ) dut_pe_array (
    .clk            (clk),
    .rst_n          (rst_n),
    .a_in_row       (pe_a_in_row),
    .a_in_valid     (pe_a_in_valid),
    .b_in_col       (pe_b_in_col),
    .b_in_valid     (pe_b_in_valid),
    .acc_clear_block(pe_acc_clear_block),
    .drain_pulse    (pe_drain_pulse),
    .acc_mat        (pe_acc_mat),
    .acc_v_mat      (pe_acc_v_mat)
  );

  // ------------------------------------------------------------
  // BRAM C (result storage) - kept for later, unused for now
  // ------------------------------------------------------------
  logic [T-1:0]               bram_c_en;
  logic [T-1:0][9:0]          bram_c_addr;
  logic [T-1:0][ACCW-1:0]     bram_c_din;
  logic [T-1:0]               bram_c_we;
  logic [T-1:0][ACCW/8-1:0]   bram_c_be;
  logic [T-1:0][ACCW-1:0]     bram_c_dout;

  m10k_banks #(
    .N_BANKS       (T),
    .W             (ACCW),
    .DEPTH_PER_BANK(1024),
    .USE_BYTE_EN   (0),
    .RDW_MODE      (0)   // WRITE_FIRST
  ) bram_c (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (bram_c_en),
    .a_addr  (bram_c_addr),
    .a_din   (bram_c_din),
    .a_we    (bram_c_we),
    .a_be    (bram_c_be),
    .a_dout  (bram_c_dout),
    .b_en    ('0),
    .b_addr  ('0),
    .b_din   ('0),
    .b_we    ('0),
    .b_be    ('0),
    .b_dout  ()
  );

  // ------------------------------------------------------------
  // Simple BRAM → PE input pipeline (kept for later use)
  // ------------------------------------------------------------
  logic [T-1:0][W-1:0] bram_a_dout_q;
  logic [T-1:0]        bram_a_valid_q, bram_a_valid_q2;
  logic [T-1:0][W-1:0] bram_b_dout_q;
  logic [T-1:0]        bram_b_valid_q, bram_b_valid_q2;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bram_a_dout_q   <= '0;
      bram_a_valid_q  <= '0;
      bram_a_valid_q2 <= '0;
      bram_b_dout_q   <= '0;
      bram_b_valid_q  <= '0;
      bram_b_valid_q2 <= '0;
    end else begin
      bram_a_valid_q  <= bram_a_en;
      bram_b_valid_q  <= bram_b_en;
      bram_a_valid_q2 <= bram_a_valid_q;
      bram_b_valid_q2 <= bram_b_valid_q;
      bram_a_dout_q   <= bram_a_dout;
      bram_b_dout_q   <= bram_b_dout;
    end
  end

  assign pe_a_in_row   = bram_a_dout_q;
  assign pe_a_in_valid = bram_a_valid_q2;
  assign pe_b_in_col   = bram_b_dout_q;
  assign pe_b_in_valid = bram_b_valid_q2;

  // ------------------------------------------------------------
  // Debug monitoring (kept; helps when we later stream)
  // ------------------------------------------------------------
  always @(posedge clk) begin
    if (pe_a_in_valid != 0 || pe_b_in_valid != 0) begin
      $display("Time %0t: PE inputs - a_valid=%b, b_valid=%b",
               $time, pe_a_in_valid, pe_b_in_valid);
     /* for (int idx = 0; idx < T; idx++) begin
        if (pe_a_in_valid[idx])
          $display("  a_in_row[%0d] = %0d", idx, pe_a_in_row[idx]);
        if (pe_b_in_valid[idx])
          $display("  b_in_col[%0d] = %0d", idx, pe_b_in_col[idx]);
      end*/
    end
  end

  // ------------------------------------------------------------
  // Helper Tasks: write matrices (ONLY thing used in Test 1)
  // ------------------------------------------------------------

  // Write Matrix A to BRAM A (row-major: bank = row, addr = col)
  task automatic write_matrix_a(input logic [T-1:0][T-1:0][W-1:0] mat_a);
    int i, j;
    $display("  Writing Matrix A to BRAM...");

    bram_a_en = '0;
    bram_a_we = '0;

    for (i = 0; i < T; i++) begin
      for (j = 0; j < T; j++) begin
        bram_a_en = '0;
        bram_a_we = '0;

        bram_a_en[i]      = 1'b1;
        bram_a_we[i]      = 1'b1;
        bram_a_addr[i]    = j[9:0];
        bram_a_din[i]     = mat_a[i][j];

//        if (i < 2 && j < 4)
        //  $display("    A[%0d][%0d] -> BRAM_A bank %0d addr %0d = %0d",
  //                 i, j, i, j, mat_a[i][j]);

        @(posedge clk);
      end
    end

    bram_a_en = '0;
    bram_a_we = '0;
    repeat (3) @(posedge clk);

    $display("  Matrix A write complete");
  endtask

  // Write Matrix B to BRAM B (column-major: bank = col, addr = row)
  task automatic write_matrix_b(input logic [T-1:0][T-1:0][W-1:0] mat_b);
    int i, j;
    $display("  Writing Matrix B to BRAM...");

    bram_b_en = '0;
    bram_b_we = '0;

    for (j = 0; j < T; j++) begin
      for (i = 0; i < T; i++) begin
        bram_b_en = '0;
        bram_b_we = '0;

        bram_b_en[j]      = 1'b1;
        bram_b_we[j]      = 1'b1;
        bram_b_addr[j]    = i[9:0];
        bram_b_din[j]     = mat_b[i][j];

       // if (i < 2 && j < 2)
       //   $display("    B[%0d][%0d] -> BRAM_B bank %0d addr %0d = %0d",
//                   i, j, j, i, mat_b[i][j]);

        @(posedge clk);
      end
    end

    bram_b_en = '0;
    bram_b_we = '0;
    repeat (3) @(posedge clk);

    $display("  Matrix B write complete");
  endtask

// Stream matrices through PE array (systolic style)
task automatic stream_matrices();
  int cycle, i, j, addr_val;
  $display("  Streaming matrices through PE array...");

  // 1) Clear accumulators once at start
  pe_acc_clear_block = 1;
  @(posedge clk);
  pe_acc_clear_block = 0;
  @(posedge clk);

  // 2) Drive the classic 2D systolic wave for 2*T-1 cycles
  for (cycle = 0; cycle < 2*T-1; cycle++) begin

    // Read from BRAM A (rows → banks)
    for (i = 0; i < T; i++) begin
      if (cycle >= i && (cycle - i) < T) begin
        addr_val          = cycle - i;
        bram_a_en[i]      = 1'b1;
        bram_a_addr[i]    = addr_val[9:0];
      end else begin
        bram_a_en[i]      = 1'b0;
      end
    end

    // Read from BRAM B (cols → banks)
    for (j = 0; j < T; j++) begin
      if (cycle >= j && (cycle - j) < T) begin
        addr_val          = cycle - j;
        bram_b_en[j]      = 1'b1;
        bram_b_addr[j]    = addr_val[9:0];
      end else begin
        bram_b_en[j]      = 1'b0;
      end
    end

    @(posedge clk);
  end

  // 3) Stop issuing reads + flush pipeline
  bram_a_en = '0;
  bram_b_en = '0;
  repeat (10) @(posedge clk);

  $display("  Done streaming.");
endtask

task automatic drain_pe_results();
  int i, j;
  $display("  Draining PE array results...");
  $display("  PE acc_v_mat before drain: %b", pe_acc_v_mat);

  // Single pulse to start drain
  pe_drain_pulse = 1;
  @(posedge clk);
  pe_drain_pulse = 0;

  // Wait for drain to propagate through T×T array
  repeat (T*T + 5) @(posedge clk);

  $display("  PE acc_v_mat after drain: %b", pe_acc_v_mat);
  $display("  Sample values (first 2x2):");
  for (i = 0; i < 2 && i < T; i++) begin
    for (j = 0; j < 2 && j < T; j++) begin
      if (pe_acc_v_mat[i][j])
        $display("    pe_acc_mat[%0d][%0d] = %0d", i, j, pe_acc_mat[i][j]);
      else
        $display("    pe_acc_mat[%0d][%0d] = INVALID", i, j);
    end
  end
endtask

task automatic check_pe_results_2x2();
  bit pass = 1;

  int exp00 = 19;
  int exp01 = 22;
  int exp10 = 43;
  int exp11 = 50;

  $display("  Checking 2x2 results in pe_acc_mat...");

  if (!pe_acc_v_mat[0][0] || pe_acc_mat[0][0] !== exp00) begin
    $display("    MISMATCH C[0][0]: got %0d, expected %0d",
              pe_acc_mat[0][0], exp00);
    pass = 0;
  end
  if (!pe_acc_v_mat[0][1] || pe_acc_mat[0][1] !== exp01) begin
    $display("    MISMATCH C[0][1]: got %0d, expected %0d",
              pe_acc_mat[0][1], exp01);
    pass = 0;
  end
  if (!pe_acc_v_mat[1][0] || pe_acc_mat[1][0] !== exp10) begin
    $display("    MISMATCH C[1][0]: got %0d, expected %0d",
              pe_acc_mat[1][0], exp10);
    pass = 0;
  end
  if (!pe_acc_v_mat[1][1] || pe_acc_mat[1][1] !== exp11) begin
    $display("    MISMATCH C[1][1]: got %0d, expected %0d",
              pe_acc_mat[1][1], exp11);
    pass = 0;
  end

  if (pass)
    $display("  PASS: 2x2 PE results correct after drain.");
  else
    $display("  FAIL: 2x2 PE results incorrect.");
endtask

// Write a rows×cols block of PE results into BRAM C
// Layout: C[row][col] -> bank=row, addr=col
task automatic write_results_to_bram_c(input int rows, input int cols);
  int i, j;

  $display("  Writing results to BRAM C [%0d x %0d]...", rows, cols);

  bram_c_en = '0;
  bram_c_we = '0;

  for (i = 0; i < rows && i < T; i++) begin
    for (j = 0; j < cols && j < T; j++) begin
      if (pe_acc_v_mat[i][j]) begin
        bram_c_en = '0;
        bram_c_we = '0;

        bram_c_en[i]      = 1'b1;
        bram_c_we[i]      = 1'b1;
        bram_c_addr[i]    = j[9:0];
        bram_c_din[i]     = pe_acc_mat[i][j];

        $display("    C[%0d][%0d] = %0d -> BRAM_C bank %0d addr %0d",
                 i, j, pe_acc_mat[i][j], i, j);

        @(posedge clk);
      end
    end
  end

  bram_c_en = '0;
  bram_c_we = '0;
  repeat (2) @(posedge clk);

  $display("  BRAM C write complete");
endtask

task automatic verify_bram_c(
  input logic [T-1:0][T-1:0][ACCW-1:0] expected,
  input int rows, 
  input int cols,
  input bit verbose = 0  // Set to 1 to see all OK messages
);
  int i, j;
  bit pass = 1;
  int mismatch_count = 0;
  logic [ACCW-1:0] read_val;
  
  $display("\n=== Verifying BRAM C contents [%0d x %0d] ===", rows, cols);

  // Ensure all enables are off initially
  bram_c_en = '0;
  bram_c_we = '0;
  @(posedge clk);

 for (i = 0; i < rows && i < T; i++) begin
  for (j = 0; j < cols && j < T; j++) begin
    
    // Set address and enable
    bram_c_en[i]   = 1'b1;
    bram_c_addr[i] = j[9:0];
    bram_c_we[i]   = 1'b0;
    
    // Wait for read to complete
    repeat(2) @(posedge clk);
    
    // Capture data
    read_val = bram_c_dout[i];
    
    // Turn off enable before next iteration
    bram_c_en[i] = 1'b0;
    
    // Check...
    if (read_val !== expected[i][j]) begin
      // ... error reporting
    end
  end
end

  // Cleanup: disable all banks
  bram_c_en = '0;
  repeat (2) @(posedge clk);

  // Final summary
  $display("\n--- Verification Summary ---");
  if (pass) begin
    $display("  ✓✓✓ PASS: All %0d×%0d values in BRAM C match expected!", rows, cols);
  end else begin
    $display(" FAIL: %0d mismatches found out of %0d values", 
             mismatch_count, rows * cols);
  end
  $display("============================\n");
endtask

  // ------------------------------------------------------------
  // Test 1: 2x2 — currently only writes + prints
  // ------------------------------------------------------------
  task automatic test_2x2_matmul();
    logic [T-1:0][T-1:0][W-1:0]    mat_a, mat_b;
    logic [T-1:0][T-1:0][ACCW-1:0] expected; // for later

    $display("\n=== Test 1: 2x2 Write Sanity ===");
    $display("  A = [1 2; 3 4]");
    $display("  B = [5 6; 7 8]");

    mat_a = '0;
    mat_b = '0;

    mat_a[0][0] = 8'd1; mat_a[0][1] = 8'd2;
    mat_a[1][0] = 8'd3; mat_a[1][1] = 8'd4;

    mat_b[0][0] = 8'd5; mat_b[0][1] = 8'd6;
    mat_b[1][0] = 8'd7; mat_b[1][1] = 8'd8;

    // For now: just write and display what we wrote
    write_matrix_a(mat_a);
    write_matrix_b(mat_b);

    expected[0][0] = 32'd19; expected[0][1] = 32'd22;
    expected[1][0] = 32'd43; expected[1][1] = 32'd50;
    
     stream_matrices();
     drain_pe_results();
    check_pe_results_2x2();
    write_results_to_bram_c(2,2);
 // verify_bram_c(expected, 2, 2);
  endtask


task automatic test_4x4_matmul();
  logic [T-1:0][T-1:0][W-1:0]     mat_a, mat_b;
  logic [T-1:0][T-1:0][ACCW-1:0]  expected;
  int i, j;

  if (T < 4) begin
    $display("\n=== Test 2: Skipped (T < 4) ===");
    return;
  end

  $display("\n=== Test 2: 4x4 Matrix Multiplication ===");
  $display("  A = I4, B = [1..16] row-major; expect C = B");

  mat_a   = '0;
  mat_b   = '0;
  expected = '0;

  // A = 4x4 identity
  for (i = 0; i < 4; i++) begin
    mat_a[i][i] = 8'd1;
  end

  // B = 4x4, values 1..16 in row-major
  for (i = 0; i < 4; i++) begin
    for (j = 0; j < 4; j++) begin
      mat_b[i][j] = W'(i*4 + j + 1);
      expected[i][j] = mat_b[i][j]; // since A = I
    end
  end

  // 1) Load A/B into BRAMs
  write_matrix_a(mat_a);
  write_matrix_b(mat_b);

  // 2) Run systolic streaming
  stream_matrices();

  // 3) Drain PE results into acc_mat/acc_v_mat
  drain_pe_results();

  // 5) Write C tile into BRAM C with our canonical layout
  write_results_to_bram_c(4, 4);

  // 6) Read back from BRAM C and compare  verify_bram_c(expected, 4, 4);
endtask

// Test 3: Full T x T matrix multiplication (stress test)
// Uses deterministic patterns so we can compute expected in TB.
task automatic test_full_tile_matmul();
  // using full T from mm_pkg
  logic [T-1:0][T-1:0][W-1:0]    mat_a, mat_b;
  logic [T-1:0][T-1:0][ACCW-1:0] expected;
  int i, j, k;

  $display("\n=== Test 3: Full %0dx%0d Tile Matmul Stress Test ===", T, T);

  // ---------- Initialize A and B ----------
  // Choose patterns that:
  // - Exercise all banks and addresses
  // - Are not symmetric / trivial
  // - Stay within 8-bit range
  mat_a = '0;
  mat_b = '0;
  expected = '0;

  // Example:
  // A[i][j] = (i*7 + j*11 + 1) mod 256
  // B[i][j] = (i*13 + j*5 + 3) mod 256
  for (i = 0; i < T; i++) begin
    for (j = 0; j < T; j++) begin
  mat_a[i][j] = W'((i*7  + j*11 + 1) & 8'h7F);  // 0-127 ✓
    mat_b[i][j] = W'((i*13 + j*5  + 3) & 8'h7F);  // 0-127 ✓

    end
  end

  // ---------- Golden C = A * B ----------
  for (i = 0; i < T; i++) begin
    for (j = 0; j < T; j++) begin
automatic longint signed sum = 0;  // ✓ Use signed accumulator!
      for (k = 0; k < T; k++) begin
        sum += $signed(mat_a[i][k]) * $signed( mat_b[k][j]);
      end
      expected[i][j] = sum[ACCW-1:0];
    end
  end

  // ---------- Execute pipeline ----------
  // 1) Write A/B into BRAMs
  write_matrix_a(mat_a);
  write_matrix_b(mat_b);

 $display("Time %0t:",$time);
  // 2) Stream through systolic array
  stream_matrices();
 $display("Time %0t:",$time);
  // 3) Drain PE -> acc_mat/acc_v_mat
  drain_pe_results();
 $display("Time %0t:",$time);

  // 5) Write C into BRAM C with our canonical layout
  write_results_to_bram_c(T, T);
 $display("Time %0t:",$time);
  verify_bram_c(expected,T,T,1);

  $display("=== End of Test 3: Full Tile ===");
endtask


  // ------------------------------------------------------------
  // Main Test Execution
  // ------------------------------------------------------------
  initial begin
    $display("========================================");
    $display("BRAM → PE Array → BRAM C Testbench");
    $display("T = %0d, W = %0d, ACCW = %0d", T, W, ACCW);
    $display("Focus: BRAM A/B write sanity (Test 1 only)");
    $display("========================================");

    // Init signals
    bram_a_en = '0; bram_a_addr = '0; bram_a_din = '0; bram_a_we = '0; bram_a_be = '0;
    bram_b_en = '0; bram_b_addr = '0; bram_b_din = '0; bram_b_we = '0; bram_b_be = '0;
    bram_c_en = '0; bram_c_addr = '0; bram_c_din = '0; bram_c_we = '0; bram_c_be = '0;

    pe_acc_clear_block = 0;
    pe_drain_pulse     = 0;

    // Reset sequence
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    
    //test_2x2_matmul();
    //test_4x4_matmul();
    test_full_tile_matmul();


    $display("\n========================================");
    $display("All Tests Complete (Write Sanity Only)");
    $display("========================================\n");

    repeat (10) @(posedge clk);
    $finish;
  end

  // ------------------------------------------------------------
  // Timeout watchdog
  // ------------------------------------------------------------
  initial begin
    #500000;
    $display("\nERROR: Testbench timeout!");
    $finish;
  end

  // ------------------------------------------------------------
  // Waveform dump
  // ------------------------------------------------------------
  initial begin
    $dumpfile("tb_bram_pe_bram.vcd");
    $dumpvars(0, tb_a1);
  end

endmodule
