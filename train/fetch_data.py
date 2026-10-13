"""下载训练数据：COCO 内容图 + 公版名画风格图。

    python -m train.fetch_data --content 800 --styles 3

**传输层用 curl 而不是 urllib。** 本机（国内网络）实测：urllib 打
commons.wikimedia.org 无论换什么 User-Agent 都是 WinError 10054 连接重置，
而 curl 同一时刻稳定 200。这不是 UA 问题，换浏览器 UA / curl UA 都照样被砍，
所以不做无用的 UA 伪装，直接 shell out 到 curl。
（pypi / images.cocodataset.org 不受影响，但统一走 curl 省得分两套代码。）

风格图不硬编码直链——Wikimedia 的文件路径会变（我第一版硬编码的两个 URL 已经 400 了），
改成走 Commons API 用文件名解析真实缩略图地址。

内容图用 COCO val2017，即 Fast Neural Style 论文用的同一批数据，出问题时有可比性；
解出前 N 张后删掉 zip，不留 1GB 垃圾。
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

UA = "fpga-style-transfer/0.1 (student competition research)"

COCO_URL = "http://images.cocodataset.org/zips/val2017.zip"

STYLE_FILES = {
    "starry_night": "Van Gogh - Starry Night - Google Art Project.jpg",
    "great_wave": "Tsunami by hokusai 19th century.jpg",
    "the_scream": "Edvard Munch, 1893, The Scream, oil, tempera and pastel on cardboard, 91 x 73 cm, National Gallery of Norway.jpg",
    "water_lilies": "Claude Monet - Water Lilies - Google Art Project.jpg",
}


def _curl_bytes(url: str, timeout: int = 60) -> bytes:
    """取回 URL 内容。curl 是唯一在测试中稳定可用的客户端。"""
    out = subprocess.run(
        ["curl", "-sSL", "--fail", "--retry", "3", "--retry-delay", "2",
         "--max-time", str(timeout), "-A", UA, url],
        capture_output=True, check=True,
    )
    return out.stdout


def _curl_file(url: str, dest: Path, timeout: int = 120) -> None:
    """下载到文件。用 -o 让 curl 自己写盘，避免大文件在内存里过一遍。"""
    tmp = dest.with_suffix(dest.suffix + ".part")
    # -sS：静默进度条但保留报错。778MB 的下载进度条刷进日志只会淹掉有用信息，
    # 进度交给外层的"开始/完成"两行。
    subprocess.run(
        ["curl", "-sSL", "--fail", "--retry", "3", "--retry-delay", "2",
         "--max-time", str(timeout), "-A", UA, "-o", str(tmp), url],
        check=True,
    )
    tmp.replace(dest)  # 半截文件不能冒充成品


def resolve_commons(file_title: str, width: int = 1024) -> str:
    """用 Commons API 把文件名解析成指定宽度的缩略图直链。"""
    api = ("https://commons.wikimedia.org/w/api.php?action=query&format=json"
           "&prop=imageinfo&iiprop=url&iiurlwidth={w}&titles={t}")
    from urllib.parse import quote
    data = json.loads(_curl_bytes(api.format(w=width, t=quote(f"File:{file_title}"))))
    page = next(iter(data["query"]["pages"].values()))
    if "imageinfo" not in page:
        raise RuntimeError(f"Commons 上找不到：{file_title}")
    return page["imageinfo"][0]["thumburl"]


def download_styles(limit: int) -> None:
    out = DATA / "styles"
    out.mkdir(parents=True, exist_ok=True)
    for i, (name, title) in enumerate(STYLE_FILES.items()):
        if i >= limit:
            break
        dest = out / f"{name}.jpg"
        if dest.exists():
            print(f"  [跳过] {name}（已存在）")
            continue
        try:
            _curl_file(resolve_commons(title), dest)
            print(f"  [OK]   {name}  {dest.stat().st_size / 1024:.0f}KB")
        except Exception as e:  # 单张风格图失败不该拖垮整批
            print(f"  [失败] {name}: {e}")


def download_coco(n: int) -> None:
    out = DATA / "content"
    out.mkdir(parents=True, exist_ok=True)
    have = len(list(out.glob("*.jpg")))
    if have >= n:
        print(f"  [跳过] COCO 已有 {have} 张")
        return

    zip_path = DATA / "val2017.zip"
    if not zip_path.exists():
        print("  下载 COCO val2017（约 778MB，几分钟）...", flush=True)
        _curl_file(COCO_URL, zip_path, timeout=3600)
        print(f"  下载完成 {zip_path.stat().st_size / 1e6:.0f}MB")

    print(f"  解出前 {n} 张 -> {out}")
    with zipfile.ZipFile(zip_path) as z:
        members = sorted(m for m in z.namelist() if m.endswith(".jpg"))
        for m in members[:n]:
            with z.open(m) as src, open(out / Path(m).name, "wb") as dst:
                shutil.copyfileobj(src, dst)
    zip_path.unlink()  # 用完就删
    print(f"  已删除临时 zip，内容图 {len(list(out.glob('*.jpg')))} 张")


def main() -> None:
    ap = argparse.ArgumentParser(description="下载风格迁移训练数据")
    ap.add_argument("--content", type=int, default=800, help="COCO 内容图数量")
    ap.add_argument("--styles", type=int, default=3, help="风格图数量")
    args = ap.parse_args()

    DATA.mkdir(exist_ok=True)
    print(f"数据目录 {DATA}")
    print("风格图：")
    download_styles(args.styles)
    print("内容图：")
    download_coco(args.content)
    print("完成。")


if __name__ == "__main__":
    sys.exit(main())
