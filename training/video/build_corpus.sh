#!/usr/bin/env bash
# Build the video corpus: fetch clips from R2, extract landmark tracks, delete
# the mp4. Chunked so peak disk stays around 1.5 GB instead of the full 23 GB.
#
#   ./training/video/build_corpus.sh            # everything
#   ./training/video/build_corpus.sh 200 4      # chunk size and parallel jobs
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

PY=training/video/.venv/bin/python
CHUNK="${1:-400}"
JOBS="${2:-6}"

if [[ ! -x $PY ]]; then
  echo "missing venv: run uv venv --python 3.11 training/video/.venv first" >&2
  exit 1
fi

while :; do
  fetch_out="$($PY training/video/fetch_r2_clips.py --limit "$CHUNK" --jobs 8)"
  echo "$fetch_out"
  todo="$(printf '%s\n' "$fetch_out" | sed -n 's/^todo: //p')"
  $PY training/video/extract_tracks.py --jobs "$JOBS" --delete-after
  if [[ "${todo:-0}" == "0" ]]; then
    break
  fi
done

echo "corpus built: $(find training/video/data/tracks -name '*.npz' | wc -l | tr -d ' ') tracks"
