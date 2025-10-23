//=====================================================================
// File: pim_opcodes.svh
// Purpose: Defines PIM opcodes and command structure.
//=====================================================================

`ifndef PIM_OPCODES_SVH
`define PIM_OPCODES_SVH

// Define PIM operation codes
typedef enum logic [7:0] {
    OPC_NOP           = 8'h00,
    OPC_FETCH_INPUT   = 8'h01,
    OPC_FETCH_WEIGHTS = 8'h02,
    OPC_COMPUTE       = 8'h03,
    OPC_STORE_OUTPUT  = 8'h04,
    OPC_HALT          = 8'hFF // Example halt opcode
} pim_opcode_e;

// Define a generic PIM command structure
// This is heavily simplified for this example
typedef struct packed {
    pim_opcode_e opcode;     // 8-bit opcode
    logic [55:0] operand;    // 56-bit generic operand (e.g., address, size)
} pim_cmd_t;

`endif // PIM_OPCODES_SVH