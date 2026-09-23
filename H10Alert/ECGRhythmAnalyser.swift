//
//  ECGRhythmAnalyser.swift
//  H10ECG
//
//  Detection of irregularly irregular rhythm — the RR signature of atrial
//  fibrillation — from the R-wave series alone.
//
//  IMPORTANT, and please carry this through into the UI: this identifies
//  *irregularity*, not atrial fibrillation. The RR series cannot distinguish AF
//  from atrial flutter with variable block, multifocal atrial tachycardia, or
//  frequent atrial ectopy, because all of them look irregular. Confirming AF
//  needs the atrial activity itself — absent P waves, fibrillatory baseline —
//  which a single chest-strap lead is poorly placed to show and which this code
//  does not attempt. Label the output "irregular rhythm", surface it as a
//  prompt to seek a proper recording, and never as a diagnosis.
//
//  The features are the standard published ones for short RR segments:
//
//    * Normalised RMSSD — beat-to-beat variability scaled by rate.
//    * Coefficient of Sample Entropy (Lake & Moorman 2011), which is sample
//      entropy corrected for the scale of the tolerance and the mean interval.
//      It is the strongest single discriminator on short windows.
//    * Shannon entropy of the normalised RR-difference histogram.
//
//  What actually separates a usable detector from a noisy one is not the
//  features, it's the suppression logic. The two things that masquerade as AF
//  are ectopy (bigeminy produces a huge RMSSD) and missed or spurious beats.
//  Both are patterned or localised rather than random, so both are testable:
//
//    * Alternation index — lag-1 autocorrelation of the RR differences. An
//      independent RR series sits near 0.5 by construction; bigeminy runs to
//      1.0 because every short interval is followed by a long one.
//    * Cluster separation — the largest gap in the sorted RR values relative
//      to their spread. Bigeminy is bimodal and shows a wide gap; AF fills the
//      distribution smoothly.
//    * Windows are never allowed to span an artifact span, since one missed
//      beat is enough to make a regular rhythm look chaotic.
//

import Foundation

// MARK: - Options

struct ECGRhythmOptions {

    /// Beats per analysis window. 32 is a reasonable compromise: long enough
    /// for the entropy estimates to settle, short enough to localise an episode.
    var windowBeats: Int = 32

    /// Window advance.
    var stepBeats: Int = 8

    /// Clinical convention treats 30 seconds as the minimum reportable episode.
    var minimumEpisodeSeconds: Double = 30.0

    /// Episodes separated by less than this are treated as one.
    var mergeGapSeconds: Double = 15.0

    /// Consecutive positive windows needed to open an episode.
    var requiredConsecutiveWindows: Int = 2

    // Feature ramps: score 0 at the low end, 1 at the high end.
    var rmssdRamp: (low: Float, high: Float) = (0.06, 0.14)
    var cosEnRamp: (low: Float, high: Float) = (-2.0, -1.0)
    var shannonRamp: (low: Float, high: Float) = (0.60, 0.85)

    /// Combined score needed to call a window irregular.
    var scoreThreshold: Float = 0.60

    /// Above this, the rhythm is patterned rather than random — almost always
    /// bigeminy or trigeminy. This is the knob to reach for if ectopy is
    /// producing false positives.
    var maximumAlternationIndex: Float = 0.80

    /// Above this, the RR distribution is bimodal — again, ectopy.
    var maximumClusterSeparation: Float = 0.30

    /// Plausibility gates.
    var minimumRRSeconds: Double = 0.25
    var maximumRRSeconds: Double = 3.00
    var minimumHeartRate: Double = 30
    var maximumHeartRate: Double = 200

    /// Beats below this detection confidence break the run.
    var minimumBeatConfidence: Double = 0.40

    /// Sample entropy parameters.
    var entropyToleranceFraction: Float = 0.03
    var entropyMinimumMatches: Int = 8

    init() {}
}

// MARK: - Results

enum ECGRhythmSuppression {
    case none
    case insufficientBeats
    case implausibleInterval
    case implausibleRate
    /// Alternating short/long pattern — bigeminy rather than fibrillation.
    case patterned
    /// Bimodal interval distribution — ectopy rather than fibrillation.
    case bimodal
}

struct ECGRhythmWindow {
    var sampleRange: Range<Int>
    var beatCount: Int
    var meanRRSeconds: Double
    var heartRate: Double

    var normalisedRMSSD: Float
    var cosEn: Float
    var shannonEntropy: Float
    var alternationIndex: Float
    var clusterSeparation: Float

    var score: Float
    var suppression: ECGRhythmSuppression
    var isIrregular: Bool
}

enum ECGRhythmConfidence {
    case low
    case moderate
    case high
}

struct ECGIrregularEpisode {
    var sampleRange: Range<Int>
    var startSeconds: Double
    var durationSeconds: Double
    var beatCount: Int
    var meanHeartRate: Double
    var meanScore: Float
    var meanNormalisedRMSSD: Float
    var meanCosEn: Float
    var confidence: ECGRhythmConfidence
}

struct ECGRhythmAnalysis {
    var windows = [ECGRhythmWindow]()
    var episodes = [ECGIrregularEpisode]()

    /// Seconds of clean, analysable rhythm.
    var analysedSeconds: Double = 0

    /// Proportion of analysed time inside an irregular episode. The nearest
    /// thing here to a "burden" figure — and only as good as the caveat at the
    /// top of this file.
    var irregularFraction: Double {
        guard analysedSeconds > 0 else { return 0 }
        let total = episodes.reduce(0.0) { $0 + $1.durationSeconds }
        return min(1.0, total / analysedSeconds)
    }
}

// MARK: - Analyser

enum ECGRhythmAnalyser {

    static func analyse(rPeaks: [Int],
                        confidences: [Double] = [],
                        samplesPerSecond fs: Double,
                        artifactMask: ECGArtifactMask? = nil,
                        options: ECGRhythmOptions = ECGRhythmOptions()) -> ECGRhythmAnalysis {

        var analysis = ECGRhythmAnalysis()
        guard fs > 0, rPeaks.count > options.windowBeats else { return analysis }

        // MARK: contiguous clean runs
        //
        // A window must never straddle an artifact. A single missed beat inside
        // one turns a metronomic rhythm into a convincing imitation of AF, so
        // the beat list is first cut into runs with nothing suspect between
        // consecutive beats.

        var runs = [[Int]]()
        var current = [Int]()

        for i in 0..<rPeaks.count {
            var breakRun = false

            if i > 0 {
                let span = rPeaks[i - 1]..<rPeaks[i]
                if let mask = artifactMask, mask.intersects(span) { breakRun = true }
                let rr = Double(rPeaks[i] - rPeaks[i - 1]) / fs
                if rr < options.minimumRRSeconds || rr > options.maximumRRSeconds { breakRun = true }
            }
            if i < confidences.count, confidences[i] < options.minimumBeatConfidence { breakRun = true }

            if breakRun {
                if current.count >= options.windowBeats { runs.append(current) }
                current = [rPeaks[i]]
            } else {
                current.append(rPeaks[i])
            }
        }
        if current.count >= options.windowBeats { runs.append(current) }

        // MARK: windows

        for run in runs {
            analysis.analysedSeconds += Double(run[run.count - 1] - run[0]) / fs

            var start = 0
            while start + options.windowBeats <= run.count {
                let beats = Array(run[start..<(start + options.windowBeats)])
                if let window = measureWindow(beats: beats, samplesPerSecond: fs, options: options) {
                    analysis.windows.append(window)
                }
                start += options.stepBeats
            }
        }

        analysis.windows.sort { $0.sampleRange.lowerBound < $1.sampleRange.lowerBound }
        analysis.episodes = assembleEpisodes(from: analysis.windows,
                                             samplesPerSecond: fs,
                                             options: options)
        return analysis
    }

    // MARK: - Window measurement

    /// Measures one window of consecutive beats. Exposed so the live monitor
    /// uses exactly these features rather than a causal reimplementation of
    /// them — the offline and streaming paths must not drift apart.
    static func measureWindow(beats: [Int],
                              samplesPerSecond fs: Double,
                              options: ECGRhythmOptions) -> ECGRhythmWindow? {

        guard beats.count >= 8 else { return nil }

        var rr = [Double]()
        rr.reserveCapacity(beats.count - 1)
        for i in 1..<beats.count { rr.append(Double(beats[i] - beats[i - 1]) / fs) }
        guard rr.count >= 6 else { return nil }

        let sampleRange = beats[0]..<(beats[beats.count - 1] + 1)
        let meanRR = rr.reduce(0, +) / Double(rr.count)
        let hr = meanRR > 0 ? 60.0 / meanRR : 0

        // Differences between successive intervals — the basis of every
        // feature below.
        var d = [Double]()
        for i in 1..<rr.count { d.append(rr[i] - rr[i - 1]) }

        let rmssd = (d.reduce(0.0) { $0 + $1 * $1 } / Double(d.count)).squareRoot()
        let nRMSSD = Float(meanRR > 0 ? rmssd / meanRR : 0)

        let cosEn = coefficientOfSampleEntropy(rr, options: options)
        let shannon = shannonEntropyOfDifferences(d, meanRR: meanRR)
        let alternation = alternationIndex(d)
        let separation = clusterSeparation(rr)

        // MARK: suppression

        var suppression = ECGRhythmSuppression.none
        if hr < options.minimumHeartRate || hr > options.maximumHeartRate {
            suppression = .implausibleRate
        } else if rr.contains(where: { $0 < options.minimumRRSeconds || $0 > options.maximumRRSeconds }) {
            suppression = .implausibleInterval
        } else if alternation > options.maximumAlternationIndex {
            suppression = .patterned
        } else if separation > options.maximumClusterSeparation {
            suppression = .bimodal
        }

        // MARK: score

        let score = (ramp(nRMSSD, options.rmssdRamp)
                     + ramp(cosEn, options.cosEnRamp)
                     + ramp(shannon, options.shannonRamp)) / 3.0

        return ECGRhythmWindow(sampleRange: sampleRange,
                               beatCount: beats.count,
                               meanRRSeconds: meanRR,
                               heartRate: hr,
                               normalisedRMSSD: nRMSSD,
                               cosEn: cosEn,
                               shannonEntropy: shannon,
                               alternationIndex: alternation,
                               clusterSeparation: separation,
                               score: score,
                               suppression: suppression,
                               isIrregular: suppression == .none && score >= options.scoreThreshold)
    }

    // MARK: - Features

    /// CosEn = SampEn(m=1, r) + ln(2r) − ln(mean RR).
    ///
    /// The tolerance is grown until enough template matches exist, which is
    /// what makes the measure usable on windows this short — a fixed tolerance
    /// frequently finds no matches at all and the entropy becomes undefined.
    private static func coefficientOfSampleEntropy(_ x: [Double],
                                                   options: ECGRhythmOptions) -> Float {
        let n = x.count
        guard n > 4 else { return -10 }
        let mean = x.reduce(0, +) / Double(n)
        guard mean > 0 else { return -10 }

        var r = Double(options.entropyToleranceFraction) * mean
        let maximumR = 0.5 * mean
        var a = 0, b = 0

        while r <= maximumR {
            (a, b) = matchCounts(x, tolerance: r)
            if b >= options.entropyMinimumMatches && a > 0 { break }
            r *= 1.15
        }
        if b == 0 { return -10 }

        // Continuity correction so a window with no length-2 matches — i.e. the
        // most irregular case there is — yields a large finite entropy rather
        // than an infinity.
        let aa = a > 0 ? Double(a) : 0.5
        let sampEn = -log(aa / Double(b))
        return Float(sampEn + log(2 * r) - log(mean))
    }

    /// Chebyshev-distance template match counts for m = 1 and m = 2.
    private static func matchCounts(_ x: [Double], tolerance r: Double) -> (Int, Int) {
        let n = x.count
        let last = n - 2               // vectors of length 2 need i+1 to exist
        guard last >= 1 else { return (0, 0) }

        var a = 0, b = 0
        // Unordered pairs i < j, both in 0...last. The outer loop must stop at
        // last - 1: at i == last the inner range would be (last+1)...last, and
        // Swift builds the range before any `where` clause can reject it.
        for i in 0..<last {
            for j in (i + 1)...last {
                if abs(x[i] - x[j]) <= r {
                    b += 1
                    if abs(x[i + 1] - x[j + 1]) <= r { a += 1 }
                }
            }
        }
        return (a, b)
    }

    /// Normalised Shannon entropy of the RR-difference histogram, scaled by
    /// mean RR so it is rate-independent.
    private static func shannonEntropyOfDifferences(_ d: [Double], meanRR: Double) -> Float {
        guard !d.isEmpty, meanRR > 0 else { return 0 }
        let bins = 16
        var counts = [Int](repeating: 0, count: bins)

        for value in d {
            // Normalised difference clamped to ±50% of the mean interval.
            let normalised = max(-0.5, min(0.5, value / meanRR))
            var bin = Int((normalised + 0.5) * Double(bins))
            bin = max(0, min(bins - 1, bin))
            counts[bin] += 1
        }

        let total = Double(d.count)
        var h = 0.0
        for c in counts where c > 0 {
            let p = Double(c) / total
            h -= p * log(p)
        }
        return Float(h / log(Double(bins)))
    }

    /// Lag-1 autocorrelation of the RR differences, sign-flipped so that
    /// alternating rhythms score high. An independent interval series sits near
    /// 0.5; bigeminy approaches 1.0.
    private static func alternationIndex(_ d: [Double]) -> Float {
        guard d.count > 3 else { return 0 }
        var num = 0.0, den = 0.0
        for i in 0..<(d.count - 1) { num += d[i] * d[i + 1] }
        for v in d { den += v * v }
        guard den > 0 else { return 0 }
        return Float(-num / den)
    }

    /// Largest gap in the sorted intervals, relative to their spread. A smooth
    /// unimodal distribution gives a small value; two tight clusters — the
    /// short-long pattern of ectopy — give a large one.
    private static func clusterSeparation(_ rr: [Double]) -> Float {
        guard rr.count > 6 else { return 0 }
        let sorted = rr.sorted()
        let lo = sorted[sorted.count / 20]
        let hi = sorted[sorted.count - 1 - sorted.count / 20]
        let spread = hi - lo
        guard spread > 0 else { return 0 }

        var largest = 0.0
        for i in 1..<sorted.count {
            largest = max(largest, sorted[i] - sorted[i - 1])
        }
        return Float(largest / spread)
    }

    private static func ramp(_ value: Float, _ bounds: (low: Float, high: Float)) -> Float {
        guard bounds.high > bounds.low else { return 0 }
        return max(0, min(1, (value - bounds.low) / (bounds.high - bounds.low)))
    }

    // MARK: - Episode assembly

    private static func assembleEpisodes(from windows: [ECGRhythmWindow],
                                         samplesPerSecond fs: Double,
                                         options: ECGRhythmOptions) -> [ECGIrregularEpisode] {

        guard !windows.isEmpty else { return [] }

        // Runs of consecutive irregular windows.
        var raw = [(range: Range<Int>, windows: [ECGRhythmWindow])]()
        var i = 0
        while i < windows.count {
            guard windows[i].isIrregular else { i += 1; continue }
            var j = i
            while j + 1 < windows.count && windows[j + 1].isIrregular { j += 1 }

            let count = j - i + 1
            if count >= options.requiredConsecutiveWindows {
                let group = Array(windows[i...j])
                raw.append((windows[i].sampleRange.lowerBound..<windows[j].sampleRange.upperBound, group))
            }
            i = j + 1
        }

        // Merge, then apply the duration floor.
        let mergeGap = Int(options.mergeGapSeconds * fs)
        var merged = [(range: Range<Int>, windows: [ECGRhythmWindow])]()
        for entry in raw {
            if var last = merged.last, entry.range.lowerBound - last.range.upperBound <= mergeGap {
                last.range = last.range.lowerBound..<max(last.range.upperBound, entry.range.upperBound)
                last.windows.append(contentsOf: entry.windows)
                merged[merged.count - 1] = last
            } else {
                merged.append(entry)
            }
        }

        let minimumSamples = Int(options.minimumEpisodeSeconds * fs)

        return merged.compactMap { entry -> ECGIrregularEpisode? in
            guard entry.range.count >= minimumSamples, !entry.windows.isEmpty else { return nil }

            let n = Float(entry.windows.count)
            let meanScore = entry.windows.reduce(0) { $0 + $1.score } / n
            let meanRMSSD = entry.windows.reduce(0) { $0 + $1.normalisedRMSSD } / n
            let meanCosEn = entry.windows.reduce(0) { $0 + $1.cosEn } / n
            let meanHR = entry.windows.reduce(0.0) { $0 + $1.heartRate } / Double(entry.windows.count)
            let duration = Double(entry.range.count) / fs

            var confidence = ECGRhythmConfidence.moderate
            if duration >= 120 && meanScore >= 0.75 { confidence = .high }
            if duration < 60 || meanScore < 0.68 { confidence = .low }

            return ECGIrregularEpisode(sampleRange: entry.range,
                                       startSeconds: Double(entry.range.lowerBound) / fs,
                                       durationSeconds: duration,
                                       beatCount: entry.windows.reduce(0) { $0 + $1.beatCount },
                                       meanHeartRate: meanHR,
                                       meanScore: meanScore,
                                       meanNormalisedRMSSD: meanRMSSD,
                                       meanCosEn: meanCosEn,
                                       confidence: confidence)
        }
    }
}

// MARK: - Live monitor

/// Streaming counterpart to `ECGRhythmAnalyser.analyse`. Fed one R peak at a
/// time, it maintains a rolling window and reports a rhythm state.
///
/// The features are identical — it calls the same `measureWindow` — so live and
/// offline cannot disagree about what a given 32 beats look like. What differs
/// is only that live has to commit to a verdict before seeing the rest of the
/// recording, which is handled with hysteresis rather than by weakening the
/// thresholds.
///
/// Note the inherent lag. At 32 beats per window, the first verdict needs
/// roughly 30 seconds of rhythm, and `.irregular` additionally waits for the
/// episode to reach `minimumEpisodeSeconds`. So a genuine episode is reported
/// about a minute after it starts. That delay is not a defect to tune away —
/// it is what stops a handful of ectopics from firing an alert. If a faster
/// live readout is wanted, shorten `windowBeats` for the monitor only and leave
/// the offline pass at its default.
enum ECGLiveRhythmState {
    /// Not enough consecutive clean beats yet.
    case acquiring
    /// Signal unreadable, or the beat run was broken.
    case unavailable
    case regular
    /// Windows are firing but the episode has not yet reached the minimum
    /// duration. Show this as "checking", not as a finding.
    case suspected
    /// Sustained irregularly irregular rhythm. Still not a diagnosis — see the
    /// warning at the top of this file.
    case irregular
}

final class ECGLiveRhythmMonitor {

    private let fs: Double
    private let options: ECGRhythmOptions

    /// Negative windows needed to close an episode. Deliberately larger than
    /// the opening requirement: AF is often paroxysmal and briefly organises,
    /// so closing eagerly fragments one episode into several.
    var windowsToClose: Int = 3

    private(set) var state: ECGLiveRhythmState = .acquiring
    private(set) var latestWindow: ECGRhythmWindow?

    /// Duration of the episode currently in progress, if any.
    private(set) var irregularDurationSeconds: Double = 0

    var onStateChanged: ((ECGLiveRhythmState) -> Void)?

    private var beats = [Int]()
    private var confidenceOK = true
    private var beatsSinceWindow = 0
    private var consecutivePositive = 0
    private var consecutiveNegative = 0
    private var episodeStart: Int?

    init(samplesPerSecond fs: Double, options: ECGRhythmOptions = ECGRhythmOptions()) {
        self.fs = fs
        self.options = options
    }

    func reset() {
        beats.removeAll(keepingCapacity: true)
        beatsSinceWindow = 0
        consecutivePositive = 0
        consecutiveNegative = 0
        episodeStart = nil
        irregularDurationSeconds = 0
        latestWindow = nil
        transition(to: .acquiring)
    }

    /// Called when the signal becomes unreadable, or anything else makes the
    /// beat sequence untrustworthy. One missed beat is enough to make a
    /// metronomic rhythm look like fibrillation, so the window is discarded
    /// rather than carried across the discontinuity.
    func breakRun() {
        beats.removeAll(keepingCapacity: true)
        beatsSinceWindow = 0
        consecutivePositive = 0
        consecutiveNegative = 0
        episodeStart = nil
        irregularDurationSeconds = 0
        transition(to: .unavailable)
    }

    func add(rIndex: Int, confidence: Double) {

        if confidence < options.minimumBeatConfidence {
            breakRun()
            return
        }

        if let last = beats.last {
            let rr = Double(rIndex - last) / fs
            if rr < options.minimumRRSeconds || rr > options.maximumRRSeconds {
                // Almost certainly a missed or spurious beat rather than real
                // physiology at this extreme. Start a fresh run from here.
                breakRun()
                beats.append(rIndex)
                transition(to: .acquiring)
                return
            }
        }

        // Ordered insert: searchback can in principle hand back a beat that
        // belongs earlier in the sequence.
        if let last = beats.last, rIndex < last {
            let i = beats.firstIndex { $0 > rIndex } ?? beats.count
            beats.insert(rIndex, at: i)
        } else {
            beats.append(rIndex)
        }

        if beats.count > options.windowBeats {
            beats.removeFirst(beats.count - options.windowBeats)
        }
        beatsSinceWindow += 1

        if state == .unavailable { transition(to: .acquiring) }

        guard beats.count >= options.windowBeats else { return }
        guard beatsSinceWindow >= options.stepBeats || latestWindow == nil else { return }
        beatsSinceWindow = 0

        guard let window = ECGRhythmAnalyser.measureWindow(beats: beats,
                                                           samplesPerSecond: fs,
                                                           options: options) else { return }
        latestWindow = window
        evaluate(window, at: rIndex)
    }

    private func evaluate(_ window: ECGRhythmWindow, at index: Int) {

        if window.isIrregular {
            consecutivePositive += 1
            consecutiveNegative = 0

            if consecutivePositive >= options.requiredConsecutiveWindows {
                if episodeStart == nil { episodeStart = window.sampleRange.lowerBound }
                if let start = episodeStart {
                    irregularDurationSeconds = Double(index - start) / fs
                    transition(to: irregularDurationSeconds >= options.minimumEpisodeSeconds
                               ? .irregular : .suspected)
                }
            }
            return
        }

        consecutiveNegative += 1
        consecutivePositive = 0

        if consecutiveNegative >= windowsToClose {
            episodeStart = nil
            irregularDurationSeconds = 0
            transition(to: .regular)
        }
    }

    private func transition(to newState: ECGLiveRhythmState) {
        guard newState != state else { return }
        state = newState
        onStateChanged?(newState)
    }
}
