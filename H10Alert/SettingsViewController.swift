//
//  SettingsViewController.swift
//  H10Alert
//
//  Created by Boris Golovnev on 11/06/2026.
//

import UIKit

class SettingsViewController : UITableViewController
{
    
    @IBOutlet weak var tfName: UITextField!
    @IBOutlet weak var tfNeighborPhone: UITextField!
    @IBOutlet weak var sgEmergencyPhone: UISegmentedControl!
    @IBOutlet weak var stLowHR: UIStepper!
    @IBOutlet weak var lblLowHR: UILabel!
    @IBOutlet weak var stHighHR: UIStepper!
    @IBOutlet weak var lblHighHR: UILabel!
    @IBOutlet weak var stAlert0Delay: UIStepper!
    @IBOutlet weak var lblAlert0Delay: UILabel!
    @IBOutlet weak var stAlert1Delay: UIStepper!
    @IBOutlet weak var lblAlert1Delay: UILabel!
    @IBOutlet weak var swTakePhoto: UISwitch!
    @IBOutlet weak var swDebugButtons: UISwitch!
    
    
    var onDismissBlock: (()->Void)? = nil
    
    override func viewDidLoad() {
        let ud = UserDefaults.standard
        
        tfName.text = ud.string(forKey: UserDefaults.AlertKeys.userName)
        
        tfNeighborPhone.text = ud.string(forKey: UserDefaults.AlertKeys.neighborPhoneNumber)
        
        let usSelected = ud.string(forKey: UserDefaults.AlertKeys.emergencyPhoneNumber) == "911"
        sgEmergencyPhone.selectedSegmentIndex = usSelected ? 0 : 1
        
        stLowHR.value = Double(ud.integer(forKey: UserDefaults.AlertKeys.lowHR))
        stHighHR.value = Double(ud.integer(forKey: UserDefaults.AlertKeys.highHR))
        stAlert0Delay.value = Double(ud.integer(forKey: UserDefaults.AlertKeys.alert0Delay))
        stAlert1Delay.value = Double(ud.integer(forKey: UserDefaults.AlertKeys.alert1Delay))
        
        swTakePhoto.isOn = ud.bool(forKey: UserDefaults.AlertKeys.takePhotoEnabled)
        swDebugButtons.isOn = ud.bool(forKey: UserDefaults.AlertKeys.debugEnabled)
        
        updateTimeLabels()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismissBlock?()
    }
    
    func updateTimeLabels() {
        lblLowHR.text = "Low HR: \(Int(stLowHR.value))"
        lblHighHR.text = "High HR: \(Int(stHighHR.value))"
        lblAlert0Delay.text = "Alert 1 delay: \(Int(stAlert0Delay.value)) s"
        lblAlert1Delay.text = "Alert 2 delay: \(Int(stAlert1Delay.value)) s"
    }
    
    @IBAction func handleNameChanged(_ sender: UITextField) {
        UserDefaults.standard.set(sender.text, forKey: UserDefaults.AlertKeys.userName)
    }
    @IBAction func handleNeighborPhoneChange(_ sender: UITextField) {
        UserDefaults.standard.set(sender.text, forKey: UserDefaults.AlertKeys.neighborPhoneNumber)
    }
    
    @IBAction func handleEmergencyPhoneChange(_ sender: UISegmentedControl) {
        if sender.selectedSegmentIndex == 0 {
            UserDefaults.standard.set("911", forKey: UserDefaults.AlertKeys.emergencyPhoneNumber)
        } else {
            UserDefaults.standard.set("112", forKey: UserDefaults.AlertKeys.emergencyPhoneNumber)
        }
    }
    
    @IBAction func handleLowHRChange(_ sender: UIStepper) {
        let newValue = Int(stLowHR.value)
        UserDefaults.standard.setValue(newValue, forKey: UserDefaults.AlertKeys.lowHR)
        updateTimeLabels()
    }
    @IBAction func handleHighHRChange(_ sender: UIStepper) {
        let newValue = Int(stHighHR.value)
        UserDefaults.standard.setValue(newValue, forKey: UserDefaults.AlertKeys.highHR)
        updateTimeLabels()
    }
    @IBAction func handleAlert0DelayChange(_ sender: UIStepper) {
        let newValue = Int(stAlert0Delay.value)
        UserDefaults.standard.setValue(newValue, forKey: UserDefaults.AlertKeys.alert0Delay)
        updateTimeLabels()
    }
    @IBAction func handleAlert1DelayChange(_ sender: UIStepper) {
        let newValue = Int(stAlert1Delay.value)
        UserDefaults.standard.setValue(newValue, forKey: UserDefaults.AlertKeys.alert1Delay)
        updateTimeLabels()
    }
    
    @IBAction func doExport(_ sender: Any) {
        if let vc = presentingViewController as? ViewController {
            vc.doExport()
        }
        dismiss(animated: true)
    }
    
    @IBAction func handlePhotoEnabledChange(_ sender: UISwitch) {
        UserDefaults.standard.setValue(swTakePhoto.isOn, forKey: UserDefaults.AlertKeys.takePhotoEnabled)
    }
    
    @IBAction func handleDebugEnabledChange(_ sender: UISwitch) {
        UserDefaults.standard.setValue(swDebugButtons.isOn, forKey: UserDefaults.AlertKeys.debugEnabled)
    }
}
