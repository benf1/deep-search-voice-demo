#!/usr/bin/env python3
"""Build a PVC-ready speech dataset from episode audio + transcript JSON files.

Manifest format:
{
  "episodes": [
    {"id": "ep1", "audio": "audio/segments/deep-search-first-10m.mp3", "transcript": "transcripts/first-10m.fr.json"}
  ]
}
"""

from __future__ import annotations

import argparse
import json
import shlex
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass
class Region:
    start: float
    end: float
    char_count: int

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


@dataclass
class Clip:
    episode_id: str
    clip_id: str
    start: float
    end: float
    path: Path

    @property
    def duration(self) -> float:
        return max(0.0, self.end - self.start)


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def load_segments(path: Path) -> list[dict[str, Any]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    return data.get("segments", [])


def merge_regions(segments: list[dict[str, Any]], max_gap_s: float, min_chars: int, min_duration_s: float) -> list[Region]:
    regions: list[Region] = []
    cur: Region | None = None

    for seg in segments:
        text = (seg.get("text") or "").strip()
        if not text:
            continue

        start = float(seg.get("start", 0.0))
        end = float(seg.get("end", start))
        if end <= start:
            continue

        if cur is None:
            cur = Region(start=start, end=end, char_count=len(text))
            continue

        gap = start - cur.end
        if gap <= max_gap_s:
            cur.end = end
            cur.char_count += len(text)
        else:
            if cur.char_count >= min_chars and cur.duration >= min_duration_s:
                regions.append(cur)
            cur = Region(start=start, end=end, char_count=len(text))

    if cur and cur.char_count >= min_chars and cur.duration >= min_duration_s:
        regions.append(cur)

    return regions


def pad_and_merge(regions: list[Region], pad_s: float, max_end: float) -> list[Region]:
    out: list[Region] = []
    for r in regions:
        s = max(0.0, r.start - pad_s)
        e = min(max_end, r.end + pad_s)
        if not out or s > out[-1].end:
            out.append(Region(start=s, end=e, char_count=r.char_count))
        else:
            out[-1].end = max(out[-1].end, e)
            out[-1].char_count += r.char_count
    return out


def ffprobe_duration(audio_path: Path) -> float:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=nokey=1:noprint_wrappers=1",
        str(audio_path),
    ]
    out = subprocess.check_output(cmd, text=True).strip()
    return float(out)


def extract_clip(audio_path: Path, out_path: Path, start: float, end: float, sample_rate: int) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-ss",
        f"{start:.3f}",
        "-to",
        f"{end:.3f}",
        "-i",
        str(audio_path),
        "-ac",
        "1",
        "-ar",
        str(sample_rate),
        "-c:a",
        "pcm_s16le",
        str(out_path),
    ]
    run(cmd)


def concat_pack(concat_txt: Path, output_wav: Path) -> None:
    output_wav.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "concat",
        "-safe",
        "0",
        "-i",
        str(concat_txt),
        "-c",
        "copy",
        str(output_wav),
    ]
    run(cmd)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Build curated PVC speech dataset from episodes.")
    p.add_argument("--manifest", required=True, help="JSON manifest path")
    p.add_argument("--output-dir", required=True, help="Output directory for clips/metadata")
    p.add_argument("--sample-rate", type=int, default=24000, help="Output sample rate")
    p.add_argument("--max-gap", type=float, default=3.0, help="Merge transcript segments if gap <= this")
    p.add_argument("--min-chars", type=int, default=80, help="Minimum chars for a speech region")
    p.add_argument("--min-duration", type=float, default=12.0, help="Minimum speech region duration")
    p.add_argument("--padding", type=float, default=3.5, help="Padding around each speech region")
    p.add_argument("--max-total-seconds", type=float, default=0.0, help="Optional cap for total extracted seconds (0=unlimited)")
    p.add_argument("--concat-wav", default="", help="Optional output wav path for a single merged pack")
    return p.parse_args()


def main() -> None:
    args = parse_args()
    manifest_path = Path(args.manifest).expanduser().resolve()
    out_dir = Path(args.output_dir).expanduser().resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    episodes = manifest.get("episodes", [])
    if not episodes:
        raise SystemExit("Manifest has no episodes")

    clips: list[Clip] = []
    total = 0.0

    for ep in episodes:
        ep_id = ep["id"]
        audio_path = (manifest_path.parent / ep["audio"]).resolve() if not Path(ep["audio"]).is_absolute() else Path(ep["audio"]).resolve()
        transcript_path = (manifest_path.parent / ep["transcript"]).resolve() if not Path(ep["transcript"]).is_absolute() else Path(ep["transcript"]).resolve()

        if not audio_path.exists():
            raise SystemExit(f"Missing audio: {audio_path}")
        if not transcript_path.exists():
            raise SystemExit(f"Missing transcript: {transcript_path}")

        segs = load_segments(transcript_path)
        dur = ffprobe_duration(audio_path)
        regions = merge_regions(
            segs,
            max_gap_s=float(args.max_gap),
            min_chars=int(args.min_chars),
            min_duration_s=float(args.min_duration),
        )
        windows = pad_and_merge(regions, pad_s=float(args.padding), max_end=dur)

        for i, win in enumerate(windows, start=1):
            if args.max_total_seconds > 0 and total >= args.max_total_seconds:
                break
            remaining = args.max_total_seconds - total if args.max_total_seconds > 0 else None
            start = win.start
            end = win.end
            if remaining is not None and win.duration > remaining:
                end = start + max(0.0, remaining)
            if end - start < 2.0:
                continue

            clip_id = f"{ep_id}-{i:04d}"
            clip_path = out_dir / "clips" / f"{clip_id}.wav"
            extract_clip(audio_path, clip_path, start, end, args.sample_rate)
            clips.append(Clip(episode_id=ep_id, clip_id=clip_id, start=start, end=end, path=clip_path))
            total += end - start

    concat_txt = out_dir / "concat.txt"
    concat_lines = [f"file {shlex.quote(str(c.path))}" for c in clips]
    concat_txt.write_text("\n".join(concat_lines) + ("\n" if concat_lines else ""), encoding="utf-8")

    out_manifest = {
        "clips": [
            {
                "episode_id": c.episode_id,
                "clip_id": c.clip_id,
                "start": round(c.start, 3),
                "end": round(c.end, 3),
                "duration": round(c.duration, 3),
                "path": str(c.path),
            }
            for c in clips
        ],
        "total_duration_seconds": round(sum(c.duration for c in clips), 3),
        "total_duration_minutes": round(sum(c.duration for c in clips) / 60.0, 2),
    }
    (out_dir / "manifest.json").write_text(json.dumps(out_manifest, indent=2), encoding="utf-8")

    if args.concat_wav:
        concat_pack(concat_txt, Path(args.concat_wav).expanduser().resolve())

    print(f"Generated {len(clips)} clips")
    print(f"Total speech pack duration: {out_manifest['total_duration_minutes']} min")
    print(f"Manifest: {out_dir / 'manifest.json'}")
    if args.concat_wav:
        print(f"Merged pack: {Path(args.concat_wav).expanduser().resolve()}")


if __name__ == "__main__":
    main()
