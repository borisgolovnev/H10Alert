//
//  RecordingExportViewController.swift
//  H10ECG
//
//  Created by Boris Golovnev on 21/09/2022.
//

import UIKit


class RecordingExportViewController: UIViewController, ECGExporterDelegate {
    
    static var didExport = false
    
    @IBOutlet weak var selFormat:UISegmentedControl!
    @IBOutlet weak var selTimestamps:UISwitch!
    
    @IBOutlet weak var eventsItem:UIStackView!
    @IBOutlet weak var selEvents:UISwitch!
    @IBOutlet weak var eventsOnlyItem:UIStackView!
    @IBOutlet weak var selEventsOnly:UISwitch!
    
    @IBOutlet weak var selRange:UISegmentedControl!
    @IBOutlet weak var lblStatus:UILabel!
    @IBOutlet weak var progress:UIProgressView!
    @IBOutlet weak var btnStart:UIButton!
    
    var offset = 0
    var data:ECGData!
    var analysis:ECGAnalyserAnalysis? = nil
    var exporter:ECGDataExporter? = nil
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        let ud = UserDefaults.standard
        selTimestamps.isOn = ud.bool(forKey: UserDefaults.Keys.exportOptionTimestamps)
        selEvents.isOn = ud.bool(forKey: UserDefaults.Keys.exportOptionEvents)
        selEventsOnly.isOn = ud.bool(forKey: UserDefaults.Keys.exportOptionEventsOnly)
        selFormat.selectedSegmentIndex = ud.integer(forKey: UserDefaults.Keys.exportOptionFormat)
        selRange.selectedSegmentIndex = ud.integer(forKey: UserDefaults.Keys.exportOptionRange)
        
        if data.notes.count == 0 {
            eventsItem.isHidden = true
            eventsOnlyItem.isHidden = true
            selEvents.isOn = false
            selEventsOnly.isOn = false
        }
        
        updateStatus()
    }
    
    
    @IBAction func close() {
        dismiss(animated: true)
    }
    
    @IBAction func updateStatus() {
        guard let data = data else { return }
        
        selTimestamps.isEnabled = true
        selEvents.isEnabled = true
        selEventsOnly.isEnabled = true
        selRange.isEnabled = true
        
        if selEventsOnly.isOn {
            selEvents.isOn = true
        }
        
        if selFormat.selectedSegmentIndex == 0 {
            exporter = ECGDataExporterCSV(data: data)
            selEvents.isEnabled = false
            selEventsOnly.isEnabled = false
        } else if selFormat.selectedSegmentIndex == 1 {
            exporter = ECGDataExporterPDF(data: data)
        } else {
            exporter = ECGDataExporterGIF(data: data)
            selTimestamps.isEnabled = false
            selRange.isEnabled = false
            selEvents.isEnabled = false
            selEventsOnly.isEnabled = false
        }
        
        exporter!.withTimestamps = selTimestamps.isOn
        exporter!.withNotes = selEvents.isOn
        exporter!.notesOnly = selEventsOnly.isOn
        exporter!.analysis = analysis
        if selRange.selectedSegmentIndex == 0 {
            exporter!.range = 0..<data.numValues
        } else {
            let fifteenSeconds:Int
            if exporter is ECGDataExporterGIF {
                fifteenSeconds = Int((exporter as! ECGDataExporterGIF).duration / 2.0 * data.samplesPerSecond)
            } else {
                fifteenSeconds = Int(15.0 * data.samplesPerSecond)
            }
            let left = max(0, offset - fifteenSeconds)
            let right = min(data.numValues, left + fifteenSeconds * 2 - 1)
            exporter!.range = left..<right
        }
        
        lblStatus.text = exporter?.exportInfo
        
        let ud = UserDefaults.standard
        ud.set(selTimestamps.isOn, forKey: UserDefaults.Keys.exportOptionTimestamps)
        ud.set(selEvents.isOn, forKey: UserDefaults.Keys.exportOptionEvents)
        ud.set(selEventsOnly.isOn, forKey: UserDefaults.Keys.exportOptionEventsOnly)
        ud.set(selFormat.selectedSegmentIndex, forKey: UserDefaults.Keys.exportOptionFormat)
        ud.set(selRange.selectedSegmentIndex, forKey: UserDefaults.Keys.exportOptionRange)
    }
    
    @IBAction func startExport() {
        btnStart.isEnabled = false
        exporter?.delegate = self
        exporter?.startExport()
    }
    
    
    
    
    
    func dataExporterDidFinish(dataUrl: URL?) {
        DispatchQueue.main.async {
            if let exporter = self.exporter, let resultURL = exporter.outputURL {
                let sharer = UIActivityViewController(activityItems: [resultURL], applicationActivities: nil)
                self.present(sharer, animated: true)
            }
            self.btnStart.isEnabled = true
            RecordingExportViewController.didExport = true
        }
    }
    
    func dataExporterIsExporting(progress: Double) {
        DispatchQueue.main.async {
            self.progress.progress = Float(progress)
        }
    }
}
