//=====================================================================
// File: memory_model.sv
// Purpose: Simple behavioral memory model for the PIM system bus.
// Notes : For simulation only. Models basic read/write with fixed latency.
//=====================================================================

`timescale 1ns / 1ps

module memory_model #(
    parameter int MEM_DEPTH_WORDS = 1024, // FIX: Renamed from MEMORY_DEPTH_WORDS
    parameter int BUS_WIDTH_BITS     = 64,
    parameter int ADDR_WIDTH_BITS    = 64,
    parameter int READ_LATENCY   = 2
)(
    input  logic clk,
    input  logic rst_n,

    // Bus Interface
    input  logic [ADDR_WIDTH_BITS-1:0] addr,
    input  logic [BUS_WIDTH_BITS-1:0]  wdata,
    input  logic                     wen,
    output logic [BUS_WIDTH_BITS-1:0] rdata,
    output logic                     rvalid
);
    localparam int WORD_ADDR_WIDTH = $clog2(MEM_DEPTH_WORDS);

    logic [BUS_WIDTH_BITS-1:0] mem [MEM_DEPTH_WORDS-1:0];
    logic [BUS_WIDTH_BITS-1:0] rdata_reg;
    logic rvalid_reg;

    assign rdata = rdata_reg;
    assign rvalid = rvalid_reg;

    logic [WORD_ADDR_WIDTH-1:0] word_addr;
    assign word_addr = addr[$clog2(BUS_WIDTH_BITS/8) +: WORD_ADDR_WIDTH];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < MEM_DEPTH_WORDS; i++) mem[i] <= i;
            rvalid_reg <= 1'b0;
        end else begin
            if (wen) begin
                mem[word_addr] <= wdata;
            end

            // Simple 1-cycle latency read model
            if (!wen) begin
                rdata_reg <= mem[word_addr];
            end
            rvalid_reg <= !wen;
        end
    end
endmodule
