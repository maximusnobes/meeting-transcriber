#!/bin/bash
# One-time setup. Run from anywhere:  bash /path/to/meeting-transcriber/setup.sh
# Builds everything inside this folder. Output is also saved to setup.log here.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec > >(tee "$DIR/setup.log") 2>&1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

step() { echo; echo "==== $*"; }
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; FAILED=1; }
FAILED=0

step "1. Tools (Homebrew, ffmpeg, uv)"
if ! command -v brew >/dev/null; then
  bad "Homebrew is not installed. Install it from https://brew.sh, then rerun."
  exit 1
fi
command -v ffmpeg >/dev/null || brew install -q ffmpeg
command -v uv >/dev/null || brew install -q uv
command -v ffmpeg >/dev/null && ok "ffmpeg" || bad "ffmpeg"
command -v uv >/dev/null && ok "uv $(uv --version | cut -d' ' -f2)" || bad "uv"

step "2. Python environment ($DIR/venv)"
cd "$DIR" || exit 1
uv venv --quiet --python 3.12 --allow-existing venv && ok "venv (Python 3.12)" || bad "venv"
uv pip install --quiet --python venv/bin/python -r requirements.txt && ok "packages installed" || bad "pip install"
venv/bin/python -c "import mlx_whisper, torch, pyannote.audio; print('  OK   imports: torch', torch.__version__, '/ pyannote.audio', pyannote.audio.__version__)" \
  || bad "imports"
chmod +x transcribe.sh watch_downloads.sh 2>/dev/null
mkdir -p "Audio Recordings" "Meeting Transcriptions"

step "3. Hugging Face token (~/.hf_token, kept outside this folder)"
if [ ! -s "$HOME/.hf_token" ] && [ -t 0 ]; then
  echo "  No token yet. Before pasting one:"
  echo "   - accept the terms at https://huggingface.co/pyannote/speaker-diarization-3.1"
  echo "     and https://huggingface.co/pyannote/segmentation-3.0"
  echo "   - create a Read token at https://huggingface.co/settings/tokens"
  printf "  Paste the token here (hidden), or press Enter to skip: "
  read -rs TOKEN; echo
  if [ -n "$TOKEN" ]; then
    printf '%s' "$TOKEN" > "$HOME/.hf_token"; unset TOKEN
  fi
fi
if [ -s "$HOME/.hf_token" ]; then
  chmod 600 "$HOME/.hf_token"
  for m in speaker-diarization-3.1 segmentation-3.0; do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $(cat "$HOME/.hf_token")" \
      "https://huggingface.co/pyannote/$m/resolve/main/config.yaml")
    [[ "$CODE" =~ ^(200|302|307)$ ]] && ok "token can access pyannote/$m" \
      || bad "pyannote/$m returned HTTP $CODE (401 = bad token, 403 = accept that model's terms)"
  done
else
  bad "no token saved yet; rerun this script once you have one"
fi

step "4. Tidy up files from the earlier home-folder setup"
for f in transcribe.sh watch_downloads.sh process_meeting.py; do
  [ -f "$HOME/$f" ] && [ "$DIR" != "$HOME" ] && rm "$HOME/$f" && echo "  removed ~/$f (copy; the real one is in this folder)"
done
for d in "Audio Recordings" "Meeting Transcriptions"; do
  [ "$DIR" != "$HOME" ] && rmdir "$HOME/$d" 2>/dev/null && echo "  removed empty ~/$d"
done
if [ -d "$HOME/whisper-env" ] && [ ! -x "$HOME/whisper-env/bin/pip" ]; then
  rm -rf "$HOME/whisper-env" && echo "  removed broken ~/whisper-env"
fi
true

step "DONE"
if [ "$FAILED" = 0 ]; then
  echo "All checks passed. Try it:"
  echo "  cd \"$DIR\" && ./transcribe.sh ~/Downloads/YourMeeting.m4a"
else
  echo "Some steps failed. Ask Claude to read setup.log in this folder."
fi
