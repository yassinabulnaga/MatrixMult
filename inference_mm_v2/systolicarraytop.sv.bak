module topSystolicArray
 #(parameter int N = 16)(

    input logic                          clk,
    input logic                          rst,
    input logic                          in_valid,

    input logic [N-1:0][N-1:0][7:0]      in_a,
    input logic [N-1:0][N-1:0][7:0]      in_b,

    output logic [N-1:0][N-1:0][31:0]    out_c,
    output logic                         out_valid

 );

    // 3N - 2 cycles from start of processing until all outputs valid
    localparam int unsigned MULT_CYCLES = 3*N-2;
    localparam int unsigned MULT_CYCLES_W = $clog2(MULT_CYCLES+1);

    //Control Process + Counter
    logic [MULT_CYCLES_W-1:0] counter_d, counter_q;
    logic process_d, process_q; 

    always_ff @(posedge clk or negedge rst) begin // counter 
        if (!rst) begin
            counter_q <= '0;
            process_q <= 1'b0;
        end else begin
            counter_q <= counter_d;
            process_q <= process_d;
        end
    end


    always_comb begin
    //defaults
        counter_d = '0;
        process_d = process_q;

        if(in_valid == 1) begin
            process_d = 1'b1;
        end else if (counter_q == MULT_CYCLES_W'(MULT_CYCLES + 1)) begin
            process_d = 1'b0;
        end

        if (process_q == 1) begin
            counter_d = counter_q + 1;
        end 
    end

    assign out_valid = (counter_q == MULT_CYCLES_W'(MULT_CYCLES));

    localparam int unsigned PAD = 8*(N-1);
    localparam logic [PAD-1:0] APPEND_ZERO = '0;


  // The rows are inputs to the in_a port of PEs in the first column.
  // The columns are inputs to the in_b port of PEs in the first row.
    logic [N-1:0][(2*N)-2:0][7:0] row_d, row_q;
    logic [N-1:0][(2*N)-2:0][7:0] col_d, col_q;

    // Input row/column formatting
    logic [N-1:0][N-1:0][7:0] invertedRowElements;
    logic [N-1:0][N-1:0][7:0] invertedColElements;

    genvar i, j_row, j_col;
    
    generate
    for (i = 0; i < N ; i = i + 1) begin: perRowCol

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            row_q[i] <= '0;
        end else begin
            row_q[i] <= row_d[i];
        end
    end

    always_comb begin 

    if (in_valid)begin 
    row_d[i] = {APPEND_ZERO, invertedRowElements[i]} << i*8; //Add Padding & Skew

    end else if(counter_q != 0 )begin
    row_d[i] = row_q[i] >> 8; //Shift Right by 1 Byte

    end else begin
    row_d[i] = row_q[i]; // Idle
     
     end
    end

    //Invert elements in each row
    for (j_row = 0; j_row < N ; j_row = j_row + 1) begin: invertRowElements
    assign invertedRowElements[i][j_row] = in_a[i][N-1-j_row];

    end

    always_ff @(posedge clk or negedge rst) begin
        if (!rst) begin
            col_q[i] <= '0;
        end else begin
            col_q[i] <= col_d[i];
        end
    end

    always_comb begin 

    if (in_valid)begin 
    col_d[i] = {APPEND_ZERO, invertedColElements[i]} << i*8; //Add Padding & Skew

    end else if(counter_q != 0 )begin
    col_d[i] = col_q[i] >> 8; //Shift Right by 1 Byte

    end else begin
    col_d[i] = col_q[i]; // Idle
 
     end
    end

    // Invert the positions of the elements in each col to form the col matrix.
    for (j_col = 0; j_col < N; j_col = j_col + 1) begin: perColElement
    assign  invertedColElements[i][j_col] = in_b[N-j_col-1][i];
    
    end

    end
    endgenerate

    systolicarray #(.N(N)) u_systolicarray (
        .clk        (clk),
        .rst        (rst),
        .process    (process_q),
        .in_row     (row_q),
        .in_col     (col_q),
        .out_c      (out_c)
    );




endmodule