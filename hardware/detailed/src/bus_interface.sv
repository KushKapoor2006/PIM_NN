//=====================================================================
// File: bus_interface.sv
// Purpose: Models shared bus transactions for PIM System
//=====================================================================

`timescale 1ns / 1ps

module bus_interface #(
    parameter int BUS_WIDTH_BITS       = 64,
    parameter int CMD_SIZE_BITS        = 64,
    parameter int ADDR_WIDTH_BITS      = 64
)(
    input  logic clk,
    input  logic rst_n,

    // Interface to Requester
    input  logic              req_valid,
    output logic              req_ready,
    input  logic [1:0]        req_type,
    input  logic [ADDR_WIDTH_BITS-1:0] req_addr,
    input  logic [CMD_SIZE_BITS-1:0] req_data,
    input  logic [7:0]        req_len,

    // Bus Arbitration
    output logic              bus_req,
    input  logic              bus_grant,

    // --- FIX: Added missing output ports for memory connection ---
    output logic [ADDR_WIDTH_BITS-1:0] bus_addr,
    output logic [BUS_WIDTH_BITS-1:0] bus_write_data,
    output logic              bus_write_en,
    input  logic [BUS_WIDTH_BITS-1:0] bus_read_data,
    input  logic              bus_read_valid,

    // Status
    output logic              bus_op_done
);

    typedef enum logic [1:0] { IDLE, ARBITRATING, TRANSFERRING } bus_state_e;
    bus_state_e bus_state_q, bus_state_d;

    logic [7:0] transfer_count_q, transfer_count_d;
    logic [7:0] current_req_len_q, current_req_len_d;
    logic [1:0] current_req_type_q, current_req_type_d;
    logic [ADDR_WIDTH_BITS-1:0] current_req_addr_q, current_req_addr_d;
    logic [CMD_SIZE_BITS-1:0] current_req_data_q, current_req_data_d;
    logic bus_op_done_r;

    localparam int CYCLES_PER_CMD_TRANSFER = (CMD_SIZE_BITS + BUS_WIDTH_BITS - 1) / BUS_WIDTH_BITS;

    assign req_ready      = (bus_state_q == IDLE);
    assign bus_req        = (bus_state_q == ARBITRATING);
    assign bus_write_en   = (bus_state_q == TRANSFERRING) && bus_grant && ((current_req_type_q == 2'b00) || (current_req_type_q == 2'b10));
    assign bus_write_data = current_req_data_q[BUS_WIDTH_BITS-1:0];
    assign bus_addr       = current_req_addr_q + (transfer_count_q * (BUS_WIDTH_BITS/8));
    assign bus_op_done    = bus_op_done_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bus_state_q <= IDLE;
            transfer_count_q <= '0;
            current_req_len_q <= '0;
            bus_op_done_r <= 1'b0;
        end else begin
            bus_state_q <= bus_state_d;
            transfer_count_q <= transfer_count_d;
            current_req_len_q <= current_req_len_d;
            if (req_valid && req_ready) begin
                current_req_type_q <= req_type;
                current_req_addr_q <= req_addr;
                current_req_data_q <= req_data;
            end
            bus_op_done_r <= (bus_state_q == TRANSFERRING) && (bus_state_d == IDLE);
        end
    end

    always_comb begin
        bus_state_d = bus_state_q;
        transfer_count_d = transfer_count_q;
        current_req_len_d = current_req_len_q;

        case (bus_state_q)
            IDLE: begin
                if (req_valid) begin
                    bus_state_d = ARBITRATING;
                    current_req_len_d = (req_type == 2'b00) ? CYCLES_PER_CMD_TRANSFER : req_len;
                    transfer_count_d = '0;
                end
            end
            ARBITRATING: begin
                if (bus_grant) begin
                    bus_state_d = TRANSFERRING;
                end
            end
            TRANSFERRING: begin
                if (bus_grant) begin
                    logic is_read = (current_req_type_q == 2'b01);
                    if (is_read && !bus_read_valid) begin
                        // Stall for read data
                    end else begin
                        if (transfer_count_q == current_req_len_q - 1) begin
                            bus_state_d = IDLE;
                        end else begin
                            transfer_count_d = transfer_count_q + 1;
                        end
                    end
                end
            end
            default: bus_state_d = IDLE;
        endcase
    end
endmodule
