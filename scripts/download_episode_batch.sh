#!/usr/bin/env bash
set -euo pipefail

# Input format (TSV):
# episode_id<TAB>episode_url

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIST_FILE="${1:-$ROOT/configs/episode_urls.tsv}"
OUT_DIR="${2:-$ROOT/audio/raw}"

if [[ ! -f "$LIST_FILE" ]]; then
  echo "Missing list file: $LIST_FILE"
  exit 1
fi

mkdir -p "$OUT_DIR"

while IFS=$'\t' read -r episode_id episode_url; do
  [[ -z "${episode_id:-}" ]] && continue
  [[ "${episode_id:0:1}" == "#" ]] && continue
  if [[ -z "${episode_url:-}" ]]; then
    echo "Skipping $episode_id: empty URL"
    continue
  fi

  out="$OUT_DIR/${episode_id}.mp3"
  if [[ -f "$out" ]]; then
    echo "Exists, skip: $out"
    continue
  fi

  echo "Downloading $episode_id"
  curl -L "$episode_url" -o "$out"
done < "$LIST_FILE"
