// Matrix Multiply Controller FSM
// Coordinates loader, PE array, drainer, packer, and Avalon writer
// Handles double-buffered (ping-pong) banksets and tile scheduling
// Created By Yassin Abulnaga

module mm_fsm_controller #(

    //SYSTEM ARCHITECTURE PARAMETERS
    parameter int T            = 16,     //Systolic Array Dimension
    parameter int W            = 16,     //Element Width (A/B)
    parameter int ACC_W        = 32,     //Accumulator Width (C)
    parameter int AW           = 10,     //BRAM Address Width
    parameter int BANKS        = 16,     //Banks Per Set
    parameter int SETS         = 2,      //Banksets Compute/Service
    parameter int BEAT_W       = 128,    //Beat Width
    parameter int BURST_MAX    = 32,     // Max Avalon burst length
    parameter int TIMEOUT_CYC  = 4096,   // Timeout cycles for stall 
    parameter bit COL_MAJOR    = 0,      // B layout in memory
    parameter bit SIGNED_MUL   = 1,      // Signed/unsigned multiply
    parameter bit PAD_EDGES    = 1,      // Enable edge padding
    parameter bit USE_OVERLAP  = 1,      // Overlap preload w/ compute
    parameter int WARMUP_LAT   = T-1,    // Array warmup cycles
    parameter int FLUSH_LAT    = T-1,    // Array flush cycles
    parameter int K_PER_BLOCK  = 16      // K-steps per load

)(
    
    //CLK/RESET
    input logic clk,
    input logic rst,

    // Host configuration inputs
    input logic                 start,
    input logic                 abort, 
    
    input  logic [15:0]         cfg_M,       // total M dimension
    input  logic [15:0]         cfg_N,       // total N dimension
    input  logic [15:0]         cfg_K,       // total K dimension
    input  logic [15:0]         cfg_Tm,      // tile M size
    input  logic [15:0]         cfg_Tn,      // tile N size
    input  logic [15:0]         cfg_Tk,      // tile K size




);



endmodule