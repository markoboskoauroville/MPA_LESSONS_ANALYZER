import Foundation

struct Seg: Identifiable, Equatable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
}

struct LessonSection: Equatable {
    var start: Double
    var end: Double
    var title: String
    var code: String
    var what: String
    var shoot: String
}

struct Remark: Equatable {
    var start: Double
    var end: Double
    var text: String
}

struct Clip: Equatable, Identifiable {
    var n: Int
    var title: String
    var start: Double
    var end: Double
    var code: String
    var shoot: String
    var id: Int { n }
}

struct Shot: Equatable, Identifiable {
    var n: Int
    var title: String
    var watch: [Int]
    var secs: Double
    var code: String
    var say: String
    var id: Int { n }
}

struct Cut: Equatable {
    var start: Double
    var end: Double
    var why: String
}

struct Stroke: Equatable {
    var t: Double
    var db: Double
    var cls: String
}

struct Analysis: Equatable {
    var cuts: [Cut] = []
    var clips: [Clip] = []
    var shots: [Shot] = []
    var title = ""
    var lesson = ""
    var sections: [LessonSection] = []
    var remarks: [Remark] = []
}

enum Item: Identifiable {
    case header(Int, LessonSection)
    case row(Seg, [Remark], String, String?)
    var id: String {
        switch self {
        case .header(let i, _): return "h\(i)"
        case .row(let s, _, _, _): return "r\(s.id)"
        }
    }
}

func num(_ v: Any?) -> Double {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let s = v as? String, let d = Double(s) { return d }
    return 0
}

func parseAnalysis(_ data: Data) -> Analysis? {
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var a = Analysis()
    a.title = o["title"] as? String ?? ""
    a.lesson = o["lesson"] as? String ?? ""
    for s in (o["sections"] as? [[String: Any]] ?? []) {
        a.sections.append(LessonSection(start: num(s["start"]), end: num(s["end"]),
                                  title: s["title"] as? String ?? "", code: s["code"] as? String ?? "",
                                  what: s["what"] as? String ?? "", shoot: s["shoot"] as? String ?? ""))
    }
    for r in (o["remarks"] as? [[String: Any]] ?? []) {
        let st = num(r["start"])
        let en = r["end"] == nil ? st : num(r["end"])
        a.remarks.append(Remark(start: st, end: en, text: r["text"] as? String ?? ""))
    }
    for c in (o["cut"] as? [[String: Any]] ?? []) {
        a.cuts.append(Cut(start: num(c["start"]), end: num(c["end"]), why: c["why"] as? String ?? ""))
    }
    for (i, c) in (o["clips"] as? [[String: Any]] ?? []).enumerated() {
        a.clips.append(Clip(n: c["n"] == nil ? i + 1 : Int(num(c["n"])), title: c["title"] as? String ?? "", start: num(c["start"]), end: num(c["end"]),
                            code: c["code"] as? String ?? "", shoot: c["shoot"] as? String ?? ""))
    }
    for (i, c) in (o["shots"] as? [[String: Any]] ?? []).enumerated() {
        a.shots.append(Shot(n: c["n"] == nil ? i + 1 : Int(num(c["n"])), title: c["title"] as? String ?? "",
                            watch: (c["watch"] as? [Any] ?? []).map { Int(num($0)) }, secs: num(c["secs"]),
                            code: c["code"] as? String ?? "", say: c["say"] as? String ?? ""))
    }
    // v24: the shots stay in the file's order (tools/plan_sync orders them by the MPA Academy lesson plan; the numbers stay the take names')
    a.clips.sort { $0.n < $1.n }
    a.cuts.sort { $0.start < $1.start }
    a.sections.sort { $0.start < $1.start }
    a.remarks.sort { $0.start < $1.start }
    return a
}

/// Words [{w,t,d}] (t = start, d = END, seconds) into sentences-ish segments.
func segmentWords(_ words: [[String: Any]]) -> [Seg] {
    var out: [Seg] = []
    var cur: [String] = []
    var st = 0.0, en = 0.0
    func flush() {
        if !cur.isEmpty {
            out.append(Seg(id: out.count, start: st, end: en, text: cur.joined(separator: " ")))
            cur = []
        }
    }
    for w in words {
        let t = num(w["t"]), d = num(w["d"])
        let word = (w["w"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if word.isEmpty { continue }
        if !cur.isEmpty && (t - en > 1.0 || en - st > 15) { flush() }
        if cur.isEmpty { st = t }
        cur.append(word)
        en = max(d, t)
        if let l = word.last, ".?!…".contains(l), cur.count >= 3 { flush() }
    }
    flush()
    return out
}

func fmtTime(_ t: Double) -> String {
    let s = Int(max(0, t))
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// A section whose whole range lies inside one cut range (e.g. "Setting up the classroom") is not part of the lesson.
func sectionIsCut(_ s: LessonSection, _ a: Analysis) -> Bool {
    a.cuts.contains { s.start >= $0.start - 1 && s.end <= $0.end + 1 }
}

func cutWhy(_ seg: Seg, _ a: Analysis) -> String? {
    for c in a.cuts where seg.start >= c.start && seg.start < c.end { return c.why.isEmpty ? "not the lesson" : c.why }
    return nil
}

/// "12 | D5 T4 K3": the strokes whose time falls in [start, end).
func strokeSummary(_ strokes: [Stroke], _ start: Double, _ end: Double) -> String {
    var lo = 0, hi = strokes.count
    while lo < hi { let m = (lo + hi) / 2; if strokes[m].t < start { lo = m + 1 } else { hi = m } }
    var counts: [String: Int] = [:]
    var n = 0
    var i = lo
    while i < strokes.count && strokes[i].t < end { counts[strokes[i].cls, default: 0] += 1; n += 1; i += 1 }
    if n == 0 { return "" }
    let order = ["D", "T", "P", "K", "-"]
    return "\(n)  " + order.compactMap { c in counts[c].map { "\(c)\($0)" } }.joined(separator: " ")
}

/// Whisper's known inventions on silence and music.
func isHallucination(_ text: String) -> Bool {
    let t = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " .,!?-–—…\"'\n\t"))
    if t.isEmpty { return true }
    let exact: Set<String> = ["you", "thank you", "thanks", "bye", "bye-bye", "bye bye", "okay", "ok", "so", "thank you very much"]
    if exact.contains(t) { return true }
    let parts = ["thank you for watching", "thanks for watching", "please subscribe", "like and subscribe", "subscribe to", "subtitles by", "subtitled by",
                 "amara.org", "amara", "transcribed by", "see you in the next video", "see you next time", "don't forget to subscribe",
                 "sous-titres", "untertitel", "www.", ".com/", "captions by", "closed captioning", "mbc news"]
    return parts.contains { t.contains($0) }
}

func buildItems(_ allSegs: [Seg], _ a: Analysis, _ strokes: [Stroke], lessonOnly: Bool, filterRows: Bool) -> [Item] {
    let segs = allSegs
    var assigned = [[Remark]](repeating: [], count: segs.count)
    if !segs.isEmpty {
        for r in a.remarks {
            var idx: Int? = segs.firstIndex { r.start < $0.end && max(r.end, r.start + 0.01) > $0.start }
            if idx == nil { idx = segs.lastIndex { $0.start <= r.start } ?? 0 }
            assigned[idx!].append(r)
        }
    }
    var items: [Item] = []
    var si = 0
    for (i, s) in segs.enumerated() {
        let why = cutWhy(s, a)
        if lessonOnly && filterRows && (why != nil || isHallucination(s.text)) { continue }
        while si < a.sections.count && a.sections[si].start < s.end {
            if !(lessonOnly && sectionIsCut(a.sections[si], a)) { items.append(.header(si, a.sections[si])) }
            si += 1
        }
        items.append(.row(s, assigned[i], strokeSummary(strokes, s.start, s.end), why))
    }
    while si < a.sections.count {
        if !(lessonOnly && sectionIsCut(a.sections[si], a)) { items.append(.header(si, a.sections[si])) }
        si += 1
    }
    return items
}
