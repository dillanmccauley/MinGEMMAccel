`timescale 1ns/1ps

module tb_systolic_array_output_stationary;

    parameter DATA_WIDTH  = 8;
    parameter ACCUM_WIDTH = 16;
    parameter ARRAY_SIZE  = 3; 
    
    logic clk, rst, en, drain;
    logic [DATA_WIDTH-1:0]  a_in  [ARRAY_SIZE-1:0];
    logic [DATA_WIDTH-1:0]  b_in  [ARRAY_SIZE-1:0];
    logic [ACCUM_WIDTH-1:0] c_out [ARRAY_SIZE-1:0]; // Streaming output

    // DUT Instantiation
    systolic_array_output_stationary #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .ARRAY_SIZE(ARRAY_SIZE)
    ) dut (.*); // Use .* for brevity if names match

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    real image[3][3] = '{ '{1, 2, 3}, '{4, 5, 6}, '{7, 8, 9} };
    real kernel_flat[9] = '{9, 8, 7, 6, 5, 4, 3, 2, 1};
    real current_windows[3][9];
    int  expected_C [3][3] = '{ '{26, 56, 54}, '{84, 165, 144}, '{134, 236, 186} };
    int  errors = 0;

   	// Helper Function: Extracts a 3x3 window and flattens it
    function void get_window(input int center_row, input int center_col, output real flat_out[9]);
        automatic int idx = 0;
        for (int r = center_row - 1; r <= center_row + 1; r++) begin
            for (int c = center_col - 1; c <= center_col + 1; c++) begin
                // Apply Zero Padding: If out of bounds, value is 0
                if (r < 0 || r > 2 || c < 0 || c > 2)
                    flat_out[idx] = 0;
                else
                    flat_out[idx] = image[r][c];
                idx++;
            end
        end
    endfunction

    initial begin
        // Reset
        rst = 1; en = 0; drain = 0;
        for (int i = 0; i < ARRAY_SIZE; i++) begin a_in[i] = 0; b_in[i] = 0; end
        
        @(negedge clk);
        rst = 0; en = 1;

        for (int pass = 0; pass < 3; pass++) begin
            for (int col_idx = 0; col_idx < 3; col_idx++) get_window(pass, col_idx, current_windows[col_idx]);

            $display("--- Pass %0d: Streaming Inputs ---", pass);

            // Stream 9 elements + Array Skew
            for (int i = 0; i < 9 + ARRAY_SIZE; i++) begin
                // Trigger DRAIN on the last cycle of computation (9th element)
                // Note: In a skewed array, the 'last' element hits different rows at different times.
                // For simplicity here, we trigger drain when the LAST PE (2,2) finishes its 9th MAC.
                drain = (i == 8 + (ARRAY_SIZE-1)); 

                for (int k = 0; k < ARRAY_SIZE; k++) begin
                    if (i >= k && (i - k) < 9) begin
                        a_in[k] = kernel_flat[i-k];
                        b_in[k] = current_windows[k][i-k];
                    end else begin
                        a_in[k] = 0; b_in[k] = 0;
                    end
                end
                @(negedge clk);
            end

            // Now, we wait for the data to SHIFT DOWN to the bottom c_out pins
            repeat(ARRAY_SIZE - 2) @(negedge clk); 

            // VERIFICATION (Checking Row 0)
            for (int j = 0; j < 3; j++) begin
                if (c_out[j] !== expected_C[pass][j]) begin
                    $display("FAIL Pass %0d, Col %0d: Exp %0d, Got %0d", pass, j, expected_C[pass][j], c_out[j]);
                    errors++;
                end else begin
                    $display("PASS Pass %0d, Col %0d: Got %0d", pass, j, c_out[j]);
                end
            end
            
            // NO RST NEEDED! Drain cleared c_accum for us.
            drain = 0;
        end

        $display("\nSimulation Finished. Errors: %0d", errors);
        $finish;
    end
endmodule