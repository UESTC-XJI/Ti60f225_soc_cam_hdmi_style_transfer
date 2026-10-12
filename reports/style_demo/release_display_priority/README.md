# Display priority fix

This bit changes only the inner CNN/display DDR read arbitration. Display reads are prioritized over CNN reads so a long inference cannot starve 720p row fetches and turn missing pixels black. The outer CPU/video bridge remains round-robin.

- Bit: `ti60f225_oob.bit`
- ELF: `soc_video_app.elf` (unchanged from the style demo release)
- Efinity map/interface/PNR/PGM: PASS
- Map resources: LUT4 38447, FF 28282, RAM10 248, DPRAM10 6, DSP48 42, DSP24 98
- Timing: CNN setup +0.302 ns, core setup +2.464 ns, minimum reported hold +0.098 ns
- RTL checks: shared DDR, video, display, and integrated system PASS; integrated behavioral DDR test underflows=0

Board validation is still required. Program this bit together with the supplied ELF after `monitor reset halt` and `load`.
