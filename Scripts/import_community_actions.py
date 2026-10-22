#!/usr/bin/env python3
"""Import every WebM in a pinned community pack as lazy-loadable WebP atlases.

Run with a Python environment providing Pillow and a local ffmpeg executable.
Only data assets are downloaded; no upstream scripts or executables are run.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import io
import json
from pathlib import Path
import shutil
import subprocess
import time
from urllib.parse import quote
from urllib.request import urlopen

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/PC2005-cloud/dsh-pet"
REVISION = "2dc2dfe7796c2ab77edb6f093c5886642d6870f4"
WORK = ROOT / "work/community-assets"
OUTPUT = ROOT / "Apps/macOS/Resources/CommunityActions"
FPS = 12
SIZE = (384, 216)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fetch(relative, target):
    if target.exists():
        return
    url = f"https://raw.githubusercontent.com/PC2005-cloud/dsh-pet/{REVISION}/{quote(relative, safe='/')}"
    for attempt in range(3):
        try:
            with urlopen(url, timeout=90) as response:
                data = response.read()
            target.write_bytes(data)
            return
        except Exception:
            if attempt == 2:
                raise
            time.sleep(attempt + 1)


def category(title):
    if any(word in title for word in ["吃", "涮", "喝", "饭", "餐"]):
        return "吃吃喝喝"
    if any(word in title for word in ["工作", "代码", "记录", "余额", "思考"]):
        return "工作与表情"
    if any(word in title for word in ["点击", "拖拽", "睡", "哈欠", "懒腰", "待机", "张望"]):
        return "互动与休息"
    return "奇奇怪怪的小动作"


def enumerate_sources():
    checkout = WORK / "upstream-index"
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise RuntimeError(f"Expected pinned revision {REVISION}, got {revision}")
    tree = subprocess.check_output([
        "git", "-C", str(checkout), "ls-tree", "-rz", "HEAD", "--", "dsh-pet/assets/webm"
    ])
    sources = []
    for entry in tree.split(b"\0"):
        if not entry:
            continue
        meta, path = entry.split(b"\t", 1)
        path = path.decode("utf-8")
        if not path.endswith(".webm"):
            continue
        identifier = digest(path.encode())[:12]
        sources.append({"id": identifier, "title": Path(path).stem,
                        "path": path, "gitBlob": meta.decode().split()[-1]})
    if not sources:
        raise RuntimeError("No source animations found")
    return sorted(sources, key=lambda source: source["path"])


def normalized(bounds):
    x0, y0, x1, y1 = bounds
    return {"x": x0 / SIZE[0], "y": y0 / SIZE[1],
            "width": (x1 - x0) / SIZE[0], "height": (y1 - y0) / SIZE[1]}


def convert(source, ffmpeg):
    path = WORK / "sources" / f"{source['id']}.webm"
    data = path.read_bytes()
    # Git's blob ID verifies bytes against the pinned tree, including LFS pointer errors.
    git_blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    if git_blob != source["gitBlob"]:
        raise RuntimeError(f"Source integrity mismatch: {source['title']}")
    raw = subprocess.check_output([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-threads", "1",
        "-c:v", "libvpx-vp9", "-i", str(path), "-an", "-vf",
        f"fps={FPS},scale={SIZE[0]}:{SIZE[1]}:flags=lanczos,format=rgba",
        "-threads", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1"
    ])
    frame_bytes = SIZE[0] * SIZE[1] * 4
    count = len(raw) // frame_bytes
    if not count or len(raw) % frame_bytes:
        raise RuntimeError(f"Invalid frame stream: {source['title']}")
    columns = min(8, count)
    rows = (count + columns - 1) // columns
    atlas = Image.new("RGBA", (SIZE[0] * columns, SIZE[1] * rows))
    if max(atlas.size) > 16383:
        raise RuntimeError(f"Atlas exceeds WebP dimension limit: {source['title']}")
    frames = []
    preview = None
    has_transparency = False
    last_bounds = (SIZE[0] // 3, 0, SIZE[0] * 2 // 3, SIZE[1])
    for index in range(count):
        frame = Image.frombytes("RGBA", SIZE, raw[index * frame_bytes:(index + 1) * frame_bytes])
        alpha = frame.getchannel("A")
        has_transparency |= alpha.getextrema()[0] == 0
        bounds = alpha.point(lambda value: 255 if value > 16 else 0).getbbox() or last_bounds
        last_bounds = bounds
        x, y = (index % columns) * SIZE[0], (index // columns) * SIZE[1]
        atlas.paste(frame, (x, y))
        visual = normalized(bounds)
        frames.append({"rect": {"x": x, "y": y, "width": SIZE[0], "height": SIZE[1]},
                       "duration": 1 / FPS, "anchor": {"x": 0.5, "y": 1},
                       "visualBounds": visual, "hitbox": visual})
        if index == count // 2:
            preview = frame
    if not has_transparency:
        raise RuntimeError(f"Alpha channel was lost: {source['title']}")
    target = OUTPUT / f"{source['id']}.webp"
    atlas.save(target, "WEBP", quality=84, method=3, exact=True)
    return {
        "source": {**source, "sha256": digest(data), "frameCount": count,
                   "atlasSha256": digest(target.read_bytes()), "atlasBytes": target.stat().st_size},
        "action": {"clipID": f"full.community.{source['id']}", "title": source["title"],
                   "category": category(source["title"])},
        "atlas": {"id": f"community.{source['id']}", "resource": f"CommunityActions/{source['id']}.webp",
                  "pixelWidth": atlas.width, "pixelHeight": atlas.height},
        "clip": {"id": f"full.community.{source['id']}", "atlasID": f"community.{source['id']}",
                 "looping": False, "frames": frames},
        "preview": preview
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download", action="store_true", help="Download every source clip and MIT text")
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args()
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required")
    sources = enumerate_sources()
    (WORK / "sources").mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if args.download:
        with ThreadPoolExecutor(max_workers=6) as pool:
            futures = [pool.submit(fetch, source["path"], WORK / "sources" / f"{source['id']}.webm")
                       for source in sources]
            for index, future in enumerate(as_completed(futures), 1):
                future.result()
                if index % 10 == 0 or index == len(sources):
                    print(f"Downloaded {index}/{len(sources)}", flush=True)
        fetch("LICENSE", OUTPUT / "LICENSE.txt")
    results = []
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = [pool.submit(convert, source, ffmpeg) for source in sources]
        for index, future in enumerate(as_completed(futures), 1):
            result = future.result()
            results.append(result)
            print(f"Prepared {index}/{len(sources)} {result['action']['title']}", flush=True)
    results.sort(key=lambda result: result["source"]["path"])
    by_title = {result["action"]["title"]: result for result in results}
    idle = by_title["待机呼吸休闲"]
    aliases = {"idle": "待机呼吸休闲", "happy": "点击回应-开心跃动",
               "poke": "点击回应-傲娇生气", "dragged": "被鼠标拖拽悬空反馈",
               "greet": "点击回应-元气挥手"}
    manifest = {"schemaVersion": 1, "atlases": [result["atlas"] for result in results],
                "clips": [result["clip"] for result in results]}
    manifest["clips"].append({"id": "full.community.return", "atlasID": idle["atlas"]["id"],
                              "looping": False, "frames": idle["clip"]["frames"][:4]})
    catalog = {"sourceRepository": REPOSITORY, "sourceRevision": REVISION,
               "aliases": {key: by_title[value]["action"]["clipID"] for key, value in aliases.items()},
               "actions": [result["action"] for result in results]}
    provenance = {"repository": REPOSITORY, "revision": REVISION, "license": "MIT",
                  "copyright": "Copyright (c) 2026 PC2005-cloud",
                  "transform": {"fps": FPS, "frameSize": SIZE, "sharedCanvas": True,
                                "encoding": "WebP atlas, quality 84, alpha retained"},
                  "sources": [result["source"] for result in results]}
    for filename, content in [("sprite-manifest.json", manifest), ("catalog.json", catalog),
                              ("provenance.json", provenance)]:
        (OUTPUT / filename).write_text(json.dumps(content, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    (OUTPUT / "NOTICE.md").write_text(
        f"# Community whale-girl actions\n\nSource: {REPOSITORY}\n\nPinned revision: `{REVISION}`. "
        f"All {len(sources)} WebM animations in `dsh-pet/assets/webm/` were downloaded and converted.\n\n"
        "Copyright (c) 2026 PC2005-cloud. MIT license: see LICENSE.txt. "
        "The app retains its existing ZipZipPipe character credit. This is an unofficial community character; "
        "no DeepSeek affiliation or endorsement is claimed.\n\n"
        "Only image data is included. No upstream application code, scripts, executables, account or network integrations are used. "
        "Every source is verified against the pinned Git blob and recorded with SHA-256 in provenance.json. "
        "The full shared canvas and transparency are retained at 12 fps.\n", encoding="utf-8")
    columns = 8
    sheet = Image.new("RGB", (columns * 192, ((len(results) + columns - 1) // columns) * 132), "#dedee4")
    draw = ImageDraw.Draw(sheet)
    for index, result in enumerate(results):
        thumbnail = result["preview"].resize((192, 108))
        origin = ((index % columns) * 192, (index // columns) * 132)
        sheet.paste(thumbnail, origin, thumbnail)
        draw.text((origin[0] + 8, origin[1] + 111), f"{index + 1:03d} {result['source']['id']}", fill="black")
    sheet.save(WORK / "all-actions-contact-sheet.jpg")
    total = sum(result["source"]["atlasBytes"] for result in results)
    print(f"Imported ALL {len(results)} actions, {sum(len(result['clip']['frames']) for result in results)} frames, "
          f"{total / 1024 / 1024:.1f} MiB of lazy-loaded atlases", flush=True)


if __name__ == "__main__":
    main()
