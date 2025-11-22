module m10k_banks #(

        parameter int N_BANKS = 16,
        parameter int W = 8,
        parameter int DEPTH_PER_BANK = 1024,
        parameter bit USE_BYTE_EN = 0,
        parameter int RDW_MODE       = 2
)(
        input logic clk,
        input logic rst_n,

// Port A [N_BANKS-1:0] is array type of structure, ex 16 enables for 16 banks
        input logic [N_BANKS-1:0] a_en,
        input logic [N_BANKS-1:0][$clog2(DEPTH_PER_BANK)-1:0] a_addr,
        input logic [N_BANKS-1:0][W-1:0] a_din,
        input logic [N_BANKS-1:0]a_we,
        input  logic  [N_BANKS-1:0][(W/8>0?W/8:1)-1:0]            a_be,   // ignored if USE_BYTE_EN=0
        output logic [N_BANKS-1:0][W-1:0] a_dout,

  //Port B
  input  logic  [N_BANKS-1:0]                               b_en,
  input  logic  [N_BANKS-1:0][$clog2(DEPTH_PER_BANK)-1:0]  b_addr,
  input  logic  [N_BANKS-1:0][W-1:0]                        b_din,
  input  logic  [N_BANKS-1:0]                               b_we,
  input  logic  [N_BANKS-1:0][(W/8>0?W/8:1)-1:0]            b_be,   // ignored if USE_BYTE_EN=0
  output logic  [N_BANKS-1:0][W-1:0]                        b_dout
);

for (genvar i = 0; i<N_BANKS; i++) begin: g_bank

dp_bram #(
           .W(W),
           .DEPTH(DEPTH_PER_BANK),
           .USE_BYTE_EN(USE_BYTE_EN),
           .AW((DEPTH_PER_BANK <= 1) ? 1 : $clog2(DEPTH_PER_BANK)),
           .RDW_MODE(RDW_MODE)
) u_bank (
//important: each bank generated uses the indexed one in aray ex, bank0 will use a_en[0]...
      .clk   (clk),
      .rst_n (rst_n),
      .a_en   (a_en[i]),
      .a_addr (a_addr[i]),
      .a_din  (a_din[i]),
      .a_we   (a_we[i]),
      .a_be   (a_be[i]),
      .a_dout (a_dout[i]),

      .b_en   (b_en[i]),
      .b_addr (b_addr[i]),
      .b_din  (b_din[i]),
      .b_we   (b_we[i]),
      .b_be   (b_be[i]),
      .b_dout (b_dout[i])
);
end





endmodule