import SwiftUI
import AVKit
import AppKit

struct StepButton: View {
    let n: Int
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
                Text(word).underline(hover && enabled)
            }
            .foregroundStyle(enabled ? Color.primary : Color.gray)
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

    var body: some View {
        VStack(spacing: 0) {
            topRow
            Divider()
            steps
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
                VideoPlayer(player: s.player).frame(height: 260)
                Divider()
            }
            TableView()
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    var topRow: some View {
        HStack(spacing: 12) {
            Text("MPA Lessons Analyzer (Mantra)").font(.headline)
            Text("v\(VERSION)").foregroundStyle(.secondary)
            Spacer()
            Button("Settings") { showSettings = true }.buttonStyle(.plain).foregroundStyle(.secondary)
            Button("OFF") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    var steps: some View {
        HStack(spacing: 28) {
            StepButton(n: 1, word: "Open", enabled: true) { s.chooseVideo() }
            Divider().frame(height: 20)
            StepButton(n: 2, word: s.busy ? "Stop" : "Transcribe", enabled: s.videoURL != nil) { s.transcribeOrStop() }
            Divider().frame(height: 20)
            StepButton(n: 3, word: "Analyze", enabled: !s.segs.isEmpty) { s.analyze() }
            Spacer()
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
                Cell(label: "SEGMENTS", value: "\(s.segs.count)")
                Cell(label: "LESSON", value: s.analysis.title.isEmpty ? "-" : (s.analysis.lesson.isEmpty ? s.analysis.title : "\(s.analysis.lesson): \(s.analysis.title)"))
                Cell(label: "API", value: s.port == 0 ? "-" : "127.0.0.1:\(s.port)")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}

struct TableView: View {
    @EnvironmentObject var s: Store
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text("Time").frame(width: 56, alignment: .leading)
                Text("Transcription").frame(maxWidth: .infinity, alignment: .leading)
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
                            case .row(let seg, let rem): RowView(seg: seg, remarks: rem, active: s.now >= seg.start && s.now < seg.end)
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
    let active: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Text(fmtTime(seg.start)).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .leading)
                Text(seg.text).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
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
            Spacer(minLength: 12)
            Divider()
            Text("© 2026 Mantra Productions").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, maxWidth: .infinity, minHeight: 260)
    }
}
