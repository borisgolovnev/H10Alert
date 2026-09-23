//
//  ViewController.swift
//  H10Alert
//
//  Created by Boris Golovnev on 08/06/2026.
//

import UIKit

import PolarBleSdk
import RxSwift
import InfiniteGraph
import AVFoundation

class ViewController: UIViewController, PolarBleApiDeviceFeaturesObserver, PolarBleApiDeviceHrObserver {
    
    @IBOutlet weak var liveView: LiveEcgView!
    @IBOutlet weak var liveStatus: LiveStatusView!
    @IBOutlet weak var btnSymptoms: MainScreenButton!
    @IBOutlet weak var btnCancel: MainScreenButton!
    @IBOutlet weak var btnPhoto: MainScreenButton!
    @IBOutlet weak var btnDialNeighbor: MainScreenButton!
    @IBOutlet weak var btnDialEmergency: MainScreenButton!
    @IBOutlet weak var checkmark:UIImageView!
    @IBOutlet weak var stMockHR:UISegmentedControl!
    
    var leadsOn = false
    
    var liveData = ECGData()
    let hrCheck = HRChecker()
    let alertAbnormal = {
        let view = AlertView()
        view.text = "Abnormal heart rate"
        return view
    }()
    let alertIrregular = {
        let view = AlertView()
        view.backgroundColor = UIColor(red: 1.0, green: 1.0, blue: 0.0, alpha: 0.4)
        view.text = "Irregular heart rhythm"
        return view
    }()
    let prealarmPlayer = AlertPlayer(soundName: "Beacon")
    let alarmPlayer = AlertPlayer(soundName: "Alarm")
    let mockReaderAFIB = MockReader("afib")
    let mockReaderSVTA = MockReader("svta", startIndex: (28*60+33) * 130)
    let mockReaderBrad = MockReader("brady")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.deviceConnecting), name: PolarNotification.deviceConnecting, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.deviceChanged), name: PolarNotification.deviceChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.batteryCharge), name: PolarNotification.deviceBattery, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(self.appWillClose), name: UIApplication.willTerminateNotification, object: nil)
        
        let addEventAction = UIAction(title: "Mark event",
                                      image: UIImage(systemName: "pencil.tip.crop.circle.badge.plus") ) { [weak self] _ in self?.doMakeEvent() }
        let topMenu = UIMenu(title: "", options: .displayInline, children: [addEventAction])
        
        var menuItemsArray = [UIAction]()
        for eventType in ["Palpitations", "Light-headedness", "Chest pain", "Shortness of breath", "Start sleeping", "Woke from sleep"] {
            let eventTypeItem = UIAction(title: eventType, image: nil ) { [weak self] _ in self?.doMakeEvent(eventType) }
            menuItemsArray.append(eventTypeItem)
        }
        
        let eventsMenu = UIMenu(title: "Preset events:", options:.displayInline, children: menuItemsArray)
        
        btnSymptoms.menu = UIMenu(title: "", children: [topMenu, eventsMenu])
        btnSymptoms.showsMenuAsPrimaryAction = true
        btnSymptoms.layer.shouldRasterize = true
        btnSymptoms.layer.rasterizationScale = view.window?.screen.scale ?? 3.0
        
        checkmark.alpha = 0
        liveView.statusLabel.text = "Not connected"
        liveStatus.clear()
        
        liveView.addSubview(alertAbnormal)
        liveView.addSubview(alertIrregular)
        
        btnCancel.isEnabled = false
        alertAbnormal.isHidden = true
        alertIrregular.isHidden = true
        hrCheck.issueAlert0 = {
            self.alertIrregular.isHidden = false
            self.btnCancel.isEnabled = true
            self.prealarmPlayer.startPlayback()
            self.doMakeEvent("Alert level 1", showConfirmation: false)
        }
        
        hrCheck.issueAlert1 = {
            self.doDialEmergency(self.btnDialEmergency!)
            self.prealarmPlayer.stopPlayback()
            self.alarmPlayer.startPlayback()
            self.doMakeEvent("Alert level 2", showConfirmation: false)
        }
        
        hrCheck.irregularAlert = { isIrregular in
            if isIrregular {
                self.doMakeEvent("Irregular rhythm", showConfirmation: false)
                self.alertAbnormal.isHidden = true
                self.btnCancel.isEnabled = true
            }
            self.alertIrregular.isHidden = !isIrregular
        }
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        
        alertAbnormal.frame = liveView.bounds
        alertIrregular.frame = liveView.bounds
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        btnPhoto.isHidden = !UserDefaults.standard.bool(forKey: UserDefaults.AlertKeys.takePhotoEnabled)
        stMockHR.isHidden = !UserDefaults.standard.bool(forKey: UserDefaults.AlertKeys.debugEnabled)
        
        var api = PolarApiWrapper.shared().api
        api.deviceHrObserver = self
        api.deviceFeaturesObserver = self
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if UserDefaults.standard.bool(forKey: UserDefaults.Keys.clearOnLiveOpen) {
            clear()
        }
        checkVolumeAndWarnIfLow()
    }
    
    func checkVolumeAndWarnIfLow(threshold: Float = 0.6) {
        let session = AVAudioSession.sharedInstance()
        
        do {
            try session.setActive(true)
        } catch {
            print("Failed to activate audio session: \(error)")
            return
        }
        let volume = session.outputVolume

        guard volume < threshold else { return }

        let alert = UIAlertController(
            title: "Volume Is Low",
            message: "Your device volume is low. Turn it up so you hear the alerts.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))

        present(alert, animated: true)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if segue.destination is SettingsViewController {
            (segue.destination as! SettingsViewController).onDismissBlock = { [weak self] in
                self?.btnPhoto.isHidden = !UserDefaults.standard.bool(forKey: UserDefaults.AlertKeys.takePhotoEnabled)
                self?.stMockHR.isHidden = !UserDefaults.standard.bool(forKey: UserDefaults.AlertKeys.debugEnabled)
            }
        } else if segue.destination is EventsListViewController {
            (segue.destination as! EventsListViewController).ecgData = liveData
        }
    }

    @IBAction func doCancel(_ sender: Any) {
        hrCheck.reset()
        btnCancel.isEnabled = false
        alertAbnormal.isHidden = true
        alertIrregular.isHidden = true
        prealarmPlayer.stopPlayback()
        alarmPlayer.stopPlayback()
    }
    
    @IBAction func doTakePhoto(_ sender: Any) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            let alert = UIAlertController(title: "Camera Unavailable", message: "This device has no camera available.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = self
        present(picker, animated: true)
    }
    
    @IBAction func doDialNeighbor(_ sender: Any) {
        let neighborPhoneNumber = UserDefaults.standard.string(forKey: UserDefaults.AlertKeys.neighborPhoneNumber) ?? ""
        if !neighborPhoneNumber.isEmpty {
            guard let url = URL(string: "tel://" + neighborPhoneNumber), UIApplication.shared.canOpenURL(url) else {
                return
            }
            UIApplication.shared.open(url)
        } else {
            let alert = UIAlertController(title: "No neighbor phone number is set", message: "Set one in settings", preferredStyle: .alert)
            let okAction = UIAlertAction(title: "Ok", style: .cancel)
            alert.addAction(okAction)
            present(alert, animated: true)
        }
    }
    
    @IBAction func doDialEmergency(_ sender: Any) {
        let emergencyNumber = UserDefaults.standard.string(forKey: UserDefaults.AlertKeys.emergencyPhoneNumber) ?? ""
        if !emergencyNumber.isEmpty {
            guard let url = URL(string: "tel://" + emergencyNumber), UIApplication.shared.canOpenURL(url) else {
                return
            }
            UIApplication.shared.open(url)
        }
    }
    
    

    
    @objc private func deviceConnecting(notification: NSNotification) {
        if let deviceInfo = notification.object as? PolarDeviceInfo {
            liveView.statusLabel.text = "Connecting to \(deviceInfo.deviceId)"
        } else {
            liveView.statusLabel.text = "Connecting..."
        }
    }
    
    @objc private func deviceChanged(notification: NSNotification) {
        if let deviceInfo = notification.object as? PolarDeviceInfo {
            liveView.statusLabel.text = "Connected to \(deviceInfo.deviceId)"
        } else {
            liveStatus.clear()
        }
    }
    
    @objc private func batteryCharge(notification: NSNotification) {
//        if let charge = notification.object as? UInt {
//            
//        }
    }
    
    @objc private func appWillClose(notification: NSNotification) {
        if UserDefaults.standard.bool(forKey: UserDefaults.Keys.autoSave) {
            let task = UIApplication.shared.beginBackgroundTask()
            liveData.saveToFile()
            UIApplication.shared.endBackgroundTask(task)
        }
    }
    
    
    func hrValueReceived(_ identifier: String, data: (hr: UInt8, rrs: [Int], rrsMs: [Int], contact: Bool, contactSupported: Bool)) {
        //print("HR notification: \(data.hr) rrs: \(data.rrs)")
        var hr = data.hr
        if data.contactSupported && !data.contact {
            hr = 0
            leadsOn = false
        }
        leadsOn = true
        liveData.append(heartRate: hr)
    }
    
    func processEcgData(_ data:PolarEcgData) {
        var newData = data
        if self.stMockHR.selectedSegmentIndex == 1 {
            newData = self.mockReaderSVTA.replace(data)
        } else if self.stMockHR.selectedSegmentIndex == 2 {
            newData = self.mockReaderBrad.replace(data)
        } else if self.stMockHR.selectedSegmentIndex == 3 {
            newData = self.mockReaderAFIB.replace(data)
        }
        self.liveData.append(newData: newData)
        self.liveStatus.setTime(duration: self.liveData.recordedDuration)
        
        hrCheck.checkData(data: newData)
        liveStatus.bpm = hrCheck.lastHr
        
        if self.leadsOn {
            let samples = newData.samples.map{Float($0.voltage)/1000.0}
            self.liveView.append(samples)
        }
    }
    
    @IBAction func saveTap() {
        let oldData = liveData
        clear()
        
        if !UserDefaults.standard.bool(forKey: UserDefaults.Keys.autoSave) {
            DispatchQueue.global(qos: .utility).async {
                oldData.saveToFile()
            }
        }
    }
    
    func doMakeEvent(_ name:String = "Event", showConfirmation:Bool = true) {
        if liveData.markNow(name) {
            if showConfirmation {
                checkmark.alpha = 1.0
                UIView.animate(withDuration: 0.33, delay: 2.0) {
                    self.checkmark.alpha = 0.0
                }
            }
        }
    }
    
    @IBAction func clear() {
        if UserDefaults.standard.bool(forKey: UserDefaults.Keys.autoSave) {
            let oldData = liveData
            DispatchQueue.global(qos: .utility).async {
                oldData.saveToFile()
            }
        }
        liveData = ECGData()
    }
    
    
    
    
    func doExport() {
        if liveData.recordedDuration > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let sb = UIStoryboard(name: "RecordingExport", bundle: nil)
                let revc = sb.instantiateInitialViewController() as! RecordingExportViewController
                revc.data = self.liveData
                self.present(revc, animated: true)
            }
        }
    }
    
    
    
    
    
    
    
    
    
    
    
    
    
    func hrFeatureReady(_ identifier: String) {
        print("HR READY")
    }
    func ftpFeatureReady(_ identifier: String) {
        
    }
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdk.PolarBleSdkFeature) {
        print("Feature \(feature) is ready.")
        if feature == PolarBleSdkFeature.feature_polar_online_streaming {
            
        }
    }
    func streamingFeaturesReady(_ identifier: String, streamingFeatures: Set<PolarBleSdk.PolarDeviceDataType>) {
        for feature in streamingFeatures {
            if feature == .ecg {
                PolarApiWrapper.shared().startEcgWithDataCallback() { (data:PolarEcgData) in
                    self.processEcgData(data)
                }
            }
        }
    }
    
}




extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        guard let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) else { return }
        guard let imageData = image.jpegData(compressionQuality: 0.9) else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "report_\(formatter.string(from: Date())).jpg"
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(filename)
        
        try? imageData.write(to: url)
        picker.dismiss(animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
