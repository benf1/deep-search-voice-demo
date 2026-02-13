#!/usr/bin/env bash
set -euo pipefail

# Run speech-to-speech (voice changer) variants from one guide narration.
# Usage:
#   ELEVENLABS_API_KEY=... bash scripts/run_elevenlabs_voice_changer_ab.sh \
#     /path/to/guide.wav /path/to/out_dir [voice_id]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
API_KEY="${ELEVENLABS_API_KEY:-}"
GUIDE_AUDIO="${1:-}"
OUT_DIR="${2:-$ROOT/audio/cloned/voice_changer_ab}"
VOICE_ID="${3:-${ELEVENLABS_VOICE_ID:-}}"

if [[ -z "$API_KEY" ]]; then
  echo "ELEVENLABS_API_KEY is required"
  exit 1
fi
if [[ -z "$GUIDE_AUDIO" || ! -f "$GUIDE_AUDIO" ]]; then
  echo "Guide audio is required and must exist"
  exit 1
fi
if [[ -z "$VOICE_ID" ]]; then
  echo "Voice ID is required (arg3 or ELEVENLABS_VOICE_ID)"
  exit 1
fi

mkdir -p "$OUT_DIR"

render_variant() {
  local name="$1"
  local stability="$2"
  local similarity="$3"
  local style="$4"
  local out="$OUT_DIR/${name}.mp3"

  curl -sS -X POST "https://api.elevenlabs.io/v1/speech-to-speech/$VOICE_ID" \
    -H "xi-api-key: $API_KEY" \
    -H "Accept: audio/mpeg" \
    -F "audio=@$GUIDE_AUDIO" \
    -F "model_id=eleven_multilingual_sts_v2" \
    -F "voice_settings={\"stability\":$stability,\"similarity_boost\":$similarity,\"style\":$style,\"use_speaker_boost\":true}" \
    --output "$out"

  ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$out" >/dev/null
}

render_variant "vc_a_identity" 0.45 0.90 0.15
render_variant "vc_b_balanced" 0.52 0.84 0.12
render_variant "vc_c_expressive" 0.38 0.88 0.22

cat > "$OUT_DIR/variants.txt" <<'TXT'
vc_a_identity: stability=0.45 similarity=0.90 style=0.15
vc_b_balanced: stability=0.52 similarity=0.84 style=0.12
vc_c_expressive: stability=0.38 similarity=0.88 style=0.22
TXT

echo "Done. Voice Changer variants in: $OUT_DIR"
