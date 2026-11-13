# MPA Lessons Analyzer (Mantra): takeover

Mac SwiftUI app, Marko's helper for MPA Academy (frame drum lessons). Compiled only by GitHub Actions (.github/workflows/build.yml, mac-swift template); never on the Mac. Release v<N> marked Latest, asset app.zip. Whole-number versions (`let VERSION` in app/App.swift).

## v1
1 Open (video) -> 2 Transcribe -> 3 Analyze. Transcribe: ffmpeg (/opt/homebrew/bin/ffmpeg) makes a mono 16 kHz WAV in Caches, splits it into 300 s chunks, each chunk goes to MANTRA_VOICE POST http://127.0.0.1:8837/hear?lang=auto&words=1 {"path"} (whole-file requests time out), timestamps offset by chunk start, merged into `<video>.transcript.json`. Words come as {w, t(start), d(END)}; the app groups them into segments.
Table Time | Transcription | Remarks. Remarks and sections come from `<video>.analysis.json` (written by Claude Code / Queen, reloaded when it changes): {"title","lesson","sections":[{start,end,title,code,what,shoot}],"remarks":[{start,end,text}]}. Click a row to play from there.
Local API on 127.0.0.1:8965 (next free port above if busy; number in ~/.mantra/ports/mpa-lessons-analyzer): GET /status, POST /open {"path"}, POST /transcribe, GET /transcript, GET /analysis, POST /reload.
Settings: export folder (UserDefaults `exportFolder`, default ~/Desktop), used by later versions.

## Next (request 256, momentaryupdates.md)
Shooting assistant (Beatrice voice, Sony via Webcam Recorder, Resolve grade/trim/export), website lesson update with Lab sequencer, Queen corrections. Never put videos, transcripts or keys in this repo. No README, no description (public, unpromoted).
