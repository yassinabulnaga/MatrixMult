// result_drain.sv
// Drains a C tile from row-banked BRAMs (bank=row, addr={bankset_sel, col}).
// One element per cycle with ready/valid; assumes 1-cycle BRAM read latency.

module result_drain #(
    parameter int W  = 8,    // element width
    parameter int T  = 16,   // number of banks (rows)
    parameter int AW = 10    // per-bank address width (bankset_sel + col bits)
)(
    input  logic                 clk,
    input  logic                 rst_n,

    // Control
    input  logic                 start,        // pulse to begin draining this tile
    output logic                 busy,
    output logic                 done,         // 1-cycle pulse when tile drained

    // Tile shape / selection
    input  logic [15:0]          tile_rows,    // <= T
    input  logic [15:0]          tile_cols,    // <= 2**(AW-1)
    input  logic                 bankset_sel,  // MSB of address

    // BRAM Port-A (READ) per bank (connect to C_banks Port-A)
    output logic [T-1:0]         a_en,
    output logic [T-1:0][AW-1:0] a_addr,
    input  logic [T-1:0][W-1:0]  a_dout,

    // Stream out (to elem FIFO / packer)
    output logic                 out_valid,
    output logic [W-1:0]         out_data,
    input  logic                 out_ready,

    // Packer assist
    output logic                 flush         // 1-cycle pulse on last element
);

    // FSM
    typedef enum logic [1:0] {S_IDLE, S_ISSUE, S_EMIT, S_DONE} st_t;
    st_t st, st_n;

    // Indices
    logic [15:0] row_i, col_i;
    logic [15:0] next_row, next_col;

    // BRAM read pipeline (1-cycle)
    logic        rd_valid_q;
    logic [W-1:0]rd_data_q;
    logic [15:0] rd_row_q;   // which bank we addressed last cycle

    // Busy = any active draining
    assign busy = (st != S_IDLE) && (st != S_DONE);

    // Stream outputs directly from pipeline
    assign out_valid = rd_valid_q;
    assign out_data  = rd_data_q;

    // FSM state reg
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            st <= S_IDLE;
        else
            st <= st_n;
    end

    // Main sequential: indices, BRAM control, pipeline, done/flush
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_i      <= '0;
            col_i      <= '0;
            rd_valid_q <= 1'b0;
            rd_data_q  <= '0;
            rd_row_q   <= '0;

            a_en       <= '0;
            a_addr     <= '0;

            done       <= 1'b0;
            flush      <= 1'b0;
        end else begin
            // defaults each cycle
            a_en       <= '0;
            a_addr     <= '0;
            done       <= 1'b0;
            flush      <= 1'b0;

            // capture BRAM data when valid
            if (rd_valid_q) begin
                rd_data_q <= a_dout[rd_row_q];
            end

            unique case (st)
                // ---------------- IDLE ----------------
                S_IDLE: begin
                    rd_valid_q <= 1'b0;
                    if (start) begin
                        row_i      <= 16'd0;
                        col_i      <= 16'd0;
                    end
                end

                // ---------------- ISSUE ----------------
                // Issue first read based on (row_i, col_i)
                S_ISSUE: begin
                    if ((tile_rows != 0) && (tile_cols != 0) &&
                        (row_i < tile_rows) && (col_i < tile_cols)) begin
                        a_en[row_i]            <= 1'b1;
                        a_addr[row_i][AW-1]    <= bankset_sel;
                        a_addr[row_i][AW-2:0]  <= col_i[AW-2:0];

                        rd_valid_q             <= 1'b1;     // expect data next cycle
                        rd_row_q               <= row_i;
                    end else begin
                        rd_valid_q <= 1'b0;                 // empty/invalid tile guard
                    end
                end

                // ---------------- EMIT ----------------
                // Stream out and issue subsequent reads
                S_EMIT: begin
                    // Default next indices = current
                    next_row = row_i;
                    next_col = col_i;

                    if (rd_valid_q && (out_ready || !out_valid)) begin
                        // We are consuming one element this cycle.

                        // Check if this was the last element
                        if ((row_i == tile_rows-1) && (col_i == tile_cols-1)) begin
                            // Last element emitted
                            flush      <= 1'b1;     // tell packer to flush (if partial beat)
                            rd_valid_q <= 1'b0;     // no next data in flight
                            // FSM will move to S_DONE via next-state logic
                        end else begin
                            // Advance to next element (row-major)
                            if (col_i + 1 == tile_cols) begin
                                next_col = 16'd0;
                                next_row = row_i + 1;
                            end else begin
                                next_col = col_i + 1;
                                next_row = row_i + 1'b0;
                                next_col = col_i + 1;
                            end

                            // Issue next read if still in bounds
                            if ((next_row < tile_rows) && (next_col < tile_cols)) begin
                                a_en[next_row]            <= 1'b1;
                                a_addr[next_row][AW-1]    <= bankset_sel;
                                a_addr[next_row][AW-2:0]  <= next_col[AW-2:0];

                                rd_valid_q                <= 1'b1;
                                rd_row_q                  <= next_row;
                            end else begin
                                rd_valid_q <= 1'b0;
                            end

                            // Commit updated indices
                            row_i <= next_row;
                            col_i <= next_col;
                        end
                    end
                end

                // ---------------- DONE ----------------
                S_DONE: begin
                    done       <= 1'b1;   // one-cycle pulse
                    rd_valid_q <= 1'b0;
                end
            endcase
        end
    end

    // Next-state logic
    always_comb begin
        st_n = st;
        unique case (st)
            S_IDLE:  if (start)     st_n = S_ISSUE;
            S_ISSUE:               st_n = S_EMIT;  // first data comes next
            S_EMIT: begin
                // Go to DONE once we've emitted last element
                if ((row_i == tile_rows-1) &&
                    (col_i == tile_cols-1) &&
                    rd_valid_q && out_ready)
                    st_n = S_DONE;
            end
            S_DONE:                st_n = S_IDLE;
            default:               st_n = S_IDLE;
        endcase
    end

    // Synthesis-time sanity (ignored in synth)
    // pragma translate_off
    initial begin
        if (T < 1)  $fatal(1, "T must be >= 1");
        if (AW < 2) $fatal(1, "AW must be >= 2");
    end
    // pragma translate_on

endmodule
