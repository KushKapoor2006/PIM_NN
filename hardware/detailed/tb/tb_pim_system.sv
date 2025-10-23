`timescale 1ns/1ps
`include "../src/pim_opcodes.svh"

module tb_pim_system;

    // clock / reset
    logic clk;
    logic rst_n;

    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100 MHz -> 10 ns period (for waveform timing)
    end

    // DUT ports
    logic cpu_cmd_valid;
    logic [63:0] cpu_cmd_data;
    logic cpu_cmd_ready;

    logic cpu_microprog_valid;
    logic [64*4-1:0] cpu_microprog_data; // MICROPROG_LEN_WORDS = 4, CMD_SIZE_BITS = 64
    logic cpu_microprog_ack;

    logic cpu_execute_seq_valid;
    logic cpu_execute_seq_ready;

    logic pim_system_idle;
    logic sequencer_busy_out;

    // --- FIX: Moved all logic declarations to the module scope ---
    logic [63:0] op_fetch_input;
    logic [63:0] op_fetch_weights;
    logic [63:0] op_compute;
    logic [63:0] op_store;
    logic [64*4-1:0] microprog;
    logic [63:0] cpu_compute_cmd;

    // instantiate DUT
    pim_system uut (
        .clk(clk),
        .rst_n(rst_n),
        .cpu_cmd_valid(cpu_cmd_valid),
        .cpu_cmd_data(cpu_cmd_data),
        .cpu_cmd_ready(cpu_cmd_ready),
        .cpu_microprog_valid(cpu_microprog_valid),
        .cpu_microprog_data(cpu_microprog_data),
        .cpu_microprog_ack(cpu_microprog_ack),
        .cpu_execute_seq_valid(cpu_execute_seq_valid),
        .cpu_execute_seq_ready(cpu_execute_seq_ready),
        .pim_system_idle(pim_system_idle),
        .sequencer_busy_out(sequencer_busy_out)
    );

    // ---------- helper: build command words ----------
    function automatic logic [63:0] make_cmd(input logic [7:0] opcode,
                                             input logic [31:0] addr,
                                             input logic [15:0] mac_count);
        logic [7:0] flags = 8'h00;
        make_cmd = {opcode, flags, addr, mac_count};
    endfunction

    // ---------- stimulus ----------
    initial begin
        // VCD dump
        $dumpfile("pim_system_tb.vcd");
        $dumpvars(0, tb_pim_system);

        // reset
        rst_n = 1'b0;
        cpu_cmd_valid = 0;
        cpu_cmd_data = 0;
        cpu_microprog_valid = 0;
        cpu_microprog_data = 0;
        cpu_execute_seq_valid = 0;
        #50;
        rst_n = 1'b1;
        #20;

        $display("[%0t] Testbench: Reset deasserted", $time);

        // Build a standard microprogram for a single layer
        op_fetch_input   = make_cmd(OPC_FETCH_INPUT,  32'h0000_1000, 16'h0000);
        op_fetch_weights = make_cmd(OPC_FETCH_WEIGHTS,32'h0000_2000, 16'h0000);
        op_compute       = make_cmd(OPC_COMPUTE,      32'h0000_0000, 16'd10000);
        op_store         = make_cmd(OPC_STORE_OUTPUT, 32'h0000_3000, 16'h0000);
        
        // microprogram packing: {op3, op2, op1, op0} so op0 is LSB
        microprog = {op_store, op_compute, op_fetch_weights, op_fetch_input};

        // Write 3 microprogram entries into the sequencer FIFO
        for (int i = 0; i < 3; i++) begin
            @(posedge clk);
            cpu_microprog_data = microprog;
            cpu_microprog_valid = 1;
            @(posedge clk);
            wait (cpu_microprog_ack == 1); // wait for ack from FIFO
            $display("[%0t] TB: FIFO accepted microprogram entry %0d", $time, i);
            cpu_microprog_valid = 0;
            #1;
        end

        $display("[%0t] TB: Wrote 3 microprograms into FIFO. Sequencer should start processing.", $time);

        // Let sequencer run for a while
        repeat (800) @(posedge clk);

        // Now issue a micromanagement compute command
        cpu_compute_cmd = make_cmd(OPC_COMPUTE, 32'h0, 16'd5000);
        @(posedge clk);
        cpu_cmd_data = cpu_compute_cmd;
        cpu_cmd_valid = 1;
        
        wait (cpu_cmd_ready); // wait until CPU command is accepted
        @(posedge clk);
        cpu_cmd_valid = 0;
        $display("[%0t] TB: Issued and got ack for direct CPU compute command.", $time);

        // wait until the system is idle
        wait (pim_system_idle);
        #20;
        $display("[%0t] TB: System idle. Test complete.", $time);
        $finish;
    end

endmodule
