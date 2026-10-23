# QSE UI candidate — offline verified, not board tested

- Branch: qse-extension. No commit or board programming performed.
- Rotary label only: 0:origin / 1:style1 / 2:style2 / 3:style3. No model/weight changes.
- KEY0 toggles OSD/histogram, default on. KEY1 toggles side-by-side comparison / centered single styled VGA image, default comparison.
- RTL 20 ms contact debounce, press edge, no autorepeat. Whole-selector candidate stability. Frame-boundary publishing; row mode crosses via request FIFO.
- Existing metrics moved to y=40, label at (16,16). Existing firmware rebuilt without business-logic changes.

## Verification

QSE suite passed: GPIO/pins/UART regression; key bounce/hold/repress; all Gray states; exact four labels; 19,200 label pixels; 3 full display frames with 1,536,000 checked image pixels and no simulated underflow/DMA errors. Font equivalence passed. Existing OSD regression independently passed 52,800 exact pixels.

Efinity map/interface/pnr/pgm passed. Final constrained clock-relationship worst setup +0.281 ns, hold +0.026 ns. XLR 56,338/60,800; RAM 239/256; DSP 140/160. Prior QSE-only routed placement: XLR 56,047; RAM 239; DSP 140. UI net increase: 291 XLR, no additional RAM/DSP.

The discarded first UI attempt prevented character RAM inference and reached 59,049 XLR. Final code restores unconditional registered dual-clock RAM read before the label mux.

## Remaining gates / inherited warnings

Not programmed or board-verified. Confirm selector physical detent ordering and key polarity on hardware. Board display stability, real switching and actual contact bounce remain unmeasured. Existing JTAG clock/constraint warnings and missing unused interface ports remain; positive constrained timing is not proof all external interfaces are constrained. Tool logs also contain the inherited 'cannot find correct IV value' warning. Icarus emits existing font always_comb sensitivity and testbench force limitations; exact pixel scoreboards pass.

Use only the artifacts in this directory as this candidate; outflow_qse_ui contains an abandoned attempt. Full behavior and reproduction commands: QSE_UI.md.
