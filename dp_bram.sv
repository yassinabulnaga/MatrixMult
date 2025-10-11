module dp_bram #(

    parameter int W = 128,
    parameter DEPTH = 1024,
    parameter bit USE_BYTE_EN = 1,
    parameter int AW          = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter int RDW_MODE =0 // 0 = Write first, 1 = Read first, 2 = No change. 
    )(
    input logic clk,
    input logic rst_n,

    //Port A
    input logic a_en,
    input logic [AW-1:0] a_addr,
    input logic [W-1:0] a_din,
    input logic a_we,
    input logic [W/8 -1:0] a_be, //ignored if BYTE EN = 0 
    output logic [W-1:0] a_dout,

    //Port B 
    input logic b_en,
    input logic [AW-1:0] b_addr,
    input logic [W-1:0] b_din,
    input logic b_we,
    input logic [W/8 -1:0] b_be, //ignored if BYTE EN =0
    output logic [W-1:0] b_dout
);


(* ramstyle = "M10K, no_rw_check" *) logic [W-1:0] mem [0:DEPTH-1]; //Hint for Quartus

logic [W-1:0] a_q, b_q; // Read data 

initial begin
    if (USE_BYTE_EN && (W % 8) != 0)
      $fatal(1, "dp_bram: W must be a multiple of 8 when USE_BYTE_EN=1"); // If using Byte EN but width isnt a multiple of 8
    if (RDW_MODE < 0 || RDW_MODE > 2)
      $fatal(1, "dp_bram: RDW_MODE must be 0/1/2"); // if Mode isnt chosen
  end


 // Byte-enable write mask PROBABLY WONT USE
  function automatic [W-1:0] mask_write(
    input [W-1:0] din,
    input [W-1:0] prev,
    input [W/8-1:0] be
  );
    if (!USE_BYTE_EN) return din;
    automatic logic [W-1:0] res;
    for (int i = 0; i < W/8; i++) begin
      res[i*8 +: 8] = be[i] ? din[i*8 +: 8] : prev[i*8 +: 8];
    end
    return res;
  endfunction


 // Port A
  always_ff @(posedge clk) begin
    if (a_en) begin
      logic [W-1:0] wdata_a = mask_write(a_din, mem[a_addr], a_be);
      if (a_we) begin
        mem[a_addr] <= wdata_a;
      end
      unique case (RDW_MODE)
        // During a write, present the new data; otherwise present stored data.
        0: a_q <= a_we ? wdata_a : mem[a_addr];              // WRITE_FIRST
        // Always present the stored data (old contents during write cycle).
        1: a_q <= mem[a_addr];                                // READ_FIRST
        // Hold last value on writes; update only on pure reads.
        2: a_q <= a_we ? a_q : mem[a_addr];                   // NO_CHANGE
        default: a_q <= mem[a_addr];
      endcase
    end
  end

  // Port B
  always_ff @(posedge clk) begin
    if (b_en) begin
      logic [W-1:0] wdata_b = mask_write(b_din, mem[b_addr], b_be);
      if (b_we) begin
        mem[b_addr] <= wdata_b;
      end
      unique case (RDW_MODE)
        0: b_q <= b_we ? wdata_b : mem[b_addr];               // WRITE_FIRST
        1: b_q <= mem[b_addr];                                // READ_FIRST
        2: b_q <= b_we ? b_q : mem[b_addr];                   // NO_CHANGE
        default: b_q <= mem[b_addr];
      endcase
    end
  end

  // Optional output register stage (sync reset to 0)
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_dout <= '0;
      b_dout <= '0;
    end else begin
      a_dout <= a_q;
      b_dout <= b_q;
    end
  end







endmodule