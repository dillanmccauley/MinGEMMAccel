// =============================================================================
// pe_output_stationary.sv  ?  final
//
// Two bugs fixed from previous versions:
//
//   Bug 1 ? registered c_out on drain cannot sum the vertical chain.
//     All PEs fire drain simultaneously. Every PE sees c_in=0 (the chain
//     was relaying zeros). So c_wire[k+1] = c_accum[k] independently ?
//     c_wire[9] only ever held PE(8)'s accumulator.
//
//     Fix: c_out is COMBINATIONAL on drain.
//       c_out = drain ? (c_in + c_accum) : c_relay_reg
//     With combinational c_out, c_wire is a purely combinational adder chain
//     during drain: c_wire[1]=A[0], c_wire[2]=A[0]+A[1], ...
//     c_wire[ROWS] = sum of ALL accumulators in a SINGLE clock cycle.
//     No propagation wait needed.
//
//   Bug 2 ? c_accum cleared on drain posedge, invalidating the combinational
//     c_out path after posedge.
//
//     Fix: use drain_r (drain registered one cycle). Clear c_accum when drain_r=1
//     (one cycle AFTER drain). This keeps c_accum valid through the entire drain
//     cycle so the combinational c_out reads the correct value at negedge.
//
// Sampling model:
//   Negedge N:   assert drain=1
//   Posedge N+½: drain_r<=1; c_accum unchanged (drain_r was 0, no clear yet)
//   Negedge N+1: drain=1, c_accum=A[k] ? c_out combinationally = chain sum ? SAMPLE
//   Drain=0 set
//   Posedge N+1½: drain_r_prev=1, drain=0 ? c_accum<=0 (cleared for next pass)
// =============================================================================
module pe_output_stationary #(
    parameter DATA_WIDTH  = 8,
    parameter ACCUM_WIDTH = 32
)(
    input  logic                   clk,
    input  logic                   rst,
    input  logic                   en,
    input  logic                   drain,
    input  logic [DATA_WIDTH-1:0]  a_in,
    input  logic [DATA_WIDTH-1:0]  b_in,
    input  logic [ACCUM_WIDTH-1:0] c_in,
    output logic [DATA_WIDTH-1:0]  a_out,
    output logic [DATA_WIDTH-1:0]  b_out,
    output logic [ACCUM_WIDTH-1:0] c_out
);
    logic [ACCUM_WIDTH-1:0] c_accum;
    logic [ACCUM_WIDTH-1:0] c_relay_reg;  // registered c_in for non-drain relay
    logic                   drain_r;       // drain delayed 1 cycle for safe clear
 
    logic [ACCUM_WIDTH-1:0] product;
    assign product = ((a_in == '0) || (b_in == '0))
                     ? '0 : ACCUM_WIDTH'(a_in) * ACCUM_WIDTH'(b_in);
 
    // c_out COMBINATIONAL on drain ? all ROWS PEs sum their accumulators in one cycle.
    // c_out registered relay (c_relay_reg) on non-drain ? clean pipeline between passes.
    assign c_out = drain ? (c_in + c_accum) : c_relay_reg;
 
    always_ff @(posedge clk) begin
        if (rst) begin
            a_out       <= '0;
            b_out       <= '0;
            c_accum     <= '0;
            c_relay_reg <= '0;
            drain_r     <= '0;
        end else begin
            drain_r <= drain;  // one-cycle delay for safe c_accum clear
            if (en) begin
                a_out       <= a_in;
                b_out       <= b_in;
                c_relay_reg <= c_in;  // register current c_in for non-drain relay
 
                if (drain_r) begin
                    // Clear one cycle AFTER drain so c_accum is valid throughout
                    // the entire drain cycle for the combinational c_out path.
                    c_accum <= '0;
                end else if (!drain) begin
                    // Normal accumulation ? skip if drain is active this cycle
                    // (avoids double-counting the final product)
                    c_accum <= c_accum + product;
                end
                // When drain=1: c_accum holds steady (read combinationally by c_out)
            end
        end
    end
endmodule