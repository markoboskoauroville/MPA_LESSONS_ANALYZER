# Second Take tests, 13.11.2026 (tester session)

## Round 1, 19:31: installed Mac app = v8 (pid started 19:25), phone app = versionName 1
| Test | Result | Evidence |
|---|---|---|
| GET 127.0.0.1:8965/status | FAIL | connection refused; the process listens only on *:8966 (lsof). Same bug as fixed in v9 |
| LAN :8966/status | FAIL (old behaviour) | `{"error":"pair: a code is shown on the Mac screen..."}` , v8 still demands pairing; protocol says no codes |
| Phone offline state | PASS | red bar "NO ANSWER . 127.0.0.1:8965", OFFLINE, buttons dimmed |
| Newer builds | v12 is released on GitHub (18:30) but NOT installed; installed is v8. Waiting for install. |

## Round 2, 19:33-19:40: v12 installed (status version 12)
| Test | Result | Evidence |
|---|---|---|
| GET :8965/status | PASS | has protocol, name, mode, shot, shots, takes, elapsed, version, muted, controller |
| GET /shots, /takes | PASS | {"shots":[...]} with n,title,code,say,secs (+watch); /takes {"skipped":[],"takes":[]} |
| Bonjour _secondtake._tcp | PASS | dns-sd shows instance "Second Take" |
| POST watch/live/stop/next/mute/release | PASS | 200 with JSON; /live frame [0,0,2560,1440] on "BenQ LCD" |
| WATCH on BenQ | PASS (partly) | /private/tmp/claude-501/-Users-markobosko-Developer-claude-code/011d3a7a-9b4b-4dff-a736-b51e4f586685/scratchpad/w1.png and w2.png differ (bbox 874..1686 x 0..1440, so the picture moves); portrait video centred, controls bottom-centre (RECORD, WATCH AGAIN, UNMUTE, CLOSE (Esc)), nothing cut. Topmost not proven |
| clip starts muted | PASS | status muted:true, button shows UNMUTE |
| POST /stop returns | PASS | mode idle; frontmost app after = MPALessonsAnalyzer |
| First-come lock (LAN :8966) | PASS | Fake1 owned it; Fake2 got 423 {"busy":true,"owner":"Fake"} on /status and /next; loopback with Fake2 id not blocked |
| Phone states | PASS | OFFLINE (red bar, buttons dimmed), CONNECTED + WATCH green + RECORDING 00:11 + takes count, text matches shots |
| Unknown path | PASS | 404 not part of the Second Take protocol |
| POST /shot with {} or n=99 | MINOR | 404 "no shot 0"/"no shot 99"; 400 would suit bad input |
| POST /again | BUG/NOTE | answers 202, protocol says every POST answers 200; and AGAIN starts a real recording (Shoot.swift again() calls startRecording) |
| clip silent while :8837 speaks | UNTESTED | no voice playback done |
| quit/reopen, last file | UNTESTED | not done |
| record, dry-run | UNTESTED | no dry-run; no recording allowed |
| Mac app down, phone | PASS (earlier, with the old v8) | phone showed NO ANSWER |

Tester mistake: my POST /again on the LAN listener started a real take, ~/Movies/Lesson 12.11.2026 · shot 2 · TR01 · take 1.mov (27 MB). Not deleted.
Bugs ranked: 1) AGAIN starts recording at once, no dry-run exists; 2) /again answers 202; 3) bad /shot input gives 404.

## OBS end-to-end recording test (13.11.2026, evening)

Marko, word for word: "For testing the second take, please, on the desktop, I want to see all the clips you generated, mockup clips, and I will watch them. So, make a mockup. Load the generated clips to the OBS. Play them through virtual camera and record them through second take. And make sure everything is recorded correctly. So basically our OBS is simulating the real camera and person in front of it."
Marko, word for word: "Please make another layer in OBS to check for frozen frames because nothing is moving ... I like we were doing that we were testing Video Ninja. There were some dots flying on the screen. It was nice test. I want to see it now also as a test of movement, overlaid over my frozen picture"

Setup: OBS 32.2.2, collection SecondTakeMock, scene "Second Take mock", 1080x1920 at 25 fps, ffmpeg media source (take) + overlay of 7 moving dots with frame counter F and time T; Start Virtual Camera; OBS audio monitoring to BlackHole 2ch; Second Take camera "OBS Virtual Camera", mic "BlackHole 2ch".
Result: shots 1, 2, 8 recorded as HEVC 1080x1920 25 fps + AAC 48 kHz; counter read on every frame went up by exactly 1 (no dropped, no duplicated, no frozen frames). Files in ~/Desktop/Second Take mock 13.11.2026/.
Findings: (1) the Live and REC view always opens on the BenQ (Watch.swift screen = NSScreen.screens.first). (2) a second take of a shot gets the name "... take 2.mov" and an existing file gets an "mb_<date>" prefix; takes.json keeps entries of earlier runs. (3) the recorded duration is the time between REC and STOP, not the clip length. (4) OBS media-source audio went silent after about two file switches (OBS side, not the app): fixed by creating a fresh media input per take.

## Fix log (the app's one maintainer)
- v13 (installed v14+): AGAIN no longer records (readies the next take, live picture), dryRun on /record and /again, /again /record /record/stop answer 200, bad /shot input 400. Verified 13.11.2026 20:30.
- v14: /status has clipVolume and ducked; ducking under :8837 speech verified (volume 0 while speaking, 1 after).
- v15: Settings picker + POST /screen {"name"|"index"} choose the display of the full-screen view (default the menu-bar display = BenQ; verified: Built-in Retina chosen, /live frame [2560,458,1512,982], reset to BenQ); POST /takes/delete {path, trash?}; AGAIN removes the discarded take from takes.json (file stays in ~/Movies); takes.json drops entries whose file moved or is gone; take numbers use the first free number (no collision with listed takes or files in ~/Movies). Installed 20:50.
