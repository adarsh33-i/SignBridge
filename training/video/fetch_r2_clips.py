#!/usr/bin/env python3
"""Download the labelled signer clips referenced by assets/signs/manifest.json.

The clips live in the Cloudflare R2 bucket `signbridge-sign-videos` and are
served by the deployed sign_assets worker, so no credentials are needed. The
worker is the only route that works from a laptop: the Cloudflare REST API
rejects the stored wrangler token.

    python3 training/video/fetch_r2_clips.py --lang asl --limit 200
    python3 training/video/fetch_r2_clips.py            # everything

Files land in training/video/data/clips/<lang>/<name>.mp4 and are kept, so a
re-run only fetches what is missing.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "assets" / "signs" / "manifest.json"
DEFAULT_BASE_URL = "https://signbridge-sign-assets.signbridge-adesso.workers.dev"
DATA = Path(__file__).resolve().parent / "data"
DEFAULT_OUT = DATA / "clips"
MP4_MAGIC = b"ftyp"
MIN_BYTES = 20_000
LOG = DATA / "downloaded.jsonl"


def manifest_clip_paths(manifest: dict, langs: tuple[str, ...]) -> list[str]:
    paths: set[str] = set()
    for lang in langs:
        for asset_path in manifest.get(lang, {}).values():
            name = Path(asset_path).name
            paths.add(f"{lang}/{name}")
    return sorted(paths)


def load_downloaded() -> set[str]:
    """Keys fetched by an earlier run. The mp4 itself may be gone: extraction
    deletes clips after their track is written, so the log is the resume point."""
    if not LOG.is_file():
        return set()
    keys = set()
    for line in LOG.read_text(encoding="utf-8").splitlines():
        if line.strip():
            keys.add(json.loads(line)["key"])
    return keys


def is_complete(target: Path) -> bool:
    if not target.is_file():
        return False
    if target.stat().st_size < MIN_BYTES:
        return False
    with target.open("rb") as handle:
        head = handle.read(12)
    return MP4_MAGIC in head


def fetch_one(
    key: str, base_url: str, out_dir: Path, retries: int, timeout: int
) -> tuple[str, str, int]:
    target = out_dir / key
    if is_complete(target):
        return key, "skip", target.stat().st_size
    target.parent.mkdir(parents=True, exist_ok=True)
    url = f"{base_url}/{key}"
    last_error = "unknown"
    for attempt in range(1, retries + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "signbridge-corpus"})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read()
            if response.status != 200 or len(body) < MIN_BYTES or MP4_MAGIC not in body[:12]:
                last_error = f"bad response ({response.status}, {len(body)}B)"
            else:
                tmp = target.with_suffix(".part")
                tmp.write_bytes(body)
                tmp.replace(target)
                return key, "ok", len(body)
        except (urllib.error.URLError, TimeoutError, OSError) as error:
            last_error = str(error)
        time.sleep(attempt * 2)
    return key, f"fail: {last_error}", 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--lang", choices=("asl", "isl", "both"), default="both")
    parser.add_argument("--limit", type=int, default=0, help="max clips (0 = all)")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--retries", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    langs = ("asl", "isl") if args.lang == "both" else (args.lang,)
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    keys = manifest_clip_paths(manifest, langs)
    downloaded = load_downloaded()
    todo = [key for key in keys if key not in downloaded and not is_complete(args.out / key)]
    if args.limit:
        per_lang: dict[str, int] = {}
        kept = []
        for key in todo:
            lang = key.split("/", 1)[0]
            per_lang[lang] = per_lang.get(lang, 0) + 1
            if per_lang[lang] <= args.limit:
                kept.append(key)
        todo = kept

    print(f"{len(keys)} clips in manifest, {len(downloaded)} already fetched")
    print(f"todo: {len(todo)}")
    if args.dry_run:
        for key in todo[:20]:
            print(f"  would fetch {key}")
        return 0

    done = ok_bytes = 0
    failures: list[str] = []
    started = time.perf_counter()
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with ThreadPoolExecutor(max_workers=args.jobs) as pool, LOG.open("a", encoding="utf-8") as log:
        futures = [
            pool.submit(fetch_one, key, args.base_url, args.out, args.retries, args.timeout)
            for key in todo
        ]
        for index, future in enumerate(futures, 1):
            key, status, size = future.result()
            if status == "ok":
                ok_bytes += size
                log.write(json.dumps({"key": key, "bytes": size}) + "\n")
                log.flush()
            elif status != "skip":
                failures.append(f"{key}: {status}")
            done += 1
            if index % 200 == 0 or index == len(futures):
                rate = done / max(time.perf_counter() - started, 1e-6)
                print(
                    f"  {done}/{len(futures)} clips, "
                    f"{ok_bytes / 1e6:.0f} MB, {rate:.1f}/s"
                )

    elapsed = time.perf_counter() - started
    print(
        f"done: {done - len(failures)} present, {ok_bytes / 1e9:.2f} GB fetched "
        f"in {elapsed / 60:.1f} min"
    )
    for line in failures[:20]:
        print(f"  FAILED {line}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
