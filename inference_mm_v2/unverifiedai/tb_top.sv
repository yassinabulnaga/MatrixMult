// Testbench for Matrix Multiply Accelerator
// Simulates DDR memory and tests complete flow

`timescale 1ns/1ps

module tb_matmul_accelerator;

    localparam int N = 16;
    localparam int CLK_PERIOD = 10;
    
    // DUT signals
    logic        clk;
    logic        rst;
    logic        start;
    logic [31:0] ddr_addr_a;
    logic [31:0] ddr_addr_b;
    logic [31:0] ddr_addr_c;
    logic        complete;
    logic        busy;
    
    // Avalon-MM signals
    logic [31:0] avm_address;
    logic        avm_read;
    logic        avm_write;
    logic [31:0] avm_writedata;
    logic [31:0] avm_readdata;
    logic        avm_readdatavalid;
    logic        avm_waitrequest;
    logic [3:0]  avm_byteenable;
    
    // DDR memory model (byte-addressable)
    logic [7:0] ddr_mem [0:65535];  // 64KB for testing
    
    // Clock generation
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end
    
    // DDR memory model with Avalon-MM interface
    logic [31:0] read_data_q;
    logic        read_valid_q;
    
    // Assign outputs
    assign avm_waitrequest = 1'b0;  // No wait for simplicity
    assign avm_readdata = read_data_q;
    assign avm_readdatavalid = read_valid_q;
    
    // Handle reads and writes
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            read_data_q <= '0;
            read_valid_q <= 1'b0;
            
            // Initialize DDR memory during reset
            for (int i = 0; i < 65536; i++) begin
                ddr_mem[i] <= 8'h00;
            end
            
            // Write Identity matrix A to DDR (row-major, packed)
            for (int row = 0; row < N; row++) begin
                for (int col = 0; col < N; col++) begin
                    ddr_mem[32'h0000 + row*N + col] <= (row == col) ? 8'd1 : 8'd0;
                end
            end
            
            // Write matrix B to DDR: B[row][col] = row - col
            for (int row = 0; row < N; row++) begin
                for (int col = 0; col < N; col++) begin
                    ddr_mem[32'h0100 + row*N + col] <= 8'(signed'(row - col));
                end
            end
        end else begin
            // Handle reads
            read_valid_q <= avm_read;
            if (avm_read) begin
                read_data_q <= {ddr_mem[avm_address+3], 
                               ddr_mem[avm_address+2], 
                               ddr_mem[avm_address+1], 
                               ddr_mem[avm_address]};
            end
            
            // Handle writes
            if (avm_write) begin
                if (avm_byteenable[0]) ddr_mem[avm_address]   <= avm_writedata[7:0];
                if (avm_byteenable[1]) ddr_mem[avm_address+1] <= avm_writedata[15:8];
                if (avm_byteenable[2]) ddr_mem[avm_address+2] <= avm_writedata[23:16];
                if (avm_byteenable[3]) ddr_mem[avm_address+3] <= avm_writedata[31:24];
            end
        end
    end
    
    // DUT instantiation
    matmul_accelerator #(.N(N)) dut (
        .clk                (clk),
        .rst                (rst),
        .start              (start),
        .ddr_addr_a         (ddr_addr_a),
        .ddr_addr_b         (ddr_addr_b),
        .ddr_addr_c         (ddr_addr_c),
        .complete           (complete),
        .busy               (busy),
        .avm_address        (avm_address),
        .avm_read           (avm_read),
        .avm_write          (avm_write),
        .avm_writedata      (avm_writedata),
        .avm_readdata       (avm_readdata),
        .avm_readdatavalid  (avm_readdatavalid),
        .avm_waitrequest    (avm_waitrequest),
        .avm_byteenable     (avm_byteenable)
    );
    
    // Test
    initial begin
        int errors;
        logic signed [7:0] expected;
        logic signed [31:0] actual;
        
        $display("=== Matrix Multiply Accelerator Test ===\n");
        
        // Initialize control signals
        rst = 0;
        start = 0;
        ddr_addr_a = 32'h0000;
        ddr_addr_b = 32'h0100;
        ddr_addr_c = 32'h0200;
        
        $display("Writing test matrices to DDR memory:");
        $display("  Matrix A: Identity (16x16 int8)");
        $display("  Matrix B: B[i][j] = i - j (16x16 int8)\n");
        
        // Reset (DDR memory initializes during reset)
        #(CLK_PERIOD * 2);
        rst = 1;
        #(CLK_PERIOD * 2);
        
        $display("[%0t] Starting accelerator...", $time);
        
        // Start operation
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Wait for completion
        @(posedge complete);
        #(CLK_PERIOD * 2);
        
        $display("[%0t] Accelerator complete!\n", $time);
        
        // Verify results in DDR
        $display("Verifying results in DDR memory:");
        errors = 0;
        for (int row = 0; row < N; row++) begin
            for (int col = 0; col < N; col++) begin
                expected = row - col;
                // Read 32-bit result from DDR (little-endian)
                actual = {ddr_mem[ddr_addr_c + (row*N+col)*4 + 3],
                         ddr_mem[ddr_addr_c + (row*N+col)*4 + 2],
                         ddr_mem[ddr_addr_c + (row*N+col)*4 + 1],
                         ddr_mem[ddr_addr_c + (row*N+col)*4]};
                
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
            $display("✓ All %0d results correct!", N*N);
        end else begin
            $display("✗ Found %0d errors", errors);
        end
        
        #(CLK_PERIOD * 10);
        $display("\n=== Test Complete ===");
        $finish;
    end
    
    // Timeout
    initial begin
        #(CLK_PERIOD * 1000000);
        $display("ERROR: Timeout!");
        $finish;
    end

endmodule