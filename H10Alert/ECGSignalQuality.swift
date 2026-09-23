//
//  ECGSignalQuality.swift
//  H10ECG
//
//  Detection and masking of electrode-motion artifact — the huge low-frequency
//  swings you get from adjusting the strap, a loose electrode, or the belt
//  slipping during exercise.
//
//  Why the 5–15 Hz bandpass does not deal with these on its own:
//
//    * They are not actually low frequency. The event is a *step* in electrode
//      half-cell potential. A step has energy at every frequency, so a large
//      fraction of it lands squarely inside the QRS passband. "Low frequency"
//      describes the envelope, not the edges.
//
//    * A linear filter rings on a step. The 4th-order Butterworth, run
//      forward and backward, produces a decaying oscillation at roughly the
//      band centre — i.e. something that looks exactly like a QRS burst. The
//      zero-phase pass makes the ringing symmetric, so it also smears
//      *backwards* in time, corrupting a few hundred milliseconds of otherwise
//      clean signal before the event.
//
//    * Squaring amplifies the disparity. An artifact edge 20× the QRS in the
//      derivative becomes 400× after squaring.
//
//    * That poisons SPKI, and Pan–Tompkins has a deadlock here. THRESHOLD_I1
//      is 0.75·NPKI + 0.25·SPKI, so a single 400× peak drags the threshold far
//      above every real beat. SPKI only updates when a beat is *accepted* — so
//      nothing gets accepted, so SPKI never comes back down. Left alone, one
//      strap adjustment can cost you the rest of the recording.
//
//  So: detect the events explicitly, mask them, and harden the detector so
//  smaller ones can't poison it either.
//

import Foundation

// MARK: - Mask

/// Sample ranges considered unreadable. Sorted and non-overlapping.
struct ECGArtifactMask {

    private(set) var spans: [Range<Int>]
    let totalSamples: Int

    init(spans: [Range<Int>] = [], totalSamples: Int = 0) {
        self.spans = spans.sorted { $0.lowerBound < $1.lowerBound }
        self.totalSamples = totalSamples
    }

    var isEmpty: Bool { spans.isEmpty }

    var maskedSampleCount: Int {
        return spans.reduce(0) { $0 + $1.count }
    }

    var cleanFraction: Double {
        guard totalSamples > 0 else { return 1 }
        return 1.0 - Double(maskedSampleCount) / Double(totalSamples)
    }

    func contains(_ index: Int) -> Bool {
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if index < spans[mid].lowerBound { hi = mid - 1 }
            else if index >= spans[mid].upperBound { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    func intersects(_ range: Range<Int>) -> Bool {
        return maskedSamples(in: range) > 0
    }

    /// How many samples of `range` fall inside a masked span.
    func maskedSamples(in range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        var total = 0
        // Spans are sorted; walk from the first that could overlap.
        var i = 0
        var lo = 0, hi = spans.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].upperBound <= range.lowerBound { lo = mid + 1 } else { hi = mid - 1 }
        }
        i = lo
        while i < spans.count, spans[i].lowerBound < range.upperBound {
            let overlap = min(spans[i].upperBound, range.upperBound) - max(spans[i].lowerBound, range.lowerBound)
            if overlap > 0 { total += overlap }
            i += 1
        }
        return total
    }
}

// MARK: - Options

struct ECGArtifactOptions {

    /// Window over which signal statistics are computed.
    var windowSeconds: Double = 0.25

    /// A window is artifact if its peak-to-peak range exceeds this multiple of
    /// the recording's typical window range. A normal window containing a QRS
    /// sits at roughly 1.0 by construction.
    var rangeFactor: Float = 4.0

    /// A window is artifact if the baseline moved by more than this multiple of
    /// the typical range over half a second. This is the one that actually
    /// catches strap adjustment — the excursion may build slowly, but it moves
    /// far further than any physiological signal.
    var slopeFactor: Float = 2.5

    /// Guard band grown around every flagged region. Needs to be generous:
    /// filtfilt spreads the artifact symmetrically in time, so clean-looking
    /// samples just before the event are already contaminated in the filtered
    /// domain.
    var guardSeconds: Double = 0.60

    /// Flagged regions closer together than this are merged.
    var mergeGapSeconds: Double = 1.00

    /// Regions shorter than this after merging are discarded as false alarms.
    var minimumSpanSeconds: Double = 0.20

    init() {}
}

// MARK: - Detection

enum ECGSignalQuality {

    /// Single pass over the raw data collecting window statistics, then two
    /// cheap passes over the statistics. The threshold is self-calibrating:
    /// it's a multiple of the *median* window range across the whole recording,
    /// which the artifact itself cannot move as long as it occupies a minority
    /// of the file.
    static func detectArtifacts(data: ECGData,
                                options: ECGArtifactOptions = ECGArtifactOptions()) -> ECGArtifactMask {

        let fs = data.samplesPerSecond
        let total = data.numValues
        guard fs > 0, total > 0 else { return ECGArtifactMask(totalSamples: total) }

        let windowSamples = max(4, Int(options.windowSeconds * fs))
        let windowCount = total / windowSamples
        guard windowCount > 8 else { return ECGArtifactMask(totalSamples: total) }

        var ranges = [Float](repeating: 0, count: windowCount)
        var levels = [Float](repeating: 0, count: windowCount)

        // MARK: statistics

        let blockWindows = max(1, Int(60.0 * fs) / windowSamples)
        var w = 0
        while w < windowCount {
            let lastWindow = min(windowCount, w + blockWindows)
            let start = w * windowSamples
            let end = lastWindow * windowSamples
            let block = data.getData(start..<end).map { Float($0) }

            var k = w
            while k < lastWindow {
                let lo = (k - w) * windowSamples
                let hi = min(block.count, lo + windowSamples)
                guard hi > lo + 2 else { k += 1; continue }
                var slice = Array(block[lo..<hi])
                slice.sort()
                // 5th/95th percentile rather than min/max, so a single dropped
                // sample doesn't flag an otherwise clean window.
                let p5 = slice[max(0, slice.count / 20)]
                let p95 = slice[min(slice.count - 1, slice.count - 1 - slice.count / 20)]
                ranges[k] = p95 - p5
                levels[k] = slice[slice.count / 2]
                k += 1
            }
            w = lastWindow
        }

        // MARK: self-calibration

        let sorted = ranges.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return ECGArtifactMask(totalSamples: total) }
        let typical = sorted[sorted.count / 2]
        guard typical > 0 else { return ECGArtifactMask(totalSamples: total) }

        let rangeLimit = options.rangeFactor * typical
        let slopeLimit = options.slopeFactor * typical
        let halfSecondWindows = max(1, Int(0.5 / options.windowSeconds))

        var flagged = [Bool](repeating: false, count: windowCount)
        for i in 0..<windowCount {
            if ranges[i] > rangeLimit { flagged[i] = true; continue }
            let a = max(0, i - halfSecondWindows)
            let b = min(windowCount - 1, i + halfSecondWindows)
            if abs(levels[b] - levels[a]) > slopeLimit { flagged[i] = true }
        }

        // MARK: spans

        var spans = [Range<Int>]()
        var i = 0
        while i < windowCount {
            guard flagged[i] else { i += 1; continue }
            var j = i
            while j + 1 < windowCount && flagged[j + 1] { j += 1 }
            spans.append((i * windowSamples)..<min(total, (j + 1) * windowSamples))
            i = j + 1
        }

        let guardSamples = Int(options.guardSeconds * fs)
        let mergeGap = Int(options.mergeGapSeconds * fs)
        let minimumSpan = Int(options.minimumSpanSeconds * fs)

        spans = spans.map { max(0, $0.lowerBound - guardSamples)..<min(total, $0.upperBound + guardSamples) }

        var merged = [Range<Int>]()
        for span in spans {
            if var last = merged.last, span.lowerBound - last.upperBound <= mergeGap {
                last = last.lowerBound..<max(last.upperBound, span.upperBound)
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }
        merged = merged.filter { $0.count >= minimumSpan }

        return ECGArtifactMask(spans: merged, totalSamples: total)
    }
}

// MARK: - Robust baseline removal

extension ECGSignalPipeline {

    /// Median-based baseline estimate. A median filter tracks a step without
    /// ringing, which is exactly the property a linear highpass lacks — so
    /// subtracting this before the bandpass removes most of the artifact edge
    /// before it can excite the Butterworth.
    ///
    /// Computed on a decimated copy (block medians at ~32 Hz) and interpolated
    /// back, which turns an O(n·w log w) operation into something negligible.
    static func robustBaseline(_ x: [Float], samplesPerSecond fs: Double) -> [Float] {
        let n = x.count
        guard n > 8, fs > 0 else { return [Float](repeating: 0, count: n) }

        let decim = max(1, Int((fs / 32.0).rounded()))
        var coarse = [Float]()
        coarse.reserveCapacity(n / decim + 2)

        var i = 0
        while i < n {
            let end = min(n, i + decim)
            var slice = Array(x[i..<end])
            slice.sort()
            coarse.append(slice[slice.count / 2])
            i = end
        }
        guard coarse.count > 4 else { return [Float](repeating: coarse.first ?? 0, count: n) }

        let coarseRate = fs / Double(decim)
        // 200 ms removes the QRS, 600 ms then removes P and T, leaving baseline.
        var b = medianFilter(coarse, window: oddWindow(0.20 * coarseRate))
        b = medianFilter(b, window: oddWindow(0.60 * coarseRate))

        // Linear interpolation back to full rate. Block k is centred on
        // sample k·decim + (decim-1)/2.
        var out = [Float](repeating: 0, count: n)
        let offset = Double(decim - 1) * 0.5
        for j in 0..<n {
            let p = (Double(j) - offset) / Double(decim)
            if p <= 0 { out[j] = b[0]; continue }
            if p >= Double(b.count - 1) { out[j] = b[b.count - 1]; continue }
            let k = Int(p)
            let f = Float(p - Double(k))
            out[j] = b[k] * (1 - f) + b[k + 1] * f
        }
        return out
    }

    /// Typical QRS peak magnitude, as the median across one-second windows.
    /// Robust to an artifact occupying part of the block.
    ///
    /// This deliberately measures a *peak*, not a percentile spread. A 5th–95th
    /// percentile range over a full second discards the top 5% of samples — and
    /// a thin, tall R wave three or four samples wide is entirely inside that
    /// top 5% at these rates. Scaling from such a range yields the amplitude of
    /// the baseline wander between beats, and clipping at a multiple of *that*
    /// flattens the R waves the detector is looking for.
    static func robustScale(_ x: [Float], samplesPerSecond fs: Double) -> Float {
        let w = max(8, Int(fs))
        guard x.count >= w * 2 else { return 0 }
        var peaks = [Float]()
        var i = 0
        while i + w <= x.count {
            var magnitudes = x[i..<(i + w)].map { abs($0) }
            magnitudes.sort()
            // Second largest: keeps a narrow R spike, drops a single-sample glitch.
            peaks.append(magnitudes[magnitudes.count - 2])
            i += w
        }
        guard !peaks.isEmpty else { return 0 }
        peaks.sort()
        return peaks[peaks.count / 2]
    }

    static func oddWindow(_ value: Double) -> Int {
        var w = max(3, Int(value.rounded()))
        if w % 2 == 0 { w += 1 }
        return w
    }

    static func medianFilter(_ x: [Float], window: Int) -> [Float] {
        let n = x.count
        guard window > 1, n > 0 else { return x }
        let half = window / 2
        var out = [Float](repeating: 0, count: n)
        var buffer = [Float](repeating: 0, count: window)
        for i in 0..<n {
            for k in 0..<window {
                buffer[k] = x[min(n - 1, max(0, i - half + k))]
            }
            buffer.sort()
            out[i] = buffer[half]
        }
        return out
    }
}
