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
