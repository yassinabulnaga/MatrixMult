// Compute Module - Loads BRAM -> Systolic Array -> Writes BRAM C

module compute_unit #(
    parameter int N = 16
)(
    input  logic        clk,
    input  logic        rst,
    
    // Control
    input  logic        start,
    output logic        done,
    
    // BRAM A interface (read only)
    output logic [15:0][7:0] bram_a_addr,
    input  logic [15:0][7:0] bram_a_rdata,
    
    // BRAM B interface (read only)
    output logic [15:0][7:0] bram_b_addr,
    input  logic [15:0][7:0] bram_b_rdata,
    
    // BRAM C interface (write only)
    output logic [15:0][7:0]  bram_c_addr,
    output logic [15:0][31:0] bram_c_wdata,
    output logic [15:0]       bram_c_wren
);

    typedef enum logic [2:0] {
        IDLE,
        LOAD,
        COMPUTE,
        WAIT_RESULT,
        STORE,
        DONE
    } state_t;
    
    state_t state_d, state_q;
    
    logic [3:0] load_cnt_d, load_cnt_q;
    logic [3:0] store_row_d, store_row_q;
    
    // Registers for matrices
    logic [N-1:0][N-1:0][7:0] reg_a_d, reg_a_q;
    logic [N-1:0][N-1:0][7:0] reg_b_d, reg_b_q;
    
    // Systolic array signals
    logic                       systolic_valid_in;
    logic [N-1:0][N-1:0][31:0]  systolic_out_c;
    logic                       systolic_valid_out;
    
    // Instantiate systolic array
    topSystolicArray #(.N(N)) u_systolic (
        .clk        (clk),
        .rst        (rst),
        .in_valid   (systolic_valid_in),
        .in_a       (reg_a_q),
        .in_b       (reg_b_q),
        .out_c      (systolic_out_c),
        .out_valid  (systolic_valid_out)
    );
    
    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            state_q <= IDLE;
            load_cnt_q <= '0;
            store_row_q <= '0;
            reg_a_q <= '0;
            reg_b_q <= '0;
        end else begin
            state_q <= state_d;
            load_cnt_q <= load_cnt_d;
            store_row_q <= store_row_d;
            reg_a_q <= reg_a_d;
            reg_b_q <= reg_b_d;
        end
    end
    
    always_comb begin
        // Defaults
        state_d = state_q;
        load_cnt_d = load_cnt_q;
        store_row_d = store_row_q;
        reg_a_d = reg_a_q;
        reg_b_d = reg_b_q;
        
        bram_a_addr = '0;
        bram_b_addr = '0;
        bram_c_addr = '0;
        bram_c_wdata = '0;
        bram_c_wren = '0;
        
        systolic_valid_in = 1'b0;
        done = 1'b0;
        
        case (state_q)
            IDLE: begin
                if (start) begin
                    state_d = LOAD;
                    load_cnt_d = '0;
                end
            end
            
            LOAD: begin
                // Request read for current row from all banks
                for (int i = 0; i < N; i++) begin
                    bram_a_addr[i] = {4'b0, load_cnt_q};
                    bram_b_addr[i] = {4'b0, load_cnt_q};
                end
                
                // Capture data (account for 1-cycle BRAM delay)
                if (load_cnt_q > 0) begin
                    for (int i = 0; i < N; i++) begin
                        reg_a_d[load_cnt_q-1][i] = bram_a_rdata[i];
                        reg_b_d[load_cnt_q-1][i] = bram_b_rdata[i];
                    end
                end
                
                load_cnt_d = load_cnt_q + 1;
                
                // Need N+1 cycles (N for addresses, 1 extra for last read)
                if (load_cnt_q == N) begin
                    // Capture last row
                    for (int i = 0; i < N; i++) begin
                        reg_a_d[N-1][i] = bram_a_rdata[i];
                        reg_b_d[N-1][i] = bram_b_rdata[i];
                    end
                    state_d = COMPUTE;
                end
            end
            
            COMPUTE: begin
                systolic_valid_in = 1'b1;
                state_d = WAIT_RESULT;
            end
            
            WAIT_RESULT: begin
                if (systolic_valid_out) begin
                    state_d = STORE;
                    store_row_d = '0;
                end
            end
            
            STORE: begin
                // Write entire row in parallel to all 16 banks
                for (int col = 0; col < N; col++) begin
                    bram_c_addr[col] = {4'b0, store_row_q};
                    bram_c_wdata[col] = systolic_out_c[store_row_q][col];
                    bram_c_wren[col] = 1'b1;
                end
                
                if (store_row_q == N-1) begin
                    state_d = DONE;
                end else begin
                    store_row_d = store_row_q + 1;
                end
            end
            
            DONE: begin
                done = 1'b1;
                state_d = IDLE;
            end
        endcase
    end

endmodule