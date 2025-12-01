package mm_pkg;
  parameter int W        = 8;    // element width
  parameter int ACCW     = 32;   // accumulator width
  parameter int T        = 16;    // tile size (4x4 array)
  parameter bit SIGNED_M = 1;    // signed multiply
  parameter bit PIPE_MUL = 0;    // pipeline multiply
endpackage