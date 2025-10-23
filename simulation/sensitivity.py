#!/usr/bin/env python3
# sensitivity_analysis_fixed.py
# Copy-paste and run. Assumes your simulator module is importable as `sim`
# (adjust the import line if your simulator file has a different name).

import math
import os
import numpy as np
import pandas as pd
import matplotlib.pyplot as plt

# Adjust this import to match your file name (e.g., rigorous_control_plane_sim_final -> import rigorous_control...)
from main_sim import SystemConfig, ConvLayer, simulate_micromanagement, simulate_sequencer

OUT_DIR = "simulation"
os.makedirs(OUT_DIR, exist_ok=True)

def safe_speedup(mic_t, seq_t):
    # Returns mic/seq safely; if seq_t is zero (shouldn't), return np.nan
    try:
        if seq_t <= 0:
            return float('nan')
        return float(mic_t) / float(seq_t)
    except Exception:
        return float('nan')

def run_sensitivity_analysis():
    print("--- Running Sensitivity Analysis (fixed) ---")
    network = [ConvLayer("layer", in_c=32, h=16, w=16, out_c=32, k=3) for _ in range(20)]
    default_cfg = SystemConfig()

    # Sweep 1: MACS_PER_CYCLE (log spaced)
    macs_sweep = [4, 8, 16, 32, 64, 128]
    mac_rows = []
    for macs in macs_sweep:
        cfg = SystemConfig(MACS_PER_CYCLE=macs,
                           BUS_WIDTH_BITS=default_cfg.BUS_WIDTH_BITS,
                           FETCH_PAYLOAD_BITS=default_cfg.FETCH_PAYLOAD_BITS,
                           SEQUENCER_FIFO_DEPTH=default_cfg.SEQUENCER_FIFO_DEPTH)
        mic_res = simulate_micromanagement(cfg, network)
        seq_res = simulate_sequencer(cfg, network)
        speedup = safe_speedup(mic_res['total_time'], seq_res['total_time'])
        mac_rows.append({
            'sweep_var': macs, 'type': 'macs',
            'mic_total_time': mic_res['total_time'],
            'seq_total_time': seq_res['total_time'],
            'speedup': speedup,
            'mic_compute_util': mic_res.get('compute_utilization', float('nan')),
            'seq_compute_util': seq_res.get('compute_utilization', float('nan'))
        })
        print(f"MACs={macs}: mic={mic_res['total_time']}, seq={seq_res['total_time']}, speedup={speedup:.3f}")

    # Sweep 2: BUS_WIDTH_BITS (log spaced; keep other params default)
    bus_sweep = [32, 64, 128, 256, 512]  # add 32 to see narrower bus too
    bus_rows = []
    for width in bus_sweep:
        cfg = SystemConfig(BUS_WIDTH_BITS=width,
                           MACS_PER_CYCLE=default_cfg.MACS_PER_CYCLE,
                           FETCH_PAYLOAD_BITS=default_cfg.FETCH_PAYLOAD_BITS,
                           SEQUENCER_FIFO_DEPTH=default_cfg.SEQUENCER_FIFO_DEPTH)
        mic_res = simulate_micromanagement(cfg, network)
        seq_res = simulate_sequencer(cfg, network)
        speedup = safe_speedup(mic_res['total_time'], seq_res['total_time'])
        bus_rows.append({
            'sweep_var': width, 'type': 'bus',
            'mic_total_time': mic_res['total_time'],
            'seq_total_time': seq_res['total_time'],
            'speedup': speedup,
            'mic_compute_util': mic_res.get('compute_utilization', float('nan')),
            'seq_compute_util': seq_res.get('compute_utilization', float('nan'))
        })
        print(f"BUS={width} bits: mic={mic_res['total_time']}, seq={seq_res['total_time']}, speedup={speedup:.3f}")

    rows = mac_rows + bus_rows
    df = pd.DataFrame(rows)
    csv_out = os.path.join(OUT_DIR, "results/sensitivity_results.csv")
    df.to_csv(csv_out, index=False)
    print(f"[INFO] Results saved to {csv_out}")

    # ----- Plotting -----
    fig, axes = plt.subplots(2, 1, figsize=(10, 10))
    ax_speedup, ax_times = axes

    # Plot MACs sweep on speedup axis
    mac_df = df[df['type'] == 'macs'].copy()
    ax_speedup.plot(mac_df['sweep_var'], mac_df['speedup'], marker='o', label='vary MACs (keep bus default)')
    ax_speedup.set_xscale('log', base=2)
    ax_speedup.set_xlabel('MACs per cycle (log2 scale)')
    ax_speedup.set_ylabel('Speedup (mic / seq)')
    ax_speedup.grid(True, which='both', ls=':')
    ax_speedup.set_title('Sequencer Speedup vs MACs per Cycle')

    # Plot BUS sweep on same axis with different marker
    bus_df = df[df['type'] == 'bus'].copy()
    ax_speedup.plot(bus_df['sweep_var'], bus_df['speedup'], marker='s', label='vary BUS width (bits)')
    ax_speedup.set_xscale('log', base=2)
    # Put legend
    ax_speedup.legend()

    # Plot absolute times in second subplot (log scale y)
    ax_times.plot(mac_df['sweep_var'], mac_df['mic_total_time'], marker='o', label='mic_total_time (MAC sweep)')
    ax_times.plot(mac_df['sweep_var'], mac_df['seq_total_time'], marker='o', linestyle='--', label='seq_total_time (MAC sweep)')
    ax_times.plot(bus_df['sweep_var'], bus_df['mic_total_time'], marker='s', label='mic_total_time (BUS sweep)')
    ax_times.plot(bus_df['sweep_var'], bus_df['seq_total_time'], marker='s', linestyle='--', label='seq_total_time (BUS sweep)')
    ax_times.set_xscale('log', base=2)
    ax_times.set_yscale('log')
    ax_times.set_xlabel('Sweep variable (log2 scale)')
    ax_times.set_ylabel('Total time (cycles, log scale)')
    ax_times.grid(True, which='both', ls=':')
    ax_times.set_title('Absolute total times (mic vs seq)')

    ax_times.legend()
    plt.tight_layout()
    fig_path = os.path.join(OUT_DIR, "results/sensitivity_analysis.png")
    plt.savefig(fig_path, dpi=200)
    print(f"[INFO] Figure saved to {fig_path}")
    plt.show(block=False)
    return df, fig_path

if __name__ == "__main__":
    df, fig_path = run_sensitivity_analysis()
