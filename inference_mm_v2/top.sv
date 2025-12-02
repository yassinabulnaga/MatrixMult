module matmult(
    input  logic        CLOCK_50,
    input  logic [3:0]  KEY,
    output logic        done
);

logic start_pulse;
logic key3_sync, key3_prev;

// Generate 1-cycle start pulse from KEY3
always_ff @(posedge CLOCK_50) begin
    key3_sync <= ~KEY[3];
    key3_prev <= key3_sync;
end

assign start_pulse = key3_sync & ~key3_prev;

// Instantiate the compute unit
compute_unit #(.N(16)) u_compute_unit (
    .clk   (CLOCK_50),
    .rst   (KEY[0]),      // KEY0 = reset (active low when pressed)
    .start (start_pulse),  // KEY3 = start computation
    .done  (done)
);

endmodule