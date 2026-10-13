"""下载一批公有领域的浮世绘，作为第二风格的候选素材。

    python -m tools.fetch_ukiyoe

**为什么可以放心用**：这些都是 19 世纪的木版画（北斋、广重），早就过了版权期，
维基共享资源上有高清扫描件。和之前那个在世插画师的素材是完全不同的性质。

**为什么选浮世绘**（见 `runs/final/README.md`）：
它的"风格"本身就是**平坦色块 + 粗轮廓 + 有限调色板**——
正好落在 Gram 能学、且我们后处理管线能产出的范围内。
米山舞那种精细线条和光影是 Gram 的结构盲区，怎么调都够不着。

传输层用 curl（本机 urllib 打 Wikimedia 会被重置，见 README「已知的坑」）。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import DATA  # noqa: E402
from train.fetch_data import _curl_file, resolve_commons  # noqa: E402

# 短名 -> 维基共享资源的文件名（不含 "File:" 前缀）
UKIYOE = {
    "ukiyoe_red_fuji":
        "Katsushika Hokusai - Fine Wind, Clear Weather - Google Art Project.jpg",
    "ukiyoe_kusatsu":
        "Ando Hiroshige - Landscape at Kusatsu - Google Art Project.jpg",
    "ukiyoe_kameido":
        "Plum garden at Kameido (Kameido umeyashiki) (CBL J 2693).jpg",
    "ukiyoe_brooklyn":
        "Brooklyn Museum - Landscape Scene - Utagawa Hiroshige (Ando).jpg",
    "ukiyoe_moon":
        "Hiroshige Full moon over a mountain landscape.jpg",
}


def main() -> int:
    out = DATA / "styles"
    out.mkdir(parents=True, exist_ok=True)

    ok = fail = 0
    for name, title in UKIYOE.items():
        dst = out / f"{name}.jpg"
        if dst.exists():
            print(f"  跳过（已存在） {dst.name}")
            ok += 1
            continue
        try:
            url = resolve_commons(title, width=1600)
            _curl_file(url, dst)
            print(f"  OK  {dst.name:28s} {dst.stat().st_size / 1024:.0f} KB")
            ok += 1
        except Exception as e:  # noqa: BLE001
            print(f"  失败 {name}: {type(e).__name__}: {str(e)[:90]}")
            fail += 1

    print(f"\n完成：{ok} 成功 / {fail} 失败，都在 {out}")
    print("注意：great_wave 早就在那儿了，是第 6 张浮世绘。")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
