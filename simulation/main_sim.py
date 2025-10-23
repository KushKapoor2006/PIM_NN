#!/usr/bin/env python3
# main_sim.py
# Calibrated simulation script (micromanagement vs sequencer)
# - includes separate CPU-issue-cost calibration to reproduce the 3.02x example
# - saves CSV and speedup PNG to simulation/results/

import math
import csv
import os
from dataclasses import dataclass, asdict
from typing import List, Dict, Tuple
from collections import deque
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.ticker import FormatStrFormatter

# --- 1. System Configuration: A Credible, Parameterized Model ---
@dataclass
class SystemConfig:
    """Holds the architectural parameters of our simulated system. All units in cycles unless noted."""
    # Packet and Bus
    CMD_SIZE_BITS: int = 64
    BUS_WIDTH_BITS: int = 64

    # Controller and CPU Overheads (split for calibration)
    CONTROLLER_DECODE_CYCLES: int = 1
    # Default (kept for backward compatibility) — use per-mode fields below instead
    CPU_ISSUE_CYCLES: int = 1
    # Separate issue-cycle costs so micromanagement and sequencer can be calibrated independently
    CPU_ISSUE_CYCLES_MIC: int = 1    # used only in micromanagement model
    CPU_ISSUE_CYCLES_SEQ: int = 1    # used only in sequencer model
    CONTROLLER_WRITE_ACK_CYCLES: int = 0  # microprogram write ack

    # PIM Compute Throughput
    MACS_PER_CYCLE: float = 16.0
    PIM_BASE_LATENCY_CYCLES: int = 400

    # Sequencer-specific Costs (tuned small handshake values)
    SEQUENCER_FIFO_DEPTH: int = 4
    SEQUENCER_PER_MICRO_CYCLES: int = 1
    SEQUENCER_SETUP_CPU_CYCLES: int = 0
    SEQUENCER_EXECUTE_OVERHEAD: int = 1

    # IO Model
    FETCH_PAYLOAD_BITS: int = 64  # one bus-width chunk

    # Energy model (coarse)
    E_MAC_pJ: float = 0.1
    E_BUS_PER_64B_pJ: float = 10.0
    E_CTRL_DECODE_pJ: float = 1.0
    SEQUENCER_STATIC_mW: float = 1.0

    def __post_init__(self):
        # Derived parameters
        self.BUS_CYCLES_PER_TRANSFER: int = math.ceil(self.CMD_SIZE_BITS / self.BUS_WIDTH_BITS)
        self.FETCH_BUS_TRANSFERS: int = max(1, math.ceil(self.FETCH_PAYLOAD_BITS / self.BUS_WIDTH_BITS))

        # Fixed latencies (consistent with your SV TB)
        self.FETCH_CYCLES: int = 150
        self.STORE_CYCLES: int = 150


# --- 2. Workload Definition ---
@dataclass
class ConvLayer:
    name: str
    in_c: int; h: int; w: int; out_c: int; k: int

    def __post_init__(self):
        self.mac_ops: int = int(self.in_c * self.h * self.w * self.out_c * self.k * self.k)


# --- 3. Helpers ---
def consume_bus(bus_time: int, owner_start_time: int, num_transfers: int, cfg: SystemConfig, metrics: Dict) -> Tuple[int, int]:
    """
    Acquire the shared bus for `num_transfers` transfers (each transfer costs BUS_CYCLES_PER_TRANSFER).
    Returns (new_bus_time, owner_finish_time) and updates metrics['bus_transfers'].
    """
    start = int(max(owner_start_time, bus_time))
    duration = int(num_transfers) * int(cfg.BUS_CYCLES_PER_TRANSFER)
    finish = start + duration
    metrics['bus_transfers'] += int(num_transfers)
    return finish, finish


# --- 4. Simulation Functions (with tracing & energy accounting) ---
def simulate_micromanagement(cfg: SystemConfig, network: List[ConvLayer], micro_len: int = 4) -> Dict:
    cpu_time, pim_time, bus_time = 0, 0, 0
    metrics = {'cmds': 0, 'compute': 0, 'io': 0, 'bus_transfers': 0, 'macs': 0}
    trace = []

    # Use the MIC-specific CPU issue cycles (allows calibration)
    cpu_issue_cycles = cfg.CPU_ISSUE_CYCLES_MIC

    for idx, layer in enumerate(network):
        layer_id = idx + 1
        metrics['macs'] += layer.mac_ops
        compute_cycles = int(cfg.PIM_BASE_LATENCY_CYCLES + math.ceil(layer.mac_ops / cfg.MACS_PER_CYCLE))

        for cmd_name, is_compute in [('FETCH_INPUT', False), ('FETCH_WEIGHTS', False),
                                     ('COMPUTE', True), ('STORE_OUTPUT', False)]:
            cpu_issue_start = cpu_time
            cpu_time += cpu_issue_cycles

            # Command packet transfer
            bus_time, cpu_time = consume_bus(bus_time, cpu_time, 1, cfg, metrics)
            cmd_packet_end = cpu_time
            metrics['cmds'] += 1

            controller_ready = bus_time + cfg.CONTROLLER_DECODE_CYCLES
            start_pim = max(pim_time, controller_ready)

            io_time = 0
            comp_time = 0
            if not is_compute:
                bus_time, owner_finish = consume_bus(bus_time, start_pim, cfg.FETCH_BUS_TRANSFERS, cfg, metrics)
                pim_time = owner_finish + cfg.FETCH_CYCLES
                io_time = pim_time - start_pim
                metrics['io'] += io_time
            else:
                pim_time = start_pim + compute_cycles
                comp_time = compute_cycles
                metrics['compute'] += comp_time

            # CPU stalls until operation completes
            cpu_time = pim_time

            trace.append({
                'layer': layer_id,
                'cmd': cmd_name,
                'cpu_issue_start': cpu_issue_start,
                'cpu_issue_end': cmd_packet_end,
                'controller_ready': controller_ready,
                'pim_start': start_pim,
                'pim_end': pim_time,
                'compute_cycles': comp_time,
                'io_cycles': io_time
            })

    total_time = int(max(cpu_time, pim_time, bus_time))
    mat_busy_time = int(metrics['compute'] + metrics['io'])
    energy_pJ = metrics['macs'] * cfg.E_MAC_pJ + metrics['bus_transfers'] * cfg.E_BUS_PER_64B_pJ + metrics['cmds'] * cfg.E_CTRL_DECODE_pJ

    return {
        'total_time': total_time,
        'cpu_time': int(cpu_time),
        'pim_time': int(pim_time),
        'bus_time': int(bus_time),
        'mat_busy_time': mat_busy_time,
        'mat_compute_time': int(metrics['compute']),
        'mat_idle_cycles': int(total_time - mat_busy_time),
        'compute_utilization': (metrics['compute'] / mat_busy_time) if mat_busy_time else 0,
        'commands_issued': int(metrics['cmds']),
        'bus_transfers': int(metrics['bus_transfers']),
        'macs': int(metrics['macs']),
        'energy_pJ': energy_pJ,
        'trace': trace,
        'cfg': asdict(cfg)
    }


def simulate_sequencer(cfg: SystemConfig, network: List[ConvLayer], micro_len: int = 4) -> Dict:
    cpu_time, pim_time, bus_time = 0, 0, 0
    metrics = {'cmds': 0, 'compute': 0, 'io': 0, 'micro': 0, 'bus_transfers': 0, 'macs': 0}
    trace = []
    pim_finish_times = deque()

    # Use the SEQ-specific CPU issue cycles (burst + 1 execute)
    cpu_issue_seq = cfg.CPU_ISSUE_CYCLES_SEQ

    microprog_size_bytes = int((micro_len * cfg.CMD_SIZE_BITS) // 8)
    fifo_bytes = cfg.SEQUENCER_FIFO_DEPTH * microprog_size_bytes

    for idx, layer in enumerate(network):
        layer_id = idx + 1
        metrics['macs'] += layer.mac_ops

        # Free finished FIFO entries
        while pim_finish_times and pim_finish_times[0] <= cpu_time:
            pim_finish_times.popleft()

        # If FIFO full, wait
        if len(pim_finish_times) >= cfg.SEQUENCER_FIFO_DEPTH:
            earliest = pim_finish_times[0]
            cpu_time = earliest
            while pim_finish_times and pim_finish_times[0] <= cpu_time:
                pim_finish_times.popleft()

        # CPU writes microprogram burst
        cpu_burst_start = cpu_time + cfg.SEQUENCER_SETUP_CPU_CYCLES
        burst_transfers = int(math.ceil((micro_len * cfg.CMD_SIZE_BITS) / cfg.BUS_WIDTH_BITS))
        bus_time, cpu_time = consume_bus(bus_time, cpu_burst_start, burst_transfers, cfg, metrics)
        bus_time += cfg.CONTROLLER_WRITE_ACK_CYCLES
        cpu_time = bus_time

        # CPU issues single EXECUTE packet (lightweight in sequencer case)
        cpu_time += cpu_issue_seq
        bus_time, cpu_time = consume_bus(bus_time, cpu_time, 1, cfg, metrics)
        metrics['cmds'] += 1

        # PIM execution begins when controller ready and PIM free
        controller_ready_time = bus_time + cfg.SEQUENCER_EXECUTE_OVERHEAD
        start_pim_layer = max(pim_time, controller_ready_time)

        # IO1
        bus_time, pim_io1_fin = consume_bus(bus_time, start_pim_layer, cfg.FETCH_BUS_TRANSFERS, cfg, metrics)
        pim_io1_end = pim_io1_fin + cfg.FETCH_CYCLES

        # IO2
        bus_time, pim_io2_fin = consume_bus(bus_time, pim_io1_end, cfg.FETCH_BUS_TRANSFERS, cfg, metrics)
        pim_io2_end = pim_io2_fin + cfg.FETCH_CYCLES

        # Compute
        compute_cycles = int(cfg.PIM_BASE_LATENCY_CYCLES + math.ceil(layer.mac_ops / cfg.MACS_PER_CYCLE))
        compute_start = pim_io2_end
        compute_end = compute_start + compute_cycles

        # Store
        bus_time, pim_io3_fin = consume_bus(bus_time, compute_end, cfg.FETCH_BUS_TRANSFERS, cfg, metrics)
        pim_io3_end = pim_io3_fin + cfg.STORE_CYCLES

        local_micro_overhead = micro_len * cfg.SEQUENCER_PER_MICRO_CYCLES
        pim_time = pim_io3_end + local_micro_overhead
        pim_finish_times.append(pim_time)

        # Metrics accumulation
        layer_io = (pim_io1_end - start_pim_layer) + (pim_io2_end - pim_io1_end) + (pim_io3_end - compute_end)
        metrics['compute'] += compute_cycles
        metrics['io'] += layer_io
        metrics['micro'] += local_micro_overhead

        trace.append({
            'layer': layer_id,
            'cpu_burst_start': cpu_burst_start,
            'cpu_burst_end': cpu_time,
            'execute_issue_time': cpu_time,
            'pim_start': start_pim_layer,
            'pim_end': pim_time,
            'compute_cycles': compute_cycles,
            'io_cycles': layer_io,
            'micro_overhead': local_micro_overhead,
            'fifo_occupancy_after_submit': len(pim_finish_times),
            'microprog_bytes': microprog_size_bytes,
            'fifo_bytes': fifo_bytes
        })

    total_time = int(max(cpu_time, pim_time, bus_time))
    mat_busy_time = int(metrics['compute'] + metrics['io'] + metrics['micro'])

    energy_pJ = metrics['macs'] * cfg.E_MAC_pJ + metrics['bus_transfers'] * cfg.E_BUS_PER_64B_pJ + metrics['cmds'] * cfg.E_CTRL_DECODE_pJ
    # sequencer static energy (pJ)
    freq_ghz = 1.0
    total_time_s = total_time / (freq_ghz * 1e9)
    sequencer_static_energy_pJ = cfg.SEQUENCER_STATIC_mW * 1e-3 * total_time_s * 1e12
    energy_pJ += sequencer_static_energy_pJ

    return {
        'total_time': total_time,
        'cpu_time': int(cpu_time),
        'pim_time': int(pim_time),
        'bus_time': int(bus_time),
        'mat_busy_time': mat_busy_time,
        'mat_compute_time': int(metrics['compute']),
        'mat_idle_cycles': int(total_time - mat_busy_time),
        'compute_utilization': (metrics['compute'] / mat_busy_time) if mat_busy_time else 0,
        'commands_issued': int(metrics['cmds']),
        'bus_transfers': int(metrics['bus_transfers']),
        'macs': int(metrics['macs']),
        'energy_pJ': energy_pJ,
        'trace': trace,
        'cfg': asdict(cfg)
    }


# --- 5. Sweep runner ---
def run_sweep(macs_list=[1, 8, 32], fifo_list=[1, 4, 8], micro_len=4,
              include_calibrated_case=True):
    """
    Runs simulations for sweeps and optionally appends a calibrated example row.
    Generates a CSV file and a speedup plot.
    """
    rows = []
    # Workload for the main parameter sweep (e.g., 20 layers)
    big_network = [ConvLayer("layer", in_c=32, h=16, w=16, out_c=32, k=3) for _ in range(20)]
    print(f"--- Running Parameter Sweep (Workload: {len(big_network)} layers) ---")

    for macs in macs_list:
        for fifo in fifo_list:
            print(f"  Simulating: MACs/cycle={macs}, FIFO Depth={fifo}")
            # Use default CPU issue cycles for the sweep part
            cfg = SystemConfig(MACS_PER_CYCLE=macs, SEQUENCER_FIFO_DEPTH=fifo)
            mic = simulate_micromanagement(cfg, big_network, micro_len)
            seq = simulate_sequencer(cfg, big_network, micro_len)
            speedup = mic['total_time'] / seq['total_time'] if seq['total_time'] > 0 else float('inf')
            rows.append({
                'MACS_PER_CYCLE': macs, 'FIFO_DEPTH': fifo,
                'mic_total_time': mic['total_time'], 'seq_total_time': seq['total_time'],
                'speedup': speedup,
                'mic_compute_util': mic['compute_utilization'], 'seq_compute_util': seq['compute_utilization'],
                'mic_bus_transfers': mic['bus_transfers'], 'seq_bus_transfers': seq['bus_transfers'],
                'mic_commands': mic['commands_issued'], 'seq_commands': seq['commands_issued'],
                'mic_energy_pJ': mic['energy_pJ'], 'seq_energy_pJ': seq['energy_pJ'],
                'mic_macs': mic['macs'], 'seq_macs': seq['macs'],
                'case': 'sweep_big_net' # Tag for filtering
            })

    # --- Optionally run and append the calibrated case ---
    calib_info = None # Store calibrated data if generated
    if include_calibrated_case:
        print("\n--- Running Calibrated Case (Workload: 3 tiny layers) ---")
        # Calibrated parameters to reproduce specific speedup (e.g., ~3.02x)
        cfg_calib = SystemConfig(
            MACS_PER_CYCLE=8,
            SEQUENCER_FIFO_DEPTH=4,
            CPU_ISSUE_CYCLES_MIC=434, # Specific high cost for micromanagement
            CPU_ISSUE_CYCLES_SEQ=1    # Default low cost for sequencer
        )
        # Short, tiny workload to emphasize control overhead
        tiny_network = [ConvLayer("tiny_layer", in_c=1, h=1, w=1, out_c=1, k=1) for _ in range(3)]
        print(f"  Calibrated Config: MACs/cycle={cfg_calib.MACS_PER_CYCLE}, FIFO={cfg_calib.SEQUENCER_FIFO_DEPTH}, CPU_MIC_Cost={cfg_calib.CPU_ISSUE_CYCLES_MIC}")
        mic_cal = simulate_micromanagement(cfg_calib, tiny_network, micro_len=4)
        seq_cal = simulate_sequencer(cfg_calib, tiny_network, micro_len=4)
        speedup_cal = mic_cal['total_time'] / seq_cal['total_time'] if seq_cal['total_time'] > 0 else float('inf')

        calib_info = { # Store results in the same structure as rows
            'MACS_PER_CYCLE': cfg_calib.MACS_PER_CYCLE, 'FIFO_DEPTH': cfg_calib.SEQUENCER_FIFO_DEPTH,
            'mic_total_time': mic_cal['total_time'], 'seq_total_time': seq_cal['total_time'],
            'speedup': speedup_cal,
            'mic_compute_util': mic_cal['compute_utilization'], 'seq_compute_util': seq_cal['compute_utilization'],
            'mic_bus_transfers': mic_cal['bus_transfers'], 'seq_bus_transfers': seq_cal['bus_transfers'],
            'mic_commands': mic_cal['commands_issued'], 'seq_commands': seq_cal['commands_issued'],
            'mic_energy_pJ': mic_cal['energy_pJ'], 'seq_energy_pJ': seq_cal['energy_pJ'],
            'mic_macs': mic_cal['macs'], 'seq_macs': seq_cal['macs'],
            'case': 'calibrated_3.02x' # Tag for filtering
        }
        rows.append(calib_info)

    # --- Create DataFrame and Save CSV ---
    df = pd.DataFrame(rows)
    # Ensure numeric types for calculations and plotting
    for col in ['MACS_PER_CYCLE', 'FIFO_DEPTH', 'mic_total_time', 'seq_total_time', 'speedup']:
        df[col] = pd.to_numeric(df[col], errors='coerce') # Coerce forces non-numeric to NaN

    csv_path = 'simulation/results/sweep_results.csv'
    os.makedirs(os.path.dirname(csv_path), exist_ok=True)
    df.to_csv(csv_path, index=False)
    print(f"\nSweep results saved to: {os.path.abspath(csv_path)}")

    # --- Plotting ---
    fig, ax = plt.subplots(figsize=(10, 6)) # Adjusted figsize slightly

    # 1. Plot the sweep results (lines and points)
    sweep_df = df[df['case'] == 'sweep_big_net'].copy() # Filter for sweep data
    if not sweep_df.empty:
        for macs_val in sorted(sweep_df['MACS_PER_CYCLE'].unique()):
            # Select data for this specific MACS_PER_CYCLE value
            sub_df = sweep_df[sweep_df['MACS_PER_CYCLE'] == macs_val].sort_values('FIFO_DEPTH')
            if not sub_df.empty:
                avg_speedup = sub_df['speedup'].mean()
                label_text = f'MACs/cycle={int(macs_val)} (Avg Speedup: {avg_speedup:.2f}x)'
                ax.plot(sub_df['FIFO_DEPTH'], sub_df['speedup'], marker='o', linestyle='-', label=label_text)
                # Add annotations for each point
                for x, y in zip(sub_df['FIFO_DEPTH'], sub_df['speedup']):
                     # Check if y is finite before formatting
                    if np.isfinite(y):
                        ax.annotate(f"{y:.2f}x", (x, y), textcoords="offset points", xytext=(0, 8), ha='center', fontsize=9)
    else:
        print("Warning: No sweep data found to plot.")

    # 2. Plot the calibrated case (if it exists) as a distinct marker
    if calib_info is not None:
        # Extract data ensuring it's numeric
        x_cal = pd.to_numeric(calib_info['FIFO_DEPTH'], errors='coerce')
        y_cal = pd.to_numeric(calib_info['speedup'], errors='coerce')

        if pd.notna(x_cal) and pd.notna(y_cal) and np.isfinite(y_cal):
            # Plot as a large star
            ax.plot(x_cal, y_cal, marker='*', markersize=18, markeredgecolor='black', markerfacecolor='red',
                    linestyle='None', # Don't connect with lines
                    label=f'Calibrated Case (~{y_cal:.2f}x)')
            # Add annotation for the calibrated point
            ax.annotate(f"{y_cal:.2f}x\n(Calibrated @ FIFO={int(x_cal)})", (x_cal, y_cal),
                        textcoords="offset points", xytext=(0, -30), # Position below the star
                        ha='center', va='top', fontsize=10, fontweight='bold',
                        bbox=dict(boxstyle="round,pad=0.3", fc="yellow", alpha=0.6))
        else:
            print("Warning: Calibrated case data is invalid or non-finite, cannot plot.")

    # --- Plot Formatting ---
    # Adjust Y-axis limits more dynamically
    valid_speedups = df['speedup'].replace([np.inf, -np.inf], np.nan).dropna()
    if not valid_speedups.empty:
        min_s = valid_speedups.min()
        max_s = valid_speedups.max()
        # Ensure minimum is not below 0, add padding
        y_min_limit = max(0.0, min_s - 0.2 * (max_s - min_s + 1e-6)) # Add epsilon for robustness
        y_max_limit = max_s + 0.2 * (max_s - min_s + 1e-6)
        # Ensure y_max_limit is reasonably larger than y_min_limit
        if y_max_limit <= y_min_limit + 0.1: y_max_limit = y_min_limit + 0.5
        ax.set_ylim(y_min_limit, y_max_limit)
    else:
        ax.set_ylim(0, 5) # Default limit if no valid data

    ax.xaxis.set_major_formatter(FormatStrFormatter('%d')) # Ensure integer ticks
    ax.set_xticks(fifo_list) # Set ticks explicitly based on the sweep values

    ax.set_xlabel('Sequencer FIFO Depth (entries)', fontsize=12)
    ax.set_ylabel('Speedup (Micromanagement Time / Sequencer Time)', fontsize=12)
    ax.set_title('Sequencer Speedup vs. FIFO Depth for Varying Compute Power', fontsize=14, fontweight='bold')
    ax.grid(True, which='both', linestyle='--', linewidth=0.5, alpha=0.7)
    ax.axhline(1.0, color='grey', linestyle=':', linewidth=1.0, label='Baseline (No Speedup)') # Add baseline
    ax.legend(loc='best', fontsize=10)

    # --- Save Plot ---
    fig_path = 'simulation/results/speedup.png'
    os.makedirs(os.path.dirname(fig_path), exist_ok=True) # Ensure directory exists
    try:
        fig.savefig(fig_path, dpi=150, bbox_inches='tight')
        print(f"Plot saved successfully to: {os.path.abspath(fig_path)}")
    except Exception as e:
        print(f"Error saving plot: {e}")

    plt.close(fig) # Close the plot to free memory

    return df, csv_path, fig_path

# --- Main Execution ---
if __name__ == '__main__':
    # Run sweep including the calibrated case by default
    df_results, csv_path, fig_path = run_sweep(
        macs_list=[1, 8, 32], # Standard MACs sweep
        fifo_list=[1, 4, 8],  # Standard FIFO sweep
        micro_len=4,
        include_calibrated_case=True # Ensure calibrated case is run and plotted
    )
    # Display first few rows including calibrated if present
    print("\n--- Sweep Results DataFrame (Head) ---")
    print(df_results.head(len(df_results)).to_string(index=False))

    # --- Save Trace for the Calibrated Case ---
    # Configuration specifically for the calibrated trace
    print("\n--- Generating Trace for Calibrated Case ---")
    cfg_calibrated_trace = SystemConfig(
        MACS_PER_CYCLE=8,
        SEQUENCER_FIFO_DEPTH=4,
        CPU_ISSUE_CYCLES_MIC=434,
        CPU_ISSUE_CYCLES_SEQ=1
    )
    # Use the tiny network for the calibrated trace
    network_calibrated_trace = [ConvLayer("tiny_layer", in_c=1, h=1, w=1, out_c=1, k=1) for _ in range(3)]

    mic_example = simulate_micromanagement(cfg_calibrated_trace, network_calibrated_trace)
    seq_example = simulate_sequencer(cfg_calibrated_trace, network_calibrated_trace)

    trace_csv_path = 'simulation/results/traces.csv'
    os.makedirs(os.path.dirname(trace_csv_path), exist_ok=True)
    combined_trace = []
    # Add mode identifier and copy data safely
    for t in mic_example.get('trace', []): combined_trace.append({**t, 'mode': 'micromanagement'})
    for t in seq_example.get('trace', []): combined_trace.append({**t, 'mode': 'sequencer'})

    if combined_trace:
        # Dynamically get all keys from all trace dictionaries
        all_keys = sorted(list(set(key for trace_dict in combined_trace for key in trace_dict.keys())))
        try:
            with open(trace_csv_path, 'w', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=all_keys)
                writer.writeheader()
                writer.writerows(combined_trace)
            print(f"Saved example trace CSV to: {os.path.abspath(trace_csv_path)}")
        except Exception as e:
            print(f"Error writing trace CSV: {e}")
    else:
        print("Warning: No trace data generated to save.")

    # --- Print Representative Calibrated Results ---
    print("\n--- Representative Calibrated Results Summary ---")
    mic_time = mic_example.get('total_time', 0)
    seq_time = seq_example.get('total_time', 0)
    if seq_time > 0:
        speedup_rep = mic_time / seq_time
        print(f"Micromanagement total_time: {mic_time}")
        print(f"Sequencer total_time:       {seq_time}")
        print(f"Speedup (mic/seq):          {speedup_rep:.3f}x  <-- Calibrated Case Result")
    else:
        print("Calibrated case simulation failed or produced zero sequencer time.")