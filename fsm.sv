// mm_fsm_controller.sv
// State machine controller for systolic array matrix multiplier
// Controls the sequence: Load A/B tiles -> Compute -> Drain C -> Write results

import mm_pkg::*;
module mm_fsm_controller #(
  parameter int W         = mm_pkg::W,
  parameter int ACCW      = mm_pkg::ACCW,
  parameter int T         = mm_pkg::T,
  parameter int HOST_DW   = mm_pkg::HOST_DW,
  parameter int AW        = 10  // BRAM address width
)(
  input  logic                     clk,
  input  logic                     rst_n,
  
  // ---- Control/Status Interface ----
  input  logic                     start,        // Start matrix multiplication
  output logic                     busy,         // FSM is active
  output logic                     done,         // Operation complete
  output logic                     error,        // Error occurred
  
  // Matrix parameters
  input  logic [31:0]              baseA,        // Base address for matrix A
  input  logic [31:0]              baseB,        // Base address for matrix B
  input  logic [31:0]              baseC,        // Base address for matrix C
  input  logic [15:0]              N,            // Matrix dimension (multiple of T)
  input  logic [15:0]              lda,          // Leading dimension A
  input  logic [15:0]              ldb,          // Leading dimension B
  input  logic [15:0]              ldc,          // Leading dimension C
  
  // ---- Loader Control ----
  output logic                     loaderA_start,
  input  logic                     loaderA_busy,
  input  logic                     loaderA_done,
  output logic [31:0]              loaderA_base_addr,
  output logic [15:0]              loaderA_tile_rows,
  output logic [15:0]              loaderA_tile_cols,
  output logic [15:0]              loaderA_tile_len_k,
  output logic                     loaderA_bankset_sel,
  output logic                     loaderA_col_major_mode,
  
  output logic                     loaderB_start,
  input  logic                     loaderB_busy,
  input  logic                     loaderB_done,
  output logic [31:0]              loaderB_base_addr,
  output logic [15:0]              loaderB_tile_rows,
  output logic [15:0]              loaderB_tile_cols,
  output logic [15:0]              loaderB_tile_len_k,
  output logic                     loaderB_bankset_sel,
  output logic                     loaderB_col_major_mode,
  
  // ---- BRAM Bank Control for Array Feed ----
  // A banks read control (feeding rows)
  output logic [T-1:0]             a_bank_rd_en,
  output logic [T-1:0][AW-1:0]     a_bank_rd_addr,
  
  // B banks read control (feeding columns)
  output logic [T-1:0]             b_bank_rd_en,
  output logic [T-1:0][AW-1:0]     b_bank_rd_addr,
  
  // ---- PE Array Control ----
  output logic                     array_acc_clear,
  output logic                     array_drain_pulse,
  input  logic [T-1:0][T-1:0]      array_acc_valid,  // From PE array
  
  // ---- Result Drainer Control ----
  output logic                     drainer_start,
  input  logic                     drainer_busy,
  input  logic                     drainer_done,
  output logic [15:0]              drainer_tile_rows,
  output logic [15:0]              drainer_tile_cols,
  output logic                     drainer_bankset_sel,
  
  // ---- Writer Control (via packer) ----
  output logic                     writer_start,
  input  logic                     writer_busy,
  input  logic                     writer_done,
  output logic [31:0]              writer_base_addr,
  
  // ---- Status ----
  output logic [31:0]              tiles_completed,
  output logic [7:0]               current_state
);

  // FSM States
  typedef enum logic [3:0] {
    S_IDLE         = 4'h0,
    S_INIT         = 4'h1,
    S_LOAD_A       = 4'h2,
    S_WAIT_A       = 4'h3,  // NEW
    S_LOAD_B       = 4'h4,
    S_WAIT_B       = 4'h5,  // NEW
    S_COMPUTE_INIT = 4'h6,  // was 4'h5
    S_COMPUTE_FEED = 4'h7,  // was 4'h6
    S_COMPUTE_WAIT = 4'h8,  // was 4'h7
    S_DRAIN_INIT   = 4'h9,  // was 4'h8
    S_DRAIN_WAIT   = 4'hA,  // was 4'h9
    S_WRITE_INIT   = 4'hB,  // was 4'hA
    S_WRITE_WAIT   = 4'hC,  // was 4'hB
    S_NEXT_TILE    = 4'hD,  // was 4'hC
    S_DONE         = 4'hE,  // was 4'hD
    S_ERROR        = 4'hF   // was 4'hE
  } state_t;
  
  state_t state, state_nxt;
  
  // Tile indices
  logic [15:0] tile_m;        // Current tile row (output)
  logic [15:0] tile_n;        // Current tile column (output)
  logic [15:0] tile_k;        // Current K-tile for accumulation
  logic [15:0] tiles_per_dim; // N/T
  
  // Compute feed counters
  logic [15:0] feed_cycle;
  logic [15:0] compute_cycles_total;
  
  // Bank buffer selection (double buffering)
  logic        bankset_compute;  // Current bank set being used for compute
  logic        bankset_load;     // Current bank set being loaded
  
  // Timing parameters
  localparam int FEED_CYCLES = T + T - 1;  // Systolic array feed duration
  localparam int COMPUTE_LATENCY = 2;      // Additional cycles after feed


//helpers
logic [AW-2:0] a_addr_idx;
logic [AW-2:0] b_addr_idx;


//Loader internal signals 
logic loaderA_done_seen, loaderB_done_seen;

always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n) begin
    loaderA_done_seen <= 1'b0;
    loaderB_done_seen <= 1'b0;
  end else begin
    // Clear when starting a new load sequence (before LOAD_A state)
    if (state == S_INIT || state == S_NEXT_TILE) begin
      loaderA_done_seen <= 1'b0;
      loaderB_done_seen <= 1'b0;
    end
    
    // Set flags when done signals are asserted
    if (loaderA_done)
      loaderA_done_seen <= 1'b1;
    if (loaderB_done)
      loaderB_done_seen <= 1'b1;
  end
end



  
  // ---- State Register ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
    end else begin
      state <= state_nxt;
    end
  end
  
  // ---- Control Registers ----
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tile_m           <= '0;
      tile_n           <= '0;
      tile_k           <= '0;
      tiles_per_dim    <= '0;
      feed_cycle       <= '0;
      bankset_compute  <= 1'b0;
      bankset_load     <= 1'b1;
      tiles_completed  <= '0;
      compute_cycles_total <= '0;

    end else begin
      case (state)
        S_INIT: begin
          tile_m          <= '0;
          tile_n          <= '0;
          tile_k          <= '0;
          tiles_per_dim   <= N / T;  // Assume N is multiple of T
          tiles_completed <= '0;
          bankset_compute <= 1'b0;
          bankset_load    <= 1'b1;
          feed_cycle      <= '0;
          compute_cycles_total <= FEED_CYCLES + COMPUTE_LATENCY;
        end
        
        S_COMPUTE_INIT: begin
          feed_cycle <= '0;
        end
        
        S_COMPUTE_FEED: begin
          if (feed_cycle < FEED_CYCLES) begin
            feed_cycle <= feed_cycle + 1;
          end
        end
        
        S_NEXT_TILE: begin
          tiles_completed <= tiles_completed + 1;
          
          // Update K-tile index
          if (tile_k + 1 < tiles_per_dim) begin
            tile_k <= tile_k + 1;
            // Swap buffer sets for next K iteration
            bankset_compute <= bankset_load;
            bankset_load    <= bankset_compute;
          end else begin
            // Move to next output tile
            tile_k <= '0;
            if (tile_n + 1 < tiles_per_dim) begin
              tile_n <= tile_n + 1;
            end else begin
              tile_n <= '0;
              if (tile_m + 1 < tiles_per_dim) begin
                tile_m <= tile_m + 1;
              end
            end
            // Reset buffer sets for new output tile
            bankset_compute <= 1'b0;
            bankset_load    <= 1'b1;
          end
        end
        
        default: ;
      endcase
    end
  end
  
  // ---- Next State Logic ----
  always_comb begin
    state_nxt = state;
    
    case (state)
      S_IDLE: begin
        if (start) begin
          state_nxt = S_INIT;
        end
      end
      
      S_INIT: begin
        state_nxt = S_LOAD_A;
      end
      
S_LOAD_A: begin
        state_nxt = S_WAIT_A;
      end
      
      S_WAIT_A: begin
        if (loaderA_done_seen)
          state_nxt = S_LOAD_B;
        else if (!loaderA_busy && !loaderA_done_seen)
          state_nxt = S_ERROR;
      end
      
      S_LOAD_B: begin
        state_nxt = S_WAIT_B;
      end
      
      S_WAIT_B: begin
        if (loaderB_done_seen)
          state_nxt = S_COMPUTE_INIT;
        else if (!loaderB_busy && !loaderB_done_seen)
          state_nxt = S_ERROR;
      end

      
      S_COMPUTE_INIT: begin
        state_nxt = S_COMPUTE_FEED;
      end
      
      S_COMPUTE_FEED: begin
        if (feed_cycle >= FEED_CYCLES - 1) begin
          state_nxt = S_COMPUTE_WAIT;
        end
      end
      
      S_COMPUTE_WAIT: begin
        // Wait for computation to complete and check if all accumulations valid
        if (&array_acc_valid) begin
          // Check if this is the last K-tile
          if (tile_k == tiles_per_dim - 1) begin
            state_nxt = S_DRAIN_INIT;
          end else begin
            // Need to accumulate more K-tiles
            // Start loading next K-tile while current one computes
            state_nxt = S_NEXT_TILE;
          end
        end
      end
      
      S_DRAIN_INIT: begin
        state_nxt = S_DRAIN_WAIT;
      end
      
      S_DRAIN_WAIT: begin
        if (drainer_done) begin
          state_nxt = S_WRITE_INIT;
        end else if (!drainer_busy && !drainer_done) begin
          state_nxt = S_ERROR;
        end
      end
      
      S_WRITE_INIT: begin
        state_nxt = S_WRITE_WAIT;
      end
      
      S_WRITE_WAIT: begin
        if (writer_done) begin
          state_nxt = S_NEXT_TILE;
        end else if (!writer_busy && !writer_done) begin
          state_nxt = S_ERROR;
        end
      end
      
      S_NEXT_TILE: begin
        // Check if we're done with all tiles
        if ((tile_m == tiles_per_dim - 1) && 
            (tile_n == tiles_per_dim - 1) && 
            (tile_k == 0)) begin  // After processing last K-tile
          state_nxt = S_DONE;
        end else begin
          // Continue with next tile
          if (tile_k == 0) begin
            // Starting new output tile, clear accumulator
            state_nxt = S_LOAD_A;
          end else begin
            // Continue accumulating K-tiles
            state_nxt = S_LOAD_A;
          end
        end
      end
      
      S_DONE: begin
        if (!start) begin
          state_nxt = S_IDLE;
        end
      end
      
      S_ERROR: begin
        if (!start) begin
          state_nxt = S_IDLE;
        end
      end
      
      default: state_nxt = S_IDLE;
    endcase
  end
  
  // ---- Output Control Logic ----
  always_comb begin
    // Default outputs
    loaderA_start         = 1'b0;
    loaderB_start         = 1'b0;
    array_acc_clear       = 1'b0;
    array_drain_pulse     = 1'b0;
    drainer_start         = 1'b0;
    writer_start          = 1'b0;
    a_bank_rd_en          = '0;
    b_bank_rd_en          = '0;
    a_bank_rd_addr        = '0;
    b_bank_rd_addr        = '0;
    busy                  = 1'b1;
    done                  = 1'b0;
    error                 = 1'b0;
    
    // Loader A configuration
    loaderA_base_addr      = baseA + (tile_m * T * lda + tile_k * T) * W/8;
    loaderA_tile_rows      = T;
    loaderA_tile_cols      = T;  // Not used for row-major A
    loaderA_tile_len_k     = T;
    loaderA_bankset_sel    = bankset_load;
    loaderA_col_major_mode = 1'b0;  // Row-major for A
    
    // Loader B configuration  
    loaderB_base_addr      = baseB + (tile_k * T * ldb + tile_n * T) * W/8;
    loaderB_tile_rows      = T;  // Not used for col-major B
    loaderB_tile_cols      = T;
    loaderB_tile_len_k     = T;
    loaderB_bankset_sel    = bankset_load;
    loaderB_col_major_mode = 1'b1;  // Column-major for B
    
    // Drainer configuration
    drainer_tile_rows    = T;
    drainer_tile_cols    = T;
    drainer_bankset_sel  = 1'b0;  // C results always in bankset 0
    
    // Writer configuration
    writer_base_addr = baseC + (tile_m * T * ldc + tile_n * T) * ACCW/8;
    
    // State-specific outputs
    case (state)
      S_IDLE: begin
        busy = 1'b0;
      end
      
S_LOAD_A: begin
        loaderA_start = 1'b1;
        $display("[%0t] FSM: Starting LoaderA", $time);  // ADD THIS
      end
      
      S_LOAD_B: begin
        loaderB_start = 1'b1;
        $display("[%0t] FSM: Starting LoaderB", $time);  // ADD THIS
      end
      
      S_COMPUTE_INIT: begin
        // Clear accumulator only at the start of a new output tile
        if (tile_k == 0) begin
          array_acc_clear = 1'b1;
        end
      end
      
      S_COMPUTE_FEED: begin
        // Enable bank reads for feeding the array
        // Feed pattern: staggered start for systolic feeding
        for (int i = 0; i < T; i++) begin
    if (feed_cycle >= i && feed_cycle < T + i) begin
      a_bank_rd_en[i] = 1'b1;
      a_addr_idx      = feed_cycle - i;
      a_bank_rd_addr[i] = {bankset_compute, a_addr_idx};
          end
        end
        
        for (int j = 0; j < T; j++) begin
if (feed_cycle >= j && feed_cycle < T + j) begin
      b_bank_rd_en[j] = 1'b1;
      b_addr_idx      = feed_cycle - j;
      b_bank_rd_addr[j] = {bankset_compute, b_addr_idx};
          end
        end
      end
      
      S_COMPUTE_WAIT: begin
        // Send drain pulse after computation
        if (!array_acc_valid[0][0]) begin  // Not yet drained
          array_drain_pulse = 1'b1;
        end
      end
      
      S_DRAIN_INIT: begin
        drainer_start = 1'b1;
      end
      
      S_WRITE_INIT: begin
        writer_start = 1'b1;
      end
      
      S_DONE: begin
        busy = 1'b0;
        done = 1'b1;
      end
      
      S_ERROR: begin
        busy  = 1'b0;
        error = 1'b1;
      end
      
      default: ;
    endcase
  end
  
  // Status output
  assign current_state = {4'b0, state};
  
  // Assertions for debug
  `ifdef SIMULATION
    always @(posedge clk) begin
      if (state == S_COMPUTE_FEED) begin
        $display("[FSM] Cycle %d: Feeding cycle %d/%d", $time, feed_cycle, FEED_CYCLES);
      end
      if (state == S_DRAIN_INIT) begin
        $display("[FSM] Draining tile [%d,%d] after K=%d accumulations", tile_m, tile_n, tile_k+1);
      end
    end
  `endif

endmodule