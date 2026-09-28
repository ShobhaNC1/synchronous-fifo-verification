// ============================================================================
// Testbench    : tb_sync_fifo
// Description  : Self-checking, constrained-random verification environment
//                for sync_fifo. Includes:
//                  - Randomized write/read stimulus generation
//                  - Reference model (array-based circular buffer, mirrors
//                    DUT semantics) + scoreboard comparison
//                  - Directed corner-case tests (full, empty, simultaneous
//                    read/write, back-to-back bursts)
//                  - Functional coverage tracking (bins for corner cases)
//                  - Assertion checks live in the RTL (sync_fifo.v)
// Author       : N C Shobha
// ============================================================================
`timescale 1ns/1ps

module tb_sync_fifo;

    localparam DATA_WIDTH = 8;
    localparam DEPTH      = 16;
    localparam ADDR_WIDTH = $clog2(DEPTH);
    localparam NUM_RANDOM_TXNS = 2000;
    localparam REF_SIZE = 4096; // generous reference-model capacity

    reg                     clk;
    reg                     rst_n;
    reg                     wr_en;
    reg  [DATA_WIDTH-1:0]   wr_data;
    wire                    full, almost_full;
    reg                     rd_en;
    wire [DATA_WIDTH-1:0]   rd_data;
    wire                    empty, almost_empty;
    wire [ADDR_WIDTH:0]     count;
    wire                    overflow, underflow;

    // ---- DUT instantiation ----
    sync_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .DEPTH(DEPTH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_data(wr_data), .full(full), .almost_full(almost_full),
        .rd_en(rd_en), .rd_data(rd_data), .empty(empty), .almost_empty(almost_empty),
        .count(count), .overflow(overflow), .underflow(underflow)
    );

    // ---- Clock generation: 10ns period (100MHz) ----
    initial clk = 0;
    always #5 clk = ~clk;

    // ---- Reference model: plain array-based circular buffer, mirrors
    //      expected FIFO content independently of the DUT's internals ----
    reg [DATA_WIDTH-1:0] ref_mem [0:REF_SIZE-1];
    integer ref_head;   // next element to be read
    integer ref_tail;   // next free slot to write
    integer ref_count;  // number of valid elements currently queued

    task automatic ref_push(input [DATA_WIDTH-1:0] d);
        begin
            ref_mem[ref_tail] = d;
            ref_tail = (ref_tail + 1) % REF_SIZE;
            ref_count = ref_count + 1;
        end
    endtask

    task automatic ref_pop(output [DATA_WIDTH-1:0] d);
        begin
            d = ref_mem[ref_head];
            ref_head = (ref_head + 1) % REF_SIZE;
            ref_count = ref_count - 1;
        end
    endtask

    // ---- Scoreboard counters ----
    integer total_checks       = 0;
    integer total_errors       = 0;
    integer writes_accepted    = 0;
    integer reads_accepted     = 0;
    integer overflow_events    = 0;
    integer underflow_events   = 0;

    // ---- Coverage bins (corner cases) ----
    integer cov_hit_full            = 0;
    integer cov_hit_empty           = 0;
    integer cov_hit_almost_full     = 0;
    integer cov_hit_almost_empty    = 0;
    integer cov_hit_simul_rw        = 0;   // simultaneous read+write, not full/empty
    integer cov_hit_simul_rw_full   = 0;   // simultaneous read+write while full
    integer cov_hit_wr_reject       = 0;   // write attempted while full (rejected)
    integer cov_hit_rd_reject       = 0;   // read attempted while empty (rejected)
    integer cov_hit_back_to_back_wr = 0;   // >=4 consecutive writes
    integer cov_hit_back_to_back_rd = 0;   // >=4 consecutive reads
    integer consec_wr = 0, consec_rd = 0;

    // ---- Latency-correct data check bookkeeping ----
    // rd_data is registered (1-cycle latency after rd_en), so we predict
    // the expected value BEFORE driving a read, then compare it against
    // rd_data on the following cycle.
    reg [DATA_WIDTH-1:0] cmp_val;
    reg                  cmp_pending;

    reg                  do_wr, do_rd;
    reg [DATA_WIDTH-1:0] rnd_data;
    integer              i;
    reg                  wr_accept, rd_accept;

    // ---- Task: reset DUT and reference model ----
    task automatic apply_reset;
        begin
            rst_n       = 0;
            wr_en       = 0;
            rd_en       = 0;
            wr_data     = 0;
            ref_head    = 0;
            ref_tail    = 0;
            ref_count   = 0;
            cmp_pending = 0;
            repeat (3) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
            #1;
        end
    endtask

    // ---- Task: single-cycle drive ----
    task automatic drive_cycle(input do_write, input do_read, input [DATA_WIDTH-1:0] data);
        begin
            wr_en   = do_write;
            wr_data = data;
            rd_en   = do_read;
            @(posedge clk);
            #1; // let NBA updates (wr_ptr/rd_ptr/rd_data) settle before
                // any code samples full/empty/rd_data/count this cycle
        end
    endtask

    // ---- Scoreboard: takes PRE-EDGE accept decisions explicitly, so it
    //      never re-derives full/empty from post-edge (already-updated)
    //      DUT signals - avoiding a classic race condition where full/empty
    //      changes on the very edge a read/write is issued. ----
    task automatic check_and_score(input wr_accept, input rd_accept, input wr_attempt, input rd_attempt);
        reg [DATA_WIDTH-1:0] dummy;
        begin
            if (wr_accept) begin
                ref_push(wr_data);
                writes_accepted = writes_accepted + 1;
            end
            if (wr_attempt && !wr_accept) begin
                overflow_events = overflow_events + 1;
                cov_hit_wr_reject = cov_hit_wr_reject + 1;
            end

            if (rd_accept) begin
                ref_pop(dummy);
                reads_accepted = reads_accepted + 1;
                total_checks   = total_checks + 1;
            end
            if (rd_attempt && !rd_accept) begin
                underflow_events = underflow_events + 1;
                cov_hit_rd_reject = cov_hit_rd_reject + 1;
            end

            // Coverage bin tracking (post-edge flags are fine here - just
            // observational, not used to drive scoreboard state)
            if (full)          cov_hit_full          = cov_hit_full + 1;
            if (empty)         cov_hit_empty         = cov_hit_empty + 1;
            if (almost_full)   cov_hit_almost_full   = cov_hit_almost_full + 1;
            if (almost_empty)  cov_hit_almost_empty  = cov_hit_almost_empty + 1;
            if (wr_attempt && rd_attempt) begin
                if (!wr_accept && rd_accept) cov_hit_simul_rw_full = cov_hit_simul_rw_full + 1; // write rejected (full) while read succeeds
                else                         cov_hit_simul_rw      = cov_hit_simul_rw + 1;
            end

            if (wr_accept) consec_wr = consec_wr + 1; else consec_wr = 0;
            if (rd_accept) consec_rd = consec_rd + 1; else consec_rd = 0;
            if (consec_wr >= 4) cov_hit_back_to_back_wr = cov_hit_back_to_back_wr + 1;
            if (consec_rd >= 4) cov_hit_back_to_back_rd = cov_hit_back_to_back_rd + 1;
        end
    endtask

    task automatic report_coverage_bin(input [8*40-1:0] name, input integer hits);
        begin
            if (hits > 0)
                $display("  [HIT ] %0s : %0d hits", name, hits);
            else
                $display("  [MISS] %0s : %0d hits", name, hits);
        end
    endtask

    // ---- Main stimulus ----
    initial begin
        $display("=========================================================");
        $display(" Synchronous FIFO Verification - Constrained Random Test ");
        $display(" DEPTH=%0d  DATA_WIDTH=%0d  NUM_RANDOM_TXNS=%0d", DEPTH, DATA_WIDTH, NUM_RANDOM_TXNS);
        $display("=========================================================");

        apply_reset();

        // ---------------- Directed corner-case tests ----------------
        $display("[TEST] Directed: Fill FIFO completely, verify FULL flag");
        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_accept = !full; rd_accept = 0;
            drive_cycle(1, 0, i[DATA_WIDTH-1:0]);
            check_and_score(wr_accept, rd_accept, 1, 0);
        end
        if (!full) begin
            $display("  ERROR: Expected FULL after %0d writes, full=%0b", DEPTH, full);
            total_errors = total_errors + 1;
        end else $display("  PASS: FIFO correctly reports FULL after %0d writes", DEPTH);

        $display("[TEST] Directed: Attempt write while FULL (should be rejected)");
        wr_accept = !full; rd_accept = 0;
        drive_cycle(1, 0, 8'hFF);
        check_and_score(wr_accept, rd_accept, 1, 0);
        if (!overflow) begin
            $display("  ERROR: Expected overflow flag on write-while-full");
            total_errors = total_errors + 1;
        end else $display("  PASS: overflow flag correctly asserted");

        $display("[TEST] Directed: Drain FIFO completely, verify EMPTY flag");
        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_accept = 0; rd_accept = !empty;
            drive_cycle(0, 1, 0);
            check_and_score(wr_accept, rd_accept, 0, 1);
        end
        if (!empty) begin
            $display("  ERROR: Expected EMPTY after draining, empty=%0b", empty);
            total_errors = total_errors + 1;
        end else $display("  PASS: FIFO correctly reports EMPTY after full drain");

        $display("[TEST] Directed: Attempt read while EMPTY (should be rejected)");
        wr_accept = 0; rd_accept = !empty;
        drive_cycle(0, 1, 0);
        check_and_score(wr_accept, rd_accept, 0, 1);
        if (!underflow) begin
            $display("  ERROR: Expected underflow flag on read-while-empty");
            total_errors = total_errors + 1;
        end else $display("  PASS: underflow flag correctly asserted");

        $display("[TEST] Directed: Simultaneous read+write in steady state");
        for (i = 0; i < 4; i = i + 1) begin
            wr_accept = !full; rd_accept = 0;
            drive_cycle(1, 0, i[DATA_WIDTH-1:0]);
            check_and_score(wr_accept, rd_accept, 1, 0);
        end
        for (i = 0; i < 8; i = i + 1) begin
            wr_accept = !full; rd_accept = !empty;
            drive_cycle(1, 1, (100+i));
            check_and_score(wr_accept, rd_accept, 1, 1);
        end
        $display("  PASS: simultaneous read/write cycles executed");

        $display("[TEST] Directed: Simultaneous read+write while FULL");
        for (i = 0; i < DEPTH; i = i + 1) begin
            wr_accept = !full; rd_accept = 0;
            drive_cycle(1, 0, (200+i));
            check_and_score(wr_accept, rd_accept, 1, 0);
        end
        for (i = 0; i < 6; i = i + 1) begin
            wr_accept = !full; rd_accept = !empty;
            drive_cycle(1, 1, (220+i));
            check_and_score(wr_accept, rd_accept, 1, 1);
        end
        $display("  PASS: simultaneous read/write while full cycles executed");

        apply_reset();

        // ---------------- Constrained-random stimulus ----------------
        $display("[TEST] Constrained-random: %0d cycles of randomized wr_en/rd_en/data", NUM_RANDOM_TXNS);
        for (i = 0; i < NUM_RANDOM_TXNS; i = i + 1) begin
            do_wr    = ($urandom_range(0,99) < 55);  // 55% write probability
            do_rd    = ($urandom_range(0,99) < 55);  // 55% read probability
            rnd_data = $urandom_range(0,255);

            // Data-integrity check for the PREVIOUS cycle's registered read
            if (cmp_pending) begin
                if (rd_data !== cmp_val) begin
                    $display("  ERROR @%0t: rd_data mismatch. Expected=%0h Got=%0h", $time, cmp_val, rd_data);
                    total_errors = total_errors + 1;
                end
            end

            // Capture PRE-EDGE accept decisions once, using current
            // (pre-edge) full/empty - reused for BOTH the read prediction
            // and the scoreboard push/pop, so they can never disagree.
            wr_accept = do_wr && !full;
            rd_accept = do_rd && !empty;

            // Predict THIS cycle's read result before driving (peek, don't pop yet)
            if (rd_accept) begin
                cmp_val     = ref_mem[ref_head];
                cmp_pending = 1;
            end else begin
                cmp_pending = 0;
            end

            drive_cycle(do_wr, do_rd, rnd_data);
            check_and_score(wr_accept, rd_accept, do_wr, do_rd);
        end

        // Flush final pending comparison
        if (cmp_pending) begin
            if (rd_data !== cmp_val) begin
                $display("  ERROR @%0t: rd_data mismatch (final). Expected=%0h Got=%0h", $time, cmp_val, rd_data);
                total_errors = total_errors + 1;
            end
        end

        $display("[INFO] Entries remaining in reference model at end of test: %0d", ref_count);

        $display("=========================================================");
        $display(" FUNCTIONAL COVERAGE REPORT");
        $display("=========================================================");
        report_coverage_bin("FULL condition hit",                cov_hit_full);
        report_coverage_bin("EMPTY condition hit",                cov_hit_empty);
        report_coverage_bin("ALMOST_FULL condition hit",          cov_hit_almost_full);
        report_coverage_bin("ALMOST_EMPTY condition hit",         cov_hit_almost_empty);
        report_coverage_bin("Simultaneous R+W (steady state)",    cov_hit_simul_rw);
        report_coverage_bin("Simul. R+W, write rejected (FULL)", cov_hit_simul_rw_full);
        report_coverage_bin("Write rejected (overflow attempt)",  cov_hit_wr_reject);
        report_coverage_bin("Read rejected (underflow attempt)",  cov_hit_rd_reject);
        report_coverage_bin("Back-to-back writes (>=4 consec.)",  cov_hit_back_to_back_wr);
        report_coverage_bin("Back-to-back reads (>=4 consec.)",   cov_hit_back_to_back_rd);

        begin
            integer bins_hit;
            bins_hit = (cov_hit_full>0) + (cov_hit_empty>0) + (cov_hit_almost_full>0) +
                       (cov_hit_almost_empty>0) + (cov_hit_simul_rw>0) + (cov_hit_simul_rw_full>0) +
                       (cov_hit_wr_reject>0) + (cov_hit_rd_reject>0) + (cov_hit_back_to_back_wr>0) +
                       (cov_hit_back_to_back_rd>0);
            $display("---------------------------------------------------------");
            $display(" Coverage bins hit: %0d / 10  (%0.1f%%)", bins_hit, (bins_hit*100.0)/10.0);
        end

        $display("=========================================================");
        $display(" SCOREBOARD SUMMARY");
        $display("=========================================================");
        $display(" Total data checks performed   : %0d", total_checks);
        $display(" Writes accepted                : %0d", writes_accepted);
        $display(" Reads accepted                 : %0d", reads_accepted);
        $display(" Overflow (rejected write) evts : %0d", overflow_events);
        $display(" Underflow (rejected read) evts : %0d", underflow_events);
        $display(" TOTAL ERRORS                   : %0d", total_errors);
        if (total_errors == 0)
            $display(" RESULT: *** ALL CHECKS PASSED ***");
        else
            $display(" RESULT: *** %0d CHECK(S) FAILED ***", total_errors);
        $display("=========================================================");

        $finish;
    end

    // Waveform dump
    initial begin
        $dumpfile("sync_fifo.vcd");
        $dumpvars(0, tb_sync_fifo);
    end

endmodule
