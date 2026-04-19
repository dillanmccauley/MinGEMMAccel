module pe_output_stationary #(
    parameter DATA_WIDTH = 8,
    parameter ACCUM_WIDTH = 16
)(
    input  logic                   clk,   // Clock signal
    input  logic                   rst,   // Reset signal
    input  logic                   en,    // Enable signal (calculate output)
    input  logic   		           load,  // Load weights signal
    input  logic [DATA_WIDTH-1:0]  a_in,  // Activation Register input
    input  logic [DATA_WIDTH-1:0]  b_in,  // Weight Register input
    output logic [DATA_WIDTH-1:0]  a_out, // Activation Register output
    output logic [DATA_WIDTH-1:0]  b_out, // Weigth Register output
    output logic [ACCUM_WIDTH-1:0] c_out  // Partial Sum output
);

    always_ff @(posedge clk) begin
        if (rst) begin
            a_out <= '0;
            b_out <= '0;
            c_out <= '0;
        end else if (en) begin
            // Pass data to the next PEs in the array
            a_out <= a_in;
            b_out <= b_in;
            // Multiply and accumulate
            c_out <= c_out + (a_in * b_in);
        end
    end

endmodule