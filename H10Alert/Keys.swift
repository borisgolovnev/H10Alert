//
//  Keys.swift
//  H10Alert
//
//  Created by Boris Golovnev on 11/06/2026.
//

import Foundation

extension UserDefaults {
    struct AlertKeys {
        static let userName = "userName"
        static let neighborPhoneNumber = "neighborPhoneNumber"
        static let emergencyPhoneNumber = "emergencyPhoneNumber"
        static let highHR = "highHR"
        static let lowHR = "lowHR"
        static let alert0Delay = "alert0Delay"
        static let alert1Delay = "alert1Delay"
        static let takePhotoEnabled = "takePhotoEnabled"
        static let debugEnabled = "debugEnabled"
    }
    
    class func setAlertDefaultDefaults() {
        let ud = UserDefaults.standard
        let allKeys = ud.dictionaryRepresentation().keys
        if !allKeys.contains(AlertKeys.userName) {
            ud.set("User \(Int.random(in: 0...999999))", forKey: AlertKeys.userName)
        }
        if !allKeys.contains(AlertKeys.neighborPhoneNumber) {
            ud.set("", forKey: AlertKeys.neighborPhoneNumber)
        }
        if !allKeys.contains(AlertKeys.emergencyPhoneNumber) {
            ud.set("911", forKey: AlertKeys.emergencyPhoneNumber)
        }
        if !allKeys.contains(AlertKeys.highHR) {
            ud.set(150, forKey: AlertKeys.highHR)
        }
        if !allKeys.contains(AlertKeys.lowHR) {
            ud.set(40, forKey: AlertKeys.lowHR)
        }
        if !allKeys.contains(AlertKeys.alert0Delay) {
            ud.set(30, forKey: AlertKeys.alert0Delay)
        }
        if !allKeys.contains(AlertKeys.alert1Delay) {
            ud.set(20, forKey: AlertKeys.alert1Delay)
        }
        ud.synchronize()
    }
    
}
