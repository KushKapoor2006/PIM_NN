//=====================================================================
// File: sequencer_fifo.sv
// Purpose: Small synchronous FIFO to hold microprogram entries (each
//          entry = MICROPROG_LEN_WORDS * CMD_SIZE_BITS bits).
// Notes : Synthesizable SystemVerilog (target: iverilog -g2022).
//         - write_en accepted when !full; drive write_ack high for one
//           cycle on acceptance.
//         - read_en accepted when !empty; read_data is registered and
//           valid the cycle after read_en (true synchronous read).
//=====================================================================

`timescale 1ns / 1ps

module sequencer_fifo #(
    parameter int FIFO_DEPTH = 4,
    parameter int MICROPROG_LEN_WORDS = 4,
    parameter int CMD_SIZE_BITS = 64
) (
    input  logic clk,
    input  logic rst_n,

    // Write interface (from CPU)
    input  logic write_en,   // pulse/high to request write
    input  logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] write_data,
    output logic write_ack,  // pulses one cycle when write is accepted

    // Read interface (to Sequencer FSM)
    input  logic read_en,    // pulse/high to request read
    output logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] read_data, // Registered output
    output logic empty,
    output logic full,
    output logic [$clog2(FIFO_DEPTH+1)-1:0] current_depth
);

    // ------------------------------------------------------------
    // Local parameters for pointer widths
    // ------------------------------------------------------------
    localparam int ENTRY_BITS = CMD_SIZE_BITS * MICROPROG_LEN_WORDS;
    // pointer width must be at least 1 for $clog2(1) = 0 issue. If FIFO_DEPTH=1, PTR_W=1.
    localparam int PTR_W = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam int DEPTH_W = $clog2(FIFO_DEPTH + 1); // to represent 0..FIFO_DEPTH

    // ------------------------------------------------------------
    // Internal storage and pointers
    // ------------------------------------------------------------
    logic [ENTRY_BITS-1:0] mem [0:FIFO_DEPTH-1];

    logic [PTR_W-1:0] wr_ptr_q, wr_ptr_d;
    logic [PTR_W-1:0] rd_ptr_q, rd_ptr_d;
    logic [DEPTH_W-1:0] depth_count_q, depth_count_d;

    // registered output for stable read_data (the value becomes available NEXT cycle)
    logic [ENTRY_BITS-1:0] read_data_r;

    // --- FIX: Move do_write and do_read to module scope ---
    logic do_write;
    logic do_read;

    // ------------------------------------------------------------
    // Output assignments
    // ------------------------------------------------------------
    assign read_data = read_data_r;
    assign empty = (depth_count_q == 0);
    assign full  = (depth_count_q == FIFO_DEPTH);
    assign current_depth = depth_count_q;

    // ------------------------------------------------------------
    // Sequential Block
    // ------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_q     <= '0;
            rd_ptr_q     <= '0;
            depth_count_q<= '0;
            read_data_r  <= '0; // Reset read_data register
            write_ack    <= 1'b0; // Reset write_ack pulse
        end else begin
            wr_ptr_q     <= wr_ptr_d;
            rd_ptr_q     <= rd_ptr_d;
            depth_count_q<= depth_count_d;
            
            // Default: clear write_ack and read_data_r
            write_ack    <= 1'b0;
            read_data_r  <= read_data_r; // Maintain current value unless overwritten

            // Handle write
            if (do_write) begin // Use the module-scope do_write
                mem[wr_ptr_q] <= write_data;
                write_ack <= 1'b1; // Pulse write_ack
            end

            // Handle read (registered output - data valid next cycle)
            if (do_read) begin // Use the module-scope do_read
                read_data_r <= mem[rd_ptr_q]; // Latch data from memory
            end
        end
    end

    // ------------------------------------------------------------
    // Combinational Next State Logic
    // ------------------------------------------------------------
    always_comb begin
        wr_ptr_d      = wr_ptr_q;
        rd_ptr_d      = rd_ptr_q;
        depth_count_d = depth_count_q;

        // --- FIX: Assign do_write and do_read ---
        do_write = write_en && !full;
        do_read  = read_en  && !empty;

        // Update pointers
        if (do_write) begin
            wr_ptr_d = wr_ptr_q + 1;
        end
        if (do_read) begin
            rd_ptr_d = rd_ptr_q + 1;
        end

        // Update depth counter
        if (do_write && !do_read) begin
            depth_count_d = depth_count_q + 1;
        end else if (!do_write && do_read) begin
            depth_count_d = depth_count_q - 1;
        end
        // if both do_write && do_read -> depth_count unchanged
    end

endmodule
