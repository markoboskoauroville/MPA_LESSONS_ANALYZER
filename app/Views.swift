import SwiftUI
import AVKit
import AppKit

struct StepButton: View {
    let n: String
    let word: String
    let enabled: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text("\(n)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(enabled ? Color.orange : Color.gray.opacity(0.5), lineWidth: 1))
                    .scaleEffect(hover && enabled ? 1.15 : 1)
                Text(word).underline(hover && enabled).lineLimit(1).fixedSize()
            }
            .foregroundStyle(enabled ? Color.primary : Color.gray)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0; if $0 && enabled { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .accessibilityLabel(word)
    }
}

struct Cell: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Color.gray.opacity(0.4)).frame(height: 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ContentView: View {
    @EnvironmentObject var s: Store
    @State private var showSettings = false
    @ObservedObject private var shoot = Shoot.shared
    @ObservedObject private var ctl = Controller.shared

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Divider()
            steps
            if !shoot.finishSummary.isEmpty {
                Text(shoot.finishSummary).font(.callout).foregroundStyle(shoot.finishSummary.contains("PROBLEM") ? Color.red : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            cells
            Divider()
            if let e = Optional(s.error), !e.isEmpty {
                Text(e).foregroundStyle(.red).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            if s.videoURL != nil {
                HStack(spacing: 0) {
                    if s.playerReady { PlayerPane(player: s.player).frame(maxWidth: s.clips.isEmpty ? .infinity : 360) }
                    else { Text(s.playerNote.isEmpty ? "Loading the video..." : s.playerNote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(12).frame(maxWidth: .infinity) }
                    if !s.clips.isEmpty { Divider(); PlaylistView() }
                }
                .frame(height: 260)
                Divider()
            }
            if !s.shots.isEmpty { ShotsView(); Divider() }
            TableView()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $shoot.open) { ShootView().environmentObject(s) }
    }

    var topRow: some View {
        HStack(spacing: 12) {
            Text("MPA Lessons Analyzer (Mantra)").font(.headline)
            Text("v\(VERSION)").foregroundStyle(.secondary)
            Spacer()
            if let o = ctl.ownerName {
                Button("RELEASE \(o)") { ctl.release() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("The remote \(o) controls this app; release it so another remote can connect")
            }
            if Capture.permissionsMissing {
                Button("PERMISSIONS") { Capture.openPermissions() }.buttonStyle(.plain).foregroundStyle(Color.orange)
                    .help("Camera or microphone is not allowed yet: opens the switch in System Settings")
            }
            Button("Settings") { showSettings = true }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button("OFF") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    var steps: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 20) {
            StepButton(n: "1", word: "Open", enabled: true) { s.chooseVideo() }
            Divider().frame(height: 20)
            StepButton(n: "2a", word: s.busy ? "Stop" : "Split voice/drums", enabled: s.videoURL != nil) { s.splitOrStop() }
            Divider().frame(height: 20)
            StepButton(n: "2", word: s.busy ? "Stop" : "Transcribe", enabled: s.videoURL != nil) { s.transcribeOrStop() }
            Divider().frame(height: 20)
            StepButton(n: "3", word: "Analyze", enabled: !s.segs.isEmpty) { s.analyze() }
            Divider().frame(height: 20)
            StepButton(n: "4", word: "SHOOT", enabled: !s.shots.isEmpty) { Shoot.shared.begin() }
            Divider().frame(height: 20)
            StepButton(n: "5", word: shoot.finishRunning ? "Finishing..." : "FINISH", enabled: !s.shots.isEmpty && !shoot.finishRunning) { Shoot.shared.finishRun() }
            Spacer(minLength: 0)
        }
        HStack(spacing: 12) {
            Text("Language").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Picker("", selection: $s.pickLang) {
                ForEach(["en", "hr", "auto", "hi", "de", "es", "fr", "it", "ru"], id: \.self) { Text($0) }
            }
            .labelsHidden().frame(width: 80).help("Language of the transcription")
            Spacer()
            Picker("", selection: $s.lessonOnly) {
                Text("Lesson only").tag(true)
                Text("Full").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 200)
        }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    var cells: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 16) {
                Cell(label: "FILE", value: s.videoName.isEmpty ? "-" : s.videoName)
                Cell(label: "STATE", value: s.phase)
            }
            HStack(alignment: .top, spacing: 16) {
                Cell(label: "ELAPSED", value: s.busy ? fmtTime(s.elapsed) : "-")
                Cell(label: "SEGMENTS", value: s.shownSegs == s.segs.count ? "\(s.segs.count)" : "\(s.shownSegs) of \(s.segs.count)")
                Cell(label: "STROKES", value: s.strokes.isEmpty ? "-" : "\(s.strokes.count)")
                Cell(label: "LESSON", value: s.analysis.title.isEmpty ? "-" : (s.analysis.lesson.isEmpty ? s.analysis.title : "\(s.analysis.lesson): \(s.analysis.title)"))
                Cell(label: "API", value: s.port == 0 ? "-" : "127.0.0.1:\(s.port)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct PlaylistView: View {
    @EnvironmentObject var s: Store
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("PLAYLIST").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(s.clips.count) clips").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(s.playingAll ? "Stop" : "Play all") { s.playAllClips() }.buttonStyle(.plain).foregroundStyle(Color.orange)
                if s.playingClip != nil && !s.playingAll { Button("Stop") { s.stopPlayback() }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(s.clips) { c in
                        let on = s.playingClip == c.n
                        VStack(spacing: 0) {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(c.n)").font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 22, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.title).font(.system(size: 13, weight: on ? .bold : .regular)).fixedSize(horizontal: false, vertical: true)
                                    if !c.shoot.isEmpty { Text(c.shoot).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("\(fmtTime(c.start))-\(fmtTime(c.end))").font(.system(size: 11, design: .monospaced))
                                    Text(fmtTime(c.end - c.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5).padding(.horizontal, 12)
                            .background(on ? Color.accentColor.opacity(0.22) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture { s.playClip(c.n) }
                            Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ShotsView: View {
    @EnvironmentObject var s: Store
    @State private var open = true
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("SHOTS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(s.shots.count) videos to record").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(open ? "Hide" : "Show") { open.toggle() }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            if open {
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(s.shots) { sh in
                            VStack(spacing: 0) {
                                HStack(alignment: .top, spacing: 10) {
                                    Text("\(sh.n)").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(width: 24, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 10) {
                                            Text(sh.title).font(.system(size: 13, weight: .bold))
                                            if sh.secs > 0 { Text("\(Int(sh.secs)) sec").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                                            if !sh.code.isEmpty { Text(sh.code).font(.system(size: 11, design: .monospaced)).foregroundStyle(.teal) }
                                        }
                                        Text(sh.say).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    if !sh.watch.isEmpty {
                                        Button(s.watchingShot == sh.n ? "Stop" : "WATCH") { s.watchShot(sh.n) }
                                            .buttonStyle(.plain).foregroundStyle(Color.orange)
                                            .help("Plays clips \(sh.watch.map(String.init).joined(separator: ", ")) of the original video")
                                    }
                                }
                                .padding(.vertical, 6).padding(.horizontal, 16)
                                .background(s.watchingShot == sh.n ? Color.accentColor.opacity(0.22) : Color.clear)
                                Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

struct TableView: View {
    @EnvironmentObject var s: Store
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text("Time").frame(width: 56, alignment: .leading)
                Text("Transcription").frame(maxWidth: .infinity, alignment: .leading)
                Text("Strokes").frame(width: 110, alignment: .leading)
                Text("Remarks").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            if s.items.isEmpty {
                Text(s.videoURL == nil ? "Press 1 Open and choose the lesson video." : "Press 2 Transcribe.")
                    .foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(s.items) { item in
                            switch item {
                            case .header(_, let sec): SectionHeader(sec: sec)
                            case .row(let seg, let rem, let strokes, let cut): RowView(seg: seg, remarks: rem, strokes: strokes, cut: cut, active: s.now >= seg.start && s.now < seg.end)
                            }
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SectionHeader: View {
    let sec: LessonSection
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(sec.title)\(sec.code.isEmpty ? "" : "  [\(sec.code)]")  \(fmtTime(sec.start))-\(fmtTime(sec.end))")
                .font(.system(size: 14, weight: .bold))
            if !sec.what.isEmpty { Text(sec.what).font(.callout) }
            if !sec.shoot.isEmpty { Text("Shoot: \(sec.shoot)").font(.callout).foregroundStyle(.orange) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background(Color.orange.opacity(0.12))
        .padding(.top, 8)
    }
}

struct RowView: View {
    @EnvironmentObject var s: Store
    let seg: Seg
    let remarks: [Remark]
    let strokes: String
    let cut: String?
    let active: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(fmtTime(seg.start)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(seg.text).fixedSize(horizontal: false, vertical: true)
                    if let c = cut { Text("cut: \(c)").font(.system(size: 11)).italic().foregroundStyle(.secondary) }
                }
                .opacity(cut == nil ? 1 : 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(strokes).font(.system(size: 11, design: .monospaced)).foregroundStyle(.teal)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(remarks.enumerated()), id: \.offset) { _, r in
                        Text(r.text).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(active ? Color.accentColor.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { s.seek(seg.start) }
            Rectangle().fill(Color.gray.opacity(0.25)).frame(height: 1)
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage("exportFolder") private var exportFolder = (NSHomeDirectory() + "/Desktop")
    @AppStorage("voiceToTextPort") private var vtPort = 0
    @AppStorage("viewScreen") private var viewScreen = ""
    @AppStorage("capture") private var capture = "remote"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Settings").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).frame(width: 28, height: 28)
            }
            Divider()
            Text("EXPORT FOLDER").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(exportFolder).font(.system(size: 13, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Choose") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { exportFolder = u.path }
                }
                Button("Desktop") { exportFolder = NSHomeDirectory() + "/Desktop" }
            }
            Text("Finished lesson videos will be exported here by later versions.").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("VOICE TO TEXT (MANTRA) PORT").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("0 = find it automatically", value: $vtPort, format: .number.grouping(.never)).frame(width: 140)
            Text("Step 2 sends the video to Voice to Text (Mantra)'s local API.").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("FULL-SCREEN VIEW ON").font(.system(size: 10)).foregroundStyle(.secondary)
            Picker("", selection: $viewScreen) {
                Text("The display with the menu bar (the BenQ)").tag("")
                ForEach(WatchScreen.screenNames, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(maxWidth: 360)
            Text("RECORDING").font(.system(size: 10)).foregroundStyle(.secondary)
            Picker("", selection: $capture) {
                Text("On the Sony's card, by remote control (Imaging Edge Remote)").tag("remote")
                Text("Built-in webcam capture (the Sony over USB Streaming)").tag("webcam")
            }.labelsHidden().frame(maxWidth: 460)
            Text(capture == "webcam" ? "Camera and microphone are built in: the Sony (USB) first, the microphone of the Mac; POST /camera chooses others."
                 : "RECORD brings Imaging Edge Remote to the front on the MacBook screen (Rectangle, never full screen) and presses the Sony's record button (sonycam); after the take Remote goes to the other screen and Second Take comes back. The Mac's microphone writes a small guide track per take.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Divider()
            Text("© 2026 Mantra Productions").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: .infinity, minHeight: 260)
    }
}

struct PlayerPane: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.videoGravity = .resizeAspect
        v.controlsStyle = .inline
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
