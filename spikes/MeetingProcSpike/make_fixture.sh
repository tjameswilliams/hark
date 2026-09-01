#!/bin/zsh
# Builds fixture/meeting.wav: a synthetic two-speaker meeting.
# Speaker A: Samantha (en_US, female). Speaker B: Daniel (en_GB, male).
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")"
mkdir -p fixture
cd fixture
rm -f utt_*.aiff utt_*.wav meeting.wav

typeset -a lines
lines=(
  "Samantha|Good morning everyone, thanks for joining the planning call today."
  "Daniel|Morning. I reviewed the latest build and the audio capture is working well."
  "Samantha|That is great news. Did you notice any problems with the microphone levels?"
  "Daniel|Only one small issue. The system audio channel is slightly quieter than the microphone."
  "Samantha|We can normalize the channels before mixing them together in the processor."
  "Daniel|Agreed. I also think we should show progress messages while the models are loading."
  "Samantha|Yes, the first download takes a while, so feedback is essential for the user."
  "Daniel|Exactly. After that the models are cached and everything runs much faster."
  "Samantha|Perfect. Let us ship the diarization feature in the next release then."
  "Daniel|Sounds good to me. I will prepare the release notes this afternoon."
)

i=0
for entry in "${lines[@]}"; do
  i=$((i+1))
  voice="${entry%%|*}"
  text="${entry#*|}"
  idx=$(printf "%02d" $i)
  say -v "$voice" -o "utt_${idx}.aiff" "$text"
  # 16 kHz 16-bit mono WAV
  afconvert -f WAVE -d LEI16@16000 -c 1 "utt_${idx}.aiff" "utt_${idx}.wav"
done

# 0.7 s silence gap between utterances, concatenated with sox.
sox -n -r 16000 -c 1 -b 16 gap.wav trim 0.0 0.7
parts=()
for f in utt_*.wav; do
  parts+=("$f" "gap.wav")
done
sox "${parts[@]}" meeting.wav
rm -f utt_*.aiff utt_*.wav gap.wav
soxi meeting.wav
