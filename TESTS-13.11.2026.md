# Second Take tests, 13.11.2026 (tester session)

## Round 1, 19:31: installed Mac app = v8 (pid started 19:25), phone app = versionName 1
| Test | Result | Evidence |
|---|---|---|
| GET 127.0.0.1:8965/status | FAIL | connection refused; the process listens only on *:8966 (lsof). Same bug as fixed in v9 |
| LAN :8966/status | FAIL (old behaviour) | `{"error":"pair: a code is shown on the Mac screen..."}` , v8 still demands pairing; protocol says no codes |
| Phone offline state | PASS | red bar "NO ANSWER . 127.0.0.1:8965", OFFLINE, buttons dimmed |
| Newer builds | v12 is released on GitHub (18:30) but NOT installed; installed is v8. Waiting for install. |
