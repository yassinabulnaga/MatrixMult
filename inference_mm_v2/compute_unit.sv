module compute_unit #(
    parameter int N = 16
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       start,
    output logic       done
);

    // Address parameters
    localparam int ADDR_MAX = N*N;              // 256
    localparam int ADDR_W = $clog2(ADDR_MAX);   // 8

    // FSM states
    typedef enum logic [1:0] {
        IDLE,
        LOAD_MATRICES,
        COMPUTE,
        STORE_RESULT
    } state_t;
    
    state_t state_q, state_d;
    
    // Counter - needs extra bit to count to 256
    logic [ADDR_W:0] addr_cnt_d, addr_cnt_q;  // 9 bits to handle 0-256
    
    // BRAM A signals (8-bit input data) - SINGLE PORT
    logic [ADDR_W-1:0] bram_a_addr;
    logic [7:0]        bram_a_data;
    logic              bram_a_wren;
    logic [7:0]        bram_a_q;
    
    // BRAM B signals (8-bit input data) - SINGLE PORT
    logic [ADDR_W-1:0] bram_b_addr;
    logic [7:0]        bram_b_data;
    logic              bram_b_wren;
    logic [7:0]        bram_b_q;
    
    // BRAM C signals (32-bit output data) - SINGLE PORT
    logic [ADDR_W-1:0] bram_c_addr;
    logic [31:0]       bram_c_data;
    logic              bram_c_wren;
    logic [31:0]       bram_c_q;
    
    // Delayed address register to track which address produced current q value
    logic [ADDR_W-1:0] bram_a_addr_q;
    logic [ADDR_W-1:0] bram_b_addr_q;
    
    // Register matrices for A and B
    logic [N-1:0][N-1:0][7:0] reg_matrix_a_d, reg_matrix_a_q;
    logic [N-1:0][N-1:0][7:0] reg_matrix_b_d, reg_matrix_b_q;
    
    // Systolic array interface
    logic                       sa_in_valid;
    logic [N-1:0][N-1:0][31:0]  sa_out_c;
    logic                       sa_out_valid;
    
    // BRAM instantiations - SINGLE PORT
    bram_a bram_a_inst (
        .clock     (clk),
        .address   (bram_a_addr),
        .data      (bram_a_data),
        .wren      (bram_a_wren),
        .q         (bram_a_q)
    );
    
    bram_b bram_b_inst (
        .clock     (clk),
        .address   (bram_b_addr),
        .data      (bram_b_data),
        .wren      (bram_b_wren),
        .q         (bram_b_q)
    );
    
    bram_c bram_c_inst (
        .clock     (clk),
        .address   (bram_c_addr),
        .data      (bram_c_data),
        .wren      (bram_c_wren),
        .q         (bram_c_q)
    );
    
    // Systolic array instantiation
    topSystolicArray #(.N(N)) systolic_array_inst (
        .clk       (clk),
        .rst       (rst),
        .in_valid  (sa_in_valid),
        .in_a      (reg_matrix_a_q),
        .in_b      (reg_matrix_b_q),
        .out_c     (sa_out_c),
        .out_valid (sa_out_valid)
    );
    
    // State and counter registers
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            state_q        <= IDLE;
            addr_cnt_q     <= '0;
            reg_matrix_a_q <= '0;
            reg_matrix_b_q <= '0;
            bram_a_addr_q  <= '0;
            bram_b_addr_q  <= '0;
        end else begin
            state_q        <= state_d;
            addr_cnt_q     <= addr_cnt_d;
            reg_matrix_a_q <= reg_matrix_a_d;
            reg_matrix_b_q <= reg_matrix_b_d;
            // Track address for BRAM read latency
            bram_a_addr_q  <= bram_a_addr;
            bram_b_addr_q  <= bram_b_addr;
        end
    end
    
    // Decode coordinates from delayed addresses (these match current q values)
    logic [3:0] row_a, col_a;
    logic [3:0] row_b, col_b;
    logic [3:0] row_c, col_c;
    
    always_comb begin
        // For loading (delayed addresses match current q outputs)
        row_a = bram_a_addr_q[7:4];
        col_a = bram_a_addr_q[3:0];
        
        row_b = bram_b_addr_q[7:4];
        col_b = bram_b_addr_q[3:0];
        
        // For storing (current counter)
        row_c = addr_cnt_q[7:4];
        col_c = addr_cnt_q[3:0];
    end
    
    // FSM and control logic
    always_comb begin
        // Default assignments
        state_d        = state_q;
        addr_cnt_d     = addr_cnt_q;
        reg_matrix_a_d = reg_matrix_a_q;
        reg_matrix_b_d = reg_matrix_b_q;
        
        // BRAM A control defaults (prevent truncation at 256)
        if (addr_cnt_q < ADDR_MAX) begin
            bram_a_addr  = addr_cnt_q[ADDR_W-1:0];
        end else begin
            bram_a_addr  = '0;  // Safe default when counter >= 256
        end
        bram_a_data  = '0;
        bram_a_wren  = 1'b0;
        
        // BRAM B control defaults
        if (addr_cnt_q < ADDR_MAX) begin
            bram_b_addr  = addr_cnt_q[ADDR_W-1:0];
        end else begin
            bram_b_addr  = '0;
        end
        bram_b_data  = '0;
        bram_b_wren  = 1'b0;
        
        // BRAM C control defaults
        if (addr_cnt_q < ADDR_MAX) begin
            bram_c_addr  = addr_cnt_q[ADDR_W-1:0];
        end else begin
            bram_c_addr  = '0;
        end
        bram_c_data  = '0;
        bram_c_wren  = 1'b0;
        
        sa_in_valid  = 1'b0;
        done         = 1'b0;
        
        case (state_q)
            IDLE: begin
                addr_cnt_d = '0;
                if (start) begin
                    state_d = LOAD_MATRICES;
                end
            end
            
            LOAD_MATRICES: begin
                // Issue addresses for 0..255, then move to COMPUTE
                if (addr_cnt_q < ADDR_MAX) begin
                    // Cycle 0-255: increment counter, issue reads
                    addr_cnt_d = addr_cnt_q + 1;
                end else begin
                    // Cycle 256: captured last data (addr 255), move to COMPUTE
                    addr_cnt_d = addr_cnt_q;
                    state_d = COMPUTE;
                end
                
                // Capture BRAM data into matrices (delayed address matches current q value)
                if (bram_a_addr_q < ADDR_MAX) begin
                    reg_matrix_a_d[row_a][col_a] = bram_a_q;
                end
                
                if (bram_b_addr_q < ADDR_MAX) begin
                    reg_matrix_b_d[row_b][col_b] = bram_b_q;
                end
            end
            
            COMPUTE: begin
                // Trigger systolic array computation and reset counter
                sa_in_valid = 1'b1;
                addr_cnt_d = '0;
                state_d = STORE_RESULT;
            end
            
            STORE_RESULT: begin
                // Default: no write
                bram_c_wren = 1'b0;
                bram_c_data = sa_out_c[row_c][col_c];  // Set data for current address
                
                if (!sa_out_valid && addr_cnt_q == '0) begin
                    // Case 1: Waiting for systolic array to finish
                    addr_cnt_d = '0;
                    
                end else if (sa_out_valid && addr_cnt_q == '0) begin
                    // Case 2: First cycle when sa_out_valid goes high
                    bram_c_wren = 1'b1;
                    addr_cnt_d = 9'd1;
                    
                end else if (addr_cnt_q < ADDR_MAX) begin
                    // Case 3: Continue writing results (one per cycle)
                    bram_c_wren = 1'b1;
                    addr_cnt_d = addr_cnt_q + 1;
                    
                end else begin
                    // Case 4: Finished writing all N*N entries
                    state_d = IDLE;
                    done = 1'b1;
                end
            end
            
            default: state_d = IDLE;
        endcase
    end

endmodule