// mm_top.sv
// Top-level module for systolic array matrix multiplier
// Implements C = A * B using tiled matrix multiplication
// Data flow: DDR -> Loader -> A/B BRAM -> PE Array -> C BRAM -> Drainer -> FIFO -> Packer -> Writer -> DDR

import mm_pkg::*;


module mm_top #(
  parameter int W           = mm_pkg::W,         // Element width (8-bit)
  parameter int ACCW        = mm_pkg::ACCW,      // Accumulator width (32-bit)
  parameter int T           = mm_pkg::T,         // Tile size (16x16)
  parameter int HOST_DW     = mm_pkg::HOST_DW,   // Host bus width (128-bit)
  parameter bit SIGNED_M    = mm_pkg::SIGNED_M,  // Signed multiply
  parameter bit PIPE_MUL    = mm_pkg::PIPE_MUL,  // Pipeline multiply
  parameter int AW          = 10,                // BRAM address width
  parameter int FIFO_DEPTH  = 7,                 // Log2 of FIFO depth
  parameter bit ADDR_IS_WORD = 1                 // Avalon address mode
)(
  input  logic                     clk,
  input  logic                     rst_n,
  
  // ---- Control/Status Interface ----
  input  logic                     start,
  output logic                     busy,
  output logic                     done,
  output logic                     irq,
  
  // Configuration registers
  input  logic [31:0]              baseA,        // Base address matrix A
  input  logic [31:0]              baseB,        // Base address matrix B
  input  logic [31:0]              baseC,        // Base address matrix C
  input  logic [15:0]              N,            // Matrix dimension
  input  logic [15:0]              lda,          // Leading dimension A
  input  logic [15:0]              ldb,          // Leading dimension B
  input  logic [15:0]              ldc,          // Leading dimension C
  input  logic                     irq_en,       // Interrupt enable
  
  // ---- Avalon-MM Master Interface (to DDR) ----
  output logic [31:0]              avm_address,
  output logic                     avm_read,
  output logic                     avm_write,
  output logic [HOST_DW-1:0]       avm_writedata,
  output logic [HOST_DW/8-1:0]     avm_byteenable,
  input  logic [HOST_DW-1:0]       avm_readdata,
  input  logic                     avm_readdatavalid,
  input  logic                     avm_waitrequest,
  output logic [7:0]               avm_burstcount,
  
  // ---- Debug/Status ----
  output logic [31:0]              debug_tiles_completed,
  output logic [7:0]               debug_state
);

  // ============================================================================
  // Internal Signals
  // ============================================================================
  
  // FSM signals
  logic        fsm_loaderA_start, fsm_loaderA_busy, fsm_loaderA_done;
  logic [31:0] fsm_loaderA_base_addr;
  logic [15:0] fsm_loaderA_tile_rows, fsm_loaderA_tile_cols, fsm_loaderA_tile_len_k;
  logic        fsm_loaderA_bankset_sel, fsm_loaderA_col_major_mode;
  
  logic        fsm_loaderB_start, fsm_loaderB_busy, fsm_loaderB_done;
  logic [31:0] fsm_loaderB_base_addr;
  logic [15:0] fsm_loaderB_tile_rows, fsm_loaderB_tile_cols, fsm_loaderB_tile_len_k;
  logic        fsm_loaderB_bankset_sel, fsm_loaderB_col_major_mode;
  
  logic [T-1:0]             fsm_a_bank_rd_en;
  logic [T-1:0][AW-1:0]     fsm_a_bank_rd_addr;
  logic [T-1:0]             fsm_b_bank_rd_en;
  logic [T-1:0][AW-1:0]     fsm_b_bank_rd_addr;
  
  logic        fsm_array_acc_clear, fsm_array_drain_pulse;
  logic        fsm_drainer_start, fsm_drainer_busy, fsm_drainer_done;
  logic [15:0] fsm_drainer_tile_rows, fsm_drainer_tile_cols;
  logic        fsm_drainer_bankset_sel;
  logic        fsm_writer_start, fsm_writer_busy, fsm_writer_done;
  logic [31:0] fsm_writer_base_addr;
  logic        fsm_error;
  
  // Loader Avalon buses (arbitrated)
  logic [31:0]       loaderA_avm_address, loaderB_avm_address;
  logic              loaderA_avm_read, loaderB_avm_read;
  logic [HOST_DW-1:0] loaderA_avm_readdata, loaderB_avm_readdata;
  logic              loaderA_avm_readdatavalid, loaderB_avm_readdatavalid;
  logic              loaderA_avm_waitrequest, loaderB_avm_waitrequest;
  logic [7:0]        loaderA_avm_burstcount, loaderB_avm_burstcount;
  
  // A BRAM bank signals
  logic [T-1:0]           a_banks_a_en, a_banks_b_en;
  logic [T-1:0][AW-1:0]   a_banks_a_addr, a_banks_b_addr;
  logic [T-1:0][W-1:0]    a_banks_a_din, a_banks_b_din;
  logic [T-1:0]           a_banks_a_we, a_banks_b_we;
  logic [T-1:0][W/8-1:0]  a_banks_a_be, a_banks_b_be;
  logic [T-1:0][W-1:0]    a_banks_a_dout, a_banks_b_dout;
  
  // B BRAM bank signals
  logic [T-1:0]           b_banks_a_en, b_banks_b_en;
  logic [T-1:0][AW-1:0]   b_banks_a_addr, b_banks_b_addr;
  logic [T-1:0][W-1:0]    b_banks_a_din, b_banks_b_din;
  logic [T-1:0]           b_banks_a_we, b_banks_b_we;
  logic [T-1:0][W/8-1:0]  b_banks_a_be, b_banks_b_be;
  logic [T-1:0][W-1:0]    b_banks_a_dout, b_banks_b_dout;
  
  // C BRAM bank signals (for result storage)
  logic [T-1:0]           c_banks_a_en, c_banks_b_en;
  logic [T-1:0][AW-1:0]   c_banks_a_addr, c_banks_b_addr;
  logic [T-1:0][ACCW-1:0] c_banks_a_din, c_banks_b_din;
  logic [T-1:0]           c_banks_a_we, c_banks_b_we;
  logic [T-1:0][ACCW/8-1:0] c_banks_a_be, c_banks_b_be;
  logic [T-1:0][ACCW-1:0] c_banks_a_dout, c_banks_b_dout;
  
  // PE Array signals
  logic [T-1:0][W-1:0]    array_a_in, array_b_in;
  logic [T-1:0]           array_a_valid, array_b_valid;
  logic [T-1:0][T-1:0][ACCW-1:0] array_acc_mat;
  logic [T-1:0][T-1:0]    array_acc_v_mat;
  
  // Drainer to FIFO stream
  logic        drain_stream_valid, drain_stream_ready;
  logic [ACCW-1:0] drain_stream_data;
  logic        drain_flush;
  
  // FIFO to Packer stream
  logic        fifo_out_valid, fifo_out_ready;
  logic [ACCW-1:0] fifo_out_data;
  
  // Packer to Writer stream
  logic        pack_out_valid, pack_out_ready;
  logic [HOST_DW-1:0] pack_out_data;
  logic [HOST_DW/8-1:0] pack_out_strb;
  logic        pack_out_last;
  

    // Writer Avalon-MM sideband (from writer into arbiter)
  logic [31:0]         writer_avm_address;
  logic                writer_avm_write;
  logic [HOST_DW-1:0]  writer_avm_writedata;
  logic [HOST_DW/8-1:0] writer_avm_byteenable;
  logic                writer_avm_waitrequest;
  logic [7:0]          writer_avm_burstcount;

  // ============================================================================
  // Module Instantiations
  // ============================================================================
  
  // ---- FSM Controller ----
  mm_fsm_controller #(
    .W(W),
    .ACCW(ACCW),
    .T(T),
    .HOST_DW(HOST_DW),
    .AW(AW)
  ) u_fsm (
    .clk                  (clk),
    .rst_n                (rst_n),
    .start                (start),
    .busy                 (busy),
    .done                 (done),
    .error                (fsm_error),
    .baseA                (baseA),
    .baseB                (baseB),
    .baseC                (baseC),
    .N                    (N),
    .lda                  (lda),
    .ldb                  (ldb),
    .ldc                  (ldc),
    .loaderA_start        (fsm_loaderA_start),
    .loaderA_busy         (fsm_loaderA_busy),
    .loaderA_done         (fsm_loaderA_done),
    .loaderA_base_addr    (fsm_loaderA_base_addr),
    .loaderA_tile_rows    (fsm_loaderA_tile_rows),
    .loaderA_tile_cols    (fsm_loaderA_tile_cols),
    .loaderA_tile_len_k   (fsm_loaderA_tile_len_k),
    .loaderA_bankset_sel  (fsm_loaderA_bankset_sel),
    .loaderA_col_major_mode(fsm_loaderA_col_major_mode),
    .loaderB_start        (fsm_loaderB_start),
    .loaderB_busy         (fsm_loaderB_busy),
    .loaderB_done         (fsm_loaderB_done),
    .loaderB_base_addr    (fsm_loaderB_base_addr),
    .loaderB_tile_rows    (fsm_loaderB_tile_rows),
    .loaderB_tile_cols    (fsm_loaderB_tile_cols),
    .loaderB_tile_len_k   (fsm_loaderB_tile_len_k),
    .loaderB_bankset_sel  (fsm_loaderB_bankset_sel),
    .loaderB_col_major_mode(fsm_loaderB_col_major_mode),
    .a_bank_rd_en         (fsm_a_bank_rd_en),
    .a_bank_rd_addr       (fsm_a_bank_rd_addr),
    .b_bank_rd_en         (fsm_b_bank_rd_en),
    .b_bank_rd_addr       (fsm_b_bank_rd_addr),
    .array_acc_clear      (fsm_array_acc_clear),
    .array_drain_pulse    (fsm_array_drain_pulse),
    .array_acc_valid      (array_acc_v_mat),
    .drainer_start        (fsm_drainer_start),
    .drainer_busy         (fsm_drainer_busy),
    .drainer_done         (fsm_drainer_done),
    .drainer_tile_rows    (fsm_drainer_tile_rows),
    .drainer_tile_cols    (fsm_drainer_tile_cols),
    .drainer_bankset_sel  (fsm_drainer_bankset_sel),
    .writer_start         (fsm_writer_start),
    .writer_busy          (fsm_writer_busy),
    .writer_done          (fsm_writer_done),
    .writer_base_addr     (fsm_writer_base_addr),
    .tiles_completed      (debug_tiles_completed),
    .current_state        (debug_state)
  );
  
  // ---- Loader A (loads A tiles) ----
  tile_loader #(
    .W(W),
    .BUSW(HOST_DW),
    .T(T),
    .AW(AW),
    .ADDR_IS_WORD(ADDR_IS_WORD)
  ) u_loaderA (
    .clk                (clk),
    .rst_n              (rst_n),
    .start              (fsm_loaderA_start),
    .busy               (fsm_loaderA_busy),
    .done               (fsm_loaderA_done),
    .base_addr_bytes    (fsm_loaderA_base_addr),
    .tile_rows          (fsm_loaderA_tile_rows),
    .tile_cols          (fsm_loaderA_tile_cols),
    .tile_len_k         (fsm_loaderA_tile_len_k),
    .bankset_sel        (fsm_loaderA_bankset_sel),
    .col_major_mode     (fsm_loaderA_col_major_mode),
    .avm_address        (loaderA_avm_address),
    .avm_read           (loaderA_avm_read),
    .avm_readdata       (loaderA_avm_readdata),
    .avm_readdatavalid  (loaderA_avm_readdatavalid),
    .avm_waitrequest    (loaderA_avm_waitrequest),
    .avm_burstcount     (loaderA_avm_burstcount),
    .b_en               (a_banks_b_en),
    .b_addr             (a_banks_b_addr),
    .b_din              (a_banks_b_din),
    .b_we               (a_banks_b_we)
  );
  
  // ---- Loader B (loads B tiles) ----
  tile_loader #(
    .W(W),
    .BUSW(HOST_DW),
    .T(T),
    .AW(AW),
    .ADDR_IS_WORD(ADDR_IS_WORD)
  ) u_loaderB (
    .clk                (clk),
    .rst_n              (rst_n),
    .start              (fsm_loaderB_start),
    .busy               (fsm_loaderB_busy),
    .done               (fsm_loaderB_done),
    .base_addr_bytes    (fsm_loaderB_base_addr),
    .tile_rows          (fsm_loaderB_tile_rows),
    .tile_cols          (fsm_loaderB_tile_cols),
    .tile_len_k         (fsm_loaderB_tile_len_k),
    .bankset_sel        (fsm_loaderB_bankset_sel),
    .col_major_mode     (fsm_loaderB_col_major_mode),
    .avm_address        (loaderB_avm_address),
    .avm_read           (loaderB_avm_read),
    .avm_readdata       (loaderB_avm_readdata),
    .avm_readdatavalid  (loaderB_avm_readdatavalid),
    .avm_waitrequest    (loaderB_avm_waitrequest),
    .avm_burstcount     (loaderB_avm_burstcount),
    .b_en               (b_banks_b_en),
    .b_addr             (b_banks_b_addr),
    .b_din              (b_banks_b_din),
    .b_we               (b_banks_b_we)
  );
  
  // ---- A Matrix BRAM Banks ----
  m10k_banks #(
    .N_BANKS(T),
    .W(W),
    .DEPTH_PER_BANK(1 << AW),
    .USE_BYTE_EN(0),
    .RDW_MODE(2)
  ) u_a_banks (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (a_banks_a_en),
    .a_addr  (a_banks_a_addr),
    .a_din   (a_banks_a_din),
    .a_we    (a_banks_a_we),
    .a_be    ({T{1'b1}}),
    .a_dout  (a_banks_a_dout),
    .b_en    (a_banks_b_en),
    .b_addr  (a_banks_b_addr),
    .b_din   (a_banks_b_din),
    .b_we    (a_banks_b_we),
    .b_be    ({T{1'b1}}),
    .b_dout  (a_banks_b_dout)
  );
  
  // ---- B Matrix BRAM Banks ----
  m10k_banks #(
    .N_BANKS(T),
    .W(W),
    .DEPTH_PER_BANK(1 << AW),
    .USE_BYTE_EN(0),
    .RDW_MODE(2)
  ) u_b_banks (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (b_banks_a_en),
    .a_addr  (b_banks_a_addr),
    .a_din   (b_banks_a_din),
    .a_we    (b_banks_a_we),
    .a_be    ({T{1'b1}}),
    .a_dout  (b_banks_a_dout),
    .b_en    (b_banks_b_en),
    .b_addr  (b_banks_b_addr),
    .b_din   (b_banks_b_din),
    .b_we    (b_banks_b_we),
    .b_be    ({T{1'b1}}),
    .b_dout  (b_banks_b_dout)
  );
  
  // ---- C Result BRAM Banks ----
  m10k_banks #(
    .N_BANKS(T),
    .W(ACCW),
    .DEPTH_PER_BANK(1 << AW),
    .USE_BYTE_EN(0),
    .RDW_MODE(2)
  ) u_c_banks (
    .clk     (clk),
    .rst_n   (rst_n),
    .a_en    (c_banks_a_en),
    .a_addr  (c_banks_a_addr),
    .a_din   (c_banks_a_din),
    .a_we    (c_banks_a_we),
    .a_be    ({T{4'hF}}),
    .a_dout  (c_banks_a_dout),
    .b_en    (c_banks_b_en),
    .b_addr  (c_banks_b_addr),
    .b_din   (c_banks_b_din),
    .b_we    (c_banks_b_we),
    .b_be    ({T{4'hF}}),
    .b_dout  (c_banks_b_dout)
  );
  
  // Connect FSM bank read controls to A banks (Port A for array feeding)
  always_comb begin
    a_banks_a_en   = fsm_a_bank_rd_en;
    a_banks_a_addr = fsm_a_bank_rd_addr;
    a_banks_a_din  = '0;
    a_banks_a_we   = '0;
  end
  
  // Connect FSM bank read controls to B banks (Port A for array feeding)
  always_comb begin
    b_banks_a_en   = fsm_b_bank_rd_en;
    b_banks_a_addr = fsm_b_bank_rd_addr;
    b_banks_a_din  = '0;
    b_banks_a_we   = '0;
  end
  
  // Pipeline registers for BRAM read data (1-cycle latency)
  logic [T-1:0][W-1:0] a_data_q, b_data_q;
  logic [T-1:0] a_valid_q, b_valid_q;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_data_q  <= '0;
      b_data_q  <= '0;
      a_valid_q <= '0;
      b_valid_q <= '0;
    end else begin
      a_data_q  <= a_banks_a_dout;
      b_data_q  <= b_banks_a_dout;
      a_valid_q <= fsm_a_bank_rd_en;
      b_valid_q <= fsm_b_bank_rd_en;
    end
  end
  
  // Connect to PE array inputs
  assign array_a_in    = a_data_q;
  assign array_a_valid = a_valid_q;
  assign array_b_in    = b_data_q;
  assign array_b_valid = b_valid_q;
  
  // ---- PE Array ----
  pe_array #(
    .W(W),
    .ACCW(ACCW),
    .T(T),
    .SIGNED_M(SIGNED_M),
    .PIPE_MUL(PIPE_MUL)
  ) u_pe_array (
    .clk             (clk),
    .rst_n           (rst_n),
    .a_in_row        (array_a_in),
    .a_in_valid      (array_a_valid),
    .b_in_col        (array_b_in),
    .b_in_valid      (array_b_valid),
    .acc_clear_block (fsm_array_acc_clear),
    .drain_pulse     (fsm_array_drain_pulse),
    .acc_mat         (array_acc_mat),
    .acc_v_mat       (array_acc_v_mat)
  );
  
  // Write PE array results to C banks (Port B)
  always_comb begin
    for (int i = 0; i < T; i++) begin
      for (int j = 0; j < T; j++) begin
        c_banks_b_en[i]        = array_acc_v_mat[i][j];
        c_banks_b_we[i]        = array_acc_v_mat[i][j];
        c_banks_b_addr[i]      = {1'b0, j[AW-2:0]};  // bankset 0, column j
        c_banks_b_din[i]       = array_acc_mat[i][j];
      end
    end
  end
  
  // ---- Result Drainer ----
  result_drain #(
    .W(ACCW),
    .T(T),
    .AW(AW)
  ) u_drainer (
    .clk           (clk),
    .rst_n         (rst_n),
    .start         (fsm_drainer_start),
    .busy          (fsm_drainer_busy),
    .done          (fsm_drainer_done),
    .tile_rows     (fsm_drainer_tile_rows),
    .tile_cols     (fsm_drainer_tile_cols),
    .bankset_sel   (fsm_drainer_bankset_sel),
    .a_en          (c_banks_a_en),
    .a_addr        (c_banks_a_addr),
    .a_dout        (c_banks_a_dout),
    .out_valid     (drain_stream_valid),
    .out_data      (drain_stream_data),
    .out_ready     (drain_stream_ready),
    .flush         (drain_flush)
  );
  
  // Unused C bank port A write signals
  always_comb begin
    c_banks_a_din = '0;
    c_banks_a_we  = '0;
  end
  
  // ---- FIFO between Drainer and Packer ----
  fifo_wrapper #(
    .W(ACCW),
    .LGFLEN(FIFO_DEPTH)
  ) u_fifo (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_data  (drain_stream_data),
    .s_valid (drain_stream_valid),
    .s_ready (drain_stream_ready),
    .m_data  (fifo_out_data),
    .m_valid (fifo_out_valid),
    .m_ready (fifo_out_ready)
  );
  
  // ---- Packer (elements to bus-width beats) ----
  packer #(
    .W(ACCW),
    .BEAT_W(HOST_DW),
    .LSB_FIRST(1)
  ) u_packer (
    .clk     (clk),
    .rst_n   (rst_n),
    .s_valid (fifo_out_valid),
    .s_ready (fifo_out_ready),
    .s_data  (fifo_out_data),
    .s_last  (drain_flush),
    .m_valid (pack_out_valid),
    .m_ready (pack_out_ready),
    .m_data  (pack_out_data),
    .m_strb  (pack_out_strb),
    .m_last  (pack_out_last)
  );
  
  // ---- Avalon-MM Writer ----
  avalon_mm_writer #(
    .BEAT_W(HOST_DW),
    .ADDR_W(32)
  ) u_writer (
    .clk            (clk),
    .rst_n          (rst_n),
    .s_valid        (pack_out_valid),
    .s_ready        (pack_out_ready),
    .s_data         (pack_out_data),
    .s_strb         (pack_out_strb),
    .s_last         (pack_out_last),
    .start          (fsm_writer_start),
    .base_addr      (fsm_writer_base_addr),
    .busy           (fsm_writer_busy),
    .done           (fsm_writer_done),
    .avm_address    (writer_avm_address),
    .avm_write      (writer_avm_write),
    .avm_writedata  (writer_avm_writedata),
    .avm_byteenable (writer_avm_byteenable),
    .avm_burstcount (writer_avm_burstcount),
    .avm_waitrequest(writer_avm_waitrequest)
  );
  

  
  always_comb begin
    // Default: no activity
    avm_address     = '0;
    avm_read        = 1'b0;
    avm_write       = 1'b0;
    avm_writedata   = '0;
    avm_byteenable  = '0;
    avm_burstcount  = 8'd1;
    
    loaderA_avm_readdata      = '0;
    loaderA_avm_readdatavalid = 1'b0;
    loaderA_avm_waitrequest   = 1'b1;
    
    loaderB_avm_readdata      = '0;
    loaderB_avm_readdatavalid = 1'b0;
    loaderB_avm_waitrequest   = 1'b1;
    
    writer_avm_waitrequest    = 1'b1;
    
    // Priority: Writer > LoaderA > LoaderB
    if (writer_avm_write) begin
      // Writer has priority
      avm_address            = writer_avm_address;
      avm_write              = writer_avm_write;
      avm_writedata          = writer_avm_writedata;
      avm_byteenable         = writer_avm_byteenable;
      avm_burstcount         = writer_avm_burstcount;
      writer_avm_waitrequest = avm_waitrequest;
      
    end else if (loaderA_avm_read) begin
      // LoaderA gets bus
      avm_address                = loaderA_avm_address;
      avm_read                   = loaderA_avm_read;
      avm_burstcount             = loaderA_avm_burstcount;
      loaderA_avm_readdata       = avm_readdata;
      loaderA_avm_readdatavalid  = avm_readdatavalid;
      loaderA_avm_waitrequest    = avm_waitrequest;
      
    end else if (loaderB_avm_read) begin
      // LoaderB gets bus
      avm_address                = loaderB_avm_address;
      avm_read                   = loaderB_avm_read;
      avm_burstcount             = loaderB_avm_burstcount;
      loaderB_avm_readdata       = avm_readdata;
      loaderB_avm_readdatavalid  = avm_readdatavalid;
      loaderB_avm_waitrequest    = avm_waitrequest;
    end
  end
  
  // ---- Interrupt Generation ----
  logic done_q;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_q <= 1'b0;
      irq    <= 1'b0;
    end else begin
      done_q <= done;
      irq    <= irq_en && done && !done_q;  // Rising edge of done
    end
  end

endmodule