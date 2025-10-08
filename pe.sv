
module pe #(parameter int W = 8, //data width
         parameter int ACCW = 32, //accumulator width
         parameter bit SIGNED = 1 //signed or unsigned for multiplication
)(
  input  logic  clk,
  input  logic  rst_n,
  //input data 
    input  logic [W-1:0] a,
    input  logic [W-1:0] b,
    input logic a_valid,
    input logic b_valid,
    //output data
    output logic [W-1:0] a_out,
    output logic [W-1:0] b_out,
    output logic a_valid_out,
    output logic b_valid_out,
    // control
    input logic acc_clear_block, // 1-cycle pulse at start of a new C-block
    input logic drain_en,        // assert when it's time to expose result
    output logic [ACCW-1:0]      acc_out,
    output logic                 acc_out_valid
);


//Systolic Shift, Forwarding a and b to next PE
always_ff @(posedge clk or negedge rst_n) begin 

if(!rst_n) begin 

a_valid_out <= 1'b0; b_valid_out <= 1'b0;
a_out <= '0; b_out <= '0;
end
else begin 
a_valid_out <= a_valid; b_valid_out <= b_valid;
a_out <= a; b_out <= b;

end
end

logic [2*W-1:0] prod;
//Multiplication
always_comb begin 
if(SIGNED) prod = $signed(a) * $signed(b); //if signed do signed mult 
else prod = a * b; //else unsigned mult

end

//Accumulation
logic [ACCW-1:0] acc_q; // accumulator sum basically
wire do_mac = a_valid & b_valid; // only do mac when both a and b are valid
wire [ACCW-1:0] prod_sext = {{(ACCW-(2*W)){prod[2*W-1]}}, prod}; // sign-extend product to accumulator width

always_ff @(posedge clk or negedge rst_n) begin
if (!rst_n) acc_q <= '0;
else if (acc_clear_block) acc_q <= '0; // clear acc at start of new C block
else if (do_mac) acc_q <= acc_q + prod_sext; // do mac when both a and b are valid

end

// Draining the accumulator
assign acc_out = acc_q;
assign acc_out_valid = drain_en; // acc_out is valid when drain_en is high


endmodule