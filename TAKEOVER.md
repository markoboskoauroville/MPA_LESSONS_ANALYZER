# MPA Lessons Analyzer (Mantra): takeover

Mac SwiftUI app, Marko's helper for MPA Academy (frame drum lessons). Compiled only by GitHub Actions (.github/workflows/build.yml, mac-swift template); never on the Mac. Release v<N> marked Latest, asset app.zip. Whole-number versions (`let VERSION` in app/App.swift).

## v1
1 Open (video) -> 2 Transcribe -> 3 Analyze. Transcribe: the video path is POSTed to Voice to Text (Mantra)'s local API (POST /transcribe, poll GET /job/<id>; port from Settings, ~/.config/mantra-ports.json or its row in APPS AND SERVERS.md); the result `<video>.transcript.json` {source,engine,language,duration,segments[{start,end,text}]} is loaded, also at Open.
Table Time | Transcription | Remarks. Remarks and sections come from `<video>.analysis.json` (written by Claude Code / Queen, reloaded when it changes): {"title","lesson","sections":[{start,end,title,code,what,shoot}],"remarks":[{start,end,text}]}. Click a row to play from there.
Local API on 127.0.0.1:8965 (next free port above if busy; number in ~/.mantra/ports/mpa-lessons-analyzer): GET /status, POST /open {"path"}, POST /transcribe, GET /transcript, GET /analysis, POST /reload.
Settings: export folder (UserDefaults `exportFolder`, default ~/Desktop), used by later versions.

## v3-v4 (13.11.2026)
- **drumsplit** (drumsplit/main.swift, own release asset `drumsplit`, also Contents/MacOS/drumsplit): `drumsplit <video|audio> [--out dir] [--param name=value] [--preset n] [--list-params] [--strokes-on-source] [--ls-gain] [--detect-only]`. ffmpeg decodes to 48 kHz stereo float, AVAudioEngine offline manual rendering runs Supertone Clear (aufx cler Sptn, loads fine from a command-line process), residual delay is found by cross-correlation and removed (Clear reports latency 0 but is about 366 ms late), drums = source minus voice, strokes.json by spectral flux + adaptive threshold (D low, T/P high, K/- quiet). Measured about x10 real time (render x10, whole run x9).
- **Clear parameters (v1.1.1):** Ambience Diff/Gain/Mute/Solo, Voice Reverb Diff/Gain/Mute/Solo, Voice Diff/Gain/Mute/Solo, EcoMode, MiniMode, Mono or Stereo; presets Default, Studio, Concert Hall, OutDoor, Ghost, Silence. Default here: Voice Solo=1. FINDING: on the frame-drum excerpt Clear keeps the drum strokes in the voice (voice RMS = source RMS, drums.wav only -39 dB residue); Voice Mute/Diff, Ambience Solo give only residue; presets Ghost and Silence mute everything. So Clear does not remove the drum here. Use `--strokes-on-source` (detects on the original), or another separator (HPSS / a drum-stem model); PatchWork would host the same plug-in and give the same result.
- **App:** 2a Split voice/drums, 2 Transcribe sends <name>.voice.wav to Voice to Text (groq_v3, language picker), full transcript `<name>.transcript.full.json`, lesson-only `<name>.transcript.json` (analysis "cut" ranges, "lessonOnly": true), Lesson only | Full switch, Strokes lane, PLAYLIST of "clips" (boundary-observer stop, Play all with 1 s pause, Space and arrows), SHOTS list with WATCH. v4: SHOOT (4): Beatrice via langsay, Webcam Recorder API (POST /camera, /record/start, /record/stop, port from Settings, ~/.mantra/ports/webcam-recorder or APPS AND SERVERS.md), TALK (mic until 1.5 s silence, Voice to Text groq_v3, Queen /api/chat answers a JSON array of actions: watch record again skip next note edit_shot add_say), `<name>.takes.json`, `<name>.finish.md`, HAND TO QUEEN.
- **API:** GET /status /strokes /clips /shots /takes /finish /transcript /transcript/full /analysis; POST /open /split /transcribe /play {"n"|"start","end"|"all"} /stop /watch {"n"} /shoot/start /shoot/action /reload.
- **Not proven:** SHOOT, TALK, the Webcam Recorder calls and the app itself were never run (no app was opened, by rule); only drumsplit was run.

## Next (request 256, momentaryupdates.md)
Shooting assistant (Beatrice voice, Sony via Webcam Recorder, Resolve grade/trim/export), website lesson update with Lab sequencer, Queen corrections. Never put videos, transcripts or keys in this repo. No README, no description (public, unpromoted).

## v6-v7 (13.11.2026): the first step of the shooting assistant
- WATCH (a shot's WATCH button, POST /watch {"n"}) opens a borderless full-screen window on the display with the menu bar (the BenQ), the clips as video only (aspect fit, black around), sound to the default output. Esc/CLOSE returns. RECORD button bottom centre; while recording it becomes STOP in the same place. SEEN 13.11.2026: shot 1 full screen on the BenQ, two captures differ.
- RECORD: prepareCamera() opens Webcam Recorder (Mantra) when its API is silent, chooses ILCE-7M5 vertical slice, waits for fps > 0, POST /record/start with the name "Lesson 12.11.2026 · shot N · CODE · take K"; STOP lists the take in <video>.takes.json with its path. NOT YET RUN (no test recordings).
- LIVE (v7): POST /live shows the Sony's live picture (middle 9:16) full screen without recording; shown while recording with a REC dot and time. NOT PROVEN: in the first test the live view was black (Webcam Recorder was not running, Sony may need it streaming).
- API added: GET /screen, POST /live, /record, /record/stop, /next, /again; /status has mode (idle|watch|live|record), recording, currentShot, recElapsed.

## v8-v12 (13.11.2026)
- Camera built in (Camera.swift, Recorder.swift, Slicer.swift copied from Webcam Recorder; no port 8867): Sony ILCE-7M5 first, vertical 9:16 slice, HEVC .mov with time code, file ~/Movies/<take name>.mov. SEEN: live picture of the Sony full screen on the BenQ, REC dot and time, a take file was created (by the tester) named "Lesson 12.11.2026 · shot 2 · TR01 · take 1.mov".
- Mute (clips start muted, MUTE/UNMUTE in the full-screen group, POST /mute) and ducking while :8837 /speaking plays. Last video reopened at start. POST /takes/add, finish prompt (safe names, mp4 hvc1+aac, silence rule).
- Second Take protocol: LAN listener :8966 (Bonjour _secondtake._tcp), private/Tailscale sources only, protocol actions only; NO pairing codes; first come first served by X-Remote-Id (423 {"busy","owner"}), 30 s silence or RELEASE (button, POST /release) frees it; loopback :8965 is the full local API and never locked. /status has controller.

## Finisher: tools/secondtake-finish (13.11.2026)
`secondtake-finish [Lesson 2] [--takes F] [--out DIR] [--lut F.cube] [--unkept] [--dry-run] [--json]`; `--serve [8966]` gives
POST /finish (JSON body: lesson, takes, out, lut, unkept). No LLM, no paid call. Per kept take: silencedetect -55 dB trim
(0.15 s before, 0.3 s after), hevc_videotoolbox 10M hvc1 + AAC 192k, 1080x1920, "Lesson 2 - 5 Title.mp4", ffprobe self-check
(hvc1, aac, size, duration = trim, peak < 0 dBFS), LESSON_DRAFT.md next to the clips. Upload and website wait for Marko.
Grade: his film look is a Resolve Color-page DRX (~/ElevateMedia/tools/filmlook), not a LUT, so ffmpeg SKIPS it and says so
(--lut applies a real .cube). The Resolve route (dedicated project "SecondTake <date>") is not implemented: Resolve was not
running and a scripted DRX grade there is crash-prone.

## State at close, 13.11.2026

Second Take v5-v22 closed 13.11.2026: first come first served controller (423, RELEASE), no pairing, LAN limited to private/Tailscale; AGAIN only readies the next take; FINISH runs tools/secondtake-finish (trim, H.265 vertical export, verify, LESSON_DRAFT) as a subprocess; no silent camera fallback (SONY NOT CONNECTED screen, 409 on RECORD); 4K preset when the camera offers it; v21 recovers orphan takes and refuses quit while recording; tools/rehearsal_test is the reusable PASS/FAIL rehearsal. Waiting for Marko: the real shoot tomorrow (Sony on, USB Streaming, white balance 3200-3800 K, mic gain 50-60 %, checklist on the Desktop).
