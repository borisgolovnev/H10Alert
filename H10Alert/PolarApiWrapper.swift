//
//  PolarApiWrapper.swift
//  H10ECG
//
//  Created by Boris Golovnev on 05/04/2021.
//

import Foundation
import PolarBleSdk
import RxSwift
import CoreBluetooth

struct PolarNotification {
    static let deviceConnecting = NSNotification.Name("deviceConnecting")
    static let deviceDisconnected = NSNotification.Name("deviceDisconnected")
    static let deviceChanged = NSNotification.Name("connectedDeviceChange")
    static let deviceBattery = NSNotification.Name("deviceBattery")
}

class PolarApiWrapper : PolarBleApiObserver, PolarBleApiDeviceInfoObserver, PolarBleApiLogger {
    
    private static var sharedApi: PolarApiWrapper = {
        let sharedApi = PolarApiWrapper()
        return sharedApi
    }()

    class func shared() -> PolarApiWrapper {
        return sharedApi
    }
    
    private init() {
        api = PolarBleApiDefaultImpl.polarImplementation(DispatchQueue.main, features: [.feature_polar_online_streaming, .feature_hr])
        api.observer = self
        api.deviceInfoObserver = self
        api.logger = self
        
        deviceId = UserDefaults.standard.string(forKey: UserDefaults.Keys.lastConnectedId) ?? ""
        if UserDefaults.standard.bool(forKey: UserDefaults.Keys.autoConnect) {
            tryToConnect()
        }
    }

    var api:PolarBleApi
    var deviceId = ""
    var connectedDevice = ""
    
    
    
    
    var deviceList = [PolarDeviceInfo]()
    var deviceSearch:Disposable?
    func searchForDevices(withCompletionHandler completion:@escaping ()->Void) {
        deviceList.removeAll()
        self.stopSearch()
        deviceSearch = api.searchForDevice()
            .observe(on: MainScheduler.instance)
            .subscribe{ e in
                switch e {
                case .completed:
                    NSLog("search complete")
                case .error(let err):
                    NSLog("search error: \(err)")
                case .next(let item):
                    if item.name.matches("Polar H10 \\w{8}") {
                        self.deviceList.append(item)
                        completion()
                        NSLog("polar device found: \(item.name) connectable: \(item.connectable) address: \(item.address.uuidString)")
                    } else {
                        NSLog("some device found")
                    }
                    
                }
            }
    }
    func stopSearch() {
        deviceSearch?.dispose()
        deviceSearch = nil
    }
    
    
    
    
    func select(device:PolarDeviceInfo) {
        deviceId = device.deviceId
        tryToConnect()
    }
    
    func tryToConnect() {
        if deviceId != "" {
            do{
                print("connecting to \(deviceId)")
                try api.connectToDevice(deviceId)
            } catch let err {
                print("\(err)")
                deviceId = ""
            }
        }
    }
    
    
    
    
    
    
    
    
    var ecgRequest:Disposable?
    func startEcgWithDataCallback(callback:@escaping (PolarEcgData)->Void) {
        self.stopEcg()
        ecgRequest = PolarApiWrapper.shared().api.requestStreamSettings(self.connectedDevice, feature: .ecg)
            .asObservable()
            .flatMap({ (settings) -> Observable<PolarEcgData> in
                return self.api.startEcgStreaming(self.connectedDevice, settings: settings.maxSettings())
            })
            .observe(on: MainScheduler.instance)
            .subscribe{ e in
                switch e {
                case .next(let data):
                    callback(data)
                case .error(let err):
                    print("ECG error: \(err)")
                    self.stopEcg()
                case .completed:
                    print("completed")
                    break
                }
            }
    }
    func stopEcg() {
        ecgRequest?.dispose()
        self.ecgRequest = nil
    }
    
    
    
    
    
    
    
    
    func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {
        print("DEVICE CONNECTING: \(polarDeviceInfo)")
        NotificationCenter.default.post(name: PolarNotification.deviceConnecting, object: polarDeviceInfo)
    }
    
    func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
        print("DEVICE CONNECTED: \(polarDeviceInfo)")
        connectedDevice = polarDeviceInfo.deviceId
        UserDefaults.standard.set(connectedDevice, forKey: UserDefaults.Keys.lastConnectedId)
        NotificationCenter.default.post(name: PolarNotification.deviceChanged, object: polarDeviceInfo)
    }
    
    func deviceDisconnected(_ identifier: PolarBleSdk.PolarDeviceInfo, pairingError: Bool) {
        print("DISCONNECTED: \(identifier)")
        connectedDevice = ""
        NotificationCenter.default.post(name: PolarNotification.deviceDisconnected, object: identifier)
        NotificationCenter.default.post(name: PolarNotification.deviceChanged, object: nil)
    }
    
    
    
    
    
    
    
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        print("battery level updated: \(batteryLevel)")
        NotificationCenter.default.post(name: PolarNotification.deviceBattery, object: batteryLevel)
    }
    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        print("received \(identifier) value \(value)")
    }
    
    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        print("received \(identifier) key \(key) value \(value)")
    }
    
    
    
    func message(_ str: String) {
        //NSLog("Polar SDK log:  \(str)")
    }
    
}
