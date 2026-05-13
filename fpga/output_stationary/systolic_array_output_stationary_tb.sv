`timescale 1ns/1ps
`include "gemm_pkg.sv"

// =============================================================================
// tb_1x9_conv  ?  clock realignment fix
//
// Root cause of got=0: gather task uses #1 delays (9 total = 9ns).
//
// Clock is 10ns period (posedge at 5ns, negedge at 10ns).
// Gather runs from T=Tn to T=Tn+9ns. A posedge fires at T=Tn+5ns ? in the
// MIDDLE of gather ? with a_in=0, b_in=0 (stream not started yet).
// c_accum accumulates 0 at that posedge.
//
// After gather finishes at T=Tn+9ns, stream_and_verify sets a/b at T=Tn+9ns
// and calls @(negedge clk) which returns at T=Tn+10ns.
// Between T=Tn+9ns and T=Tn+10ns there is NO posedge.
// Then drain=1 is set immediately, and the NEXT posedge at T=Tn+15ns sees
// drain=1 ? skipping the accumulate branch entirely.
// c_accum stays 0 ? c_out = 0 on drain.
//
// Fix: add ONE @(negedge clk) at the start of stream_and_verify.
// This advances to T=Tn+10ns (negedge), then T=Tn+20ns (next negedge), with
// a clean posedge at T=Tn+15ns ? AFTER gather, BEFORE drain.
// a/b are driven at T=Tn+10ns; posedge at T=Tn+15ns fires with correct values.
// c_accum accumulates correctly. Then drain fires on the following posedge.
//
// Per-pass timing after fix:
//   Cycle 0 (realign):  @(negedge clk) ? consumes dirty posedge from gather
//   Cycle 1 (MAC):      drive a/b, @(negedge clk) ? posedge accumulates c_accum
//   Cycle 2 (drain):    drain=1, a/b=0, @(negedge clk) ? drain_r=1, c_accum valid
//                       SAMPLE c_out[0] at this negedge
//   Cycle 3 (clear):    drain=0, @(negedge clk) ? c_accum clears
// =============================================================================

module tb_1x9_conv;
    import gemm_pkg::*;

    // -------------------------------------------------------------------------
    // Parameters
    // -------------------------------------------------------------------------
    parameter DATA_WIDTH  = 8;
    parameter ACCUM_WIDTH = 32;
    parameter PE_ROWS     = 9;
    parameter PE_COLS     = 1;

    parameter H   = 3, W   = 3;
    parameter KH  = 3, KW  = 3;
    parameter S   = 1, PAD = 1;
    parameter OH  = 3, OW  = 3;
    parameter COL_ROWS = KH * KW;   // 9
    parameter COL_COLS = OH * OW;   // 9

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    logic clk, rst, en, drain;
    logic [DATA_WIDTH-1:0]  a_in  [PE_ROWS-1:0];
    logic [DATA_WIDTH-1:0]  b_in  [PE_ROWS-1:0];
    logic [ACCUM_WIDTH-1:0] c_out [PE_COLS-1:0];

    // -------------------------------------------------------------------------
    // addr gen ports
    // -------------------------------------------------------------------------
    logic [$clog2(COL_COLS)-1:0] ag_col_idx;
    logic [$clog2(COL_ROWS)-1:0] ag_row_idx;
    logic [IMG_ABITS-1:0]        ag_img_addr;
    logic                        ag_pad_pixel;

    // -------------------------------------------------------------------------
    // Instantiations
    // -------------------------------------------------------------------------
    systolic_array_output_stationary #(
        .DATA_WIDTH  (DATA_WIDTH),
        .ACCUM_WIDTH (ACCUM_WIDTH),
        .ROWS        (PE_ROWS),
        .COLS        (PE_COLS)
    ) dut (
        .clk   (clk), .rst (rst), .en (en), .drain (drain),
        .a_in  (a_in), .b_in (b_in), .c_out (c_out)
    );

    im2col_addr_gen addr_gen (
        .col_idx   (ag_col_idx), .row_idx   (ag_row_idx),
        .img_addr  (ag_img_addr), .pad_pixel (ag_pad_pixel)
    );

    // -------------------------------------------------------------------------
    // Clock ? 10ns period
    // -------------------------------------------------------------------------
    initial clk = 0;
    always  #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Memories
    // -------------------------------------------------------------------------
    logic [DATA_WIDTH-1:0]  image_sram [0:8];
    logic [DATA_WIDTH-1:0]  kernel     [0:COL_ROWS-1];
    logic [DATA_WIDTH-1:0]  col_buf    [0:COL_ROWS-1];

    logic [ACCUM_WIDTH-1:0] expected [0:8] = '{
        32'd26,  32'd56,  32'd54,
        32'd84,  32'd165, 32'd144,
        32'd134, 32'd236, 32'd186
    };

    int errors = 0;

    // -------------------------------------------------------------------------
    // Task: gather ? combinational addr gen, #1 delays, NO clock edges
    //
    // Uses #1 delays so NO clock is consumed. However, the cumulative 9ns of
    // simulation time will cross one clock posedge. That posedge fires with
    // a_in/b_in still at their previous values (stream hasn't driven them yet).
    // This is harmless but leaves the simulation at a point where the NEXT
    // posedge is ~1ns away when stream_and_verify begins.
    //
    // stream_and_verify corrects for this with a realignment cycle.
    // -------------------------------------------------------------------------
    task automatic gather_column(input int ci);
        $display("  [gather] col_idx=%0d (oh=%0d, ow=%0d)",
                  ci, ci/OW, ci%OW);
        for (int ri = 0; ri < COL_ROWS; ri++) begin
            ag_col_idx = ci[($clog2(COL_COLS)-1):0];
            ag_row_idx = ri[($clog2(COL_ROWS)-1):0];
            #1;
            col_buf[ri] = ag_pad_pixel ? '0 : image_sram[ag_img_addr];
            $display("    row_idx=%0d | pad=%0b addr=%0d val=%0d",
                      ri, ag_pad_pixel, ag_img_addr, col_buf[ri]);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task: stream and verify
    //
    // FIX: first @(negedge clk) realigns to a clean cycle boundary.
    //
    // Why it's needed:
    //   Gather runs for ~9ns via #1 delays, crossing a posedge mid-way.
    //   When gather returns, simulation time is ~1ns before the next negedge.
    //   If we drive a/b immediately and @(negedge clk), that negedge arrives
    //   1ns later with NO intervening posedge ? c_accum never fires.
    //   Then drain fires on the NEXT posedge. c_accum=0 ? c_out=0.
    //
    //   By adding one @(negedge clk) first, we advance to a clean negedge
    //   boundary. The following @(negedge clk) after driving a/b now has a
    //   full 10ns window ? a posedge fires in the middle with correct values.
    //
    // Timing after fix (all negedges are 10ns apart):
    //   Negedge R+0 (realign):    idle, en=1, drain=0
    //   Negedge R+1 (MAC):        a/b driven; posedge R+0.5: c_accum+=product
    //   Negedge R+2 (drain):      drain=1, a/b=0; posedge R+1.5: drain_r=1,
    //                             c_accum unchanged; negedge R+2: SAMPLE c_out
    //   Negedge R+3 (clear):      drain=0; posedge R+2.5: c_accum<=0
    // -------------------------------------------------------------------------
    task automatic stream_and_verify(input int ci);
        automatic logic [ACCUM_WIDTH-1:0] got;

        $display("  [stream] col_idx=%0d", ci);

        // ?? Realign to clean clock boundary ??
        // Consume the partial cycle left over from gather's #1 delays.
        // After this negedge, exactly 10ns to the next negedge ? enough
        // room for a proper MAC posedge.
        @(negedge clk);

        // ?? MAC cycle ??
        // All 9 PE rows get their weight and activation simultaneously.
        // Posedge fires 5ns later with these values present.
        for (int k = 0; k < PE_ROWS; k++) begin
            a_in[k] = kernel[k];
            b_in[k] = col_buf[k];
        end
        drain = 0;
        @(negedge clk);   // posedge: c_accum[k] += kernel[k]*col_buf[k]

        // ?? Drain cycle ??
        // Assert drain, zero a/b. Posedge: drain_r<=1, c_accum unchanged.
        // At negedge: drain=1, c_accum=A[k] ?
        //   c_out = c_in+c_accum (combinational chain) = dot product ? SAMPLE
        drain = 1;
        for (int k = 0; k < PE_ROWS; k++) begin
            a_in[k] = '0;
            b_in[k] = '0;
        end
        @(negedge clk);
        got = c_out[0];
        $display("  [drain]  c_out[0] = %0d", got);
        drain = 0;

        // ?? Clear cycle ??
        // Posedge: drain_r=1 AND drain=0 ? c_accum<=0 for all PEs.
        @(negedge clk);

        // ?? Verify ??
        if (got !== expected[ci]) begin
            $display("  FAIL pass=%0d (oh=%0d ow=%0d): expected=%0d got=%0d",
                      ci, ci/OW, ci%OW, expected[ci], got);
            errors++;
        end else begin
            $display("  PASS pass=%0d (oh=%0d ow=%0d): got=%0d",
                      ci, ci/OW, ci%OW, got);
        end
    endtask

    // -------------------------------------------------------------------------
    // Main stimulus
    // -------------------------------------------------------------------------
    initial begin
        image_sram = '{ 8'd1, 8'd2, 8'd3,
                        8'd4, 8'd5, 8'd6,
                        8'd7, 8'd8, 8'd9 };

        kernel = '{ 8'd9, 8'd8, 8'd7,
                    8'd6, 8'd5, 8'd4,
                    8'd3, 8'd2, 8'd1 };

        rst = 1; en = 0; drain = 0;
        for (int k = 0; k < PE_ROWS; k++) begin
            a_in[k] = '0; b_in[k] = '0;
        end
        repeat(4) @(negedge clk);
        rst = 0;
        repeat(2) @(negedge clk);
        en = 1;

        $display("=== 1x9 systolic array ? 3x3 conv C=1 K=1 S=1 P=1 ===");
        $display("");

        for (int ci = 0; ci < COL_COLS; ci++) begin
            $display("--- Pass %0d / %0d ---", ci, COL_COLS-1);
            gather_column(ci);
            stream_and_verify(ci);
            $display("");
        end

        $display("=== Done. Errors: %0d / %0d ===", errors, COL_COLS);
        $finish;
    end

endmodule