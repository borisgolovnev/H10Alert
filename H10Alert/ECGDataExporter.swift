//
//  ECGDataExporter.swift
//  H10ECG
//
//  Created by Boris Golovnev on 20/09/2022.
//

import Foundation

protocol ECGExporterDelegate : AnyObject {
    func dataExporterDidFinish(dataUrl:URL?)
    func dataExporterIsExporting(progress:Double)
}

class ECGDataExporter {
    
    static let df:DateFormatter = {
        let result = DateFormatter()
        result.dateStyle = .medium
        result.timeStyle = .medium
        return result
    }()
    
    let data:ECGData
    var dataSlice:[Int32]!
    var date = Date()
    
    var withTimestamps = false
    var withNotes = false
    var notesOnly = false
    var analysis:ECGAnalyserAnalysis? = nil
    
    var range:Range<Int>! {
        didSet {
            updateParams()
        }
    }
    
    var exportInfo = ""
    var progress = 0.0
    var outputURL:URL? = nil
    weak var delegate:ECGExporterDelegate?
    
    var filename:String {
        let dateString = ECGDataExporter.df.string(from: date)
        return "ECG "+dateString
    }
    
    init(data: ECGData) {
        self.data = data
        self.range = 0..<data.numValues
    }
    
    func updateParams() {
        self.date = data.startDate.addingTimeInterval(Double(range.lowerBound) / data.samplesPerSecond)
    }
    
    func startExport() {
        updateParams()
        DispatchQueue.global(qos: .userInitiated).async {
            self.doExport()
        }
    }
    
    func doExport() {
        outputURL = URL(fileURLWithPath: NSTemporaryDirectory().appending(filename))
        dataSlice = data.getData(range)
        guard let outputURL = outputURL,
              dataSlice.count > 1
        else { return }
        try? FileManager.default.removeItem(at: outputURL)
    }
    
}
