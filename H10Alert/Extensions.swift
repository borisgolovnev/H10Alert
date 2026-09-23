//
//  Extensions.swift
//  H10ECG
//
//  Created by Boris Golovnev on 05/04/2021.
//

import Foundation

import HealthKit
import UIKit

extension String {
    func matches(_ regex: String) -> Bool {
        return self.range(of: regex, options: .regularExpression, range: nil, locale: nil) != nil
    }
}

extension URL {
    
    static func documentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }
    
    static func documentURL(_ name:String) -> URL {
        let documents = self.documentsDirectory()
        let file = documents.appendingPathComponent(name)
        return file
    }
}

extension UserDefaults {
    struct Keys {
        static let lastConnectedId = "lastConnected"
        
        static let autoConnect = "autoConnect"
        static let autoSave = "autoSave"
        static let clearOnLiveOpen = "clearOnLiveOpen"
        static let saveHRToHealthKit = "HealthKitWriteHR"
        static let retransmitHeartRate = "RetransmitHeartRate"
        
        static let showRR = "showRR"
        static let showHR = "showHR"
        
        static let lastUsedMMS = "lastUsedMMS"
        static let lastUsedMMMV = "lastUsedMMMV"
        
        static let exportOptionTimestamps = "exportOptionTimestamps"
        static let exportOptionEvents = "exportOptionEvents"
        static let exportOptionEventsOnly = "exportOptionEventsOnly"
        static let exportOptionFormat = "exportOptionFormat"
        static let exportOptionRange = "exportOptionRange"
    }
    
    class func setDefaultDefaults() {
        let ud = UserDefaults.standard
        let allKeys = ud.dictionaryRepresentation().keys
        if !allKeys.contains(Keys.autoSave) {
            ud.set(true, forKey: Keys.autoSave)
        }
        if !allKeys.contains(Keys.autoConnect) {
            ud.set(true, forKey: Keys.autoConnect)
        }
        if !allKeys.contains(Keys.showHR) && !allKeys.contains(Keys.showRR) {
            ud.set(true, forKey: Keys.showRR)
        }
        if !allKeys.contains(Keys.lastUsedMMS) {
            ud.set(25.0, forKey: Keys.lastUsedMMS)
        }
        if !allKeys.contains(Keys.lastUsedMMMV) {
            ud.set(10.0, forKey: Keys.lastUsedMMMV)
        }
        //...
        ud.synchronize()
    }
}

extension UILabel {
    class func standardLabel(withText text:String = "") -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.textColor = .label
        label.font = UIFont(name: "Menlo-Bold", size: 12)
        label.text = text
        label.sizeToFit()
        return label
    }
}

extension UIApplication {
    class func appString() -> String {
        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return "H10Alert (" + bundleVersion + ")"
    }
}
