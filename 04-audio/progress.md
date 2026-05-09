# OneChipBook-12 FPGA Project

This is a from-scratch SoC project on a OneChipBook-12, a Japanese FPGA-based laptop with an Altera Cyclone I (EP1C12Q240C8N), 32MB SDRAM, repurposed iPad LCD, PS/2 keyboard, SD card, and audio. The end goal is a complete homebrew computer — custom CPU, custom peripherals, running software the user writes — built up incrementally on real hardware.

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

- **The DIP switch numbering on the physical hardware starts at 1; in the schematic it starts at 0.** Always cross-reference with the manual's pin assignment table when assigning DIP switches.
- **Active Serial programming works for Cyclone I on this board** despite Quartus officially saying it shouldn't. JTAG mode does NOT work — the board's programming header is wired to the EPCS configuration EEPROM, not to the FPGA's JTAG pins.
- **Sync polarity is active-low for ALL resolutions on this board's scaler**, even though SVGA/XGA specs say positive. Don't trust the spec; trust the working measurement. (Video-only — keep noted for future projects.)
- **PLL ratios are tight on Cyclone I.** Cyclone PLLs use small integer M/N ratios with VCO range constraints. Don't expect arbitrary frequencies. The MegaWizard will report what it actually achieved — believe it, not what you asked for.
- **The crystal is 21.47727 MHz, not 21 MHz.** Use 46.561 ns period in SDC files.
- **Quartus default constant-loop iteration limit is 5000.** For inferred RAM init loops larger than that (e.g., text buffer 8192 entries), bump via `set_global_assignment -name VERILOG_CONSTANT_LOOP_LIMIT 10000` in the QSF.

## Current state of the design — Stage A in progress

**Stage A goal:** prove the DAC is wired and audible. Generate a fixed 440 Hz square wave on both channels. No keyboard, no display.

Modules:
- `tone_gen.v` — 32-bit DDS phase accumulator + square-wave output (MSB → 6'h10/6'h2F mid-rail swing).
- `audio.v` — top-level. Drives both L and R DAC channels with the same sample.

## What's next on the roadmap

- **Stage B:** PS/2 keyboard input (reuse `ps2_rx.v` + `sc_parser.v` from 03-keyboard). Add a key-to-frequency LUT for 30 keys (10 per row × 3 rows). Add sine LUT and sawtooth wave shapes. Wire row → wave-select. Monophonic, key-down sets pitch+wave, key-up silences.
- **Stage C:** Decimal frequency display on screen (reuse text terminal). Show "440 Hz" or similar in a fixed location.

After 04-audio, the next big subsystems are: SDRAM controller (Wishbone-attached), then RV32I CPU, then UART, then OS/C-program port.

## How to help going forward

- The user has solid digital logic fundamentals from ECEN 320 but is new to Verilog-2001 specifics (vs SystemVerilog) and Altera's tools (vs Xilinx). They learn fast and appreciate explanation of *why* something works, not just the mechanics.
- They appreciate getting concrete code that works on first compile, with clear comments explaining the structure. They'll iterate from there.
- They like understanding tradeoffs and second-order consequences ("if I change X, what does it cost in resources / timing / complexity later?"). Surface these proactively when relevant.
- Stage things into small verifiable wins. They've been burned by hours of debugging where bugs in multiple subsystems entangle. One thing at a time, on real hardware, before stacking the next thing.
- They want to do this project the right way — clean code, version-controlled, well-documented. Suggest good practices when natural; don't lecture.

## Things that DON'T work, don't try them again

- JTAG programming on this board — physically not connected to FPGA JTAG pins
- Standard SVGA active-high sync — the scaler rejects it on this board
- PLLs targeting frequencies that need M/N ratios outside Cyclone I's range — accept the closest achievable
- Quartus newer than 13.0sp1 for Cyclone I — device support dropped

## 04-audio completed stages

(none yet)
