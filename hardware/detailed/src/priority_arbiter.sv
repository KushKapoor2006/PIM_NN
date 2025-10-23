//=====================================================================
// File: priority_arbiter.sv
// Purpose: Generic fixed-priority arbiter. Highest index has highest priority.
//=====================================================================

`timescale 1ns / 1ps

module priority_arbiter #(
    parameter int MASTERS = 2
) (
    input  logic [MASTERS-1:0] req,
    output logic [MASTERS-1:0] gnt
);
    always_comb begin
        gnt = '0;
        for (int i = MASTERS - 1; i >= 0; i--) begin
            if (req[i]) begin
                gnt[i] = 1'b1;
                break;
            end
        end
    end
endmodule
