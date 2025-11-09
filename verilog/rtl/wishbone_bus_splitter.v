`timescale 1ns/1ps

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
    parameter SEL_WIDTH         = (DATA_WIDTH / 8),
    parameter ADDR_SEL_LOW_BIT  = 16  // Base bit for peripheral selection
)(
    // Master Interface
    input  wire [ADDR_WIDTH-1:0] m_wb_adr_i,
    input  wire [DATA_WIDTH-1:0] m_wb_dat_i,
    output wire [DATA_WIDTH-1:0] m_wb_dat_o,
    input  wire                  m_wb_we_i,
    input  wire [SEL_WIDTH-1:0]  m_wb_sel_i,
    input  wire                  m_wb_cyc_i,
    input  wire                  m_wb_stb_i,
    output wire                  m_wb_ack_o,
    output wire                  m_wb_err_o,

    // Slave Interfaces
    output wire [NUM_PERIPHERALS-1:0]            s_wb_cyc_o,
    output wire [NUM_PERIPHERALS-1:0]            s_wb_stb_o,
    output wire [NUM_PERIPHERALS-1:0]            s_wb_we_o,
    output wire [NUM_PERIPHERALS*SEL_WIDTH-1:0]  s_wb_sel_o,
    output wire [NUM_PERIPHERALS*ADDR_WIDTH-1:0] s_wb_adr_o,
    output wire [NUM_PERIPHERALS*DATA_WIDTH-1:0] s_wb_dat_o,
    input  wire [NUM_PERIPHERALS*DATA_WIDTH-1:0] s_wb_dat_i,
    input  wire [NUM_PERIPHERALS-1:0]            s_wb_ack_i,
    input  wire [NUM_PERIPHERALS-1:0]            s_wb_err_i
);

    // --------- Helpers ----------
    // Synthesizable clog2 (returns 0 for val<=1)
    function integer clog2;
        input integer value;
        integer v;
        begin
            v = value - 1;
            clog2 = 0;
            while (v > 0) begin
                v = v >> 1;
                clog2 = clog2 + 1;
            end
        end
    endfunction

    // Ensure selection width is at least 1 bit to avoid zero-width vectors
    localparam ADDR_SEL_WIDTH    = (NUM_PERIPHERALS <= 1) ? 1 : clog2(NUM_PERIPHERALS);
    localparam ADDR_SEL_HIGH_BIT = ADDR_SEL_LOW_BIT + ADDR_SEL_WIDTH - 1;

    // Optional debug default word (all zeros to be width-agnostic)
    localparam [DATA_WIDTH-1:0] DEBUG_WORD = {DATA_WIDTH{1'b0}};

    // --------- Elaboration-time parameter checks (simulation-time) ----------
    initial begin
        if (ADDR_SEL_HIGH_BIT >= ADDR_WIDTH) begin
            $display("ERROR: ADDR_SEL bits (%0d:%0d) exceed ADDR_WIDTH (%0d)",
                     ADDR_SEL_HIGH_BIT, ADDR_SEL_LOW_BIT, ADDR_WIDTH);
            $finish;
        end
        if (NUM_PERIPHERALS < 1) begin
            $display("ERROR: NUM_PERIPHERALS must be >= 1");
            $finish;
        end
    end

    // --------- Internal signals ----------
    wire [ADDR_SEL_WIDTH-1:0] peripheral_sel;
    wire                       valid_peripheral;

    reg  [DATA_WIDTH-1:0]      dat_mux;
    reg                        ack_mux;
    reg                        err_mux;

    // --- 1. Address Decoding ---
    assign peripheral_sel  = m_wb_adr_i[ADDR_SEL_HIGH_BIT : ADDR_SEL_LOW_BIT];
    assign valid_peripheral = (peripheral_sel < NUM_PERIPHERALS);

    // --- 2. Master-to-Slave Demultiplexing ---
    genvar g;
    generate
        for (g = 0; g < NUM_PERIPHERALS; g = g + 1) begin : gen_slave_signals
            // CYC is broadcast
            assign s_wb_cyc_o[g] = m_wb_cyc_i;

            // STB is gated to the selected peripheral only
            assign s_wb_stb_o[g] = m_wb_stb_i && valid_peripheral && (peripheral_sel == g[ADDR_SEL_WIDTH-1:0]);

            // Broadcast the rest (slaves ignore if STB is low)
            assign s_wb_we_o[g] = m_wb_we_i;

            assign s_wb_sel_o[(g+1)*SEL_WIDTH-1 : g*SEL_WIDTH]   = m_wb_sel_i;
            assign s_wb_adr_o[(g+1)*ADDR_WIDTH-1 : g*ADDR_WIDTH] = m_wb_adr_i;
            assign s_wb_dat_o[(g+1)*DATA_WIDTH-1 : g*DATA_WIDTH] = m_wb_dat_i;
        end
    endgenerate

    // --- 3. Slave-to-Master Multiplexing ---
    always @* begin
        integer sel_shift;
        reg [NUM_PERIPHERALS*DATA_WIDTH-1:0] dat_shifted;

        // Defaults (idle or invalid access)
        dat_mux = DEBUG_WORD;
        ack_mux = 1'b0;
        err_mux = 1'b0;

        if (valid_peripheral) begin
            sel_shift  = peripheral_sel * DATA_WIDTH;
            dat_shifted = s_wb_dat_i >> sel_shift;
            dat_mux    = dat_shifted[DATA_WIDTH-1:0];

            ack_mux    = s_wb_ack_i[peripheral_sel];
            err_mux    = s_wb_err_i[peripheral_sel];
        end
        else if (m_wb_stb_i && m_wb_cyc_i) begin
            // Invalid address -> error response (ACK and ERR mutually exclusive)
            ack_mux = 1'b0;
            err_mux = 1'b1;
        end
    end

    assign m_wb_dat_o = dat_mux;
    assign m_wb_ack_o = ack_mux;
    assign m_wb_err_o = err_mux;

endmodule
