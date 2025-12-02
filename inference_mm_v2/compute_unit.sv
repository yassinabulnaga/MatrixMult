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
    
    // Delayed address registers to track which address produced current q values
    logic [7:0] bram_a_addr_a_q, bram_a_addr_b_q;
    logic [7:0] bram_b_addr_a_q, bram_b_addr_b_q;
    
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
            bram_a_addr_a_q <= '0;
            bram_a_addr_b_q <= '0;
            bram_b_addr_a_q <= '0;
            bram_b_addr_b_q <= '0;
        end else begin
            state_q        <= state_d;
            addr_cnt_q     <= addr_cnt_d;
            reg_matrix_a_q <= reg_matrix_a_d;
            reg_matrix_b_q <= reg_matrix_b_d;
            // Track addresses for BRAM read latency
            bram_a_addr_a_q <= bram_a_addr_a;
            bram_a_addr_b_q <= bram_a_addr_b;
            bram_b_addr_a_q <= bram_b_addr_a;
            bram_b_addr_b_q <= bram_b_addr_b;
        end
    end
    
    // Decode coordinates from delayed addresses (these match current q values)
    logic [3:0] row_a_a, col_a_a, row_a_b, col_a_b;
    logic [3:0] row_b_a, col_b_a, row_b_b, col_b_b;
    logic [3:0] row_c_a, col_c_a, row_c_b, col_c_b;
    
    always_comb begin
        // For loading (delayed addresses match current q outputs)
        row_a_a = bram_a_addr_a_q[7:4];
        col_a_a = bram_a_addr_a_q[3:0];
        row_a_b = bram_a_addr_b_q[7:4];
        col_a_b = bram_a_addr_b_q[3:0];
        
        row_b_a = bram_b_addr_a_q[7:4];
        col_b_a = bram_b_addr_a_q[3:0];
        row_b_b = bram_b_addr_b_q[7:4];
        col_b_b = bram_b_addr_b_q[3:0];
        
        // For storing (current counter)
        row_c_a = addr_cnt_q[7:4];
        col_c_a = addr_cnt_q[3:0];
        row_c_b = (addr_cnt_q + 1)[7:4];
        col_c_b = (addr_cnt_q + 1)[3:0];
    end
    
    // FSM and control logic
    always_comb begin
        // Default assignments
        state_d        = state_q;
        addr_cnt_d     = addr_cnt_q;
        reg_matrix_a_d = reg_matrix_a_q;
        reg_matrix_b_d = reg_matrix_b_q;
        
        // BRAM A control defaults
        bram_a_addr_a  = addr_cnt_q[7:0];
        bram_a_addr_b  = addr_cnt_q[7:0] + 1;
        bram_a_data_a  = '0;
        bram_a_data_b  = '0;
        bram_a_wren_a  = 1'b0;
        bram_a_wren_b  = 1'b0;
        
        // BRAM B control defaults
        bram_b_addr_a  = addr_cnt_q[7:0];
        bram_b_addr_b  = addr_cnt_q[7:0] + 1;
        bram_b_data_a  = '0;
        bram_b_data_b  = '0;
        bram_b_wren_a  = 1'b0;
        bram_b_wren_b  = 1'b0;
        
        // BRAM C control defaults
        bram_c_addr_a  = addr_cnt_q[7:0];
        bram_c_addr_b  = addr_cnt_q[7:0] + 1;
        bram_c_data_a  = sa_out_c[row_c_a][col_c_a];
        bram_c_data_b  = sa_out_c[row_c_b][col_c_b];
        bram_c_wren_a  = 1'b0;
        bram_c_wren_b  = 1'b0;
        
        sa_in_valid    = 1'b0;
        done           = 1'b0;
        
        case (state_q)
            IDLE: begin
                addr_cnt_d = '0;
                if (start) begin
                    state_d = LOAD_MATRICES;
                end
            end
            
            LOAD_MATRICES: begin
                // Advance addresses while we still have elements to read
                if (addr_cnt_q < ADDR_MAX - 1) begin
                    addr_cnt_d = addr_cnt_q + 2;  // Two elements per cycle
                end else begin
                    // Stop incrementing, do one more cycle to capture last data
                    addr_cnt_d = addr_cnt_q;
                    state_d = COMPUTE;
                end
                
                // Capture BRAM data into matrices (delayed addresses match current q values)
                if (bram_a_addr_a_q < ADDR_MAX) begin
                    reg_matrix_a_d[row_a_a][col_a_a] = bram_a_q_a;
                end
                if (bram_a_addr_b_q < ADDR_MAX) begin
                    reg_matrix_a_d[row_a_b][col_a_b] = bram_a_q_b;
                end
                
                if (bram_b_addr_a_q < ADDR_MAX) begin
                    reg_matrix_b_d[row_b_a][col_b_a] = bram_b_q_a;
                end
                if (bram_b_addr_b_q < ADDR_MAX) begin
                    reg_matrix_b_d[row_b_b][col_b_b] = bram_b_q_b;
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
                end
                
                // Write results to BRAM C using dual-port writes
                if (sa_out_valid || addr_cnt_q > 0) begin
                    if (addr_cnt_q < ADDR_MAX) begin
                        bram_c_wren_a = 1'b1;
                        if (addr_cnt_q + 1 < ADDR_MAX) begin
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