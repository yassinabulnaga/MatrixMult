module fifo_wrapper #(parameter int W=16, LGFLEN=7)(
  input  logic         clk,
  input  logic         rst_n,
  input  logic [W-1:0] s_data,
  input  logic         s_valid,
  output logic         s_ready,
  output logic [W-1:0] m_data,
  output logic         m_valid,
  input  logic         m_ready
);

  localparam DEPTH = 1 << LGFLEN;
  
  logic [W-1:0] mem [0:DEPTH-1];
  logic [LGFLEN:0] wr_ptr, rd_ptr;
  logic [LGFLEN:0] count;
  
  wire full = (count == DEPTH);
  wire empty = (count == 0);
  
  assign s_ready = !full;
  
  // Write logic
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
    end else if (s_valid && s_ready) begin
      mem[wr_ptr[LGFLEN-1:0]] <= s_data;
      wr_ptr <= wr_ptr + 1;
    end
  end
  
  // Read logic with output register
  logic [W-1:0] m_data_q;
  logic m_valid_q;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_ptr <= '0;
      m_data_q <= '0;
      m_valid_q <= 1'b0;
    end else begin
      if (m_valid_q && !m_ready) begin
        // Stalled - hold output
        m_data_q <= m_data_q;
        m_valid_q <= m_valid_q;
      end else if (!empty) begin
        // Read from FIFO
        m_data_q <= mem[rd_ptr[LGFLEN-1:0]];
        m_valid_q <= 1'b1;
        rd_ptr <= rd_ptr + 1;
      end else begin
        m_valid_q <= 1'b0;
      end
    end
  end
  
  assign m_data = m_data_q;
  assign m_valid = m_valid_q;
  
  // Count logic
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      count <= '0;
    end else begin
      case ({s_valid && s_ready, m_valid_q && m_ready})
        2'b10: count <= count + 1;
        2'b01: count <= count - 1;
        default: count <= count;
      endcase
    end
  end

endmodule
