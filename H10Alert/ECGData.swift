//
//  ECGData.swift
//  H10ECG
//
//  Created by Boris Golovnev on 06/04/2021.
//

import Foundation
import PolarBleSdk
import InfiniteGraph
import UniformTypeIdentifiers

final class ECGData : InfiniteGraphDataSource, Codable {

    var heartRates = [UInt8]()
    var segments = [ECGDataFile]()
    var notes = [UInt64:String]()
    var startDate = Date()
    var mms:Double = UserDefaults.standard.double(forKey: UserDefaults.Keys.lastUsedMMS)
    var mmmv:Double = UserDefaults.standard.double(forKey: UserDefaults.Keys.lastUsedMMMV)
    
    enum CodingKeys: String, CodingKey {
        case heartRates
        case segments
        case notes
        case startDate
        case mms
        case mmmv
        case documentName
    }
    
    static let fileExtensionLegacy = "ecgdata"
    static let fileExtension = "ecgdata2"
    static let infoFilename = "info.json"
    static let timestampToSeconds = 1_000_000_000.000
    var documentName = NSUUID().uuidString.appending("." + ECGData.fileExtension)
    
    var isLive = true
    var isFromAlertApp = false
    
    var firstTimestamp:UInt64 {
        get {
            guard segments.count > 0 else { return 0 }
            return segments.first!.firstTimestamp
        }
    }
    var lastTimestamp:UInt64 {
        get {
            guard segments.count > 0 else { return UInt64.max }
            return segments.last!.lastTimestamp
        }
    }
    
    init() {
        
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        heartRates = try container.decode([UInt8].self, forKey: .heartRates)
        segments = try container.decode([ECGDataFile].self, forKey: .segments)
        notes = try container.decode([UInt64:String].self, forKey: .notes)
        startDate = try container.decode(Date.self, forKey: .startDate)
        
        mms = try container.decodeIfPresent(Double.self, forKey: .mms) ?? 25.0
        mmmv = try container.decodeIfPresent(Double.self, forKey: .mmmv) ?? 10.0
        
        documentName = try container.decode(String.self, forKey: .documentName)
    }
    
    
    
    func markNow(_ eventName:String) -> Bool {
        guard let lastSegment = segments.last else { return false }
        let numNotesWithThisName = notes.values.filter{ $0.hasPrefix(eventName) }.count
        notes[lastSegment.lastTimestamp] = "\(eventName) \(numNotesWithThisName+1)"
        return true
    }
    
    func append(newData:PolarEcgData) {
        var added = false
        if segments.last?.canAppend(data: newData) ?? false {
            let lastTimestamp = min(newData.timeStamp, segments.last!.timestamps.last ?? newData.timeStamp)
            let timestampDifference = newData.timeStamp - lastTimestamp
            let timeDifference = Double(timestampDifference) / ECGData.timestampToSeconds
            if timeDifference < 3.0 {
                segments.last?.append(newData: newData)
                added = true
            }
        }
        if !added {
            self.saveToFile(writeSegmentsToDisk: false)
            segments.last?.dumpToFile()
            
            let newSegment = ECGDataFile()
            let fileName = String(newData.timeStamp)+".dat"
            newSegment.filePath = documentName + "/" + fileName
            newSegment.append(newData: newData)
            segments.append(newSegment)
            
            print("new segment! \(fileName)")
        }
    }
    
    func append(heartRate:UInt8) {
        heartRates.append(heartRate)
    }
    
    var recordedDuration:TimeInterval { //slightly incorrect as first timestamp is the end of first batch of samples
        segments.map({$0.recordedDuration}).reduce(0, +)
    }
    
    
    var pointsPerSecond: CGFloat {
        mms * InfiniteGraphView.screenMm
    }
    
    var samplesPerSecond: CGFloat {
        segments.last?.samplesPerSecond ?? 0
    }
    
    
    
    
    
    
    
    var valuesPerPoint: CGFloat {
        self.samplesPerSecond / self.pointsPerSecond
    }
    
    var valueScale: CGFloat {
        InfiniteGraphView.screenMm * mmmv / 1000.0
    }
    
    var numValues: Int {
        segments.map({$0.numSamples}).reduce(0, +)
    }
    
    var numTimestamps: Int {
        segments.map({$0.timestamps.count}).reduce(0, +)
    }
    
    func getData(_ range:Range<Int>) -> [Int32] {
        return getData(from: range.lowerBound, to: range.upperBound)
    }
    
    func getData(from:Int, to:Int) -> [Int32] {
        var result = [Int32]()
        if from < to {
            let (fromSegment, fromIndex) = getSegmentAndOffset(for: max(0, from))
            let (toSegment, toIndex) = getSegmentAndOffset(for: min(numValues, to))
            for sIdx in fromSegment...toSegment {
                var range:Range<Int>!
                if fromSegment != toSegment {
                    if sIdx == fromSegment {
                        range = fromIndex..<segments[fromSegment].numSamples
                    } else if sIdx == toSegment {
                        range = 0..<toIndex
                    } else {
                        range = 0..<segments[sIdx].numSamples
                    }
                } else {
                    range = fromIndex..<toIndex
                }
                for idx in range {
                    result.append(segments[sIdx].samples[idx])
                }
            }
        }
        return result
    }
    
    func getRelativePosition(of timestamp:UInt64) -> Double {
        let span = self.lastTimestamp - self.firstTimestamp
        assert(span > 0)
        let relative = timestamp - self.firstTimestamp
        return Double(relative) / Double(span)
    }
    
    func getSampleNumberAt(timestamp:UInt64) -> Int {
        if timestamp < self.firstTimestamp || timestamp >= self.lastTimestamp {
            return -1
        }
        
        var sum = 0
        for i in 0..<segments.count {
            let segment = segments[i]
            if timestamp >= segment.lastTimestamp {
                sum += segment.numSamples
                continue
            } else {
                let lastSegmentSampleIndex = segment.nearestSampleIndexFor(timestamp: timestamp)
                return sum + lastSegmentSampleIndex
            }
        }
        return -1
    }
    
    func getSegmentAndOffset(for globalOffset:Int) -> (Int, Int) {
        var sum = 0
        for i in 0 ..< segments.count {
            let segment = segments[i]
            if globalOffset < (sum + segment.numSamples) {
                return (i, globalOffset - sum)
            }
            sum += segment.numSamples
        }
        return (max(0, segments.count - 1), segments.last?.numSamples ?? 0)
    }
    
    func loadAllSegments() {
        let pathPrefix = URL.documentsDirectory()
        segments.forEach { $0.loadFromFile(basePath:pathPrefix) }
        segments.removeAll { $0.saved != true }
    }
    
    
    class func readFromFile(file:URL) throws -> ECGData? {
        let fileData = try Data(contentsOf: file.appendingPathComponent(ECGData.infoFilename, conformingTo: .data))
        let data = try JSONDecoder().decode(ECGData.self, from: fileData)
        data.isLive = false
        return data
    }
    
    class func readFromLegacyFile(file:URL) -> ECGData? {
        print("reading \(file)")
        
        do {
            let handle = try FileHandle(forReadingFrom: file)
            
            let tsLengthData = handle.readData(ofLength: MemoryLayout<Int>.size)
            let tsLength = tsLengthData.withUnsafeBytes { $0.load(as: Int.self) }
            let tsData = handle.readData(ofLength: tsLength)
            
            let ixLengthData = handle.readData(ofLength: MemoryLayout<Int>.size)
            let ixLength = ixLengthData.withUnsafeBytes { $0.load(as: Int.self) }
            let ixData = handle.readData(ofLength: ixLength)
            
            let sdLengthData = handle.readData(ofLength: MemoryLayout<Int>.size)
            let sdLength = sdLengthData.withUnsafeBytes { $0.load(as: Int.self) }
            let sdData = handle.readData(ofLength: sdLength)
            
            let result = ECGData()
            let segment = ECGDataFile()
            
            do {
                let classes = [NSArray.self, NSNumber.self]
                
                let timestampsArray = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: tsData) as? [NSNumber] ?? []
                segment.timestamps = timestampsArray.map { $0.uint64Value }
                
                let indicesArray = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: ixData) as? [NSNumber] ?? []
                segment.indices = indicesArray.map { $0.intValue }
                
                let samplesArray = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: sdData) as? [NSNumber] ?? []
                segment.samples = samplesArray.map { $0.int32Value }
            } catch let err {
                print("could not deserialize data \(err)")
            }
            result.segments.append(segment)
            result.isLive = false
            try? result.startDate = file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? Date()
            return result
            
        } catch let err {
            print("\(err)")
            return nil
        }
    }
    
    func saveToFile(writeSegmentsToDisk writeSegments:Bool = true) {
        if numValues < 10 { return }
        let rootUrl = URL.documentURL(documentName)
        let url = rootUrl.appendingPathComponent(ECGData.infoFilename, conformingTo: .data)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        do {
            var isDirectory:ObjCBool = false
            if !FileManager.default.fileExists(atPath: rootUrl.path, isDirectory: &isDirectory) || !(isDirectory.boolValue) {
                try? FileManager.default.removeItem(at: rootUrl)
                try FileManager.default.createDirectory(at: rootUrl, withIntermediateDirectories: true)
            }
            try? FileManager.default.removeItem(at: url)
            let data = try encoder.encode(self)
            try data.write(to:url)
            
            if writeSegments {
                for segment in segments {
                    segment.dumpToFile()
                }
            }
        } catch {
            print("could not \(error)")
        }
    }
    
    
}
