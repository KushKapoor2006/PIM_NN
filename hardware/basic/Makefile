# Makefile for iverilog simulation

# --- Tool ---
VERILOG = iverilog

# --- Flags ---
# Use -g2012 for SystemVerilog features
VFLAGS = -g2012

# --- Files ---
# List all Verilog/SV files needed for the simulation
SOURCES = tb_sequencer_accelerator.sv sequencer_accelerator.sv

# --- Targets ---
# Default target
all:
	$(VERILOG) $(VFLAGS) -o sim.vvp $(SOURCES)

# Target to run the simulation
run: all
	vvp sim.vvp

# Target to view waveforms with GTKWave
view:
	gtkwave accelerator_tb.vcd

# Target to clean up generated files
clean:
	rm -f sim.vvp accelerator_tb.vcd

.PHONY: all run view clean