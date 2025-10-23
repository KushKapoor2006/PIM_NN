//=====================================================================
// File: sequencer_accelerator.sv
// Purpose: A simplified, single-module PIM accelerator that demonstrates
//          the performance difference between micromanagement and a
//          hardware command sequencer.
// Notes: Icarus-friendly edits: use shift+mask instead of variable part-select,
//        and use plain always for assertion block to avoid a noisy iverilog warning.
//=====================================================================

`timescale 1ns / 1ps
`include "pim_opcodes.svh"

module sequencer_accelerator #(
    parameter int MICROPROG_LEN       = 4,
    parameter int FIFO_DEPTH          = 4,
    parameter int IO_CYCLES           = 150,
    parameter int COMPUTE_CYCLES      = 400
)(
    input  logic clk,
    input  logic rst_n,

    // --- CPU Interface ---
    input  logic cpu_mode, // 0 for Micromanagement, 1 for Sequencer
    input  logic cpu_cmd_valid,
    input  logic [64*MICROPROG_LEN-1:0] cpu_cmd_data,
    output logic cpu_cmd_ready,     

    // --- Status ---
    output logic accelerator_busy,
    output logic layer_done
);

    // --- Parameter Validation ---
    initial begin
        if (MICROPROG_LEN < 1) $fatal(1, "MICROPROG_LEN must be >= 1");
        if (FIFO_DEPTH < 1) $fatal(1, "FIFO_DEPTH must be >= 1");
    end

    // Modes
    localparam MICROMANAGEMENT_MODE = 1'b0;
    localparam SEQUENCER_MODE       = 1'b1;

    localparam int OP_IDX_W = (MICROPROG_LEN > 1) ? $clog2(MICROPROG_LEN) : 1;
    localparam int CMD_WIDTH = 64;

    // ---- Safe pointer/count widths to support FIFO_DEPTH == 1
    localparam int PTR_W   = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam int COUNT_W = (FIFO_DEPTH+1 > 1) ? $clog2(FIFO_DEPTH+1) : 1;

    //=============================================================
    // 1. Internal FIFO for Sequencer Mode
    //=============================================================
    logic [CMD_WIDTH*MICROPROG_LEN-1:0] fifo_mem [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [COUNT_W-1:0] fifo_count;
    logic fifo_full, fifo_empty;
    logic fifo_write_en, fifo_read_en;

    assign fifo_full = (fifo_count == FIFO_DEPTH);
    assign fifo_empty = (fifo_count == 0);

    // combinational read address to avoid read-after-write confusion
    logic [PTR_W-1:0] fifo_rd_addr;
    assign fifo_rd_addr = rd_ptr;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
            fifo_count <= '0;
        end else begin
            if (fifo_write_en) begin
                fifo_mem[wr_ptr] <= cpu_cmd_data;
                wr_ptr <= wr_ptr + 1;
            end
            if (fifo_read_en) begin
                rd_ptr <= rd_ptr + 1;
            end

            // Corrected fifo_count update logic
            if (fifo_write_en && !fifo_read_en)      fifo_count <= fifo_count + 1;
            else if (!fifo_write_en && fifo_read_en) fifo_count <= fifo_count - 1;
            // if both happen, fifo_count unchanged
        end
    end

    // Assertions for FIFO overflow/underflow (gated by reset)
    // Use plain always to avoid iverilog "cannot be synthesized in always_ff" warning.
    `ifndef VERILATOR
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ;
        else begin
            if (fifo_write_en && fifo_full) $fatal(2, "FIFO Overflow detected!");
            if (fifo_read_en  && fifo_empty) $fatal(2, "FIFO Underflow detected!");
        end
    end
    `endif

    //=============================================================
    // 2. Simple PIM Execution Unit (Behavioral Model)
    //=============================================================
    // Use simple logic signals for state to stay iverilog-friendly
    localparam EXEC_IDLE = 1'b0;
    localparam EXEC_BUSY = 1'b1;
    logic exec_state_q, exec_state_d;
    logic [15:0] exec_timer_q, exec_timer_d;
    logic exec_start; // handshake for starting an exec
    logic [CMD_WIDTH-1:0] exec_cmd_in;
    logic exec_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            exec_state_q <= EXEC_IDLE;
            exec_timer_q <= '0;
        end else begin
            exec_state_q <= exec_state_d;
            exec_timer_q <= exec_timer_d;
        end
    end

    // Use opcode slice instead of type-cast to pim_cmd_t (more portable)
    always_comb begin
        exec_state_d = exec_state_q;
        exec_timer_d = exec_timer_q;
        exec_done = 1'b0;

        case (exec_state_q)
            EXEC_IDLE: begin
                if (exec_start) begin
                    exec_state_d = EXEC_BUSY;
                    case (exec_cmd_in[CMD_WIDTH-1 -: 8]) // opcode located at bits [63:56]
                        OPC_FETCH_INPUT, OPC_FETCH_WEIGHTS, OPC_STORE_OUTPUT: exec_timer_d = IO_CYCLES;
                        OPC_COMPUTE: exec_timer_d = COMPUTE_CYCLES;
                        default: exec_timer_d = 1;
                    endcase
                end
            end
            EXEC_BUSY: begin
                if (exec_timer_q <= 1) begin
                    exec_state_d = EXEC_IDLE;
                    exec_done = 1'b1;
                end else begin
                    exec_timer_d = exec_timer_q - 1;
                end
            end
            default: begin
                exec_state_d = EXEC_IDLE;
                exec_timer_d = '0;
            end
        endcase
    end

    //=============================================================
    // 2b. Exec command extraction (avoid variable part-select warning)
    //=============================================================
    // We extract the CMD_WIDTH-bit command by shifting down by (op_idx_q * CMD_WIDTH)
    // and masking the lowest CMD_WIDTH bits. This is portable and avoids the
    // "constant selects in always_*" complaint from some iverilog versions.
    logic [CMD_WIDTH-1:0] exec_cmd_mask;
    assign exec_cmd_mask = {CMD_WIDTH{1'b1}};

    always_comb begin
        // shift right by op_idx_q * CMD_WIDTH, then mask low bits
        exec_cmd_in = (microprog_reg_q >> (op_idx_q * CMD_WIDTH)) & exec_cmd_mask;
    end

    //=============================================================
    // 3. Main Sequencer FSM (The "Brain")
    //=============================================================
    // small encoded FSM (2-bit)
    localparam [1:0] S_IDLE  = 2'b00;
    localparam [1:0] S_FETCH = 2'b01;
    localparam [1:0] S_ISSUE = 2'b10;
    localparam [1:0] S_WAIT  = 2'b11;
    logic [1:0] state_q, state_d;

    logic [CMD_WIDTH*MICROPROG_LEN-1:0] microprog_reg_q;
    logic [OP_IDX_W-1:0] op_idx_q, op_idx_d;
    logic layer_done_r;

    // --- Control Signal Assignments ---
    assign cpu_cmd_ready = (state_q == S_IDLE) &&
                           ((cpu_mode == MICROMANAGEMENT_MODE) ||
                            (cpu_mode == SEQUENCER_MODE && !fifo_full));

    // accelerator_busy: indicates either active execution or queued work pending
    assign accelerator_busy = (state_q != S_IDLE) || (exec_state_q != EXEC_IDLE) || (cpu_mode == SEQUENCER_MODE && !fifo_empty);

    assign layer_done = layer_done_r;

    // exec_start: FSM in ISSUE and exec is idle.
    assign exec_start = (state_q == S_ISSUE) && (exec_state_q == EXEC_IDLE);

    // FIFO enables: include cpu_cmd_ready to honor the handshake
    assign fifo_write_en = (cpu_mode == SEQUENCER_MODE) && cpu_cmd_valid && cpu_cmd_ready;
    assign fifo_read_en  = (state_q == S_FETCH) && (cpu_mode == SEQUENCER_MODE) && !fifo_empty;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
            op_idx_q <= '0;
            layer_done_r <= 1'b0;
            microprog_reg_q <= '0;
        end else begin
            state_q <= state_d;
            op_idx_q <= op_idx_d;

            // one-cycle pulse for layer_done (registered)
            layer_done_r <= (state_q == S_WAIT) && exec_done &&
                            ((cpu_mode == MICROMANAGEMENT_MODE) || (op_idx_q == MICROPROG_LEN - 1));

            if (state_d == S_FETCH) begin
                if (cpu_mode == MICROMANAGEMENT_MODE) begin
                    microprog_reg_q <= {{(CMD_WIDTH*(MICROPROG_LEN-1)){1'b0}}, cpu_cmd_data[CMD_WIDTH-1:0]};
                end else begin
                    // read from FIFO at the current rd_ptr (combinational fifo_rd_addr)
                    microprog_reg_q <= fifo_mem[fifo_rd_addr];
                end
            end
        end
    end

    always_comb begin
        state_d = state_q;
        op_idx_d = op_idx_q;

        case (state_q)
            S_IDLE: begin
                if ((cpu_mode == SEQUENCER_MODE && !fifo_empty) ||
                    (cpu_mode == MICROMANAGEMENT_MODE && cpu_cmd_valid && cpu_cmd_ready)) begin
                    state_d = S_FETCH;
                    op_idx_d = '0;
                end
            end
            S_FETCH: begin
                state_d = S_ISSUE;
            end
            S_ISSUE: begin
                // If exec accepts the start condition, move to wait
                if (exec_start) begin
                    state_d = S_WAIT;
                end
            end
            S_WAIT: begin
                if (exec_done) begin
                    if ((cpu_mode == MICROMANAGEMENT_MODE) || (op_idx_q == MICROPROG_LEN - 1)) begin
                        state_d = S_IDLE;
                    end else begin
                        state_d = S_ISSUE; // Go to next micro-op
                        op_idx_d = op_idx_q + 1;
                    end
                end
            end
            default: begin
                state_d = S_IDLE;
                op_idx_d = '0;
            end
        endcase
    end

endmodule
