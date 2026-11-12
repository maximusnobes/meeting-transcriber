#!/bin/bash
# Triggered by launchd whenever ~/Downloads changes.
# Finds finished .m4a files, transcribes them, notifies on completion.
#
# Deliberately NOT using `set -e`: if one file fails we still want to try
# the next one.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

WATCH_DIR="$HOME/Downloads"
TRANSCRIBE="$HOME/transcribe.sh"
LOCKDIR="/tmp/transcribe_watch.lock"

# How long a file's size must stay unchanged before we consider the download
# finished. Raise this if you regularly grab very large recordings.
STABLE_WAIT=5

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" 2>/dev/null || true
}

# --- Single-instance lock -------------------------------------------------
# launchd fires WatchPaths on every change to the folder, including the ones
# our own move creates. mkdir is atomic, so this prevents overlapping runs.
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  # Clear a lock left behind by a crashed run (older than 4 hours).
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +240 2>/dev/null)" ]; then
    echo "$(date '+%F %T') Removing stale lock."
    rmdir "$LOCKDIR" 2>/dev/null && mkdir "$LOCKDIR" 2>/dev/null || exit 0
  else
    exit 0
  fi
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

shopt -s nullglob nocaseglob

for AUDIO in "$WATCH_DIR"/*.m4a; do
  BASENAME=$(basename -- "$AUDIO")

  # Skip anything a browser is still writing.
  for PARTIAL in "$AUDIO".download "$AUDIO".crdownload "$AUDIO".part "$AUDIO".partial; do
    [ -e "$PARTIAL" ] && continue 2
  done

  # Confirm the file has stopped growing before touching it.
  SIZE_BEFORE=$(stat -f %z "$AUDIO" 2>/dev/null) || continue
  sleep "$STABLE_WAIT"
  SIZE_AFTER=$(stat -f %z "$AUDIO" 2>/dev/null) || continue
  if [ "$SIZE_BEFORE" != "$SIZE_AFTER" ] || [ "$SIZE_AFTER" -lt 10000 ]; then
    echo "$(date '+%F %T') Skipping $BASENAME (still downloading or too small)."
    continue
  fi

  echo ""
  echo "$(date '+%F %T') Picked up $BASENAME"
  notify "Transcription started" "$BASENAME"

  if bash "$TRANSCRIBE" "$AUDIO"; then
    notify "Transcription complete" "${BASENAME%.*}"
  else
    echo "$(date '+%F %T') FAILED on $BASENAME"
    notify "Transcription failed" "$BASENAME — check the log"
  fi
done
