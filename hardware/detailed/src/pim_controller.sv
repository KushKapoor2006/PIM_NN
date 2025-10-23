//=====================================================================
// File: pim_controller.sv
// Purpose: PIM Controller - decodes commands (FETCH, COMPUTE, STORE),
//          issues bus requests for PIM-initiated IO, models local memory
//          access and compute latency, and produces a one-cycle pim_op_done.
// Notes : Synthesizable SystemVerilog (target: iverilog -g2022)
//=====================================================================

`timescale 1ns / 1ps
`include "pim_opcodes.svh"

module pim_controller #(
    parameter int CMD_SIZE_BITS         = 64,
    parameter int MACS_PER_CYCLE        = 16,
    parameter int PIM_BASE_LATENCY_CYCLES = 20,
    parameter int FETCH_CYCLES          = 5,
    parameter int STORE_CYCLES          = 5,
    parameter int FETCH_BUS_TRANSFERS   = 128, // Num. of BUS_WIDTH_BITS transfers for 1KB
    parameter int CONTROLLER_DECODE_CYCLES = 5,
    parameter int ADDR_WIDTH_BITS       = 64
)(
    input  logic                   clk,
    input  logic                   rst_n,

    // Command input (from CPU or Sequencer via arbiter)
    input  logic                   cmd_valid,
    input  logic [CMD_SIZE_BITS-1:0] cmd_data,
    output logic                   cmd_ready,

    // Bus request interface (to bus_interface via arbiter)
    output logic                   bus_req_valid,
    output logic [1:0]             bus_req_type,
    output logic [ADDR_WIDTH_BITS-1:0] bus_req_addr,
    output logic [7:0]             bus_req_len,
    output logic [CMD_SIZE_BITS-1:0] bus_req_data, // FIX: Explicitly listed as output
    input  logic                   bus_req_ready,
    input  logic                   bus_op_done,

    // Status outputs
    output logic                   pim_busy,
    output logic                   pim_op_done
);

    typedef enum logic [2:0] {
        S_IDLE, S_DECODE, S_ISSUE_BUS_REQ,
        S_WAIT_BUS_COMPLETE, S_LOCAL_MEM, S_PERFORM_COMPUTE
    } state_e;
    state_e state_q, state_d;

    pim_cmd_t current_cmd_q, current_cmd_d;
    logic [$clog2(CONTROLLER_DECODE_CYCLES+1):0] decode_timer_q, decode_timer_d;
    logic [15:0] op_timer_q, op_timer_d;
    logic [15:0] mac_ops_q, mac_ops_d;
    logic pim_op_done_r;

    assign cmd_ready = (state_q == S_IDLE);
    assign pim_busy = (state_q != S_IDLE);
    assign bus_req_type = (current_cmd_q.opcode == OPC_STORE_OUTPUT) ? 2'b10 : 2'b01;
    assign bus_req_addr = {{(ADDR_WIDTH_BITS-32){1'b0}}, current_cmd_q.addr};
    assign bus_req_len  = FETCH_BUS_TRANSFERS[7:0];
    assign bus_req_data = '0; // FIX: Assign a default value if not driven by controller logic
    assign pim_op_done = pim_op_done_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q <= S_IDLE;
            current_cmd_q <= '{default:0};
            decode_timer_q <= '0;
            op_timer_q <= '0;
            mac_ops_q <= '0;
            pim_op_done_r <= 1'b0;
        end else begin
            state_q <= state_d;
            current_cmd_q <= current_cmd_d;
            decode_timer_q <= decode_timer_d;
            op_timer_q <= op_timer_d;
            mac_ops_q <= mac_ops_d;
            pim_op_done_r <= (state_q != S_IDLE) && (state_d == S_IDLE);
        end
    end

    always_comb begin
        state_d = state_q;
        current_cmd_d = current_cmd_q;
        decode_timer_d = decode_timer_q;
        op_timer_d = op_timer_q;
        mac_ops_d = mac_ops_q;
        bus_req_valid = 1'b0;

        case (state_q)
            S_IDLE: begin
                if (cmd_valid) begin
                    pim_cmd_t received_cmd;
                    received_cmd = pim_cmd_t'(cmd_data);
                    
                    current_cmd_d = received_cmd;
                    mac_ops_d = received_cmd.mac_count;
                    
                    decode_timer_d = CONTROLLER_DECODE_CYCLES;
                    state_d = S_DECODE;
                end
            end

            S_DECODE: begin
                if (decode_timer_q <= 1) begin
                    decode_timer_d = '0;
                    if ((current_cmd_q.opcode == OPC_FETCH_INPUT) ||
                        (current_cmd_q.opcode == OPC_FETCH_WEIGHTS) ||
                        (current_cmd_q.opcode == OPC_STORE_OUTPUT)) begin
                        state_d = S_ISSUE_BUS_REQ;
                    end else if (current_cmd_q.opcode == OPC_COMPUTE) begin
                        op_timer_d = PIM_BASE_LATENCY_CYCLES + ((mac_ops_q + MACS_PER_CYCLE - 1) / MACS_PER_CYCLE);
                        state_d = S_PERFORM_COMPUTE;
                    end else begin
                        $error("PIM Controller: Unknown opcode %h", current_cmd_q.opcode);
                        state_d = S_IDLE;
                    end
                end else begin
                    decode_timer_d = decode_timer_q - 1;
                end
            end

            S_ISSUE_BUS_REQ: begin
                bus_req_valid = 1'b1;
                if (bus_req_ready) begin
                    state_d = S_WAIT_BUS_COMPLETE;
                end
            end

            S_WAIT_BUS_COMPLETE: begin
                if (bus_op_done) begin
                    op_timer_d = (current_cmd_q.opcode == OPC_STORE_OUTPUT) ? STORE_CYCLES : FETCH_CYCLES;
                    state_d = S_LOCAL_MEM;
                end
            end

            S_LOCAL_MEM: begin
                if (op_timer_q <= 1) begin
                    state_d = S_IDLE;
                end else begin
                    op_timer_d = op_timer_q - 1;
                end
            end

            S_PERFORM_COMPUTE: begin
                if (op_timer_q <= 1) begin
                    state_d = S_IDLE;
                end else begin
                    op_timer_d = op_timer_q - 1;
                end
            end

            default: begin
                state_d = S_IDLE;
            end
        endcase
    end

endmodule
