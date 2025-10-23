#include "verilated.h"          // Core Verilator header
#include "verilated_vcd_c.h"    // Waveform generation header
#include "Vtb_pim_system.h"   // Header generated from tb_pim_system.sv

#include <iostream>

int main(int argc, char** argv) {
    // Initialize Verilator
    VerilatedContext* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);

    // Instantiate our design
    Vtb_pim_system* top = new Vtb_pim_system{contextp};

    // Initialize waveform tracing
    VerilatedVcdC* tfp = new VerilatedVcdC;
    top->trace(tfp, 99); // Trace 99 levels of hierarchy
    tfp->open("pim_system_tb.vcd"); // Open the VCD file for writing

    std::cout << "Starting Verilator simulation..." << std::endl;

    // Simulation loop
    while (!contextp->gotFinish()) {
        // --- Clock Generation ---
        // Advance simulation time
        contextp->timeInc(5); // timeInc is in picoseconds (matches timescale)
        // Toggle the clock
        top->clk = !top->clk;
        // Evaluate the model
        top->eval();
        // Dump trace data
        tfp->dump(contextp->time());

        // Advance time again for the other half of the clock cycle
        contextp->timeInc(5);
        top->clk = !top->clk;
        top->eval();
        tfp->dump(contextp->time());
    }

    std::cout << "Verilator simulation finished." << std::endl;

    // Cleanup
    tfp->close();
    delete top;
    delete contextp;
    return 0;
}
