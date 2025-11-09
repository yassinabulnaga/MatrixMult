`timescale 1ns/1ps

module tb_m10;

  localparam int N_BANKS         = 4;
  localparam int W               = 32;
  localparam int DEPTH_PER_BANK  = 16;
  localparam bit USE_BYTE_EN     = 0;
  localparam int RDW_MODE        = 2;
  localparam int READ_LATENCY    = 3;

  // Clock / reset
  logic clk;
  logic rst_n;

  // Port A
  logic [N_BANKS-1:0]                              a_en;
  logic [N_BANKS-1:0][$clog2(DEPTH_PER_BANK)-1:0]  a_addr;
  logic [N_BANKS-1:0][W-1:0]                       a_din;
  logic [N_BANKS-1:0]                              a_we;
  logic [N_BANKS-1:0][(W/8>0?W/8:1)-1:0]           a_be;
  logic [N_BANKS-1:0][W-1:0]                       a_dout;

  // Port B
  logic [N_BANKS-1:0]                              b_en;
  logic [N_BANKS-1:0][$clog2(DEPTH_PER_BANK)-1:0]  b_addr;
  logic [N_BANKS-1:0][W-1:0]                       b_din;
  logic [N_BANKS-1:0]                              b_we;
  logic [N_BANKS-1:0][(W/8>0?W/8:1)-1:0]           b_be;
  logic [N_BANKS-1:0][W-1:0]                       b_dout;

  // Golden model: one mem per bank
  logic [W-1:0] model_mem [0:N_BANKS-1][0:DEPTH_PER_BANK-1];

  // DUT
  m10k_banks #(
    .N_BANKS        (N_BANKS),
    .W              (W),
    .DEPTH_PER_BANK (DEPTH_PER_BANK),
    .USE_BYTE_EN    (USE_BYTE_EN),
    .RDW_MODE       (RDW_MODE)
  ) dut (
    .clk    (clk),
    .rst_n  (rst_n),

    .a_en   (a_en),
    .a_addr (a_addr),
    .a_din  (a_din),
    .a_we   (a_we),
    .a_be   (a_be),
    .a_dout (a_dout),

    .b_en   (b_en),
    .b_addr (b_addr),
    .b_din  (b_din),
    .b_we   (b_we),
    .b_be   (b_be),
    .b_dout (b_dout)
  );

  // Clock 100 MHz
  initial clk = 0;
  always #5 clk = ~clk;

  // ===== Main =====
  initial begin
    // init
    rst_n = 0;
    a_en = '0; a_we = '0; a_addr = '0; a_din = '0; a_be = '1;
    b_en = '0; b_we = '0; b_addr = '0; b_din = '0; b_be = '1;

    for (int b = 0; b < N_BANKS; b++)
      for (int a = 0; a < DEPTH_PER_BANK; a++)
        model_mem[b][a] = '0;

    repeat (4) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // 1) Per-bank basic write/read
    basic_bank_writes_reads();

    // 2) Cross-bank isolation check
    cross_bank_isolation();

    // 3) Parallel multi-bank ops (stress index wiring)
    parallel_multi_bank_ops();

    $display("[%0t] m10k_banks wrapper connectivity tests PASSED", $time);
    $finish;
  end

  // ===== Helpers =====

  function automatic logic [W-1:0] gen_pattern(int bank, int addr);
    gen_pattern = {8'(bank), 8'(addr), 16'hA55A};
  endfunction

  // Single write via A to (bank, addr)
  task automatic a_write(int bank, int addr, logic [W-1:0] data);
  begin
    @(posedge clk);
    a_en = '0; a_we = '0;
    a_en[bank]   = 1'b1;
    a_we[bank]   = 1'b1;
    a_addr[bank] = addr;
    a_din[bank]  = data;
    a_be         = '1;
    @(posedge clk); // commit
    a_en[bank]   = 1'b0;
    a_we[bank]   = 1'b0;
    model_mem[bank][addr] = data;
  end
  endtask

  // Single read via B with known latency
  task automatic b_read_chk(int bank, int addr);
    logic [W-1:0] exp;
  begin
    exp = model_mem[bank][addr];

    @(posedge clk);
    b_en = '0; b_we = '0;
    b_en[bank]   = 1'b1;
    b_addr[bank] = addr;
    b_be         = '1;

    repeat (READ_LATENCY) @(posedge clk);
    #1;

    if (b_dout[bank] !== exp) begin
      $fatal(1,
        "[%0t] B_RD_FAIL bank=%0d addr=%0d exp=%h got=%h",
        $time, bank, addr, exp, b_dout[bank]
      );
    end

    b_en[bank] = 1'b0;
  end
  endtask

  // ===== Tests =====

  // 1) For each bank, write unique patterns and read back via B.
  task automatic basic_bank_writes_reads;
  begin
    for (int b = 0; b < N_BANKS; b++) begin
      for (int a = 0; a < DEPTH_PER_BANK; a++) begin
        a_write(b, a, gen_pattern(b, a));
      end
    end

    for (int b = 0; b < N_BANKS; b++) begin
      for (int a = 0; a < DEPTH_PER_BANK; a++) begin
        b_read_chk(b, a);
      end
    end

    $display("[%0t] Basic per-bank writes/reads OK", $time);
  end
  endtask

  // 2) Cross-bank isolation:
  //    change one bank; confirm others unchanged.
  task automatic cross_bank_isolation;
    int base_addr = 3;
    logic [W-1:0] new_val;
  begin
    // modify only bank 1 at base_addr
    new_val = 32'hDEAD_BEEF;
    a_write(1, base_addr, new_val);

    // check bank 1 updated
    b_read_chk(1, base_addr);

    // check same addr in other banks unchanged
    for (int b = 0; b < N_BANKS; b++) if (b != 1) begin
      @(posedge clk);
      b_en = '0; b_we = '0;
      b_en[b]   = 1'b1;
      b_addr[b] = base_addr;
      b_be      = '1;
      repeat (READ_LATENCY) @(posedge clk);
      #1;

      if (b_dout[b] !== model_mem[b][base_addr]) begin
        $fatal(1,
          "[%0t] Isolation FAIL: bank=%0d addr=%0d exp=%h got=%h",
          $time, b, base_addr, model_mem[b][base_addr], b_dout[b]
        );
      end

      b_en[b] = 1'b0;
    end

    $display("[%0t] Cross-bank isolation OK", $time);
  end
  endtask

  // 3) In one cycle, hit multiple banks in parallel on A,
  //    then read back via B to confirm each slice routes correctly.
  task automatic parallel_multi_bank_ops;
    int addr = 7;
    logic [W-1:0] vals [0:N_BANKS-1];
  begin
    // prepare per-bank values
    for (int b = 0; b < N_BANKS; b++)
      vals[b] = {8'(b), 8'(addr), 16'hB00B};

    // parallel write on A to all banks at same addr
    @(posedge clk);
    a_en = '0; a_we = '0;
    for (int b = 0; b < N_BANKS; b++) begin
      a_en[b]   = 1'b1;
      a_we[b]   = 1'b1;
      a_addr[b] = addr;
      a_din[b]  = vals[b];
    end
    a_be = '1;
    @(posedge clk);
    a_en = '0; a_we = '0;

    // update model
    for (int b = 0; b < N_BANKS; b++)
      model_mem[b][addr] = vals[b];

    // read back each via B, one at a time
    for (int b = 0; b < N_BANKS; b++)
      b_read_chk(b, addr);

    $display("[%0t] Parallel multi-bank ops OK", $time);
  end
  endtask

endmodule

