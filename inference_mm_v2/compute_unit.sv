module compute_unit #(
    parameter int N = 16
)(
    input  logic       clk,
    input  logic       rst,
    input  logic       start,
    output logic       done
);

    // FSM states
    typedef enum logic [1:0] {
        IDLE,
        LOAD_MATRICES,
        COMPUTE,
        STORE_RESULT
    } state_t;
    
    state_t state_q, state_d;
    
    // Counter for loading and storing
    logic [7:0] addr_cnt_d, addr_cnt_q;
    
    // BRAM A signals (8-bit input data)
    logic [7:0] bram_a_addr_a, bram_a_addr_b;
    logic [7:0] bram_a_data_a, bram_a_data_b;
    logic       bram_a_wren_a, bram_a_wren_b;
    logic [7:0] bram_a_q_a, bram_a_q_b;
    
    // BRAM B signals (8-bit input data)
    logic [7:0] bram_b_addr_a, bram_b_addr_b;
    logic [7:0] bram_b_data_a, bram_b_data_b;
    logic       bram_b_wren_a, bram_b_wren_b;
    logic [7:0] bram_b_q_a, bram_b_q_b;
    
    // BRAM C signals (32-bit output data)
    logic [7:0]  bram_c_addr_a, bram_c_addr_b;
    logic [31:0] bram_c_data_a, bram_c_data_b;
    logic        bram_c_wren_a, bram_c_wren_b;
    logic [31:0] bram_c_q_a, bram_c_q_b;
    
    // Register matrices for A and B
    logic [N-1:0][N-1:0][7:0] reg_matrix_a_d, reg_matrix_a_q;
    logic [N-1:0][N-1:0][7:0] reg_matrix_b_d, reg_matrix_b_q;
    
    // Systolic array interface
    logic                       sa_in_valid;
    logic [N-1:0][N-1:0][31:0]  sa_out_c;
    logic                       sa_out_valid;
    
    // BRAM instantiations
    bram_a bram_a_inst (
        .clock     (clk),
        .address_a (bram_a_addr_a),
        .address_b (bram_a_addr_b),
        .data_a    (bram_a_data_a),
        .data_b    (bram_a_data_b),
        .wren_a    (bram_a_wren_a),
        .wren_b    (bram_a_wren_b),
        .q_a       (bram_a_q_a),
        .q_b       (bram_a_q_b)
    );
    
    bram_b bram_b_inst (
        .clock     (clk),
        .address_a (bram_b_addr_a),
        .address_b (bram_b_addr_b),
        .data_a    (bram_b_data_a),
        .data_b    (bram_b_data_b),
        .wren_a    (bram_b_wren_a),
        .wren_b    (bram_b_wren_b),
        .q_a       (bram_b_q_a),
        .q_b       (bram_b_q_b)
    );
    
    bram_c bram_c_inst (
        .clock     (clk),
        .address_a (bram_c_addr_a),
        .address_b (bram_c_addr_b),
        .data_a    (bram_c_data_a),
        .data_b    (bram_c_data_b),
        .wren_a    (bram_c_wren_a),
        .wren_b    (bram_c_wren_b),
        .q_a       (bram_c_q_a),
        .q_b       (bram_c_q_b)
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
        end else begin
            state_q        <= state_d;
            addr_cnt_q     <= addr_cnt_d;
            reg_matrix_a_q <= reg_matrix_a_d;
            reg_matrix_b_q <= reg_matrix_b_d;
        end
    end
    
    // FSM and control logic
    logic [7:0] addr_a_prev, addr_b_prev, addr_c_a, addr_c_b;
    logic [3:0] row_a, col_a, row_b, col_b, row_c_a, col_c_a, row_c_b, col_c_b;
    
    always_comb begin
        // Default assignments
        state_d        = state_q;
        addr_cnt_d     = addr_cnt_q;
        reg_matrix_a_d = reg_matrix_a_q;
        reg_matrix_b_d = reg_matrix_b_q;
        
        // BRAM control defaults
        bram_a_addr_a  = addr_cnt_q;
        bram_a_addr_b  = addr_cnt_q + 1;
        bram_a_data_a  = '0;
        bram_a_data_b  = '0;
        bram_a_wren_a  = 1'b0;
        bram_a_wren_b  = 1'b0;
        
        bram_b_addr_a  = addr_cnt_q;
        bram_b_addr_b  = addr_cnt_q + 1;
        bram_b_data_a  = '0;
        bram_b_data_b  = '0;
        bram_b_wren_a  = 1'b0;
        bram_b_wren_b  = 1'b0;
        
        // Parse addresses for BRAM C indexing
        addr_c_a   = addr_cnt_q;
        addr_c_b   = addr_cnt_q + 1;
        row_c_a    = addr_c_a[7:4];
        col_c_a    = addr_c_a[3:0];
        row_c_b    = addr_c_b[7:4];
        col_c_b    = addr_c_b[3:0];
        
        bram_c_addr_a  = addr_cnt_q;
        bram_c_addr_b  = addr_cnt_q + 1;
        bram_c_data_a  = sa_out_c[row_c_a][col_c_a];
        bram_c_data_b  = sa_out_c[row_c_b][col_c_b];
        bram_c_wren_a  = 1'b0;
        bram_c_wren_b  = 1'b0;
        
        sa_in_valid    = 1'b0;
        done           = 1'b0;
        
        // Address parsing for matrix loading
        addr_a_prev = addr_cnt_q - 1;
        addr_b_prev = addr_cnt_q;
        row_a = addr_a_prev[7:4];
        col_a = addr_a_prev[3:0];
        row_b = addr_b_prev[7:4];
        col_b = addr_b_prev[3:0];
        
        case (state_q)
            IDLE: begin
                addr_cnt_d = '0;
                if (start) begin
                    state_d = LOAD_MATRICES;
                end
            end
            
            LOAD_MATRICES: begin
                // Load matrices from BRAM using dual-port reads
                // BRAM stores row-major: addr=row*16+col maps to matrix[row][col]
                // addr[7:4] = row, addr[3:0] = col
                if (addr_cnt_q < N*N) begin
                    addr_cnt_d = addr_cnt_q + 2;
                end else if (addr_cnt_q >= N*N && addr_cnt_q < N*N + 2) begin
                    // Wait one more cycle to capture last data
                    addr_cnt_d = addr_cnt_q + 1;
                end else begin
                    // All data captured, transition to compute
                    addr_cnt_d = '0;
                    state_d = COMPUTE;
                end
                
                // Capture data (with 1-cycle BRAM read latency)
                if (addr_cnt_q >= 1 && addr_cnt_q <= N*N + 1) begin
                    if (addr_a_prev < N*N) begin
                        reg_matrix_a_d[row_a][col_a] = bram_a_q_a;
                        reg_matrix_b_d[row_a][col_a] = bram_b_q_a;
                    end
                    
                    if (addr_b_prev < N*N) begin
                        reg_matrix_a_d[row_b][col_b] = bram_a_q_b;
                        reg_matrix_b_d[row_b][col_b] = bram_b_q_b;
                    end
                end
            end
            
            COMPUTE: begin
                // Trigger systolic array computation
                sa_in_valid = 1'b1;
                state_d = STORE_RESULT;
            end
            
            STORE_RESULT: begin
                // Wait for computation to complete
                if (sa_out_valid) begin
                    addr_cnt_d = '0;
                    // Start writing results to BRAM C
                end
                
                // Write results to BRAM C using dual-port writes
                if (sa_out_valid || addr_cnt_q > 0) begin
                    if (addr_cnt_q < N*N) begin
                        bram_c_wren_a = 1'b1;
                        if (addr_cnt_q + 1 < N*N) begin
                            bram_c_wren_b = 1'b1;
                        end
                        addr_cnt_d = addr_cnt_q + 2;
                    end else begin
                        state_d = IDLE;
                        done = 1'b1;
                    end
                end
            end
            
            default: state_d = IDLE;
        endcase
    end

endmodule
