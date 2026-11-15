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

## v23-v25 (15.11.2026): the second take records on the Sony's card, by remote control
Marko: "Only thing which is changing that we are not recording with web camera, we are recording by remote control." Everything else (guide, clips, Beatrice, TALK, Queen, the remote, FINISH) is unchanged.
- **Capture** (Settings > RECORDING, UserDefaults `capture`, POST /capture {"mode":"remote"|"webcam"}; default remote). Remote mode (app/SonyRemote.swift):
  RECORD = guide track starts, then `sonycam start` (MACRO_SKILLS tools/sonycam, Imaging Edge Remote over USB), REC confirmed by `sonycam status`;
  STOP = `sonycam stop`, guide stops 0.5 s later. During a sonycam click the full-screen window lets clicks through (`passClicks`) and takes the front back (`refront`).
  A poll every second mirrors REC/STBY and the camera counter (GET /status `cameraState`, `cameraCounter`); REC or STOP pressed on the camera or in Remote is followed.
- **Picture**: Imaging Edge Remote's biggest window (bundle com.sony.Remote) captured by ScreenCaptureKit (one window, 30 fps; calls from MANTRA_MACRO Capture.swift) and shown
  full screen with the shot title and text on top; Remote may sit on any screen. Needs Screen Recording for Second Take (PERMISSIONS, amber, top right).
- **Take** (takes.json): path = `~/Movies/<take name>.guide.m4a` (Mac microphone, AAC mono 64 kb/s), `camera: true`, `camStart` (ISO, Mac clock at counter 0), `camSecs`,
  later `cameraFile`, `cameraOffset` (tools/secondtake-match), `said` + `heard` (Voice to Text of the guide; `heard` = the shot the words sound like, a hint in the log).
  In remote mode only camera takes count for a shot's state; the webcam takes of 13-14.11.2026 stay listed.
- **Matching afterwards**: `tools/secondtake-match [card PRIVATE/M4ROOT/CLIP or folder] [--dry-run]`: clip CreationDate (XML sidecar / ffprobe) against camStart with the
  best common clock offset (start and length within 3 s), then guide-vs-clip sound cross-correlation (offset, peak; < 0.15 = check by ear). Tested on synthetic clips (30 s clock offset, 1.0 s found).
  `secondtake-finish` uses `cameraFile` for camera takes (skips unmatched ones and says so in LESSON_DRAFT.md).
- **Plan**: `tools/plan_sync [--live] [--dry-run]`: the shot ORDER follows the MPA Academy LESSON PLAN (Text Lesson cb38b4ba); plan steps the class did not show become shots
  12 Foot-bell exercise 1, 13 Warm-up EX02, 14 Maqsum orn T, 15 Maqsum orn P (no clip; WATCH shows their text); toning and the closing song are not shot. Backup
  `<lesson>.analysis.before-plan-sync.json`. v24: the app keeps the file's shot order (no sort by number); SHOOT shows "SHOT 2 OF 15 · NO. 12".
- **Queen** ($0, groq_ai_studio qwen_app/second_take.py, skill second-take): "start second take", "next exercise", "stop second take", "second take status".
- Not run yet: a real camera take through the app (needs Marko watching, and Screen Recording on). tools/rehearsal_test still tests the webcam path.

## v26 (15.11.2026): the real Imaging Edge Remote is flipped, never copied; nothing full screen
Marko tried v25: "a copy of the original program which I couldn't even click. It's disaster ... Simply put in front the original program while we are
recording and then put it on the second when we don't need it. Use Rectangle" and "never make it totally full screen, so I'm blocked".
- The ScreenCaptureKit window copy is gone (no Screen Recording needed; PERMISSIONS = microphone only in remote mode).
- `sonycam front` (MACRO_SKILLS): Remote fronted, Rectangle next-display until it is on the Built-in display, then almost-maximize; `sonycam away`: next-display
  until it leaves the Built-in display. Second Take: RECORD, AGAIN, POST /live and "start second take" bring Remote to the front (Second Take's own window steps back);
  after the take (STOP from Second Take, Queen, the phone, or the red button in Remote itself, followed by the 1 s poll) Remote goes away and Second Take comes back
  for KEEP / AGAIN; WATCH, POST /live {"on":false} and POST /stop send Remote away too.
- The record click: sonycam now clicks the red record button found by Accessibility (AX button "Video", centre by Macro Recorder's AXClick), ONE click only
  (it waits up to 6 s for REC/STBY, never clicks twice); the old offset is used only when the AX button is missing. Found 15.11.2026: the old offset
  (origin + 758,182) hit the big "Photo" (still shutter) button in the 918-wide window; the red one is "Video". Not yet run with a real recording.
- WATCH: a normal titled window, almost-maximized on the chosen screen (visible frame less 2.5 % around), level normal; never borderless full screen.
- Dry flip of Remote tested by sonycam front/away with screenshots of both screens (MacBook: Remote 1361x850 in front, not full screen; BenQ after away).
  The flip through the app itself (v26) is not yet run: Marko paused screen work at 14:12.

## v27 (15.11.2026): SHOOT is a standard window; Remote big on the BenQ with a RECORDING overlay
- SHOOT (app/ShootWindow.swift) is a standard window, not a sheet: titled, resizable from every edge, frame autosave "SecondTakeShoot", first place 720x520 on the MacBook screen,
  minimum 420x360, full screen (green button, ⌃⌘F, FULL SCREEN in the panel) with text growing with the width (x1 to x2.6); buttons wrap (FlowLayout), the whole panel scrolls.
  Checked by screenshots at 720x520 and 420x360 (nothing cut; buttons on two rows at the minimum). POST /shoot/size {"w","h"}, GET /shoot/window; POST /shoot/start {"quiet":true} opens it without Beatrice.
- RECORD: `sonycam big` (MACRO_SKILLS): Remote on the BenQ, Rectangle maximize (not macOS full screen); it stays there after the take; the SHOOT window comes to the front on the MacBook.
  RecOverlay: a click-through non-activating panel on the BenQ: "● RECORDING", timer (camera counter, else own clock), shot title, 6 px red edges left and right; STANDBY line when not
  recording. POST /overlay/test {"on":true|false} simulates it (screenshot checked 15.11.2026).
- A camera take whose counter never moved (camSecs < 1) is marked "(no camera clip ...)", never counts and is never kept. While recording, a lost live view says CAMERA LOST.
- The 0 s take of 16:56:56: it was started by the RECORD path (button, key 2 in SHOOT, POST /record, the phone or Queen; the log line "REC shot" is written only there), not by
  /shoot/start or WATCH; the guide ran 125 s while the camera's counter never moved and Remote lost its live view (state NONE), so no clip on the card; the take closed when STBY came back.
