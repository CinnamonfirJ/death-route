"""Package a Godot Web export for Cloudflare Pages' 25 MiB file limit."""

import argparse
import gzip
import hashlib
import shutil
from pathlib import Path
from zipfile import ZIP_STORED, ZipFile

LIMIT = 25 * 1024 * 1024
SCRIPT_TAG = '<script src="index.js"></script>'
EXPORT_FILES = (
    "index.html", "index.js", "index.wasm", "index.pck",
    "index.audio.worklet.js", "index.audio.position.worklet.js",
    "index.apple-touch-icon.png", "index.icon.png", "index.png",
)


def package(source: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise SystemExit(f"Use an empty output directory: {output}")
    if missing := [name for name in EXPORT_FILES if not (source / name).is_file()]:
        raise SystemExit(f"Incomplete Godot Web export: {', '.join(missing)}")
    html = (source / "index.html").read_text(encoding="utf-8")
    if html.count(SCRIPT_TAG) != 1:
        raise SystemExit("Expected one index.js script tag in the Web export")

    wasm = (source / "index.wasm").read_bytes()
    if not wasm.startswith(b"\0asm"):
        raise SystemExit("The input index.wasm must be an uncompressed WebAssembly module")
    digest = hashlib.sha256(wasm).hexdigest()[:16]
    payload = f"engine-{digest}.bin"
    (output / payload).write_bytes(gzip.compress(wasm, compresslevel=9, mtime=0))
    loader = Path(__file__).with_name("cloudflare_wasm.js").read_text(encoding="utf-8")
    loader = loader.replace("__ENGINE_PAYLOAD__", payload)
    html = html.replace(SCRIPT_TAG, f"<script>\n{loader}</script>\n  {SCRIPT_TAG}")
    (output / "index.html").write_text(html, encoding="utf-8")
    for name in EXPORT_FILES:
        if name not in {"index.html", "index.wasm"}:
            shutil.copyfile(source / name, output / name)
    shutil.copyfile(Path(__file__).with_name("dead_route_privacy.html"), output / "privacy.html")
    shutil.copyfile(Path(__file__).with_name("dead_route_pages_worker.js"), output / "_worker.js")
    (output / "_routes.json").write_text(
        '{"version":1,"include":["/healthz","/signin","/signin/web","/oauth/callback","/api/device/*","/api/web/*","/api/entitlement","/api/market/*"],"exclude":[]}',
        encoding="utf-8",
    )

    # Disable Pages' SPA fallback so a missing asset or API returns a real 404.
    (output / "404.html").write_text(
        '<!doctype html><meta charset="utf-8"><title>Page not found</title>'
        '<h1>Page not found</h1><a href="/">Back to Dead Route</a>',
        encoding="utf-8",
    )
    for asset in output.iterdir():
        size = asset.stat().st_size
        if size > LIMIT:
            raise SystemExit(f"{asset.name} is {size:,} bytes; Pages allows at most {LIMIT:,}")
        print(f"{asset.name}: {size:,} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--zip", type=Path, help="Optional ZIP for dashboard uploads")
    args = parser.parse_args()
    package(args.source, args.output)
    if args.zip:
        if args.zip.resolve().is_relative_to(args.output.resolve()):
            parser.error("the ZIP must be outside the Pages output directory")
        with ZipFile(args.zip, "w", ZIP_STORED) as archive:
            for asset in sorted(args.output.iterdir()):
                archive.write(asset, asset.name)
