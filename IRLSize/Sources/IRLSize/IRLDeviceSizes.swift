//
//  File.swift
//  
//
//  Created by Boris Golovnev on 13/5/23.
//

import Foundation

// All measurements are in millimeters, sourced from official, publicly-
// available Apple device documentation here:
//
// https://developer.apple.com/accessories/

public struct IRLDeviceScreenSize {
    
    public let width:Double
    public let height:Double
    
    /////////////
    // iPhones //
    /////////////

    // iPhone 5
    static let iPhone5 = IRLDeviceScreenSize(width: 51.70, height: 90.39)
    static let iPhone5c = iPhone5
    static let iPhone5s = iPhone5
    static let iPhoneSE = iPhone5

    // iPhone 6
    static let iPhone6 = IRLDeviceScreenSize(width: 58.50, height: 104.05)
    static let iPhone6s = iPhone6
    static let iPhone7 = iPhone6
    static let iPhone8 = iPhone6
    static let iPhoneSE2 = iPhone6
    static let iPhoneSE3 = iPhone6
    
    // iPhone 6 Plus
    static let iPhone6Plus = IRLDeviceScreenSize(width: 68.36, height: 121.54)
    static let iPhone6sPlus = iPhone6Plus
    static let iPhone7Plus = iPhone6Plus
    static let iPhone8Plus = iPhone6Plus

    // iPhone X
    static let iPhoneX = IRLDeviceScreenSize(width: 63.12, height: 135.75)
    static let iPhoneXS = iPhoneX
    
    // iPhone XR
    static let iPhoneXR = IRLDeviceScreenSize(width: 64.58, height: 139.78)

    // iPhone XS Max
    static let iPhoneXSMax = IRLDeviceScreenSize(width: 69.61, height: 149.71)

    // iPhone 11
    static let iPhone11 = IRLDeviceScreenSize(width: 64.58, height: 139.77)
    static let iPhone12 = iPhone11
    static let iPhone12Pro = iPhone11
    static let iPhone13 = iPhone11
    static let iPhone13Pro = iPhone11
    static let iPhone14 = iPhone11
    
    // iPhone 11 Pro
    static let iPhone11Pro = IRLDeviceScreenSize(width: 62.33, height: 134.95)

    // iPhone 11 Pro Max
    static let iPhone11ProMax = IRLDeviceScreenSize(width: 68.81, height: 148.91)
    
    // iPhone 12 mini
    static let iPhone12Mini = IRLDeviceScreenSize(width: 57.67, height: 124.96)
    static let iPhone13Mini = iPhone12Mini
    
    // iPhone 12 Pro Max
    static let iPhone12ProMax = IRLDeviceScreenSize(width: 71.13, height: 153.90)
    static let iPhone13ProMax = iPhone12ProMax
    static let iPhone14Plus = iPhone12ProMax

    // iPhone 14 Pro
    static let iPhone14Pro = IRLDeviceScreenSize(width: 65.08, height: 141.09)

    // iPhone 14 Pro Max
    static let iPhone14ProMax = IRLDeviceScreenSize(width: 71.21, height: 154.34)

    
    
    
    
    
    ///////////
    // iPads //
    ///////////

    // iPad (4th Generation)
    static let iPad4 = IRLDeviceScreenSize(width: 149.0, height: 198.1)

    // iPad (5th Generation)
    static let iPad5 = IRLDeviceScreenSize(width: 147.97, height: 196.47)
    static let iPad6 = iPad5

    // iPad (7th Generation)
    static let iPad7 = IRLDeviceScreenSize(width: 155.52, height: 207.36)
    static let iPad8 = iPad7
    static let iPad9 = iPad7

    // iPad mini
    static let iPadMini = IRLDeviceScreenSize(width: 121.3, height: 161.2)
    static let iPadMini2 = iPadMini
    static let iPadMini3 = iPadMini
    static let iPadMini4 = iPadMini
    static let iPadMini5 = IRLDeviceScreenSize(width: 120.81, height: 160.74)
    static let iPadMini6 = IRLDeviceScreenSize(width: 117.06, height: 177.75)

    // iPad Air
    static let iPadAir = IRLDeviceScreenSize(width: 149.0, height: 198.1)
    static let iPadAir2 = IRLDeviceScreenSize(width: 153.71, height: 203.11)
    static let iPadAir3 = IRLDeviceScreenSize(width: 160.13, height: 213.50)
    static let iPadAir4 = IRLDeviceScreenSize(width: 158.44, height: 227.56)

    // iPad Pro
    static let iPadPro12_9Inch = IRLDeviceScreenSize(width: 196.61, height: 262.27)
    static let iPadPro9_7Inch = IRLDeviceScreenSize(width: 153.71, height: 203.11)
    static let iPadPro12_9Inch2 = IRLDeviceScreenSize(width: 196.61, height: 262.27)
    static let iPadPro10_5Inch = IRLDeviceScreenSize(width: 160.13, height: 213.50)
    static let iPadPro12_9Inch3 = IRLDeviceScreenSize(width: 197.61, height: 263.27)
    static let iPadPro11Inch = IRLDeviceScreenSize(width: 161.13, height: 230.25)
    static let iPadPro12_9Inch4 = IRLDeviceScreenSize(width: 196.61, height: 262.27)
    static let iPadPro11Inch2 = iPadPro11Inch
    static let iPadPro12_9Inch5 = iPadPro12_9Inch4
    static let iPadPro11Inch3 = iPadPro11Inch2

    /////////////////
    // iPods touch //
    /////////////////

    static let iPodTouch5 = IRLDeviceScreenSize(width: 49.92, height: 88.61)
    static let iPodTouch6 = iPodTouch5
    static let iPodTouch7 = iPodTouch5
    
    
    // Estimated heights for unknown devices use the most-recently-known height for
    // that screen size. These are used in the case of an unknown model identifier
    // (usually a new device) that shares a screen resolution with a known device.

    ///////////////////////
    // iPhone/iPod touch //
    ///////////////////////

    // 3.5"
    // None of the devices in the specifications I could find were 3.5" devices, so
    // these are the estimates from the previous version (1.3.0) of IRLSize.
    static let iPhone3_5Inch = IRLDeviceScreenSize(width: 49.3, height: 74.0)

    // 4.0"
    static let iPhone4_0Inch = iPhoneSE

    // 4.7"
    static let iPhone4_7Inch = iPhoneSE2

    // 5.5"
    static let iPhone5_5Inch = iPhone8Plus

    // 5.8"
    static let iPhone5_8Inch = iPhone11Pro

    // 6.1" (2018-2019)
    static let iPhone6_1Inch = iPhone11

    // 6.1" (2020-)
    static let iPhone6_1Inch2 = iPhone12

    // 6.5"
    static let iPhone6_5Inch = iPhone11ProMax

    // 6.7"
    static let iPhone6_7Inch = iPhone12ProMax

    //////////
    // iPad //
    //////////

    // 7.9"
    // Since both iPad mini and iPad have the same resolution, we can't use the
    // 7.9" screen dimensions for estimating. Keeping this here but marked as
    // __unused in case future iPad mini models have some other method of
    // disambiguating what they are if model identifier and resolution don't work
    // (e.g. if the next iPad mini has the same screen size but is 3x instead of
    // 2x).
    static let iPad7_9Inch = iPadMini5

    // 9.7"
    static let iPad9_7Inch = iPad6

    // 10.2"
    static let iPad10_2Inch = iPad8

    // 10.5"
    static let iPad10_5Inch = iPadPro10_5Inch

    // 11"
    static let iPad11Inch = iPadPro11Inch2

    // 12.9"
    static let iPad12_9Inch = iPadPro12_9Inch4
}
