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
