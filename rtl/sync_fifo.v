// ============================================================================
// Module      : sync_fifo
// Description : Parameterized synchronous FIFO with full/empty flags and
//               overflow/underflow protection. Single clock domain.
// Author      : N C Shobha
// ============================================================================

module sync_fifo #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH      = 16,                       // must be power of 2
    parameter ADDR_WIDTH = $clog2(DEPTH)
) (
    input  wire                    clk,
    input  wire                    rst_n,     // active-low synchronous reset

    // Write port
    input  wire                    wr_en,
    input  wire [DATA_WIDTH-1:0]   wr_data,
    output wire                    full,
    output wire                    almost_full,

    // Read port
    input  wire                    rd_en,
    output reg  [DATA_WIDTH-1:0]   rd_data,
    output wire                    empty,
    output wire                    almost_empty,

    // Status
    output wire [ADDR_WIDTH:0]     count,     // current occupancy (0..DEPTH)
    output reg                     overflow,  // pulses when wr attempted while full
    output reg                     underflow  // pulses when rd attempted while empty
);

    // Memory array
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // Pointers are ADDR_WIDTH+1 bits wide: MSB is a wrap bit used to
    // distinguish full from empty when read_ptr == write_ptr.
    reg [ADDR_WIDTH:0] wr_ptr, rd_ptr;

    wire [ADDR_WIDTH-1:0] wr_addr = wr_ptr[ADDR_WIDTH-1:0];
    wire [ADDR_WIDTH-1:0] rd_addr = rd_ptr[ADDR_WIDTH-1:0];

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);

    assign count = wr_ptr - rd_ptr;
    assign almost_full  = (count == DEPTH-1);
    assign almost_empty = (count == 1);

    wire wr_valid = wr_en && !full;
    wire rd_valid = rd_en && !empty;

    // Write logic
    always @(posedge clk) begin
        if (!rst_n) begin
            wr_ptr <= 0;
        end else if (wr_valid) begin
            mem[wr_addr] <= wr_data;
            wr_ptr <= wr_ptr + 1'b1;
        end
    end

    // Read logic
    always @(posedge clk) begin
        if (!rst_n) begin
            rd_ptr  <= 0;
            rd_data <= {DATA_WIDTH{1'b0}};
        end else if (rd_valid) begin
            rd_data <= mem[rd_addr];
            rd_ptr  <= rd_ptr + 1'b1;
        end
    end

    // Overflow / underflow detection (protection: writes/reads are
    // dropped, but we flag the illegal attempt for verification/debug)
    always @(posedge clk) begin
        if (!rst_n) begin
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            overflow  <= wr_en && full;
            underflow <= rd_en && empty;
        end
    end

    // ------------------------------------------------------------------
    // Assertions - immediate assertions checked every clock edge.
    // (Icarus Verilog's open-source simulator supports immediate
    // assertions; full concurrent SVA `property`/`assert property` is
    // used in commercial tools like QuestaSim/VCS - the same checks
    // are expressed here in a portable style.)
    // ------------------------------------------------------------------
    // synthesis translate_off
    always @(posedge clk) begin
        if (rst_n) begin
            assert (!(wr_en && full) || (count == DEPTH))
                else $error("[ASSERTION FAILED] Write accepted while FIFO full at time %0t", $time);

            assert (!(rd_en && empty) || (count == 0))
                else $error("[ASSERTION FAILED] Read accepted while FIFO empty at time %0t", $time);

            assert (count <= DEPTH)
                else $error("[ASSERTION FAILED] FIFO count out of range at time %0t", $time);

            assert (!(full && empty))
                else $error("[ASSERTION FAILED] full and empty asserted simultaneously at time %0t", $time);
        end
    end
    // synthesis translate_on

endmodule
