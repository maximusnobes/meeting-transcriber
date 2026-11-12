#!/bin/bash
set -euo pipefail

# Usage (from the project folder):
#   ./transcribe.sh ~/Downloads/MyMeeting.m4a
#   ./transcribe.sh ~/Downloads/MyMeeting.m4a --speakers 4
#   ./transcribe.sh ~/Downloads/MyMeeting.m4a --names "SPEAKER_00=Alex,SPEAKER_01=Sam"
#
# Any extra arguments pass straight through to process_meeting.py.
# Also called by watch_downloads.sh if you set up the optional watcher.

# Homebrew is not on launchd's default PATH, so set it explicitly.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Everything (scripts, venv, recordings, transcripts) lives in this folder.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

if [ ! -x "$DIR/venv/bin/python" ]; then
  echo "Error: $DIR/venv not found. Run ./setup.sh first."
  exit 1
fi

AUDIO_VAULT="$DIR/Audio Recordings"
TRANSCRIPT_VAULT="$DIR/Meeting Transcriptions"
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
if [ "$INPUT_FILE" -ef "$TARGET_FILE" ]; then
  echo "File is already in Audio Recordings."
else
  if [ -e "$TARGET_FILE" ]; then
    # Don't clobber an earlier recording that happens to share a name.
    TARGET_FILE="$AUDIO_VAULT/${NAME_ONLY}_$(date +%Y%m%d-%H%M%S).${FILENAME##*.}"
    echo "Name collision; archiving as $(basename -- "$TARGET_FILE")"
  fi
  echo "Moving file to Audio Recordings..."
  mv "$INPUT_FILE" "$TARGET_FILE"
fi

echo "Loading models..."
# set -e aborts here if Python fails, so the success banner cannot lie.
"$DIR/venv/bin/python" "$DIR/process_meeting.py" "$TARGET_FILE" "$@"

echo "========================================"
echo "DONE"
echo "Transcript: $TRANSCRIPT_VAULT/$(basename "${TARGET_FILE%.*}").txt"
echo "Audio:      $TARGET_FILE"
echo "========================================"
