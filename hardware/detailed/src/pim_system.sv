//=====================================================================
// File: pim_system.sv
// Purpose: Top-level integration of the PIM system.
//=====================================================================

`timescale 1ns / 1ps
`include "pim_opcodes.svh"

module pim_system #(
    parameter int BUS_WIDTH_BITS           = 64,
    parameter int CMD_SIZE_BITS            = 64,
    parameter int FETCH_BUS_TRANSFERS      = 128,
    parameter int MACS_PER_CYCLE           = 16,
    parameter int PIM_BASE_LATENCY_CYCLES  = 20,
    parameter int FETCH_CYCLES             = 5,
    parameter int STORE_CYCLES             = 5,
    parameter int SEQUENCER_FIFO_DEPTH     = 4,
    parameter int MICROPROG_LEN_WORDS      = 4,
    parameter int ADDR_WIDTH_BITS          = 64,
    parameter int MEM_DEPTH_WORDS          = 1024
)(
    input  logic clk,
    input  logic rst_n,

    // --- FIX: Re-added ports the testbench expects ---
    input  logic cpu_cmd_valid,
    input  logic [CMD_SIZE_BITS-1:0]  cpu_cmd_data,
    output logic cpu_cmd_ready,
    input  logic cpu_microprog_valid,
    input  logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] cpu_microprog_data,
    output logic cpu_microprog_ack,
    input  logic cpu_execute_seq_valid,
    output logic cpu_execute_seq_ready,

    // Status
    output logic pim_system_idle,
    output logic sequencer_busy_out
);

    // --- FIX: All internal wires are now explicitly declared ---
    logic       seq_cmd_valid, seq_cmd_ready;
    logic [CMD_SIZE_BITS-1:0] seq_cmd_data;
    logic [1:0] cmd_arb_req, cmd_arb_gnt;
    logic       seq_cmd_gnt, cpu_cmd_gnt;

    logic       pim_ctrl_cmd_valid;
    logic [CMD_SIZE_BITS-1:0] pim_ctrl_cmd_data;
    logic       pim_ctrl_cmd_ready, pim_ctrl_pim_busy, pim_ctrl_pim_op_done;

    logic       pim_bus_req_valid, pim_bus_req_ready;
    logic [1:0] pim_bus_req_type;
    logic [ADDR_WIDTH_BITS-1:0] pim_bus_req_addr;
    logic [7:0] pim_bus_req_len;
    logic [CMD_SIZE_BITS-1:0] pim_bus_req_data;

    logic       bus_if_op_done;
    logic       bus_grant = 1'b1;

    logic       fifo_empty, fifo_full, fifo_read_en;
    logic [CMD_SIZE_BITS*MICROPROG_LEN_WORDS-1:0] fifo_read_data;
    
    logic [ADDR_WIDTH_BITS-1:0]  mem_bus_addr;
    logic [BUS_WIDTH_BITS-1:0]   mem_bus_wdata;
    logic                        mem_bus_wen;
    logic [BUS_WIDTH_BITS-1:0]   mem_bus_rdata;
    logic                        mem_bus_rvalid;

    logic       bus_req_sink, sequencer_done_sink;

    // --- Instantiate Arbiters ---
    priority_arbiter #(.MASTERS(2)) i_cmd_arb ( // FIX: Correct parameter name
        .req({seq_cmd_valid, cpu_cmd_valid}),
        .gnt({seq_cmd_gnt, cpu_cmd_gnt})
    );
    
    // --- Muxing and Wiring ---
    assign pim_ctrl_cmd_valid = (seq_cmd_gnt && seq_cmd_valid) || (cpu_cmd_gnt && cpu_cmd_valid);
    assign pim_ctrl_cmd_data  = seq_cmd_gnt ? seq_cmd_data : cpu_cmd_data;
    assign seq_cmd_ready = seq_cmd_gnt && pim_ctrl_cmd_ready;
    assign cpu_cmd_ready = cpu_cmd_gnt && pim_ctrl_cmd_ready;

    // --- Instantiate Modules ---
    bus_interface #( .ADDR_WIDTH_BITS(ADDR_WIDTH_BITS) ) i_bus_if (
        .clk(clk), .rst_n(rst_n),
        .req_valid(pim_bus_req_valid), .req_ready(pim_bus_req_ready),
        .req_type(pim_bus_req_type), .req_addr(pim_bus_req_addr),
        .req_len(pim_bus_req_len), .req_data(pim_bus_req_data),
        .bus_grant(bus_grant),
        .bus_req(bus_req_sink),
        .bus_addr(mem_bus_addr), .bus_write_en(mem_bus_wen), .bus_write_data(mem_bus_wdata),
        .bus_read_data(mem_bus_rdata), .bus_read_valid(mem_bus_rvalid),
        .bus_op_done(bus_if_op_done)
    );

    sequencer_fifo #(.FIFO_DEPTH(SEQUENCER_FIFO_DEPTH)) i_fifo (
        .clk(clk), .rst_n(rst_n),
        .write_en(cpu_microprog_valid), .write_data(cpu_microprog_data),
        .write_ack(cpu_microprog_ack),
        .read_en(fifo_read_en), .read_data(fifo_read_data),
        .empty(fifo_empty), .full(fifo_full), .current_depth()
    );

    sequencer_fsm i_seq_fsm (
        .clk(clk), .rst_n(rst_n),
        .fifo_read_data(fifo_read_data), .fifo_empty(fifo_empty),
        .fifo_read_en(fifo_read_en),
        .cmd_to_pim_valid(seq_cmd_valid), .cmd_to_pim_data(seq_cmd_data),
        .cmd_to_pim_ready(seq_cmd_ready),
        .pim_op_done(pim_ctrl_pim_op_done),
        .sequencer_busy(sequencer_busy_out),
        .sequencer_done(sequencer_done_sink)
    );

    pim_controller #( .ADDR_WIDTH_BITS(ADDR_WIDTH_BITS) ) i_pim_ctrl (
        .clk(clk), .rst_n(rst_n),
        .cmd_valid(pim_ctrl_cmd_valid), .cmd_data(pim_ctrl_cmd_data),
        .cmd_ready(pim_ctrl_cmd_ready),
        .bus_req_valid(pim_bus_req_valid), .bus_req_ready(pim_bus_req_ready),
        .bus_req_type(pim_bus_req_type), .bus_req_addr(pim_bus_req_addr),
        .bus_req_len(pim_bus_req_len), .bus_req_data(pim_bus_req_data),
        .bus_op_done(bus_if_op_done),
        .pim_busy(pim_ctrl_pim_busy),
        .pim_op_done(pim_ctrl_pim_op_done)
    );
    
    memory_model #( .MEM_DEPTH_WORDS(MEM_DEPTH_WORDS), .ADDR_WIDTH_BITS(ADDR_WIDTH_BITS) ) i_mem ( // FIX: Correct parameter name
        .clk(clk), .rst_n(rst_n),
        .addr(mem_bus_addr), .wen(mem_bus_wen), .wdata(mem_bus_wdata),
        .rdata(mem_bus_rdata), .rvalid(mem_bus_rvalid)
    );

    assign pim_system_idle = !pim_ctrl_pim_busy && !sequencer_busy_out && fifo_empty;
    assign cpu_execute_seq_ready = !fifo_empty && !sequencer_busy_out;
    
endmodule
