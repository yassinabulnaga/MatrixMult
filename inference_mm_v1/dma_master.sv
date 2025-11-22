//Designed by Yassin Abulnaga


module avalon_mm #(
    parameter int BEAT_W   = 128, // Avalon Bit width  | 16 bytes
    parameter int ADDR_W   = 32,  // Avalon Address width 
    parameter int LENGTH_W = 8,   // Length inside beat
    parameter int BRAM_AW  = 8    // BRAM Address width
)(
    input  logic              clk,
    input  logic              rst_n,

// ====== Control Logic =======

    // Start Logic
    input  logic              start_load_a,  //DDR to BRAM A
    input  logic              start_load_b,  //DDR to BRAM B
    input  logic              start_store_c, //BRAM C to DDR

    //DDR Base Addresses
    input  logic [ADDR_W-1:0] base_addr_a,
    input  logic [ADDR_W-1:0] base_addr_b,
    input  logic [ADDR_W-1:0] base_addr_c,

    // Lengths in beats (each beat = BEAT_W bits = BEAT_W/8 bytes)
    input  logic [LENGTH_W-1:0] length_a,
    input  logic [LENGTH_W-1:0] length_b,
    input  logic [LENGTH_W-1:0] length_c,

    // Status
    output logic              done_load_a,
    output logic              done_load_b,
    output logic              done_store_c,
    output logic              busy,

// ====== Avalon MM Interface ======

    // Bram A (DDR -> BRAM A Load)
    output logic [BRAM_AW-1:0]     bram_a_addr,
    output logic                   bram_a_we,
    output logic                   bram_a_en,
    output logic [BEAT_W-1:0]      bram_a_wdata,

    // Bram B (DDR -> BRAM B Load)
    output logic [BRAM_AW-1:0]     bram_b_addr,
    output logic                   bram_b_we,
    output logic                   bram_b_en,
    output logic [BEAT_W-1:0]      bram_b_wdata,

    // Bram C (BRAM C -> DDR Store)
    output logic [BRAM_AW-1:0]     bram_c_addr,
    output logic                   bram_c_en,
    input  logic [BEAT_W-1:0]      bram_c_rdata,

//===== Avalon MM Master Interface ======

    output logic [ADDR_W-1:0]      avm_address,
    output logic                   avm_read,
    output logic                   avm_write,
    output logic [BEAT_W-1:0]      avm_writedata,
    output logic [BEAT_W/8-1:0]    avm_byteenable,
    output logic [7:0]             avm_burstcount, // always 1 for now
    input  logic [BEAT_W-1:0]      avm_readdata,
    input  logic                   avm_waitrequest,
    input  logic                   avm_readdatavalid
);
   
 //Compile Time Checks
     initial begin
        if (BEAT_W % 8 != 0)
            $fatal(1, "avalon_mm: BEAT_W must be a multiple of 8");
        if (LENGTH_W > BRAM_AW)
            $fatal(1, "avalon_mm: BRAM_AW must be >= LENGTH_W");
    end


    localparam int BYTES_PER_BEAT = BEAT_W / 8;

    // Operation Type
        typedef enum logic [1:0] {
        OP_NONE = 2'd0,
        OP_LOAD_A = 2'd1,
        OP_LOAD_B = 2'd2,
        OP_STORE_C = 2'd3
    } op_e;

    // State Machine States
    typedef enum logic [1:0] {
        ST_IDLE  = 2'd0,
        ST_LOAD  = 2'd1,
        ST_STORE = 2'd2
    } state_e;

    state_e st_q, st_d;
    op_e    op_q, op_d;

    logic [ADDR_W-1:0]   addr_q, addr_d;       // current DDR byte address
    logic [LENGTH_W-1:0] len_q,  len_d;        // total length in beats (latched)
    logic [LENGTH_W-1:0] beat_idx_q, beat_idx_d; // index of current beat [0..len-1]

    logic busy_q, busy_d;

    // For LOAD (DDR -> BRAM):
    logic                 rd_outstanding_q, rd_outstanding_d; // one read in flight

    // For STORE (BRAM C -> DDR):
    logic                 rd_pending_q,   rd_pending_d;   // BRAM C read in flight
    logic [BEAT_W-1:0]    data_q,        data_d;         // buffered BRAM data to write
    logic                 data_valid_q,  data_valid_d;   // data_q is valid

    // Done pulses
    logic done_load_a_q,    done_load_a_d;
    logic done_load_b_q,    done_load_b_d;
    logic done_store_c_q,   done_store_c_d;

    // Sequential Logic 
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st_q             <= ST_IDLE;
            op_q             <= OP_NONE;
            addr_q           <= '0;
            len_q            <= '0;
            beat_idx_q       <= '0;
            busy_q           <= 1'b0;
            rd_outstanding_q <= 1'b0;

            rd_pending_q     <= 1'b0;
            data_q           <= '0;
            data_valid_q     <= 1'b0;

            done_load_a_q    <= 1'b0;
            done_load_b_q    <= 1'b0;
            done_store_c_q   <= 1'b0;
        end else begin
            st_q             <= st_d;
            op_q             <= op_d;
            addr_q           <= addr_d;
            len_q            <= len_d;
            beat_idx_q       <= beat_idx_d;
            busy_q           <= busy_d;
            rd_outstanding_q <= rd_outstanding_d;

            rd_pending_q     <= rd_pending_d;
            data_q           <= data_d;
            data_valid_q     <= data_valid_d;

            done_load_a_q    <= done_load_a_d;
            done_load_b_q    <= done_load_b_d;
            done_store_c_q   <= done_store_c_d;
        end
    end

    always_comb begin
        // Default outputs
        busy          = busy_q;
        done_load_a   = done_load_a_q;
        done_load_b   = done_load_b_q;
        done_store_c  = done_store_c_q;

        // Clear done pulses by default (1-cycle)
        done_load_a_d   = 1'b0;
        done_load_b_d   = 1'b0;
        done_store_c_d  = 1'b0;

        // Avalon defaults
        avm_address   = addr_q;
        avm_read      = 1'b0;
        avm_write     = 1'b0;
        avm_writedata = data_q;
        avm_byteenable= {BEAT_W/8{1'b1}};
        avm_burstcount= 8'd1; // single-beat bursts

        // BRAM defaults
        bram_a_en     = 1'b0;
        bram_a_we     = 1'b0;
        bram_a_addr   = beat_idx_q;
        bram_a_wdata  = avm_readdata;

        bram_b_en     = 1'b0;
        bram_b_we     = 1'b0;
        bram_b_addr   = beat_idx_q;
        bram_b_wdata  = avm_readdata;

        bram_c_en     = 1'b0;
        bram_c_addr   = beat_idx_q;

        // Next-state defaults
        st_d             = st_q;
        op_d             = op_q;
        addr_d           = addr_q;
        len_d            = len_q;
        beat_idx_d       = beat_idx_q;
        busy_d           = busy_q;
        rd_outstanding_d = rd_outstanding_q;

        rd_pending_d     = rd_pending_q;
        data_d           = data_q;
        data_valid_d     = data_valid_q;

        case (st_q)

            // ============================================================
            // IDLE: wait for one of the start_* pulses
            // ============================================================
            ST_IDLE: begin
                busy_d           = 1'b0;
                op_d             = OP_NONE;
                rd_outstanding_d = 1'b0;
                rd_pending_d     = 1'b0;
                data_valid_d     = 1'b0;

                if (start_load_a && (load_a_length_beats != '0)) begin
                    // Start LOAD A
                    op_d       = OP_LOAD_A;
                    addr_d     = load_a_base_addr;
                    len_d      = load_a_length_beats;
                    beat_idx_d = '0;
                    busy_d     = 1'b1;
                    st_d       = ST_LOAD;

                end else if (start_load_b && (load_b_length_beats != '0)) begin
                    // Start LOAD B
                    op_d       = OP_LOAD_B;
                    addr_d     = load_b_base_addr;
                    len_d      = load_b_length_beats;
                    beat_idx_d = '0;
                    busy_d     = 1'b1;
                    st_d       = ST_LOAD;

                end else if (start_store_c && (store_c_length_beats != '0)) begin
                    // Start STORE C
                    op_d         = OP_STORE_C;
                    addr_d       = store_c_base_addr;
                    len_d        = store_c_length_beats;
                    beat_idx_d   = '0;
                    busy_d       = 1'b1;

                    // kick off first BRAM C read
                    bram_c_en    = 1'b1;
                    bram_c_addr  = '0;
                    rd_pending_d = 1'b1;

                    st_d         = ST_STORE;
                end
            end

            // ============================================================
            // ST_LOAD: DDR -> BRAM A/B (read channel)
            // ============================================================
            ST_LOAD: begin
                // 1) Issue read if none outstanding and still beats left
                if (!rd_outstanding_q && (beat_idx_q < len_q) && !avm_waitrequest) begin
                    avm_read        = 1'b1;
                    avm_address     = addr_q;
                    addr_d          = addr_q + BYTES_PER_BEAT;
                    rd_outstanding_d= 1'b1;
                end

                // 2) When read data returns, write to appropriate BRAM
                if (avm_readdatavalid && rd_outstanding_q) begin
                    rd_outstanding_d = 1'b0;

                    // Write into BRAM A or B based on op
                    case (op_q)
                        OP_LOAD_A: begin
                            bram_a_en    = 1'b1;
                            bram_a_we    = 1'b1;
                            bram_a_addr  = beat_idx_q;
                            bram_a_wdata = avm_readdata;
                        end
                        OP_LOAD_B: begin
                            bram_b_en    = 1'b1;
                            bram_b_we    = 1'b1;
                            bram_b_addr  = beat_idx_q;
                            bram_b_wdata = avm_readdata;
                        end
                        default: ; // shouldn't happen
                    endcase

                    // advance beat index
                    beat_idx_d = beat_idx_q + 1;

                    // check if finished
                    if (beat_idx_q + 1 >= len_q) begin
                        // we're done with this load
                        busy_d = 1'b0;
                        st_d   = ST_IDLE;
                        case (op_q)
                            OP_LOAD_A: done_load_a_d   = 1'b1;
                            OP_LOAD_B: done_load_b_d   = 1'b1;
                            default: ;
                        endcase
                    end
                end
            end

            // ============================================================
            // ST_STORE: BRAM C -> DDR (write channel)
            // ============================================================
            ST_STORE: begin
                // Step 1: capture BRAM C data if a read was initiated last cycle
                if (rd_pending_q) begin
                    data_d        = bram_c_rdata;
                    data_valid_d  = 1'b1;
                    rd_pending_d  = 1'b0;
                end

                // Step 2: if we have data and Avalon is not stalling, issue write
                if (data_valid_q && !avm_waitrequest) begin
                    avm_write     = 1'b1;
                    avm_address   = addr_q;
                    avm_writedata = data_q;

                    // advance DDR address
                    addr_d        = addr_q + BYTES_PER_BEAT;

                    // consume this data beat
                    data_valid_d  = 1'b0;
                    beat_idx_d    = beat_idx_q + 1;

                    // If more beats remain, start next BRAM C read
                    if (beat_idx_q + 1 < len_q) begin
                        bram_c_en    = 1'b1;
                        bram_c_addr  = beat_idx_q + 1;
                        rd_pending_d = 1'b1;
                    end else begin
                        // Done
                        busy_d        = 1'b0;
                        st_d          = ST_IDLE;
                        done_store_c_d= 1'b1;
                    end
                end
            end

            default: begin
                st_d = ST_IDLE;
            end

        endcase




    end


   
   
   endmodule