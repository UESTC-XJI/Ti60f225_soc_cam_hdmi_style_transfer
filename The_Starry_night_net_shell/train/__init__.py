"""超轻量快速风格迁移网络的训练、通道剪枝与推理实现（依赖 torch）。

入口：
  train.train      训练 / 微调
  train.prune      通道前缀剪枝
  train.stylize    出图 + PSNR/SSIM
  train.fetch_data 下载 COCO 内容图与公版风格图
"""
