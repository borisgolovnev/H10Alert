//
//  ECGStreamingAnalyser.swift
//  H10ECG
//
//  Real-time QRS detection. Feed it samples as the strap delivers them; it
//  calls back with beats.
//
//  The detector itself is reused unchanged — same thresholds, same T-wave
//  rejection, same searchback, same artifact relearn. Only the front end is
//  different, because the offline one is thoroughly non-causal:
//
//      offline                       live
//      ─────────────────────────     ─────────────────────────
//      filtfilt (forward+back)   →   single-pass biquads
//      centred 5-point derivative →  causal 5-point derivative
//      centred integrator        →   trailing integrator
//      centred median baseline   →   trailing running median
//      whole-file artifact calib →   trailing self-calibration
//
//  Each substitution costs either accuracy or delay, and the delay is the
//  interesting part. Total detection latency is about 120 ms at 130 Hz:
//
//      bandpass group delay      ~25 ms   (measured at init, see groupDelay)
//      derivative                ~15 ms   (2 samples)
//      integrator half-window    ~75 ms
//      peak confirmation         ~8 ms    (1 sample)
//
//  That delay is also what makes accurate R timing possible. The R peak is
//  refined by searching ±60 ms of the *baseline-removed raw* signal around the
//  delay-compensated position — and because the accumulated delay exceeds the
//  refinement half-window, those samples are already in the ring buffer when
//  the integral peak is confirmed. So `rIndex` is a true, filter-delay-free
//  sample index, reported roughly 120 ms after the heart actually did it.
//
//  One thing the live path gets for free: no leading artifact guard band is
//  needed. That existed offline only because filtfilt smears artifact
//  *backwards* in time. Causal filters cannot, so only a trailing guard applies.
//
//  Live results will not be bit-identical to the offline pass, mainly because
//  a single-pass Butterworth has phase distortion a zero-phase one doesn't.
//  Use this for display and alerting; re-run ECGAnalyser.analyze over the
//  stored recording afterwards for the definitive answer. That is what
//  dedicated hardware does too.
//

import Foundation

// MARK: - Options

struct ECGStreamingOptions {

    /// Trailing window for the running-median baseline estimate. Longer than a
    /// QRS so the complex itself doesn't drag the baseline.
    var baselineWindowSeconds: Double = 0.60

    /// Clip level as a multiple of the running amplitude scale. A real QRS sits
    /// near 1.0, so this bounds artifact without touching physiology.
    var clipFactor: Float = 6.0

    /// Artifact: a one-second window whose range exceeds this multiple of the
    /// running reference is unreadable.
    var artifactRangeFactor: Float = 4.0

    /// How long artifact suppression persists after the signal settles.
    var artifactGuardSeconds: Double = 0.60

    /// Memory of the amplitude reference used for artifact calibration.
    var artifactReferenceWindows: Int = 60

    /// Beats used for the smoothed heart-rate output.
    var heartRateSmoothingBeats: Int = 5

    /// Live irregular-rhythm monitoring.
    var monitorRhythm: Bool = true
    var rhythmOptions: ECGRhythmOptions = ECGRhythmOptions()

    /// A narrow QRS can produce two local maxima in the integrated signal. Only
    /// the largest within this window is treated as the beat, which stops the
    /// reported R position flipping between the two lobes as amplitude varies.
    ///
    /// Bought with latency: the peak must be held this long before it can be
    /// known to be the dominant one, so it adds directly to `latencySeconds`.
    /// Set to 0 to disable if latency matters more than interval precision —
    /// the offline pass has no such trade to make and will still produce clean
    /// intervals from the stored samples.
    var peakMergeSeconds: Double = 0.15

    init() {}
}

// MARK: - Output

struct ECGStreamBeat {
    /// Global sample index of the R peak, corrected for all filter delays.
    var rIndex: Int
    var timeSeconds: Double
    var qIndex: Int?
    var sIndex: Int?
    var confidence: Double

    /// Nil for the first beat, and after any artifact — an interval spanning
    /// unreadable signal is not a real RR.
    var rrSeconds: Double?
    var instantaneousHeartRate: Double?
    var smoothedHeartRate: Double?

    /// Beats recovered by searchback arrive out of order relative to real time,
    /// referring to a moment already past.
    var isRetrospective: Bool
}

// MARK: - Analyser

final class ECGStreamingAnalyser {

    // MARK: callbacks

    /// Called once per detected beat, on whichever thread calls `append`.
    var onBeat: ((ECGStreamBeat) -> Void)?

    /// Called when the signal becomes unreadable or recovers.
    var onArtifactStateChanged: ((Bool) -> Void)?

    /// Called when the live rhythm verdict changes.
    var onRhythmStateChanged: ((ECGLiveRhythmState) -> Void)?

    /// Rolling irregular-rhythm monitor. Nil when disabled in options.
    private(set) var rhythmMonitor: ECGLiveRhythmMonitor?

    var rhythmState: ECGLiveRhythmState { rhythmMonitor?.state ?? .unavailable }

    // MARK: public state

    let samplesPerSecond: Double
    private(set) var totalSamples: Int = 0
    private(set) var beatCount: Int = 0
    private(set) var isArtifact: Bool = false

    /// Approximate delay between a heartbeat and its callback.
    private(set) var latencySeconds: Double = 0

    /// Most recent smoothed heart rate, nil until enough beats have arrived.
    private(set) var heartRate: Double?

    var secondsElapsed: Double { Double(totalSamples) / samplesPerSecond }

    // MARK: internals

    private let options: ECGStreamingOptions
    private let detector: ECGPanTompkinsDetector

    private var baselineMedian: RunningMedian
    private var bandpass: [Biquad]

    private let derivativeDelay = 2
    private let integrationWindow: Int
    private var integratorDelay: Int { (integrationWindow - 1) / 2 }
    private var bandpassDelay: Int

    /// Total displacement between the integral peak and the true R peak.
    private var totalDelay: Int { bandpassDelay + derivativeDelay + integratorDelay }

    // Ring buffers, addressed by global sample index.
    private var rawRing: Ring
    private var bandRing: Ring
    private var derivRing: Ring

    // Causal derivative history.
    private var bandHistory = [Float](repeating: 0, count: 5)

    // Causal integrator.
    private var squareHistory: [Float]
    private var squareCursor = 0
    private var runningSum: Double = 0

    // Integral peak detection needs three consecutive values.
    private var integralPrev2: Float = 0
    private var integralPrev1: Float = 0
    private var haveIntegral = 0

    // Dominant-peak hold.
    private let peakMergeWindow: Int
    private var pendingPeakIndex: Int?
    private var pendingPeakValue: Float = 0

    // Amplitude scale and artifact calibration.
    private var secondWindow = [Float]()
    private var recentRanges = [Float]()
    private var amplitudeScale: Float = 0
    private var artifactUntil: Int = -1
    private var artifactSamplesSincePreviousCandidate = 0

    // Delivered-beat bookkeeping.
    private var deliveredBeats = 0
    private var lastDeliveredRIndex: Int?
    private var lastDeliveredPosition: Double?
    private var recentRR = [Double]()

    // Running QRS polarity consensus, so the refinement doesn't flip between
    // the R apex and the S trough as beat amplitude varies.
    private var positiveEvidence: Double = 0
    private var negativeEvidence: Double = 0
    private var positivePolarity = true

    private let refineHalf: Int
    private let qsLimit: Int
    private let localHalf: Int

    // MARK: init

    init(samplesPerSecond fs: Double, options: ECGStreamingOptions = ECGStreamingOptions()) {
        self.samplesPerSecond = fs
        self.options = options
        self.detector = ECGPanTompkinsDetector(samplesPerSecond: fs)

        self.integrationWindow = ECGSignalPipeline.windowSize(for: fs)
        self.squareHistory = [Float](repeating: 0, count: integrationWindow)

        self.baselineMedian = RunningMedian(window: ECGSignalPipeline.oddWindow(options.baselineWindowSeconds * fs))

        let sections = [
            Biquad.highpass(cutoff: ECGSignalPipeline.lowCutoffHz, samplingRate: fs),
            Biquad.lowpass(cutoff: ECGSignalPipeline.highCutoffHz, samplingRate: fs)
        ]
        self.bandpass = sections
        self.bandpassDelay = ECGStreamingAnalyser.groupDelay(sections: sections, samplesPerSecond: fs)

        self.refineHalf = max(2, Int(0.060 * fs))
        self.qsLimit = max(3, Int(0.100 * fs))
        self.localHalf = max(2, integrationWindow / 2)

        let ringLength = max(Int(3.0 * fs), integrationWindow * 8)
        self.rawRing = Ring(capacity: ringLength)
        self.bandRing = Ring(capacity: ringLength)
        self.derivRing = Ring(capacity: ringLength)

        self.peakMergeWindow = max(0, Int(options.peakMergeSeconds * fs))
        self.latencySeconds = Double(totalDelay + 1 + peakMergeWindow) / fs
        if options.monitorRhythm {
            let monitor = ECGLiveRhythmMonitor(samplesPerSecond: fs, options: options.rhythmOptions)
            monitor.onStateChanged = { [weak self] state in
                self?.onRhythmStateChanged?(state)
            }
            self.rhythmMonitor = monitor
        }
    }

    // MARK: - Input

    func append(_ samples: [Float]) {
        for s in samples { push(s) }
    }

    func append(_ samples: [Double]) {
        for s in samples { push(Float(s)) }
    }

    func append(_ samples: [Int32]) {
        for s in samples { push(Float(s)) }
    }

    func reset() {
        totalSamples = 0
        beatCount = 0
        deliveredBeats = 0
        lastDeliveredRIndex = nil
        lastDeliveredPosition = nil
        recentRR.removeAll()
        heartRate = nil
        isArtifact = false
        rhythmMonitor?.reset()
        artifactUntil = -1
        artifactSamplesSincePreviousCandidate = 0
        positiveEvidence = 0
        negativeEvidence = 0
        positivePolarity = true
        runningSum = 0
        squareCursor = 0
        haveIntegral = 0
        pendingPeakIndex = nil
        pendingPeakValue = 0
        secondWindow.removeAll()
        recentRanges.removeAll()
        amplitudeScale = 0
        squareHistory = [Float](repeating: 0, count: integrationWindow)
        bandHistory = [Float](repeating: 0, count: 5)
        baselineMedian.reset()
        rawRing.reset()
        bandRing.reset()
        derivRing.reset()
        bandpass = [
            Biquad.highpass(cutoff: ECGSignalPipeline.lowCutoffHz, samplingRate: samplesPerSecond),
            Biquad.lowpass(cutoff: ECGSignalPipeline.highCutoffHz, samplingRate: samplesPerSecond)
        ]
    }

    // MARK: - Per-sample pipeline

    private func push(_ input: Float) {
        let index = totalSamples
        totalSamples += 1

        // 1. Baseline. A trailing median tracks a step without ringing, which a
        //    causal highpass emphatically does not.
        let baseline = baselineMedian.push(input)
        var x = input - baseline

        // 2. Amplitude scale and artifact state, updated once per second.
        updateSignalScale(x, at: index)

        // 3. Clip.
        if amplitudeScale > 0, options.clipFactor > 0 {
            let limit = options.clipFactor * amplitudeScale
            x = min(limit, max(-limit, x))
        }
        rawRing.write(x, at: index)

        // 4. Bandpass, single pass.
        var b = Double(x)
        for i in 0..<bandpass.count { b = bandpass[i].process(b) }
        let band = Float(b)
        bandRing.write(band, at: index)

        // 5. Causal 5-point derivative: (1/8)[2x(n) + x(n-1) - x(n-3) - 2x(n-4)],
        //    which is the paper's centred kernel delayed by two samples.
        bandHistory[4] = bandHistory[3]
        bandHistory[3] = bandHistory[2]
        bandHistory[2] = bandHistory[1]
        bandHistory[1] = bandHistory[0]
        bandHistory[0] = band
        let deriv = (2 * bandHistory[0] + bandHistory[1] - bandHistory[3] - 2 * bandHistory[4]) * 0.125
        derivRing.write(deriv, at: index)

        // 6. Square and integrate over a trailing window.
        let squared = deriv * deriv
        runningSum -= Double(squareHistory[squareCursor])
        squareHistory[squareCursor] = squared
        runningSum += Double(squared)
        squareCursor = (squareCursor + 1) % integrationWindow
        let integral = Float(runningSum / Double(integrationWindow))

        // 7. Local maximum of the integral, confirmed one sample late.
        if haveIntegral >= 2 {
            if integralPrev1 > integralPrev2, integralPrev1 >= integral, integralPrev1 > 0 {
                offerPeak(integralIndex: index - 1, value: integralPrev1)
            }
        }
        integralPrev2 = integralPrev1
        integralPrev1 = integral
        if haveIntegral < 2 { haveIntegral += 1 }

        // 8. Release a held peak once nothing larger can still arrive within
        //    the merge window.
        if let pending = pendingPeakIndex, index - pending >= peakMergeWindow {
            flushPendingPeak()
        }
    }

    /// Holds a confirmed integral peak until it is known to be the dominant one
    /// in its QRS. Without this the beat position is decided by whichever lobe
    /// crosses threshold first, which flips with respiration and throws the
    /// intervals either side of it out by tens of milliseconds.
    private func offerPeak(integralIndex: Int, value: Float) {
        guard peakMergeWindow > 0 else {
            handlePeak(integralIndex: integralIndex, value: value)
            return
        }

        if let pending = pendingPeakIndex {
            if integralIndex - pending < peakMergeWindow {
                if value > pendingPeakValue {
                    pendingPeakIndex = integralIndex
                    pendingPeakValue = value
                }
                return
            }
            flushPendingPeak()
        }
        pendingPeakIndex = integralIndex
        pendingPeakValue = value
    }

    private func flushPendingPeak() {
        guard let pending = pendingPeakIndex else { return }
        pendingPeakIndex = nil
        handlePeak(integralIndex: pending, value: pendingPeakValue)
    }

    // MARK: - Artifact and scale

    private func updateSignalScale(_ x: Float, at index: Int) {
        secondWindow.append(x)
        guard secondWindow.count >= Int(samplesPerSecond) else { return }

        var magnitudes = secondWindow.map { abs($0) }
        secondWindow.removeAll(keepingCapacity: true)
        magnitudes.sort()
        // Peak magnitude, not a percentile spread: a thin R wave a few samples
        // wide sits entirely within the top 5% of a one-second window, so a
        // percentile range measures the baseline between beats instead of the
        // beats. Second largest drops a single-sample glitch.
        let peak = magnitudes[magnitudes.count - 2]

        let flagged = amplitudeScale > 0 && peak > options.artifactRangeFactor * amplitudeScale

        // Only clean windows update the reference, otherwise a sustained
        // artifact drags the calibration up behind it and stops being detected.
        if !flagged {
            recentRanges.append(peak)
            if recentRanges.count > options.artifactReferenceWindows { recentRanges.removeFirst() }
            var sorted = recentRanges
            sorted.sort()
            amplitudeScale = sorted[sorted.count / 2]
        }

        if flagged {
            // Trailing guard only. Offline the guard is symmetric because
            // filtfilt smears artifact backwards; a causal chain cannot.
            artifactUntil = index + Int(options.artifactGuardSeconds * samplesPerSecond)
        }

        let nowArtifact = index < artifactUntil
        if nowArtifact != isArtifact {
            isArtifact = nowArtifact
            // Entering artifact invalidates the rolling window: beats are about
            // to go missing, and a gap in the sequence is indistinguishable
            // from genuine irregularity.
            if nowArtifact { rhythmMonitor?.breakRun() }
            onArtifactStateChanged?(nowArtifact)
        }
    }

    // MARK: - Candidate assembly

    private func handlePeak(integralIndex: Int, value: Float) {

        // Delay compensation: the integral peak trails the true R by the
        // accumulated group delay of the whole chain.
        let estimatedR = integralIndex - totalDelay
        guard estimatedR - refineHalf >= rawRing.oldestIndex,
              estimatedR >= 0 else { return }

        // Anything during artifact is discarded outright — not fed in as noise,
        // which would inflate NPKI and raise the threshold just as damagingly.
        if integralIndex < artifactUntil {
            artifactSamplesSincePreviousCandidate += 1
            return
        }

        // Refine onto the true R in the baseline-removed raw signal, so the
        // reported index carries no filter delay at all. Deliberately NOT the
        // bandpassed signal: a 5–15 Hz filter reshapes the QRS and adds ringing
        // from the P and T waves, and the position of the reshaped maximum
        // shifts with how far the R towers over that ringing — i.e. with beat
        // amplitude.
        var maxPositive: Float = 0
        var maxNegative: Float = 0
        for j in (estimatedR - refineHalf)...(estimatedR + refineHalf) {
            guard let v = smoothedRaw(at: j) else { continue }
            maxPositive = max(maxPositive, v)
            maxNegative = max(maxNegative, -v)
        }
        positiveEvidence += Double(maxPositive)
        negativeEvidence += Double(maxNegative)
        positivePolarity = positiveEvidence >= negativeEvidence

        // Locked polarity rather than argmax of |x|: otherwise the winner flips
        // between the R apex and the S trough when they are comparable, and the
        // reported position jumps by 30–40 ms as amplitude varies.
        var rIndex = estimatedR
        var best: Float = -.greatestFiniteMagnitude
        for j in (estimatedR - refineHalf)...(estimatedR + refineHalf) {
            guard let raw = smoothedRaw(at: j) else { continue }
            let v = positivePolarity ? raw : -raw
            if v > best { best = v; rIndex = j }
        }
        guard best > -.greatestFiniteMagnitude else { return }

        let rFraction = parabolicOffset(at: rIndex, positive: positivePolarity)

        var peakF: Float = 0
        var slope: Float = 0
        for j in (integralIndex - localHalf)...(integralIndex + localHalf) {
            if let v = bandRing.read(at: j) { peakF = max(peakF, abs(v)) }
            if let v = derivRing.read(at: j) { slope = max(slope, abs(v)) }
        }

        let q = turningPoint(from: rIndex, step: -1, seekingMinimum: positivePolarity)
        let s = turningPoint(from: rIndex, step: 1, seekingMinimum: positivePolarity)

        let candidate = ECGQRSCandidate(index: integralIndex,
                                        integralPeak: value,
                                        filteredPeak: peakF,
                                        slope: slope,
                                        rIndex: rIndex,
                                        rFraction: rFraction,
                                        qIndex: q,
                                        sIndex: s)

        detector.ingest(candidate,
                        artifactSamplesSincePrevious: artifactSamplesSincePreviousCandidate)
        artifactSamplesSincePreviousCandidate = 0

        drainDetector()
    }

    /// Symmetric [0.25, 0.5, 0.25] smoother applied at read time. Costs no
    /// filter state and no delay — the ring already holds the samples either
    /// side, because the pipeline's own group delay runs ahead of it.
    private func smoothedRaw(at index: Int) -> Float? {
        guard let centre = rawRing.read(at: index) else { return nil }
        guard let before = rawRing.read(at: index - 1),
              let after = rawRing.read(at: index + 1) else { return centre }
        return 0.25 * before + 0.5 * centre + 0.25 * after
    }

    /// Sub-sample peak position from a parabola through the peak and its
    /// neighbours. At 130 Hz the sample grid alone puts about 3 ms of RMS noise
    /// into every interval.
    private func parabolicOffset(at index: Int, positive: Bool) -> Float {
        guard let a = smoothedRaw(at: index - 1),
              let b = smoothedRaw(at: index),
              let c = smoothedRaw(at: index + 1) else { return 0 }
        let s: Float = positive ? 1 : -1
        let y0 = s * a, y1 = s * b, y2 = s * c
        let denominator = y0 - 2 * y1 + y2
        guard denominator < 0 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (y0 - y2) / denominator))
    }

    private func turningPoint(from start: Int, step: Int, seekingMinimum: Bool) -> Int? {
        guard var best = rawRing.read(at: start) else { return nil }
        var bestIndex = start
        var i = start
        var steps = 0
        while steps < qsLimit {
            let next = i + step
            guard let v = rawRing.read(at: next) else { break }
            let continuing = seekingMinimum ? (v <= best) : (v >= best)
            guard continuing else { break }
            best = v
            bestIndex = next
            i = next
            steps += 1
        }
        return bestIndex == start ? nil : bestIndex
    }

    // MARK: - Delivery

    /// The detector appends accepted beats to its own array, including ones
    /// recovered retrospectively by searchback. Anything new since last time
    /// gets delivered.
    private func drainDetector() {
        let beats = detector.beats
        guard beats.count > deliveredBeats else { return }

        for i in deliveredBeats..<beats.count {
            let beat = beats[i]
            let confidence = i < detector.confidences.count ? detector.confidences[i] : 1.0

            var rr: Double?
            var instant: Double?

            // Searchback beats can arrive referring to a moment before the
            // previously delivered one, so ordering is not guaranteed.
            let retrospective = lastDeliveredRIndex.map { beat.rIndex < $0 } ?? false

            if let previous = lastDeliveredPosition, !retrospective, beat.rPosition > previous {
                let interval = (beat.rPosition - previous) / samplesPerSecond
                // An interval that straddled artifact is not a real RR.
                if interval > 0.2, interval < 3.0, !isArtifact {
                    rr = interval
                    instant = 60.0 / interval
                    recentRR.append(interval)
                    if recentRR.count > options.heartRateSmoothingBeats { recentRR.removeFirst() }
                    if recentRR.count >= 3 {
                        let sorted = recentRR.sorted()
                        heartRate = 60.0 / sorted[sorted.count / 2]
                    }
                }
            }

            if !retrospective {
                lastDeliveredRIndex = beat.rIndex
                lastDeliveredPosition = beat.rPosition
            }
            beatCount += 1

            rhythmMonitor?.add(rIndex: beat.rIndex, confidence: confidence)

            onBeat?(ECGStreamBeat(rIndex: beat.rIndex,
                                  timeSeconds: beat.rPosition / samplesPerSecond,
                                  qIndex: beat.qIndex,
                                  sIndex: beat.sIndex,
                                  confidence: confidence,
                                  rrSeconds: rr,
                                  instantaneousHeartRate: instant,
                                  smoothedHeartRate: heartRate,
                                  isRetrospective: retrospective))
        }
        deliveredBeats = beats.count
    }

    // MARK: - Group delay

    /// Energy centroid of the filter chain's impulse response. Measured rather
    /// than assumed, so it stays correct if the passband is ever retuned.
    private static func groupDelay(sections: [Biquad], samplesPerSecond fs: Double) -> Int {
        var chain = sections
        var weighted = 0.0
        var total = 0.0
        let n = max(64, Int(fs * 2))
        for i in 0..<n {
            var v = (i == 0) ? 1.0 : 0.0
            for k in 0..<chain.count { v = chain[k].process(v) }
            let energy = v * v
            weighted += Double(i) * energy
            total += energy
        }
        guard total > 0 else { return 0 }
        return Int((weighted / total).rounded())
    }
}

// MARK: - Ring buffer

/// Fixed-size buffer addressed by absolute sample index. Reads outside the
/// retained span return nil rather than stale data.
private struct Ring {
    private var storage: [Float]
    private let capacity: Int
    private var newestIndex = -1

    init(capacity: Int) {
        self.capacity = max(8, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    var oldestIndex: Int { max(0, newestIndex - capacity + 1) }

    mutating func reset() {
        newestIndex = -1
        for i in 0..<capacity { storage[i] = 0 }
    }

    mutating func write(_ value: Float, at index: Int) {
        storage[index % capacity] = value
        newestIndex = index
    }

    func read(at index: Int) -> Float? {
        guard index >= 0, index <= newestIndex, index >= oldestIndex else { return nil }
        return storage[index % capacity]
    }
}

// MARK: - Running median

/// Trailing median over a fixed window. Keeps a sorted mirror of the window so
/// each push is a binary search plus one insertion — cheap enough at ECG rates,
/// and the only baseline estimator that follows a step without ringing.
struct RunningMedian {

    private let window: Int
    private var fifo: [Float]
    private var head = 0
    private var filled = 0
    private var sorted = [Float]()

    init(window: Int) {
        self.window = max(3, window)
        self.fifo = [Float](repeating: 0, count: self.window)
        self.sorted.reserveCapacity(self.window)
    }

    mutating func reset() {
        head = 0
        filled = 0
        sorted.removeAll(keepingCapacity: true)
    }

    mutating func push(_ value: Float) -> Float {
        if filled == window {
            let outgoing = fifo[head]
            if let i = indexOf(outgoing) { sorted.remove(at: i) }
        } else {
            filled += 1
        }
        fifo[head] = value
        head = (head + 1) % window

        sorted.insert(value, at: insertionPoint(value))
        return sorted[sorted.count / 2]
    }

    private func insertionPoint(_ value: Float) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func indexOf(_ value: Float) -> Int? {
        let i = insertionPoint(value)
        guard i < sorted.count, sorted[i] == value else { return nil }
        return i
    }
}
