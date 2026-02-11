#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

API_KEY="${ELEVENLABS_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  echo "ELEVENLABS_API_KEY is required."
  exit 1
fi

VOICE_ID_FILE="$ROOT/.elevenlabs_voice_id_quality"
VOICE_ID="${ELEVENLABS_VOICE_ID:-}"
VOICE_NAME="${ELEVENLABS_VOICE_NAME:-Laurent Voice Quality Pass}"
TEXT_FILE="${1:-$ROOT/transcripts/laurent-interstitial-2m45.en.localized.txt}"

REF_DIR="$ROOT/audio/reference/identity/final"
REF_FILES=(
  "$REF_DIR/s2_fela_23s.wav"
  "$REF_DIR/s3_bahamas_54s.wav"
  "$REF_DIR/s4_jazz_20s.wav"
  "$REF_DIR/s5_rex_60s.wav"
)

for f in "${REF_FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "Missing reference clip: $f"
    exit 1
  fi
done

if [[ ! -f "$TEXT_FILE" ]]; then
  echo "Missing text file: $TEXT_FILE"
  exit 1
fi

mkdir -p "$ROOT/audio/cloned" "$ROOT/site/assets/ab"

create_voice_if_needed() {
  if [[ -n "$VOICE_ID" ]]; then
    echo "Using ELEVENLABS_VOICE_ID from environment."
    return 0
  fi

  if [[ -f "$VOICE_ID_FILE" ]]; then
    VOICE_ID="$(cat "$VOICE_ID_FILE")"
    if [[ -n "$VOICE_ID" ]]; then
      echo "Using cached quality voice id from $VOICE_ID_FILE"
      return 0
    fi
  fi

  echo "Creating fresh ElevenLabs voice for quality pass..."
  local tmp_json
  tmp_json="$(mktemp)"

  local curl_args
  curl_args=(
    -sS -X POST "https://api.elevenlabs.io/v1/voices/add"
    -H "xi-api-key: $API_KEY"
    -F "name=$VOICE_NAME"
    -F "description=Quality pass voice clone from curated Laurent references"
  )

  for f in "${REF_FILES[@]}"; do
    curl_args+=( -F "files=@$f" )
  done

  curl "${curl_args[@]}" > "$tmp_json"

  VOICE_ID="$(python3 - "$tmp_json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
if "voice_id" in data:
    print(data["voice_id"])
    raise SystemExit(0)
detail = data.get("detail") or data
raise SystemExit(f"Failed to create voice: {detail}")
PY
)"

  echo "$VOICE_ID" > "$VOICE_ID_FILE"
  echo "Created quality voice id: $VOICE_ID"
}

synthesize_mp3() {
  local out_mp3="$1"
  local stability="$2"
  local similarity="$3"
  local style="$4"
  local payload

  payload="$(python3 - "$TEXT_FILE" "$stability" "$similarity" "$style" <<'PY'
import json
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
stability = float(sys.argv[2])
similarity = float(sys.argv[3])
style = float(sys.argv[4])

body = {
    "text": text,
    "model_id": "eleven_multilingual_v2",
    "voice_settings": {
        "stability": stability,
        "similarity_boost": similarity,
        "style": style,
        "use_speaker_boost": True
    }
}
print(json.dumps(body))
PY
)"

  curl -sS -X POST "https://api.elevenlabs.io/v1/text-to-speech/$VOICE_ID" \
    -H "xi-api-key: $API_KEY" \
    -H "Accept: audio/mpeg" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    --output "$out_mp3"

  ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$out_mp3" >/dev/null
}

mix_with_bed() {
  local dry_mp3="$1"
  local mix_mp3="$2"
  local target_audio="$ROOT/audio/segments/laurent-interstitial-2m45.mp3"
  local bed_audio="$ROOT/audio/processed/htdemucs/laurent-interstitial-2m45/no_vocals.mp3"
  local aligned_mp3="$ROOT/audio/cloned/.tmp-aligned-$(basename "$dry_mp3")"

  local dry_dur target_dur atempo
  dry_dur="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$dry_mp3")"
  target_dur="$(ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$target_audio")"
  atempo="$(python3 - "$dry_dur" "$target_dur" <<'PY'
import sys
ratio = float(sys.argv[1]) / float(sys.argv[2])
ratio = max(0.5, min(2.0, ratio))
print(f"{ratio:.6f}")
PY
)"

  ffmpeg -y -hide_banner -loglevel error -i "$dry_mp3" \
    -filter:a "atempo=$atempo,volume=1.16" "$aligned_mp3"

  ffmpeg -y -hide_banner -loglevel error \
    -i "$bed_audio" \
    -i "$aligned_mp3" \
    -filter_complex "[0:a]volume=0.70[a0];[1:a]highpass=f=90,lowpass=f=12000,volume=1.18[a1];[a0][a1]amix=inputs=2:duration=first:dropout_transition=2[m]" \
    -map "[m]" -c:a libmp3lame -q:a 2 "$mix_mp3"
}

create_voice_if_needed

echo "Rendering quality variants..."
# q1 identity-heavy
synthesize_mp3 "$ROOT/audio/cloned/quality-q1.mp3" 0.20 0.97 0.35
# q2 balanced-broadcast
synthesize_mp3 "$ROOT/audio/cloned/quality-q2.mp3" 0.28 0.92 0.28
# q3 expressive
synthesize_mp3 "$ROOT/audio/cloned/quality-q3.mp3" 0.16 0.95 0.44
# q4 natural-safe
synthesize_mp3 "$ROOT/audio/cloned/quality-q4.mp3" 0.34 0.88 0.24

echo "Mixing variants over music bed..."
mix_with_bed "$ROOT/audio/cloned/quality-q1.mp3" "$ROOT/audio/cloned/quality-q1.mix.mp3"
mix_with_bed "$ROOT/audio/cloned/quality-q2.mp3" "$ROOT/audio/cloned/quality-q2.mix.mp3"
mix_with_bed "$ROOT/audio/cloned/quality-q3.mp3" "$ROOT/audio/cloned/quality-q3.mix.mp3"
mix_with_bed "$ROOT/audio/cloned/quality-q4.mp3" "$ROOT/audio/cloned/quality-q4.mix.mp3"

# Keep site wiring unchanged: overwrite current English clone slots.
cp "$ROOT/audio/cloned/quality-q1.mix.mp3" "$ROOT/site/assets/english-mix.mp3"
cp "$ROOT/audio/cloned/quality-q2.mix.mp3" "$ROOT/site/assets/english-clone-xtts-full-mix.mp3"
cp "$ROOT/audio/cloned/quality-q3.mix.mp3" "$ROOT/site/assets/ab/variant_a.mix.1p4x.mp3"
cp "$ROOT/audio/cloned/quality-q4.mix.mp3" "$ROOT/site/assets/ab/variant_b.mix.mp3"

cat > "$ROOT/audio/cloned/quality-variants.txt" <<'TXT'
q1: stability=0.20 similarity=0.97 style=0.35
q2: stability=0.28 similarity=0.92 style=0.28
q3: stability=0.16 similarity=0.95 style=0.44
q4: stability=0.34 similarity=0.88 style=0.24
TXT

echo "Done. Updated English clone assets with quality-pass renders."
echo "Notes: $ROOT/audio/cloned/quality-variants.txt"
