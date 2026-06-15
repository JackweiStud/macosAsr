# Third Stage Experiment: VAD, Latency, Stop Safety

Branch: `codex/asr-vad-latency-sequencing`

This branch is an experience branch, not a mainline merge candidate yet. It targets three user-visible problems:

1. Long final segments caused by VAD treating background noise as continued speech.
2. Lack of measurable latency data for ASR partial/final performance.
3. Unsafe timing after Stop, where a late final may arrive after the user has started editing.

## What Changed

- VAD now uses a relative silence check inside an active utterance. If background noise remains above the absolute threshold but is clearly lower than the recent speech peak, it can count as silence and end the sentence.
- `daemon.log` now includes privacy-safe metrics:
  - `utterance_started`
  - `partial_metrics`
  - `final_metrics`
- Stop now enters a `stoppingAwaitingFinal` state. If the user types or clicks before the daemon sends `session_stopped`, the app clears pending ASR text and drops the late final instead of mutating the user's new edits.

The logs include lengths, timings, and reasons only. They do not include transcript text.

## How To Test

Run the branch build:

```bash
open --env MACOSASR_ROOT=/Users/jackwl/Code/macosAsr "/Users/jackwl/Code/macosAsr/MacApp/build/macosAsrApp.app"
```

### Test 1: VAD Sentence Split

1. Start dictation with `⌥Z`.
2. Say one short sentence.
3. Pause for about 2 seconds.
4. Say a second short sentence.
5. Stop with `⌥Z`.

Expected difference: final text should arrive in shorter chunks more often, instead of one long combined final.

Check:

```bash
tail -n 80 log/daemon.log | rg "utterance_started|final_metrics"
```

Useful signal:

- More `final_metrics` rows for separate spoken sentences.
- Shorter `utterance_seconds` per final.
- Fewer very long `final_len` values for normal short sentences.

### Test 2: Latency Metrics

Speak a 10-20 second mixed sentence and stop.

Check:

```bash
tail -n 120 log/daemon.log | rg "partial_metrics|final_metrics"
```

Useful signal:

- `first_partial_ms` tells how long the first visible text took.
- `partial_ms` tells whether live refresh is getting expensive.
- `final_ms` tells how long final correction took.

### Test 3: Stop Then Edit

1. Start dictation.
2. Speak a sentence long enough to produce partial text.
3. Press `⌥Z` to stop.
4. Immediately type a few characters or click elsewhere before final arrives.

Expected difference: the late final should not backspace or rewrite your manual edits.

Check:

```bash
tail -n 80 log/macapp.log | rg "late_final|injection_pending"
```

Useful signal:

- `late_final_will_be_dropped_after_user_input`
- `late_final_dropped_after_user_input len=...`

## Validation

Automated checks run for this branch:

```bash
python3 -m unittest discover -s tests
./scripts/test_p0c.sh
./scripts/ci_smoke.sh
./scripts/build_macapp.sh
git diff --check
```
