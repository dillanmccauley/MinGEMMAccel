module tb_systolic_array_weight_stationary;



    // Parameters

    parameter DATA_WIDTH  = 8;

    parameter ACCUM_WIDTH = 16;

    parameter ARRAY_SIZE  = 3; // Using 3x3 for easier manual matrix verification

    

    // Signals

    logic clk;

    logic rst;

    logic en;

    logic load;

    

    logic [DATA_WIDTH-1:0]  a_in  [ARRAY_SIZE-1:0];

    logic [ACCUM_WIDTH-1:0]  c_in  [ARRAY_SIZE-1:0];

    logic [ACCUM_WIDTH-1:0] c_out [ARRAY_SIZE-1:0];



    // DUT Instantiation

    systolic_array_weight_stationary #(

        .DATA_WIDTH(DATA_WIDTH),

        .ACCUM_WIDTH(ACCUM_WIDTH),

        .ARRAY_SIZE(ARRAY_SIZE)

    ) systolic_array(

        .clk(clk),

        .rst(rst),

.load(load),

        .en(en),

        .a_in(a_in),

        .c_in(c_in),

        .c_out(c_out)

    );



    // Clock Generation

    initial begin

        clk = 0;

        forever #5 clk = ~clk; // 10ns period

    end



// --- Data Definitions ---

real image[3][3] = '{ '{1, 2, 3}, '{4, 5, 6}, '{7, 8, 9} };

real kernel[3][3] = '{ '{9, 8, 7}, '{6, 5, 4}, '{3, 2, 1}};

real current_windows[3][9]; // Holds 3 windows for one pass (3 columns of the array)



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



    int expected_C [ARRAY_SIZE][ARRAY_SIZE];



    // Variables for input streaming

    int cycle;

    int i, j;

    int errors;



    initial begin

        // Expected Matrix C = A * B

        expected_C = '{ '{26, 56, 54}, '{84, 165, 144}, '{134, 236, 186} };



        // 1. Reset the System

        rst = 1;

        en = 0;

        load = 0;

        for (i = 0; i < ARRAY_SIZE; i++) begin

            a_in[i] = 0;

            c_in[i] = 0;

        end

        errors = 0;

        cycle = 0;



        @(negedge clk);

        rst = 0;

        en = 1;



        $display("At init");

 

// 3. Stream data into the array (Parallel Column Version)
        for (int pass = 0; pass < 3; pass++) begin
            // We now track 3 separate partial sums for the 3 columns
            automatic int partial_sums[3] = '{0, 0, 0};

            for (int col_idx = 0; col_idx < 3; col_idx++) 
                get_window(pass, col_idx, current_windows[col_idx]);
            
            $display("\n=================================");
            $display("Processing Output Row %0d (Parallel Columns)", pass);
            $display("=================================");
            
            for (int chunk = 0; chunk < 3; chunk++) begin
                $display("\n  --- Starting Kernel Chunk %0d ---", chunk);
                // A. Load Weights into ALL columns
                load = 1; en = 0;
                for (int w = 2; w >= 0; w--) begin
                    for (int c = 0; c < 3; c++) c_in[c] = kernel[chunk][w];
                    @(negedge clk);
                end
                load = 0; @(negedge clk);
                

                // B. Parallel Stream
                en = 1;
                for (int t = 0; t < 9; t++) begin // Increased t to 9 to flush all columns
                    for (int r = 0; r < 3; r++) begin
                        // Feeding Windows 0, 1, and 2 in sequence
                        automatic int win_idx = t - r; 
                        automatic int elem_idx = (chunk * 3) + r;

                        if (win_idx >= 0 && win_idx < 3)
                            a_in[r] = current_windows[win_idx][elem_idx];
                        else
                            a_in[r] = 0;
                    end

                    // C_IN FEEDBACK: Each column gets its specific window's partial sum
                    // Window W enters Column C at time t = W + C
                    for (int c = 0; c < 3; c++) begin
                        automatic int target_win = t - c; 
                        if (target_win >= 0 && target_win < 3)
                            c_in[c] = partial_sums[target_win];
                        else
                            c_in[c] = 0;
                    end

                    @(negedge clk);

                    // CAPTURE LOGIC: Each window 'W' finishes at Column 'C' 
                    // at time t = W + C + 2 (where 2 is the vertical latency)
                    for (int c = 0; c < 3; c++) begin
                        automatic int finishing_win = t - c - 2;
                        if (finishing_win >= 0 && finishing_win < 3) begin
                            // We only store the value if it's the result of the window 
                            // intended for THIS specific column.
                            // Col 0 -> Win 0, Col 1 -> Win 1, Col 2 -> Win 2
                            if (finishing_win == c) begin
                                partial_sums[c] = c_out[c];
                                if (chunk == 2)
                                    $display("  Time %0t | Final Result: Window %0d from c_out[%0d] = %0d", 
                                             $time, c, c, c_out[c]);
                            end
                        end
                    end
                end
	    end
            // Verification
            $display("\n  --- Row %0d Final Results ---", pass);
            for (int j = 0; j < 3; j++) begin
                $display("  Col %0d: Got %0d (Expected %0d)", j, partial_sums[j], expected_C[pass][j]);
                if (partial_sums[j] !== expected_C[pass][j]) errors++;
            end

            rst = 1; @(negedge clk); rst = 0;
        end



        // Final Result Printout

        $display("\n=================================");

        if (errors == 0)

            $display("SUCCESS: Matrix Multiplication Correct!");

        else

            $display("FAILED with %0d errors.", errors);

        $display("=================================\n");



        $finish;

    end

endmodule