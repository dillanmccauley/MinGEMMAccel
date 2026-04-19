module systolic_array_weight_stationary #(
    parameter DATA_WIDTH  = 8,
    parameter ACCUM_WIDTH = 16,
    parameter ARRAY_SIZE  = 3
)(
    input  logic clk,
    input  logic rst,
    input  logic en,
    input  logic load,
    
    // Streaming inputs: one element per row/col per clock
    input wire logic [DATA_WIDTH-1:0]  a_in [ARRAY_SIZE-1:0],
    input wire logic [ACCUM_WIDTH-1:0]  c_in [ARRAY_SIZE-1:0],
    
    // Accumulated output matrix C
    output logic [ACCUM_WIDTH-1:0] c_out [ARRAY_SIZE-1:0]
);

    // Interconnect wires between PEs
    // a_wire connects left-to-right, c_wire connects top-to-bottom
    logic [DATA_WIDTH-1:0] a_wire [ARRAY_SIZE-1:0][ARRAY_SIZE:0];
    logic [ACCUM_WIDTH-1:0] c_wire [ARRAY_SIZE:0][ARRAY_SIZE-1:0];

    genvar r, c;
    generate
        for (r = 0; r < ARRAY_SIZE; r++) begin : row_gen
            for (c = 0; c < ARRAY_SIZE; c++) begin : col_gen
                
                // --- Boundary Assignments ---
                
                // 1. Left Edge: Feed a_in into the horizontal wire grid
                if (c == 0) assign a_wire[r][0] = a_in[r];
                
                // 2. Top Edge: Feed c_in to vertical wire grid
                if (r == 0) assign c_wire[0][c] = c_in[c];
                
                // 3. Bottom Edge: Feed the last vertical wire to the output port
                if (r == ARRAY_SIZE-1) assign c_out[c] = c_wire[ARRAY_SIZE][c];

                // --- PE Instantiation ---
                pe_weight_stationary #(DATA_WIDTH, ACCUM_WIDTH) pe (
                    .clk   (clk),
                    .rst   (rst),
                    .load  (load),
                    .en    (en),
                    .a_in  (a_wire[r][c]),     // Activation from left
                    .c_in  (c_wire[r][c]),     // Partial sum from top
                    .a_out (a_wire[r][c+1]),   // Pass activation right
                    .c_out (c_wire[r+1][c])    // Pass partial sum down
                );
            end
        end
    endgenerate

endmodule