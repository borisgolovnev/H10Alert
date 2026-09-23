//
//  ConnectionViewController.swift
//  H10ECG
//
//  Created by Boris Golovnev on 05/04/2021.
//

import UIKit
import PolarBleSdk

class ConnectionViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    
    @IBOutlet weak var tableView:UITableView!
    @IBOutlet weak var lblCurrentDevice:UILabel!
    
    override func viewDidLoad() {
        
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        PolarApiWrapper.shared().searchForDevices() {
            self.tableView.reloadData()
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(self.deviceChanged), name: PolarNotification.deviceChanged, object: nil)
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        PolarApiWrapper.shared().stopSearch()
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc private func deviceChanged(notification: NSNotification){
        if let device = notification.object as? PolarDeviceInfo {
            lblCurrentDevice.text = device.name
        } else {
            lblCurrentDevice.text = "None"
        }
        
        for cell in tableView.visibleCells {
            (cell as! DeviceCell).spinner.stopAnimating()
        }
    }
    
    
    
    
    
    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        PolarApiWrapper.shared().deviceList.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = PolarApiWrapper.shared().deviceList[indexPath.row]
        
        let cell = tableView.dequeueReusableCell(withIdentifier: "deviceCell") as! DeviceCell
        cell.title.text = item.name
        cell.rssi.text = String(item.rssi)
        cell.spinner.stopAnimating()
        
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = PolarApiWrapper.shared().deviceList[indexPath.row]
        let cell = tableView.cellForRow(at: indexPath) as! DeviceCell
        cell.spinner.startAnimating()
        PolarApiWrapper.shared().select(device: item)
    }
}
