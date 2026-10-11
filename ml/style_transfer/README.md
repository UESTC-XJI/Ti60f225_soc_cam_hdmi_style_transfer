# Trained Monet C24/R4 deployment

The dataset is an unpaired Monet/photo collection, not a verified Van Gogh collection. The hardware deploys only the student. `artifacts/student_qat.pt` is the selected original checkpoint (SHA256 in `artifacts/manifest.json`); failed QAT candidates are excluded. The teacher artifact omits optimizer state. `artifacts/integer` provides the independent NumPy oracle parameters and explicit Conv/BN graph; the RTL coefficient image is under `rtl/style/model`.

Training used Python 3.12, PyTorch 2.11.0+cu128, torchvision 0.26.0 and an RTX5070. Scripts also require NumPy and Pillow. Run from the repository root. GPU training is seeded but is not promised to reproduce identical checkpoint bytes on a different runtime/GPU.

```powershell
python ml/style_transfer/prepare.py --dataset ../archive --out reports/style_demo/data_v2
python ml/style_transfer/train.py --manifest reports/style_demo/data_v2/manifest.json --out reports/style_demo/teacher_v2 --kind teacher --steps 2500 --batch 6 --validate-every 250
# Keep the step-5000 FP checkpoint from this run; early QAT artifacts are not selected.
python ml/style_transfer/train.py --manifest reports/style_demo/data_v2/manifest.json --out reports/style_demo/student --kind student --teacher reports/style_demo/teacher_v2/step_002500.pt --steps 8000 --batch 12 --qat-after 5500 --validate-every 500
python ml/style_transfer/train.py --manifest reports/style_demo/data_v2/manifest.json --out reports/style_demo/qat_recovery --kind student --resume reports/style_demo/student/step_005000.pt --reference-student reports/style_demo/student/step_005000.pt --steps 3000 --batch 12 --qat-after 1 --lr 0.00005 --content-weight 0.1 --style-weight 0 --distill-weight 50 --validate-every 500
```

The original training configurations predate the corrected loss-description string. Actual QAT recovery coefficients are content 0.1, style 0, reference L1 50 and TV 0.03. BN running statistics stay frozen during QAT. The checkpoint hash is preserved; metadata corrections do not alter its tensors.

To regenerate deployment from the supplied selected artifact:

```powershell
python ml/style_transfer/export.py --checkpoint ml/style_transfer/artifacts/student_qat.pt --out reports/style_demo/export_reproduced
python ml/style_transfer/program.py --model reports/style_demo/export_reproduced --out rtl/style/model
python tools/prepare_style_firmware.py
python tools/build_firmware.py
```

To repeat the reserved test assessment, reuse the committed manifest and point its dataset field to the local collection if needed. Preserve its split assignments.

```powershell
python ml/style_transfer/evaluate.py --manifest reports/style_demo/data_v2/manifest.json --fp ml/style_transfer/artifacts/student_fp.pt --qat ml/style_transfer/artifacts/student_qat.pt --teacher ml/style_transfer/artifacts/teacher.pt --integer ml/style_transfer/artifacts/integer --out reports/style_demo/evaluation_repeated --count 64
```

The initial student's training history contained a fake-quant gradient issue after step 5500. The supplied FP step 5000 precedes that issue; the supplied QAT recovery was trained with the corrected clamp gradient. Retraining with current code may improve the initial QAT run and need not recreate that failure.

Selected-stage training/validation records and the 64-image test assessment are versioned under `docs/style_demo_results`. Deployment, source bytes on the build host, timing reports and simulation results are hashed in `reports/style_demo/release/manifest.json`. Published model/result bytes retain their original line endings through `.gitattributes`.
