# Lessons

1. MANTRA_VOICE /hear on a whole 46-minute WAV times out; v1 therefore leaves transcription to Voice to Text (Mantra), not to :8837.
2. BSD sed has no \b: use perl for word-boundary renames. A type named Section clashes with SwiftUI.Section.

3. SwiftUI VideoPlayer crashed at run time ("failed to demangle superclass of VideoPlayerView ... AVPlayerView"): v2 wraps AVKit AVPlayerView in an NSViewRepresentable and links AVKit/AVFoundation explicitly in build.sh.
