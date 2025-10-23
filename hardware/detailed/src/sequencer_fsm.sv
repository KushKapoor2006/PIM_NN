//=====================================================================
// File: sequencer_fsm.sv
// Purpose: Sequencer FSM that reads microprogram entries from a FIFO,
//          issues micro-ops (commands) to the PIM controller, waits for
//          completion, and repeats for the microprogram length.
// Notes : Synthesizable SystemVerilog (target: iverilog -g2022).
//=====================================================================

`timescale 1ns / 1ps
`include "pim_opcodes.svh"

module sequencer_fsm #(
    parameter int MICROPROG_LEN_WORDS      = 4,
    parameter int CMD_SIZE_BITS            = 64,
    parameter int SEQUENCER_EXECUTE_OVERHEAD = 8,
    parameter int SEQUENCER_PER_MICRO_CYCLES = 1
) (
    input  logic clk,
    input  logic rst_n,

    // FIFO side (FIFO is synchronous read)
    input  logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] fifo_read_data,
    input  logic fifo_empty,
    output logic fifo_read_en,

    // PIM command interface (valid/ready)
    output logic cmd_to_pim_valid,
    output logic [CMD_SIZE_BITS-1:0] cmd_to_pim_data,
    input  logic cmd_to_pim_ready,

    // PIM completion (one-cycle pulse from pim_controller)
    input  logic pim_op_done,

    // Status outputs
    output logic sequencer_busy,
    output logic sequencer_done
);

    localparam int OP_IDX_W = (MICROPROG_LEN_WORDS > 1) ? $clog2(MICROPROG_LEN_WORDS) : 1;

    // --- FIX: Added S_READ_FIFO_WAIT state ---
    typedef enum logic [2:0] {
        S_IDLE, S_START_OVERHEAD, S_READ_FIFO_REQ, S_READ_FIFO_WAIT,
        S_ISSUE_MICRO_OP, S_WAIT_PIM_OP, S_CLEANUP
    } seq_state_e;
    seq_state_e state_q, state_d;

    logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] microprog_q;
    logic [OP_IDX_W-1:0] micro_op_idx_q, micro_op_idx_d;
    logic [7:0] overhead_timer_q, overhead_timer_d; // 8-bit timer is enough for overhead
    logic sequencer_done_r;

    function automatic logic [CMD_SIZE_BITS-1:0] get_micro_op (
        input logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] mp,
        input int index
    );
        return mp[(index*CMD_SIZE_BITS) +: CMD_SIZE_BITS];
    endfunction

    assign cmd_to_pim_data = get_micro_op(microprog_q, micro_op_idx_q);
    assign sequencer_busy = (state_q != S_IDLE);
    assign sequencer_done = sequencer_done_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
            microprog_q <= '0;
            micro_op_idx_q <= '0;
            overhead_timer_q <= '0;
            sequencer_done_r <= 1'b0;
        end else begin
            state_q <= state_d;
            micro_op_idx_q <= micro_op_idx_d;
            overhead_timer_q <= overhead_timer_d;
            
            // Latch microprogram from FIFO on the correct cycle
            if (state_q == S_READ_FIFO_WAIT) begin
                microprog_q <= fifo_read_data;
            end else if (state_d == S_IDLE) begin
                microprog_q <= '0; // Clear when done
            end
            
            sequencer_done_r <= (state_q == S_CLEANUP); // Pulse when in cleanup state
        end
    end

    always_comb begin
        state_d = state_q;
        micro_op_idx_d = micro_op_idx_q;
        overhead_timer_d = overhead_timer_q;
        fifo_read_en = 1'b0;
        cmd_to_pim_valid = 1'b0;

        case (state_q)
            S_IDLE: begin
                if (!fifo_empty) begin
                    state_d = S_START_OVERHEAD;
                    overhead_timer_d = SEQUENCER_EXECUTE_OVERHEAD;
                end
            end
            S_START_OVERHEAD: begin
                if (overhead_timer_q <= 1) state_d = S_READ_FIFO_REQ;
                else overhead_timer_d = overhead_timer_q - 1;
            end
            S_READ_FIFO_REQ: begin
                fifo_read_en = 1'b1;
                state_d = S_READ_FIFO_WAIT;
            end
            S_READ_FIFO_WAIT: begin
                // Data is being latched in always_ff this cycle
                state_d = S_ISSUE_MICRO_OP;
                micro_op_idx_d = '0;
            end
            S_ISSUE_MICRO_OP: begin
                cmd_to_pim_valid = 1'b1;
                if (cmd_to_pim_ready) begin
                    state_d = S_WAIT_PIM_OP;
                    overhead_timer_d = SEQUENCER_PER_MICRO_CYCLES;
                end
            end
            S_WAIT_PIM_OP: begin
                if (overhead_timer_q > 1) overhead_timer_d = overhead_timer_q - 1;
                else overhead_timer_d = '0;
                
                if (pim_op_done) begin
                    if (micro_op_idx_q == MICROPROG_LEN_WORDS - 1) begin
                        state_d = S_CLEANUP;
                    end else begin
                        micro_op_idx_d = micro_op_idx_q + 1;
                        state_d = S_ISSUE_MICRO_OP;
                    end
                end
            end
            S_CLEANUP: begin
                state_d = S_IDLE;
            end
            default: state_d = S_IDLE;
        endcase
    end
endmodule