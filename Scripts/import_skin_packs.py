#!/usr/bin/env python3
"""Convert pinned, verified data downloads into lazy shared sprite atlases.

Downloads are prepared separately in work/style-review; no upstream code is run.
The baseline metadata is snapshotted once, so reruns do not duplicate actions.
"""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import unicodedata

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "work/style-review"
OUT = ROOT / "Apps/macOS/Resources/CommunityActions"
BASE = WORK / "before-skins"
FPS = 12
CANVAS = (384, 216)


def read(path):
    return json.loads(path.read_text())


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, separators=(",", ":")))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def title_key(title):
    return re.sub(r"\s+", "", unicodedata.normalize("NFKC", title))


def bounds(image, threshold=2):
    return image.getchannel("A").point(lambda v: 255 if v >= threshold else 0).getbbox()


def norm(box, size):
    x0, y0, x1, y1 = box
    return dict(x=x0 / size[0], y=y0 / size[1],
                width=(x1 - x0) / size[0], height=(y1 - y0) / size[1])


def gif_frames(path):
    """Sample the original GIF timeline; retain accumulated duration for held poses."""
    result = []
    source = Image.open(path)
    elapsed = 0.0
    sample = 0
    previous = None
    for index in range(source.n_frames):
        source.seek(index)
        duration = max(0.02, source.info.get("duration", 100) / 1000)
        end = elapsed + duration
        if sample / FPS < end - 1e-8:
            frame = source.convert("RGBA")
            frame.thumbnail((180, 180), Image.Resampling.LANCZOS)
            canvas = Image.new("RGBA", CANVAS)
            # A common scale and bottom alignment for every frame, never a per-pose crop.
            canvas.paste(frame, ((CANVAS[0] - frame.width) // 2, 198 - frame.height))
            signature = sha(canvas.tobytes())
            while sample / FPS < end - 1e-8:
                if signature == previous:
                    result[-1][1] += 1 / FPS
                else:
                    result.append([canvas, 1 / FPS])
                    previous = signature
                sample += 1
        elapsed = end
    return result


def webm_frames(path):
    raw = subprocess.check_output([
        shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-threads", "1",
        "-c:v", "libvpx-vp9", "-i", str(path), "-an", "-vf",
        "fps=12,scale=216:216:force_original_aspect_ratio=decrease:flags=lanczos,"
        "pad=384:216:(ow-iw)/2:(oh-ih)/2:color=black@0,format=rgba",
        "-threads", "1", "-f", "rawvideo", "-pix_fmt", "rgba", "pipe:1"
    ])
    step = CANVAS[0] * CANVAS[1] * 4
    if not raw or len(raw) % step:
        raise ValueError(f"Invalid decoded stream: {path.name}")
    return [[Image.frombytes("RGBA", CANVAS, raw[i:i + step]), 1 / FPS]
            for i in range(0, len(raw), step)]


def convert(item):
    namespace, source = item
    ident = namespace + "." + source["id"]
    cached = WORK / "converted" / (ident + ".json")
    if cached.exists() and (OUT / (ident + ".webp")).exists():
        return read(cached)
    extension = ".gif" if namespace == "red" else ".webm"
    path = WORK / ("red-sources" if namespace == "red" else "yanz-sources") / (source["id"] + extension)
    data = path.read_bytes()
    if sha(data) != source["sha256"]:
        raise ValueError(f"Source SHA mismatch: {path}")
    frames = gif_frames(path) if namespace == "red" else webm_frames(path)
    nonempty = [bounds(im) for im, _ in frames if bounds(im)]
    if not nonempty:
        raise ValueError(f"Empty animation: {source['title']}")
    crop = (max(0, min(b[0] for b in nonempty) - 2), max(0, min(b[1] for b in nonempty) - 2),
            min(CANVAS[0], max(b[2] for b in nonempty) + 2), min(CANVAS[1], max(b[3] for b in nonempty) + 2))
    size = (crop[2] - crop[0], crop[3] - crop[1])
    columns = min(16, len(frames))
    rows = (len(frames) + columns - 1) // columns
    atlas = Image.new("RGBA", (columns * size[0], rows * size[1]))
    if max(atlas.size) > 16383:
        raise ValueError(f"Atlas too large: {source['title']}")
    entries = []
    for index, (im, duration) in enumerate(frames):
        frame = im.crop(crop)
        x, y = index % columns * size[0], index // columns * size[1]
        atlas.paste(frame, (x, y))
        visual = norm(bounds(frame, 24) or (0, 0, *size), size)
        # Split exceptionally long holds to respect schema v1's duration limit.
        while duration > 1e-8:
            held = min(10, duration)
            if held < 0.03:
                entries[-1]["duration"] += held
                break
            entries.append(dict(rect=dict(x=x, y=y, width=size[0], height=size[1]),
                                duration=held, anchor=dict(x=0.5, y=1), visualBounds=visual, hitbox=visual))
            duration -= held
    target = OUT / (ident + ".webp")
    atlas.save(target, "WEBP", quality=84, method=4, exact=True)
    title = source["title"]
    if namespace == "red":
        title = re.sub(r"_\d{4}-\d\d-\d\d.*$", "", title).removeprefix("蓝色大肥鱼_")
        title = {"1": "待机A", "2": "思考", "3": "待机B", "4": "输出", "5": "完成"}.get(title, title)
    action = dict(clipID="full.community." + ident, title=title,
                  category="赤风RED动作" if namespace == "red" else "新增互动与生活", skin="red" if namespace == "red" else "classic")
    if namespace == "red" and source["path"].startswith("素材/"):
        action["category"] = "待机与状态"
    result = dict(action=action,
                  atlas=dict(id="community." + ident, resource="CommunityActions/" + target.name,
                             pixelWidth=atlas.width, pixelHeight=atlas.height),
                  clip=dict(id=action["clipID"], atlasID="community." + ident, looping=False, frames=entries),
                  layout=dict(canvasWidth=CANVAS[0], canvasHeight=CANVAS[1], x=crop[0], y=crop[1], width=size[0], height=size[1]),
                  source=dict(**source, atlasSHA256=sha(target.read_bytes()), atlasBytes=target.stat().st_size,
                              sampledFrames=len(frames), clipID=action["clipID"]))
    write(cached, result)
    print("Converted", namespace, title, len(entries), flush=True)
    return result


def main():
    BASE.mkdir(exist_ok=True)
    (WORK / "converted").mkdir(exist_ok=True)
    for name in ["catalog.json", "sprite-manifest.json", "render-layout.json"]:
        if not (BASE / name).exists():
            shutil.copy2(OUT / name, BASE / name)
    catalog, manifest, layouts = [read(BASE / n) for n in ["catalog.json", "sprite-manifest.json", "render-layout.json"]]
    yanz = read(WORK / "yanz-sources.json")
    red = read(WORK / "red-sources.json")
    old_titles = {title_key(a["title"]): a["clipID"] for a in catalog["actions"]}
    skipped, imports = [], []
    for source in yanz["sources"]:
        existing = old_titles.get(title_key(source["title"]))
        if existing:
            skipped.append(dict(source, reusedClipID=existing, reason="same named action already present; preserve existing version"))
        else:
            imports.append(("yanz", source))
    imports += [("red", s) for s in red["sources"]]
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(convert, imports))
    aliases = {}
    for result in results:
        catalog["actions"].append(result["action"])
        manifest["atlases"].append(result["atlas"])
        manifest["clips"].append(result["clip"])
        layouts[result["atlas"]["id"]] = result["layout"]
        if result["source"]["path"].startswith("素材/"):
            aliases[Path(result["source"]["path"]).stem] = result["clip"]["id"]
    write(OUT / "catalog.json", catalog)
    write(OUT / "sprite-manifest.json", manifest)
    write(OUT / "render-layout.json", layouts)
    write(OUT / "skins.json", dict(aliases={"red": dict(idle=aliases["3"], happy=aliases["5"],
          poke=aliases["2"], dragged=aliases["1"], greet=aliases["5"], **{"return": aliases["3"]})}))
    write(OUT / "skin-provenance.json", dict(yanz=dict(repository=yanz["repository"], revision=yanz["revision"],
          reusedActions=skipped, importedActions=[r["source"] for r in results if r["action"]["skin"] == "classic"]),
          red=dict(repository="https://github.com/Aibie07/whale-girl-desktop-pet", revision="584b11f8d654ffcdf675e1ea38801f01c73c8bed",
          releaseURL=red["releaseURL"], archiveSHA256=red["archiveSHA256"], artist="赤风RED",
          permission="Upstream author has permission; other uses require permission directly from artist. No blanket MIT art license is claimed.",
          sources=[r["source"] for r in results if r["action"]["skin"] == "red"]),
          transform=dict(fps=FPS, canvas=CANVAS, encoding="WebP quality 84, transparent alpha retained",
                         cropping="One union of all frame bounds per action, logical canvas mapping preserved")))
    shutil.copy2(WORK / "yanz-LICENSE", OUT / "yanzwzz-LICENSE.txt")
    shutil.copy2(WORK / "yanz-README.md", OUT / "yanzwzz-UPSTREAM-README.md")
    print("FINISHED", dict(yanzImported=len(results) - len(red["sources"]), yanzReused=len(skipped), red=len(red["sources"]),
                           addedMiB=round(sum(r["source"]["atlasBytes"] for r in results) / 1024**2, 2)), flush=True)


if __name__ == "__main__":
    main()
