# Lessons

1. MANTRA_VOICE /hear on a whole 46-minute WAV times out; v1 therefore leaves transcription to Voice to Text (Mantra), not to :8837.
2. BSD sed has no \b: use perl for word-boundary renames. A type named Section clashes with SwiftUI.Section.

3. SwiftUI VideoPlayer crashed at run time ("failed to demangle superclass of VideoPlayerView ... AVPlayerView"): v2 wraps AVKit AVPlayerView in an NSViewRepresentable and links AVKit/AVFoundation explicitly in build.sh.

4. Supertone Clear's AU reports latency 0 but its output is about 366 ms late: always cross-correlate voice against source and shift; do not trust AUAudioUnit.latency.
5. Clear (v1.1.1) treats a frame drum as voice: Voice Solo keeps the strokes. Do not promise "drums removed"; test the plug-in on the real excerpt first (per-second RMS of voice vs drums).
6. A portrait H.264 file in AVPlayerView showed only the QuickTime icon until the player item was ready: attach the view after AVPlayerItem.status == .readyToPlay, videoGravity .resizeAspect.
7. Voice to Text names its result after the sent file: <name>.voice.transcript.json; the app copies it to <name>.transcript.full.json.
8. The class file is AV1 + Opus in an mp4 (from the browser), not H.264/AAC: AVFoundation shows only the QuickTime icon. v5 checks isPlayable/isDecodable and plays an ffmpeg H.264+AAC copy cached in ~/Library/Caches/MPA Lessons Analyzer (same timeline). ffprobe the file before blaming the view.
9. A lesson-only transcript written by someone else ("lessonOnly": true, no "by":"app") is shown as it is and never overwritten; the app's own derived copy carries "by":"app". Whisper's hallucination lines (thank you for watching, subscribe, Amara) are dropped when deriving.

## 13.11.2026

- 13.11.2026: never fall back silently to another camera; show SONY NOT CONNECTED and answer 409 to RECORD, otherwise a take is shot with the wrong lens.
- 13.11.2026: a stale picture behind an error message looks like a working camera (v20); clear it.
- 13.11.2026: a rehearsal that is a script (tools/rehearsal_test, PASS/FAIL) finds more than reading code; keep it and rerun after every version.
- 13.11.2026: a macOS compile fix can hide in a device-format call: set the 4K format on the device after the preset (v18).
- 15.11.2026: the app sorted shots by number, so a reordered analysis.json was undone on load; the file's order is the order now (v24). Read the parser before reordering data.
- 15.11.2026: sonycam clicks at screen positions in Remote's window: any always-on-top window of ours over it would take the click. Let clicks through during the hand's click.
- 15.11.2026: "next" in SHOOT means KEEP and go on (it can keep a pending take); a Queen test of "next exercise" moved the current shot; put it back with POST /shot {"n"}.
- 15.11.2026: never show a copy of another app's window as the control surface: Marko could not click it ("disaster"). Bring the real app forward and move it away after.
- 15.11.2026: never full screen (borderless screen-saver-level windows included): Marko must always reach the menu bar, the Dock and other apps. Almost-maximize.
- 15.11.2026: an unlabelled AX button can still be located: Imaging Edge Remote's record button is AX "Video" (the big "Photo" beside it is the still shutter); dump AX frames with pyobjc before trusting a click offset.
- 15.11.2026: one Rectangle next-display right after `open -b` can miss (the app not in front yet): loop and read the display from macro win-list.
