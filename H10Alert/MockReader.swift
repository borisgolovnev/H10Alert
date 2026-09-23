//
//  MockReader.swift
//  H10Alert
//
//  Created by Boris Golovnev on 19/08/2026.
//

import Foundation
import PolarBleSdk

class MockReader {
    
    let replacementData:ECGDataFile
    let startIndex:Int
    var cursor = 0
    
    init(_ fileName:String, startIndex idx:Int = 0) {
        replacementData = ECGDataFile()
        replacementData.loadFromFile(Bundle.main.url(forResource: fileName, withExtension: "dat")!)
        startIndex = idx
    }
    
    func replace(_ sourceData:PolarEcgData) -> PolarEcgData {
        if let read = replacementData.polarEcgData(fromOffset: cursor, count: sourceData.samples.count) {
            var readSamples = read.samples
            for i in 0 ..< readSamples.count {
                readSamples[i].timeStamp = sourceData.samples[i].timeStamp
            }
            
            cursor += readSamples.count
            if cursor >= replacementData.numSamples {
                cursor = startIndex
            }
            
            return (timeStamp: sourceData.timeStamp, samples: readSamples)
        } else {
            return sourceData
        }
    }
    
    
}
