//Designed by Yassin Abulnaga
//Performs 8-bit MAC
module pe   (

    input logic                clk,
    input logic                rst,

    input logic                process,

    input logic signed  [7:0]  in_a,
    input logic signed  [7:0]  in_b,

    output logic signed [7:0]  out_a,
    output logic signed [7:0]  out_b,
    output logic signed [31:0] out
); 

logic signed [31:0] mult; //multiplication  output

logic signed [31:0] mac_d, mac_q; // mac registers

logic signed [7:0] a_q, b_q; // reg inputs

always_comb begin 

mult = $signed(in_a) * $signed(in_b) ;  //signed multiplication

mac_d = (process) ? (mac_q + mult ): mac_q; //  Accumulate

//Forwarding Logic 
out   = mac_q; 
out_a = a_q;
out_b = b_q;
end

 always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin // Active Low Reset
            mac_q <= '0;
            a_q   <= '0;
            b_q   <= '0;
        end else begin
            //reg update
            mac_q <= mac_d; 

            if (process) begin 
                a_q <= in_a;
                b_q <= in_b;
            end
        end
    end


endmodule