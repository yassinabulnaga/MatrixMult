package mm_pkg;
  parameter int W         = 8;     // element width
  parameter int ACCW      = 32;    // accumulator width
  parameter int T         = 16;    // tile size (array is T x T)
  parameter bit SIGNED_M  = 1;
  parameter bit PIPE_MUL  = 0;

  // Host bus widths (tweak to your fabric)
  parameter int HOST_DW   = 128;

  // Simple register block layout offsets (AXI-lite/Avalon)
  typedef struct packed {
    logic [31:0] baseA;   // byte addr
    logic [31:0] baseB;   // byte addr
    logic [31:0] baseC;   // byte addr
    logic [15:0] N;       // matrix dimension (multiple of T recommended)
    logic [15:0] lda;     // leading dims if needed
    logic [15:0] ldb;
    logic [15:0] ldc;
    logic [15:0] tilesK;  // N/T (how many K-tiles)
    logic        start;
    logic        done;
    logic        irq_en;
  } regs_t;

  function automatic int ceil_div(input int a, input int b);
    return (a + b - 1) / b;
  endfunction
endpackage
