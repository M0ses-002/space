"""把 D:/user/window 下的 36 帧序列（0001.png…0036.png）拼成 Godot 可用的 6×6 图集。

统一处理：
1. 按文件名数字顺序读取，保证"序列帧名字以标记顺序"。
2. 用一个**所有帧共用**的正方形裁切框，避免逐帧包围盒变化导致抖动。
3. 缩放到目标边长后按 6 列 × 6 行拼图，帧尺寸一致。

裁切框有两种定位方式（JOBS 的 center 字段）：
- "bbox"：按全部帧 alpha 并集的包围盒居中。适合碎片、小行星这类单块主体。
- "disc"：按**圆盘主体**的圆心与半径居中。行星带环、带卫星、带星点时，
  并集包围盒会被这些零散元素拉偏，导致圆盘不落在帧中心；"disc" 用每行/每列
  最长连续不透明段定位实心圆盘，环和杂点不参与。
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path

import numpy as np
from PIL import Image

SEQ_COUNT = 36
COLS = 6
ROWS = 6
ALPHA_THRESHOLD = 8
SOLID_ALPHA = 128

def natural_key(path: Path) -> tuple:
    parts = re.split(r"(\d+)", path.stem)
    return tuple(int(p) if p.isdigit() else p.lower() for p in parts)

def load_frames(folder: Path) -> list[Image.Image]:
    files = sorted(folder.glob("*.png"), key=natural_key)
    if len(files) < SEQ_COUNT:
        raise SystemExit(f"{folder} 只有 {len(files)} 帧，需要 {SEQ_COUNT} 帧")
    return [Image.open(f).convert("RGBA") for f in files[:SEQ_COUNT]]

def union_bbox(frames: list[Image.Image]) -> tuple[int, int, int, int]:
    left = top = 10**9
    right = bottom = -1
    for frame in frames:
        box = frame.getchannel("A").point(lambda a: 255 if a > ALPHA_THRESHOLD else 0).getbbox()
        if not box:
            continue
        left = min(left, box[0])
        top = min(top, box[1])
        right = max(right, box[2])
        bottom = max(bottom, box[3])
    if right <= left or bottom <= top:
        side = min(frames[0].size)
        return (0, 0, side, side)
    return (left, top, right, bottom)

def _longest_run(row: np.ndarray) -> tuple[int, int, int]:
    """一行布尔数组中最长连续 True 段的 (起点, 终点(不含), 长度)。"""
    padded = np.concatenate(([False], row, [False]))
    edges = np.flatnonzero(padded[1:] != padded[:-1])
    if edges.size < 2:
        return 0, 0, 0
    starts, ends = edges[0::2], edges[1::2]
    lengths = ends - starts
    best = int(np.argmax(lengths))
    return int(starts[best]), int(ends[best]), int(lengths[best])

def disc_geometry(alpha: np.ndarray) -> tuple[float, float, float]:
    """用每行/每列最长连续不透明段定位实心圆盘，返回 (cx, cy, radius)。

    圆盘是一整块实心区域，最长连续段必然落在圆盘内；环、卫星、星点是独立短段，
    不会被计入，因此圆心与半径不会被它们拉偏。
    """
    mask = alpha > SOLID_ALPHA
    rows = [_longest_run(mask[y]) for y in range(mask.shape[0])]
    cols = [_longest_run(mask[:, x]) for x in range(mask.shape[1])]
    row_len = np.array([r[2] for r in rows], dtype=float)
    col_len = np.array([c[2] for c in cols], dtype=float)
    radius = float(max(row_len.max(), col_len.max())) / 2.0
    # 只有弦长接近直径的行/列属于圆盘主体，取其中点中位数作为圆心，抗噪。
    row_mid = np.array([(r[0] + r[1]) / 2.0 for r in rows])
    col_mid = np.array([(c[0] + c[1]) / 2.0 for c in cols])
    solid_rows = row_mid[row_len > 0.85 * row_len.max()]
    solid_cols = col_mid[col_len > 0.85 * col_len.max()]
    return float(np.median(solid_cols)), float(np.median(solid_rows)), radius

def disc_metrics(frames: list[Image.Image]) -> tuple[float, float, float]:
    """全部帧的圆盘圆心与半径中位数：单帧抖动不影响共用裁切框。"""
    centers, radii = [], []
    for frame in frames:
        cx, cy, radius = disc_geometry(np.asarray(frame)[:, :, 3])
        centers.append((cx, cy))
        radii.append(radius)
    centers_array = np.array(centers)
    return (float(np.median(centers_array[:, 0])),
            float(np.median(centers_array[:, 1])),
            float(np.median(radii)))

def square_box(cx: float, cy: float, side: float) -> tuple[int, int, int, int]:
    """以 (cx, cy) 为中心的正方形裁切框，边长取整保证宽高严格相等。"""
    x0 = round(cx - side / 2.0)
    y0 = round(cy - side / 2.0)
    edge = round(side)
    return (x0, y0, x0 + edge, y0 + edge)

def square_crop_box(bbox: tuple[int, int, int, int], margin: float) -> tuple[int, int, int, int]:
    left, top, right, bottom = bbox
    side = max(right - left, bottom - top) * margin
    return square_box((left + right) / 2.0, (top + bottom) / 2.0, side)

def crop_square(frame: Image.Image, box: tuple[int, int, int, int], target: int) -> Image.Image:
    x0, y0, x1, y1 = box
    # 裁切框可能超出原图，先铺透明画布再把整帧平移到裁切原点。
    canvas = Image.new("RGBA", (x1 - x0, y1 - y0), (0, 0, 0, 0))
    canvas.paste(frame, (-x0, -y0), frame)
    return canvas.resize((target, target), Image.LANCZOS)

def build_sheet(frames: list[Image.Image], target: int, margin: float, center: str) -> tuple[Image.Image, float]:
    """返回 (图集, 圆盘直径占帧边长的比例)。bbox 模式下比例为 0。"""
    disc_ratio = 0.0
    if center == "disc":
        cx, cy, radius = disc_metrics(frames)
        box = square_box(cx, cy, 2.0 * radius * margin)
        disc_ratio = 2.0 * radius / (box[2] - box[0])
    else:
        box = square_crop_box(union_bbox(frames), margin)
    sheet = Image.new("RGBA", (target * COLS, target * ROWS), (0, 0, 0, 0))
    for index, frame in enumerate(frames):
        tile = crop_square(frame, box, target)
        sheet.paste(tile, ((index % COLS) * target, (index // COLS) * target))
    return sheet, disc_ratio

JOBS = [
    {"source": "D:/user/window/P09_晶体_CRYSTAL/frames",
     "output": "assets/world/debris_crystal_sheet.png", "frame": 192, "margin": 1.06, "center": "bbox"},
    {"source": "D:/user/window/P11_黑曜石_OBSIDIAN/frames",
     "output": "assets/world/debris_obsidian_sheet.png", "frame": 192, "margin": 1.06, "center": "bbox"},
    {"source": "D:/user/window/P05_沙漠_DESERT/frames",
     "output": "assets/world/asteroid_desert_sheet.png", "frame": 192, "margin": 1.06, "center": "bbox"},
    # 小行星铁锈：岩石周围散着细小碎屑，按 bbox 裁会把主体压小、还会偏心；
    # 改用 disc 定位岩石实心主体，margin 1.25 让主体等效直径约占帧宽 0.73，
    # 与沙漠那颗的观感尺寸一致（两者共用 200 单位画幅）。
    {"source": "D:/user/Download/P19_破碎_FRACTURED等20项文件/P13_铁锈_RUST/frames",
     "output": "assets/world/asteroid_rust_sheet.png", "frame": 192, "margin": 1.25, "center": "disc"},
    # 行星带环：环向外延伸到约 1.15 倍圆盘半径，margin 取 1.18 才不会被裁；
    # 裁切框以圆盘圆心为中心，保证帧中心与球心重合。
    {"source": "D:/user/window/W2_罗宋_RUSSIAN/frames",
     "output": "assets/world/planet_russian_sheet.png", "frame": 512, "margin": 1.18, "center": "disc"},
    # 行星拉丁：主体外沿约 1.10 倍半径，零星装饰点到 1.35 倍；与罗宋共用 1.18 的画幅，
    # 两种行星的 disc_ratio 因此一致。
    {"source": "D:/user/window/W3_拉丁_LATIN/frames",
     "output": "assets/world/planet_latin_sheet.png", "frame": 512, "margin": 1.18, "center": "disc"},
]

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", default="D:/Godot/Project/space")
    parser.add_argument("--only", default="", help="只处理输出路径包含该子串的任务")
    args = parser.parse_args()
    project = Path(args.project)
    for job in JOBS:
        if args.only and args.only not in job["output"]:
            continue
        frames = load_frames(Path(job["source"]))
        sheet, disc_ratio = build_sheet(frames, job["frame"], job["margin"], job["center"])
        destination = project / job["output"]
        destination.parent.mkdir(parents=True, exist_ok=True)
        sheet.save(destination)
        extra = f"  disc_ratio={disc_ratio:.4f}" if disc_ratio > 0.0 else ""
        print(f"{destination}  {sheet.width}x{sheet.height}  frame={job['frame']}{extra}")

if __name__ == "__main__":
    main()
