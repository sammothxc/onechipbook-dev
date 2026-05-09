# OneChipBook-12 FPGA Project

This is a from-scratch SoC project on a OneChipBook-12, a Japanese FPGA-based laptop with an Altera Cyclone I (EP1C12Q240C8N), 32MB SDRAM, repurposed iPad LCD, PS/2 keyboard, SD card, and audio. The end goal is a complete homebrew computer — custom CPU, custom peripherals, running software the user writes — built up incrementally on real hardware.

The user is a BYU student (IT&C and ECEN coursework) with a strong homelab and vintage computing background. They've taken one FPGA class (ECEN 320), where they used SystemVerilog on Vivado/Artix-7. This project is their first time using Verilog-2001, Quartus, and Altera's ecosystem.

## Hardware quick reference

**FPGA:** Cyclone EP1C12Q240C8N — 12,060 LEs, 239,616 bits block RAM, 2 PLLs, 240-pin PQFP
**Crystal:** 21.47727 MHz on CLK0 (NTSC color subcarrier × 6) — pin documented in manual
**Display:** Built-in iPad LCD, native 1024×768. Driven via VGA-style RGB+sync from FPGA. Behind a scaler chip with a preset list (preset 9 = 640×480, preset 19 = 800×600, preset 30 = 1024×768).
**Memory:** 32MB SDRAM, K4S561632E equivalent (16-bit data, 4 banks, 13-bit row × 9-bit col)
**Keyboard:** PS/2 protocol, CLK on pin 68, DATA on pin 67. MCU between physical keys and FPGA generates standard Set 2 PS/2 codes.
**Audio:** Dual 6-bit DACs (R/L), pins 105–120
**LEDs:** 8 user LEDs (pins 43–50), one extra (pin 240)
**DIP switches:** 8 total. **Numbering on physical switches starts at 1 but in schematic at 0**, so physical SW1 = schematic DIP0 = pin 53. Always confirm by referring to manual's pin assignment table.
**SD card:** Pins 61–66 (SPI/SDIO compatible)
**Programming:** Active Serial Programming (NOT JTAG). Uses .pof files. The board's USB-Blaster header is wired to the EPCS configuration EEPROM, not to FPGA JTAG.

The user has the full English Technical Reference manual (PDF) and has done extensive personal exploration of the schematic (e.g., traced the scanline-generation circuit involving DIP1/DIP2 and 74HC74 flip-flops feeding TS5V330 muxes — they understand the analog video chain in depth).

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

## Current state of the design

Working modules (all compile, all tested on real hardware):

1. **`vga_pll.v`** — ALTPLL MegaWizard-generated. Currently configured for 64.43 MHz from 21.47727 MHz (3:1 multiply, the closest achievable ratio). Drives the pixel clock. Also outputs a `locked` signal that gates reset.

2. **`timing.v`** — VGA-style timing generator. Currently parameterized for 1024×768 @ ~59.4 Hz (XGA). Generates HSYNC, VSYNC, visible, pixel_x, pixel_y. **Sync is active-low for both HSYNC and VSYNC** — non-standard for SVGA/XGA spec but required by this board's scaler. The user verified this empirically. All outputs registered.

3. **`text_renderer.v`** — Pixel-rate character renderer. Computes which character cell each pixel is in, looks up the character from a hardcoded "Hello, World!" string, reads the character bitmap from a 2KB ROM, selects the right pixel. Two-stage pipeline: ROM read takes 1 cycle, output register adds another, so signals like `pixel_in_col`, `in_message`, `visible` are delayed by 2 cycles to align with ROM output.

4. **`char_rom.v`** — MegaWizard-generated 2048×8 ROM, initialized from `vga_8x16.mif`. Holds the IBM PC 8×16 VGA font for ASCII 0–127.

5. **`video.v`** — Top-level. Instantiates PLL, timing, text_renderer. Routes signals to pins.

Resource usage at XGA: **115 LEs (1%), 16384 memory bits (7%), 1 PLL.** Plenty of headroom.

## Project files

- `video.v` — top module
- `timing.v` — VGA timing generator
- `text_renderer.v` — character rendering pipeline
- `char_rom.v` — MegaWizard ROM (do not edit by hand; regenerate via MegaWizard)
- `vga_pll.v` — MegaWizard PLL (same)
- `vga_8x16.mif` — font data
- `video.qpf` / `video.qsf` / `video.sdc` — Quartus project files
- `cbx_args.txt` — MegaWizard parameter memory (keep, used for IP regen)

The `.qsf` is the source of truth for pin assignments and project settings.

## Hard-won lessons (please respect these)

- **The DIP switch numbering on the physical hardware starts at 1; in the schematic it starts at 0.** Always cross-reference with the manual's pin assignment table when assigning DIP switches.
- **Active Serial programming works for Cyclone I on this board** despite Quartus officially saying it shouldn't. JTAG mode does NOT work — the board's programming header is wired to the EPCS configuration EEPROM, not to the FPGA's JTAG pins.
- **Sync polarity is active-low for ALL resolutions on this board's scaler**, even though SVGA/XGA specs say positive. Don't trust the spec; trust the working measurement.
- **DIP2 (the schematic's DIP2, physical SW3) on disables video to the LCD entirely.** Keep it OFF for normal operation.
- **PLL ratios are tight on Cyclone I.** Cyclone PLLs use small integer M/N ratios with VCO range constraints. Don't expect arbitrary frequencies. The MegaWizard will report what it actually achieved — believe it, not what you asked for.
- **The character ROM has 2 cycles of latency** (`outdata_reg_a = "CLOCK0"` registers both address and data). The output register adds a third. Any metadata signal derived from pixel_x must be delayed with **2 registers (`_d1` and `_d2`)** to align with ROM output. See "Things that DON'T work" for details.
- **The crystal is 21.47727 MHz, not 21 MHz.** Use 46.561 ns period in SDC files.
- **The user has ALL the Quartus warnings investigated.** They understand `dangling logic` warnings (signals optimized away because nothing uses them — fine when expected), the PowerPlay analyzer "skipped" warning (informational, ignore), and PLL connectivity warnings (areset unused, harmless if you tie it to 1'b0 explicitly).

## What's next on the roadmap

03-keyboard is **complete** — working text terminal on real hardware. After this, the user wants to build a CPU (RV32I, single-cycle to start), an SDRAM controller (Wishbone-attached), a UART for printf-style debugging, and eventually port a small OS or run C programs through it.

## How to help going forward

- The user has solid digital logic fundamentals from ECEN 320 but is new to Verilog-2001 specifics (vs SystemVerilog) and Altera's tools (vs Xilinx). They learn fast and appreciate explanation of *why* something works, not just the mechanics.
- They appreciate getting concrete code that works on first compile, with clear comments explaining the structure. They'll iterate from there.
- They like understanding tradeoffs and second-order consequences ("if I change X, what does it cost in resources / timing / complexity later?"). Surface these proactively when relevant.
- Stage things into small verifiable wins. They've been burned by hours of debugging where bugs in multiple subsystems entangle. One thing at a time, on real hardware, before stacking the next thing.
- They want to do this project the right way — clean code, version-controlled, well-documented. Suggest good practices when natural; don't lecture.
- They can be at home (full toolchain) or at work (no FPGA, but full development env). Suggest simulation-first work when at work; suggest hardware iteration when at home.
- Their domain at home is `samwarr.dev`. Their git workflow is established. They use Linux (Debian 13 KDE) with a Quartus VM for hardware bring-up.
- The OneChipBook context is somewhat unusual — repurposed iPad LCD, Japanese educational hardware, etc. — and the manual quirks have been hard-won. Refer to this CLAUDE.md as the authoritative source on the board's actual behavior.

## Reference URLs that have been useful

- The OneChipBook-12 Technical Reference Rev1.01 (English) — the user has the PDF
- Quartus II 11.0 Web Edition handbook — for module/IP documentation
- VESA DMT timing tables — for VGA/SVGA/XGA timing parameters
- IBM PC 8×16 VGA font — public domain, generated into `vga_8x16.mif`

## Things that DON'T work, don't try them again

- JTAG programming on this board — physically not connected to FPGA JTAG pins
- Standard SVGA active-high sync — the scaler rejects it on this board
- PLLs targeting frequencies that need M/N ratios outside Cyclone I's range — accept the closest achievable
- Quartus newer than 13.0sp1 for Cyclone I — device support dropped
- **char_rom pipeline is 2 cycles, not 1.** `outdata_reg_a = "CLOCK0"` means the ROM registers both the address input AND the data output. Total pipeline from `pixel_x` to `r/g/b`: 4 cycles (2 ROM + 1 pixel_on combinational + 1 output register). Metadata signals (`col`, `in_area`, etc.) need `_d1` AND `_d2` delay registers to align with `rom_data` at the `pixel_on` stage. One delay register is 1 cycle short — causes a column-shift bug where each character's first column appears displaced. Don't derive this from first principles; match `text_renderer.v`'s pipeline exactly.

## 03-keyboard completed stages

- **Stage A:** PS/2 byte receiver (`ps2_rx.v`). 2-flop sync, falling edge detect, 11-bit frame shift register, odd parity check, `data_valid` pulse. Last received scan code shown on 8 LEDs. Tested on hardware.
- **Stage B:** `hex_display.v` renders last received scan code as 2 hex characters at center of 1024×768 display. Uses `vga65mhz_pll` (64.43 MHz), XGA timing, same `char_rom` as 02-video. Tested on hardware.
- **Stage C:** `sc_parser.v` strips 0xE0 (extended) and 0xF0 (release) prefixes, emits key-down/key-up events.
- **Stage D:** Scan code → ASCII translation with shift-state tracking inside `sc_parser.v`. Emits `ascii` + `ascii_valid` for printable keys, plus 0x0D (Enter) and 0x08 (Backspace).
- **Stage E:** `text_buf.v` (8192×8 inferred dual-port M4K RAM, init 0x20), `terminal.v` (4-cycle pixel pipeline reading from buffer), cursor controller in `keyboard.v`. Keystrokes write into the buffer and advance the cursor; Enter wraps to next row, Backspace erases. **Working text terminal on hardware.**
  - text_buf init loop (8192 iters) exceeded Quartus's default constant-loop limit of 5000; bumped via `set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 10000` in `keyboard.qsf`.
  - Synthesizer optimizes away 2 of 16 M4K blocks because bit 7 of `rd_data` is never read in `terminal.v` (only `rd_data[6:0]`) and `wr_data` is always < 0x80 → bit-7 storage is provably constant. Benign; 14 M4Ks used. Restore by widening `char_rom_addr` to 12 bits if extended ASCII is ever needed.