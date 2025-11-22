//Designed by Yassin Abulnaga


module avalon_mm #(
    parameter int BEAT_W   = 128, // Avalon Bit width  | 16 bytes
    parameter int ADDR_W   = 32,  // Avalon Address width 
    parameter int LENGTH_W = 8,   // Length inside beat
    parameter int BRAM_AW  = 8    // BRAM Address width
)(
    input  logic              clk,
    input  logic              rst_n,

// ====== Control Logic =======

    // Start Logic
    input  logic              start_load_a,  //DDR to BRAM A
    input  logic              start_load_b,  //DDR to BRAM B
    input  logic              start_store_c, //BRAM C to DDR

    //DDR Base Addresses
    input  logic [ADDR_W-1:0] base_addr_a,
    input  logic [ADDR_W-1:0] base_addr_b,
    input  logic [ADDR_W-1:0] base_addr_c,

    // Lengths in beats (each beat = BEAT_W bits = BEAT_W/8 bytes)
    input  logic [LENGTH_W-1:0] length_a,
    input  logic [LENGTH_W-1:0] length_b,
    input  logic [LENGTH_W-1:0] length_c,

    // Status
    output logic              done_load_a,
    output logic              done_load_b,
    output logic              done_store_c,
    output logic              busy,

// ====== Avalon MM Interface ======

    // Bram A (DDR -> BRAM A Load)
    output logic [BRAM_AW-1:0]     bram_a_addr,
    output logic                   bram_a_we,
    output logic                   bram_a_en,
    output logic [BEAT_W-1:0]      bram_a_wdata,

    // Bram B (DDR -> BRAM B Load)
    output logic [BRAM_AW-1:0]     bram_b_addr,
    output logic                   bram_b_we,
    output logic                   bram_b_en,
    output logic [BEAT_W-1:0]      bram_b_wdata,

    // Bram C (BRAM C -> DDR Store)
    output logic [BRAM_AW-1:0]     bram_c_addr,
    output logic                   bram_c_en,
    input  logic [BEAT_W-1:0]      bram_c_rdata,

//===== Avalon MM Master Interface ======

    output logic [ADDR_W-1:0]      avm_address,
    output logic                   avm_read,
    output logic                   avm_write,
    output logic [BEAT_W-1:0]      avm_writedata,
    output logic [BEAT_W/8-1:0]    avm_byteenable,
    output logic [7:0]             avm_burstcount, // always 1 for now
    input  logic [BEAT_W-1:0]      avm_readdata,
    input  logic                   avm_waitrequest,
    input  logic                   avm_readdatavalid
);
   
 //Compile Time Checks
     initial begin
        if (BEAT_W % 8 != 0)
            $fatal(1, "avalon_mm: BEAT_W must be a multiple of 8");
        if (LENGTH_W > BRAM_AW)
            $fatal(1, "avalon_mm: BRAM_AW must be >= LENGTH_W");
    end


    localparam int BYTES_PER_BEAT = BEAT_W / 8;

    // Operation Type
        typedef enum logic [1:0] {
        OP_NONE = 2'd0,
        OP_LOAD_A = 2'd1,
        OP_LOAD_B = 2'd2,
        OP_STORE_C = 2'd3
    } op_e;

    // State Machine States
    typedef enum logic [1:0] {
        ST_IDLE  = 2'd0,
        ST_LOAD  = 2'd1,
        ST_STORE = 2'd2
    } state_e;

    state_e st_q, st_d;
    op_e    op_q, op_d;


   
   
   endmodule