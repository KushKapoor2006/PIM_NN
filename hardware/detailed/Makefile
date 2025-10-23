# Makefile for Verilator Simulation

# --- Configuration ---
TOP_MODULE = tb_pim_system
DRIVER_FILE = tb/tb_driver.cpp

# --- Tools ---
VERILATOR = verilator
CXX = g++
CXXFLAGS = -std=c++11 -I/usr/share/verilator/include
LDFLAGS = -L/usr/lib -lverilated

# --- Verilator Flags ---
VFLAGS = -Wall --cc --exe --build -j 0 --trace -sv \
         -I./src \
         --top-module $(TOP_MODULE) \
         -o ./obj_dir/sim_main

# --- Source Files ---
# --- FIX: Added priority_arbiter.sv and memory_model.sv ---
VSOURCES = tb/tb_pim_system.sv \
           src/pim_system.sv \
           src/sequencer_fsm.sv \
           src/sequencer_fifo.sv \
           src/pim_controller.sv \
           src/bus_interface.sv \
           src/priority_arbiter.sv \
           src/memory_model.sv

# Default target
all:
	@echo "Running Verilator to build simulation executable..."
	$(VERILATOR) $(VFLAGS) $(VSOURCES) $(DRIVER_FILE)

# Target to run the simulation
run: all
	@echo "Executing simulation..."
	./obj_dir/sim_main

# Target to view waveforms
view:
	@echo "Opening GTKWave..."
	gtkwave pim_system_tb.vcd

# Target to clean up generated files
clean:
	@echo "Cleaning up..."
	rm -rf obj_dir pim_system_tb.vcd

.PHONY: all run view clean
