// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2025 [Organization Name]
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// =============================================================================
// Module: wishbone_bus_splitter
// =============================================================================
//
// Description:
//   A parameterized 1-to-N Wishbone Classic bus splitter that connects a 
//   single Wishbone master to multiple slave peripherals. The module provides
//   address-based routing with automatic slave selection and error handling
//   for invalid address ranges.
//
// Features:
//   - Configurable number of slave interfaces
//   - Parameterized address decoding range
//   - Automatic error response for out-of-range addresses
//   - Full Wishbone Classic protocol compliance
//   - Combinatorial routing for minimal latency
//
// Operation:
//
//   Master to Slave (Demultiplexing):
//   - CYC signal broadcast to all slaves per Wishbone specification
//   - STB signal gated to selected slave only based on address decode
//   - Address, data, write enable, and byte select broadcast to all slaves
//   - Only the selected slave responds due to gated STB signal
//
//   Slave to Master (Multiplexing):
//   - Data output (DAT_O) multiplexed from selected slave
//   - Acknowledge (ACK) routed from selected slave
//   - Error (ERR) combines slave error and invalid address detection
//
// Address Decoding:
//   The module uses a configurable range of address bits to select the target
//   slave peripheral. The selection field width is automatically calculated
//   based on the number of peripherals.
//
//   Decode Logic:
//   - Selection bits = m_wb_adr_i[ADDR_SEL_LOW_BIT +: $clog2(NUM_PERIPHERALS)]
//   - Valid range: 0 to (NUM_PERIPHERALS - 1)
//   - Out-of-range addresses generate automatic error response
//
//   Example Configuration:
//   - NUM_PERIPHERALS = 3
//   - ADDR_SEL_LOW_BIT = 16
//   - Selection width = $clog2(3) = 2 bits
//   - Selection field = m_wb_adr_i[17:16]
//   - Address mapping:
//       2'b00 → Slave 0 (Valid)
//       2'b01 → Slave 1 (Valid)
//       2'b10 → Slave 2 (Valid)
//       2'b11 → Invalid (Error response)
//
// Error Handling:
//   The module generates error responses in two scenarios:
//   1. Invalid peripheral selection (address out of range)
//   2. Error flag asserted by selected slave (forwarded to master)
//
// Parameters:
//   NUM_PERIPHERALS  - Number of slave interfaces (must be ≥ 1)
//                      Note: Use non-power-of-2 values (e.g., 3, 5, 10) to
//                      enable automatic error detection for invalid addresses
//   ADDR_WIDTH       - Width of Wishbone address bus (bits)
//   DATA_WIDTH       - Width of Wishbone data bus (bits)
//   SEL_WIDTH        - Width of byte select bus (typically DATA_WIDTH/8)
//   ADDR_SEL_LOW_BIT - Starting bit position for peripheral address decode
//
// =============================================================================

module wishbone_bus_splitter #(
    parameter NUM_PERIPHERALS   = 10,
    parameter ADDR_WIDTH        = 32,
    parameter DATA_WIDTH        = 32,
    parameter SEL_WIDTH         = DATA_WIDTH / 8,
    parameter ADDR_SEL_LOW_BIT  = 16  // Base bit for peripheral selection
)(
    // Master Interface
    input  logic [ADDR_WIDTH-1:0] m_wb_adr_i,
    input  logic [DATA_WIDTH-1:0] m_wb_dat_i,
    output logic [DATA_WIDTH-1:0] m_wb_dat_o,
    input  logic                  m_wb_we_i,
    input  logic [SEL_WIDTH-1:0]  m_wb_sel_i,
    input  logic                  m_wb_cyc_i,
    input  logic                  m_wb_stb_i,
    output logic                  m_wb_ack_o,
    output logic                  m_wb_err_o,  // <-- ADDED

    // Slave Interfaces
    output logic [NUM_PERIPHERALS-1:0]                s_wb_cyc_o,
    output logic [NUM_PERIPHERALS-1:0]                s_wb_stb_o,
    output logic [NUM_PERIPHERALS-1:0]                s_wb_we_o,
    output logic [NUM_PERIPHERALS*SEL_WIDTH-1:0]      s_wb_sel_o,
    output logic [NUM_PERIPHERALS*ADDR_WIDTH-1:0]     s_wb_adr_o,
    output logic [NUM_PERIPHERALS*DATA_WIDTH-1:0]     s_wb_dat_o,
    input  logic [NUM_PERIPHERALS*DATA_WIDTH-1:0]     s_wb_dat_i,
    input  logic [NUM_PERIPHERALS-1:0]                s_wb_ack_i,
    input  logic [NUM_PERIPHERALS-1:0]                s_wb_err_i   // <-- ADDED
);
    // Calculate number of bits needed to select N peripherals
    localparam ADDR_SEL_WIDTH = $clog2(NUM_PERIPHERALS);
    localparam ADDR_SEL_HIGH_BIT = ADDR_SEL_LOW_BIT + ADDR_SEL_WIDTH - 1;

    // Check for parameter errors at elaboration time
    initial begin
        if (ADDR_SEL_HIGH_BIT >= ADDR_WIDTH) begin
            $display("ERROR: ADDR_SEL bits (%0d:%0d) exceed ADDR_WIDTH (%0d)",
                     ADDR_SEL_HIGH_BIT, ADDR_SEL_LOW_BIT, ADDR_WIDTH);
            $finish;
        end
    end

    // Internal signals for decoding
    wire [ADDR_SEL_WIDTH-1:0] peripheral_sel;
    wire                      valid_peripheral;

    // Combinatorial muxing signals
    logic [DATA_WIDTH-1:0] dat_mux;
    logic                  ack_mux;
    logic                  err_mux;

    // --- 1. Address Decoding ---
    assign peripheral_sel = m_wb_adr_i[ADDR_SEL_HIGH_BIT : ADDR_SEL_LOW_BIT];
    assign valid_peripheral = (peripheral_sel < NUM_PERIPHERALS);

    
    // --- 2. Master-to-Slave Demultiplexing ---
    genvar g;
    generate
        for (g = 0; g < NUM_PERIPHERALS; g = g + 1) begin : gen_slave_signals
            // CYC is broadcast to all slaves
            assign s_wb_cyc_o[g] = m_wb_cyc_i;

            // STB is gated only to the selected slave
            assign s_wb_stb_o[g] = m_wb_stb_i && valid_peripheral && (peripheral_sel == g);
            
            // Other signals are broadcast (slaves should ignore if STB is low)
            assign s_wb_we_o[g]  = m_wb_we_i;
            assign s_wb_sel_o[g*SEL_WIDTH +: SEL_WIDTH] = m_wb_sel_i;
            assign s_wb_adr_o[g*ADDR_WIDTH +: ADDR_WIDTH] = m_wb_adr_i;
            assign s_wb_dat_o[g*DATA_WIDTH +: DATA_WIDTH] = m_wb_dat_i;
        end
    endgenerate

    // --- 3. Slave-to-Master Multiplexing ---
    always_comb begin
        // Default values for an idle cycle or invalid access
        dat_mux = 32'hDEADBEEF; // Error/debug value
        ack_mux = 1'b0;
        err_mux = 1'b0;

        if (valid_peripheral) begin
            // Valid peripheral is selected: pass its signals back
            dat_mux = s_wb_dat_i[peripheral_sel*DATA_WIDTH +: DATA_WIDTH];
            ack_mux = s_wb_ack_i[peripheral_sel];
            err_mux = s_wb_err_i[peripheral_sel];
        end 
        else if (m_wb_stb_i && m_wb_cyc_i) begin
            // Access to an invalid address: generate an error
            ack_mux = 1'b0; // ACK and ERR must be mutually exclusive
            err_mux = 1'b1;
        end
    end

    assign m_wb_dat_o = dat_mux;
    assign m_wb_ack_o = ack_mux;
    assign m_wb_err_o = err_mux;

endmodule
