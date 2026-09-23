//
//  ECGAnalyser.swift
//  H10ECG
//
//  Created by Boris Golovnev on 24/07/2022.
//  Rewritten 2026 as a faithful Pan–Tompkins implementation.
//
//  Reference:
//    Pan J, Tompkins WJ. "A Real-Time QRS Detection Algorithm."
//    IEEE Trans. Biomed. Eng. BME-32(3):230-236, 1985.
//
//  Differences from the 1985 paper, all deliberate, all because this runs
//  offline rather than on a 1985 microcontroller:
//
//    * The bandpass is a proper 5–15 Hz Butterworth run forward-and-backward
//      (filtfilt), not the paper's integer-coefficient cascade. Zero phase
//      distortion, so no delay compensation is needed anywhere downstream.
//    * The derivative and the moving-window integrator are centred rather
//      than causal, for the same reason.
//    * Every time constant is derived from the sample rate instead of
//      assuming 200 Hz.
//
//  The detection logic itself — dual-channel adaptive thresholds, the
//  SPKI/NPKI estimators, T-wave slope rejection, the two RR averages and
//  the missed-beat searchback — follows the paper.
//
//  NOTE: NVDSP is no longer needed; the filters are implemented here so the
//  passband and phase response are known quantities.
//

import Foundation

// MARK: - Wave model

enum ECGAnalyserWaveType {
    case p
    case q
    case r
    case s
    case t
    case u
}

struct ECGAnalyserWave {
    let type: ECGAnalyserWaveType
    let globalOffset: Int
    let offset: Int
    /// 0...1. Derived from how far the detection peak sat above the adaptive
    /// threshold; beats recovered by searchback are discounted.
    /// (Was previously `let confidence = 1`, which silently excluded it from
    /// the memberwise init so nothing could ever set it.)
    var confidence: Double = 1.0

    /// Sub-sample refinement of `globalOffset`, in −0.5...0.5 samples. Set for
    /// R waves; zero for Q and S, where the turning point is not well enough
    /// defined for interpolation to mean anything.
    var subSampleOffset: Double = 0

    /// Position in samples including the sub-sample refinement.
    var position: Double { Double(globalOffset) + subSampleOffset }
}

// MARK: - Analysis result

/// If this type is already declared in another file, delete that declaration
/// and keep this one — the new fields are needed by `ECGAnalyser.analyze`.
final class ECGAnalyserAnalysis {

    var samplesPerSecond: Double = 0

    /// Q, R and S waves, ordered by `globalOffset`, no duplicates.
    var waves = [ECGAnalyserWave]()

    /// Beat-to-beat intervals in milliseconds, one per adjacent R-R pair.
    var rrIntervalsMs = [Int]()

    /// Instantaneous heart rate for each R-R pair, physiologically plausible
    /// values only.
    var instantHeartRates = [Float]()

    /// Downsampled, median-filtered heart rate track (legacy display series).
    var heartRates = [UInt8]()

    var maxHR: Int = 0
    var minHR: Int = 0
    var meanHR: Float = 0

    /// Time-domain HRV, computed over intervals that survive ectopic filtering.
    var sdnnMs: Float = 0
    var rmssdMs: Float = 0
    var pnn50: Float = 0

    /// QT/QTc from RR-binned median beats. Nil if it wasn't requested or if no
    /// bin had enough clean beats.
    var qt: ECGQTAnalysis?

    /// Regions excluded as electrode-motion artifact.
    var artifactMask = ECGArtifactMask()

    /// Irregularly-irregular rhythm windows and episodes. See the warning at
    /// the top of ECGRhythmAnalyser.swift before presenting any of this.
    var rhythm: ECGRhythmAnalysis?

    /// Fraction of the recording that was usable.
    var cleanFraction: Double { artifactMask.cleanFraction }

    /// Peaks the detector threw out as implausibly large. A non-zero count
    /// with a low `cleanFraction` means the strap needs attention, not the
    /// algorithm.
    var artifactRejections: Int = 0

    var beatCount: Int { waves.lazy.filter { $0.type == .r }.count }
}

// MARK: - Biquad

/// Direct-form II transposed biquad. Coefficients are normalised so a0 == 1.
struct Biquad {

    var b0: Double
    var b1: Double
    var b2: Double
    var a1: Double
    var a2: Double

    private var z1: Double = 0
    private var z2: Double = 0

    /// 2nd-order Butterworth lowpass via bilinear transform with prewarping.
    static func lowpass(cutoff: Double, samplingRate: Double) -> Biquad {
        let k = tan(Double.pi * min(cutoff, samplingRate * 0.49) / samplingRate)
        let kk = k * k
        let norm = 1.0 / (1.0 + Double(2.0).squareRoot() * k + kk)
        return Biquad(b0: kk * norm,
                      b1: 2.0 * kk * norm,
                      b2: kk * norm,
                      a1: 2.0 * (kk - 1.0) * norm,
                      a2: (1.0 - Double(2.0).squareRoot() * k + kk) * norm)
    }

    /// 2nd-order Butterworth highpass via bilinear transform with prewarping.
    static func highpass(cutoff: Double, samplingRate: Double) -> Biquad {
        let k = tan(Double.pi * min(cutoff, samplingRate * 0.49) / samplingRate)
        let kk = k * k
        let norm = 1.0 / (1.0 + Double(2.0).squareRoot() * k + kk)
        return Biquad(b0: norm,
                      b1: -2.0 * norm,
                      b2: norm,
                      a1: 2.0 * (kk - 1.0) * norm,
                      a2: (1.0 - Double(2.0).squareRoot() * k + kk) * norm)
    }

    /// Sets the delay line to the steady state for a constant input, which
    /// removes the startup transient that would otherwise look like a QRS.
    mutating func prime(with x: Double) {
        let gain = (b0 + b1 + b2) / (1.0 + a1 + a2)
        let y = x * gain
        z2 = b2 * x - a2 * y
        z1 = b1 * x - a1 * y + z2
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

// MARK: - Signal pipeline

/// The filter chain. Stateless from the caller's point of view: give it a
/// block of samples, get back every intermediate stage.
enum ECGSignalPipeline {

    struct Channels {
        var bandpass: [Float]
        var derivative: [Float]
        var squared: [Float]
        var integral: [Float]
        /// Baseline-removed signal with only a gentle symmetric smoother
        /// applied. Detection uses the narrow band; *timing* uses this, because
        /// a 5–15 Hz filter reshapes the QRS and the position of the reshaped
        /// maximum depends on what else is nearby.
        var wideband: [Float]
    }

    static let lowCutoffHz = 5.0
    static let highCutoffHz = 15.0
    static let integrationWindowSeconds = 0.150

    static func process(_ input: [Float],
                        samplesPerSecond fs: Double,
                        removeBaseline: Bool = true,
                        clipFactor: Float = 6.0) -> Channels {
        guard input.count > 8, fs > 0 else {
            let z = [Float](repeating: 0, count: input.count)
            return Channels(bandpass: z, derivative: z, squared: z, integral: z, wideband:z)
        }

        var work = input

        // A median-based baseline estimate tracks a step without ringing;
        // subtracting it first stops the Butterworth being excited by electrode
        // motion. See ECGSignalQuality.swift for why this matters so much.
        if removeBaseline {
            let baseline = robustBaseline(input, samplesPerSecond: fs)
            for i in 0..<work.count { work[i] -= baseline[i] }
        }

        // Whatever survives the detrend gets bounded. A real QRS sits at about
        // 1.0 on this scale, so clipping at 6 leaves physiology untouched while
        // capping how hard an artifact edge can hit the derivative — and, after
        // squaring, how badly it can poison SPKI.
        if clipFactor > 0 {
            let scale = robustScale(work, samplesPerSecond: fs)
            if scale > 0 {
                let limit = clipFactor * scale
                for i in 0..<work.count { work[i] = min(limit, max(-limit, work[i])) }
            }
        }

        let sections = [
            Biquad.highpass(cutoff: lowCutoffHz, samplingRate: fs),
            Biquad.lowpass(cutoff: highCutoffHz, samplingRate: fs)
        ]

        let band = filtfilt(work, sections: sections, padLength: Int(fs))
        let deriv = derivative(band)
        let sq = deriv.map { $0 * $0 }
        let integ = movingWindowIntegral(sq,
                                         window: windowSize(for: fs))

        return Channels(bandpass: band, derivative: deriv, squared: sq, integral: integ,
                        wideband: smoothed3(work))
    }

    /// Symmetric [0.25, 0.5, 0.25] kernel. Takes the edge off sample noise
    /// without shifting anything, which is all the timing channel needs.
    static func smoothed3(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n > 2 else { return x }
        var out = [Float](repeating: 0, count: n)
        out[0] = x[0]
        out[n - 1] = x[n - 1]
        for i in 1..<(n - 1) {
            out[i] = 0.25 * x[i - 1] + 0.5 * x[i] + 0.25 * x[i + 1]
        }
        return out
    }

    /// Sub-sample peak position by fitting a parabola through the maximum and
    /// its two neighbours. Returns an offset in samples, in −0.5...0.5.
    ///
    /// At 130 Hz one sample is 7.7 ms, so quantising R positions to the grid
    /// puts roughly 3 ms of RMS noise into every interval — which is a
    /// meaningful fraction of a resting RMSSD.
    static func parabolicOffset(_ x: [Float], at i: Int, positive: Bool) -> Float {
        guard i > 0, i < x.count - 1 else { return 0 }
        let s: Float = positive ? 1 : -1
        let y0 = s * x[i - 1], y1 = s * x[i], y2 = s * x[i + 1]
        let denominator = y0 - 2 * y1 + y2
        // Must actually curve downward; a clipped or flat top gives no
        // information and is left on the grid.
        guard denominator < 0 else { return 0 }
        return max(-0.5, min(0.5, 0.5 * (y0 - y2) / denominator))
    }

    static func windowSize(for fs: Double) -> Int {
        var w = Int((integrationWindowSeconds * fs).rounded())
        w = max(3, w)
        if w % 2 == 0 { w += 1 }   // odd, so it can be centred exactly
        return w
    }

    /// Forward-backward filtering. Doubles the effective order and, more
    /// importantly, gives exactly zero phase shift — the R peak in the
    /// bandpassed signal sits where it does in the raw signal.
    static func filtfilt(_ input: [Float], sections: [Biquad], padLength: Int) -> [Float] {
        let n = input.count
        guard n > 3 else { return input }

        let pad = min(max(padLength, 8), n - 1)

        // Odd reflection about the endpoints, as scipy does, to keep the
        // padded signal continuous in value and slope.
        var work = [Double]()
        work.reserveCapacity(n + 2 * pad)
        let first = Double(input[0])
        let last = Double(input[n - 1])
        for i in stride(from: pad, to: 0, by: -1) { work.append(2 * first - Double(input[i])) }
        for v in input { work.append(Double(v)) }
        for i in stride(from: n - 2, to: n - 2 - pad, by: -1) { work.append(2 * last - Double(input[i])) }

        // Forward
        for var section in sections {
            section.prime(with: work[0])
            for i in 0..<work.count { work[i] = section.process(work[i]) }
        }
        // Backward
        for var section in sections {
            section.prime(with: work[work.count - 1])
            for i in stride(from: work.count - 1, through: 0, by: -1) {
                work[i] = section.process(work[i])
            }
        }

        return (pad..<(pad + n)).map { Float(work[$0]) }
    }

    /// Pan–Tompkins five-point derivative, written centred as it is in the
    /// paper: y(n) = (1/8)[-x(n-2) - 2x(n-1) + 2x(n+1) + x(n+2)]
    static func derivative(_ x: [Float]) -> [Float] {
        let n = x.count
        guard n > 4 else { return [Float](repeating: 0, count: n) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let m2 = x[max(0, i - 2)]
            let m1 = x[max(0, i - 1)]
            let p1 = x[min(n - 1, i + 1)]
            let p2 = x[min(n - 1, i + 2)]
            out[i] = (-m2 - 2 * m1 + 2 * p1 + p2) * 0.125
        }
        return out
    }

    /// Centred moving average over `window` samples, running-sum so it is O(n)
    /// rather than the O(n·w) double loop this replaces.
    static func movingWindowIntegral(_ x: [Float], window: Int) -> [Float] {
        let n = x.count
        guard n > 0, window > 1 else { return x }
        let half = window / 2
        var out = [Float](repeating: 0, count: n)

        var sum: Double = 0
        for i in -half...half { sum += Double(x[clamp(i, 0, n - 1)]) }
        out[0] = Float(sum / Double(window))

        for i in 1..<n {
            sum -= Double(x[clamp(i - half - 1, 0, n - 1)])
            sum += Double(x[clamp(i + half, 0, n - 1)])
            out[i] = Float(sum / Double(window))
        }
        return out
    }

    @inline(__always)
    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
        return min(hi, max(lo, v))
    }
}

// MARK: - Candidate peaks

/// One local maximum of the integrated signal, with everything the detector
/// needs to judge it. Fully self-describing so searchback can reach back
/// across a processing-chunk boundary without needing the old sample buffers.
struct ECGQRSCandidate {
    let index: Int              // global sample index of the integral peak
    let integralPeak: Float
    let filteredPeak: Float     // max |bandpass| local to the peak
    let slope: Float            // max |derivative| local to the peak
    let rIndex: Int             // global index of the R deflection
    /// Sub-sample refinement of `rIndex`, in −0.5...0.5 samples.
    let rFraction: Float
    let qIndex: Int?
    let sIndex: Int?

    /// R position in samples, including the sub-sample fraction.
    var rPosition: Double { Double(rIndex) + Double(rFraction) }
}

extension ECGSignalPipeline {

    /// Extracts candidate peaks whose *integral peak* lies inside `coreRange`
    /// (local indices). Neighbouring samples outside the core are still used
    /// for the local-maximum test and for refinement, so chunks can tile with
    /// no overlap: every peak belongs to exactly one core, so no beat is
    /// duplicated and none is lost at a boundary.
    static func candidates(in ch: Channels,
                           coreRange: Range<Int>,
                           globalOffset: Int,
                           samplesPerSecond fs: Double) -> [ECGQRSCandidate] {

        let n = ch.integral.count
        guard n > 3 else { return [] }

        let refineHalf = max(2, Int(0.060 * fs))          // ±60 ms for the R peak
        let localHalf = max(2, windowSize(for: fs) / 2)   // integration half-width
        let qsLimit = max(3, Int(0.100 * fs))             // Q/S no further than 100 ms

        let lo = max(1, coreRange.lowerBound)
        let hi = min(n - 1, coreRange.upperBound)
        guard lo < hi else { return [] }

        var result = [ECGQRSCandidate]()

        // Pass 1: locate the integral peaks and settle on a QRS polarity for
        // this block.
        //
        // Taking argmax of |signal| lets the winner flip between the R apex and
        // the S trough when the two are comparable, and which one wins depends
        // on beat amplitude — so the reported position jumps by 30–40 ms as the
        // R wave grows and shrinks with respiration. Deciding the polarity once
        // across many beats and then always taking that extremum removes the
        // bistability.
        var rawPeaks = [Int]()
        for i in lo..<hi {
            let v = ch.integral[i]
            guard v > ch.integral[i - 1], v >= ch.integral[i + 1], v > 0 else { continue }
            rawPeaks.append(i)
        }

        // Keep only the dominant peak in each QRS-width neighbourhood. Without
        // this the position of a beat is decided by which of two lobes happens
        // to cross threshold first, which flips with respiration.
        let peakIndices = dominantPeaks(rawPeaks,
                                        values: ch.integral,
                                        minimumSeparation: max(2, Int(0.15 * fs)))

        var positiveEvidence: Double = 0
        var negativeEvidence: Double = 0

        for i in peakIndices {
            var maxPositive: Float = 0
            var maxNegative: Float = 0
            for j in max(0, i - refineHalf)...min(n - 1, i + refineHalf) {
                maxPositive = max(maxPositive, ch.wideband[j])
                maxNegative = max(maxNegative, -ch.wideband[j])
            }
            positiveEvidence += Double(maxPositive)
            negativeEvidence += Double(maxNegative)
        }

        let positivePolarity = positiveEvidence >= negativeEvidence

        // Pass 2: refine each peak.
        for i in peakIndices {

            // Refine on the wideband channel, not the 5–15 Hz one. A narrowband
            // filter reshapes a QRS and superimposes ringing from the P and T
            // waves either side of it; the position of the reshaped maximum
            // then depends on how far the QRS towers over that ringing, which
            // is to say it depends on beat amplitude.
            var rLocal = i
            var best: Float = -.greatestFiniteMagnitude
            for j in max(0, i - refineHalf)...min(n - 1, i + refineHalf) {
                let value = positivePolarity ? ch.wideband[j] : -ch.wideband[j]
                if value > best { best = value; rLocal = j }
            }

            let fraction = parabolicOffset(ch.wideband, at: rLocal, positive: positivePolarity)

            var peakF: Float = 0
            var slope: Float = 0
            for j in max(0, i - localHalf)...min(n - 1, i + localHalf) {
                peakF = max(peakF, abs(ch.bandpass[j]))
                slope = max(slope, abs(ch.derivative[j]))
            }

            let q = turningPoint(from: rLocal, step: -1, limit: qsLimit,
                                 seekingMinimum: positivePolarity, in: ch.wideband)
            let s = turningPoint(from: rLocal, step: 1, limit: qsLimit,
                                 seekingMinimum: positivePolarity, in: ch.wideband)

            result.append(ECGQRSCandidate(index: globalOffset + i,
                                          integralPeak: ch.integral[i],
                                          filteredPeak: peakF,
                                          slope: slope,
                                          rIndex: globalOffset + rLocal,
                                          rFraction: fraction,
                                          qIndex: q.map { globalOffset + $0 },
                                          sIndex: s.map { globalOffset + $0 }))
        }
        return result
    }

    /// Non-maximum suppression over the integrated signal.
    ///
    /// A narrow QRS often yields two local maxima in the integral: the
    /// derivative's upstroke and downstroke lobes do not always merge inside a
    /// 150 ms window. Both become candidates and both fall inside the other's
    /// 200 ms refractory, so exactly one is accepted as the beat — and which
    /// one wins flips with small amplitude changes from respiration. The
    /// reported R then moves by the lobe separation, tens of milliseconds,
    /// which is enough to turn a metronomic 75 bpm into 88 followed by 66.
    ///
    /// Taking the largest peak in each QRS-width neighbourhood makes the choice
    /// deterministic. The separation stays below the refractory period, so a
    /// genuine second beat can never be suppressed.
    static func dominantPeaks(_ indices: [Int],
                              values: [Float],
                              minimumSeparation: Int) -> [Int] {
        guard indices.count > 1, minimumSeparation > 0 else { return indices }

        let byAmplitude = indices.sorted { values[$0] > values[$1] }
        var kept = [Int]()
        for candidate in byAmplitude {
            var dominant = true
            for accepted in kept where abs(accepted - candidate) < minimumSeparation {
                dominant = false
                break
            }
            if dominant { kept.append(candidate) }
        }
        return kept.sorted()
    }

    /// Walks away from the R peak until the signal stops falling (or rising,
    /// for an inverted complex) — the Q or S trough.
    private static func turningPoint(from start: Int,
                                     step: Int,
                                     limit: Int,
                                     seekingMinimum: Bool,
                                     in a: [Float]) -> Int? {
        var best = a[start]
        var bestIndex = start
        var i = start
        var steps = 0
        while steps < limit {
            let next = i + step
            guard next >= 0, next < a.count else { break }
            let v = a[next]
            let continuing = seekingMinimum ? (v <= best) : (v >= best)
            guard continuing else { break }
            best = v
            bestIndex = next
            i = next
            steps += 1
        }
        return bestIndex == start ? nil : bestIndex
    }
}

// MARK: - Pan–Tompkins detector

/// Holds all adaptive state. One instance can be fed candidates from
/// consecutive chunks — the thresholds, RR averages and searchback buffer all
/// survive across boundaries, so nothing has to re-learn every few seconds.
final class ECGPanTompkinsDetector {

    // Tuning, all derived from the sample rate.
    private let fs: Double
    private let refractory: Int          // 200 ms — no beat can follow sooner
    private let tWaveWindow: Int         // 360 ms — T-wave ambiguity zone
    private let learningSamples: Int     // 2 s learning phase

    // Adaptive estimators (I = integrated channel, F = filtered channel).
    private var spki: Float = 0
    private var npki: Float = 0
    private var spkf: Float = 0
    private var npkf: Float = 0

    private var thresholdI1: Float = 0
    private var thresholdI2: Float = 0
    private var thresholdF1: Float = 0
    private var thresholdF2: Float = 0

    // Rhythm state.
    private var lastQRS: Int = -1
    private var lastQRSSlope: Float = 0
    private var rrRecent = [Int]()       // last 8 intervals, unconditional
    private var rrSelected = [Int]()     // last 8 intervals that looked normal
    private var rrAverage1: Double = 0
    private var rrAverage2: Double = 0
    private var irregular = false

    private var learning = true
    private var learningBuffer = [ECGQRSCandidate]()
    private var pendingNoise = [ECGQRSCandidate]()

    // MARK: artifact handling

    /// Regions the detector should refuse to make claims about.
    var artifactMask: ECGArtifactMask?

    /// A masked gap at least this long invalidates the amplitude model as well
    /// as the rhythm model — adjusting a strap moves the lead axis, so QRS
    /// amplitude genuinely changes and the estimators must be relearned.
    var relearnAfterMaskedSeconds: Double = 2.0

    /// A peak this many times larger than the current signal estimate is not a
    /// QRS. Expressed in the amplitude domain; the integrated channel is a
    /// squared quantity, so this is squared before being applied there.
    var artifactPeakRatio: Float = 8.0

    /// A single accepted beat may raise SPKI by at most this factor, so one
    /// surviving artifact edge cannot lift the threshold above every real beat.
    /// Amplitude domain, squared for the integrated channel.
    var maximumSPKIGrowth: Float = 3.0

    /// Consecutive implausibly-large peaks before we conclude the signal really
    /// did change scale and relearn rather than keep rejecting.
    var artifactRejectionsBeforeRelearn: Int = 8

    private var consecutiveArtifactRejections = 0
    private var suppressNextRR = false

    /// Index of the last candidate that survived the mask. The masked gap must
    /// be measured against this, NOT against `lastQRS`: during a relearn no
    /// beat is being accepted, so `lastQRS` stays frozen at the last beat
    /// before the artifact and the gap would keep containing the same span
    /// forever, restarting the learning phase on every candidate.
    private var previousCandidate: Int = -1

    /// Beats discarded as artifact rather than as noise. Useful diagnostics.
    private(set) var artifactRejections = 0

    /// Accepted beats, in order.
    private(set) var beats = [ECGQRSCandidate]()
    private(set) var confidences = [Double]()

    /// (sample index, threshold) pairs for plotting the adaptive threshold.
    private(set) var thresholdTrace = [(index: Int, value: Float)]()

    init(samplesPerSecond fs: Double) {
        self.fs = fs
        self.refractory = max(1, Int(0.200 * fs))
        self.tWaveWindow = max(2, Int(0.360 * fs))
        self.learningSamples = max(1, Int(2.0 * fs))
    }

    func process(_ candidates: [ECGQRSCandidate]) {
        for c in candidates {

            // Nothing inside a masked region is evidence of anything — not a
            // beat, and not noise either. Feeding it in as noise would inflate
            // NPKI, which raises the threshold just as effectively as poisoning
            // SPKI does. It is simply discarded.
            if let mask = artifactMask, mask.contains(c.index) { continue }

            var masked = 0
            if previousCandidate >= 0, let mask = artifactMask {
                masked = mask.maskedSamples(in: previousCandidate..<c.index)
            }
            ingest(c, artifactSamplesSincePrevious: masked)
        }
    }

    /// Single-candidate entry point. The offline path derives
    /// `artifactSamplesSincePrevious` from the mask; a live source tracks it
    /// itself. Everything downstream is identical either way, which is the
    /// point — the streaming and offline detectors must not be two algorithms.
    func ingest(_ c: ECGQRSCandidate, artifactSamplesSincePrevious masked: Int) {

        // Did an artifact fall between the previous surviving candidate and
        // this one? Masked candidates are dropped by the caller, so consecutive
        // survivors straddle a given span exactly once — which means this fires
        // once per artifact rather than once per candidate.
        if previousCandidate >= 0, masked > 0 {
            // The interval spanning the artifact is not a real RR, and nothing
            // before the artifact is a valid searchback target.
            suppressNextRR = true
            pendingNoise.removeAll(keepingCapacity: true)

            if Double(masked) / fs >= relearnAfterMaskedSeconds {
                beginLearning()
            }
        }
        previousCandidate = c.index

        if learning {
            learningBuffer.append(c)
            if let first = learningBuffer.first,
               c.index - first.index >= learningSamples {
                finishLearning()
            }
            return
        }
        evaluate(c)
    }

    /// Drops back into the 2-second acquisition phase, keeping the beats found
    /// so far but discarding the amplitude and rhythm models.
    private func beginLearning() {
        learning = true
        learningBuffer.removeAll(keepingCapacity: true)
        pendingNoise.removeAll(keepingCapacity: true)
        rrRecent.removeAll()
        rrSelected.removeAll()
        rrAverage1 = 0
        rrAverage2 = 0
        irregular = false
        lastQRSSlope = 0
        consecutiveArtifactRejections = 0
        suppressNextRR = true

        // Drop the rhythm anchor too. Leaving it pointing at a beat on the far
        // side of the artifact would make the starvation logic bleed SPKI away
        // immediately after we've just relearned it, and would let searchback
        // reach back across the gap.
        lastQRS = -1
    }

    /// Call once after the last chunk: flushes the learning phase if the
    /// recording was shorter than it, and runs a final searchback.
    func finish(endIndex: Int) {
        if learning { finishLearning() }
        attemptSearchback(before: endIndex + refractory)
    }

    // MARK: Learning phase

    private func finishLearning() {
        let buffered = learningBuffer
        learningBuffer.removeAll()
        learning = false

        guard !buffered.isEmpty else { return }

        // PT initialises the estimators from the first couple of seconds.
        //
        // The naive "signal peak = largest peak seen" is unsafe here, because a
        // relearn is usually triggered *by* artifact and the acquisition window
        // sits right next to one. But clamping against the median peak — which
        // is a *noise* peak — is worse: on a clean recording with a tall, thin
        // R wave the real QRS sits hundreds of times above the noise, and the
        // clamp drags SPKI down far below the beats it is supposed to describe.
        //
        // Instead, take the median of the top K peaks, where K is roughly how
        // many beats the acquisition window should contain. One artifact edge
        // cannot move a median; a run of comparable QRS peaks defines it.
        let peaksI = buffered.map { $0.integralPeak }.sorted()
        let peaksF = buffered.map { $0.filteredPeak }.sorted()

        let learningSeconds = Double(learningSamples) / fs
        let expectedBeats = max(2, Int((learningSeconds * 1.5).rounded()))   // ~90 bpm
        let k = min(expectedBeats, peaksI.count)

        spki = peaksI[peaksI.count - 1 - (k - 1) / 2]
        spkf = peaksF[peaksF.count - 1 - (k - 1) / 2]

        // Median rather than mean for the noise estimate: the mean is pulled up
        // by the QRS peaks it is meant to exclude.
        npki = peaksI[peaksI.count / 2]
        npkf = peaksF[peaksF.count / 2]

        if npki >= spki { npki = spki * 0.5 }
        if npkf >= spkf { npkf = spkf * 0.5 }
        recomputeThresholds()

        // `evaluate` can itself call `beginLearning` if it hits a run of
        // implausible peaks, so re-check rather than evaluating blindly.
        for c in buffered {
            if learning { learningBuffer.append(c) } else { evaluate(c) }
        }
    }

    // MARK: Core decision

    private func evaluate(_ c: ECGQRSCandidate) {

        // Implausibly large peak: artifact, not a beat. Crucially this updates
        // *neither* estimator, so it cannot move the threshold in either
        // direction. If it keeps happening the signal scale has genuinely
        // changed, and we relearn rather than reject forever.
        //
        // The ratio is expressed in the *amplitude* domain. The integrated
        // channel derives from the squared derivative, so an amplitude ratio r
        // shows up there as r² — comparing `integralPeak` against a plain
        // multiple of SPKI silently applies a limit of sqrt(ratio), which on a
        // clean tall-R recording rejects every real beat.
        //
        // Both channels must agree before anything is thrown away. Rejecting a
        // genuine QRS is far more costly than accepting a stray edge, which the
        // growth clamp below will contain anyway.
        if spki > 0, spkf > 0,
           c.integralPeak > artifactPeakRatio * artifactPeakRatio * spki,
           c.filteredPeak > artifactPeakRatio * spkf {
            artifactRejections += 1
            consecutiveArtifactRejections += 1
            if consecutiveArtifactRejections >= artifactRejectionsBeforeRelearn {
                beginLearning()
                learningBuffer.append(c)
            }
            return
        }
        consecutiveArtifactRejections = 0

        // A beat is overdue: go back and look for one we rejected too harshly.
        if lastQRS >= 0, rrAverage2 > 0 {
            var guardCount = 0
            while Double(c.index - lastQRS) > rrAverage2 * 1.66, guardCount < 8 {
                guard attemptSearchback(before: c.index) else { break }
                guardCount += 1
            }
        }

        // Starvation recovery. Classic Pan–Tompkins can deadlock: a single
        // oversized peak lifts SPKI, the threshold rises above every real beat,
        // and because SPKI only updates on accepted beats it never comes back
        // down. If nothing has been accepted for well over the expected
        // interval, bleed SPKI back toward the noise estimate so the detector
        // can re-acquire.
        if lastQRS >= 0 {
            let starvation = rrAverage2 > 0 ? rrAverage2 * 3.0 : 3.0 * fs
            if Double(c.index - lastQRS) > starvation {
                spki = npki + 0.75 * (spki - npki)
                spkf = npkf + 0.75 * (spkf - npkf)
                recomputeThresholds()
            }
        }

        // Absolute refractory period. Nothing here can be a beat.
        if lastQRS >= 0, c.index - lastQRS < refractory {
            return
        }

        let isSignal = c.integralPeak > thresholdI1 && c.filteredPeak > thresholdF1

        if isSignal {
            // T-wave discrimination: a peak arriving 200–360 ms after a QRS
            // with less than half its steepness is a T wave, not a beat.
            // This is what the old code approximated with a blunt 280 ms
            // refractory period.
            if lastQRS >= 0, c.index - lastQRS < tWaveWindow, lastQRSSlope > 0 {
                if c.slope < 0.5 * lastQRSSlope {
                    classifyAsNoise(c)
                    return
                }
            }
            accept(c, viaSearchback: false)
        } else {
            classifyAsNoise(c)
        }
    }

    private func classifyAsNoise(_ c: ECGQRSCandidate) {
        npki = 0.125 * c.integralPeak + 0.875 * npki
        npkf = 0.125 * c.filteredPeak + 0.875 * npkf
        pendingNoise.append(c)
        recomputeThresholds()
    }

    @discardableResult
    private func attemptSearchback(before limit: Int) -> Bool {
        guard lastQRS >= 0, !pendingNoise.isEmpty else { return false }

        let windowStart = lastQRS + refractory
        let windowEnd = limit - refractory
        guard windowStart < windowEnd else { return false }

        // The paper takes the *largest* qualifying peak in the gap. The old
        // code took every crossing it found, which manufactured extra beats
        // in noisy stretches.
        var best: ECGQRSCandidate?
        for c in pendingNoise where c.index > windowStart && c.index < windowEnd {
            guard c.integralPeak > thresholdI2, c.filteredPeak > thresholdF2 else { continue }
            // Never recover a beat out of a region we've declared unreadable.
            if let mask = artifactMask, mask.contains(c.index) { continue }
            if best == nil || c.integralPeak > best!.integralPeak { best = c }
        }

        guard let found = best else { return false }
        accept(found, viaSearchback: true)
        return true
    }

    private func accept(_ c: ECGQRSCandidate, viaSearchback: Bool) {

        // Searchback beats update the estimators faster (0.25 vs 0.125), as
        // in the paper, because the threshold clearly needs to come down.
        let alpha: Float = viaSearchback ? 0.25 : 0.125

        // Growth clamp. The paper assumes a peak that passed the threshold is a
        // genuine QRS, so it lets SPKI follow it anywhere. A surviving artifact
        // edge exploits that to lift the threshold above every subsequent beat.
        // Squared for the integrated channel, for the same reason as above.
        let boundedI = spki > 0
            ? min(c.integralPeak, spki * maximumSPKIGrowth * maximumSPKIGrowth)
            : c.integralPeak
        let boundedF = spkf > 0 ? min(c.filteredPeak, spkf * maximumSPKIGrowth) : c.filteredPeak

        spki = alpha * boundedI + (1 - alpha) * spki
        spkf = alpha * boundedF + (1 - alpha) * spkf

        if lastQRS >= 0 && !suppressNextRR {
            let rr = c.index - lastQRS
            pushRR(rr)
        }
        suppressNextRR = false

        let margin = c.integralPeak - thresholdI1
        let span = max(spki - thresholdI1, 1e-6)
        var confidence = 0.5 + 0.5 * Double(min(max(margin / span, 0), 1))
        if viaSearchback { confidence *= 0.6 }

        beats.append(c)
        confidences.append(confidence)

        lastQRS = c.index
        lastQRSSlope = c.slope
        pendingNoise.removeAll(keepingCapacity: true)
        recomputeThresholds()
    }

    private func pushRR(_ rr: Int) {
        rrRecent.append(rr)
        if rrRecent.count > 8 { rrRecent.removeFirst() }
        rrAverage1 = Double(rrRecent.reduce(0, +)) / Double(rrRecent.count)

        // RR_AVERAGE2 only accepts intervals within 92–116% of itself, so a
        // single ectopic beat cannot drag the rhythm model around. The old
        // code had one EMA with a three-beat memory and no gate at all.
        let low = rrAverage2 * 0.92
        let high = rrAverage2 * 1.16
        let normal = rrAverage2 == 0 || (Double(rr) >= low && Double(rr) <= high)

        if normal {
            rrSelected.append(rr)
            if rrSelected.count > 8 { rrSelected.removeFirst() }
            rrAverage2 = Double(rrSelected.reduce(0, +)) / Double(rrSelected.count)
            irregular = false
        } else {
            irregular = true
        }
    }

    private func recomputeThresholds() {
        thresholdI1 = npki + 0.25 * (spki - npki)
        thresholdF1 = npkf + 0.25 * (spkf - npkf)

        // Irregular rhythm: halve the thresholds so we adapt quickly rather
        // than missing the next several beats.
        if irregular {
            thresholdI1 *= 0.5
            thresholdF1 *= 0.5
        }

        thresholdI2 = 0.5 * thresholdI1
        thresholdF2 = 0.5 * thresholdF1

        if let last = thresholdTrace.last, last.index == lastQRS {
            thresholdTrace[thresholdTrace.count - 1] = (lastQRS, thresholdI1)
        } else {
            thresholdTrace.append((max(0, lastQRS), thresholdI1))
        }
    }
}

// MARK: - Analyser

final class ECGAnalyser {

    var valuesPerSecond: Double
    var valuesPerPoint: Double
    var timeRange: Range<Int>

    /// The range actually analysed, clamped to the data. The old code built
    /// `position..<(position+batchSize)` and let it run past `numValues`.
    private(set) var analysedRange: Range<Int>

    var sampleData = [Float]()
    var bandpassData = [Float]()
    var diffData = [Float]()
    var squaredData = [Float]()
    var integralData = [Float]()
    var widebandData = [Float]()
    var thresholds = [Float]()
    var waves = [ECGAnalyserWave]()

    /// Extra samples pulled in on each side so the filters and the peak
    /// refinement have context; trimmed off before anything is published.
    private var contextSamples: Int { max(8, Int(2.0 * valuesPerSecond)) }

    /// Optional artifact mask, so a plotted window agrees with what the
    /// whole-recording pass concluded.
    var artifactMask: ECGArtifactMask?

    init(with data: ECGData, range: Range<Int>, artifactMask: ECGArtifactMask? = nil) {
        valuesPerSecond = data.samplesPerSecond
        valuesPerPoint = data.valuesPerPoint
        timeRange = range
        self.artifactMask = artifactMask

        let lower = max(0, range.lowerBound)
        let upper = min(data.numValues, max(lower, range.upperBound))
        analysedRange = lower..<upper

        update(with: data)
    }

    func update(with data: ECGData) {
        // Every buffer is cleared. `integralData` was previously never reset,
        // so a second call would have appended onto stale data.
        sampleData.removeAll(keepingCapacity: true)
        bandpassData.removeAll(keepingCapacity: true)
        diffData.removeAll(keepingCapacity: true)
        squaredData.removeAll(keepingCapacity: true)
        integralData.removeAll(keepingCapacity: true)
        widebandData.removeAll(keepingCapacity: true)
        thresholds.removeAll(keepingCapacity: true)
        waves.removeAll(keepingCapacity: true)

        guard analysedRange.count > 10, valuesPerSecond > 0 else { return }

        let padStart = max(0, analysedRange.lowerBound - contextSamples)
        let padEnd = min(data.numValues, analysedRange.upperBound + contextSamples)
        let padded = data.getData(padStart..<padEnd).map { Float($0) }
        guard padded.count > 10 else { return }

        let channels = ECGSignalPipeline.process(padded, samplesPerSecond: valuesPerSecond)

        let coreStart = analysedRange.lowerBound - padStart
        let coreEnd = coreStart + analysedRange.count

        sampleData = Array(padded[coreStart..<coreEnd])
        bandpassData = Array(channels.bandpass[coreStart..<coreEnd])
        diffData = Array(channels.derivative[coreStart..<coreEnd])
        squaredData = Array(channels.squared[coreStart..<coreEnd])
        integralData = Array(channels.integral[coreStart..<coreEnd])
        widebandData = Array(channels.wideband[coreStart..<coreEnd])

        let candidates = ECGSignalPipeline.candidates(in: channels,
                                                      coreRange: coreStart..<coreEnd,
                                                      globalOffset: padStart,
                                                      samplesPerSecond: valuesPerSecond)

        let detector = ECGPanTompkinsDetector(samplesPerSecond: valuesPerSecond)
        detector.artifactMask = artifactMask
        detector.process(candidates)
        detector.finish(endIndex: analysedRange.upperBound)

        waves = ECGAnalyser.waves(from: detector.beats,
                                  confidences: detector.confidences,
                                  rangeStart: analysedRange.lowerBound)

        thresholds = ECGAnalyser.expandThresholdTrace(detector.thresholdTrace,
                                                      rangeStart: analysedRange.lowerBound,
                                                      count: integralData.count)
    }

    // MARK: Wave assembly

    fileprivate static func waves(from beats: [ECGQRSCandidate],
                                  confidences: [Double],
                                  rangeStart: Int) -> [ECGAnalyserWave] {
        var out = [ECGAnalyserWave]()
        out.reserveCapacity(beats.count * 3)

        for (i, beat) in beats.enumerated() {
            let confidence = i < confidences.count ? confidences[i] : 1.0

            if let q = beat.qIndex {
                out.append(ECGAnalyserWave(type: .q,
                                           globalOffset: q,
                                           offset: q - rangeStart,
                                           confidence: confidence))
            }
            out.append(ECGAnalyserWave(type: .r,
                                       globalOffset: beat.rIndex,
                                       offset: beat.rIndex - rangeStart,
                                       confidence: confidence,
                                       subSampleOffset: Double(beat.rFraction)))
            if let s = beat.sIndex {
                out.append(ECGAnalyserWave(type: .s,
                                           globalOffset: s,
                                           offset: s - rangeStart,
                                           confidence: confidence))
            }
        }
        // P, T and U are deliberately not emitted. They live below 5 Hz and a
        // 5–15 Hz channel destroys them; delineating them needs a separate,
        // wider passband and a different algorithm.
        return out
    }

    /// Turns the sparse (index, threshold) trace into a per-sample series so
    /// it can be drawn over `integralData`. Both are now in the same units —
    /// the old `/33.0` display fudge is gone.
    fileprivate static func expandThresholdTrace(_ trace: [(index: Int, value: Float)],
                                                 rangeStart: Int,
                                                 count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var out = [Float](repeating: trace.first?.value ?? 0, count: count)
        guard !trace.isEmpty else { return out }

        var t = 0
        var current = trace[0].value
        for i in 0..<count {
            let global = rangeStart + i
            while t < trace.count && trace[t].index <= global {
                current = trace[t].value
                t += 1
            }
            out[i] = current
        }
        return out
    }

    // MARK: - Utilities (kept from the original, corrected)

    class func median(_ windowSize: Int, input: [Float]) -> [Float] {
        guard windowSize > 1, !input.isEmpty else { return input }
        var result = [Float]()
        result.reserveCapacity(input.count)
        var window = [Float]()
        window.reserveCapacity(windowSize)
        for i in 0..<input.count {
            window.removeAll(keepingCapacity: true)
            for ii in 0..<windowSize {
                let index = min(input.count - 1, max(0, i - windowSize / 2 + ii))
                window.append(input[index])
            }
            window.sort()
            // True median for even windows too, rather than the upper element.
            if windowSize % 2 == 0 {
                result.append((window[windowSize / 2 - 1] + window[windowSize / 2]) * 0.5)
            } else {
                result.append(window[windowSize / 2])
            }
        }
        return result
    }

    class func average(_ windowSize: Int, input: [Float]) -> [Float] {
        guard windowSize > 1, !input.isEmpty else { return input }
        var result = [Float]()
        result.reserveCapacity(input.count)
        for i in 0..<input.count {
            var sum = Float.zero
            for ii in 0..<windowSize {
                let index = min(input.count - 1, max(0, i - windowSize / 2 + ii))
                sum += input[index]
            }
            result.append(sum / Float(windowSize))
        }
        return result
    }

    // MARK: - Whole-recording analysis

    /// Streams the whole recording through one detector. Chunks tile exactly
    /// (no overlap) and each chunk is filtered with real context on both
    /// sides, so there are no duplicate beats to deduplicate, no beats lost at
    /// a boundary, and the thresholds and RR averages never re-learn from
    /// scratch mid-recording.
    class func analyze(data: ECGData,
                       measureQT: Bool = false,
                       qtOptions: ECGQTOptions = ECGQTOptions(),
                       detectArtifacts: Bool = true,
                       artifactOptions: ECGArtifactOptions = ECGArtifactOptions(),
                       analyseRhythm: Bool = true,
                       rhythmOptions: ECGRhythmOptions = ECGRhythmOptions(),
                       progress: ((Float) -> Void)?) -> ECGAnalyserAnalysis {

        let result = ECGAnalyserAnalysis()
        let fs = data.samplesPerSecond
        let total = data.numValues
        result.samplesPerSecond = fs

        guard total > 10, fs > 0 else { return result }

        // Prepass: find the unreadable regions before trying to detect in them.
        let mask = detectArtifacts
            ? ECGSignalQuality.detectArtifacts(data: data, options: artifactOptions)
            : ECGArtifactMask(totalSamples: total)
        result.artifactMask = mask

        let chunkSize = max(1024, Int(30.0 * fs))
        let context = max(8, Int(2.0 * fs))

        let detector = ECGPanTompkinsDetector(samplesPerSecond: fs)
        detector.artifactMask = mask

        var position = 0
        while position < total {
            let coreEnd = min(position + chunkSize, total)
            let padStart = max(0, position - context)
            let padEnd = min(total, coreEnd + context)

            let padded = data.getData(padStart..<padEnd).map { Float($0) }
            if padded.count > 10 {
                let channels = ECGSignalPipeline.process(padded, samplesPerSecond: fs)
                let candidates = ECGSignalPipeline.candidates(
                    in: channels,
                    coreRange: (position - padStart)..<(coreEnd - padStart),
                    globalOffset: padStart,
                    samplesPerSecond: fs)
                detector.process(candidates)
            }

            position = coreEnd
            progress?(Float(position) / Float(total))
        }
        detector.finish(endIndex: total)

        result.waves = ECGAnalyser.waves(from: detector.beats,
                                         confidences: detector.confidences,
                                         rangeStart: 0)

        // MARK: rhythm statistics

        let rPeaks = detector.beats.map { $0.rIndex }
        // Fractional positions, so interval precision is not limited to one
        // sample. At 130 Hz the grid alone contributes about 3 ms of RMS noise
        // to every interval, which is a real fraction of a resting RMSSD.
        let rPositions = detector.beats.map { $0.rPosition }
        var rrMs = [Int]()
        var rrPrecise = [Double]()
        var hrs = [Float]()
        rrMs.reserveCapacity(max(0, rPeaks.count - 1))

        for i in 1..<max(1, rPeaks.count) {
            let samples = rPositions[i] - rPositions[i - 1]
            guard samples > 0 else { continue }

            // An interval that straddles an artifact is not a real beat-to-beat
            // interval — there are almost certainly beats hidden inside it.
            // Counting it would wreck SDNN and invent a bradycardia.
            if mask.intersects(rPeaks[i - 1]..<rPeaks[i]) { continue }

            let seconds = samples / fs
            let hr = 60.0 / seconds
            rrMs.append(Int((seconds * 1000).rounded()))
            rrPrecise.append(seconds * 1000)
            // Only physiologically plausible rates reach the statistics, so a
            // single detector glitch can no longer define maxHR.
            if hr >= 20 && hr <= 250 {
                hrs.append(Float(hr.rounded()))
            }
        }

        result.rrIntervalsMs = rrMs
        result.instantHeartRates = hrs

        if !hrs.isEmpty {
            let smoothed = ECGAnalyser.median(5, input: hrs)
            result.maxHR = Int(smoothed.max() ?? 0)
            result.minHR = Int(smoothed.min() ?? 0)
            result.meanHR = smoothed.reduce(0, +) / Float(smoothed.count)

            // Legacy downsampled display track. Clamped — the old
            // `UInt8(...)` conversion trapped at runtime above 255 bpm.
            result.heartRates.reserveCapacity(smoothed.count / 5)
            for i in 0..<(smoothed.count / 5) {
                let v = smoothed[i * 5 + 2]
                result.heartRates.append(UInt8(min(max(v, 0), 255)))
            }
        }

        result.artifactRejections = detector.artifactRejections

        ECGAnalyser.computeHRV(rrPrecise, into: result)

        // MARK: rhythm

        if analyseRhythm {
            result.rhythm = ECGRhythmAnalyser.analyse(rPeaks: rPeaks,
                                                      confidences: detector.confidences,
                                                      samplesPerSecond: fs,
                                                      artifactMask: mask,
                                                      options: rhythmOptions)
        }

        // MARK: QT

        if measureQT {
            // Only beats with a clean window either side are usable for a
            // median beat, so masked ones are dropped before binning.
            var cleanPeaks = [Int]()
            var cleanConfidences = [Double]()
            let halo = Int((qtOptions.preSeconds + qtOptions.postSeconds) * fs)
            for (i, p) in rPeaks.enumerated() {
                let window = max(0, p - halo)..<min(total, p + halo)
                if mask.intersects(window) { continue }
                cleanPeaks.append(p)
                cleanConfidences.append(i < detector.confidences.count ? detector.confidences[i] : 1.0)
            }

            result.qt = ECGQTAnalyser.analyse(data: data,
                                              rPeaks: cleanPeaks,
                                              confidences: cleanConfidences,
                                              options: qtOptions)
        }

        return result
    }

    /// Time-domain HRV over intervals that survive a simple ectopic filter
    /// (successive intervals differing by more than 20% are excluded).
    private class func computeHRV(_ rrMs: [Double], into result: ECGAnalyserAnalysis) {
        guard rrMs.count > 2 else { return }

        var clean = [Double]()
        for i in 1..<rrMs.count {
            let a = rrMs[i - 1]
            let b = rrMs[i]
            if abs(b - a) / max(a, 1) <= 0.20 {
                if clean.isEmpty { clean.append(rrMs[i - 1]) }
                clean.append(rrMs[i])
            }
        }
        guard clean.count > 2 else { return }

        let mean = clean.reduce(0, +) / Double(clean.count)
        let variance = clean.reduce(0.0) { $0 + pow($1 - mean, 2) } / Double(clean.count)
        result.sdnnMs = Float(variance.squareRoot())

        var sumSquares = 0.0
        var over50 = 0
        for i in 1..<clean.count {
            let d = clean[i] - clean[i - 1]
            sumSquares += d * d
            if abs(d) > 50 { over50 += 1 }
        }
        let pairs = Double(clean.count - 1)
        result.rmssdMs = Float((sumSquares / pairs).squareRoot())
        result.pnn50 = Float(Double(over50) / pairs * 100.0)
    }
}
