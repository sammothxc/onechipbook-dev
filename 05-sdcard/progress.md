# OneChipBook-12 FPGA Project

This is a from-scratch SoC project on a OneChipBook-12, an FPGA-based laptop with an Altera Cyclone I (EP1C12Q240C8N), 32MB SDRAM, repurposed iPad LCD, PS/2 keyboard, SD card, and audio. The end goal is a complete homebrew computer — custom CPU, custom peripherals, running software the user writes — built up incrementally on real hardware.

The user is a BYU student (IT&C and ECEN coursework) with a strong homelab and vintage computing background. They've taken one FPGA class (ECEN 320), where they used SystemVerilog on Vivado/Artix-7. This project is their first time using Verilog-2001, Quartus, and Altera's ecosystem.

## Hardware quick reference

**FPGA:** Cyclone EP1C12Q240C8N — 12,060 LEs, 239,616 bits block RAM, 2 PLLs, 240-pin PQFP
**Crystal:** 21.47727 MHz on CLK0 (NTSC color subcarrier × 6) — pin documented in manual
**Display:** Built-in iPad LCD, native 1024×768. Driven via VGA-style RGB+sync from FPGA. Behind a scaler chip with a preset list (preset 9 = 640×480, preset 19 = 800×600, preset 30 = 1024×768).
**Memory:** 32MB SDRAM, K4S561632E equivalent (16-bit data, 4 banks, 13-bit row × 9-bit col)
**Keyboard:** PS/2 protocol, CLK on pin 68, DATA on pin 67. MCU between physical keys and FPGA generates standard Set 2 PS/2 codes.
**Audio:** Dual 6-bit DACs. **Right channel SR0–SR5: pins 115–120 (contiguous). Left channel SL0–SL3: pins 105–108; SL4, SL5: pins 113, 114 (split — pins 109–112 are something else).**
**LEDs:** 8 user LEDs (pins 43–50), one extra (pin 240)
**DIP switches:** 8 total. **Numbering on physical switches starts at 1 but in schematic at 0**, so physical SW1 = schematic DIP0 = pin 53. Always confirm by referring to manual's pin assignment table.
**SD card:** Pins 61–66 (SPI/SDIO compatible)
**Programming:** Active Serial Programming (NOT JTAG). Uses .pof files. The board's USB-Blaster header is wired to the EPCS configuration EEPROM, not to FPGA JTAG.

The user has the full English Technical Reference manual (PDF) and has done extensive personal exploration of the schematic.

## Toolchain context

**Quartus II 11.0 Web Edition** is the development environment. Cyclone I support was dropped in newer Quartus versions, so this old version is required. Toolchain runs in:
- A Windows 10 VM (KVM/virt-manager on Debian 13 host) at home — the primary dev setup
- A Windows 11 work PC, where the user got it working by borrowing Quartus 13's bin64 jtagserver to bypass a 32-bit/64-bit issue

The home setup uses a virtiofs share between Debian and the VM so the user can edit on Linux and synthesize in Windows. Project files live on the Linux side; Quartus reads them through the share.

**Programming workflow:**
- Active Serial mode (NOT JTAG — Cyclone I officially doesn't support AS, but it works on this board)
- Generate `.pof`, not just `.sof`
- Configuration device EPCS is set in: Assignments → Device → Device and Pin Options → Configuration → EPCS4
- Save a `.cdf` file in the Programmer to remember settings between sessions

**Always remember:** Set "Reserve all unused pins" to "As input tri-stated" (Assignments → Device → Device and Pin Options → Unused Pins). Default is "as output driving ground" which is dangerous on this board where most pins are wired to peripherals.

## Verilog conventions used so far

- **Verilog-2001**, NOT SystemVerilog. No `logic`, no `always_ff`/`always_comb`, no interfaces, no typedefs. Use `wire` and `reg` explicitly. Keep this in mind — the user's instinct from coursework is SV.
- **Localparams for all magic numbers** (timing parameters, addresses, etc.)
- **Synchronous reset** on the resets that exist; some modules don't take reset (timing module does, renderer doesn't because it self-initializes)
- **Pipelined output for high-speed paths** — display logic registers its outputs because it runs at the pixel clock
- **All async inputs go through 2-flop synchronizers** before use (PS/2 receiver demonstrates this)

## Audio subsystem design notes

- **DDS (NCO) tone generation:** 32-bit phase accumulator clocked at the system clock. Frequency tuning word (FTW) determines output frequency: `freq = fclk × FTW / 2^32`. With `fclk = 21.47727 MHz`, FTW resolution is ~5 mHz — far below 1 cent of musical pitch detuning.
- **DAC update rate = system clock rate (21.47727 MHz).** Audio post-stage on the board acts as a natural low-pass filter; no explicit sample-rate divider needed for clean tones in the audible band.
- **Three wave shapes mapped to QWERTY rows:**
  - Top row (Q W E R T Y U I O P) → sawtooth (top bits of phase accumulator)
  - Home row (A S D F G H J K L ;) → sine (256-entry × 6-bit LUT)
  - Bottom row (Z X C V B N M , . /) → square (MSB of phase accumulator)
- **Pentatonic C major across each row** — 2 octaves: C4 D4 E4 G4 A4 C5 D5 E5 G5 A5.
- **Monophonic.** Most-recent-key-down wins. Polyphony deferred (would need multiple oscillators + mixer).

## Hard-won lessons (please respect these)

- **FPGA IO is often labelled incorrectly or confusin.** Always have user double check with the manual's pin assignment table when assigning any IO in general.
- **Active Serial programming works for Cyclone I on this board** despite Quartus officially saying it shouldn't. JTAG mode does NOT work — the board's programming header is wired to the EPCS configuration EEPROM, not to the FPGA's JTAG pins.
- **Sync polarity is active-low for ALL resolutions on this board's scaler**, even though SVGA/XGA specs say positive. Don't trust the spec; trust the working measurement. (Video-only — keep noted for future projects.)
- **PLL ratios are tight on Cyclone I.** Cyclone PLLs use small integer M/N ratios with VCO range constraints. Don't expect arbitrary frequencies. The MegaWizard will report what it actually achieved — believe it, not what you asked for.
- **The crystal is 21.47727 MHz, not 21 MHz.** Use 46.561 ns period in SDC files.
- **Quartus default constant-loop iteration limit is 5000.** For inferred RAM init loops larger than that (e.g., text buffer 8192 entries), bump via `set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 10000` in the QSF.

## How to help going forward

- The user has solid digital logic fundamentals from ECEN 320 but is new to Verilog-2001 specifics (vs SystemVerilog) and Altera's tools (vs Xilinx). They learn fast and appreciate explanation of *why* something works, not just the mechanics.
- They appreciate getting concrete code that works on first compile, with clear comments explaining the structure. They'll iterate from there.
- They like understanding tradeoffs and second-order consequences ("if I change X, what does it cost in resources / timing / complexity later?"). Surface these proactively when relevant.
- Stage things into small verifiable wins. They've been burned by hours of debugging where bugs in multiple subsystems entangle. One thing at a time, on real hardware, before stacking the next thing.
- They want to do this project the right way — clean code, version-controlled, well-documented. Suggest good practices when natural; don't lecture.

## SD card pin mapping (confirmed from manual)

| Signal  | Manual name | FPGA pin | SPI role         |
|---------|-------------|----------|------------------|
| sd_clk  | CK          | PIN_63   | SCLK             |
| sd_mosi | CM          | PIN_64   | CMD / DI         |
| sd_miso | D0          | PIN_62   | DAT0 / DO        |
| sd_cs_n | D3          | PIN_65   | chip select (AL) |

Pins D1 (61) and D2 (66) unused in SPI mode — tri-stated by global unused-pin setting.

## 05-sdcard completed stages

- **Stage D:** Multi-sector boot loader. `sd_ctrl.v` extended with a `sector_idx [4:0]` counter and `BOOT_SECTORS=32` localparam; after each CMD17 completes the FSM re-issues CMD17 for the next sector (incrementing `sector_idx`) until all 32 are loaded. `buf_addr` widened to 14 bits (`{sector_idx, data_idx[8:0]}`). BRAM in top-level widened to 16 KB (`reg [7:0] block_mem [0:16383]`). `hex_dump.v` gains a `page_sel [4:0]` input that prepends to `rd_addr`, selecting which 512-byte page to show. DIP3–DIP7 (PIN_56–60) drive `page_sel_in`; 2-flop synchronizer on pixel_clk prevents metastability. During load, LEDs show `{state[3:0], sector_idx[3:0]}` so you can watch the sector counter increment 0→1F. CPU bringup: just expose `block_mem` read port to the CPU's fetch bus — SD side unchanged.

- **Stage B:** SPI master (Mode 0, runtime `clk_div` — 32 for ~336 kHz init, 2 for ~5.4 MHz run) → `sd_ctrl.v` init FSM (CMD0 → CMD8 → CMD55+ACMD41 loop → CMD58 for v2/SDHC detection → CMD17 sector-0 read) → 512×8 dual-clock dual-port inferred BRAM → `hex_dump.v` (16-row × 32-byte grid, 4-char offset prefix, white-on-black, centered at (240, 256) on 1024×768, 3-stage pipeline through BRAM + char_rom). LEDs show `0xAA/0x55` alternating on success, `err_dbg` byte on error. Tested on hardware — sector-0 hex dump displayed correctly, MBR magic bytes `55 AA` visible at end of row 15.
  - Quartus 11 SDC `get_clocks` takes a positional glob, not a `-filter` flag. False-path to the PLL-derived clock must use the exact derived name: `vga65mhz_pll:pll_inst|altpll:altpll_component|_clk0`.
  - Dual-clock BRAM inferred from two `always @(posedge clk)` blocks on different clocks sharing the same `reg` array. Quartus warns about "undefined read-during-write behavior" — benign when write phase ends before display begins.
  - `sdhc` flag from CMD58 OCR bit 30 (CCS) wired into CMD17 address calculation (`rd_arg = sdhc ? sector : sector << 9`). For sector 0 both are zero; flag matters for Stage D non-zero sectors.

## Things that DON'T work, don't try them again

- JTAG programming on this board — physically not connected to FPGA JTAG pins
- Standard SVGA active-high sync — the scaler rejects it on this board
- PLLs targeting frequencies that need M/N ratios outside Cyclone I's range — accept the closest achievable
- Quartus newer than 13.0sp1 for Cyclone I — device support dropped

## 03-keyboard completed stages

- **Stage A:** PS/2 byte receiver (`ps2_rx.v`). 2-flop sync, falling edge detect, 11-bit frame shift register, odd parity check, `data_valid` pulse. Last received scan code shown on 8 LEDs. Tested on hardware.
- **Stage B:** `hex_display.v` renders last received scan code as 2 hex characters at center of 1024×768 display. Uses `vga65mhz_pll` (64.43 MHz), XGA timing, same `char_rom` as 02-video. Tested on hardware.
- **Stage C:** `sc_parser.v` strips 0xE0 (extended) and 0xF0 (release) prefixes, emits key-down/key-up events.
- **Stage D:** Scan code → ASCII translation with shift-state tracking inside `sc_parser.v`. Emits `ascii` + `ascii_valid` for printable keys, plus 0x0D (Enter) and 0x08 (Backspace).
- **Stage E:** `text_buf.v` (8192×8 inferred dual-port M4K RAM, init 0x20), `terminal.v` (4-cycle pixel pipeline reading from buffer), cursor controller in `keyboard.v`. Keystrokes write into the buffer and advance the cursor; Enter wraps to next row, Backspace erases. **Working text terminal on hardware.**
  - text_buf init loop (8192 iters) exceeded Quartus's default constant-loop limit of 5000; bumped via `set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 10000` in `keyboard.qsf`.
  - Synthesizer optimizes away 2 of 16 M4K blocks because bit 7 of `rd_data` is never read in `terminal.v` (only `rd_data[6:0]`) and `wr_data` is always < 0x80 → bit-7 storage is provably constant. Benign; 14 M4Ks used. Restore by widening `char_rom_addr` to 12 bits if extended ASCII is ever needed.

## 04-audio completed stages

- **Stage A:** Fixed 440 Hz square wave on both DAC channels. `tone_gen.v` (32-bit DDS), `audio.v` (top), DIP0 mute switch. Tested on hardware — startled the user with full swing; default `HI`/`LO` reduced to 0x22/0x1D (~8% amp).
- **Stage B:** PS/2 keyboard piano. `ps2_rx.v` (copied from 03-keyboard) → `key_decoder.v` (E0/F0 prefix stripping) → `key_to_note.v` (30-key combinational LUT, pentatonic C major × 2 octaves) → monophonic note state in `audio.v` → `tone_gen.v` rewritten with sine LUT + saw + square + uniform attenuator. Top row = saw, home = sine, bottom = square. `AMP_SHIFT` localparam controls volume; default 3 (8 effective DAC levels). Tested on hardware.
  - Sine LUT generated by inline Python (`sine_lut.hex`, 256 × 8-bit storage with low 6 bits used). Storage widened to 8-bit purely to silence `$readmemh` truncation warnings.
  - Quartus eliminates 5 of 8 inferred M4Ks for `sine_lut`: bits 6/7 because we read only `[5:0]`, bits 0/1/2 because the `>>>3` attenuator drops them. Correct optimization; left as-is. Lower `AMP_SHIFT` to recover more bits + more volume.
- **Stage C:** On-screen note + frequency + wave display. Brought in video stack from 03-keyboard (`vga65mhz_pll`, `timing`, `char_rom`, `vga_8x16.mif`). New `freq_display.v` renders an 18-char string ("A4  440 Hz  sine  ") centered at (440, 376) on 1024×768. Pipeline mirrors `hex_display`. `key_to_note.v` extended with note_letter/octave + 3-digit BCD freq (rounded integer Hz, hardcoded per note). Display state latched in audio domain on every recognized key-down, held forever after (no clear on key-up = "last frequency stays" semantic). Cross-domain reads to pixel domain handled with `set_false_path` — brief inconsistency during transition is invisible at 60 Hz refresh. Tested on hardware.
