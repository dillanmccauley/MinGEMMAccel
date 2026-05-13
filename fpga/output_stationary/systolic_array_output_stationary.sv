// =============================================================================
// systolic_array_output_stationary.sv  ?  final
//
// Bug fixed: multiple drivers on b_wire[i][0] for i=1..8.
//   Previous version drove b_wire[i][0] from BOTH the generate assign
//   AND pe(i-1,0).b_out via port connection ? simultaneous drivers.
//   ModelSim warned vsim-3839 and resolved to X, producing garbage results.
//
//   Fix: remove b_wire entirely for the b dimension. Each PE's b_in port
//   connects DIRECTLY to b_in[i] from the external port. b_out is left
//   unconnected (parallel input mode ? no b pipeline propagation needed).
//   This eliminates the multi-driver completely.
//
// The c chain now works because pe_output_stationary.c_out is combinational
// on drain ? c_wire is a combinational adder chain during drain, giving
// c_wire[ROWS] = sum of all PE accumulators in a single clock cycle.
// =============================================================================
module systolic_array_output_stationary #(
    parameter DATA_WIDTH  = 8,
    parameter ACCUM_WIDTH = 32,
    parameter ROWS        = 9,
    parameter COLS        = 1
)(
    input  logic clk,
    input  logic rst,
    input  logic en,
    input  logic drain,
    // a_in[k]: weight for PE row k ? constant across all passes (K=1)
    // b_in[k]: activation for PE row k ? all driven simultaneously (parallel)
    input  logic [DATA_WIDTH-1:0]  a_in  [ROWS-1:0],
    input  logic [DATA_WIDTH-1:0]  b_in  [ROWS-1:0],
    output logic [ACCUM_WIDTH-1:0] c_out [COLS-1:0]
);
    // a_wire: carries weight across columns (left to right)
    logic [DATA_WIDTH-1:0]  a_wire [ROWS-1:0][COLS:0];
 
    // c_wire: carries partial sums down the column (top to bottom)
    // With combinational PE c_out on drain, this is a combinational chain.
    logic [ACCUM_WIDTH-1:0] c_wire [ROWS:0][COLS-1:0];
 
    // b_wire removed ? b_in[i] connects directly to each PE row.
    // No multi-driver conflict possible.
 
    genvar i, j;
 
    // Column output and initial condition
    generate
        for (i = 0; i < COLS; i++) begin : assign_cols
            assign c_out[i]     = c_wire[ROWS][i];
            assign c_wire[0][i] = '0;
        end
    endgenerate
 
    // Weight inputs: one per PE row
    generate
        for (i = 0; i < ROWS; i++) begin : assign_rows
            assign a_wire[i][0] = a_in[i];
        end
    endgenerate
 
    // PE grid: b_in[i] connects directly ? no b_wire, no multi-driver
    generate
        for (i = 0; i < ROWS; i++) begin : row
            for (j = 0; j < COLS; j++) begin : col
                pe_output_stationary #(
                    .DATA_WIDTH  (DATA_WIDTH),
                    .ACCUM_WIDTH (ACCUM_WIDTH)
                ) pe_inst (
                    .clk   (clk),
                    .rst   (rst),
                    .en    (en),
                    .drain (drain),
                    .a_in  (a_wire[i][j]),
                    .b_in  (b_in[i]),          // direct parallel connection ? no b_wire
                    .c_in  (c_wire[i][j]),
                    .a_out (a_wire[i][j+1]),
                    .b_out (),                  // unconnected ? parallel mode has no b propagation
                    .c_out (c_wire[i+1][j])
                );
            end
        end
    endgenerate
 
endmodule
