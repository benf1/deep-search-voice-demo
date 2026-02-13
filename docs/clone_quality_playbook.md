# Clone Quality Playbook (Laurent)

## Goal
Match the original Laurent tone, depth, and radio cadence more closely.

## Highest-impact pipeline

1. Build a larger, cleaner reference dataset (PVC)
- Target: 30-120+ minutes of Laurent-only speech.
- Source from multiple Deep Search episodes.
- Keep single-speaker sections only.
- Prefer dry/clear speech over heavily musical moments.

2. Train or refresh high-quality cloned voice from curated pack
- Use curated PVC pack instead of 6-10 second snippets.
- Keep one voice identity fixed while you evaluate mixes.

3. Use expressive guide reads for delivery transfer
- For best cadence, create expressive guide audio in target language.
- Convert via speech-to-speech / voice changer style workflow.

4. Improve final mix (not just model settings)
- Voice high-pass around 60-80 Hz (not too high).
- Add gentle low shelf/presence EQ.
- Sidechain duck music bed 2-4 dB under speech.
- Add light compression and subtle saturation on voice bus.

## Reproducible local workflow

### A) Download episodes
Use a TSV list (`configs/episode_urls.sample.tsv`):

```bash
bash scripts/download_episode_batch.sh configs/episode_urls.sample.tsv audio/raw
```

### B) Generate transcript JSON for each episode
Use `scripts/transcribe.py` per file and store in `transcripts/`.

### C) Build PVC dataset from manifest
Create a manifest JSON like `configs/pvc_manifest.sample.json` and run:

```bash
python3 scripts/build_pvc_dataset.py \
  --manifest configs/pvc_manifest.sample.json \
  --output-dir audio/reference/pvc_dataset \
  --max-gap 3.0 \
  --min-chars 80 \
  --min-duration 12 \
  --padding 3.5 \
  --concat-wav audio/reference/laurent-pvc-pack.wav
```

### D) Clone quality A/B
- Render 3-4 variants with fixed text and same mix chain.
- Blind compare against original on: identity, depth, cadence.
- Keep winning profile and iterate only one variable at a time.

## Full-episode rollout notes
- For full episode, keep music-only sections mostly untouched.
- For speech sections, preserve 3-4 seconds at start/end before transitions.
- Use speech windows map to auto-skip pure music while previewing variants.
