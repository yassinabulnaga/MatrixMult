`timescale 1ns/1ps

module tb_a;

  import mm_pkg::*;

  // Matrix dimensions
  localparam int MAT_SIZE   = 64;
  localparam int NUM_TILES  = MAT_SIZE / T;  // 4 tiles per dimension

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
  // BRAM A (Matrix A storage) - needs 64*64 = 4096 elements
  // ------------------------------------------------------------
  logic [T-1:0]          bram_a_en;
  logic [T-1:0][11:0]    bram_a_addr;   // 4096 depth needs 12 bits
  logic [T-1:0][W-1:0]   bram_a_din;
  logic [T-1:0]          bram_a_we;
  logic [T-1:0][W/8-1:0] bram_a_be;
  logic [T-1:0][W-1:0]   bram_a_dout;

  m10k_banks #(
    .N_BANKS        (T),
    .W              (W),
    .DEPTH_PER_BANK (4096),
    .USE_BYTE_EN    (0),
    .RDW_MODE       (0)
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
  logic [T-1:0][11:0]    bram_b_addr;
  logic [T-1:0][W-1:0]   bram_b_din;
  logic [T-1:0]          bram_b_we;
  logic [T-1:0][W/8-1:0] bram_b_be;
  logic [T-1:0][W-1:0]   bram_b_dout;

  m10k_banks #(
    .N_BANKS        (T),
    .W              (W),
    .DEPTH_PER_BANK (4096),
    .USE_BYTE_EN    (0),
    .RDW_MODE       (0)
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
  // PE Array
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
  // BRAM C (result storage) - 64x64 results
  // ------------------------------------------------------------
  logic [T-1:0]               bram_c_en;
  logic [T-1:0][11:0]         bram_c_addr;
  logic [T-1:0][ACCW-1:0]     bram_c_din;
  logic [T-1:0]               bram_c_we;
  logic [T-1:0][ACCW/8-1:0]   bram_c_be;
  logic [T-1:0][ACCW-1:0]     bram_c_dout;

  m10k_banks #(
    .N_BANKS        (T),
    .W              (ACCW),
    .DEPTH_PER_BANK (4096),
    .USE_BYTE_EN    (0),
    .RDW_MODE       (0)
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
  // Pipeline registers
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
  // Helper Tasks for 64x64 operations
  // ------------------------------------------------------------

  // Write full 64x64 Matrix A to BRAM A
  // Storage layout: Row-major with tiling
  // Bank = (row % 16), Addr = (row/16)*64 + col
  task automatic write_matrix_64x64_a(input logic [63:0][63:0][W-1:0] mat);
    int row, col, bank, addr;
    $display("  Writing 64x64 Matrix A to BRAM...");

    bram_a_en = '0;
    bram_a_we = '0;

    for (row = 0; row < 64; row++) begin
      for (col = 0; col < 64; col++) begin
        bank = row % T;               // Which bank (0-15)
        addr = (row / T) * 64 + col;  // Address within bank

        bram_a_en         = '0;
        bram_a_we         = '0;
        bram_a_en[bank]   = 1'b1;
        bram_a_we[bank]   = 1'b1;
        bram_a_addr[bank] = addr[11:0];
        bram_a_din[bank]  = mat[row][col];

        @(posedge clk);
      end
    end

    bram_a_en = '0;
    bram_a_we = '0;
    repeat (3) @(posedge clk);
    $display("  Matrix A write complete");
  endtask

  // Write full 64x64 Matrix B to BRAM B
  // Storage layout: Column-major with tiling
  // Bank = (col % 16), Addr = (col/16)*64 + row
  task automatic write_matrix_64x64_b(input logic [63:0][63:0][W-1:0] mat);
    int row, col, bank, addr;
    $display("  Writing 64x64 Matrix B to BRAM...");

    bram_b_en = '0;
    bram_b_we = '0;

    for (col = 0; col < 64; col++) begin
      for (row = 0; row < 64; row++) begin
        bank = col % T;               // Which bank (0-15)
        addr = (col / T) * 64 + row;  // Address within bank

        bram_b_en         = '0;
        bram_b_we         = '0;
        bram_b_en[bank]   = 1'b1;
        bram_b_we[bank]   = 1'b1;
        bram_b_addr[bank] = addr[11:0];
        bram_b_din[bank]  = mat[row][col];

        @(posedge clk);
      end
    end

    bram_b_en = '0;
    bram_b_we = '0;
    repeat (3) @(posedge clk);
    $display("  Matrix B write complete");
  endtask

  // Stream one 16x16 K-tile through PE array
  // tile_row_a : which 16-row block of A (0-3)
  // tile_col_b : which 16-col block of B (0-3)
  // tile_k     : which 16-wide chunk of K (0-3) so K = 4*16 = 64
  task automatic stream_tile(
    input int tile_row_a,
    input int tile_col_b,
    input int tile_k
  );
    int cycle;
    int r, c;
    int k_local;
    int base_a_row;
    int base_b_col;
    int tmp_addr_a;
    int tmp_addr_b;

    // Row/col tile bases in the BRAM address:
    //   A: base_a_row = tile_row_a*64 + tile_k*16
    //   B: base_b_col = tile_col_b*64 + tile_k*16
    base_a_row = tile_row_a * 64 + tile_k * T;
    base_b_col = tile_col_b * 64 + tile_k * T;

    // Classic 16x16 systolic wave for a K_tile of 16: 3*T - 2 cycles
    for (cycle = 0; cycle < (3*T - 2); cycle++) begin
      bram_a_en = '0;
      bram_b_en = '0;

      // ----- Drive A rows (banks = rows) -----
      for (r = 0; r < T; r++) begin
        if ((cycle >= r) && (cycle < r + T)) begin
          k_local    = cycle - r;  // 0..15 within this K tile
          tmp_addr_a = base_a_row + k_local;

          bram_a_en[r]   = 1'b1;
          bram_a_addr[r] = tmp_addr_a[11:0];
        end
      end

      // ----- Drive B columns (banks = cols) -----
      for (c = 0; c < T; c++) begin
        if ((cycle >= c) && (cycle < c + T)) begin
          k_local    = cycle - c;
          tmp_addr_b = base_b_col + k_local;

          bram_b_en[c]   = 1'b1;
          bram_b_addr[c] = tmp_addr_b[11:0];
        end
      end

      @(posedge clk);
    end

    bram_a_en = '0;
    bram_b_en = '0;
    repeat (5) @(posedge clk);
  endtask

  // Process one output tile C[tile_i][tile_j]
  task automatic process_output_tile(
    input int tile_i,  // Output tile row (0-3)
    input int tile_j   // Output tile column (0-3)
  );
    int k;

    $display("    Processing output tile C[%0d][%0d]", tile_i, tile_j);

    // Clear accumulators for first K tile
    pe_acc_clear_block = 1;
    @(posedge clk);
    pe_acc_clear_block = 0;
    @(posedge clk);

    // Process all K tiles (accumulate partial products)
    for (k = 0; k < NUM_TILES; k++) begin
      $display("      K tile %0d", k);
      stream_tile(tile_i, tile_j, k);
    end

    // Drain the results
    pe_drain_pulse = 1;
    @(posedge clk);
    pe_drain_pulse = 0;
    repeat (T*T + 5) @(posedge clk);
  endtask

  // Write current PE results to BRAM C at specified tile location
  task automatic write_tile_to_bram_c(
    input int tile_i,
    input int tile_j
  );
    int i, j, global_row, global_col, bank, addr;

    for (i = 0; i < T; i++) begin
      for (j = 0; j < T; j++) begin
        global_row = tile_i * T + i;
        global_col = tile_j * T + j;

        bank = global_row % T;
        addr = (global_row / T) * 64 + global_col;

        bram_c_en         = '0;
        bram_c_we         = '0;
        bram_c_en[bank]   = 1'b1;
        bram_c_we[bank]   = 1'b1;
        bram_c_addr[bank] = addr[11:0];
        bram_c_din[bank]  = pe_acc_mat[i][j];

        @(posedge clk);
      end
    end

    bram_c_en = '0;
    bram_c_we = '0;
    repeat (2) @(posedge clk);
  endtask

  // Complete 64x64 matrix multiplication
  task automatic matmul_64x64();
    int ti, tj;

    $display("\n  Starting 64x64 tiled matrix multiplication");
    $display("  Processing %0dx%0d tiles of size %0dx%0d",
             NUM_TILES, NUM_TILES, T, T);

    // Process each output tile
    for (ti = 0; ti < NUM_TILES; ti++) begin
      for (tj = 0; tj < NUM_TILES; tj++) begin
        process_output_tile(ti, tj);
        write_tile_to_bram_c(ti, tj);
      end
    end

    $display("  64x64 matrix multiplication complete!");
  endtask

  // Verify a few sample results from BRAM C
  task automatic verify_samples_64x64(
    input logic [63:0][63:0][ACCW-1:0] expected
  );
    int row, col, bank, addr;
    logic [ACCW-1:0] read_val;
    bit pass = 1;
    int p;
    int test_points[5][2];

    // Check corners and center
    test_points[0][0] = 0;   test_points[0][1] = 0;   // Top-left
    test_points[1][0] = 0;   test_points[1][1] = 63;  // Top-right
    test_points[2][0] = 63;  test_points[2][1] = 0;   // Bottom-left
    test_points[3][0] = 63;  test_points[3][1] = 63;  // Bottom-right
    test_points[4][0] = 32;  test_points[4][1] = 32;  // Center

    $display("\n  Verifying sample results from 64x64 multiplication:");

    for (p = 0; p < 5; p++) begin
      row = test_points[p][0];
      col = test_points[p][1];

      bank = row % T;
      addr = (row / T) * 64 + col;

      bram_c_en         = '0;
      bram_c_en[bank]   = 1'b1;
      bram_c_addr[bank] = addr[11:0];
      bram_c_we[bank]   = 1'b0;

      repeat (2) @(posedge clk);
      read_val         = bram_c_dout[bank];
      bram_c_en[bank]  = 1'b0;

      if (read_val !== expected[row][col]) begin
        $display("    ERROR at [%0d][%0d]: got %0d, expected %0d",
                 row, col, $signed(read_val), $signed(expected[row][col]));
        pass = 0;
      end else begin
        $display("    ? C[%0d][%0d] = %0d",
                 row, col, $signed(read_val));
      end

      @(posedge clk);
    end

    if (pass) begin
      $display("  ??? Sample verification PASSED!");
    end else begin
      $display("  ??? Sample verification FAILED!");
    end
  endtask

  // ------------------------------------------------------------
  // Test: 64x64 Matrix Multiplication
  // ------------------------------------------------------------
  task automatic test_64x64_matmul();
    logic [63:0][63:0][W-1:0]    mat_a, mat_b;
    logic [63:0][63:0][ACCW-1:0] expected;
    int i, j;

    $display("\n=== Test: 64x64 Matrix Multiplication ===");
    $display("  Using %0d-bit signed integers", W);
    $display("  PE Array: %0dx%0d", T, T);
    $display("  Tiles: %0dx%0d grid", NUM_TILES, NUM_TILES);

    // Initialize matrices with simple patterns
    mat_a    = '0;
    mat_b    = '0;
    expected = '0;

    // A = I (identity), B is row-major pattern, C = B
    for (i = 0; i < 64; i++) begin
      for (j = 0; j < 64; j++) begin
        mat_a[i][j]    = (i == j) ? 8'd1 : 8'd0;
        mat_b[i][j]    = W'((i*64 + j + 1) & 8'h7F);  // Keep in signed range
        expected[i][j] = mat_b[i][j];                 // Since A is identity
      end
    end

    // Execute test
    write_matrix_64x64_a(mat_a);
    write_matrix_64x64_b(mat_b);
    matmul_64x64();
    verify_samples_64x64(expected);

    $display("=== End of 64x64 Test ===");
  endtask

  // ------------------------------------------------------------
  // Main Test Execution
  // ------------------------------------------------------------
  initial begin
    $display("========================================");
    $display("64x64 Matrix Multiplication Testbench");
    $display("T = %0d, W = %0d, ACCW = %0d", T, W, ACCW);
    $display("Matrix Size = %0dx%0d", MAT_SIZE, MAT_SIZE);
    $display("========================================");

    // Initialize signals
    bram_a_en   = '0; bram_a_addr   = '0; bram_a_din   = '0; bram_a_we   = '0; bram_a_be   = '0;
    bram_b_en   = '0; bram_b_addr   = '0; bram_b_din   = '0; bram_b_we   = '0; bram_b_be   = '0;
    bram_c_en   = '0; bram_c_addr   = '0; bram_c_din   = '0; bram_c_we   = '0; bram_c_be   = '0;
    pe_acc_clear_block = 0;
    pe_drain_pulse     = 0;

    // Reset sequence
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // Run the test
    test_64x64_matmul();

    $display("\n========================================");
    $display("Test Complete");
    $display("========================================\n");

    repeat (10) @(posedge clk);
    $finish;
  end

  // ------------------------------------------------------------
  // Timeout watchdog
  // ------------------------------------------------------------
  initial begin
    #10000000;  // Longer timeout for 64x64
    $display("\nERROR: Testbench timeout!");
    $finish;
  end

  // ------------------------------------------------------------
  // Waveform dump
  // ------------------------------------------------------------
  initial begin
    $dumpfile("tb_64x64_matmul.vcd");
    $dumpvars(0, tb_a);
  end

endmodule

