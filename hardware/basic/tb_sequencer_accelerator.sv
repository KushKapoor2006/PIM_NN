//=====================================================================
// File: tb_sequencer_accelerator.sv
// Purpose: Testbench for the simplified PIM accelerator.
// Icarus/iverilog-friendly version.
//=====================================================================

`timescale 1ns / 1ps
`include "pim_opcodes.svh"

module tb_sequencer_accelerator;

    localparam MICROPROG_LEN = 4;
    
    reg clk = 0;
    reg rst_n;
    
    // Inputs to DUT are regs, outputs are wires
    reg cpu_mode;
    reg cpu_cmd_valid;
    reg [64*MICROPROG_LEN-1:0] cpu_cmd_data;
    wire cpu_cmd_ready;
    wire accelerator_busy;
    wire layer_done;

    // microprog declared at module scope (iverilog compatibility)
    reg [64*MICROPROG_LEN-1:0] microprog;

    // Instantiate DUT (port names match)
    sequencer_accelerator #(.MICROPROG_LEN(MICROPROG_LEN)) dut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_mode(cpu_mode),
        .cpu_cmd_valid(cpu_cmd_valid),
        .cpu_cmd_data(cpu_cmd_data),
        .cpu_cmd_ready(cpu_cmd_ready),
        .accelerator_busy(accelerator_busy),
        .layer_done(layer_done)
    );

    always #5 clk = ~clk; // 10ns period (100 MHz)

    // Reset task: blocking assignments are fine in TB
    task reset_dut;
        begin
            rst_n = 1'b0;
            cpu_mode = 0;
            cpu_cmd_valid = 0;
            cpu_cmd_data = 0;
            #20;
            rst_n = 1'b1;
            #10;
            $display("[%0t] Testbench: Reset complete.", $time);
        end
    endtask

    // make_cmd helper - Verilog-2001 function style
    function [63:0] make_cmd;
        input [7:0] opcode;
        begin
            make_cmd = {opcode, 56'h0};
        end
    endfunction

    // Helper: build microprogram (op0 is first-executed -> LSB)
    function [64*MICROPROG_LEN-1:0] build_microprog;
        input [63:0] op3; // Last op (MSB)
        input [63:0] op2;
        input [63:0] op1;
        input [63:0] op0; // First op (LSB)
        begin
            build_microprog = {op3, op2, op1, op0};
        end
    endfunction

    initial begin
        integer micro_start_time, micro_end_time;
        integer seq_start_time, seq_end_time;
        integer num_layers;
        integer i;
        real speedup;

        num_layers = 3;

        $dumpfile("accelerator_tb.vcd");
        $dumpvars(0, tb_sequencer_accelerator);
        
        reset_dut();

        // --- Test 1: Micromanagement Mode ---
        $display("\n--- Starting Micromanagement Test (%0d layers) ---", num_layers);
        cpu_mode = 0;
        micro_start_time = $time;
        
        for (i = 0; i < num_layers; i = i + 1) begin
            $display("[%0t] Micromanagement: Starting Layer %0d", $time, i+1);
            
            @(posedge clk);
            cpu_cmd_valid = 1;
            cpu_cmd_data = make_cmd(OPC_FETCH_INPUT);
            wait (cpu_cmd_ready);
            @(posedge clk);
            cpu_cmd_valid = 0;
            wait (layer_done);
            $display("[%0t] ...FETCH_INPUT Done.", $time);
            
            @(posedge clk);
            cpu_cmd_valid = 1;
            cpu_cmd_data = make_cmd(OPC_FETCH_WEIGHTS);
            wait (cpu_cmd_ready);
            @(posedge clk);
            cpu_cmd_valid = 0;
            wait (layer_done);
            $display("[%0t] ...FETCH_WEIGHTS Done.", $time);

            @(posedge clk);
            cpu_cmd_valid = 1;
            cpu_cmd_data = make_cmd(OPC_COMPUTE);
            wait (cpu_cmd_ready);
            @(posedge clk);
            cpu_cmd_valid = 0;
            wait (layer_done);
            $display("[%0t] ...COMPUTE Done.", $time);

            @(posedge clk);
            cpu_cmd_valid = 1;
            cpu_cmd_data = make_cmd(OPC_STORE_OUTPUT);
            wait (cpu_cmd_ready);
            @(posedge clk);
            cpu_cmd_valid = 0;
            wait (layer_done);
            $display("[%0t] ...STORE_OUTPUT Done. Layer %0d complete.", $time, i+1);
        end
        micro_end_time = $time;

        // --- Test 2: Sequencer Mode ---
        wait(!accelerator_busy);
        $display("\n--- Starting Sequencer Test (%0d layers) ---", num_layers);
        cpu_mode = 1;
        seq_start_time = $time;
        
        // first op (FETCH_INPUT) must be LSB -> pass as op0 to build_microprog
        microprog = build_microprog(make_cmd(OPC_STORE_OUTPUT), 
                                    make_cmd(OPC_COMPUTE), 
                                    make_cmd(OPC_FETCH_WEIGHTS), 
                                    make_cmd(OPC_FETCH_INPUT));
        
        // Submit all layers to the FIFO as fast as possible (handshake respected)
        for (i = 0; i < num_layers; i = i + 1) begin
            @(posedge clk);
            cpu_cmd_valid = 1;
            cpu_cmd_data = microprog;
            wait (cpu_cmd_ready);
            @(posedge clk);
            cpu_cmd_valid = 0;
            $display("[%0t] Sequencer: Submitted microprogram for Layer %0d.", $time, i+1);
        end

        wait(!accelerator_busy);
        seq_end_time = $time;
        
        // --- Report Results ---
        $display("\n--- Simulation Results ---");
        $display("Micromanagement Total Time: %0d cycles", (micro_end_time - micro_start_time)/10);
        $display("Sequencer Total Time:       %0d cycles", (seq_end_time - seq_start_time)/10);
        
        speedup = $itor(micro_end_time - micro_start_time) / $itor(seq_end_time - seq_start_time);
        $display("Speedup: %.2fx", speedup);
        
        #50;
        $finish;
    end
endmodule
