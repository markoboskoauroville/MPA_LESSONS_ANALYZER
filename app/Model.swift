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

struct Analysis: Equatable {
    var title = ""
    var lesson = ""
    var sections: [LessonSection] = []
    var remarks: [Remark] = []
}

enum Item: Identifiable {
    case header(Int, LessonSection)
    case row(Seg, [Remark])
    var id: String {
        switch self {
        case .header(let i, _): return "h\(i)"
        case .row(let s, _): return "r\(s.id)"
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

func buildItems(_ segs: [Seg], _ a: Analysis) -> [Item] {
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
        while si < a.sections.count && a.sections[si].start < s.end {
            items.append(.header(si, a.sections[si])); si += 1
        }
        items.append(.row(s, assigned[i]))
    }
    while si < a.sections.count { items.append(.header(si, a.sections[si])); si += 1 }
    return items
}
