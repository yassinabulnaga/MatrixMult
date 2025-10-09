module fifo_sync #(parameter int W = 16, //data width
                   parameter int DEPTH = 64 //depth of fifo
)(
  input  logic  clk,
  input  logic  rst_n,
  //Write side
    input  logic [W-1:0] s_data,
    input logic s_valid,
    output logic s_ready,

    //Read side
    output logic [W-1:0] m_data,
    output logic m_valid,
    input logic m_ready
);

  (* ramstyle = "M10K, no_rw_check" *) logic [W-1:0] mem [0:DEPTH-1]; // memory array 
localparam int AW = (DEPTH <= 2) ? 1 : $clog2(DEPTH); // address width  clog tells you how many bits you need per depth of fifo
logic [AW-1:0] wptr, rptr; // write and read pointers 
logic [$clog2(DEPTH):0] count;

// handshake signals
wire do_write = s_valid && s_ready; 
wire do_read = m_valid && m_ready; 

//flow control
assign s_ready = (count != DEPTH); // can write if fifo not full
assign m_valid = (count != 0); // can read if fifo not empty


//FWFT
assign m_data  = mem[rptr];

//Write logic
always_ff @(posedge clk or negedge rst_n) begin
if(!rst_n) begin
wptr <= '0;
    end
else if (do_write) begin
mem[wptr] <= s_data; // write data to memory
wptr <= (wptr == DEPTH - 1 ) ? '0 : (wptr + 1'b1 );   // if were at end go to start, else increment the write pointer 
end
end

  // read data 
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rptr <= '0;
    end else if (do_read) begin
      rptr <= (rptr == DEPTH-1) ? '0 : (rptr + 1'b1);
    end
  end

//count logic 

always_ff @(posedge clk or negedge rst_n) begin

if(!rst_n) count <= '0;
else begin
 unique case ({do_write, do_read})
 
 2'b00: count <= count; // no change
 2'b01: count <= count - 1; // read
 2'b10: count<= count +1; // write
2'b11: count <= count; // no change
  endcase
end
end
endmodule