// SDRAM controller for K4S561632E (or equivalent).
// 16-bit data, 4 banks, 13-bit row, 9-bit col, 32MB total.
// Runs at 21.47727 MHz (46.5 ns cycle) — well within the chip's 10 ns limit.
//
// User-facing interface (synchronous to clk):
//   req      — assert for one cycle to start a transaction
//   we       — 1=write, 0=read
//   addr     — 25-bit byte address (A[24:1] = row/bank/col, A[0] ignored = 16-bit aligned)
//   wr_data  — data to write (16-bit)
//   wr_mask  — byte write enables, active-high (2 bits: [1]=upper, [0]=lower)
//   rd_data  — read result, valid when rd_valid pulses
//   rd_valid — one-cycle pulse when read data is ready
//   busy     — high while a transaction or refresh is in progress; hold req until !busy
//
// SDRAM command encoding (CS_N RAS_N CAS_N WE_N):
//   INHIBIT       1 1 1 1
//   NOP           0 1 1 1
//   ACTIVE        0 0 1 1
//   READ          0 1 0 1
//   WRITE         0 1 0 0
//   PRECHARGE     0 0 1 0
//   AUTO REFRESH  0 0 0 1
//   LOAD MODE     0 0 0 0
//
// Mode register value (CL=2, burst length=1, sequential):
//   A[2:0]=000 (burst 1), A[3]=0 (sequential), A[6:4]=010 (CL=2), A[8:7]=00 (std op)
//   = 13'b0_00_010_0_000 = 13'h020
//
// Timing parameters (all in clock cycles at 21.47727 MHz / 46.5 ns):
//   tRP  (precharge)   = 20 ns -> 1 cycle  (we wait 1 extra NOP = 2 total for safety)
//   tRCD (active->rw)  = 20 ns -> 1 cycle  (1 NOP between ACTIVE and READ/WRITE)
//   tRC  (row cycle)   = 65 ns -> 2 cycles
//   tRFC (auto-refresh)= 66 ns -> 2 cycles (we wait 2 NOPs after each AREF)
//   CAS latency        = 2 cycles
//   tREF               = 64ms / 8192 rows -> 7.81 us -> 167 cycles; we refresh every 160
module sdram_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // User interface
    input  wire        req,
    input  wire        we,
    input  wire [24:0] addr,
    input  wire [15:0] wr_data,
    input  wire  [1:0] wr_mask,
    output reg  [15:0] rd_data,
    output reg         rd_valid,
    output wire        busy,

    // SDRAM pins
    output reg         sdram_cke,
    output reg         sdram_cs_n,
    output reg         sdram_ras_n,
    output reg         sdram_cas_n,
    output reg         sdram_we_n,
    output reg   [1:0] sdram_ba,
    output reg  [12:0] sdram_a,
    output reg   [1:0] sdram_dqm,
    inout  wire [15:0] sdram_dq
);

    // ----------------------------------------------------------------
    //  Timing parameters (cycles at 21.47727 MHz)
    // ----------------------------------------------------------------
    // 200 us / 46.5 ns = 4301 cycles.  4302 > 2^12=4096, needs 13 bits.
    localparam INIT_CYCLES  = 13'd4302;
    localparam AREF_WAIT    = 3'd3;     // 3 NOPs after AUTO REFRESH (3*46.5=139ns > tRFC=66ns)
    localparam tRP_WAIT     = 2'd2;     // 2 NOPs after PRECHARGE   (2*46.5=93ns  > tRP=20ns)
    localparam tRCD_WAIT    = 2'd1;     // 1 NOP  after ACTIVE      (1*46.5=46.5ns > tRCD=20ns)
    localparam REFRESH_INT  = 9'd330;   // refresh every 330 cycles (~15.4us, well inside 7.8us*2)
    // Note: we issue one refresh per interval, which is one row every 15.4 us.
    // The spec allows up to 7.81 us per row — we're 2x conservative, which is fine.
    // If we need tighter throughput later, drop this to 160.

    localparam MODE_REG     = 13'h020;  // CL=2, BL=1, sequential

    // ----------------------------------------------------------------
    //  Address decomposition: addr[24:0] byte address, 16-bit aligned
    //   bank = addr[24:23]  (2 bits)
    //   row  = addr[22:10]  (13 bits)
    //   col  = addr[9:1]    (9 bits, addr[0] ignored)
    // ----------------------------------------------------------------
    wire  [1:0] a_bank = addr[24:23];
    wire [12:0] a_row  = addr[22:10];
    wire  [8:0] a_col  = addr[9:1];

    // ----------------------------------------------------------------
    //  DQ tristate control
    // ----------------------------------------------------------------
    reg        dq_oe;    // 1 = drive (write), 0 = tristate (read)
    reg [15:0] dq_out;

    assign sdram_dq = dq_oe ? dq_out : 16'hZZZZ;

    // ----------------------------------------------------------------
    //  FSM states
    // ----------------------------------------------------------------
    localparam S_INIT_WAIT  = 4'd0;   // counting 200 us power-on
    localparam S_INIT_PRE   = 4'd1;   // sending PRECHARGE ALL
    localparam S_INIT_PRE_W = 4'd2;   // waiting tRP
    localparam S_INIT_AREF  = 4'd3;   // sending init AUTO REFRESHes (8 of them)
    localparam S_INIT_AREF_W= 4'd4;   // waiting tRFC after each init AREF
    localparam S_INIT_MRS   = 4'd5;   // sending LOAD MODE REGISTER
    localparam S_INIT_MRS_W = 4'd6;   // 2 NOP cycles after MRS
    localparam S_IDLE       = 4'd7;   // ready, watching for req or refresh
    localparam S_AREF       = 4'd8;   // runtime AUTO REFRESH
    localparam S_AREF_W     = 4'd9;   // waiting tRFC after runtime AREF
    localparam S_ACTIVE     = 4'd10;  // sending ACTIVE
    localparam S_ACTIVE_W   = 4'd11;  // waiting tRCD
    localparam S_READ       = 4'd12;  // sending READ
    localparam S_READ_W     = 4'd13;  // waiting CAS latency + data capture
    localparam S_WRITE      = 4'd14;  // sending WRITE + data
    localparam S_PRE        = 4'd15;  // sending PRECHARGE (close row after access)

    reg  [3:0] state;
    reg [12:0] init_cnt;   // 200 us counter (needs 13 bits: 4302 > 2^12)
    reg  [2:0] wait_cnt;   // general short wait counter
    reg  [2:0] aref_init;  // counts 8 init auto-refreshes
    reg  [8:0] refresh_cnt;// counts down to next refresh
    reg        need_refresh;

    // Latch transaction parameters on req
    reg        latch_we;
    reg  [1:0] latch_bank;
    reg [12:0] latch_row;
    reg  [8:0] latch_col;
    reg [15:0] latch_wdata;
    reg  [1:0] latch_wmask;

    assign busy = (state != S_IDLE) || need_refresh;

    // ----------------------------------------------------------------
    //  Refresh interval counter (free-running once init done)
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            refresh_cnt  <= 9'd0;
            need_refresh <= 1'b0;
        end else begin
            if (state == S_AREF) begin
                need_refresh <= 1'b0;
                refresh_cnt  <= REFRESH_INT - 1'b1;
            end else if (refresh_cnt == 9'd0) begin
                // Only arm refresh once we're out of init — during init the
                // 8x AUTO REFRESH commands satisfy the chip's startup requirement.
                if (state == S_IDLE) begin
                    need_refresh <= 1'b1;
                end
                refresh_cnt <= REFRESH_INT - 1'b1;
            end else begin
                refresh_cnt <= refresh_cnt - 1'b1;
            end
        end
    end

    // ----------------------------------------------------------------
    //  Command helpers (combinational shortcuts)
    // ----------------------------------------------------------------
    // Applied each cycle to the output regs in the FSM below.
    // Not used as tasks (Verilog-2001 tasks with output regs are awkward);
    // just inline the four-bit patterns in the FSM cases.
    //   NOP:         cs=0 ras=1 cas=1 we=1
    //   PRECHARGE:   cs=0 ras=0 cas=1 we=0  a[10]=1 for ALL banks
    //   AUTO REFRESH:cs=0 ras=0 cas=0 we=1
    //   LOAD MODE:   cs=0 ras=0 cas=0 we=0
    //   ACTIVE:      cs=0 ras=0 cas=1 we=1
    //   READ:        cs=0 ras=1 cas=0 we=1  a[10]=1 for auto-precharge (we use it)
    //   WRITE:       cs=0 ras=1 cas=0 we=0  a[10]=1 for auto-precharge

    // ----------------------------------------------------------------
    //  Main FSM
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_INIT_WAIT;
            init_cnt   <= 13'd4302;
            wait_cnt   <= 3'd0;
            aref_init  <= 3'd0;
            sdram_cke  <= 1'b1;
            sdram_cs_n <= 1'b1;   // INHIBIT during init wait
            sdram_ras_n<= 1'b1;
            sdram_cas_n<= 1'b1;
            sdram_we_n <= 1'b1;
            sdram_ba   <= 2'd0;
            sdram_a    <= 13'd0;
            sdram_dqm  <= 2'b11;  // mask both bytes until we're ready
            dq_oe      <= 1'b0;
            dq_out     <= 16'd0;
            rd_data    <= 16'd0;
            rd_valid   <= 1'b0;
            latch_we   <= 1'b0;
            latch_bank <= 2'd0;
            latch_row  <= 13'd0;
            latch_col  <= 9'd0;
            latch_wdata<= 16'd0;
            latch_wmask<= 2'b11;
        end else begin
            // Default outputs each cycle (overridden below as needed)
            rd_valid    <= 1'b0;
            dq_oe       <= 1'b0;
            sdram_cke   <= 1'b1;   // always enabled after reset
            // NOP by default
            sdram_cs_n  <= 1'b0;
            sdram_ras_n <= 1'b1;
            sdram_cas_n <= 1'b1;
            sdram_we_n  <= 1'b1;
            sdram_dqm   <= 2'b11;

            case (state)

                // ---- Power-on: hold INHIBIT for 200 us ----
                S_INIT_WAIT: begin
                    sdram_cs_n <= 1'b1;   // INHIBIT (override NOP default)
                    if (init_cnt == 11'd0) begin
                        state <= S_INIT_PRE;
                    end else begin
                        init_cnt <= init_cnt - 1'b1;
                    end
                end

                // ---- PRECHARGE ALL ----
                S_INIT_PRE: begin
                    // PRECHARGE: cs=0 ras=0 cas=1 we=0, A10=1 (all banks)
                    sdram_ras_n <= 1'b0;
                    sdram_we_n  <= 1'b0;
                    sdram_a     <= 13'b0_0100_0000_0000;  // A10=1 (all banks)
                    wait_cnt    <= tRP_WAIT;
                    state       <= S_INIT_PRE_W;
                end

                S_INIT_PRE_W: begin
                    // NOP while tRP elapses
                    if (wait_cnt == 3'd0) begin
                        aref_init <= 3'd0;
                        state     <= S_INIT_AREF;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- 8× AUTO REFRESH ----
                S_INIT_AREF: begin
                    // AUTO REFRESH: cs=0 ras=0 cas=0 we=1
                    sdram_ras_n <= 1'b0;
                    sdram_cas_n <= 1'b0;
                    wait_cnt    <= AREF_WAIT;
                    state       <= S_INIT_AREF_W;
                end

                S_INIT_AREF_W: begin
                    if (wait_cnt == 3'd0) begin
                        if (aref_init == 3'd7) begin
                            state <= S_INIT_MRS;
                        end else begin
                            aref_init <= aref_init + 1'b1;
                            state     <= S_INIT_AREF;
                        end
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- LOAD MODE REGISTER ----
                S_INIT_MRS: begin
                    // LOAD MODE: cs=0 ras=0 cas=0 we=0
                    sdram_ras_n <= 1'b0;
                    sdram_cas_n <= 1'b0;
                    sdram_we_n  <= 1'b0;
                    sdram_ba    <= 2'b00;
                    sdram_a     <= MODE_REG;
                    wait_cnt    <= 3'd2;
                    state       <= S_INIT_MRS_W;
                end

                S_INIT_MRS_W: begin
                    if (wait_cnt == 3'd0) begin
                        state <= S_IDLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- IDLE: wait for request or refresh ----
                S_IDLE: begin
                    sdram_dqm <= 2'b11;
                    if (need_refresh) begin
                        state <= S_AREF;
                    end else if (req) begin
                        // Latch transaction
                        latch_we    <= we;
                        latch_bank  <= a_bank;
                        latch_row   <= a_row;
                        latch_col   <= a_col;
                        latch_wdata <= wr_data;
                        latch_wmask <= wr_mask;
                        state       <= S_ACTIVE;
                    end
                end

                // ---- Runtime AUTO REFRESH ----
                S_AREF: begin
                    sdram_ras_n <= 1'b0;
                    sdram_cas_n <= 1'b0;
                    wait_cnt    <= AREF_WAIT;
                    state       <= S_AREF_W;
                end

                S_AREF_W: begin
                    if (wait_cnt == 3'd0) begin
                        state <= S_IDLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- ACTIVE (open row) ----
                S_ACTIVE: begin
                    sdram_ras_n <= 1'b0;
                    sdram_ba    <= latch_bank;
                    sdram_a     <= latch_row;
                    wait_cnt    <= tRCD_WAIT;
                    state       <= S_ACTIVE_W;
                end

                S_ACTIVE_W: begin
                    if (wait_cnt == 3'd0) begin
                        state <= latch_we ? S_WRITE : S_READ;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- READ with auto-precharge ----
                S_READ: begin
                    // READ: cs=0 ras=1 cas=0 we=1, A10=1 (auto-precharge)
                    sdram_cas_n <= 1'b0;
                    sdram_ba    <= latch_bank;
                    sdram_a     <= {2'b00, 1'b1, 1'b0, latch_col};  // A10=1, A[8:0]=col
                    sdram_dqm   <= 2'b00;  // enable both bytes
                    // CL=2: data arrives 2 cycles after READ command.
                    // Cycle 0: READ issued (this cycle)
                    // Cycle 1: NOP, CAS latency 1
                    // Cycle 2: NOP, CAS latency 2
                    // Cycle 3: data valid on DQ — we sample it in S_READ_W
                    wait_cnt <= 3'd2;      // count down 2 NOPs, then sample
                    state    <= S_READ_W;
                end

                S_READ_W: begin
                    sdram_dqm <= 2'b00;   // keep unmasked during latency
                    if (wait_cnt == 3'd0) begin
                        // Data is valid this cycle — register it
                        rd_data  <= sdram_dq;
                        rd_valid <= 1'b1;
                        state    <= S_IDLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

                // ---- WRITE with auto-precharge ----
                S_WRITE: begin
                    // WRITE: cs=0 ras=1 cas=0 we=0, A10=1 (auto-precharge)
                    sdram_cas_n <= 1'b0;
                    sdram_we_n  <= 1'b0;
                    sdram_ba    <= latch_bank;
                    sdram_a     <= {2'b00, 1'b1, 1'b0, latch_col};  // A10=1
                    sdram_dqm   <= ~latch_wmask;  // DQM active-LOW masks; wmask active-HIGH enables
                    dq_oe       <= 1'b1;
                    dq_out      <= latch_wdata;
                    // Auto-precharge handles row close; tRP elapses during
                    // the write recovery + precharge time (>20 ns at 21 MHz).
                    // Wait 2 cycles (tWR=1 cycle min + 1 for tRP) before IDLE.
                    wait_cnt <= 3'd2;
                    state    <= S_PRE;
                end

                S_PRE: begin
                    // Drive data one more cycle (write recovery), then release
                    if (wait_cnt == 3'd1) begin
                        dq_oe  <= 1'b1;
                        dq_out <= latch_wdata;
                    end
                    if (wait_cnt == 3'd0) begin
                        state <= S_IDLE;
                    end else begin
                        wait_cnt <= wait_cnt - 1'b1;
                    end
                end

            endcase
        end
    end

endmodule
