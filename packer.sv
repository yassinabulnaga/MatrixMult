module packer #( 

    parameter int W     = 16, // Element width
    parameter int BEAT_W = 128, // output bus width
    parameter bit LSB_FIRST = 1 // 1: place element in least significant bits

)(

    input logic clk,
    input logic rst_n,

    //FIFO element stream
    input logic s_valid,
    output logic s_ready,
    input logic [W-1:0] s_data,
    input logic s_last,
    
    //Avalon Downstream
    output logic m_valid,
    input logic m_ready,
    output logic [BEAT_W -1:0] m_data,
    output logic [BEAT_W/8-1:0] m_strb,
    output logic m_last // 1 on last beat
);

  // Compile-time checks
  initial begin
    if (W % 8 != 0) $fatal(1, "packer: W must be a multiple of 8");
    if (BEAT_W % 8 != 0) $fatal(1, "packer: BEAT_W must be a multiple of 8");
    if ((BEAT_W % W) != 0) $fatal(1, "packer: BEAT_W must be a multiple of W for simple packing");
  end

  
  localparam int BYTES_PER_ELEM = W/8;
  localparam int BYTES_PER_BEAT = BEAT_W/8;
  localparam int ELS_PER_BEAT   = BEAT_W / W;

  // Accumulators
  logic [BEAT_W-1:0]    acc_data_q, acc_data_d;
  logic [BYTES_PER_BEAT-1:0] acc_strb_q, acc_strb_d;
  logic [$clog2(ELS_PER_BEAT+1)-1:0] cnt_q, cnt_d;  // how many elems collected in current beat
  logic                        hold_full_q, hold_full_d;


  // End-of-transfer tracking (to mark m_last on the last emitted beat)
  logic eot_seen_q, eot_seen_d;   // latched s_last for a partial-in-progress beat

  // registers 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_data_q  <= '0;
      acc_strb_q  <= '0;
      cnt_q       <= '0;
      hold_full_q <= 1'b0;
      eot_seen_q  <= 1'b0;
    end else begin
      acc_data_q  <= acc_data_d;
      acc_strb_q  <= acc_strb_d;
      cnt_q       <= cnt_d;
      hold_full_q <= hold_full_d;
      eot_seen_q  <= eot_seen_d;
    end
  end


  //COMB LOGIC 
  always_comb begin 

    //defaults
    s_ready     = 1'b0;
    m_valid     = 1'b0;
    m_data      = acc_data_q;
    m_strb      = acc_strb_q;
    m_last      = 1'b0;
    acc_data_d  = acc_data_q;
    acc_strb_d  = acc_strb_q;
    cnt_d       = cnt_q;
    hold_full_d = hold_full_q;
    eot_seen_d  = eot_seen_q;

    //if full beat pass downstream 
    if (hold_full_q) begin 

        m_valid = 1'b1;
        m_data = acc_data_q;
        m_strb  = acc_strb_q;
        m_last  = eot_seen_q;  // if the full beat coincides with end-of-transfer
  
        if (m_ready) begin
            // Beat accepted, clear accumulator
            hold_full_d = 1'b0;
            cnt_d       = '0;
            acc_data_d  = '0;
            acc_strb_d  = '0;
            eot_seen_d  = 1'b0;
        end

    end else begin 

        s_ready = 1'b1; //accept upstream data

        if(s_valid && s_ready) begin

            //place element at slot = cnt_q | Pointers for element
            automatic int slot = cnt_q;
            automatic int bit_lo = LSB_FIRST ? slot*W : (BEAT_W - (slot+1)*W);
            automatic int bit_hi = bit_lo + W - 1;

            acc_data_d[bit_hi:bit_lo] = s_data;

            // Byte-enable pointers for this element
            automatic int byte_lo = LSB_FIRST ? slot*BYTES_PER_ELEM : (BYTES_PER_BEAT - (slot+1)*BYTES_PER_ELEM);
            automatic int byte_hi = byte_lo + BYTES_PER_ELEM - 1;

            for (int b = byte_lo; b <= byte_hi; b++) begin
              acc_strb_d[b] = 1'b1;
            end

            // Advance count
            cnt_d = cnt_q + 1'b1;

            if(cnt_q+1'b1 == ELS_PER_BEAT)begin

              hold_full_d = 1'b1; // full beat
              if(s_last) eot_seen_d = 1'b1;

            end else begin
              //Not full beat, if S_last flush the partial beat anyways
              if(s_last) eot_seen_d = 1'b1;
            end
        end

        //Partial beat flush path : if eot seen + cnt>0 flush
        if(!hold_full_q && eot_seen_q && (cnt_q>0)) begin 

            m_valid = 1'b1;
            m_data = acc_data_q;   // use registered accumulators here
            m_strb  = acc_strb_q;
            m_last  = 1'b1;

            s_ready = 1'b0; //block upstream

             if (m_ready) begin
                  // Partial beat accepted → clear acc
                  hold_full_d = 1'b0;
                  cnt_d       = '0;
                  acc_data_d  = '0;
                  acc_strb_d  = '0;
                  eot_seen_d  = 1'b0;
             end
        end
    end
  end

endmodule
