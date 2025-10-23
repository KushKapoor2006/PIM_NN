//=====================================================================
// File: pim_opcodes.svh
// Purpose: Shared command packet definitions and opcode constants for
//          the PIM sequencer / controller RTL.
// Usage : `include "pim_opcodes.svh" in any SV file that needs these.
//=====================================================================

`ifndef PIM_OPCODES_SVH
`define PIM_OPCODES_SVH

// -------------------------------
// Command packet layout (64 bits)
// -------------------------------
// Bit ranges (big picture):
// [63:56]  opcode     (8 bits)   -- operation selector
// [55:48]  flags      (8 bits)   -- per-command flags (reserved / mode bits)
// [47:16]  addr       (32 bits)  -- address or immediate (zero-extend to 64-bit if needed)
// [15:0]   mac_count  (16 bits)  -- number of MAC operations for compute commands
//
// Note: The exact wire packing / endianness must match how you construct
//       cmd_data in testbench / CPU logic. The RTL code assumes the
//       LSB 16 bits are mac_count, etc.
// -------------------------------

typedef struct packed {
    logic [7:0]  opcode;
    logic [7:0]  flags;
    logic [31:0] addr;
    logic [15:0] mac_count;
} pim_cmd_t;

// -------------------------------
// Opcode definitions (8-bit)
// -------------------------------
// Choose values that are easy to spot in simulation prints (hex-coded).
localparam logic [7:0] OPC_FETCH_INPUT    = 8'h01;
localparam logic [7:0] OPC_FETCH_WEIGHTS  = 8'h02;
localparam logic [7:0] OPC_COMPUTE        = 8'h03;
localparam logic [7:0] OPC_STORE_OUTPUT   = 8'h04;
localparam logic [7:0] OPC_EXECUTE_SEQ    = 8'h05; // optional meta-op from CPU to sequencer

// -------------------------------
// Helpful macros / extraction helpers
// -------------------------------
// You can cast a 64-bit vector into pim_cmd_t like:
//   pim_cmd_t cmd = pim_cmd_t'(cmd64);
// And access fields as cmd.opcode, cmd.addr, cmd.mac_count, etc.
//
// Alternatively, if using bit-slices:
//   opcode    = cmd64[63:56];
//   flags     = cmd64[55:48];
//   addr      = cmd64[47:16];
//   mac_count = cmd64[15:0];
//
// The RTL modules provided use pim_cmd_t'(cmd_data) where convenient.
//
// -------------------------------
`endif // PIM_OPCODES_SVH

