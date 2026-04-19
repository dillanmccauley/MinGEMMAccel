module pe_weight_stationary #(
    parameter DATA_WIDTH = 8,
    parameter ACCUM_WIDTH = 16
)(
    input  logic 		   clk,   // Clock signal
    input  logic 		   rst,   // Reset signal
    input  logic  		   load,  // Load weights signal
    input  logic 		   en,    // Enable signal (calculate output)
    input  logic [DATA_WIDTH-1:0]  a_in,  // Activation from left
    input  logic [ACCUM_WIDTH-1:0] c_in,  // Partial sum from top
    output logic [DATA_WIDTH-1:0]  a_out, // Pass activation right
    output logic [ACCUM_WIDTH-1:0] c_out  // Pass new partial sum down
);
    logic [DATA_WIDTH-1:0] weight_reg;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            weight_reg <= 0;
            a_out      <= 0;
            c_out      <= 0;
	    weight_reg <= 0;
        end else if (load) begin
            weight_reg <= c_in;    // Capture weight for this PE
            c_out      <= c_in;    // Shift weight down to the next PE
        end else if (en) begin
            a_out <= a_in;
            // The "Sum" moves, not the weight
            c_out <= c_in + ACCUM_WIDTH'(a_in * weight_reg); 
        end
    end
endmodule