`timescale 1ns/1ps

module tb_compute_unit;

    localparam int N = 16;
    localparam int CLK_PERIOD = 10;
    
    // DUT signals
    logic clk;
    logic rst;
    logic start;
    logic done;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // Instantiate compute unit
    compute_unit #(.N(N)) dut (
        .clk   (clk),
        .rst   (rst),
        .start (start),
        .done  (done)
    );
    
    // Test stimulus
    initial begin
        $display("========================================");
        $display("  Compute Unit Testbench");
        $display("  16x16 Matrix Multiplication");
        $display("========================================\n");
        
        // Initialize
        rst = 0;
        start = 0;
        
        // Reset
        #(CLK_PERIOD * 2);
        $display("[%0t] Applying reset", $time);
        rst = 1;
        #(CLK_PERIOD * 3);
        
        $display("[%0t] Reset complete", $time);
        $display("[%0t] BRAMs initialized from MIF files:", $time);
        $display("         - matrix_a.mif loaded into BRAM A", $time);
        $display("         - matrix_b.mif loaded into BRAM B", $time);
        
        // Start computation
        #(CLK_PERIOD * 2);
        $display("\n[%0t] Starting matrix multiplication...", $time);
        start = 1;
        #(CLK_PERIOD);
        start = 0;
        
        // Wait for done signal
        $display("[%0t] Waiting for computation to complete...", $time);
        wait(done);
        @(posedge clk);
        
        $display("\n[%0t] *** DONE signal asserted ***", $time);
        $display("[%0t] Result matrix stored in BRAM C", $time);
        
        // Print some info
        $display("\nOperation Summary:");
        $display("  - State progression: IDLE -> LOAD_MATRICES -> COMPUTE -> STORE_RESULT -> IDLE");
        $display("  - Load phase: ~130 cycles (256 elements / 2 per cycle)");
        $display("  - Compute phase: 46 cycles (3*N-2 = 46)");
        $display("  - Store phase: ~130 cycles (256 results / 2 per cycle)");
        $display("  - Total: ~310 cycles");
        
        // Optional: Read back and display a few results
        $display("\nSample Results from BRAM C (first 4x4 block):");
        
        // Give some extra cycles for any pipeline settling
        #(CLK_PERIOD * 5);
        
        // Access DUT internals to read BRAM C
        for (int row = 0; row < 4; row++) begin
            $write("  Row %0d: ", row);
            for (int col = 0; col < 4; col++) begin
                logic [7:0] addr;
                addr = (row << 4) | col; // row*16 + col
                
                // Note: This accesses internal BRAM - in real HW you'd need external interface
                force dut.bram_c_addr_a = addr;
                #(CLK_PERIOD);
                @(posedge clk);
                $write("%8d ", $signed(dut.bram_c_q_a));
                release dut.bram_c_addr_a;
            end
            $write("\n");
        end
        
        $display("\n========================================");
        $display("  Test Complete!");
        $display("========================================");
        
        #(CLK_PERIOD * 10);
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #(CLK_PERIOD * 100000);
        $display("\nERROR: Simulation timeout!");
        $finish;
    end
    
    // Monitor state changes
    initial begin
        $display("\nState Monitor:");
        forever begin
            @(dut.state_q);
            case (dut.state_q)
                dut.IDLE:         $display("[%0t] State: IDLE", $time);
                dut.LOAD_MATRICES:$display("[%0t] State: LOAD_MATRICES", $time);
                dut.COMPUTE:      $display("[%0t] State: COMPUTE", $time);
                dut.STORE_RESULT: $display("[%0t] State: STORE_RESULT", $time);
            endcase
        end
    end
    
    // Optional: Waveform dump for GTKWave/ModelSim
    initial begin
        $dumpfile("compute_unit.vcd");
        $dumpvars(0, tb_compute_unit);
    end

endmodule
