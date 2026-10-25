# QSE UI controls

Branch: `qse-extension`. Hardware UI only; no firmware debounce or weight reload.

## Controls

- KEY0: toggle text OSD visibility. Default on. (The HDMI histogram overlay was removed.) Firmware's OSD enable remains an additional gate and cannot override a KEY0-off state.
- KEY1: toggle comparison/single-style. Default comparison. Comparison retains the original left 640x480 image and corresponding styled right 640x480 image. Single-style displays that same styled 640x480 image centered in the 1280x720 output (x=320..959, y=120..599), with black margins; no resizing or weight replacement.
- Rotary selector: display `0:origin`, `1:style1`, `2:style2`, `3:style3` at x=16,y=16. These labels are informational; even `0:origin` does not change the inference model or select an original-only view. Existing metrics move to y=40.

## Encoding and debounce

SW1/SW2 are active-low. After normalization, `{SW2,SW1}` Gray sequence `00,01,11,10` maps to selection `0,1,2,3`. Physical starting position/order needs board confirmation.

All inputs pass through two pixel-clock synchronizer stages. KEY0/KEY1 require 1,485,000 consecutive stable pixel clocks (20 ms at nominal 74.25 MHz); release is also debounced. A held key causes only one toggle. Selector stability is checked as one 2-bit value and resets its counter on any candidate change. UI outputs publish only on a video frame boundary. The display captures mode in vertical blanking; each row's mode travels inside the asynchronous request FIFO, never as an unrelated live control in the DDR clock domain.

## Verification and regeneration

- `python tools/test_qse.py`: pin contract, original GPIO/UART tests, UI debounce/toggle/Gray tests, exact label characters and pixels, display address/viewport test, full comparison-single-comparison frames.
- `IVERILOG=/usr/bin/iverilog VVP=/usr/bin/vvp python tools/test_compact_font.py`: immutable font equivalence oracle.
- Old OSD pixel regression: compile `tests/osd_bram_pixels_tb.sv` with `osd_text_double_buffer.sv` and `osd_font8x16.sv`, then run with `+font=work/validation/font_oracle.hex`.
- Efinity: source `/home/goodmann/efinity/2026.1/bin/setup.sh`, then `efx_run ti60f225_cam_hdmi.xml --prj -f compile --output_dir outflow_qse_ui_final`, followed by `efx_run ti60f225_cam_hdmi.xml --prj -f pgm --output_dir outflow_qse_ui_final`.
- `pgm` generates the bitstream; do not run `program` unless board programming is separately authorized.

RTL source additions use the existing qse_gpio_sync module in both the SoC and pixel domains. Keep it in the active project source list; Interface Designer saving from an older open GUI may overwrite that list. qse_ui_control.sv is included by the top. SDC cuts pad-to-first-stage D pins in both instances, not the interstage paths.

Acceptance requires routed timing report inspection in addition to successful tool exits. Simulation is not board verification. Existing pre-task document deletions and other local changes are not part of this feature.
