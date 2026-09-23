//
//  ECGQTAnalyser.swift
//  H10ECG
//
//  QT / QTc measurement from a median (ensemble-averaged) beat.
//
//  The approach, and why each step is there:
//
//   1. A *separate* signal channel. The 5–15 Hz Pan–Tompkins band is built to
//      destroy everything that isn't a QRS, which includes the entire T wave.
//      Delineation runs on a lightly lowpassed copy of the raw signal instead.
//
//   2. Per-beat linear detrend between isoelectric anchors (the PQ segment of
//      this beat and of the next). Baseline drift is the single largest error
//      source in T-offset measurement, and a highpass filter fixes drift by
//      distorting the ST segment — which is the thing being measured. Two
//      anchor points and a straight line avoid that trade entirely.
//
//   3. Beats grouped into narrow RR bins before averaging. QT is rate
//      dependent; averaging a 55 bpm beat with a 90 bpm beat smears the T wave
//      into uselessness. Binning also yields a QT/RR curve for free, which is
//      more informative than any single QTc.
//
//   4. Rate *stability* required, not just rate similarity. QT lags a change
//      in heart rate by one to two minutes (QT/RR hysteresis), so a beat at
//      800 ms RR taken 10 seconds after a sprint has a QT that belongs to the
//      old rate. Beats are only used when the trailing RR average agrees with
//      the local RR.
//
//   5. Morphology rejection by cross-correlation against a provisional
//      template, so ectopics and artifact don't contaminate the average.
//
//   6. Sub-sample alignment, then cubic upsampling of the finished median beat.
//      At 130 Hz one sample is 7.7 ms — quantising QT to that is hopeless when
//      the numbers people care about are 20 ms apart. Interpolating a smooth,
//      heavily averaged waveform genuinely does buy precision here, though it
//      obviously cannot buy bandwidth. See the accuracy note at the bottom.
//
//   7. Median rather than mean across beats. Slightly worse noise suppression,
//      much better outlier rejection — the usual choice for a chest strap.
//

import Foundation

// MARK: - Configuration

struct ECGQTOptions {

    /// Segment window around each R peak.
    var preSeconds: Double = 0.30
    var postSeconds: Double = 0.65

    /// RR bin width. Narrower means cleaner T waves but fewer beats per bin.
    var rrBinWidthSeconds: Double = 0.04

    /// Bins below this are discarded.
    var minimumBeatsPerBin: Int = 30

    /// Cap on beats retained per bin (reservoir-sampled across the recording,
    /// so a long tail doesn't blow up memory and the sample stays representative).
    var maximumBeatsPerBin: Int = 400

    /// Physiological RR bounds.
    var minimumRRSeconds: Double = 0.30
    var maximumRRSeconds: Double = 2.00

    /// Beat-to-beat rhythm stability: this RR versus the previous one.
    var maximumRRStepFraction: Double = 0.12

    /// QT/RR hysteresis guard: this RR versus the trailing average.
    var trailingWindowSeconds: Double = 60.0
    var maximumTrailingDeviation: Double = 0.10

    /// Template correlation floor for a beat to enter the average.
    var minimumCorrelation: Float = 0.90

    /// Maximum realignment shift applied during template matching.
    var maximumAlignmentShiftSeconds: Double = 0.030

    /// Lowpass applied to the delineation channel.
    var lowpassHz: Double = 40.0

    /// Target rate for the interpolated median beat.
    var delineationRateHz: Double = 1000.0

    /// Minimum R-wave detection confidence for a beat to be eligible.
    var minimumBeatConfidence: Double = 0.5

    init() {}
}

// MARK: - Results

enum ECGQTQuality {
    case good
    case fair
    case poor
}

/// One ensemble-averaged beat and the measurements taken from it.
struct ECGMedianBeat {
    /// Interpolated waveform, isoelectric level subtracted.
    var samples: [Float]
    var samplesPerSecond: Double
    /// Index of the R peak within `samples`.
    var rIndex: Int
    var beatCount: Int
    var meanCorrelation: Float
    var meanRRSeconds: Double
    /// Interquartile spread of the RR intervals that contributed.
    var rrSpreadSeconds: Double
    /// Residual noise after averaging, in signal units, measured on the TP segment.
    var residualNoise: Float

    func seconds(at index: Int) -> Double {
        return Double(index - rIndex) / samplesPerSecond
    }
}

struct ECGQTMeasurement {

    var meanRRSeconds: Double
    var heartRate: Double
    var beatsAveraged: Int
    var meanCorrelation: Float
    var quality: ECGQTQuality

    /// All offsets are seconds relative to the R peak. Negative is before R.
    var qOnsetSeconds: Double
    var qrsOffsetSeconds: Double
    var tPeakSeconds: Double
    var tEndSeconds: Double
    /// Independent estimate from the amplitude-threshold method, for cross-check.
    var tEndThresholdSeconds: Double

    var qrsDurationSeconds: Double
    var qtSeconds: Double
    var jtSeconds: Double
    var tPeakTEndSeconds: Double

    var tWaveIsPositive: Bool
    var tWaveAmplitude: Float

    // Rate corrections. All in seconds.
    var qtcBazett: Double
    var qtcFridericia: Double
    var qtcFramingham: Double
    var qtcHodges: Double

    var qtMs: Int { Int((qtSeconds * 1000).rounded()) }
    var qtcFridericiaMs: Int { Int((qtcFridericia * 1000).rounded()) }
    var qtcBazettMs: Int { Int((qtcBazett * 1000).rounded()) }

    /// Agreement between the tangent and threshold estimates of T end. Large
    /// disagreement means a flat or noisy T wave and an untrustworthy QT.
    var tEndDisagreementSeconds: Double {
        return abs(tEndSeconds - tEndThresholdSeconds)
    }
}

struct ECGQTAnalysis {
    /// One entry per RR bin that had enough clean beats, ordered by rate.
    var measurements = [ECGQTMeasurement]()
    var medianBeats = [ECGMedianBeat]()

    /// The bin with the most contributing beats — usually the resting rate,
    /// and the one to quote if you only quote one.
    var representative: ECGQTMeasurement?
    var representativeBeat: ECGMedianBeat?

    /// Slope of QT against RR across bins, seconds per second. Useful as a
    /// sanity check: a healthy relationship is roughly 0.15–0.20.
    var qtRRSlope: Double?

    var beatsConsidered: Int = 0
    var beatsUsed: Int = 0
}

// MARK: - Analyser

enum ECGQTAnalyser {

    /// - Parameters:
    ///   - rPeaks: global sample indices of detected R waves, ascending.
    ///   - confidences: parallel to `rPeaks`; pass an empty array to skip gating.
    static func analyse(data: ECGData,
                        rPeaks: [Int],
                        confidences: [Double] = [],
                        options: ECGQTOptions = ECGQTOptions()) -> ECGQTAnalysis {

        var analysis = ECGQTAnalysis()
        let fs = data.samplesPerSecond
        let total = data.numValues
        guard fs > 0, total > 0, rPeaks.count > 4 else { return analysis }

        let preSamples = max(2, Int(options.preSeconds * fs))
        let postSamples = max(2, Int(options.postSeconds * fs))
        let segmentLength = preSamples + postSamples + 1

        // MARK: beat eligibility

        let eligible = selectBeats(rPeaks: rPeaks,
                                   confidences: confidences,
                                   samplesPerSecond: fs,
                                   options: options)
        analysis.beatsConsidered = rPeaks.count

        guard !eligible.isEmpty else { return analysis }

        // MARK: bin, then extract

        var bins = [Int: BeatBin]()
        var rng = SeededRandom(seed: 0x5EED_1234)

        let blockSize = max(Int(60.0 * fs), segmentLength * 4)
        let context = max(Int(3.0 * fs), segmentLength * 2)

        var cursor = 0                      // index into `eligible`
        var position = 0

        let lowpass = [Biquad.lowpass(cutoff: min(options.lowpassHz, fs * 0.40),
                                      samplingRate: fs)]

        while position < total && cursor < eligible.count {
            let coreEnd = min(position + blockSize, total)

            // Beats whose R falls in this block.
            var blockBeats = [EligibleBeat]()
            var scan = cursor
            while scan < eligible.count && eligible[scan].rIndex < coreEnd {
                if eligible[scan].rIndex >= position { blockBeats.append(eligible[scan]) }
                scan += 1
            }
            cursor = scan

            if !blockBeats.isEmpty {
                let padStart = max(0, position - context)
                let padEnd = min(total, coreEnd + context)
                let raw = data.getData(padStart..<padEnd).map { Float($0) }

                if raw.count > 16 {
                    let clean = ECGSignalPipeline.filtfilt(raw,
                                                           sections: lowpass,
                                                           padLength: Int(fs))

                    for beat in blockBeats {
                        guard let segment = extractSegment(from: clean,
                                                           blockStart: padStart,
                                                           beat: beat,
                                                           preSamples: preSamples,
                                                           postSamples: postSamples,
                                                           samplesPerSecond: fs)
                        else { continue }

                        let key = Int((beat.rrSeconds / options.rrBinWidthSeconds).rounded(.down))
                        var bin = bins[key] ?? BeatBin()
                        bin.add(segment: segment,
                                rr: beat.rrSeconds,
                                limit: options.maximumBeatsPerBin,
                                rng: &rng)
                        bins[key] = bin
                    }
                }
            }
            position = coreEnd
        }

        // MARK: average and measure each bin

        for key in bins.keys.sorted() {
            guard let bin = bins[key], bin.segments.count >= options.minimumBeatsPerBin else { continue }

            guard let beat = buildMedianBeat(bin: bin,
                                             rIndex: preSamples,
                                             segmentLength: segmentLength,
                                             samplesPerSecond: fs,
                                             options: options)
            else { continue }

            analysis.beatsUsed += beat.beatCount

            let upsampled = upsampleBeat(beat, targetRate: options.delineationRateHz)
            guard let measurement = delineate(beat: upsampled, options: options) else { continue }

            analysis.medianBeats.append(upsampled)
            analysis.measurements.append(measurement)
        }

        analysis.measurements.sort { $0.meanRRSeconds < $1.meanRRSeconds }
        analysis.medianBeats.sort { $0.meanRRSeconds < $1.meanRRSeconds }

        if let best = analysis.measurements.enumerated()
            .filter({ $0.element.quality != .poor })
            .max(by: { $0.element.beatsAveraged < $1.element.beatsAveraged })
            ?? analysis.measurements.enumerated().max(by: { $0.element.beatsAveraged < $1.element.beatsAveraged }) {
            analysis.representative = best.element
            if best.offset < analysis.medianBeats.count {
                analysis.representativeBeat = analysis.medianBeats[best.offset]
            }
        }

        analysis.qtRRSlope = regressionSlope(analysis.measurements.filter { $0.quality != .poor })
        return analysis
    }

    // MARK: - Beat eligibility

    fileprivate struct EligibleBeat {
        let rIndex: Int
        let nextRIndex: Int?
        let rrSeconds: Double
    }

    private static func selectBeats(rPeaks: [Int],
                                    confidences: [Double],
                                    samplesPerSecond fs: Double,
                                    options: ECGQTOptions) -> [EligibleBeat] {

        guard rPeaks.count > 3 else { return [] }

        var rrs = [Double](repeating: 0, count: rPeaks.count)
        for i in 1..<rPeaks.count {
            rrs[i] = Double(rPeaks[i] - rPeaks[i - 1]) / fs
        }
        rrs[0] = rrs.count > 1 ? rrs[1] : 0

        // Trailing RR average for the hysteresis guard.
        var trailing = [Double](repeating: 0, count: rPeaks.count)
        var window = [Double]()
        var windowSum = 0.0
        var head = 0
        for i in 0..<rPeaks.count {
            window.append(rrs[i])
            windowSum += rrs[i]
            while head < window.count,
                  Double(rPeaks[i] - rPeaks[max(0, i - (window.count - head) + 1)]) / fs > options.trailingWindowSeconds,
                  window.count - head > 1 {
                windowSum -= window[head]
                head += 1
            }
            trailing[i] = windowSum / Double(window.count - head)
        }

        var result = [EligibleBeat]()
        result.reserveCapacity(rPeaks.count)

        for i in 2..<(rPeaks.count - 1) {
            let rr = rrs[i]
            guard rr >= options.minimumRRSeconds, rr <= options.maximumRRSeconds else { continue }

            // Rhythm stability: this interval versus the previous one. Rejects
            // ectopics and, importantly, the compensatory beat after them,
            // whose QT is genuinely different.
            let prev = rrs[i - 1]
            guard prev > 0, abs(rr - prev) / prev <= options.maximumRRStepFraction else { continue }
            let next = rrs[i + 1]
            guard next > 0, abs(next - rr) / rr <= options.maximumRRStepFraction else { continue }

            // QT/RR hysteresis: the rate must have been where it is for a while.
            let tr = trailing[i]
            guard tr > 0, abs(rr - tr) / tr <= options.maximumTrailingDeviation else { continue }

            if i < confidences.count, confidences[i] < options.minimumBeatConfidence { continue }

            result.append(EligibleBeat(rIndex: rPeaks[i],
                                       nextRIndex: rPeaks[i + 1],
                                       rrSeconds: rr))
        }
        return result
    }

    // MARK: - Segment extraction

    /// Pulls one beat out of the block and removes baseline drift by fitting a
    /// straight line through two isoelectric anchors: the PQ segment of this
    /// beat and the PQ segment of the next. No highpass filter touches the ST
    /// segment this way.
    private static func extractSegment(from block: [Float],
                                       blockStart: Int,
                                       beat: EligibleBeat,
                                       preSamples: Int,
                                       postSamples: Int,
                                       samplesPerSecond fs: Double) -> [Float]? {

        let r = beat.rIndex - blockStart
        let start = r - preSamples
        let end = r + postSamples
        guard start >= 0, end < block.count else { return nil }

        // Anchor 1: PQ segment of this beat, 100–60 ms before R.
        let a1Lo = r - Int(0.100 * fs)
        let a1Hi = r - Int(0.060 * fs)
        guard a1Lo >= 0, a1Hi > a1Lo else { return nil }
        let anchor1 = medianOf(Array(block[a1Lo...a1Hi]))
        let anchor1X = Double((a1Lo + a1Hi) / 2 - start)

        var slope = 0.0
        var intercept = Double(anchor1)

        // Anchor 2: PQ segment of the next beat, if it is close enough to be
        // inside the window and the rhythm is slow enough for a real TP segment.
        if let nextR = beat.nextRIndex, beat.rrSeconds <= 1.5 {
            let n = nextR - blockStart
            let a2Lo = n - Int(0.120 * fs)
            let a2Hi = n - Int(0.070 * fs)
            if a2Lo > a1Hi, a2Hi < block.count, a2Hi > a2Lo {
                let anchor2 = medianOf(Array(block[a2Lo...a2Hi]))
                let anchor2X = Double((a2Lo + a2Hi) / 2 - start)
                if anchor2X > anchor1X {
                    slope = Double(anchor2 - anchor1) / (anchor2X - anchor1X)
                    intercept = Double(anchor1) - slope * anchor1X
                }
            }
        }

        var segment = [Float](repeating: 0, count: preSamples + postSamples + 1)
        for i in 0..<segment.count {
            let baseline = intercept + slope * Double(i)
            segment[i] = block[start + i] - Float(baseline)
        }
        return segment
    }

    // MARK: - Bins

    fileprivate struct BeatBin {
        var segments = [[Float]]()
        var rrs = [Double]()
        var seen = 0

        mutating func add(segment: [Float], rr: Double, limit: Int, rng: inout SeededRandom) {
            seen += 1
            if segments.count < limit {
                segments.append(segment)
                rrs.append(rr)
            } else {
                // Reservoir sampling keeps the retained beats spread across the
                // whole recording rather than clustered at the start.
                let j = rng.int(below: seen)
                if j < limit {
                    segments[j] = segment
                    rrs[j] = rr
                }
            }
        }
    }

    // MARK: - Median beat construction

    private static func buildMedianBeat(bin: BeatBin,
                                        rIndex: Int,
                                        segmentLength: Int,
                                        samplesPerSecond fs: Double,
                                        options: ECGQTOptions) -> ECGMedianBeat? {

        var segments = bin.segments.filter { $0.count == segmentLength }
        guard segments.count >= options.minimumBeatsPerBin else { return nil }

        let maxShift = max(1, Int(options.maximumAlignmentShiftSeconds * fs))

        // Correlation window: the QRS plus the early ST, which is where
        // morphology differences actually show up.
        let corrLo = max(0, rIndex - Int(0.08 * fs))
        let corrHi = min(segmentLength - 1, rIndex + Int(0.20 * fs))
        guard corrHi > corrLo + 4 else { return nil }

        var template = pointwiseMedian(segments, length: segmentLength)
        var correlations = [Float]()

        // Two passes: align and reject, rebuild template, repeat.
        for pass in 0..<2 {
            var accepted = [[Float]]()
            var acceptedCorr = [Float]()
            accepted.reserveCapacity(segments.count)

            for segment in segments {
                var bestShift = 0
                var bestCorr: Float = -2

                for shift in -maxShift...maxShift {
                    let c = correlation(segment, template,
                                        range: corrLo..<corrHi,
                                        shift: shift)
                    if c > bestCorr { bestCorr = c; bestShift = shift }
                }

                guard bestCorr >= options.minimumCorrelation else { continue }

                accepted.append(shifted(segment, by: bestShift))
                acceptedCorr.append(bestCorr)
            }

            guard accepted.count >= options.minimumBeatsPerBin else {
                if pass == 0 { return nil }
                break
            }
            segments = accepted
            correlations = acceptedCorr
            template = pointwiseMedian(segments, length: segmentLength)
        }

        guard segments.count >= options.minimumBeatsPerBin else { return nil }

        // Residual noise: spread across beats in the TP segment, where the
        // true signal should be flat. This is the honest error bar on the
        // averaged waveform.
        let noiseLo = max(0, rIndex - Int(0.28 * fs))
        let noiseHi = max(noiseLo + 1, rIndex - Int(0.16 * fs))
        var deviations = [Float]()
        for i in noiseLo..<noiseHi {
            for s in segments { deviations.append(abs(s[i] - template[i])) }
        }
        let noise = deviations.isEmpty ? 0 : medianOf(deviations) * 1.4826 / Float(Double(segments.count).squareRoot())

        let sortedRR = bin.rrs.sorted()
        let q1 = sortedRR[sortedRR.count / 4]
        let q3 = sortedRR[min(sortedRR.count - 1, 3 * sortedRR.count / 4)]

        return ECGMedianBeat(samples: template,
                             samplesPerSecond: fs,
                             rIndex: rIndex,
                             beatCount: segments.count,
                             meanCorrelation: correlations.isEmpty ? 0 : correlations.reduce(0, +) / Float(correlations.count),
                             meanRRSeconds: bin.rrs.reduce(0, +) / Double(bin.rrs.count),
                             rrSpreadSeconds: q3 - q1,
                             residualNoise: noise)
    }

    // MARK: - Delineation

    /// Tangent method for T offset, slope-threshold for QRS onset and offset.
    private static func delineate(beat: ECGMedianBeat,
                                  options: ECGQTOptions) -> ECGQTMeasurement? {

        let x = beat.samples
        let fs = beat.samplesPerSecond
        let r = beat.rIndex
        let n = x.count
        guard n > 32, r > 8, r < n - 8 else { return nil }

        // Smoothed derivative. The tangent method lives or dies on this being
        // stable, so it gets an 8 ms moving average.
        var d = [Float](repeating: 0, count: n)
        for i in 1..<(n - 1) { d[i] = (x[i + 1] - x[i - 1]) * 0.5 }
        d = ECGAnalyser.average(max(3, Int(0.008 * fs)), input: d)

        // Peak QRS slope sets the scale for the onset/offset thresholds.
        let qrsLo = max(1, r - Int(0.060 * fs))
        let qrsHi = min(n - 2, r + Int(0.060 * fs))
        var maxSlope: Float = 0
        for i in qrsLo...qrsHi { maxSlope = max(maxSlope, abs(d[i])) }
        guard maxSlope > 0 else { return nil }

        // QRS onset: walk back until the slope has been quiet for a few ms.
        let hold = max(2, Int(0.006 * fs))
        let onsetLimit = max(1, r - Int(0.120 * fs))
        var qOnset = onsetLimit
        var quiet = 0
        var i = r - 1
        while i > onsetLimit {
            if abs(d[i]) < 0.04 * maxSlope {
                quiet += 1
                if quiet >= hold { qOnset = i + hold; break }
            } else {
                quiet = 0
            }
            i -= 1
        }

        // Isoelectric level from the 40 ms before QRS onset.
        let baseLo = max(0, qOnset - Int(0.040 * fs))
        let baseHi = max(baseLo + 1, qOnset - Int(0.008 * fs))
        let baseline = Array(x[baseLo..<baseHi]).reduce(0, +) / Float(baseHi - baseLo)

        // QRS offset (J point). Deliberately a looser threshold — the J point
        // is genuinely ambiguous and errs are less costly here than at T end.
        let offsetLimit = min(n - 2, r + Int(0.140 * fs))
        var qrsOffset = offsetLimit
        quiet = 0
        i = r + 1
        while i < offsetLimit {
            if abs(d[i]) < 0.06 * maxSlope {
                quiet += 1
                if quiet >= hold { qrsOffset = i - hold; break }
            } else {
                quiet = 0
            }
            i += 1
        }

        // T wave search window. Stops short of where the next QRS would land.
        let searchLo = min(n - 4, qrsOffset + Int(0.020 * fs))
        let nextBeat = r + Int(beat.meanRRSeconds * fs) - Int(0.060 * fs)
        let searchHi = min(min(n - 3, nextBeat), r + Int(0.620 * beat.meanRRSeconds * fs))
        guard searchHi > searchLo + Int(0.040 * fs) else { return nil }

        // Largest deviation in the window sets the T amplitude scale.
        var tAmplitude: Float = 0
        for j in searchLo...searchHi { tAmplitude = max(tAmplitude, abs(x[j] - baseline)) }
        guard tAmplitude > 0 else { return nil }

        // Take the LAST significant lobe as the T peak, which is what the
        // tangent should be dropped from on a biphasic T wave.
        var tPeak = searchLo
        for j in (searchLo + 1)..<searchHi {
            let dev = abs(x[j] - baseline)
            guard dev >= 0.35 * tAmplitude else { continue }
            let isExtremum = (x[j] - x[j - 1]) * (x[j + 1] - x[j]) <= 0
            if isExtremum { tPeak = j }
        }
        let tPositive = x[tPeak] >= baseline

        // Steepest point on the limb returning to baseline.
        let limbHi = min(searchHi, tPeak + Int(0.220 * fs))
        var tangentIndex = -1
        var tangentSlope: Float = 0
        if limbHi > tPeak + 1 {
            for j in (tPeak + 1)...limbHi {
                let s = d[j]
                if tPositive ? (s < tangentSlope) : (s > tangentSlope) {
                    tangentSlope = s
                    tangentIndex = j
                }
            }
        }

        // Tangent intersection with the isoelectric line, in fractional samples.
        var tEnd = Double(limbHi)
        if tangentIndex > 0, abs(tangentSlope) > 1e-9 {
            let crossing = Double(tangentIndex) + Double(baseline - x[tangentIndex]) / Double(tangentSlope)
            if crossing > Double(tPeak), crossing < Double(searchHi) + 0.05 * fs {
                tEnd = crossing
            }
        }

        // Independent cross-check: first return to within 10% of T amplitude.
        var tEndThreshold = Double(limbHi)
        let peakDev = abs(x[tPeak] - baseline)
        if limbHi > tPeak {
            for j in (tPeak + 1)...limbHi where abs(x[j] - baseline) <= 0.10 * peakDev {
                tEndThreshold = Double(j)
                break
            }
        }

        // MARK: intervals

        let t = { (index: Double) -> Double in (index - Double(r)) / fs }
        let qOnsetS = t(Double(qOnset))
        let qrsOffsetS = t(Double(qrsOffset))
        let tPeakS = t(Double(tPeak))
        let tEndS = t(tEnd)
        let tEndThreshS = t(tEndThreshold)

        let qt = tEndS - qOnsetS
        let qrsDuration = qrsOffsetS - qOnsetS
        let rr = beat.meanRRSeconds
        let hr = rr > 0 ? 60.0 / rr : 0

        // MARK: quality

        var quality = ECGQTQuality.good
        let snr = beat.residualNoise > 0 ? tAmplitude / beat.residualNoise : .infinity
        if beat.beatCount < 60 || beat.meanCorrelation < 0.95 || snr < 10 { quality = .fair }
        if beat.beatCount < 30 || snr < 5 { quality = .poor }
        if abs(tEndS - tEndThreshS) > 0.040 { quality = .poor }
        if qt < 0.20 || qt > 0.70 { quality = .poor }
        if qrsDuration < 0.04 || qrsDuration > 0.20 { quality = .poor }

        return ECGQTMeasurement(
            meanRRSeconds: rr,
            heartRate: hr,
            beatsAveraged: beat.beatCount,
            meanCorrelation: beat.meanCorrelation,
            quality: quality,
            qOnsetSeconds: qOnsetS,
            qrsOffsetSeconds: qrsOffsetS,
            tPeakSeconds: tPeakS,
            tEndSeconds: tEndS,
            tEndThresholdSeconds: tEndThreshS,
            qrsDurationSeconds: qrsDuration,
            qtSeconds: qt,
            jtSeconds: tEndS - qrsOffsetS,
            tPeakTEndSeconds: tEndS - tPeakS,
            tWaveIsPositive: tPositive,
            tWaveAmplitude: tAmplitude,
            qtcBazett: rr > 0 ? qt / rr.squareRoot() : 0,
            qtcFridericia: rr > 0 ? qt / pow(rr, 1.0 / 3.0) : 0,
            qtcFramingham: qt + 0.154 * (1.0 - rr),
            qtcHodges: qt + 0.00175 * (hr - 60.0))
    }

    // MARK: - QT/RR regression

    private static func regressionSlope(_ m: [ECGQTMeasurement]) -> Double? {
        guard m.count >= 3 else { return nil }
        let n = Double(m.count)
        let meanX = m.reduce(0.0) { $0 + $1.meanRRSeconds } / n
        let meanY = m.reduce(0.0) { $0 + $1.qtSeconds } / n
        var num = 0.0, den = 0.0
        for e in m {
            let dx = e.meanRRSeconds - meanX
            num += dx * (e.qtSeconds - meanY)
            den += dx * dx
        }
        return den > 0 ? num / den : nil
    }

    // MARK: - Signal helpers

    private static func pointwiseMedian(_ segments: [[Float]], length: Int) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        var column = [Float](repeating: 0, count: segments.count)
        for i in 0..<length {
            for (j, s) in segments.enumerated() { column[j] = s[i] }
            out[i] = medianOf(column)
        }
        return out
    }

    private static func medianOf(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) * 0.5 : sorted[mid]
    }

    /// Normalised cross-correlation of `a` shifted by `shift` against `b`.
    private static func correlation(_ a: [Float], _ b: [Float],
                                    range: Range<Int>, shift: Int) -> Float {
        var sa = 0.0, sb = 0.0
        var count = 0
        for i in range {
            let j = i + shift
            guard j >= 0, j < a.count else { continue }
            sa += Double(a[j]); sb += Double(b[i]); count += 1
        }
        guard count > 4 else { return -2 }
        let ma = sa / Double(count), mb = sb / Double(count)

        var num = 0.0, da = 0.0, db = 0.0
        for i in range {
            let j = i + shift
            guard j >= 0, j < a.count else { continue }
            let va = Double(a[j]) - ma
            let vb = Double(b[i]) - mb
            num += va * vb; da += va * va; db += vb * vb
        }
        let den = (da * db).squareRoot()
        return den > 0 ? Float(num / den) : -2
    }

    private static func shifted(_ a: [Float], by shift: Int) -> [Float] {
        guard shift != 0 else { return a }
        var out = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            out[i] = a[min(a.count - 1, max(0, i + shift))]
        }
        return out
    }

    /// Catmull-Rom interpolation onto a finer grid. Buys measurement resolution
    /// on an already-smooth averaged waveform; it does not and cannot recover
    /// bandwidth lost at the ADC.
    private static func upsampleBeat(_ beat: ECGMedianBeat, targetRate: Double) -> ECGMedianBeat {
        let factor = max(1, Int((targetRate / beat.samplesPerSecond).rounded()))
        guard factor > 1 else { return beat }

        let x = beat.samples
        let n = x.count
        var out = [Float]()
        out.reserveCapacity(n * factor)

        @inline(__always) func sample(_ i: Int) -> Float {
            return x[min(n - 1, max(0, i))]
        }

        for i in 0..<n {
            let p0 = sample(i - 1), p1 = sample(i), p2 = sample(i + 1), p3 = sample(i + 2)
            for k in 0..<factor {
                let t = Float(k) / Float(factor)
                let t2 = t * t, t3 = t2 * t
                out.append(0.5 * ((2 * p1) +
                                  (-p0 + p2) * t +
                                  (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
                                  (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
            }
        }

        var result = beat
        result.samples = out
        result.samplesPerSecond = beat.samplesPerSecond * Double(factor)
        result.rIndex = beat.rIndex * factor
        return result
    }
}

// MARK: - Deterministic RNG

/// Small LCG so reservoir sampling is reproducible run to run.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func int(below n: Int) -> Int {
        guard n > 0 else { return 0 }
        return Int(next() >> 33) % n
    }
}
