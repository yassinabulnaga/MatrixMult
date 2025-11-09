// avalon_mm_writer.sv
// Avalon-MM master writer module
// Accepts streamed data beats and writes them to memory via Avalon-MM interface

module avalon_mm_writer #(
  parameter int BEAT_W = 128,  // Data width in bits
  parameter int ADDR_W = 32    // Address width
)(
  input  logic                     clk,
  input  logic                     rst_n,
  
  // Stream input interface (from packer)
  input  logic                     s_valid,
  output logic                     s_ready,
  input  logic [BEAT_W-1:0]        s_data,
  input  logic [BEAT_W/8-1:0]      s_strb,
  input  logic                     s_last,
  
  // Control interface
  input  logic                     start,         // Pulse to begin writing
  input  logic [ADDR_W-1:0]        base_addr,     // Base byte address
  output logic                     busy,
  output logic                     done,          // Pulse when complete
  
  // Avalon-MM master interface
  output logic [ADDR_W-1:0]        avm_address,
  output logic                     avm_write,
  output logic [BEAT_W-1:0]        avm_writedata,
  output logic [BEAT_W/8-1:0]      avm_byteenable,
  output logic [7:0]               avm_burstcount,
  input  logic                     avm_waitrequest
);

  // Local parameters
  localparam int BYTES_PER_BEAT = BEAT_W / 8;
  
  // FSM states
  typedef enum logic [1:0] {
    S_IDLE  = 2'b00,
    S_WRITE = 2'b01,
    S_DONE  = 2'b10
  } state_t;
  
  state_t state, state_nxt;
  
  // Internal signals
  logic [ADDR_W-1:0] addr_q, addr_d;
  logic              last_seen_q, last_seen_d;
  logic              handshake_occurred;
  
  // State register
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
    end else begin
      state <= state_nxt;
    end
  end
  
  // Address and control registers
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      addr_q      <= '0;
      last_seen_q <= 1'b0;
      done        <= 1'b0;
    end else begin
      addr_q      <= addr_d;
      last_seen_q <= last_seen_d;
      done        <= 1'b0;  // Default: clear done
      
      // Generate done pulse
      if (state == S_DONE && state_nxt == S_IDLE) begin
        done <= 1'b1;
      end
    end
  end
  
  // Handshake detection
  assign handshake_occurred = avm_write && !avm_waitrequest;
  
  // Next state logic
  always_comb begin
    state_nxt = state;
    
    case (state)
      S_IDLE: begin
        if (start) begin
          state_nxt = S_WRITE;
        end
      end
      
      S_WRITE: begin
        if (last_seen_q && !s_valid) begin
          // All data written
          state_nxt = S_DONE;
        end
      end
      
      S_DONE: begin
        state_nxt = S_IDLE;
      end
      
      default: state_nxt = S_IDLE;
    endcase
  end
  
  // Datapath and control logic
  always_comb begin
    // Default values
    addr_d      = addr_q;
    last_seen_d = last_seen_q;
    s_ready     = 1'b0;
    avm_write   = 1'b0;
    avm_address = addr_q;
    avm_writedata = s_data;
    avm_byteenable = s_strb;
    avm_burstcount = 8'd1;  // Single beat transfers
    busy        = 1'b1;
    
    case (state)
      S_IDLE: begin
        busy = 1'b0;
        if (start) begin
          addr_d      = base_addr;
          last_seen_d = 1'b0;
        end
      end
      
      S_WRITE: begin
        if (s_valid && !avm_waitrequest) begin
          // Can accept data and write to bus
          s_ready   = 1'b1;
          avm_write = 1'b1;
          
          if (handshake_occurred) begin
            // Update address for next beat
            addr_d = addr_q + BYTES_PER_BEAT;
            
            // Track if this was the last beat
            if (s_last) begin
              last_seen_d = 1'b1;
            end
          end
        end else if (s_valid && avm_waitrequest) begin
          // Hold the write request
          avm_write = 1'b1;
          s_ready   = 1'b0;
        end
      end
      
      S_DONE: begin
        busy = 1'b0;
      end
      
      default: ;
    endcase
  end
  
  // Assertions for debug
  `ifdef SIMULATION
    // Check that we don't lose data
    property p_no_data_loss;
      @(posedge clk) disable iff (!rst_n)
        (s_valid && s_ready) |-> ##1 (avm_write && !avm_waitrequest);
    endproperty
    assert property(p_no_data_loss);
    
    // Check address alignment
    property p_addr_aligned;
      @(posedge clk) disable iff (!rst_n)
        avm_write |-> (avm_address[($clog2(BYTES_PER_BEAT)-1):0] == '0);
    endproperty
    assert property(p_addr_aligned);
  `endif

endmodule