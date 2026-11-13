// drumsplit: offline voice/drums splitter and drum-stroke detector (MPA Lessons Analyzer (Mantra), v3).
// Runs the Audio Unit Supertone Clear (aufx cler Sptn) in AVAudioEngine offline manual rendering, faster than real time.
//   drumsplit <video|audio> [--out dir]      writes <name>.voice.wav, <name>.drums.wav, <name>.strokes.json
//   drumsplit --list-params                  prints the AU parameter tree and exits
// Compiled only by GitHub Actions (build.sh), never on the Mac.
import Foundation
import AVFoundation
import AudioToolbox
import Accelerate

setvbuf(stdout, nil, _IOLBF, 0)
func say(_ s: String) { print(s) }
func fail(_ s: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("drumsplit: " + s + "\n").utf8)); exit(code)
}
func fourCC(_ s: String) -> OSType { var r: UInt32 = 0; for u in s.utf8.prefix(4) { r = (r << 8) | UInt32(u) }; return r }
func now() -> Double { Date().timeIntervalSince1970 }

// MARK: arguments
var input: String? = nil
var outDir: String? = nil
var listParams = false
var detectOnly = false
var overrides: [(String, String)] = []
var block = 16384
var autoAlign = true
var lsGain = false
var noDefaults = false
var floatOut = false
var preset: String? = nil
var strokesOnSource = false
var sens = 1.0
var quietDb = 18.0
var auType = "aufx", auSub = "cler", auMfr = "Sptn"
let argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
func nextArg() -> String { ai += 1; if ai >= argv.count { fail("missing value after \(argv[ai - 1])", 2) }; return argv[ai] }
while ai < argv.count {
    let a = argv[ai]
    switch a {
    case "--out": outDir = nextArg()
    case "--list-params": listParams = true
    case "--param":
        let kv = nextArg()
        guard let eq = kv.firstIndex(of: "=") else { fail("--param needs name=value", 2) }
        overrides.append((String(kv[kv.startIndex..<eq]), String(kv[kv.index(after: eq)...])))
    case "--block": block = Int(nextArg()) ?? 16384
    case "--no-align": autoAlign = false
    case "--ls-gain": lsGain = true
    case "--no-defaults": noDefaults = true
    case "--float": floatOut = true
    case "--detect-only": detectOnly = true
    case "--preset": preset = nextArg()
    case "--strokes-on-source": strokesOnSource = true
    case "--sens": sens = Double(nextArg()) ?? 1.0
    case "--quiet-db": quietDb = Double(nextArg()) ?? 18.0
    case "--au":
        let p = nextArg().split(separator: "/").map(String.init)
        if p.count == 3 { auType = p[0]; auSub = p[1]; auMfr = p[2] } else { fail("--au type/sub/mfr, e.g. aufx/cler/Sptn", 2) }
    case "-h", "--help":
        say("""
        drumsplit <video|audio> [--out dir] [--param name=value]... [--list-params]
          writes <name>.voice.wav, <name>.drums.wav, <name>.strokes.json (default: next to the source)
          --list-params   print the Audio Unit parameter tree and exit
          --param n=v     set an AU parameter by name (or identifier); v a number, min, max or a value string
          --no-defaults   do not apply the built-in "voice only" settings
          --no-align      do not correct a residual delay found by cross-correlation
          --ls-gain       drums = source - g*voice with g fitted per 0.5 s block (default g = 1)
          --block N       render block in frames (default 16384)
          --float         write 32-bit float WAVs (default 24-bit)
          --detect-only   treat the input as a drums track: only write strokes.json
          --preset n      load a factory preset of the plug-in (number or name) before the parameters
          --strokes-on-source  detect strokes on the original audio, not on drums.wav (when the plug-in leaves the drums in the voice)
          --sens x        stroke detector sensitivity (default 1, higher = more strokes)
          --quiet-db x    strokes more than x dB below the loud strokes are K (default 18)
          --au t/s/m      other Audio Unit, default aufx/cler/Sptn
        """); exit(0)
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)", 2) }
        input = a
    }
    ai += 1
}
if input == nil && !listParams { fail("usage: drumsplit <video|audio> [--out dir] | --list-params", 2) }

// MARK: Audio Unit
func loadAU() -> AVAudioUnit {
    var desc = AudioComponentDescription(componentType: fourCC(auType), componentSubType: fourCC(auSub),
                                         componentManufacturer: fourCC(auMfr), componentFlags: 0, componentFlagsMask: 0)
    let comps = AVAudioUnitComponentManager.shared().components(matching: desc)
    if comps.isEmpty {
        say("Audio Unit \(auType)/\(auSub)/\(auMfr) not found. Installed effects with Clear in the name:")
        let any = AVAudioUnitComponentManager.shared().components(passingTest: { c, _ in c.name.lowercased().contains("clear") })
        for c in any { say("  \(c.manufacturerName): \(c.name)  \(c.audioComponentDescription.componentType)/\(c.audioComponentDescription.componentSubType)") }
        fail("Audio Unit not found", 3)
    }
    let c0 = comps[0]
    say("Audio Unit: \(c0.manufacturerName): \(c0.name) v\(c0.versionString) (\(c0.hasMIDIInput ? "midi" : "audio"), sandboxSafe=\(c0.isSandboxSafe))")
    var unit: AVAudioUnit? = nil
    var err: Error? = nil
    var done = false
    desc.componentFlags = 0
    AVAudioUnit.instantiate(with: desc, options: []) { u, e in unit = u; err = e; done = true }
    let t0 = now()
    while !done && now() - t0 < 60 { RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    guard let u = unit else { fail("the Audio Unit refused to load from a command-line process: \(err.map { "\($0)" } ?? (done ? "no unit returned" : "timeout after 60 s"))", 4) }
    return u
}

func walk(_ node: AUParameterNode, _ depth: Int) {
    let pad = String(repeating: "  ", count: depth)
    if let g = node as? AUParameterGroup {
        say("\(pad)[group] \(g.displayName) (\(g.identifier))")
        for c in g.children { walk(c, depth + 1) }
    } else if let p = node as? AUParameter {
        var s = "\(pad)\(p.displayName)  id=\(p.identifier) addr=\(p.address) range=\(p.minValue)...\(p.maxValue) value=\(p.value) unit=\(p.unit.rawValue)"
        if let vs = p.valueStrings, !vs.isEmpty { s += " values=\(vs)" }
        say(s)
    }
}

func printTree(_ u: AVAudioUnit) {
    let au = u.auAudioUnit
    say("latency=\(au.latency) s  tailTime=\(au.tailTime) s  maxFrames=\(au.maximumFramesToRender)")
    say("channelCapabilities=\(au.channelCapabilities ?? [])")
    if let pre = au.factoryPresets, !pre.isEmpty { say("factory presets: " + pre.map { "\($0.number)=\($0.name)" }.joined(separator: ", ")) }
    if let tree = au.parameterTree {
        say("parameter tree (\(tree.allParameters.count) parameters):")
        for c in tree.children { walk(c, 1) }
    } else { say("this Audio Unit has no parameter tree") }
}

@discardableResult
func setParam(_ params: [AUParameter], _ name: String, _ val: String) -> Bool {
    let key = name.lowercased()
    let p = params.first(where: { $0.displayName.lowercased() == key || $0.identifier.lowercased() == key })
        ?? params.first(where: { $0.displayName.lowercased().contains(key) || $0.identifier.lowercased().contains(key) })
    guard let q = p else { say("  parameter not found: \(name)"); return false }
    var v: Float
    if val == "max" { v = q.maxValue } else if val == "min" { v = q.minValue }
    else if let f = Float(val) { v = f }
    else if let vs = q.valueStrings, let ix = vs.firstIndex(where: { $0.lowercased() == val.lowercased() }) { v = q.minValue + Float(ix) }
    else { say("  cannot read value \(val) for \(q.displayName)"); return false }
    v = min(max(v, q.minValue), q.maxValue)
    q.value = v
    say("  set \(q.displayName) = \(q.value)")
    return true
}

/// Guessed "voice only" setting from the parameter names; refined once the real tree is known (--list-params).
func applyVoiceOnlyDefaults(_ params: [AUParameter]) {
    // Supertone Clear v1.1.1: "Voice Solo" plays only the voice component (tree read on 13.11.2026).
    if params.contains(where: { $0.displayName.lowercased() == "voice solo" }) { setParam(params, "voice solo", "1"); return }
    for p in params {
        let n = (p.displayName + " " + p.identifier).lowercased()
        if n.contains("bypass") { setParam(params, p.identifier, "min") }
        else if n.contains("mix") || n.contains("wet") { setParam(params, p.identifier, "max") }
        else if ["noise", "reverb", "ambien", "background", "reduction", "reduce", "amount", "strength", "intensity", "clear"].contains(where: { n.contains($0) }) {
            setParam(params, p.identifier, "max")
        }
    }
}

let unit = loadAU()
if listParams { printTree(unit); if input == nil { exit(0) } }

// MARK: decode
let fm = FileManager.default
guard let inPath0 = input else { exit(0) }
let inPath = (inPath0 as NSString).expandingTildeInPath
guard fm.fileExists(atPath: inPath) else { fail("file not found: \(inPath)") }
let inURL = URL(fileURLWithPath: inPath)
let stem = inURL.deletingPathExtension().lastPathComponent
let outFolder = URL(fileURLWithPath: outDir.map { ($0 as NSString).expandingTildeInPath } ?? inURL.deletingLastPathComponent().path)
try? fm.createDirectory(at: outFolder, withIntermediateDirectories: true)
let voiceURL = outFolder.appendingPathComponent(stem + ".voice.wav")
let drumsURL = outFolder.appendingPathComponent(stem + ".drums.wav")
let strokesURL = outFolder.appendingPathComponent(stem + ".strokes.json")
let SR = 48000.0

func decodeToWav() -> URL {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("drumsplit-\(getpid()).wav")
    let ff = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"].first { fm.isExecutableFile(atPath: $0) }
    guard let f = ff else { fail("ffmpeg not found (/opt/homebrew/bin/ffmpeg)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: f)
    p.arguments = ["-nostdin", "-y", "-v", "error", "-i", inPath, "-vn", "-ac", "2", "-ar", "48000", "-c:a", "pcm_f32le", tmp.path]
    do { try p.run() } catch { fail("ffmpeg did not start: \(error)") }
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("ffmpeg failed (\(p.terminationStatus)) on \(inPath)") }
    return tmp
}

let wallStart = now()
say("decoding \(inURL.lastPathComponent)")
let wav = decodeToWav()
defer { try? fm.removeItem(at: wav) }
let file: AVAudioFile
do { file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { fail("cannot read decoded audio: \(error)") }
let N = Int(file.length)
let seconds = Double(N) / SR
say(String(format: "audio: %.1f s (%d:%02d), 48 kHz stereo, decoded in %.1f s", seconds, Int(seconds) / 60, Int(seconds) % 60, now() - wallStart))

// MARK: WAV output
func writeWav(_ url: URL, _ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>) {
    var settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: SR, AVNumberOfChannelsKey: 2,
                                   AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    if floatOut { settings[AVLinearPCMBitDepthKey] = 32; settings[AVLinearPCMIsFloatKey] = true }
    else { settings[AVLinearPCMBitDepthKey] = 24; settings[AVLinearPCMIsFloatKey] = false }
    try? fm.removeItem(at: url)
    guard let f = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { fail("cannot write \(url.path)") }
    let chunk = 1 << 16
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(chunk))!
    var pos = 0
    while pos < N {
        let n = min(chunk, N - pos)
        memcpy(b.floatChannelData![0], l + pos, n * 4)
        memcpy(b.floatChannelData![1], r + pos, n * 4)
        b.frameLength = AVAudioFrameCount(n)
        do { try f.write(from: b) } catch { fail("write failed: \(error)") }
        pos += n
    }
}

// MARK: stroke detector
struct Stroke { var t: Double; var db: Double; var cls: String }

func percentile(_ a: [Double], _ p: Double) -> Double {
    if a.isEmpty { return 0 }
    let s = a.sorted()
    return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}

func detectStrokes(_ m: UnsafeMutablePointer<Float>, _ n: Int) -> (strokes: [Stroke], tempo: [[String: Any]]) {
    let nfft = 1024, hop = 240
    let log2n = vDSP_Length(10)
    guard n > nfft * 2, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], []) }
    defer { vDSP_destroy_fftsetup(setup) }
    let F = (n - nfft) / hop + 1
    var win = [Float](repeating: 0, count: nfft)
    vDSP_hann_window(&win, vDSP_Length(nfft), Int32(vDSP_HANN_NORM))
    var flux = [Float](repeating: 0, count: F)
    var prev = [Float](repeating: 0, count: nfft / 2)
    var buf = [Float](repeating: 0, count: nfft)
    var re = [Float](repeating: 0, count: nfft / 2), im = [Float](repeating: 0, count: nfft / 2)
    var mag = [Float](repeating: 0, count: nfft / 2)
    let kmax = min(nfft / 2 - 1, Int(10000.0 / (SR / Double(nfft))))
    for f in 0..<F {
        vDSP_vmul(m + f * hop, 1, win, 1, &buf, 1, vDSP_Length(nfft))
        buf.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nfft / 2) { cp in
                re.withUnsafeMutableBufferPointer { rp in
                    im.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(nfft / 2))
                        vDSP_fft_zrip(setup, &sc, 1, log2n, FFTDirection(FFT_FORWARD))
                        sc.imagp[0] = 0
                        vDSP_zvabs(&sc, 1, &mag, 1, vDSP_Length(nfft / 2))
                    }
                }
            }
        }
        var s: Float = 0
        if kmax >= 1 {
            for k in 1...kmax {
                let lm = log1p(mag[k] * 0.1)
                let d = lm - prev[k]
                if d > 0 { s += d }
                prev[k] = lm
            }
        }
        flux[f] = f == 0 ? 0 : s
    }
    // adaptive threshold: local mean + k * local std (+- 0.25 s), plus a small global floor
    let W = 50
    var c1 = [Double](repeating: 0, count: F + 1), c2 = [Double](repeating: 0, count: F + 1)
    for i in 0..<F { let v = Double(flux[i]); c1[i + 1] = c1[i] + v; c2[i + 1] = c2[i] + v * v }
    let p99 = percentile(flux.map { Double($0) }, 0.99)
    let kStd = 1.6 / sens
    let floorT = 0.04 * p99 / sens
    var cands: [(Int, Double)] = []
    let peakR = 3
    for i in peakR..<(F - peakR) {
        let lo = max(0, i - W), hi = min(F, i + W + 1)
        let cnt = Double(hi - lo)
        let mean = (c1[hi] - c1[lo]) / cnt
        let std = max(0, (c2[hi] - c2[lo]) / cnt - mean * mean).squareRoot()
        let v = Double(flux[i])
        if v <= mean + kStd * std + floorT { continue }
        var isMax = true
        for j in (i - peakR)...(i + peakR) where flux[j] > flux[i] { isMax = false; break }
        if isMax { cands.append((i, v)) }
    }
    // minimum gap 40 ms: keep the stronger
    var kept: [(Int, Double)] = []
    let gapFrames = Int(0.040 * SR) / hop + 1
    for c in cands {
        if let l = kept.last, c.0 - l.0 < gapFrames {
            if c.1 > l.1 { kept[kept.count - 1] = c }
        } else { kept.append(c) }
    }
    // per stroke: time refinement, strength, class
    let fft4 = 4096, l4 = vDSP_Length(12)
    guard let setup4 = vDSP_create_fftsetup(l4, FFTRadix(kFFTRadix2)) else { return ([], []) }
    defer { vDSP_destroy_fftsetup(setup4) }
    var win4 = [Float](repeating: 0, count: fft4)
    vDSP_hann_window(&win4, vDSP_Length(fft4), Int32(vDSP_HANN_NORM))
    var raw: [(t: Double, db: Double, low: Double, hi: Double, cen: Double)] = []
    var b4 = [Float](repeating: 0, count: fft4)
    var r4 = [Float](repeating: 0, count: fft4 / 2), i4 = [Float](repeating: 0, count: fft4 / 2), m4 = [Float](repeating: 0, count: fft4 / 2)
    for (fi, _) in kept {
        let s0 = max(0, fi * hop - hop)
        let s1 = min(n, s0 + 1400)
        var pk: Float = 0
        for j in s0..<s1 { pk = max(pk, abs(m[j])) }
        var on = s0
        for j in s0..<s1 where abs(m[j]) > 0.25 * pk { on = j; break }
        var pk2: Float = 0
        for j in on..<min(n, on + 1440) { pk2 = max(pk2, abs(m[j])) }
        let db = 20 * log10(Double(max(pk2, 1e-9)))
        // band energies over the 85 ms from the onset
        for j in 0..<fft4 { b4[j] = on + j < n ? m[on + j] * win4[j] : 0 }
        var lowE = 0.0, midE = 0.0, hiE = 0.0, cenNum = 0.0, tot = 0.0
        b4.withUnsafeBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fft4 / 2) { cp in
                r4.withUnsafeMutableBufferPointer { rp in
                    i4.withUnsafeMutableBufferPointer { ip in
                        var sc = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &sc, 1, vDSP_Length(fft4 / 2))
                        vDSP_fft_zrip(setup4, &sc, 1, l4, FFTDirection(FFT_FORWARD))
                        sc.imagp[0] = 0
                        vDSP_zvabs(&sc, 1, &m4, 1, vDSP_Length(fft4 / 2))
                    }
                }
            }
        }
        let bw = SR / Double(fft4)
        for k in 2..<(fft4 / 2) {
            let f = Double(k) * bw
            let e = Double(m4[k]) * Double(m4[k])
            tot += e; cenNum += e * f
            if f < 200 { lowE += e } else if f < 2500 { midE += e } else { hiE += e }
        }
        let t0 = max(tot, 1e-20)
        raw.append((Double(on) / SR, db, lowE / t0, hiE / t0, cenNum / t0))
        _ = midE
    }
    guard !raw.isEmpty else { return ([], []) }
    let maxDb = raw.map { $0.db }.max()!
    let gated = raw.filter { $0.db > maxDb - 50 }
    let ref = percentile(gated.map { $0.db }, 0.90)
    var strokes: [Stroke] = []
    for r in gated {
        let rel = r.db - ref
        var cls: String
        if rel < -(quietDb + 12) { cls = "-" }
        else if rel < -quietDb { cls = "K" }
        else if r.low > 0.5 { cls = "D" }
        else if r.cen >= 2000 || r.hi > 0.3 { cls = "T" }
        else { cls = "P" }
        strokes.append(Stroke(t: (r.t * 1000).rounded() / 1000, db: (r.db * 10).rounded() / 10, cls: cls))
    }
    // tempo per 10 s window: autocorrelation of the half-wave flux, lags 0.33..1.0 s (60..180 bpm)
    var tempo: [[String: Any]] = []
    let fps = SR / Double(hop)
    var w0 = 0.0
    let total = Double(n) / SR
    while w0 < total {
        let w1 = min(total, w0 + 10)
        let cnt = strokes.filter { $0.t >= w0 && $0.t < w1 }.count
        if cnt >= 4 {
            let a = Int(w0 * fps), b = min(F, Int(w1 * fps))
            if b - a > Int(2.5 * fps) {
                var x = [Float](repeating: 0, count: b - a)
                var mean: Float = 0
                vDSP_meanv(Array(flux[a..<b]), 1, &mean, vDSP_Length(b - a))
                for j in 0..<(b - a) { x[j] = max(0, flux[a + j] - mean) }
                let lagLo = Int(0.33 * fps), lagHi = min(Int(1.0 * fps), b - a - 8)
                var best = -1.0, bestLag = 0
                var acf = [Double](repeating: 0, count: lagHi + 2)
                if lagHi > lagLo {
                    for l in lagLo...lagHi {
                        var d: Float = 0
                        vDSP_dotpr(x, 1, Array(x[l...]), 1, &d, vDSP_Length(x.count - l))
                        acf[l] = Double(d) / Double(x.count - l)
                        if acf[l] > best { best = acf[l]; bestLag = l }
                    }
                    var lagF = Double(bestLag)
                    if bestLag > lagLo && bestLag < lagHi {
                        let y0 = acf[bestLag - 1], y1 = acf[bestLag], y2 = acf[bestLag + 1]
                        let den = y0 - 2 * y1 + y2
                        if den != 0 { lagF += 0.5 * (y0 - y2) / den }
                    }
                    if best > 0 { tempo.append(["start": w0, "end": w1, "bpm": ((60.0 * fps / lagF) * 10).rounded() / 10]) }
                }
            }
        }
        w0 += 10
    }
    return (strokes, tempo)
}

func writeStrokes(_ strokes: [Stroke], _ tempo: [[String: Any]]) {
    let o: [String: Any] = ["source": inURL.lastPathComponent, "duration": (seconds * 10).rounded() / 10,
                            "strokes": strokes.map { ["t": $0.t, "db": $0.db, "cls": $0.cls] as [String: Any] }, "tempo": tempo]
    if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? d.write(to: strokesURL) }
    var cc: [String: Int] = [:]
    for s in strokes { cc[s.cls, default: 0] += 1 }
    say("strokes: \(strokes.count) " + cc.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "  tempo windows: \(tempo.count)")
    say("wrote \(strokesURL.path)")
}

// MARK: read the source into memory (with room for the plug-in latency)
let au0 = unit.auAudioUnit
let latFrames = Int((au0.latency * SR).rounded())
let tailFrames = Int(min(max(au0.tailTime, 0), 1.0) * SR)
let pad = latFrames + tailFrames + 8192
guard let big = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(N + pad)) else { fail("out of memory for the source") }
do { try file.read(into: big) } catch { fail("read failed: \(error)") }
let srcL = big.floatChannelData![0], srcR = big.floatChannelData![1]
memset(srcL + N, 0, pad * 4); memset(srcR + N, 0, pad * 4)
big.frameLength = AVAudioFrameCount(N + pad)

if detectOnly {
    let m = UnsafeMutablePointer<Float>.allocate(capacity: N)
    for i in 0..<N { m[i] = 0.5 * (srcL[i] + srcR[i]) }
    let t0 = now()
    let (st, tp) = detectStrokes(m, N)
    say(String(format: "detected in %.1f s", now() - t0))
    writeStrokes(st, tp)
    exit(0)
}

// MARK: offline render through the Audio Unit
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SR, channels: 2, interleaved: false)!
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
engine.attach(player); engine.attach(unit)
engine.connect(player, to: unit, format: fmt)
engine.connect(unit, to: engine.mainMixerNode, format: fmt)
do { try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: AVAudioFrameCount(block)) }
catch { fail("offline rendering mode failed: \(error)") }
do { try engine.start() } catch { fail("engine start failed: \(error)") }

let allParams = unit.auAudioUnit.parameterTree?.allParameters ?? []
if let pr = preset {
    let list = unit.auAudioUnit.factoryPresets ?? []
    if let m = list.first(where: { String($0.number) == pr || $0.name.lowercased().contains(pr.lowercased()) }) { unit.auAudioUnit.currentPreset = m; say("preset: \(m.number) \(m.name)") }
    else { say("preset not found: \(pr)") }
}
if !noDefaults { say("voice-only defaults:"); applyVoiceOnlyDefaults(allParams) }
if !overrides.isEmpty { say("overrides:"); for (k, v) in overrides { setParam(allParams, k, v) } }
say("plug-in latency \(latFrames) frames (\(String(format: "%.1f", Double(latFrames) / SR * 1000)) ms), tail \(tailFrames) frames, block \(block)")

player.scheduleBuffer(big, at: nil, options: [], completionHandler: nil)
player.play()

let vL = UnsafeMutablePointer<Float>.allocate(capacity: N + 16), vR = UnsafeMutablePointer<Float>.allocate(capacity: N + 16)
memset(vL, 0, (N + 16) * 4); memset(vR, 0, (N + 16) * 4)
guard let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount) else { fail("render buffer") }
let need = latFrames + N
var produced = 0
var retries = 0
var nextPct = 10
let rStart = now()
while produced < need {
    let n = min(block, need - produced)
    let st: AVAudioEngineManualRenderingStatus
    do { st = try engine.renderOffline(AVAudioFrameCount(n), to: rb) } catch { fail("render failed at \(produced): \(error)") }
    switch st {
    case .success:
        let fl = Int(rb.frameLength)
        let g0 = produced, g1 = produced + fl
        let lo = max(g0, latFrames), hi = min(g1, latFrames + N)
        if hi > lo {
            memcpy(vL + (lo - latFrames), rb.floatChannelData![0] + (lo - g0), (hi - lo) * 4)
            memcpy(vR + (lo - latFrames), rb.floatChannelData![1] + (lo - g0), (hi - lo) * 4)
        }
        produced += fl
        retries = 0
        let pct = produced * 100 / need
        if pct >= nextPct {
            let el = now() - rStart
            say(String(format: "render %3d %%  x%.1f real time", pct, Double(produced) / SR / max(el, 1e-6)))
            nextPct = pct + 10
        }
    case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
        retries += 1
        if retries > 2000 { fail("render stalled at \(produced) frames (\(st))") }
        usleep(1000)
    case .error:
        fail("render error at \(produced) frames")
    @unknown default:
        fail("render status unknown")
    }
}
let renderSecs = now() - rStart
engine.stop()

// MARK: alignment check by cross-correlation (residual delay after the plug-in latency)
func shiftVoice(_ lag: Int) {
    // lag > 0: voice[i + lag] belongs to source[i]
    if lag > 0 {
        memmove(vL, vL + lag, (N - lag) * 4); memmove(vR, vR + lag, (N - lag) * 4)
        memset(vL + (N - lag), 0, lag * 4); memset(vR + (N - lag), 0, lag * 4)
    } else if lag < 0 {
        let k = -lag
        memmove(vL + k, vL, (N - k) * 4); memmove(vR + k, vR, (N - k) * 4)
        memset(vL, 0, k * 4); memset(vR, 0, k * 4)
    }
}

func residualLag() -> (lag: Int, peak: Float, zero: Float)? {
    let margin = 24000
    let winMax = 20 * 48000
    guard N > 2 * margin + 3 * 48000 else { return nil }
    let winLen = min(winMax, ((N - 2 * margin) / 8) * 8)
    // loudest window of the voice, 1 s blocks
    let nb = (N - 2 * margin) / 48000
    var e = [Double](repeating: 0, count: nb + 1)
    for b in 0..<nb {
        var s: Float = 0
        vDSP_svesq(vL + margin + b * 48000, 1, &s, 48000)
        e[b + 1] = e[b] + Double(s)
    }
    let wb = winLen / 48000
    var bestB = 0, bestE = -1.0
    if nb >= wb { for b in 0...(nb - wb) where e[b + wb] - e[b] > bestE { bestE = e[b + wb] - e[b]; bestB = b } }
    let w0 = margin + bestB * 48000
    guard w0 + winLen + margin <= N else { return nil }
    let dn = winLen / 8, R = margin / 8
    var ds = [Float](repeating: 0, count: dn), dv = [Float](repeating: 0, count: dn + 2 * R + 1)
    for j in 0..<dn { var s: Float = 0; for k in 0..<8 { s += srcL[w0 + j * 8 + k] + srcR[w0 + j * 8 + k] }; ds[j] = s }
    for j in 0..<(dn + 2 * R) { var s: Float = 0; for k in 0..<8 { s += vL[w0 - margin + j * 8 + k] + vR[w0 - margin + j * 8 + k] }; dv[j] = s }
    var best: Float = -.infinity, bl = 0
    var zero: Float = 0
    for l in -R...R {
        var d: Float = 0
        dv.withUnsafeBufferPointer { vp in vDSP_dotpr(ds, 1, vp.baseAddress! + (R + l), 1, &d, vDSP_Length(dn)) }
        if l == 0 { zero = d }
        if d > best { best = d; bl = l }
    }
    // refine at full rate
    let L0 = bl * 8
    let fl = min(winLen, 240000)
    var bestF: Float = -.infinity, bf = L0
    for L in (L0 - 8)...(L0 + 8) {
        guard w0 + L >= 0, w0 + L + fl <= N else { continue }
        var d: Float = 0
        vDSP_dotpr(srcL + w0, 1, vL + (w0 + L), 1, &d, vDSP_Length(fl))
        if d > bestF { bestF = d; bf = L }
    }
    return (bf, best, zero)
}

if let r = residualLag() {
    say(String(format: "alignment check: best lag %d samples (%.2f ms), correlation %.3g at lag, %.3g at zero", r.lag, Double(r.lag) / SR * 1000, r.peak, r.zero))
    if autoAlign && r.lag != 0 && abs(r.lag) <= 19200 && r.peak > 0 { shiftVoice(r.lag); say("voice shifted by \(-r.lag) samples to align with the source") }
} else { say("alignment check skipped (too short)") }

// MARK: drums = source - voice
let dL = UnsafeMutablePointer<Float>.allocate(capacity: N + 16), dR = UnsafeMutablePointer<Float>.allocate(capacity: N + 16)
vDSP_vsub(vL, 1, srcL, 1, dL, 1, vDSP_Length(N))
vDSP_vsub(vR, 1, srcR, 1, dR, 1, vDSP_Length(N))
if lsGain {
    let bs = 24000
    var pos = 0
    while pos < N {
        let n = min(bs, N - pos)
        var sv: Float = 0, vv: Float = 0, sv2: Float = 0, vv2: Float = 0
        vDSP_dotpr(srcL + pos, 1, vL + pos, 1, &sv, vDSP_Length(n)); vDSP_dotpr(vL + pos, 1, vL + pos, 1, &vv, vDSP_Length(n))
        vDSP_dotpr(srcR + pos, 1, vR + pos, 1, &sv2, vDSP_Length(n)); vDSP_dotpr(vR + pos, 1, vR + pos, 1, &vv2, vDSP_Length(n))
        var g = (vv + vv2) > 1e-9 ? (sv + sv2) / (vv + vv2) : 1
        g = min(max(g, 0), 1.5)
        var ng = -g
        vDSP_vsma(vL + pos, 1, &ng, srcL + pos, 1, dL + pos, 1, vDSP_Length(n))
        vDSP_vsma(vR + pos, 1, &ng, srcR + pos, 1, dR + pos, 1, vDSP_Length(n))
        pos += n
    }
    say("least-squares gain applied per 0.5 s")
}

writeWav(voiceURL, vL, vR); say("wrote \(voiceURL.path)")
writeWav(drumsURL, dL, dR); say("wrote \(drumsURL.path)")

// RMS report: whole file
func rmsDb(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> Double {
    var r: Float = 0; vDSP_rmsqv(p, 1, &r, vDSP_Length(n)); return 20 * log10(Double(max(r, 1e-9)))
}
say(String(format: "RMS dBFS: source %.1f  voice %.1f  drums %.1f", rmsDb(srcL, N), rmsDb(vL, N), rmsDb(dL, N)))

// MARK: strokes
let mono = UnsafeMutablePointer<Float>.allocate(capacity: N)
for i in 0..<N { mono[i] = strokesOnSource ? 0.5 * (srcL[i] + srcR[i]) : 0.5 * (dL[i] + dR[i]) }
let dt0 = now()
let (strokes, tempo) = detectStrokes(mono, N)
say(String(format: "stroke detection %.1f s", now() - dt0))
writeStrokes(strokes, tempo)

let wall = now() - wallStart
say(String(format: "done in %.1f s for %.1f s of audio: speed x%.1f real time overall (AU render only x%.1f)", wall, seconds, seconds / max(wall, 1e-6), seconds / max(renderSecs, 1e-6)))
