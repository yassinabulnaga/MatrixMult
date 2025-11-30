// Comprehensive Testbench for Matrix Multiplication Accelerator
// Tests full flow: Load A -> Load B -> Compute -> Store C

`timescale 1ns/1ps

import mm_pkg::*;

module tb_mm_accel_top();

    parameter int CLK_PERIOD = 10;
    parameter int T = 16;   // 16x16 PE array
    parameter int W = 8;
    parameter int ACCW = 32;
    
    // DUT signals
    logic clk, rst_n;
    logic cpu_start_load_a, cpu_start_load_b, cpu_start_compute;
    logic cpu_done, cpu_busy;
    logic [31:0] cpu_addr_a, cpu_addr_b, cpu_addr_c;
    logic [7:0] cpu_len_a, cpu_len_b, cpu_len_c;
    
    logic [31:0] avm_address;
    logic avm_read, avm_write;
    logic [127:0] avm_writedata, avm_readdata;
    logic [15:0] avm_byteenable;
    logic [7:0] avm_burstcount;
    logic avm_waitrequest, avm_readdatavalid;
    
    // DDR Memory Model (64KB)
    logic [7:0] ddr_mem [0:65535];
    
    // Memory access state
    logic read_pending;
    logic [2:0] read_delay_cnt;
    logic [31:0] read_addr_q;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    mm_accel_top #(
        .BEAT_W(128),
        .ADDR_W(32),
        .LENGTH_W(8),
        .BRAM_AW(8),
        .T(T),
        .W(W),
        .ACCW(ACCW),
        .N_BANKS(16),
        .BRAM_DEPTH(256)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_start_load_a(cpu_start_load_a),
        .cpu_start_load_b(cpu_start_load_b),
        .cpu_start_compute(cpu_start_compute),
        .cpu_addr_a(cpu_addr_a),
        .cpu_addr_b(cpu_addr_b),
        .cpu_addr_c(cpu_addr_c),
        .cpu_len_a(cpu_len_a),
        .cpu_len_b(cpu_len_b),
        .cpu_len_c(cpu_len_c),
        .cpu_done(cpu_done),
        .cpu_busy(cpu_busy),
        .avm_address(avm_address),
        .avm_read(avm_read),
        .avm_write(avm_write),
        .avm_writedata(avm_writedata),
        .avm_byteenable(avm_byteenable),
        .avm_burstcount(avm_burstcount),
        .avm_readdata(avm_readdata),
        .avm_waitrequest(avm_waitrequest),
        .avm_readdatavalid(avm_readdatavalid)
    );
    
    // Memory model - only this block writes to ddr_mem
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            read_pending <= 1'b0;
            read_delay_cnt <= '0;
            avm_readdatavalid <= 1'b0;
            avm_readdata <= '0;
            
            // Initialize memory on reset
            for (int i = 0; i < 65536; i++) ddr_mem[i] <= 8'h00;
            
            // Matrix A at 0x1000 (16x16 = 256 bytes)
            for (int i = 0; i < T; i++) begin
                for (int j = 0; j < T; j++) begin
                    ddr_mem[32'h1000 + i*T + j] <= (i == j) ? 2 : 0;
                end
            end
            
            // Matrix B at 0x2000 (16x16 = 256 bytes)
            for (int i = 0; i < T; i++) begin
                for (int j = 0; j < T; j++) begin
                    ddr_mem[32'h2000 + i*T + j] <= ((i*T + j + 1) % 64) + 1;  // Values 1-64 (avoid signed overflow)
                end
            end
        end else begin
            avm_readdatavalid <= 1'b0;
            
            // Handle read requests
            if (avm_read && !avm_waitrequest) begin
                read_pending <= 1'b1;
                read_addr_q <= avm_address;
                read_delay_cnt <= 3'd2;
            end
            
            // Process pending reads
            if (read_pending) begin
                if (read_delay_cnt > 0) begin
                    read_delay_cnt <= read_delay_cnt - 1;
                end else begin
                    avm_readdatavalid <= 1'b1;
                    for (int i = 0; i < 16; i++) begin
                        avm_readdata[i*8 +: 8] <= ddr_mem[read_addr_q + i];
                    end
                    read_pending <= 1'b0;
                end
            end
            
            // Handle write requests
            if (avm_write && !avm_waitrequest) begin
                for (int i = 0; i < 16; i++) begin
                    if (avm_byteenable[i]) begin
                        ddr_mem[avm_address + i] <= avm_writedata[i*8 +: 8];
                    end
                end
            end
        end
    end
    
    assign avm_waitrequest = 1'b0;  // No backpressure
    
    task check_result;
        input [31:0] base_addr;
        logic signed [ACCW-1:0] val;
        logic signed [ACCW-1:0] expected;
        int errors;
        begin
            errors = 0;
            $display("\nChecking results...");
            
            for (int i = 0; i < T; i++) begin
                for (int j = 0; j < T; j++) begin
                    // Read from DDR with 16 BRAM rows, 4 beats per row layout
                   automatic int row_base = i * 64;
                  automatic  int beat_in_row = j / 4;
                  automatic  int acc_in_beat = j % 4;
                   automatic int byte_offset = row_base + beat_in_row * 16 + acc_in_beat * 4;
                    
                    val = '0;
                    for (int b = 0; b < 4; b++) begin
                        val[b*8 +: 8] = ddr_mem[base_addr + byte_offset + b];
                    end
                    
                    // Expected: A*B where A=2*I, B=values 1-64
                    // C[i][j] = A[i][i]*B[i][j] = 2*B[i][j]
                    expected = 2 * (((i*T + j + 1) % 64) + 1);
                    
                    if (val !== expected) begin
                        $display("  ERROR at C[%0d][%0d]: got %0d, expected %0d", 
                                 i, j, val, expected);
                        errors++;
                    end
                end
            end
            
            if (errors == 0) begin
                $display("  *** ALL RESULTS CORRECT! ***");
            end else begin
                $display("  *** %0d ERRORS FOUND ***", errors);
            end
        end
    endtask
    
    // Test sequence
    initial begin
        $display("\n========================================");
        $display("Matrix Multiplication Accelerator Test");
        $display("  A = Input activations");
        $display("  B = Weights (persistent)");
        $display("========================================\n");
        
        // Initialize signals
        rst_n = 0;
        cpu_start_load_a = 0;
        cpu_start_load_b = 0;
        cpu_start_compute = 0;
        cpu_addr_a = 32'h00001000;
        cpu_addr_b = 32'h00002000;  // B = WEIGHTS
        cpu_addr_c = 32'h00003000;
        
        cpu_len_a = 8'd16;  // 16 beats for 16x16 input A (16 bytes per beat)
        cpu_len_b = 8'd16;  // 16 beats for 16x16 weights B
        cpu_len_c = 8'd64;  // 64 beats for 16x16 result C (each element is 32 bits)
        
        // Reset (initializes memory)
        repeat(10) @(posedge clk);
        rst_n = 1;
        $display("[%0t] Reset released, memory initialized\n", $time);
        
        repeat(5) @(posedge clk);
        
        // Display initialized matrices (after reset)
        $display("Matrix A (Input activations) at 0x00001000:");
        for (int i = 0; i < T; i++) begin
            $write("  Row %0d: ", i);
            for (int j = 0; j < T; j++) begin
                $write("%3d ", ddr_mem[32'h1000 + i*T + j]);
            end
            $write("\n");
        end
        
        $display("\nMatrix B (Weights) at 0x00002000:");
        for (int i = 0; i < T; i++) begin
            $write("  Row %0d: ", i);
            for (int j = 0; j < T; j++) begin
                $write("%3d ", ddr_mem[32'h2000 + i*T + j]);
            end
            $write("\n");
        end
        
        repeat(5) @(posedge clk);
        
        // ========== LOAD WEIGHTS B (one time) ==========
        $display("[%0t] Loading weights (B) into BRAM...", $time);
        cpu_start_load_b = 1;
        @(posedge clk);
        cpu_start_load_b = 0;
        
        wait(cpu_done);
        $display("[%0t] Weights loaded!", $time);
        
        repeat(5) @(posedge clk);
        
        // ========== LOAD INPUT A ==========
        $display("[%0t] Loading input activations (A) into BRAM...", $time);
        cpu_start_load_a = 1;
        @(posedge clk);
        cpu_start_load_a = 0;
        
        wait(cpu_done);
        $display("[%0t] Input loaded!", $time);
        
        repeat(5) @(posedge clk);
        
        // ========== COMPUTE ==========
        $display("[%0t] Starting computation (inference)...", $time);
        cpu_start_compute = 1;
        @(posedge clk);
        cpu_start_compute = 0;
        
        wait(cpu_done);
        $display("[%0t] Computation done!", $time);
        
        repeat(5) @(posedge clk);
        
        // Display and check results
        // BRAM C has 16 addresses, each stores one complete row (512 bits)
        // DMA reads 4 beats per row, storing as: addr*64 + beat*16 + byte_offset
        $display("\nResult Matrix C at 0x00003000:");
        for (int i = 0; i < T; i++) begin
            $write("  Row %0d: ", i);
            for (int j = 0; j < T; j++) begin
                logic signed [ACCW-1:0] val;
                // Each row needs 4 DMA beats
                // Row i stored at DDR: base + i*64 (4 beats × 16 bytes)
                // Accumulator j within row at: (j/4)*16 + (j%4)*4
               automatic int row_base = i * 64;  // Each row = 64 bytes (4 beats)
               automatic int beat_in_row = j / 4;
              automatic  int acc_in_beat = j % 4;
                automatic int byte_offset = row_base + beat_in_row * 16 + acc_in_beat * 4;
                
                val = '0;
                for (int b = 0; b < 4; b++) begin
                    val[b*8 +: 8] = ddr_mem[32'h3000 + byte_offset + b];
                end
                $write("%6d ", val);
            end
            $write("\n");
        end
        check_result(cpu_addr_c);
        
        repeat(20) @(posedge clk);
        
        $display("\n========================================");
        $display("Test Complete");
        $display("  Weights remain in BRAM B");
        $display("  Can now load new A and compute again");
        $display("========================================\n");
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #100000;  // 100us timeout
        $display("\n*** ERROR: TESTBENCH TIMEOUT ***");
        $finish;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("mm_accel.vcd");
        $dumpvars(0, tb_mm_accel_top);
    end

endmodule