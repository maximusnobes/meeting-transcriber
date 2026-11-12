# Local Meeting Transcriber

Drop a meeting recording into your Downloads folder and get back a speaker-labeled transcript, without the audio ever leaving your Mac.

```
[00:00:04] SPEAKER_00: Thanks for joining. Let's start with the mail schedule.
[00:00:11] SPEAKER_01: The first piece drops on the twelfth, so proofs are due Friday.
```

## Why I built it

I wanted searchable notes from long client calls without uploading confidential conversations to a third-party transcription service. This runs entirely on Apple Silicon: [MLX Whisper](https://github.com/ml-explore/mlx-examples/tree/main/whisper) for transcription and [pyannote](https://github.com/pyannote/pyannote-audio) for working out who is speaking.

## How it works

```
~/Downloads/*.m4a
   │  launchd notices the folder changed
   ▼
watch_downloads.sh   waits until the download has finished, one run at a time
   ▼
transcribe.sh        archives the original to ~/Audio Recordings
   ▼
process_meeting.py   ffmpeg → 16 kHz mono → Whisper (words + timestamps)
                     → pyannote (speaker turns) → merge → paragraphs
   ▼
~/Meeting Transcriptions/<name>.txt  and  <name>.json
```

A macOS notification fires when each transcript is ready, or if one fails.

## Details worth knowing

- **Speaker matching.** Each word is assigned to the speaker turn it overlaps most, then words are grouped into paragraphs, with a new paragraph after a pause of more than 3 seconds.
- **Sensible speaker bounds.** Clustering is limited to 2–8 speakers by default, which avoids pyannote's two common failures: inventing speakers out of background noise and merging everyone into one. Override with `--speakers`, `--min-speakers` or `--max-speakers`.
- **Fewer hallucinations.** Whisper's `condition_on_previous_text` is turned off, which prevents the repeated-phrase loops it tends to fall into on long recordings.
- **Vocabulary priming.** Put names, acronyms and jargon in `~/.meeting_vocab.txt` (or pass `--prompt`) so Whisper spells them correctly.
- **Real names.** `--names "SPEAKER_00=Alex,SPEAKER_01=Sam"` relabels speakers in the output.
- **Safe with your files.** The original recording is moved, never re-encoded, and a recording with a duplicate name is archived under a timestamped name rather than overwritten.

## Setup (macOS, Apple Silicon)

1. Install ffmpeg and create the Python environment:

   ```bash
   brew install ffmpeg
   brew install python@3.12
   python3.12 -m venv ~/whisper-env
   source ~/whisper-env/bin/activate
   pip install -r requirements.txt
   ```

2. Accept the user conditions for [`pyannote/speaker-diarization-3.1`](https://huggingface.co/pyannote/speaker-diarization-3.1) on Hugging Face, create a read token, and save it where background jobs can find it:

   ```bash
   echo "hf_your_token_here" > ~/.hf_token && chmod 600 ~/.hf_token
   ```

   (`HF_TOKEN` in your environment also works for manual runs.)

3. Put the scripts where `transcribe.sh` expects them:

   ```bash
   cp process_meeting.py transcribe.sh watch_downloads.sh ~/
   chmod +x ~/transcribe.sh ~/watch_downloads.sh
   ```

4. **Manual use:**

   ```bash
   ~/transcribe.sh ~/Downloads/MyMeeting.m4a --speakers 3
   ```

5. **Automatic use:** edit `com.example.transcribe-watch.plist` (replace `YOUR_USERNAME`), copy it to `~/Library/LaunchAgents/`, and load it:

   ```bash
   launchctl load ~/Library/LaunchAgents/com.example.transcribe-watch.plist
   ```

The first run downloads the models (a few GB) to `~/.cache/huggingface`. After that, everything runs offline apart from a quick access check on the gated pyannote model.

## License

MIT
