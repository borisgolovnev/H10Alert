//
//  ECGDataExporterCSV.swift
//  H10ECG
//
//  Created by Boris Golovnev on 20/09/2022.
//

import Foundation

class ECGDataExporterCSV: ECGDataExporter {
    
    override var filename:String { super.filename + ".csv" }
    
    override func updateParams() {
        super.updateParams()
        exportInfo = String(format: "%ld samples", range.count)
        if (withTimestamps) {
            exportInfo.append("\nTimestamp epoch is 1st of January 2000")
        }
    }
    
    override func doExport() {
        super.doExport()
        guard let outputURL else {return}
        
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        do {
            let fh = try FileHandle(forWritingTo: outputURL)
            
            if withTimestamps {
                let header = "Timestamp,Value\r\n".data(using: .utf8)!
                try fh.write(contentsOf: header)
            } else {
                let header = "Value\r\n".data(using: .utf8)!
                try fh.write(contentsOf: header)
            }
            
            let (fromSegment, fromIndex) = data.getSegmentAndOffset(for: range.lowerBound)
            let (toSegment, toIndex) = data.getSegmentAndOffset(for: range.upperBound)
            
            for sIdx in fromSegment...toSegment {
                var range:Range<Int>!
                if fromSegment != toSegment {
                    if sIdx == fromSegment {
                        range = fromIndex..<data.segments[sIdx].numSamples
                    } else if sIdx == toSegment {
                        range = 0..<toIndex
                    } else {
                        range = 0..<data.segments[sIdx].numSamples
                    }
                } else {
                    range = fromIndex..<toIndex
                }
                
                let segment = data.segments[sIdx]
                var timestampRange = 0..<segment.timestamps.count
                if let startIndex = segment.indices.firstIndex(where: { $0 >= range.lowerBound }),
                   let endIndex = segment.indices.lastIndex(where: { $0 <= range.upperBound }),
                   endIndex > startIndex {
                    timestampRange = (startIndex-1)..<endIndex
                }
                
                for i in timestampRange {
                    var block = ""
                    
                    let typicalTimestampDiff = segment.timestamps[1] - segment.timestamps[0]
                    
                    let startTimestamp = (i < 0) ? (segment.timestamps[0] - typicalTimestampDiff) : segment.timestamps[i]
                    let endTimestamp = segment.timestamps[i+1]
                    let timestampRange = Double(endTimestamp - startTimestamp)
                    
                    let startIndex = (i < 0) ? 0 : segment.indices[i]
                    let endIndex = segment.indices[i+1]
                    let indexRange = endIndex - startIndex
                    
                    assert(timestampRange > 0)
                    if withTimestamps {
                        for ii in 0..<indexRange {
                            let rangePosition = Double(ii) / Double(indexRange - 1)
                            let val = segment.samples[startIndex + ii]
                            let ts = startTimestamp + UInt64(rangePosition * timestampRange)
                            block += "\(ts),\(val)\r\n"
                        }
                    } else {
                        for ii in 0..<indexRange {
                            let val = segment.samples[startIndex + ii]
                            block += "\(val)\r\n"
                        }
                    }
                    
                    try fh.write(contentsOf: block.data(using: .utf8)!)
                }
                
                let progress = Double(sIdx) / Double(toSegment - fromSegment)
                delegate?.dataExporterIsExporting(progress: progress)
            }
            
            try fh.close()
        } catch {
            print("⚠️ \(error)")
        }
        
        delegate?.dataExporterDidFinish(dataUrl: outputURL)
    }
    
    
}
