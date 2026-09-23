//
//  ECGDataFile.swift
//  H10ECG
//
//  Created by Boris Golovnev on 10/21/22.
//

import Foundation
import PolarBleSdk

final class ECGDataFile : Codable {
    
    enum CodingKeys: String, CodingKey {
      case filePath, startDate, firstTimestamp, lastTimestamp
   }
    
    var samplesPerSecond:Double {
        if timestamps.count > 1 && indices.count > 1 && timestamps.last != timestamps.first {
            let timestampDiff = Double(timestamps.last! - timestamps.first!) / ECGData.timestampToSeconds
            let sampleIndexDiff = Double(indices.last! - indices.first!)
            return sampleIndexDiff / timestampDiff
        }
        return 0
    }
    
    static let maxSamples = 131*1800 //approximately half an hour worth of samples. so they are saved more frequently
    var samples = [Int32]()
    var timestamps = [UInt64]() //timestamps
    var indices = [Int]() //to indices
    
    var firstTimestamp:UInt64 = 0
    var lastTimestamp:UInt64 = 0
    var saved = false
    var numSamples:Int { samples.count }
    
    var recordedDuration:TimeInterval { Double(self.lastTimestamp - self.firstTimestamp) / ECGData.timestampToSeconds }
    
    var filePath:String!
    var startDate = Date()
    
    
    init() {
        
    }
    
    func nearestSampleIndexFor(timestamp:UInt64) -> Int {
        if timestamp < firstTimestamp {
            return 0
        } else if timestamp >= lastTimestamp {
            return indices.last ?? 0
        }
        for i in 0 ..< timestamps.count {
            if timestamps[i] > timestamp {
                return indices[i]
            }
        }
        return 0
    }
    
    func canAppend(data:PolarEcgData) -> Bool {
        let count = data.samples.count
        if count < 1 {
            return false
        }
        if (samples.count + count) > ECGDataFile.maxSamples {
            return false
        }
        if saved {
            return false
        }
        return true
    }
    
    func append(newData:PolarEcgData) {
        if canAppend(data: newData) {
            if timestamps.count == 0 {
                firstTimestamp = newData.timeStamp
            }
            samples.append(contentsOf: newData.samples.map{$0.voltage})
            timestamps.append(newData.timeStamp)
            indices.append(samples.count)
            lastTimestamp = newData.timeStamp
        } else {
            print("Can't add!")
        }
    }
    
    func loadFromFile(basePath:URL? = nil) {
        guard let filePath = self.filePath else { return }
        if let basePath = basePath {
            loadFromFile(basePath.appendingPathComponent(filePath))
        } else {
            loadFromFile(URL.documentURL(filePath))
        }
    }
    
    func loadFromFile(_ url:URL) {
        guard samples.count == 0, indices.count == 0, timestamps.count == 0 else { return }
        
        let handle:FileHandle!
        do {
            handle = try FileHandle(forReadingFrom: url)
            
            let sdLengthData = handle.readData(ofLength: MemoryLayout<Int>.size)
            let sdLength = sdLengthData.withUnsafeBytes { $0.load(as: Int.self) }
            let sdData = handle.readData(ofLength: sdLength)
            samples = Array<Int32>(repeating: 0, count: sdData.count/MemoryLayout<Int32>.stride)
            _ = samples.withUnsafeMutableBytes { sdData.copyBytes(to: $0) }
            
            let tsLengthData = handle.readData(ofLength: MemoryLayout<Int>.size)
            let tsLength = tsLengthData.withUnsafeBytes { $0.load(as: Int.self) }
            let tsData = handle.readData(ofLength: tsLength)
            timestamps = Array<UInt64>(repeating: 0, count: tsData.count/MemoryLayout<UInt64>.stride)
            _ = timestamps.withUnsafeMutableBytes { tsData.copyBytes(to: $0) }
            
            let ixLengthData = handle.readData(ofLength: MemoryLayout<Int>.size)
            let ixLength = ixLengthData.withUnsafeBytes { $0.load(as: Int.self) }
            let ixData = handle.readData(ofLength: ixLength)
            indices = Array<Int>(repeating: 0, count: ixData.count/MemoryLayout<Int>.stride)
            _ = indices.withUnsafeMutableBytes { ixData.copyBytes(to: $0) }
            
            saved = true
        } catch let err {
            print("could not read \(err)")
        }
    }
    
    func dumpToFile() {
        if saved { return }
        
        var resultData = Data()
        
        let samplesData = Data(bytes: &samples, count: samples.count * MemoryLayout<Int32>.stride)
        let timestampData = Data(bytes: &timestamps, count: timestamps.count * MemoryLayout<UInt64>.stride)
        let indicesData = Data(bytes: &indices, count: indices.count * MemoryLayout<Int>.stride)
        
        withUnsafeBytes(of: samplesData.count) { resultData.append(contentsOf: $0) }
        resultData.append(samplesData)
        
        withUnsafeBytes(of: timestampData.count) { resultData.append(contentsOf: $0) }
        resultData.append(timestampData)
        
        withUnsafeBytes(of: indicesData.count) { resultData.append(contentsOf: $0) }
        resultData.append(indicesData)
        
        let url = URL.documentURL(filePath)
        do {
            try resultData.write(to: url)
            saved = true
            print("✅ written to \(url)")
        } catch let err {
            print("could not write data \(err)")
        }
    }
}

extension ECGDataFile {

    /// Timestamp units (ns) between two consecutive samples, derived from the
    /// recorded timestamp/index pairs. Returns 0 if the rate can't be determined.
    var timestampUnitsPerSample: UInt64 {
        let rate = samplesPerSecond
        guard rate > 0 else { return 0 }
        return UInt64((ECGData.timestampToSeconds / rate).rounded())
    }

    /// Index of the appended batch that contains `sampleIndex`.
    /// `indices[i]` is the *exclusive* end of batch `i`, so we look for the first
    /// batch whose end is strictly greater than the sample index. Binary search.
    private func batchIndex(containing sampleIndex: Int) -> Int? {
        guard sampleIndex >= 0, !indices.isEmpty, sampleIndex < (indices.last ?? 0) else { return nil }
        var low = 0
        var high = indices.count - 1
        while low < high {
            let mid = (low + high) / 2
            if indices[mid] > sampleIndex {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return indices[low] > sampleIndex ? low : nil
    }

    /// Interpolated timestamp for a single sample, counting backwards from the
    /// last sample of the batch it belongs to.
    func timestamp(forSampleIndex sampleIndex: Int) -> UInt64? {
        guard let batch = batchIndex(containing: sampleIndex) else { return nil }
        let step = timestampUnitsPerSample
        guard step > 0 else { return timestamps[batch] }
        let offsetFromEnd = UInt64(indices[batch] - 1 - sampleIndex)
        let delta = offsetFromEnd * step
        return timestamps[batch] > delta ? timestamps[batch] - delta : 0
    }

    /// Builds a `PolarEcgData` from `count` samples starting at `offset`.
    ///
    /// - Parameters:
    ///   - offset: index into `samples` of the first sample to include.
    ///   - count:  number of samples to include. Clamped to the end of the buffer.
    /// - Returns: a `PolarEcgData` whose top-level `timeStamp` is the timestamp of
    ///   the last sample in the slice, or `nil` if the range is empty/invalid.
    func polarEcgData(fromOffset offset: Int, count: Int) -> PolarEcgData? {
        guard offset >= 0, count > 0, offset < samples.count, !indices.isEmpty else { return nil }

        let end = min(offset + count, samples.count)
        let step = timestampUnitsPerSample
        var batch = batchIndex(containing: offset) ?? 0

        var result = [(timeStamp: UInt64, voltage: Int32)]()
        result.reserveCapacity(end - offset)

        for i in offset ..< end {
            // Batches are contiguous and ascending, so a linear walk keeps this O(n).
            while batch < indices.count - 1 && indices[batch] <= i {
                batch += 1
            }
            let sampleTimestamp: UInt64
            if step > 0 {
                let delta = UInt64(max(0, indices[batch] - 1 - i)) * step
                sampleTimestamp = timestamps[batch] > delta ? timestamps[batch] - delta : 0
            } else {
                sampleTimestamp = timestamps[batch]
            }
            result.append((timeStamp: sampleTimestamp, voltage: samples[i]))
        }

        guard let last = result.last else { return nil }
        return (timeStamp: last.timeStamp, samples: result)
    }

    /// Convenience: same as above but anchored to a wall-clock timestamp
    /// rather than a raw sample offset.
    func polarEcgData(fromTimestamp timestamp: UInt64, count: Int) -> PolarEcgData? {
        polarEcgData(fromOffset: nearestSampleIndexFor(timestamp: timestamp), count: count)
    }

    /// Convenience: a slice of a given duration in seconds.
    func polarEcgData(fromOffset offset: Int, seconds: TimeInterval) -> PolarEcgData? {
        let rate = samplesPerSecond
        guard rate > 0 else { return nil }
        return polarEcgData(fromOffset: offset, count: Int((rate * seconds).rounded()))
    }
}
