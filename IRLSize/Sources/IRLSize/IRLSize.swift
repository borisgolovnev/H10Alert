//
//  File.swift
//  
//
//  Created by Boris Golovnev on 13/5/23.
//

import UIKit
import Orchard

extension UIDevice {
    
    public var mainScreenPhysicalSizeMm:IRLDeviceScreenSize {
        switch deviceIdentity {
        case .iPhone(.iPhone11ProMax):
            return .iPhone11ProMax
        case .iPhone(.iPhone), .iPhone(.iPhone3G), .iPhone(.iPhone3GS), .iPhone(.iPhone4), .iPhone(.iPhone4S):
            return .iPhone3_5Inch
        case .iPhone(.iPhone5), .iPhone(.iPhone5c), .iPhone(.iPhone5s), .iPhone(.iPhoneSE):
            return .iPhone5
        case .iPhone(.iPhone6), .iPhone(.iPhone6s), .iPhone(.iPhone7), .iPhone(.iPhone8), .iPhone(.iPhoneSE2), .iPhone(.iPhoneSE3):
            return .iPhone6
        case .iPhone(.iPhone6Plus), .iPhone(.iPhone6sPlus), .iPhone(.iPhone7Plus), .iPhone(.iPhone8Plus):
            return .iPhone6Plus
        case .iPhone(.iPhoneX), .iPhone(.iPhoneXS):
            return .iPhoneX
        case .iPhone(.iPhoneXSMax):
            return .iPhoneXSMax
        case .iPhone(.iPhoneXR):
            return .iPhoneXR
        case .iPhone(.iPhone11), .iPhone(.iPhone12), .iPhone(.iPhone12Pro), .iPhone(.iPhone13), .iPhone(.iPhone13Pro), .iPhone(.iPhone14):
            return .iPhone11
        case .iPhone(.iPhone11Pro):
            return .iPhone11Pro

        case .iPhone(.iPhone12Mini), .iPhone(.iPhone13Mini):
            return .iPhone12Mini
        case .iPhone(.iPhone12ProMax), .iPhone(.iPhone13ProMax), .iPhone(.iPhone14Plus):
            return .iPhone12ProMax
        case .iPhone(.iPhone14Pro):
            return .iPhone14Pro
        case .iPhone(.iPhone14ProMax):
            return .iPhone14ProMax
        case .iPhone(.unknown):
            return .iPhone11
        
        
        case .iPod(_):
            return .iPodTouch5
        
            
        case .iPad(.iPad), .iPad(.iPad2), .iPad(.iPad3), .iPad(.iPad4):
            return .iPad4
        case .iPad(.iPad5), .iPad(.iPad6):
            return .iPad5
        case .iPad(.iPad7), .iPad(.iPad8), .iPad(.iPad9):
            return .iPad7
        case .iPad(.iPadMini), .iPad(.iPadMini2), .iPad(.iPadMini3), .iPad(.iPadMini4):
            return .iPadMini
        case .iPad(.iPadMini5):
            return .iPadMini5
        case .iPad(.iPadMini6):
            return .iPadMini6
        case .iPad(.iPadAir):
            return .iPadAir
        case .iPad(.iPadAir2):
            return .iPadAir2
        case .iPad(.iPadAir3):
            return .iPadAir3
        case .iPad(.iPadAir4):
            return .iPadAir4
        case .iPad(.iPadAir5):
            return .iPadAir4
        case .iPad(.iPadPro12_9Inch):
            return .iPadPro12_9Inch
        case .iPad(.iPadPro9_7Inch):
            return .iPadPro9_7Inch
        case .iPad(.iPadPro12_9Inch2):
            return .iPadPro12_9Inch2
        case .iPad(.iPadPro10_5Inch):
            return .iPadPro10_5Inch
        case .iPad(.iPadPro12_9Inch3):
            return .iPadPro12_9Inch3
        case .iPad(.iPadPro11Inch), .iPad(.iPadPro11Inch2), .iPad(.iPadPro11Inch3):
            return .iPadPro11Inch
        case .iPad(.iPadPro12_9Inch4), .iPad(.iPadPro12_9Inch5):
            return .iPadPro12_9Inch4
        case .iPad(.unknown):
            return .iPad9
        default:
            return IRLDeviceScreenSize(width: -1, height: -1)
        }
    }
    
    
}
