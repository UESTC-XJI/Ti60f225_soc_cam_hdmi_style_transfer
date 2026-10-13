"""下载一批**公有领域的水彩画**，作为第二风格的新候选素材。

    python -m tools.fetch_watercolor

## 为什么转向水彩

浮世绘那条线已经把"结构 + 纹理"做到了（亮度域 + luma match），
但它的风格特征是**平涂色块 + 粗轮廓**——而我们刚把线条关掉了（用户要求），
于是浮世绘剩下的可辨识特征就很少了。

水彩的风格特征不同：**柔和的边缘晕染、纸纹、透明叠色**。
它不靠硬轮廓，正好适合"无线条"的路线。

## 版权

Turner（卒 1851）、Sargent（卒 1925）、Homer（卒 1910）——全部过了版权期，
维基共享资源上有高清扫描件。和之前在世插画师的素材是完全不同的性质。

传输层用 curl（本机 urllib 打 Wikimedia 会被重置，见 `README.md` 已知的坑）。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from train.data import DATA  # noqa: E402
from train.fetch_data import _curl_file, resolve_commons  # noqa: E402

# 短名 -> 维基共享资源的文件名（不含 "File:" 前缀）
WATERCOLOR = {
    "wc_turner_arundel":
        "William Turner. Arundel Castle, with Rainbow. c. 1824. "
        "Watercolour on paper. British Museum.jpg",
    "wc_turner_wrexham":
        "Turner, JMW, 'Wrexham, Denbighshire', watercolour.jpg",
    "wc_turner_rainclouds":
        "(Barcelona) Rain Clouds Approaching over a Landscape - William Turner - Tate Britain.jpg",
    "wc_sargent_alligators":
        "Sargent - Muddy Alligators.jpg",
    "wc_sargent_chioggia":
        "John S. Sargent - At Chioggia (c. 1903) - Mint Museum.jpg",
}


def main() -> int:
    out = DATA / "styles_watercolor"
    out.mkdir(parents=True, exist_ok=True)

    ok = fail = 0
    for name, title in WATERCOLOR.items():
        dst = out / f"{name}.jpg"
        if dst.exists():
            print(f"  跳过（已存在） {dst.name}")
            ok += 1
            continue
        try:
            url = resolve_commons(title, width=1600)
            _curl_file(url, dst)
            print(f"  OK  {dst.name:26s} {dst.stat().st_size / 1024:.0f} KB")
            ok += 1
        except Exception as e:  # noqa: BLE001
            print(f"  失败 {name}: {type(e).__name__}: {str(e)[:90]}")
            fail += 1

    print(f"\n完成：{ok} 成功 / {fail} 失败，都在 {out}")
    print("下一步：选一张当 --style，用**亮度域网络**重训（别用 3 通道）。")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
