#!/bin/bash
set -euo pipefail

# Manual usage:
#   ./transcribe.sh ~/Downloads/MyMeeting.m4a
#   ./transcribe.sh ~/Downloads/MyMeeting.m4a --speakers 4
#
# Also called by watch_downloads.sh for automatic runs.
# Any extra arguments pass straight through to process_meeting.py.

# Homebrew is not on launchd's default PATH, so set it explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ $# -lt 1 ]; then
  echo "Error: Please provide an audio file."
  echo "Usage: ./transcribe.sh ~/Downloads/MyMeeting.m4a [--speakers N]"
  exit 1
fi

INPUT_FILE="$1"
shift

if [ ! -f "$INPUT_FILE" ]; then
  echo "Error: No such file: $INPUT_FILE"
  exit 1
fi

AUDIO_VAULT="$HOME/Audio Recordings"
TRANSCRIPT_VAULT="$HOME/Meeting Transcriptions"
mkdir -p "$AUDIO_VAULT" "$TRANSCRIPT_VAULT"

FILENAME=$(basename -- "$INPUT_FILE")
NAME_ONLY="${FILENAME%.*}"
TARGET_FILE="$AUDIO_VAULT/$FILENAME"

echo "========================================"
echo "TRANSCRIBING: $NAME_ONLY"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# Archive the original first. Format conversion happens inside Python against
# a temp file, so the source recording is never re-encoded or modified.
if [ "$INPUT_FILE" != "$TARGET_FILE" ]; then
  if [ -e "$TARGET_FILE" ]; then
    # Don't clobber an earlier recording that happens to share a name.
    TARGET_FILE="$AUDIO_VAULT/${NAME_ONLY}_$(date +%Y%m%d-%H%M%S).${FILENAME##*.}"
    echo "Name collision; archiving as $(basename -- "$TARGET_FILE")"
  fi
  echo "Moving file to Audio Recordings..."
  mv "$INPUT_FILE" "$TARGET_FILE"
else
  echo "File is already in Audio Recordings."
fi

echo "Loading models..."
# shellcheck disable=SC1090
source ~/whisper-env/bin/activate

# set -e aborts here if Python fails, so the success banner cannot lie.
python ~/process_meeting.py "$TARGET_FILE" "$@"

echo "========================================"
echo "DONE"
echo "Transcript: $TRANSCRIPT_VAULT/$(basename "${TARGET_FILE%.*}").txt"
echo "Audio:      $TARGET_FILE"
echo "========================================"
