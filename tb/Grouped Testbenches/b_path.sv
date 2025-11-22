`timescale 1ns/1ps

module tb_bpath;

    // ========================================================================
    // Parameters
    // ========================================================================
    parameter int W         = 16;      // Element width
    parameter int T         = 16;      // Number of banks (rows)
    parameter int AW        = 10;      // Per-bank address width
    parameter int BEAT_W    = 128;     // Avalon bus width
    parameter int ADDR_W    = 32;      // Address width
    parameter int LGFLEN    = 7;       // FIFO depth (2^7 = 128 elements)
    
    parameter int BYTES_PER_BEAT = BEAT_W / 8;
    parameter int ELS_PER_BEAT   = BEAT_W / W;
    
    // ========================================================================
    // Clock and Reset
    // ========================================================================
    logic clk;
    logic rst_n;
    
    initial begin
        clk = 0;
        forever #5 clk = ~clk;  // 100 MHz clock
    end
    
    // ========================================================================
    // Result Drain Signals
    // ========================================================================
    logic                 drain_start;
    logic                 drain_busy;
    logic                 drain_done;
    logic [15:0]          tile_rows;
    logic [15:0]          tile_cols;
    logic                 bankset_sel;
    logic [T-1:0]         a_en;
    logic [T-1:0][AW-1:0] a_addr;
    logic [T-1:0][W-1:0]  a_dout;
    logic                 drain_out_valid;
    logic [W-1:0]         drain_out_data;
    logic                 drain_out_ready;
    logic                 drain_flush;
    
    // ========================================================================
    // FIFO Signals
    // ========================================================================
    logic [W-1:0]         fifo_m_data;
    logic                 fifo_m_valid;
    logic                 fifo_m_ready;
    
    // ========================================================================
    // Packer Signals
    // ========================================================================
    logic                 packer_m_valid;
    logic                 packer_m_ready;
    logic [BEAT_W-1:0]    packer_m_data;
    logic [BEAT_W/8-1:0]  packer_m_strb;
    logic                 packer_m_last;
    
    // ========================================================================
    // Avalon MM Writer Signals
    // ========================================================================
    logic                 writer_start;
    logic [ADDR_W-1:0]    base_addr;
    logic                 writer_busy;
    logic                 writer_done;
    logic [ADDR_W-1:0]    avm_address;
    logic                 avm_write;
    logic [BEAT_W-1:0]    avm_writedata;
    logic [BEAT_W/8-1:0]  avm_byteenable;
    logic [7:0]           avm_burstcount;
    logic                 avm_waitrequest;
    
    // ========================================================================
    // Testbench Memory (simulating BRAM banks)
    // ========================================================================
    logic [W-1:0] bram_banks [0:T-1][0:2**AW-1];
    
    // ========================================================================
    // Captured Output Data
    // ========================================================================
    logic [W-1:0] captured_data [0:16383];  // Max 16K elements
    integer capture_count;
    logic [BEAT_W-1:0] captured_beats [0:2047];  // Max 2K beats
    integer beat_count;
    
    // ========================================================================
    // Module Instantiations
    // ========================================================================
    
    // Result Drain
    result_drain #(
        .W(W),
        .T(T),
        .AW(AW)
    ) u_result_drain (
        .clk(clk),
        .rst_n(rst_n),
        .start(drain_start),
        .busy(drain_busy),
        .done(drain_done),
        .tile_rows(tile_rows),
        .tile_cols(tile_cols),
        .bankset_sel(bankset_sel),
        .a_en(a_en),
        .a_addr(a_addr),
        .a_dout(a_dout),
        .out_valid(drain_out_valid),
        .out_data(drain_out_data),
        .out_ready(drain_out_ready),
        .flush(drain_flush)
    );
    
    // FIFO Wrapper
    fifo_wrapper #(
        .W(W),
        .LGFLEN(LGFLEN)
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .s_data(drain_out_data),
        .s_valid(drain_out_valid),
        .s_ready(drain_out_ready),
        .m_data(fifo_m_data),
        .m_valid(fifo_m_valid),
        .m_ready(fifo_m_ready)
    );
    
    // Track elements for proper s_last generation
    integer elements_expected;
    integer elements_sent;
    logic is_last_element;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            elements_expected <= 0;
            elements_sent <= 0;
        end else begin
            // Capture total elements when drain starts
            if (drain_start) begin
                elements_expected <= tile_rows * tile_cols;
                elements_sent <= 0;
            end
            // Count elements going through FIFO
            if (fifo_m_valid && fifo_m_ready) begin
                elements_sent <= elements_sent + 1;
            end
        end
    end
    
    // Assert s_last when sending the final element
    assign is_last_element = (elements_sent == elements_expected - 1) && fifo_m_valid;
    
    // Packer
    packer #(
        .W(W),
        .BEAT_W(BEAT_W),
        .LSB_FIRST(1)
    ) u_packer (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(fifo_m_valid),
        .s_ready(fifo_m_ready),
        .s_data(fifo_m_data),
        .s_last(is_last_element),
        .m_valid(packer_m_valid),
        .m_ready(packer_m_ready),
        .m_data(packer_m_data),
        .m_strb(packer_m_strb),
        .m_last(packer_m_last)
    );
    
    // Avalon MM Writer
    avalon_mm_writer #(
        .BEAT_W(BEAT_W),
        .ADDR_W(ADDR_W)
    ) u_writer (
        .clk(clk),
        .rst_n(rst_n),
        .s_valid(packer_m_valid),
        .s_ready(packer_m_ready),
        .s_data(packer_m_data),
        .s_strb(packer_m_strb),
        .s_last(packer_m_last),
        .start(writer_start),
        .base_addr(base_addr),
        .busy(writer_busy),
        .done(writer_done),
        .avm_address(avm_address),
        .avm_write(avm_write),
        .avm_writedata(avm_writedata),
        .avm_byteenable(avm_byteenable),
        .avm_burstcount(avm_burstcount),
        .avm_waitrequest(avm_waitrequest)
    );
    
    // ========================================================================
    // BRAM Read Simulation (1-cycle latency)
    // ========================================================================
    always_ff @(posedge clk) begin
        for (int i = 0; i < T; i++) begin
            if (a_en[i]) begin
                a_dout[i] <= bram_banks[i][a_addr[i]];
            end
        end
    end
    
    // ========================================================================
    // Capture output data at FIFO output
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            capture_count <= 0;
        end else begin
            if (fifo_m_valid && fifo_m_ready) begin
                captured_data[capture_count] <= fifo_m_data;
                capture_count <= capture_count + 1;
            end
        end
    end
    
    // ========================================================================
    // Capture packed beats at writer output
    // ========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            beat_count <= 0;
        end else begin
            if (avm_write && !avm_waitrequest) begin
                captured_beats[beat_count] <= avm_writedata;
                beat_count <= beat_count + 1;
            end
        end
    end
    
    // ========================================================================
    // Test Control Variables (non-automatic)
    // ========================================================================
    integer test_num;
    integer errors;
    
    // ========================================================================
    // Helper Tasks
    // ========================================================================
    
    // Reset task
    task reset_dut;
        begin
            rst_n = 0;
            drain_start = 0;
            writer_start = 0;
            avm_waitrequest = 0;
            tile_rows = 0;
            tile_cols = 0;
            bankset_sel = 0;
            base_addr = 0;
            repeat(5) @(posedge clk);
            rst_n = 1;
            repeat(2) @(posedge clk);
        end
    endtask
    
    // Initialize BRAM with test pattern
    task init_bram_pattern;
        input integer pattern_type;
        input integer rows;
        input integer cols;
        input bit bankset;
        integer r, c, addr_offset;
        begin
            addr_offset = bankset ? (1 << (AW-1)) : 0;
            
            for (r = 0; r < rows && r < T; r = r + 1) begin
                for (c = 0; c < cols; c = c + 1) begin
                    case (pattern_type)
                        0: begin // Sequential pattern
                            bram_banks[r][addr_offset + c] = (r * cols + c) & 16'hFFFF;
                        end
                        1: begin // Row index pattern
                            bram_banks[r][addr_offset + c] = r;
                        end
                        2: begin // Column index pattern
                            bram_banks[r][addr_offset + c] = c;
                        end
                        3: begin // Checkerboard pattern
                            bram_banks[r][addr_offset + c] = ((r + c) & 1) ? 16'hAAAA : 16'h5555;
                        end
                        default: begin // All ones
                            bram_banks[r][addr_offset + c] = 16'hFFFF;
                        end
                    endcase
                end
            end
        end
    endtask
    
    // Verify captured data
    task verify_captured_data;
        input integer rows;
        input integer cols;
        input bit bankset;
        input integer pattern_type;
        output integer error_count;
        reg [W-1:0] expected_val;
        reg [W-1:0] actual_val;
        integer addr_offset;
        integer idx;
        integer r, c;
        begin
            error_count = 0;
            addr_offset = bankset ? (1 << (AW-1)) : 0;
            idx = 0;
            
            for (r = 0; r < rows; r = r + 1) begin
                for (c = 0; c < cols; c = c + 1) begin
                    // Calculate expected value based on pattern
                    case (pattern_type)
                        0: expected_val = (r * cols + c) & 16'hFFFF;
                        1: expected_val = r;
                        2: expected_val = c;
                        3: expected_val = ((r + c) & 1) ? 16'hAAAA : 16'h5555;
                        default: expected_val = 16'hFFFF;
                    endcase
                    
                    // Get actual value from captured data
                    actual_val = captured_data[idx];
                    
                    if (actual_val !== expected_val) begin
                        $display("ERROR [%0t]: Data mismatch at element [%0d][%0d] (idx=%0d): expected=0x%h, actual=0x%h",
                                 $time, r, c, idx, expected_val, actual_val);
                        error_count = error_count + 1;
                    end
                    
                    idx = idx + 1;
                end
            end
        end
    endtask
    
    // Apply backpressure for a duration
    task apply_backpressure;
        input integer cycles;
        input integer probability;
        integer i;
        integer rand_val;
        begin
            for (i = 0; i < cycles; i = i + 1) begin
                rand_val = $random % 100;
                if (rand_val < 0) rand_val = -rand_val;
                avm_waitrequest = (rand_val < probability);
                @(posedge clk);
            end
            avm_waitrequest = 0;
        end
    endtask
    
    // Run a single tile test
    task run_tile_test;
        input integer rows;
        input integer cols;
        input bit bankset;
        input integer pattern_type;
        input integer base_address;
        input integer backpressure_prob;
        input [255*8:1] test_name;
        integer local_errors;
        integer expected_elements;
        integer timeout_cycles;
        integer cycle_count;
        begin
            $display("\n========================================");
            $display("Test %0d: %0s", test_num, test_name);
            $display("  Rows: %0d, Cols: %0d, Bankset: %0d", rows, cols, bankset);
            $display("  Pattern: %0d, Base Addr: 0x%h", pattern_type, base_address);
            $display("  Backpressure: %0d%%", backpressure_prob);
            $display("========================================");
            
            test_num = test_num + 1;
            
            // Reset capture counters
            capture_count = 0;
            beat_count = 0;
            
            // Initialize BRAM
            init_bram_pattern(pattern_type, rows, cols, bankset);
            
            // Configure and start drain
            tile_rows = rows;
            tile_cols = cols;
            bankset_sel = bankset;
            @(posedge clk);
            
            drain_start = 1;
            @(posedge clk);
            drain_start = 0;
            
            // Configure and start writer
            base_addr = base_address;
            writer_start = 1;
            @(posedge clk);
            writer_start = 0;
            
            // Apply backpressure in parallel
            if (backpressure_prob > 0) begin
                fork
                    begin
                        expected_elements = rows * cols;
                        timeout_cycles = expected_elements * 20 + 1000;
                        apply_backpressure(timeout_cycles, backpressure_prob);
                    end
                join_none
            end
            
            // Wait for completion with timeout
            expected_elements = rows * cols;
            timeout_cycles = expected_elements * 20 + 1000;
            cycle_count = 0;
            
            while (!drain_done || !writer_done) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
                if (cycle_count >= timeout_cycles) begin
                    $display("ERROR: Timeout waiting for completion!");
                    errors = errors + 1;
                    disable run_tile_test;
                end
            end
            
            // Stop backpressure
            avm_waitrequest = 0;
            
            // Wait a few cycles for pipeline to settle
            repeat(10) @(posedge clk);
            
            // Verify captured data
            verify_captured_data(rows, cols, bankset, pattern_type, local_errors);
            
            if (local_errors == 0) begin
                $display("PASS: Test %0s completed successfully", test_name);
            end else begin
                $display("FAIL: Test %0s had %0d errors", test_name, local_errors);
                errors = errors + local_errors;
            end
            
            // Brief pause between tests
            repeat(5) @(posedge clk);
        end
    endtask
    
    // ========================================================================
    // Monitor for protocol violations (non-automatic variables)
    // ========================================================================
    reg prev_drain_valid;
    reg [W-1:0] prev_drain_data;
    reg prev_fifo_valid;
    reg [W-1:0] prev_fifo_data;
    reg prev_packer_valid;
    reg [BEAT_W-1:0] prev_packer_data;
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_drain_valid <= 0;
            prev_drain_data <= 0;
            prev_fifo_valid <= 0;
            prev_fifo_data <= 0;
            prev_packer_valid <= 0;
            prev_packer_data <= 0;
        end else begin
            // Monitor drain -> FIFO interface
            if (prev_drain_valid && !drain_out_ready) begin
                if (!drain_out_valid) begin
                    $display("WARNING [%0t]: drain_out_valid dropped while not ready", $time);
                end
                if (drain_out_data !== prev_drain_data) begin
                    $display("ERROR [%0t]: drain_out_data changed while valid && !ready", $time);
                    errors = errors + 1;
                end
            end
            
            // Monitor FIFO -> Packer interface
            if (prev_fifo_valid && !fifo_m_ready) begin
                if (!fifo_m_valid) begin
                    $display("WARNING [%0t]: fifo_m_valid dropped while not ready", $time);
                end
                if (fifo_m_data !== prev_fifo_data) begin
                    $display("ERROR [%0t]: fifo_m_data changed while valid && !ready", $time);
                    errors = errors + 1;
                end
            end
            
            // Monitor Packer -> Writer interface
            if (prev_packer_valid && !packer_m_ready) begin
                if (!packer_m_valid) begin
                    $display("WARNING [%0t]: packer_m_valid dropped while not ready", $time);
                end
                if (packer_m_data !== prev_packer_data) begin
                    $display("ERROR [%0t]: packer_m_data changed while valid && !ready", $time);
                    errors = errors + 1;
                end
            end
            
            // Store current values
            prev_drain_valid <= drain_out_valid;
            prev_drain_data <= drain_out_data;
            prev_fifo_valid <= fifo_m_valid;
            prev_fifo_data <= fifo_m_data;
            prev_packer_valid <= packer_m_valid;
            prev_packer_data <= packer_m_data;
        end
    end
    
    // ========================================================================
    // Main Test Sequence
    // ========================================================================
    initial begin
        $display("\n");
        $display("================================================================================");
        $display("Matrix Multiplication Result Path Testbench - ModelSim Compatible");
        $display("================================================================================");
        $display("Configuration:");
        $display("  Element Width (W):     %0d bits", W);
        $display("  Number of Banks (T):   %0d", T);
        $display("  Bank Address Width:    %0d bits", AW);
        $display("  Avalon Beat Width:     %0d bits (%0d bytes)", BEAT_W, BYTES_PER_BEAT);
        $display("  Elements per Beat:     %0d", ELS_PER_BEAT);
        $display("  FIFO Depth:            %0d elements", 2**LGFLEN);
        $display("================================================================================\n");
        
        test_num = 1;
        errors = 0;
        
        // Reset
        reset_dut();
        
        // Test 1: Small tile (4x4) - Sequential pattern, no backpressure
        run_tile_test(4, 4, 0, 0, 32'h0000_0000, 0, "4x4 Sequential, No Backpressure");
        
        // Test 2: Medium tile (8x8) - Row index pattern, 20% backpressure
        //run_tile_test(8, 8, 0, 1, 32'h0000_0100, 20, "8x8 Row Pattern, 20% Backpressure");
        
        // Test 3: Full tile (16x16) - Column pattern, no backpressure
        //run_tile_test(16, 16, 0, 2, 32'h0000_0200, 0, "16x16 Column Pattern, No Backpressure");
        
        // Test 4: Non-square tile (16x8) - Checkerboard, 50% backpressure
       // run_tile_test(16, 8, 1, 3, 32'h0000_0400, 50, "16x8 Checkerboard, 50% Backpressure");
        
        // Test 5: Minimum tile (1x1) - All ones pattern
        //run_tile_test(1, 1, 0, 4, 32'h0000_0600, 0, "1x1 Single Element");
        
        // Test 6: Single row (1x16) - Sequential pattern
        //run_tile_test(1, 16, 0, 0, 32'h0000_0700, 0, "1x16 Single Row");
        
        // Test 7: Single column (16x1) - Sequential pattern
        //run_tile_test(16, 1, 1, 0, 32'h0000_0800, 0, "16x1 Single Column");
        
        // Test 8: Odd dimensions (7x5) - Sequential pattern, 30% backpressure
        //run_tile_test(7, 5, 0, 0, 32'h0000_0900, 30, "7x5 Odd Dimensions, 30% Backpressure");
        
        // Test 9: Exact beat alignment (4x8) - 32 elements = 4 beats
       // run_tile_test(4, 8, 1, 0, 32'h0000_0A00, 0, "4x8 Exact Beat Alignment");
        
        // Test 10: Stress test (12x12) - 80% backpressure
        //run_tile_test(12, 12, 0, 0, 32'h0000_0C00, 80, "12x12 Stress Test, 80% Backpressure");
        
        // Final Report
        repeat(20) @(posedge clk);
        
        $display("\n");
        $display("================================================================================");
        $display("Test Summary");
        $display("================================================================================");
        $display("Total Tests Run:  %0d", test_num - 1);
        $display("Total Errors:     %0d", errors);
        
        if (errors == 0) begin
            $display("\n*** ALL TESTS PASSED ***\n");
        end else begin
            $display("\n*** %0d TEST(S) FAILED ***\n", errors);
        end
        
        $display("================================================================================\n");
        
        $stop;
    end
    
    // ========================================================================
    // Timeout watchdog
    // ========================================================================
    initial begin
        #100ms;
        $display("\n*** GLOBAL TIMEOUT - SIMULATION TERMINATED ***\n");
        $stop;
    end

endmodule