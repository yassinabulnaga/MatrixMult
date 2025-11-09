// tb_mm_top.sv
// Testbench for the complete systolic array matrix multiplier
// Tests small matrix multiplication to verify functionality

`timescale 1ns/1ps
import mm_pkg::*;
module tb_mm_top;

  // Parameters
  localparam int W         = mm_pkg::W;      // 8-bit elements
  localparam int ACCW      = mm_pkg::ACCW;   // 32-bit accumulator
  localparam int T         = 4;              // Use smaller tile for testing
  localparam int HOST_DW   = mm_pkg::HOST_DW; // 128-bit bus
  localparam int N         = 8;              // 8x8 matrices for testing
  
  // Clock and reset
  logic clk;
  logic rst_n;
  
  // Control/Status
  logic        start;
  logic        busy;
  logic        done;
  logic        irq;
  
  // Configuration
  logic [31:0] baseA, baseB, baseC;
  logic [15:0] mat_N, lda, ldb, ldc;
  logic        irq_en;
  
  // Avalon-MM interface
  logic [31:0]          avm_address;
  logic                 avm_read;
  logic                 avm_write;
  logic [HOST_DW-1:0]   avm_writedata;
  logic [HOST_DW/8-1:0] avm_byteenable;
  logic [HOST_DW-1:0]   avm_readdata;
  logic                 avm_readdatavalid;
  logic                 avm_waitrequest;
  logic [7:0]           avm_burstcount;
  
  // Debug signals
  logic [31:0] debug_tiles_completed;
  logic [7:0]  debug_state;
  
  // Memory model (simplified DDR)
  logic [7:0] memory [bit[31:0]];
  
  // Test matrices (small for verification)
  logic [W-1:0] matA[N][N];  // Input matrix A
  logic [W-1:0] matB[N][N];  // Input matrix B
  logic [ACCW-1:0] matC_expected[N][N];  // Expected result
  logic [ACCW-1:0] matC_actual[N][N];    // Actual result from DUT
  
  // DUT instantiation with smaller tile size for testing
  mm_top #(
    .W(W),
    .ACCW(ACCW),
    .T(T),  // Smaller tile for testing
    .HOST_DW(HOST_DW),
    .SIGNED_M(1),
    .PIPE_MUL(0),
    .AW(10),
    .FIFO_DEPTH(7),
    .ADDR_IS_WORD(0)  // Use byte addressing for simplicity
  ) dut (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .start                 (start),
    .busy                  (busy),
    .done                  (done),
    .irq                   (irq),
    .baseA                 (baseA),
    .baseB                 (baseB),
    .baseC                 (baseC),
    .N                     (mat_N),
    .lda                   (lda),
    .ldb                   (ldb),
    .ldc                   (ldc),
    .irq_en                (irq_en),
    .avm_address           (avm_address),
    .avm_read              (avm_read),
    .avm_write             (avm_write),
    .avm_writedata         (avm_writedata),
    .avm_byteenable        (avm_byteenable),
    .avm_readdata          (avm_readdata),
    .avm_readdatavalid     (avm_readdatavalid),
    .avm_waitrequest       (avm_waitrequest),
    .avm_burstcount        (avm_burstcount),
    .debug_tiles_completed (debug_tiles_completed),
    .debug_state           (debug_state)
  );
  
  // Clock generation
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;  // 100MHz clock
  end
  
  // Memory model tasks
  task automatic write_byte(input bit[31:0] addr, input bit[7:0] data);
    memory[addr] = data;
  endtask
  
  task automatic write_word(input bit[31:0] addr, input bit[31:0] data);
    write_byte(addr + 0, data[7:0]);
    write_byte(addr + 1, data[15:8]);
    write_byte(addr + 2, data[23:16]);
    write_byte(addr + 3, data[31:24]);
  endtask
  
  function automatic bit[7:0] read_byte(input bit[31:0] addr);
    if (memory.exists(addr))
      return memory[addr];
    else
      return 8'h00;
  endfunction
  
  function automatic bit[31:0] read_word(input bit[31:0] addr);
    bit[31:0] data;
    data[7:0]   = read_byte(addr + 0);
    data[15:8]  = read_byte(addr + 1);
    data[23:16] = read_byte(addr + 2);
    data[31:24] = read_byte(addr + 3);
    return data;
  endfunction
  
  // Initialize test matrices
  task automatic init_matrices();
    // Simple test pattern for A
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        matA[i][j] = (i == j) ? 2 : 1;  // Diagonal = 2, others = 1
      end
    end
    
    // Simple test pattern for B
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        matB[i][j] = j + 1;  // Column index + 1
      end
    end
    
    // Calculate expected result C = A * B
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        matC_expected[i][j] = 0;
        for (int k = 0; k < N; k++) begin
          matC_expected[i][j] += $signed(matA[i][k]) * $signed(matB[k][j]);
        end
      end
    end
    
    // Write matrices to memory with proper layout
    // Matrix elements are W bits (1 byte), stored row-major
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        // A matrix: baseA + (i*lda + j) * bytes_per_element
        write_byte(baseA + (i*lda + j), matA[i][j]);
        // B matrix: baseB + (i*ldb + j) * bytes_per_element  
        write_byte(baseB + (i*ldb + j), matB[i][j]);
      end
    end
  endtask
  
  // Read result matrix from memory
  task automatic read_result_matrix();
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        // C matrix uses ACCW-bit elements (4 bytes each)
        matC_actual[i][j] = read_word(baseC + (i*ldc + j)*4);
      end
    end
  endtask
  
  // Verify results
  task automatic verify_results();
    int errors = 0;
    
    $display("=== Verification Results ===");
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        if (matC_actual[i][j] !== matC_expected[i][j]) begin
          $error("Mismatch at C[%0d][%0d]: expected=%0d, actual=%0d",
                 i, j, matC_expected[i][j], matC_actual[i][j]);
          errors++;
        end
      end
    end
    
    if (errors == 0) begin
      $display("TEST PASSED: All %0d elements match!", N*N);
    end else begin
      $display("TEST FAILED: %0d mismatches found", errors);
    end
  endtask
  
  // Avalon memory model process
  logic [31:0] burst_addr;
  int burst_remaining;
  logic read_active;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      avm_waitrequest    <= 1'b0;
      avm_readdatavalid  <= 1'b0;
      avm_readdata       <= '0;
      burst_addr         <= '0;
      burst_remaining    <= 0;
      read_active        <= 1'b0;
    end else begin
      // Default outputs
  avm_readdatavalid <= 1'b0;
      avm_waitrequest   <= read_active;  // Assert waitrequest when busy
      
      // Handle read requests
      if (avm_read && !read_active) begin
        // New read burst request
        if ($random % 4 == 0) begin
          // Occasionally add wait states
          avm_waitrequest <= 1'b1;
        end else begin
          // Accept the read
          burst_addr      <= avm_address;
          burst_remaining <= avm_burstcount;
          read_active     <= 1'b1;
          $display("[MEM] Read burst: addr=0x%08x, count=%0d", avm_address, avm_burstcount);
          $display("[%0t] ", $time);

        end
      end
      
      // Process active burst
      if (read_active && burst_remaining > 0) begin
        // Return data with 1-2 cycle latency
        if ($random % 3 != 0) begin  // 2/3 probability of data valid
          logic [HOST_DW-1:0] data;
          // Read HOST_DW/8 bytes from memory
          for (int i = 0; i < HOST_DW/8; i++) begin
            data[i*8 +: 8] = read_byte(burst_addr + i);
          end
          avm_readdata      <= data;
          avm_readdatavalid <= 1'b1;
          burst_addr        <= burst_addr + HOST_DW/8;  // Next address
          burst_remaining   <= burst_remaining - 1;
          
          if (burst_remaining == 1) begin
            read_active <= 1'b0;  // Last beat
          end
        end
      end
      
      // Handle writes
      if (avm_write) begin
        if ($random % 4 == 0) begin
          avm_waitrequest <= 1'b1;
        end else begin
          // Accept write
          for (int i = 0; i < HOST_DW/8; i++) begin
            if (avm_byteenable[i]) begin
              write_byte(avm_address + i, avm_writedata[i*8 +: 8]);
            end
          end
          $display("[MEM] Write: addr=0x%08x data=0x%032x be=0x%04x", 
                   avm_address, avm_writedata, avm_byteenable);
        end
      end
    end
  end
  
  // Test sequence
  initial begin
    // Initialize
    rst_n  = 1'b0;
    start  = 1'b0;
    baseA  = 32'h0000_1000;
    baseB  = 32'h0000_2000;
    baseC  = 32'h0000_3000;
    mat_N  = N;
    lda    = N;
    ldb    = N;
    ldc    = N;
    irq_en = 1'b1;
    
    // Initialize matrices in memory
    init_matrices();
    
    // Display input matrices
    $display("=== Input Matrix A ===");
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        $write("%3d ", matA[i][j]);
      end
      $write("\n");
    end
    
    $display("=== Input Matrix B ===");
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        $write("%3d ", matB[i][j]);
      end
      $write("\n");
    end
    
    $display("=== Expected Matrix C ===");
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        $write("%5d ", matC_expected[i][j]);
      end
      $write("\n");
    end
    
    // Reset
    repeat(10) @(posedge clk);
    rst_n = 1'b1;
    repeat(10) @(posedge clk);
    
    // Start matrix multiplication
    $display("\n=== Starting Matrix Multiplication ===");
    @(posedge clk);
    start = 1'b1;
    @(posedge clk);
    start = 1'b0;
    
    // Wait for completion with timeout
    fork
      begin
        wait(done);
        $display("Matrix multiplication completed!");
        $display("Tiles processed: %0d", debug_tiles_completed);
      end
      begin
        repeat(100000) @(posedge clk);
        $error("TIMEOUT: Operation did not complete");
        $finish;
      end
    join_any
    disable fork;
    
    // Wait a bit for memory writes to complete
    repeat(100) @(posedge clk);
    
    // Read and verify results
    read_result_matrix();
    
    $display("\n=== Actual Matrix C (from memory) ===");
    for (int i = 0; i < N; i++) begin
      for (int j = 0; j < N; j++) begin
        $write("%5d ", matC_actual[i][j]);
      end
      $write("\n");
    end
    
    verify_results();
    
    // End simulation
    repeat(10) @(posedge clk);
    $finish;
  end
  
  // Monitor FSM state changes
  always @(posedge clk) begin
    static logic [7:0] prev_state = 8'hFF;
    if (debug_state != prev_state) begin
      $display("[%0t] FSM State: 0x%02x", $time, debug_state);
      prev_state = debug_state;
    end
  end
  
  // Timeout watchdog
  initial begin
    #10_000_000;  // 10ms timeout
    $error("GLOBAL TIMEOUT: Simulation took too long");
    $finish;
  end

endmodule
