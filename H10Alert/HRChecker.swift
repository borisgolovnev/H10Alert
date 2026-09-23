//
//  HRChecker.swift
//  H10Alert
//
//  Created by Boris Golovnev on 13/06/2026.
//

import Foundation
import PolarBleSdk

final class HRChecker {
    
    let streamingAnalyser = ECGStreamingAnalyser(samplesPerSecond: 130)
    var lastHr = 0
    
    var timestamp0:Date? = nil
    var timestamp1:Date? = nil
    var alert0Issued = false
    var alert1Issued = false
    
    var issueAlert0:(() -> Void)? = nil
    var issueAlert1:(() -> Void)? = nil
    var clearAlerts:(() -> Void)? = nil
    var irregularAlert:((Bool) -> Void)? = nil
    
    init() {
        streamingAnalyser.onBeat = { beat in
            let new = Int(beat.smoothedHeartRate ?? 0)
            self.checkHr(hr: new)
        }
        streamingAnalyser.onArtifactStateChanged = { bad in print(bad) }
        streamingAnalyser.onRhythmStateChanged = {state in
            self.irregularAlert?(state == .irregular)
            if (state == .irregular) {
                let oneSecondFromNow = Date().addingTimeInterval(1)
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: oneSecondFromNow)
                Task {
                    _ = try? await NotificationManager.shared.scheduleLocalNotification(title: "Irregular heart rhythm", body: "This could be atrial fibrilation. Chech the recording later.", at: components)
                }
            }
        }
    }
    
    func checkData(data:PolarEcgData) {
        streamingAnalyser.append(data.samples.map{Float($0.voltage)})
    }
    
    func checkHr(hr:Int) {
        lastHr = hr
        
        let ud = UserDefaults.standard
        if lastHr >= ud.integer(forKey: UserDefaults.AlertKeys.lowHR) && lastHr <= ud.integer(forKey: UserDefaults.AlertKeys.highHR) {
            reset()
        } else {
            if timestamp0 == nil {
                timestamp0 = Date()
            }
        }
        
        if let ts0 = timestamp0 {
            let sinceTs0 = Date().timeIntervalSince(ts0)
            let delay0 = Double(ud.integer(forKey: UserDefaults.AlertKeys.alert0Delay))
            if Double(sinceTs0) > delay0 {
                if !alert0Issued {
                    let oneSecondFromNow = Date().addingTimeInterval(1)
                    let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: oneSecondFromNow)
                    Task {
                        _ = try? await NotificationManager.shared.scheduleLocalNotification(title: "Abnormal heart rate", body: "Open the app to cancel or call 911", at: components)
                    }
                    issueAlert0?()
                    alert0Issued = true
                }
                
                if timestamp1 == nil {
                    timestamp1 = Date()
                }
            }
        }
        
        if let ts1 = timestamp1 {
            let sinceTs1 = Date().timeIntervalSince(ts1)
            let delay1 = Double(ud.integer(forKey: UserDefaults.AlertKeys.alert1Delay))
            if Double(sinceTs1) > delay1 {
                if !alert1Issued {
                    issueAlert1?()
                    alert1Issued = true
                }
            }
        }
        
    }
    
    func reset() {
        timestamp0 = nil
        timestamp1 = nil
        alert0Issued = false
        alert1Issued = false
        clearAlerts?()
    }
}
