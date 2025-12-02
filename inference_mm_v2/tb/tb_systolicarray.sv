// Simple Testbench - Writes to BRAMs using normal write interface
// Flow: Write to BRAM A/B -> Load to registers -> Compute -> Write results to BRAM C

`timescale 1ns/1ps

module tb_matmul_simple;

    localparam int N = 16;
    localparam int CLK_PERIOD = 10;
    
    // Clock and reset
    logic clk;
    logic rst;
    
    // BRAM A interface (16 banks)
    logic [15:0][7:0] bram_a_addr;
    logic [15:0][7:0] bram_a_wdata;
    logic [15:0]      bram_a_wren;
    logic [15:0][7:0] bram_a_rdata;
    
    // BRAM B interface (16 banks)
    logic [15:0][7:0] bram_b_addr;
    logic [15:0][7:0] bram_b_wdata;
    logic [15:0]      bram_b_wren;
    logic [15:0][7:0] bram_b_rdata;
    
    // BRAM C interface (16 banks)
    logic [15:0][7:0]  bram_c_addr;
    logic [15:0][31:0] bram_c_wdata;
    logic [15:0]       bram_c_wren;
    logic [15:0][31:0] bram_c_rdata;
    
    // Registers for A and B matrices
    logic [N-1:0][N-1:0][7:0] reg_a;
    logic [N-1:0][N-1:0][7:0] reg_b;
    
    // Systolic array interface
    logic                       systolic_valid_in;
    logic [N-1:0][N-1:0][31:0]  systolic_out_c;
    logic                       systolic_valid_out;
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // Instantiate BRAM banks for Matrix A
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : bram_a_banks
            bram u_bram_a (
                .address_a  (bram_a_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_a_wdata[i]),
                .data_b     (8'h00),
                .wren_a     (bram_a_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_a_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // Instantiate BRAM banks for Matrix B
    generate
        for (i = 0; i < 16; i++) begin : bram_b_banks
            bram u_bram_b (
                .address_a  (bram_b_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_b_wdata[i]),
                .data_b     (8'h00),
                .wren_a     (bram_b_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_b_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // Instantiate BRAM banks for output Matrix C
    generate
        for (i = 0; i < 16; i++) begin : bram_c_banks
            bramc u_bram_c (
                .address_a  (bram_c_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_c_wdata[i]),
                .data_b     (32'h00000000),
                .wren_a     (bram_c_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_c_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // Instantiate systolic array
    topSystolicArray #(.N(N)) u_systolic (
        .clk        (clk),
        .rst        (rst),
        .in_valid   (systolic_valid_in),
        .in_a       (reg_a),
        .in_b       (reg_b),
        .out_c      (systolic_out_c),
        .out_valid  (systolic_valid_out)
    );
    
    // Task to write to BRAM A
    task write_bram_a(input int row, input int col, input logic [7:0] data);
        @(posedge clk);
        bram_a_addr[col] = row;
        bram_a_wdata[col] = data;
        bram_a_wren[col] = 1'b1;
        @(posedge clk);
        bram_a_wren[col] = 1'b0;
    endtask
    
    // Task to write to BRAM B
    task write_bram_b(input int row, input int col, input logic [7:0] data);
        @(posedge clk);
        bram_b_addr[col] = row;
        bram_b_wdata[col] = data;
        bram_b_wren[col] = 1'b1;
        @(posedge clk);
        bram_b_wren[col] = 1'b0;
    endtask
    
    // Main test sequence
    initial begin
        int errors;
        int expected;
        int actual;
        
        $display("=== Simple Matrix Multiplication Test ===");
        $display("Matrix size: %0d x %0d\n", N, N);
        
        // Initialize signals
        rst = 0;
        systolic_valid_in = 0;
        bram_a_addr = '0;
        bram_a_wdata = '0;
        bram_a_wren = '0;
        bram_b_addr = '0;
        bram_b_wdata = '0;
        bram_b_wren = '0;
        bram_c_addr = '0;
        bram_c_wdata = '0;
        bram_c_wren = '0;
        
        // Reset
        #(CLK_PERIOD * 2);
        rst = 1;
        #(CLK_PERIOD * 2);
        
        $display("[%0t] Step 1: Writing test matrices to BRAM A and B", $time);
        $display("           Matrix A: Identity matrix");
        $display("           Matrix B: B[i][j] = i - j (signed int8)");
        
        // Write Identity matrix to BRAM A (only diagonal elements)
        for (int i = 0; i < N; i++) begin
            write_bram_a(i, i, 8'd1);  // A[i][i] = 1
        end
        
        // Write Matrix B: B[row][col] = row - col
        for (int row = 0; row < N; row++) begin
            for (int col = 0; col < N; col++) begin
                write_bram_b(row, col, 8'(signed'(row - col)));
            end
        end
        
        $display("[%0t] Step 2: Loading matrices from BRAM into registers", $time);
        
        // Load all rows from BRAM A and B into registers
        for (int row = 0; row < N; row++) begin
            // Set address = row for all banks to get entire row
            for (int bank = 0; bank < N; bank++) begin
                bram_a_addr[bank] = {4'b0, 4'(row)};
                bram_b_addr[bank] = {4'b0, 4'(row)};
            end
            
            @(posedge clk);
            @(posedge clk);  // Wait for BRAM read latency
            
            // Capture data into registers
            for (int col = 0; col < N; col++) begin
                reg_a[row][col] = bram_a_rdata[col];
                reg_b[row][col] = bram_b_rdata[col];
            end
        end
        
        $display("[%0t] Step 3: Starting systolic array computation", $time);
        
        // Start computation
        @(posedge clk);
        systolic_valid_in = 1;
        @(posedge clk);
        systolic_valid_in = 0;
        
        $display("[%0t] Step 4: Waiting for computation to complete...", $time);
        
        // Wait for valid output
        @(posedge systolic_valid_out);
        @(posedge clk);
        
        $display("[%0t] Step 5: Writing results to BRAM C", $time);
        $display("           (PE holds values stable since process=0)");
        
        // Write all results from systolic array output to BRAM C
        // Each row written in parallel across 16 banks
        for (int row = 0; row < N; row++) begin
            for (int col = 0; col < N; col++) begin
                bram_c_addr[col] = {4'b0, 4'(row)};
                bram_c_wdata[col] = systolic_out_c[row][col];
                bram_c_wren[col] = 1;
            end
            @(posedge clk);
        end
        
        bram_c_wren = '0;
        @(posedge clk);
        @(posedge clk);
        
        $display("[%0t] Step 6: Reading back and verifying results\n", $time);
        
        // Read back and verify
        errors = 0;
        for (int row = 0; row < N; row++) begin
            // Set read address for all banks
            for (int col = 0; col < N; col++) begin
                bram_c_addr[col] = {4'b0, 4'(row)};
            end
            @(posedge clk);
            @(posedge clk);  // Wait for read latency
            
            // Check all columns for this row
            for (int col = 0; col < N; col++) begin
                expected = row - col;
                actual = $signed(bram_c_rdata[col]);
                
                if (actual != expected) begin
                    $display("ERROR at [%0d][%0d]: Expected %0d, Got %0d", 
                             row, col, expected, actual);
                    errors++;
                    if (errors >= 10) begin
                        $display("... (stopping after 10 errors)");
                        break;
                    end
                end
            end
            if (errors >= 10) break;
        end
        
        if (errors == 0) begin
            $display("? All %0d results correct!", N*N);
        end else begin
            $display("? Found %0d errors", errors);
        end
        
        #(CLK_PERIOD * 10);
        $display("\n=== Test Complete ===");
        $finish;
    end
    
    // Timeout
    initial begin
        #(CLK_PERIOD * 100000);
        $display("ERROR: Timeout!");
        $finish;
    end

endmodule