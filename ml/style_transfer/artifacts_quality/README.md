# Separate color-preserving Monet candidate

This directory belongs to `codex/monet-model-quality`, based on `e8ff563`.
The original demo artifacts remain in `../artifacts`. This package does not
update the running demo's RTL ROM or firmware coefficient image.

The student still has 8,251 parameters and the original C24/R4 graph: 23 Conv,
22 explicit BN, nearest upsampling, INT8 activations and the same coefficient
address layout. All residual tensors share scale 1/16; RGB output uses 1/128.
The payload is 11,056 bytes; the banked coefficient image is 24,576 bytes.

- `student_fp.pt`: selected float reference. Honor `config.range_limit` and
  `config.activation_scales` when loading it.
- `student_qat.pt`: selected progressive-QAT model after short error recovery.
- `integer/`: coefficient image, packed payload, graph and independent integer
  oracle parameters. Load the entire folder from one candidate.
- `teacher.pt`: training-only teacher; honor `config.teacher_resize=bilinear`.
- `alternative_quant_only/`: stage-one candidate preserving the old style,
  with improved quantization fidelity. Do not mix its coefficients or graph
  with the color-preserving candidate.

Input is RGB uint8, signed activation `q = u8 - 128`. Output is RGB uint8,
`u8 = q + 128`. Padding is zero; rounding is nearest with ties away from zero.
Use `integer.py` for deployment truth, rather than treating fake QAT as exact
fixed-affine arithmetic.

Reserved test: 64 previously unreviewed near-duplicate groups, after excluding
151 earlier reviewed groups. Low-frequency chroma MAE improves from 6.72 to
1.09 LSB; content/texture proxies improve against the original model. Color
retention improves substantially, but fine grain, blur and imperfect brush
texture remain; mean luminance drift increases. These are diagnostic measures,
not an art-quality certification.

The baseline RTL exactly matches this integer candidate on three 32x24 full
network cases with randomized DDR stalls. This does not validate the concurrently
modified RTL, physical video, resource utilization, timing or board FPS.

Evidence and immutable hashes: `../../../docs/model_quality_results/`.
Experiment narrative and handoff: `../../../docs/MODEL_QUALITY_OPTIMIZATION.md`.
Training tools: `../QUALITY_README.md`.
