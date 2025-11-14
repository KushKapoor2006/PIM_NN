# PIM-NN

**Accelerator / Simulation framework for comparing micromanagement vs hardware sequencer**

## TL;DR
### PIM_NN — Processing-In-Memory Neural Primitives (SystemVerilog)
- **What:** Proof-of-concept SystemVerilog RTL implementing PIM-style neural building blocks and testbenches for verification.
- **Goal / Value:** Rapidly evaluates near-memory compute primitives, memory-bound NN kernels, and microarchitectural PIM tradeoffs; serves as a starting point for synthesizable PIM datapath development and DRAM-aware accelerator explorations.
- **Status:** Functional verification RTL + TBs provided; recommended next steps: pipeline the datapath, add multi-cycle units (dividers, accumulators), and map heavy ops to DSP/BRAM for synthesis.
---

## What this repo contains

This repository provides a behavioral SystemVerilog model of a simple PIM accelerator (`hardware/`)
and a Python-based, cycle-approximate simulator (`simulation/main_sim.py`) to compare two control
styles:

* **Micromanagement** — CPU issues every PIM micro-op and waits (chatty).
* **Sequencer** — CPU writes microprograms to an on-chip FIFO and issues a single EXECUTE; the
  hardware sequencer autonomously steps through micro-ops (batched, low-CPU overhead).

The goal is to quantify wall-clock *speedup*, bus traffic, command counts, and coarse energy
for both approaches and to reproduce a calibrated 3.02× measured speedup from the RTL TB in a
representative case.

---

## Top-level layout (mirror of the workspace)

```
PIM-NN/
├─ hardware/
│  ├─ basic/
│  │  ├─ sequencer_accelerator.sv
│  │  ├─ pim_opcodes.svh
│  │  ├─ tb_sequencer_accelerator.sv
│  │  └─ accelerator_tb.vcd
│  ├─ detailed/
│  │  └─ (optional RTL/extended models)
│  └─ Makefile / sim.vvp (scripts for running the RTL TB)
├─ simulation/
│  ├─ main_sim.py                # calibrated Python simulator
│  ├─ gantt.py                   # Gantt chart utilities (optional)
│  ├─ sensitivity.py             # sensitivity runner & plots
│  └─ results/
│     ├─ sweep_results.csv
│     ├─ sensitivity_results.csv
│     ├─ traces.csv
│     ├─ speedup.png
│     └─ gantt_chart_comparison.png
└─ README.md
```

(Your workspace screenshot shows `main_sim.py`, `gantt.py`, `sensitivity.py` and `simulation/results/*`.)

---

## Quick start

### Requirements

* Python 3.8+
* pip packages: `pandas`, `matplotlib`, `numpy`
* (Optional) Icarus/Verilator for running the SystemVerilog TB (`sequencer_accelerator.sv`)

Install the Python deps:

```bash
pip install pandas matplotlib numpy
```

### Run the Python simulation sweep + calibrated example

```bash
python3 simulation/main_sim.py
```

This will:

* run a parameter sweep and a calibrated tiny-workload case that reproduces the **~3.02×** speedup,
* write `simulation/results/sweep_results.csv`, `simulation/results/traces.csv`, and
  `simulation/results/speedup.png`.

### Run the RTL TB (optional)

If you want to reproduce the hardware testbench measurements:

```bash
cd hardware/basic
# with iverilog/vvp
iverilog -o sim.vvp tb_sequencer_accelerator.sv sequencer_accelerator.sv pim_opcodes.svh
vvp sim.vvp
# produces accelerator_tb.vcd which can be viewed in GTKWave
```

The RTL TB measures CPU-mode vs sequencer-mode runtime for a short multi-layer microprogram and
reports the `speedup` printed (this is the number we calibrate the Python script to match).

---

## Important scripts & where to look

* `simulation/main_sim.py` — cycle-approximate simulator with two models:

  * `simulate_micromanagement(...)` and `simulate_sequencer(...)`.
  * `run_sweep(...)` runs an informative sweep (20-layer workload) and appends the calibrated tiny-case.
  * The script has a calibrated parameter set that reproduces the SV TB behavior (`CPU_ISSUE_CYCLES_MIC=434`)
    and produces a highlighted point in `speedup.png`.

* `simulation/gantt.py` — helper to visualize per-layer traces (Gantt charts) from `traces.csv`.

* `hardware/basic/sequencer_accelerator.sv` and `tb_sequencer_accelerator.sv` — RTL model and TB used for
  verification and to obtain the baseline speedup reference.

---

## Calibrated example and interpretation

The calibrated case intentionally models a high per-command CPU cost for micromanagement to emulate the
handshake-heavy behavior in the SV testbench. That parameter is **tunable** — we set it to reproduce the
observed RTL speedup for a short, control-heavy workload. Important notes:

* The **3.02×** number comes from a small, tiny workload (3 microprograms / layers) where control latency
  dominates compute costs. For large, compute-dominated networks (20+ layers or heavy MACs) that CPU overhead
  is amortized and the speedup drops towards ≈1.0.
* If you change MAC throughput (`MACS_PER_CYCLE`), FIFO depth, microprogram length or the workload shape
  (number of layers / MAC ops per layer), the measured speedup will change.

---

## Output files (what to inspect)

* `simulation/results/sweep_results.csv` — full table with columns including `MACS_PER_CYCLE`, `FIFO_DEPTH`,
  `mic_total_time`, `seq_total_time`, `speedup`, `mic_commands`, `seq_commands`, `mic_bus_transfers`, etc.
* `simulation/results/speedup.png` — the main figure comparing speedup vs FIFO depth for multiple MACS settings
  and annotating the calibrated point (3.02×).
* `simulation/results/traces.csv` — combined mic/seq per-layer traces which `gantt.py` consumes for timing
  diagrams.

---

## How to reproduce the ∼3.02× number (step-by-step)

1. Ensure `simulation/main_sim.py` contains the calibrated example; confirm the constants

   * `CPU_ISSUE_CYCLES_MIC = 434` and `CPU_ISSUE_CYCLES_SEQ = 1` in the `SystemConfig` for the calibrated run.
2. Run `python3 simulation/main_sim.py`.
3. Inspect `simulation/results/speedup.png` — the calibrated red star marker should be annotated with `~3.02x`.
4. Inspect `simulation/results/traces.csv` for the corresponding `case` (tagged `calibrated_3.02x`) and cross-check
   total_time fields in the CSV.

---

## Common tunables (and their effect)

* `CPU_ISSUE_CYCLES_MIC` — increases micromanagement overhead; higher → larger speedup for tiny workloads.
* `MACS_PER_CYCLE` — increases compute throughput; higher → compute-dominated regime, speedup falls toward 1.
* `SEQUENCER_FIFO_DEPTH` — larger FIFO lets the CPU push more microprograms ahead of time; reduces backpressure.
* `PIM_BASE_LATENCY_CYCLES` — base compute latency per layer; raising this increases compute-dominance.
* `FETCH_CYCLES` / `STORE_CYCLES` — increases IO costs; can change how much bus contention matters.

Tune them in `main_sim.py` and re-run the sweep to explore sensitivity.

---

## Assumptions & Simplifications

1. **Cycle-granular model** — the Python model is *behavioral* and uses cycle counts to approximate timing. It is
   intentionally simple so it can be changed and explored rapidly. It is not a timing-accurate gate-level model.
2. **Shared bus serialisation** — all bus transfers are serialized and modeled with `BUS_CYCLES_PER_TRANSFER`.
3. **Fixed IO latencies** — `FETCH_CYCLES` and `STORE_CYCLES` are fixed constants (150 cycles) for simplicity.
4. **Coarse energy model** — energy is a simple linear combination of MAC counts, bus transfers and static sequencer
   power; not calibrated to silicon unless you provide silicon numbers.
5. **Calibrations are modelling choices** — using a large `CPU_ISSUE_CYCLES_MIC` is a deliberate calibration to
   reproduce RTL TB behavior and should be documented when reporting results.

---


## Authorship

**Project:** Reconfigurable Near-Memory Neural Primitives

**Author:** Kush Kapoor

---
