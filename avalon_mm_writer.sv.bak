module avalon_mm_writer #( 

    parameter int BEAT_W  = 128, // bus width
    parameter int ADDR_W  = 32   // address width (bytes)

)(

    input  logic clk,
    input  logic rst_n,

    // packed-beat stream from packer
    input  logic                    s_valid,
    output logic                    s_ready,
    input  logic [BEAT_W-1:0]       s_data,
    input  logic [BEAT_W/8-1:0]     s_strb,
    input  logic                    s_last,

    // control
    input  logic                    start,      // pulse to start a transfer
    input  logic [ADDR_W-1:0]       base_addr,  // byte address
    output logic                    busy,       // high while writing
    output logic                    done,       // 1-cycle pulse when the last beat is accepted

    // Avalon-MM write port
    output logic [ADDR_W-1:0]       avm_address,
    output logic                    avm_write,
    output logic [BEAT_W-1:0]       avm_writedata,
    output logic [BEAT_W/8-1:0]     avm_byteenable,
    output logic [7:0]              avm_burstcount, // single-beat writes
    input  logic                    avm_waitrequest
);

  // Compile-time checks
  initial begin
    if (BEAT_W % 8 != 0) $fatal(1, "writer: BEAT_W must be a multiple of 8");
  end

  localparam int BYTES_PER_BEAT = BEAT_W/8;

  // FSM
  typedef enum logic [1:0] {IDLE, WRITE} state_e;
  state_e st_q, st_d;

  // Accumulators / state
  logic [ADDR_W-1:0] addr_q, addr_d;
  logic              busy_q, busy_d;
  logic              done_q, done_d;

  // registers 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_q    <= IDLE;
      addr_q  <= '0;
      busy_q  <= 1'b0;
      done_q  <= 1'b0;
    end else begin
      st_q    <= st_d;
      addr_q  <= addr_d;
      busy_q  <= busy_d;
      done_q  <= done_d;
    end
  end

  // COMB LOGIC 
  always_comb begin

    // defaults
    s_ready        = 1'b0;
    busy           = busy_q;
    done           = done_q;

    avm_address    = addr_q;
    avm_write      = 1'b0;
    avm_writedata  = s_data;
    avm_byteenable = s_strb;
    avm_burstcount = 8'd1;

    st_d   = st_q;
    addr_d = addr_q;
    busy_d = busy_q;
    done_d = 1'b0; // pulse

    case (st_q)

      IDLE: begin
        if (start) begin
          addr_d = base_addr;
          busy_d = 1'b1;
          st_d   = WRITE;
        end
      end

      WRITE: begin
        // ready only when we can actually issue a write this cycle
        s_ready = !avm_waitrequest;

        // fire write if a beat is available and fabric is ready
        if (s_valid && !avm_waitrequest) begin
          avm_write = 1'b1;

          // advance address after accepted write
          addr_d = addr_q + BYTES_PER_BEAT;

          // complete on last beat
          if (s_last) begin
            busy_d = 1'b0;
            done_d = 1'b1;
            st_d   = IDLE;
          end
        end
      end

      default: st_d = IDLE;

    endcase
  end

endmodule
