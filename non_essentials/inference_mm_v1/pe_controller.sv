// PE Controller - FIXED to match reference working implementation
// Writes BRAM C one element at a time (row-major: bank=row, addr=col)

import mm_pkg::*;

module pe_controller #(
    parameter int T = mm_pkg::T,
    parameter int W = mm_pkg::W,
    parameter int ACCW = mm_pkg::ACCW,
    parameter int BRAM_AW = 8
)(
    input  logic clk,
    input  logic rst_n,
    input  logic start,
    output logic done,
    
    // BRAM A read
    output logic [BRAM_AW-1:0] bram_a_addr,
    output logic               bram_a_en,
    input  logic [T*W-1:0]     bram_a_rdata,
    
    // BRAM B read
    output logic [BRAM_AW-1:0] bram_b_addr,
    output logic               bram_b_en,
    input  logic [T*W-1:0]     bram_b_rdata,
    
    // BRAM C write - ONE ELEMENT AT A TIME
    output logic [T-1:0]               bram_c_en,     // One-hot per bank
    output logic [T-1:0]               bram_c_we,     // One-hot per bank
    output logic [T-1:0][BRAM_AW-1:0]  bram_c_addr,   // Per-bank address
    output logic [T-1:0][ACCW-1:0]     bram_c_wdata,  // Per-bank data (32-bit)
    
    // PE Array
    output logic [T-1:0][W-1:0]      a_in_row,
    output logic [T-1:0]             a_in_valid,
    output logic [T-1:0][W-1:0]      b_in_col,
    output logic [T-1:0]             b_in_valid,
    output logic                     acc_clear_block,
    output logic                     drain_pulse,
    input  logic [T-1:0][T-1:0][ACCW-1:0] acc_mat,
    input  logic [T-1:0][T-1:0]           acc_v_mat
);

    typedef enum logic [2:0] {
        IDLE   = 3'd0,
        CLEAR  = 3'd1,
        FEED   = 3'd2,
        WAIT1  = 3'd3,
        DRAIN  = 3'd4,
        WAIT2  = 3'd5,
        STORE  = 3'd6,
        DONE_S = 3'd7
    } state_t;
    
    state_t state;
    int cycle_cnt;
    int row_cnt;    // 0-15 (result matrix row)
    int col_cnt;    // 0-15 (result matrix column)
    
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            cycle_cnt <= 0;
            row_cnt <= 0;
            col_cnt <= 0;
        end else begin
            case (state)
                IDLE: if (start) state <= CLEAR;
                
                CLEAR: begin
                    state <= FEED;
                    cycle_cnt <= 0;
                end
                
                FEED: begin
                    cycle_cnt <= cycle_cnt + 1;
                    if (cycle_cnt == T-1) state <= WAIT1;
                end
                
                WAIT1: begin
                    cycle_cnt <= cycle_cnt + 1;
                    if (cycle_cnt == T+10) state <= DRAIN;
                end
                
                DRAIN: begin
                    state <= WAIT2;
                    cycle_cnt <= 0;
                end
                
                WAIT2: begin
                    cycle_cnt <= cycle_cnt + 1;
                    if (cycle_cnt == T*T + 10) begin
                        state <= STORE;
                        row_cnt <= 0;
                        col_cnt <= 0;
                    end
                end
                
                STORE: begin
                    // Advance column, then row (row-major order)
                    col_cnt <= col_cnt + 1;
                    if (col_cnt == T-1) begin
                        col_cnt <= 0;
                        row_cnt <= row_cnt + 1;
                        if (row_cnt == T-1) begin
                            state <= DONE_S;
                        end
                    end
                end
                
                DONE_S: state <= IDLE;
            endcase
        end
    end
    
    always_comb begin
        // Defaults
        bram_a_addr = '0;
        bram_a_en = 0;
        bram_b_addr = '0;
        bram_b_en = 0;
        
        bram_c_en = '0;
        bram_c_we = '0;
        bram_c_addr = '0;
        bram_c_wdata = '0;
        
        a_in_row = '0;
        a_in_valid = '0;
        b_in_col = '0;
        b_in_valid = '0;
        acc_clear_block = 0;
        drain_pulse = 0;
        done = 0;
        
        case (state)
            CLEAR: acc_clear_block = 1;
            
            FEED: begin
                bram_a_addr = cycle_cnt;
                bram_a_en = 1;
                bram_b_addr = cycle_cnt;
                bram_b_en = 1;
                for (int i = 0; i < T; i++) begin
                    a_in_row[i] = bram_a_rdata[i*W +: W];
                    b_in_col[i] = bram_b_rdata[i*W +: W];
                end
                a_in_valid = '1;
                b_in_valid = '1;
            end
            
            DRAIN: drain_pulse = 1;
            
            STORE: begin
    for (int i = 0; i < T; i++) begin
        if (i == row_cnt) begin
            bram_c_en[i] = 1'b1;
            bram_c_we[i] = 1'b1;
            bram_c_addr[i] = col_cnt[BRAM_AW-1:0];
            bram_c_wdata[i] = acc_mat[row_cnt][col_cnt];
        end else begin
            bram_c_en[i] = 1'b0;
            bram_c_we[i] = 1'b0;
            bram_c_addr[i] = '0;
            bram_c_wdata[i] = '0;
        end
    end
end            
            DONE_S: done = 1;
        endcase
    end

endmodule