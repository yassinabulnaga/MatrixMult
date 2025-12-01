//Testing PE with exp bram a b c 

module tb_pe();

  import mm_pkg::*;

  // ------------------------------------------------------------
  // Clock and reset
  // ------------------------------------------------------------
  logic clk;
  logic rst_n;

  // 100 MHz clock
  initial begin
    clk = 0;
    forever #5 clk = ~clk;
  end

    int i;
    int rows = 16;
    int cols = 16;
    logic bram_a [rows-1][cols-1];
    logic bram_b [rows-1][cols-1];

// exp BRAM A
for (i=0; i<rows; i++) begin 
for (j = 0; j<cols; j++) begin 

if (i==j) begin

    bram_a[i][j] = '1;

end else begin 

    bram_a[i][j] = '0;
end

end
end

// exp BRAM B
for (i=0; i<rows; i++) begin 
for (j = 0; j<cols; j++) begin 

bram_b [i][j] = j;

end end

//EXP BRAM C | Same as Bram B
for (i=0; i<rows; i++) begin 
for (j = 0; j<cols; j++) begin 

bram_c [i][j] = j;

end end


// BRAM A
  logic [T-1:0]          bram_a_en;
  logic [T-1:0][9:0]     bram_a_addr;   // Assume 1024 depth
  logic [T-1:0][W-1:0]   bram_a_din;
  logic [T-1:0]          bram_a_we;
  logic [T-1:0][W/8-1:0] bram_a_be;
  logic [T-1:0][W-1:0]   bram_a_dout;

  m10k_banks #(
    .N_BANKS       (T),
    .W             (W),
    .DEPTH_PER_BANK(1024),
    .USE_BYTE_EN   (0),
    .RDW_MODE      (2)   // WRITE_FIRST
  ) bram_a (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (bram_a_en),
    .a_addr  (bram_a_addr),
    .a_din   (bram_a_din),
    .a_we    (bram_a_we),
    .a_be    (bram_a_be),
    .a_dout  (bram_a_dout),
    .b_en    ('0),
    .b_addr  ('0),
    .b_din   ('0),
    .b_we    ('0),
    .b_be    ('0),
    .b_dout  ()
  );

//Bram B 

logic [T-1:0]          bram_b_en;
  logic [T-1:0][9:0]     bram_b_addr;
  logic [T-1:0][W-1:0]   bram_b_din;
  logic [T-1:0]          bram_b_we;
  logic [T-1:0][W/8-1:0] bram_b_be;
  logic [T-1:0][W-1:0]   bram_b_dout;

  m10k_banks #(
    .N_BANKS       (T),
    .W             (W),
    .DEPTH_PER_BANK(1024),
    .USE_BYTE_EN   (0),
    .RDW_MODE      (2)   
  ) bram_b (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (bram_b_en),
    .a_addr  (bram_b_addr),
    .a_din   (bram_b_din),
    .a_we    (bram_b_we),
    .a_be    (bram_b_be),
    .a_dout  (bram_b_dout),
    .b_en    ('0),
    .b_addr  ('0),
    .b_din   ('0),
    .b_we    ('0),
    .b_be    ('0),
    .b_dout  ()
  );




 // BRAM C | single port use
  logic [T-1:0]               bram_c_en;
  logic [T-1:0][9:0]          bram_c_addr;
  logic [T-1:0][ACCW-1:0]     bram_c_din;
  logic [T-1:0]               bram_c_we;
  logic [T-1:0][ACCW/8-1:0]   bram_c_be;
  logic [T-1:0][ACCW-1:0]     bram_c_dout;

  m10k_banks #(
    .N_BANKS       (T),
    .W             (ACCW),
    .DEPTH_PER_BANK(1024),
    .USE_BYTE_EN   (0),
    .RDW_MODE      (2)  
  ) bram_c (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (bram_c_en),
    .a_addr  (bram_c_addr),
    .a_din   (bram_c_din),
    .a_we    (bram_c_we),
    .a_be    (bram_c_be),
    .a_dout  (bram_c_dout),
    .b_en    ('0),
    .b_addr  ('0),
    .b_din   ('0),
    .b_we    ('0),
    .b_be    ('0),
    .b_dout  ()
  );

    //PE ARR
  logic [T-1:0][W-1:0]      pe_a_in_row;
  logic [T-1:0]             pe_a_in_valid;
  logic [T-1:0][W-1:0]      pe_b_in_col;
  logic [T-1:0]             pe_b_in_valid;
  logic                     pe_acc_clear_block;
  logic                     pe_drain_pulse;
  logic [T-1:0][T-1:0][ACCW-1:0] pe_acc_mat;
  logic [T-1:0][T-1:0]      pe_acc_v_mat;

  pe_array #(
    .W        (W),
    .ACCW     (ACCW),
    .T        (T),
    .SIGNED_M (SIGNED_M),
    .PIPE_MUL (PIPE_MUL)
  ) dut_pe_array (
    .clk            (clk),
    .rst_n          (rst_n),
    .a_in_row       (pe_a_in_row),
    .a_in_valid     (pe_a_in_valid),
    .b_in_col       (pe_b_in_col),
    .b_in_valid     (pe_b_in_valid),
    .acc_clear_block(pe_acc_clear_block),
    .drain_pulse    (pe_drain_pulse),
    .acc_mat        (pe_acc_mat),
    .acc_v_mat      (pe_acc_v_mat)
  );

  logic [T-1:0][W-1:0] bram_a_dout_q;
  logic [T-1:0]        bram_a_valid_q, bram_a_valid_q2;
  logic [T-1:0][W-1:0] bram_b_dout_q;
  logic [T-1:0]        bram_b_valid_q, bram_b_valid_q2;

//input pipeline
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      bram_a_dout_q   <= '0;
      bram_a_valid_q  <= '0;
      bram_a_valid_q2 <= '0;
      bram_b_dout_q   <= '0;
      bram_b_valid_q  <= '0;
      bram_b_valid_q2 <= '0;
    end else begin
      bram_a_valid_q  <= bram_a_en;
      bram_b_valid_q  <= bram_b_en;
      bram_a_valid_q2 <= bram_a_valid_q;
      bram_b_valid_q2 <= bram_b_valid_q;
      bram_a_dout_q   <= bram_a_dout;
      bram_b_dout_q   <= bram_b_dout;
    end
  end

  assign pe_a_in_row   = bram_a_dout_q;
  assign pe_a_in_valid = bram_a_valid_q2;
  assign pe_b_in_col   = bram_b_dout_q;
  assign pe_b_in_valid = bram_b_valid_q2;















endmodule