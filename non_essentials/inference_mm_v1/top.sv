// Matrix Multiplication Accelerator Top Module
// Connects: DMA, BRAMs A/B/C, PE Array, FSM Controller

import mm_pkg::*;

module mm_accel_top #(
    parameter int BEAT_W = 128,
    parameter int ADDR_W = 32,
    parameter int LENGTH_W = 8,
    parameter int BRAM_AW = 8,
    parameter int T = mm_pkg::T,           // tile size
    parameter int W = mm_pkg::W,           // element width
    parameter int ACCW = mm_pkg::ACCW,     // accumulator width
    parameter int N_BANKS = 16,            // number of BRAM banks
    parameter int BRAM_DEPTH = 256
)(
    input  logic clk,
    input  logic rst_n,
    
    // CPU Interface - separate start signals for flexibility
    input  logic              cpu_start_load_a,   // Load input activations
    input  logic              cpu_start_load_b,   // Load weights (B = weights)
    input  logic              cpu_start_compute,  // Run inference
    input  logic [ADDR_W-1:0] cpu_addr_a,
    input  logic [ADDR_W-1:0] cpu_addr_b,
    input  logic [ADDR_W-1:0] cpu_addr_c,
    input  logic [LENGTH_W-1:0] cpu_len_a,
    input  logic [LENGTH_W-1:0] cpu_len_b,
    input  logic [LENGTH_W-1:0] cpu_len_c,
    output logic              cpu_done,
    output logic              cpu_busy,
    
    // Avalon MM Master (to DDR)
    output logic [ADDR_W-1:0]      avm_address,
    output logic                   avm_read,
    output logic                   avm_write,
    output logic [BEAT_W-1:0]      avm_writedata,
    output logic [BEAT_W/8-1:0]    avm_byteenable,
    output logic [7:0]             avm_burstcount,
    input  logic [BEAT_W-1:0]      avm_readdata,
    input  logic                   avm_waitrequest,
    input  logic                   avm_readdatavalid
);

    // FSM <-> DMA signals
    logic dma_start_load_a, dma_start_load_b, dma_start_store_c;
    logic [ADDR_W-1:0] dma_addr_a, dma_addr_b, dma_addr_c;
    logic [LENGTH_W-1:0] dma_len_a, dma_len_b, dma_len_c;
    logic dma_done_load_a, dma_done_load_b, dma_done_store_c, dma_busy;
    
    // FSM <-> PE signals
    logic pe_start, pe_done;
    
    // DMA <-> BRAM signals
    logic [BRAM_AW-1:0] bram_a_dma_addr, bram_b_dma_addr, bram_c_dma_addr;
    logic               bram_a_dma_we, bram_a_dma_en;
    logic               bram_b_dma_we, bram_b_dma_en;
    logic               bram_c_dma_en;
 logic [BEAT_W-1:0]  bram_a_dma_wdata, bram_b_dma_wdata;
   logic [T*ACCW-1:0]  bram_c_dma_rdata;  // 16 * 32 = 512 bits
    
    // PE <-> BRAM signals
    logic [BRAM_AW-1:0] bram_a_pe_addr, bram_b_pe_addr;
    logic               bram_a_pe_en, bram_b_pe_en;
    logic [BEAT_W-1:0]  bram_a_pe_rdata, bram_b_pe_rdata;
logic [T-1:0]              bram_c_pe_en;
logic [T-1:0]              bram_c_pe_we;
logic [T-1:0][BRAM_AW-1:0] bram_c_pe_addr;
logic [T-1:0][ACCW-1:0]    bram_c_pe_wdata; 

    
    // PE Array signals
    logic [T-1:0][W-1:0]              a_in_row, b_in_col;
    logic [T-1:0]                     a_in_valid, b_in_valid;
    logic                             acc_clear_block, drain_pulse;
    logic [T-1:0][T-1:0][ACCW-1:0]    acc_mat;
    logic [T-1:0][T-1:0]              acc_v_mat;
    
    // ====================
    // FSM Controller
    // ====================
    mm_fsm_ctrl #(
        .ADDR_W(ADDR_W),
        .LENGTH_W(LENGTH_W)
    ) u_fsm (
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
        .dma_start_load_a(dma_start_load_a),
        .dma_start_load_b(dma_start_load_b),
        .dma_start_store_c(dma_start_store_c),
        .dma_addr_a(dma_addr_a),
        .dma_addr_b(dma_addr_b),
        .dma_addr_c(dma_addr_c),
        .dma_len_a(dma_len_a),
        .dma_len_b(dma_len_b),
        .dma_len_c(dma_len_c),
        .dma_done_load_a(dma_done_load_a),
        .dma_done_load_b(dma_done_load_b),
        .dma_done_store_c(dma_done_store_c),
        .pe_start(pe_start),
        .pe_done(pe_done)
    );
    
    // ====================
    // DMA Master
    // ====================
    avalon_mm #(
        .BEAT_W(BEAT_W),
        .ADDR_W(ADDR_W),
        .LENGTH_W(LENGTH_W),
        .BRAM_AW(BRAM_AW)
    ) u_dma (
        .clk(clk),
        .rst_n(rst_n),
        .start_load_a(dma_start_load_a),
        .start_load_b(dma_start_load_b),
        .start_store_c(dma_start_store_c),
        .base_addr_a(dma_addr_a),
        .base_addr_b(dma_addr_b),
        .base_addr_c(dma_addr_c),
        .length_a(dma_len_a),
        .length_b(dma_len_b),
        .length_c(dma_len_c),
        .done_load_a(dma_done_load_a),
        .done_load_b(dma_done_load_b),
        .done_store_c(dma_done_store_c),
        .busy(dma_busy),
        .bram_a_addr(bram_a_dma_addr),
        .bram_a_we(bram_a_dma_we),
        .bram_a_en(bram_a_dma_en),
        .bram_a_wdata(bram_a_dma_wdata),
        .bram_b_addr(bram_b_dma_addr),
        .bram_b_we(bram_b_dma_we),
        .bram_b_en(bram_b_dma_en),
        .bram_b_wdata(bram_b_dma_wdata),
        .bram_c_addr(bram_c_dma_addr),
        .bram_c_en(bram_c_dma_en),
        .bram_c_rdata(bram_c_dma_rdata),
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
    
    // ====================
    // BRAM A (DMA writes port A, PE reads port B)
    // ====================
    logic [N_BANKS-1:0] ba_a_en, ba_b_en;
    logic [N_BANKS-1:0][$clog2(BRAM_DEPTH)-1:0] ba_a_addr, ba_b_addr;
    logic [N_BANKS-1:0][W-1:0] ba_a_din, ba_b_din;
    logic [N_BANKS-1:0] ba_a_we, ba_b_we;
    logic [N_BANKS-1:0][(W/8>0?W/8:1)-1:0] ba_a_be, ba_b_be;
    logic [N_BANKS-1:0][W-1:0] ba_a_dout, ba_b_dout;
    
    assign ba_a_en = {N_BANKS{bram_a_dma_en}};
    assign ba_a_we = {N_BANKS{bram_a_dma_we}};
    assign ba_a_addr = {N_BANKS{bram_a_dma_addr}};
    for (genvar i = 0; i < N_BANKS; i++) begin : g_ba_din
        assign ba_a_din[i] = bram_a_dma_wdata[i*W +: W];
    end
    assign ba_a_be = '1;
    
    assign ba_b_en = {N_BANKS{bram_a_pe_en}};
    assign ba_b_we = '0;
    assign ba_b_addr = {N_BANKS{bram_a_pe_addr}};
    assign ba_b_din = '0;
    assign ba_b_be = '0;
    for (genvar i = 0; i < N_BANKS; i++) begin : g_ba_dout
        assign bram_a_pe_rdata[i*W +: W] = ba_b_dout[i];
    end
    
    m10k_banks #(
        .N_BANKS(N_BANKS),
        .W(W),
        .DEPTH_PER_BANK(BRAM_DEPTH),
        .USE_BYTE_EN(0)
    ) u_bram_a (
        .clk(clk),
        .rst_n(rst_n),
        .a_en(ba_a_en),
        .a_addr(ba_a_addr),
        .a_din(ba_a_din),
        .a_we(ba_a_we),
        .a_be(ba_a_be),
        .a_dout(ba_a_dout),
        .b_en(ba_b_en),
        .b_addr(ba_b_addr),
        .b_din(ba_b_din),
        .b_we(ba_b_we),
        .b_be(ba_b_be),
        .b_dout(ba_b_dout)
    );
    
    // ====================
    // BRAM B (same structure as A)
    // ====================
    logic [N_BANKS-1:0] bb_a_en, bb_b_en;
    logic [N_BANKS-1:0][$clog2(BRAM_DEPTH)-1:0] bb_a_addr, bb_b_addr;
    logic [N_BANKS-1:0][W-1:0] bb_a_din, bb_b_din;
    logic [N_BANKS-1:0] bb_a_we, bb_b_we;
    logic [N_BANKS-1:0][(W/8>0?W/8:1)-1:0] bb_a_be, bb_b_be;
    logic [N_BANKS-1:0][W-1:0] bb_a_dout, bb_b_dout;
    
    assign bb_a_en = {N_BANKS{bram_b_dma_en}};
    assign bb_a_we = {N_BANKS{bram_b_dma_we}};
    assign bb_a_addr = {N_BANKS{bram_b_dma_addr}};
    for (genvar i = 0; i < N_BANKS; i++) begin : g_bb_din
        assign bb_a_din[i] = bram_b_dma_wdata[i*W +: W];
    end
    assign bb_a_be = '1;
    
    assign bb_b_en = {N_BANKS{bram_b_pe_en}};
    assign bb_b_we = '0;
    assign bb_b_addr = {N_BANKS{bram_b_pe_addr}};
    assign bb_b_din = '0;
    assign bb_b_be = '0;
    for (genvar i = 0; i < N_BANKS; i++) begin : g_bb_dout
        assign bram_b_pe_rdata[i*W +: W] = bb_b_dout[i];
    end
    
    m10k_banks #(
        .N_BANKS(N_BANKS),
        .W(W),
        .DEPTH_PER_BANK(BRAM_DEPTH),
        .USE_BYTE_EN(0)
    ) u_bram_b (
        .clk(clk),
        .rst_n(rst_n),
        .a_en(bb_a_en),
        .a_addr(bb_a_addr),
        .a_din(bb_a_din),
        .a_we(bb_a_we),
        .a_be(bb_a_be),
        .a_dout(bb_a_dout),
        .b_en(bb_b_en),
        .b_addr(bb_b_addr),
        .b_din(bb_b_din),
        .b_we(bb_b_we),
        .b_be(bb_b_be),
        .b_dout(bb_b_dout)
    );
    
    // ====================
    // BRAM C (PE writes port A, DMA reads port B)
    // ====================
    parameter int C_BANKS = T;  // 16 banks (one per row)
    logic [C_BANKS-1:0] bc_a_en, bc_b_en;
    logic [C_BANKS-1:0][$clog2(BRAM_DEPTH)-1:0] bc_a_addr, bc_b_addr;
   logic [C_BANKS-1:0][ACCW-1:0] bc_a_din, bc_b_din;

    logic [C_BANKS-1:0] bc_a_we, bc_b_we;
   logic [C_BANKS-1:0][(ACCW/8>0?ACCW/8:1)-1:0] bc_a_be, bc_b_be;
   logic [C_BANKS-1:0][ACCW-1:0] bc_a_dout, bc_b_dout;
    
assign bc_a_en = bram_c_pe_en;
assign bc_a_we = bram_c_pe_we;
for (genvar i = 0; i < T; i++) begin
    assign bc_a_addr[i] = bram_c_pe_addr[i];
    assign bc_a_din[i] = bram_c_pe_wdata[i];
end
    assign bc_a_be = '1;
    
    assign bc_b_en = {C_BANKS{bram_c_dma_en}};
    assign bc_b_we = '0;
    assign bc_b_addr = {C_BANKS{bram_c_dma_addr}};
    assign bc_b_din = '0;
    assign bc_b_be = '0;
    for (genvar i = 0; i < C_BANKS; i++) begin : g_bc_dout
        //if (i*W < BEAT_W)
     assign bram_c_dma_rdata[i*ACCW +: ACCW] = bc_b_dout[i];
    end
    
    m10k_banks #(
        .N_BANKS(C_BANKS),
        .W(ACCW),
        .DEPTH_PER_BANK(BRAM_DEPTH),
        .USE_BYTE_EN(0)
    ) u_bram_c (
        .clk(clk),
        .rst_n(rst_n),
        .a_en(bc_a_en),
        .a_addr(bc_a_addr),
        .a_din(bc_a_din),
        .a_we(bc_a_we),
        .a_be(bc_a_be),
        .a_dout(bc_a_dout),
        .b_en(bc_b_en),
        .b_addr(bc_b_addr),
        .b_din(bc_b_din),
        .b_we(bc_b_we),
        .b_be(bc_b_be),
        .b_dout(bc_b_dout)
    );
    
    // ====================
    // PE Array
    // ====================
    pe_array #(
        .W(W),
        .ACCW(ACCW),
        .T(T),
        .SIGNED_M(mm_pkg::SIGNED_M),
        .PIPE_MUL(mm_pkg::PIPE_MUL)
    ) u_pe_array (
        .clk(clk),
        .rst_n(rst_n),
        .a_in_row(a_in_row),
        .a_in_valid(a_in_valid),
        .b_in_col(b_in_col),
        .b_in_valid(b_in_valid),
        .acc_clear_block(acc_clear_block),
        .drain_pulse(drain_pulse),
        .acc_mat(acc_mat),
        .acc_v_mat(acc_v_mat)
    );
    
    // ====================
    // PE Controller
    // ====================
    pe_controller #(
        .T(T),
        .W(W),
        .ACCW(ACCW),
        .BRAM_AW(BRAM_AW)
    ) u_pe_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .start(pe_start),
        .done(pe_done),
        .bram_a_addr(bram_a_pe_addr),
        .bram_a_en(bram_a_pe_en),
        .bram_a_rdata(bram_a_pe_rdata[T*W-1:0]),
        .bram_b_addr(bram_b_pe_addr),
        .bram_b_en(bram_b_pe_en),
        .bram_b_rdata(bram_b_pe_rdata[T*W-1:0]),
        .bram_c_addr(bram_c_pe_addr),
        .bram_c_we(bram_c_pe_we),
        .bram_c_en(bram_c_pe_en),
        .bram_c_wdata(bram_c_pe_wdata),
        .a_in_row(a_in_row),
        .a_in_valid(a_in_valid),
        .b_in_col(b_in_col),
        .b_in_valid(b_in_valid),
        .acc_clear_block(acc_clear_block),
        .drain_pulse(drain_pulse),
        .acc_mat(acc_mat),
        .acc_v_mat(acc_v_mat)
    );

endmodule