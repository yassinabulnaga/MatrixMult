// Top Module - Matrix Multiply Accelerator
// Integrates: DMA, FSM, Compute Unit, BRAMs

module matmul_accelerator #(
    parameter int N = 16
)(
    input  logic        clk,
    input  logic        rst,
    
    // Control interface (from CPU)
    input  logic        start,
    input  logic [31:0] ddr_addr_a,
    input  logic [31:0] ddr_addr_b,
    input  logic [31:0] ddr_addr_c,
    output logic        complete,
    output logic        busy,
    
    // Avalon-MM Master to DDR
    output logic [31:0] avm_address,
    output logic        avm_read,
    output logic        avm_write,
    output logic [31:0] avm_writedata,
    input  logic [31:0] avm_readdata,
    input  logic        avm_readdatavalid,
    input  logic        avm_waitrequest,
    output logic [3:0]  avm_byteenable
);

    // DMA <-> FSM signals
    logic        dma_start_load_a, dma_start_load_b, dma_start_store_c;
    logic [31:0] dma_addr_a, dma_addr_b, dma_addr_c;
    logic        dma_done, dma_busy;
    
    // Compute <-> FSM signals
    logic compute_start, compute_done;
    
    // BRAM A signals
    logic [15:0][7:0] bram_a_addr_dma, bram_a_addr_compute;
    logic [15:0][7:0] bram_a_wdata;
    logic [15:0]      bram_a_wren;
    logic [15:0][7:0] bram_a_rdata;
    logic [15:0][7:0] bram_a_addr;
    
    // BRAM B signals
    logic [15:0][7:0] bram_b_addr_dma, bram_b_addr_compute;
    logic [15:0][7:0] bram_b_wdata;
    logic [15:0]      bram_b_wren;
    logic [15:0][7:0] bram_b_rdata;
    logic [15:0][7:0] bram_b_addr;
    
    // BRAM C signals
    logic [15:0][7:0]  bram_c_addr_dma, bram_c_addr_compute;
    logic [15:0][31:0] bram_c_wdata;
    logic [15:0]       bram_c_wren;
    logic [15:0][31:0] bram_c_rdata;
    logic [15:0][7:0]  bram_c_addr;
    
    // Mux BRAM signals between DMA and Compute
    always_comb begin
        if (dma_busy) begin
            bram_a_addr = bram_a_addr_dma;
            bram_b_addr = bram_b_addr_dma;
            bram_c_addr = bram_c_addr_dma;
        end else begin
            bram_a_addr = bram_a_addr_compute;
            bram_b_addr = bram_b_addr_compute;
            bram_c_addr = bram_c_addr_compute;
        end
    end
    
    // Main FSM
    matmul_fsm #(.N(N)) u_fsm (
        .clk                (clk),
        .rst                (rst),
        .start              (start),
        .ddr_addr_a         (ddr_addr_a),
        .ddr_addr_b         (ddr_addr_b),
        .ddr_addr_c         (ddr_addr_c),
        .complete           (complete),
        .busy               (busy),
        .dma_start_load_a   (dma_start_load_a),
        .dma_start_load_b   (dma_start_load_b),
        .dma_start_store_c  (dma_start_store_c),
        .dma_addr_a         (dma_addr_a),
        .dma_addr_b         (dma_addr_b),
        .dma_addr_c         (dma_addr_c),
        .dma_done           (dma_done),
        .dma_busy           (dma_busy),
        .compute_start      (compute_start),
        .compute_done       (compute_done)
    );
    
    // DMA Controller
    dma_controller #(.N(N)) u_dma (
        .clk                (clk),
        .rst                (rst),
        .start_load_a       (dma_start_load_a),
        .start_load_b       (dma_start_load_b),
        .start_store_c      (dma_start_store_c),
        .addr_a             (dma_addr_a),
        .addr_b             (dma_addr_b),
        .addr_c             (dma_addr_c),
        .done               (dma_done),
        .busy               (dma_busy),
        .avm_address        (avm_address),
        .avm_read           (avm_read),
        .avm_write          (avm_write),
        .avm_writedata      (avm_writedata),
        .avm_readdata       (avm_readdata),
        .avm_readdatavalid  (avm_readdatavalid),
        .avm_waitrequest    (avm_waitrequest),
        .avm_byteenable     (avm_byteenable),
        .bram_a_addr        (bram_a_addr_dma),
        .bram_a_wdata       (bram_a_wdata),
        .bram_a_wren        (bram_a_wren),
        .bram_b_addr        (bram_b_addr_dma),
        .bram_b_wdata       (bram_b_wdata),
        .bram_b_wren        (bram_b_wren),
        .bram_c_addr        (bram_c_addr_dma),
        .bram_c_rdata       (bram_c_rdata)
    );
    
    // Compute Unit
    compute_unit #(.N(N)) u_compute (
        .clk            (clk),
        .rst            (rst),
        .start          (compute_start),
        .done           (compute_done),
        .bram_a_addr    (bram_a_addr_compute),
        .bram_a_rdata   (bram_a_rdata),
        .bram_b_addr    (bram_b_addr_compute),
        .bram_b_rdata   (bram_b_rdata),
        .bram_c_addr    (bram_c_addr_compute),
        .bram_c_wdata   (bram_c_wdata),
        .bram_c_wren    (bram_c_wren)
    );
    
    // BRAM A instances (16 banks)
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : bram_a_banks
            bram u_bram_a (
                .address_a  (bram_a_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_a_wdata[i]),
                .data_b     (8'h00),
                .wren_a     (bram_a_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_a_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // BRAM B instances (16 banks)
    generate
        for (i = 0; i < 16; i++) begin : bram_b_banks
            bram u_bram_b (
                .address_a  (bram_b_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_b_wdata[i]),
                .data_b     (8'h00),
                .wren_a     (bram_b_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_b_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // BRAM C instances (16 banks)
    generate
        for (i = 0; i < 16; i++) begin : bram_c_banks
            bramc u_bram_c (
                .address_a  (bram_c_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_c_wdata[i]),
                .data_b     (32'h00000000),
                .wren_a     (bram_c_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_c_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate

endmodule// Top Module - Matrix Multiply Accelerator
// Integrates: DMA, FSM, Compute Unit, BRAMs

module matmul_accelerator #(
    parameter int N = 16
)(
    input  logic        clk,
    input  logic        rst,
    
    // Control interface (from CPU)
    input  logic        start,
    input  logic [31:0] ddr_addr_a,
    input  logic [31:0] ddr_addr_b,
    input  logic [31:0] ddr_addr_c,
    output logic        complete,
    output logic        busy,
    
    // Avalon-MM Master to DDR
    output logic [31:0] avm_address,
    output logic        avm_read,
    output logic        avm_write,
    output logic [31:0] avm_writedata,
    input  logic [31:0] avm_readdata,
    input  logic        avm_readdatavalid,
    input  logic        avm_waitrequest,
    output logic [3:0]  avm_byteenable
);

    // DMA <-> FSM signals
    logic        dma_start_load_a, dma_start_load_b, dma_start_store_c;
    logic [31:0] dma_addr_a, dma_addr_b, dma_addr_c;
    logic        dma_done, dma_busy;
    
    // Compute <-> FSM signals
    logic compute_start, compute_done;
    
    // BRAM A signals
    logic [15:0][7:0] bram_a_addr_dma, bram_a_addr_compute;
    logic [15:0][7:0] bram_a_wdata;
    logic [15:0]      bram_a_wren;
    logic [15:0][7:0] bram_a_rdata;
    logic [15:0][7:0] bram_a_addr;
    
    // BRAM B signals
    logic [15:0][7:0] bram_b_addr_dma, bram_b_addr_compute;
    logic [15:0][7:0] bram_b_wdata;
    logic [15:0]      bram_b_wren;
    logic [15:0][7:0] bram_b_rdata;
    logic [15:0][7:0] bram_b_addr;
    
    // BRAM C signals
    logic [15:0][7:0]  bram_c_addr_dma, bram_c_addr_compute;
    logic [15:0][31:0] bram_c_wdata;
    logic [15:0]       bram_c_wren;
    logic [15:0][31:0] bram_c_rdata;
    logic [15:0][7:0]  bram_c_addr;
    
    // Mux BRAM signals between DMA and Compute
    always_comb begin
        if (dma_busy) begin
            bram_a_addr = bram_a_addr_dma;
            bram_b_addr = bram_b_addr_dma;
            bram_c_addr = bram_c_addr_dma;
        end else begin
            bram_a_addr = bram_a_addr_compute;
            bram_b_addr = bram_b_addr_compute;
            bram_c_addr = bram_c_addr_compute;
        end
    end
    
    // Main FSM
    matmul_fsm #(.N(N)) u_fsm (
        .clk                (clk),
        .rst                (rst),
        .start              (start),
        .ddr_addr_a         (ddr_addr_a),
        .ddr_addr_b         (ddr_addr_b),
        .ddr_addr_c         (ddr_addr_c),
        .complete           (complete),
        .busy               (busy),
        .dma_start_load_a   (dma_start_load_a),
        .dma_start_load_b   (dma_start_load_b),
        .dma_start_store_c  (dma_start_store_c),
        .dma_addr_a         (dma_addr_a),
        .dma_addr_b         (dma_addr_b),
        .dma_addr_c         (dma_addr_c),
        .dma_done           (dma_done),
        .dma_busy           (dma_busy),
        .compute_start      (compute_start),
        .compute_done       (compute_done)
    );
    
    // DMA Controller
    dma_controller #(.N(N)) u_dma (
        .clk                (clk),
        .rst                (rst),
        .start_load_a       (dma_start_load_a),
        .start_load_b       (dma_start_load_b),
        .start_store_c      (dma_start_store_c),
        .addr_a             (dma_addr_a),
        .addr_b             (dma_addr_b),
        .addr_c             (dma_addr_c),
        .done               (dma_done),
        .busy               (dma_busy),
        .avm_address        (avm_address),
        .avm_read           (avm_read),
        .avm_write          (avm_write),
        .avm_writedata      (avm_writedata),
        .avm_readdata       (avm_readdata),
        .avm_readdatavalid  (avm_readdatavalid),
        .avm_waitrequest    (avm_waitrequest),
        .avm_byteenable     (avm_byteenable),
        .bram_a_addr        (bram_a_addr_dma),
        .bram_a_wdata       (bram_a_wdata),
        .bram_a_wren        (bram_a_wren),
        .bram_b_addr        (bram_b_addr_dma),
        .bram_b_wdata       (bram_b_wdata),
        .bram_b_wren        (bram_b_wren),
        .bram_c_addr        (bram_c_addr_dma),
        .bram_c_rdata       (bram_c_rdata)
    );
    
    // Compute Unit
    compute_unit #(.N(N)) u_compute (
        .clk            (clk),
        .rst            (rst),
        .start          (compute_start),
        .done           (compute_done),
        .bram_a_addr    (bram_a_addr_compute),
        .bram_a_rdata   (bram_a_rdata),
        .bram_b_addr    (bram_b_addr_compute),
        .bram_b_rdata   (bram_b_rdata),
        .bram_c_addr    (bram_c_addr_compute),
        .bram_c_wdata   (bram_c_wdata),
        .bram_c_wren    (bram_c_wren)
    );
    
    // BRAM A instances (16 banks)
    genvar i;
    generate
        for (i = 0; i < 16; i++) begin : bram_a_banks
            bram u_bram_a (
                .address_a  (bram_a_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_a_wdata[i]),
                .data_b     (8'h00),
                .wren_a     (bram_a_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_a_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // BRAM B instances (16 banks)
    generate
        for (i = 0; i < 16; i++) begin : bram_b_banks
            bram u_bram_b (
                .address_a  (bram_b_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_b_wdata[i]),
                .data_b     (8'h00),
                .wren_a     (bram_b_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_b_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate
    
    // BRAM C instances (16 banks)
    generate
        for (i = 0; i < 16; i++) begin : bram_c_banks
            bramc u_bram_c (
                .address_a  (bram_c_addr[i]),
                .address_b  (8'h00),
                .clock      (clk),
                .data_a     (bram_c_wdata[i]),
                .data_b     (32'h00000000),
                .wren_a     (bram_c_wren[i]),
                .wren_b     (1'b0),
                .q_a        (bram_c_rdata[i]),
                .q_b        ()
            );
        end
    endgenerate

endmodule