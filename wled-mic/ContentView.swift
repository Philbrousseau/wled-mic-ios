// ContentView.swift
import SwiftUI
import AVFoundation
#if canImport(AVFAudio)
import AVFAudio
#endif
import Network
import Accelerate
import UIKit

// MARK: - Simple model
struct Target: Identifiable, Hashable {
    let id = UUID()
    var host: String   // IP or .local hostname
    var port: UInt16   // default 11988
}

// MARK: - Audio + Sender
final class ILLUMIDELSender: ObservableObject {
    // Targets
    @Published var targets: [Target] = [
        .init(host: "illumidel-mm.local", port: 11988)
    ]

    // UDP connections (one per target)
    private var conns: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "illumidel.sender.queue")

    // Audio / DSP
    private let engine = AVAudioEngine()
    private let frameSize = 1024
    private var hann: [Float] = []
    private var bandCenters: [Float] = Array(repeating: 0, count: 16)
    private var sampleRate: Double = 44100
    private var binEMA: [Float] = Array(repeating: 0, count: 16)
    private var frameCounter: UInt8 = 0
    private var lastUIUpdate: CFTimeInterval = 0

    // AGC → 0..255
    private var agcGain: Float = 1.0
    private let agcTarget: Float = 128.0
    private let agcAttack: Float = 0.20
    private let agcDecay:  Float = 0.02
    private let agcFloor:  Float = 0.05
    private let agcCeil:   Float = 50.0

    // Noise gate (hysteresis + hold)
    @Published var gateEnabled: Bool = true
    @Published var gateOpenThresh: Float = 22
    @Published var gateCloseThresh: Float = 12
    @Published var gateHoldMs: Int = 250
    private var gateOpen = false
    private var gateLastAboveMs: Double = 0

    // UI state
    @Published var isRunning = false
    @Published var statusText = "Idle"
    @Published var uiLevel: Float = 0
    @Published var uiBins: [Float] = Array(repeating: 0, count: 16)

    init() { buildHann() }

    // MARK: Target management
    func addTarget(host: String, port: UInt16 = 11988) {
        let t = Target(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
        guard !t.host.isEmpty else { return }
        targets.append(t)
        openConn(for: t)
    }

    func removeTargets(at offsets: IndexSet) {
        for i in offsets {
            let id = targets[i].id
            conns[id]?.cancel()
            conns.removeValue(forKey: id)
        }
        targets.remove(atOffsets: offsets)
    }

    private func openConn(for t: Target) {
        guard let p = NWEndpoint.Port(rawValue: t.port) else { return }
        let c = NWConnection(host: NWEndpoint.Host(t.host), port: p, using: .udp)
        c.start(queue: queue)
        conns[t.id] = c
    }

    private func rebuildConns() {
        conns.values.forEach { $0.cancel() }
        conns.removeAll()
        targets.forEach { openConn(for: $0) }
    }

    // MARK: Control
    func start() {
        guard !isRunning else { return }
        #if canImport(AVFAudio)
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission { [weak self] ok in
                DispatchQueue.main.async { ok ? self?.configureAndStart() : (self?.statusText = "Mic permission denied") }
            }
            return
        }
        #endif
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] ok in
            DispatchQueue.main.async { ok ? self?.configureAndStart() : (self?.statusText = "Mic permission denied") }
        }
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        statusText = "Stopped"
    }

    func sendTestPacket() {
        let bins = (0..<16).map { i -> UInt8 in
            let t = Float(i) / 15.0
            return UInt8(round(255.0 * sin(t * .pi)))
        }
        frameCounter &+= 1
        let pkt = buildV2(sampleRaw: 128, sampleSmth: 128, samplePeak: false,
                          frameCounter: frameCounter, fftBins: bins, zeroCrossingCount: 0,
                          FFT_Magnitude: 1000, FFT_MajorPeak: 440)
        fanout(pkt)
    }

    // MARK: Setup
    private func configureAndStart() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, options: [.mixWithOthers])
            try s.setMode(.measurement)
            try s.setActive(true)
        } catch {
            statusText = "AudioSession error: \(error.localizedDescription)"; return
        }

        rebuildConns()

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        sampleRate = format.sampleRate
        buildHann(); buildBands()

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(frameSize), format: format) { [weak self] buf, _ in
            self?.process(buffer: buf)
        }

        do {
            try engine.start()
            isRunning = true
            statusText = "Streaming to \(targets.count) device(s)…"
        } catch {
            statusText = "Engine error: \(error.localizedDescription)"
        }
    }

    // MARK: DSP
    private func buildHann() {
        var w = [Float](); w.reserveCapacity(frameSize)
        for i in 0..<frameSize {
            let v = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(i) / Double(frameSize))
            w.append(Float(v))
        }
        hann = w
    }

    private func buildBands() {
        let nyq = min(20000.0, sampleRate / 2.0)
        let f0 = 20.0, f1 = nyq
        bandCenters = (0..<16).map { i -> Float in
            let t0 = Double(i)/16.0, t1 = Double(i+1)/16.0
            let lo = f0 * pow(f1/f0, t0), hi = f0 * pow(f1/f0, t1)
            return Float(sqrt(lo * hi))
        }
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?.pointee else { return }
        let n = Int(buffer.frameLength); if n == 0 { return }

        var x = [Float](repeating: 0, count: frameSize)
        let count = min(n, frameSize)
        x.withUnsafeMutableBufferPointer { dst in dst.baseAddress!.update(from: ch, count: count) }
        vDSP.multiply(x, hann, result: &x)

        // RMS
        var sum: Float = 0; vDSP_svesq(x, 1, &sum, vDSP_Length(frameSize))
        let rms = sqrtf(sum / Float(frameSize))

        // AGC → 0..255
        let instRaw = min(255.0, max(0.0, rms * 255.0 * agcGain))
        let err = agcTarget - instRaw
        if err > 0 { agcGain = min(agcCeil,  agcGain * (1.0 + agcAttack * err/255.0)) }
        else       { agcGain = max(agcFloor, agcGain * (1.0 + agcDecay  * err/255.0)) }

        // Gate
        var gateNow = gateOpen
        let nowMs = CACurrentMediaTime() * 1000.0
        if gateEnabled {
            if instRaw >= gateOpenThresh { gateNow = true; gateLastAboveMs = nowMs }
            else if gateNow, instRaw < gateCloseThresh, (nowMs - gateLastAboveMs) > Double(gateHoldMs) { gateNow = false }
        } else { gateNow = true }
        gateOpen = gateNow

        // Peak
        // (simple, internal use only)
        // Zero crossings
        var zc: UInt16 = 0
        for i in 1..<count {
            let a = x[i-1], b = x[i]
            if (a < 0 && b >= 0) || (a > 0 && b <= 0) { zc &+= 1 }
        }

        // 16-band via Goertzel
        let (binsActual, maxMag, maxFreq) = geq16(samples: x, fs: Float(sampleRate))
        let magScaled = min(4096.0, max(0.0, Double(maxMag) * 600.0))

        // Smooth for UI
        let smthOpen: Float = 0.2 * instRaw + 0.8 * uiLevel * 255.0

        // Choose payload
        let instToSend: Float
        let smthToSend: Float
        let binsToSend: [UInt8]
        if gateOpen {
            instToSend = instRaw
            smthToSend = smthOpen
            binsToSend = binsActual
        } else {
            instToSend = 0; smthToSend = 0
            binsToSend = [UInt8](repeating: 0, count: 16)
        }

        // Build + send
        frameCounter &+= 1
        let pkt = buildV2(sampleRaw: instToSend, sampleSmth: smthToSend, samplePeak: false,
                          frameCounter: frameCounter, fftBins: binsToSend, zeroCrossingCount: zc,
                          FFT_Magnitude: Float(magScaled), FFT_MajorPeak: maxFreq)
        fanout(pkt)

        // UI ~20fps
        let now = CACurrentMediaTime()
        if now - lastUIUpdate > 0.05 {
            lastUIUpdate = now
            let level = min(1, max(0, instRaw / 255.0))
            let normBins = (gateOpen ? binsActual : [UInt8](repeating: 0, count: 16)).map { Float($0)/255.0 }
            DispatchQueue.main.async { [level, normBins] in
                self.uiLevel = level
                self.uiBins = normBins
            }
        }
    }

    private func geq16(samples x: [Float], fs: Float) -> ([UInt8], Float, Float) {
        var mags = [Float](repeating: 0, count: 16)
        let N = Float(x.count)
        var maxMag: Float = 0; var maxIdx = 0
        for (i, f) in bandCenters.enumerated() {
            let k = roundf(N * Float(f) / fs)
            let omega = 2.0 * Float.pi * k / N
            let coeff = 2.0 * cosf(omega)
            var s1: Float = 0, s2: Float = 0
            for n in 0..<x.count {
                let s = x[n] + coeff * s1 - s2
                s2 = s1; s1 = s
            }
            let mag2 = s2*s2 + s1*s1 - coeff*s1*s2
            let mag = sqrtf(max(0, mag2))
            mags[i] = mag
            if mag > maxMag { maxMag = mag; maxIdx = i }
        }
        var bins = [UInt8](repeating: 0, count: 16)
        let eps: Float = 1e-6
        for i in 0..<16 {
            let norm = (maxMag > eps) ? (mags[i]/maxMag) : 0
            binEMA[i] = 0.7*binEMA[i] + 0.3*norm
            bins[i] = UInt8(max(0, min(255, Int(round(binEMA[i]*255)))))
        }
        return (bins, maxMag, Float(bandCenters[maxIdx]))
    }

    // MARK: Packet + send
    private func buildV2(sampleRaw: Float, sampleSmth: Float, samplePeak: Bool, frameCounter: UInt8,
                         fftBins: [UInt8], zeroCrossingCount: UInt16, FFT_Magnitude: Float, FFT_MajorPeak: Float) -> Data {
        var p = [UInt8](repeating: 0, count: 44)
        let hdr = Array("00002".utf8)
        for i in 0..<hdr.count { p[i] = hdr[i] }
        p[5] = 0
        writeFloatLE(sampleRaw,  &p, 8)
        writeFloatLE(sampleSmth, &p, 12)
        p[16] = samplePeak ? 1 : 0
        p[17] = frameCounter
        for i in 0..<16 { p[18+i] = i < fftBins.count ? fftBins[i] : 0 }
        p[34] = UInt8(zeroCrossingCount & 0xFF)
        p[35] = UInt8((zeroCrossingCount >> 8) & 0xFF)
        writeFloatLE(FFT_Magnitude, &p, 36)
        writeFloatLE(FFT_MajorPeak, &p, 40)
        return Data(p)
    }

    private func writeFloatLE(_ f: Float, _ buf: inout [UInt8], _ off: Int) {
        let le = f.bitPattern.littleEndian
        buf[off+0] = UInt8(le & 0xFF)
        buf[off+1] = UInt8((le >> 8) & 0xFF)
        buf[off+2] = UInt8((le >> 16) & 0xFF)
        buf[off+3] = UInt8((le >> 24) & 0xFF)
    }

    private func fanout(_ pkt: Data) {
        if conns.count != targets.count { rebuildConns() } // lazy fix if list changed
        for (i, t) in targets.enumerated() {
            let id = targets[i].id
            if conns[id] == nil { openConn(for: t) }
            conns[id]?.send(content: pkt, completion: .idempotent)
        }
    }
}

// MARK: - Bars
struct BarView: View {
    var value: CGFloat
    var body: some View {
        GeometryReader { geo in
            let h = max(2, value * geo.size.height)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1)
                RoundedRectangle(cornerRadius: 3).frame(height: h)
            }
        }
    }
}

// MARK: - UI
struct ContentView: View {
    @StateObject private var sender = ILLUMIDELSender()
    @State private var keepAwake = false

    @State private var newHost = ""
    @State private var newPort = "11988"

    var body: some View {
        VStack(spacing: 14) {
            Text("Feed My ILLUMIDEL — iOS").font(.title.bold())

            // Add target
            HStack {
                TextField("illumidel-mm.local or 192.168.x.x", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                TextField("11988", text: $newPort)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                Button("Add") {
                    sender.addTarget(host: newHost, port: UInt16(newPort) ?? 11988)
                    newHost = ""; newPort = "11988"
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)

            // List of targets
            List {
                Section("Targets (\(sender.targets.count))") {
                    ForEach(sender.targets) { t in
                        HStack {
                            Text(t.host).bold().lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(t.port)").foregroundStyle(.secondary).monospaced()
                        }
                    }
                    .onDelete(perform: sender.removeTargets)
                }
            }
            .frame(height: 180)

            // Noise gate
            GroupBox("Noise Gate") {
                VStack(spacing: 8) {
                    Toggle("Enable", isOn: $sender.gateEnabled)
                    HStack {
                        Text("Open").frame(width: 60, alignment: .leading)
                        Slider(value: $sender.gateOpenThresh, in: 0...255, step: 1)
                        Text("\(Int(sender.gateOpenThresh))").monospaced()
                    }
                    HStack {
                        Text("Close").frame(width: 60, alignment: .leading)
                        Slider(value: $sender.gateCloseThresh, in: 0...255, step: 1)
                        Text("\(Int(sender.gateCloseThresh))").monospaced()
                    }
                    HStack {
                        Text("Hold").frame(width: 60, alignment: .leading)
                        TextField("250", text: Binding(
                            get: { String(sender.gateHoldMs) },
                            set: { sender.gateHoldMs = Int($0) ?? 250 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        Text("ms").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)

            // Transport + test
            HStack {
                Button(sender.isRunning ? "Stop" : "Start") {
                    sender.isRunning ? sender.stop() : sender.start()
                }
                .buttonStyle(.borderedProminent)

                Button("Send Test Packet") { sender.sendTestPacket() }
                    .buttonStyle(.bordered)

                Toggle("Keep Screen Awake", isOn: $keepAwake)
                    .onChange(of: keepAwake) { UIApplication.shared.isIdleTimerDisabled = $0 }
            }
            .padding(.horizontal)

            // Visualizers
            VStack(spacing: 8) {
                BarView(value: CGFloat(sender.uiLevel))
                    .frame(height: 70)
                    .padding(.horizontal)

                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<16, id: \.self) { i in
                        BarView(value: CGFloat(min(1.0, max(0.0, sender.uiBins[i]))))
                    }
                }
                .frame(height: 80)
                .padding(.horizontal)
            }

            Text(sender.statusText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)
        }
        .padding(.top, 8)
    }
}

@main
struct ILLUMIDELApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
