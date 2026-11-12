#!/usr/bin/env python3
"""
Transcribe an audio file with MLX Whisper and label speakers with pyannote.

Everything runs locally on this machine. The only network access is the
one-time model download from Hugging Face (cached in ~/.cache/huggingface)
plus a token-authenticated metadata check on the gated diarization repo.

Token is read from the HF_TOKEN environment variable, or from ~/.hf_token
if that variable is not set. The file fallback exists because launchd
background jobs do not inherit your shell environment.

Usage:
    python process_meeting.py meeting.m4a
    python process_meeting.py meeting.m4a --speakers 4
    python process_meeting.py meeting.m4a --max-speakers 4
    python process_meeting.py meeting.m4a --names "SPEAKER_00=Alex,SPEAKER_01=Sam"
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

import mlx_whisper
import torch
from pyannote.audio import Pipeline

# --- CONFIGURATION ---
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
DIARIZATION_MODEL = "pyannote/speaker-diarization-3.1"
TRANSCRIPT_FOLDER = os.path.expanduser("~/Meeting Transcriptions")
VOCAB_FILE = os.path.expanduser("~/.meeting_vocab.txt")
TOKEN_FILE = os.path.expanduser("~/.hf_token")

# Bounds on speaker clustering. These are applied on every run so you never
# have to specify a count by hand. They prevent pyannote's two worst failure
# modes: inventing extra speakers out of noise, and collapsing everyone into
# a single label. Lower DEFAULT_MAX_SPEAKERS if your calls are mostly 1:1.
DEFAULT_MIN_SPEAKERS = 2
DEFAULT_MAX_SPEAKERS = 8

# Start a new paragraph if the same speaker pauses longer than this (seconds).
PARAGRAPH_GAP = 3.0


# ------------------------------------------------------------------- secrets

def resolve_token():
    token = os.environ.get("HF_TOKEN")
    if token:
        return token.strip()
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
        if token:
            return token
    sys.exit(
        "No Hugging Face token found.\n"
        f"Set HF_TOKEN, or write the token to {TOKEN_FILE} (chmod 600)."
    )


# ---------------------------------------------------------------- audio prep

def normalize_audio(src, workdir):
    """Always convert to 16 kHz mono PCM. Both models expect exactly this."""
    if shutil.which("ffmpeg") is None:
        sys.exit(
            "ffmpeg not found on PATH.\n"
            "Install with: brew install ffmpeg\n"
            "If this failed inside a background job, PATH is likely missing "
            "/opt/homebrew/bin."
        )

    out = os.path.join(workdir, "normalized.wav")
    result = subprocess.run(
        ["ffmpeg", "-nostdin", "-i", src,
         "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le",
         "-y", out, "-loglevel", "error"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"ffmpeg failed to decode {src}:\n{result.stderr.strip()}")
    return out


# ------------------------------------------------------------- transcription

def load_prompt(explicit):
    """Vocabulary priming: names, acronyms, jargon Whisper would otherwise
    guess at. Roughly the first 200 tokens are what matter, so keep it to a
    short comma-separated list of the proper nouns you actually care about.
    """
    if explicit:
        return explicit
    if os.path.exists(VOCAB_FILE):
        with open(VOCAB_FILE) as f:
            text = f.read().strip()
        return text or None
    return None


def transcribe(audio, model, prompt, language):
    kwargs = {
        "path_or_hf_repo": model,
        "word_timestamps": True,
        "language": language,
        # Defaults to True upstream, which is the main cause of Whisper's
        # repetition death-spirals on long recordings.
        "condition_on_previous_text": False,
    }
    if prompt:
        kwargs["initial_prompt"] = prompt
    return mlx_whisper.transcribe(audio, **kwargs)


# --------------------------------------------------------------- diarization

def diarize(audio, token, num_speakers, min_speakers, max_speakers):
    pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL, use_auth_token=token)
    if pipeline is None:
        sys.exit(
            f"Could not load {DIARIZATION_MODEL}.\n"
            "This is a gated repo: accept the user conditions on its Hugging Face\n"
            "page and confirm the token has read access."
        )

    try:
        pipeline.to(torch.device("mps"))
    except Exception as exc:  # some ops still lack MPS kernels
        print(f"   (MPS unavailable, falling back to CPU: {exc})")

    if num_speakers is not None:
        kwargs = {"num_speakers": num_speakers}
    else:
        kwargs = {"min_speakers": min_speakers, "max_speakers": max_speakers}

    return pipeline(audio, **kwargs)


# ----------------------------------------------------------------- alignment

def turns_from(diarization):
    return sorted(
        (turn.start, turn.end, speaker)
        for turn, _, speaker in diarization.itertracks(yield_label=True)
    )


def speaker_for(turns, start, end):
    """Max-overlap match, falling back to the nearest turn in time.

    Applied per word rather than per Whisper segment, so a segment that
    straddles a speaker change gets split instead of being handed wholesale
    to whoever happened to overlap it more.
    """
    best, best_overlap = None, 0.0
    nearest, nearest_gap = None, float("inf")

    for t_start, t_end, speaker in turns:
        if t_start >= end and best is not None:
            break
        overlap = min(end, t_end) - max(start, t_start)
        if overlap > best_overlap:
            best_overlap, best = overlap, speaker
        if best is None:
            gap = t_start - end if t_start > end else start - t_end
            if gap < nearest_gap:
                nearest_gap, nearest = gap, speaker

    return best or nearest or "UNKNOWN"


def collect_words(transcription):
    """Flatten to a word list, falling back to whole segments where Whisper
    returned no word timings (happens on music, silence, very short clips)."""
    words = []
    for segment in transcription.get("segments", []):
        segment_words = segment.get("words") or []
        if segment_words:
            for w in segment_words:
                text = w.get("word", "").strip()
                if text:
                    words.append({"text": text, "start": w["start"], "end": w["end"]})
        else:
            text = segment.get("text", "").strip()
            if text:
                words.append({"text": text, "start": segment["start"], "end": segment["end"]})
    return words


def group_into_lines(words, turns):
    lines = []
    for w in words:
        speaker = speaker_for(turns, w["start"], w["end"])
        same_speaker = lines and lines[-1]["speaker"] == speaker
        short_pause = lines and (w["start"] - lines[-1]["end"]) < PARAGRAPH_GAP

        if same_speaker and short_pause:
            lines[-1]["words"].append(w["text"])
            lines[-1]["end"] = w["end"]
        else:
            lines.append({
                "speaker": speaker,
                "start": w["start"],
                "end": w["end"],
                "words": [w["text"]],
            })

    for line in lines:
        line["text"] = " ".join(line.pop("words"))
    return lines


# -------------------------------------------------------------------- output

def timestamp(seconds):
    seconds = int(seconds)
    return f"{seconds // 3600:02d}:{(seconds % 3600) // 60:02d}:{seconds % 60:02d}"


def parse_names(raw):
    if not raw:
        return {}
    mapping = {}
    for pair in raw.split(","):
        if "=" in pair:
            key, value = pair.split("=", 1)
            mapping[key.strip()] = value.strip()
    return mapping


def write_outputs(lines, audio_file, names):
    os.makedirs(TRANSCRIPT_FOLDER, exist_ok=True)
    stem = os.path.splitext(os.path.basename(audio_file))[0]

    txt_path = os.path.join(TRANSCRIPT_FOLDER, stem + ".txt")
    with open(txt_path, "w") as f:
        for line in lines:
            label = names.get(line["speaker"], line["speaker"])
            f.write(f"[{timestamp(line['start'])}] {label}: {line['text']}\n\n")

    # Timings kept alongside so you can jump back to any moment in the audio.
    json_path = os.path.join(TRANSCRIPT_FOLDER, stem + ".json")
    with open(json_path, "w") as f:
        json.dump(lines, f, indent=2)

    return txt_path, json_path


# ---------------------------------------------------------------------- main

def main():
    parser = argparse.ArgumentParser(description="Transcribe and diarize a meeting recording.")
    parser.add_argument("audio")
    parser.add_argument("--model", default=DEFAULT_MODEL,
                        help="MLX Whisper repo. Try mlx-community/whisper-large-v3-mlx "
                             "for difficult audio (slower, slightly more accurate).")
    parser.add_argument("--language", default="en", help="Skips autodetect. Use 'auto' to detect.")
    parser.add_argument("--speakers", type=int, help="Exact speaker count, if you happen to know it.")
    parser.add_argument("--min-speakers", type=int, default=DEFAULT_MIN_SPEAKERS)
    parser.add_argument("--max-speakers", type=int, default=DEFAULT_MAX_SPEAKERS)
    parser.add_argument("--prompt", help=f"Vocabulary hint. Defaults to {VOCAB_FILE} if present.")
    parser.add_argument("--names", help='e.g. "SPEAKER_00=Alex,SPEAKER_01=Sam"')
    args = parser.parse_args()

    if not os.path.isfile(args.audio):
        sys.exit(f"No such file: {args.audio}")

    token = resolve_token()
    language = None if args.language == "auto" else args.language

    with tempfile.TemporaryDirectory() as workdir:
        print("0. Normalizing audio to 16 kHz mono...", flush=True)
        audio = normalize_audio(args.audio, workdir)

        print(f"1. Transcribing {os.path.basename(args.audio)}...", flush=True)
        transcription = transcribe(audio, args.model, load_prompt(args.prompt), language)

        print("2. Identifying speakers...", flush=True)
        diarization = diarize(audio, token, args.speakers,
                              args.min_speakers, args.max_speakers)

        print("3. Aligning text (word level)...", flush=True)
        turns = turns_from(diarization)
        lines = group_into_lines(collect_words(transcription), turns)

    detected = sorted({line["speaker"] for line in lines})
    txt_path, json_path = write_outputs(lines, args.audio, parse_names(args.names))

    print(f"\n   Speakers detected: {', '.join(detected)}")
    print(f"   Transcript saved to: {txt_path}")
    print(f"   Timings saved to:    {json_path}")


if __name__ == "__main__":
    main()
