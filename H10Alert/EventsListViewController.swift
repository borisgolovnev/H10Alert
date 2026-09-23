//
//  EventsListViewController.swift
//  H10ECG
//
//  Created by Boris Golovnev on 14/07/2026.
//

import UIKit
import InfiniteGraph

class EventsListViewController : UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    static let df:DateFormatter = {
        let result = DateFormatter()
        result.dateStyle = .medium
        result.timeStyle = .medium
        return result
    }()
    
    var ecgData:ECGData!
    @IBOutlet var tableView:UITableView!
    @IBOutlet var ecgView:ECGView!
    
    override func viewDidLoad() {
        ecgView.data = ecgData
        ecgView.contentSize = CGSize(width: 90000000, height: ecgView.frame.height)
        ecgView.redrawCurrent()
    }
    
    
    
    
    
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        ecgData.notes.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var result:UITableViewCell!
        if let cell = tableView.dequeueReusableCell(withIdentifier: "cell") {
            result = cell
        } else {
            result = UITableViewCell(style: .subtitle, reuseIdentifier: "cell")
        }
        
        let keys = Array(ecgData.notes.keys).sorted()
        let cellKey = keys[indexPath.row]
        
        let eventTimestamp = ecgData.getSampleNumberAt(timestamp:cellKey)
        let eventDate = ecgData.startDate.addingTimeInterval(Double(eventTimestamp) / ecgData.samplesPerSecond)
        
        var config = UIListContentConfiguration.subtitleCell()
        config.text = ecgData.notes[cellKey]
        config.secondaryText = EventsListViewController.df.string(from: eventDate)
        config.textProperties.color = .label
        config.secondaryTextProperties.color = .secondaryLabel
        result.contentConfiguration = config
        
        return result
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let keys = Array(ecgData.notes.keys).sorted()
        let cellKey = keys[indexPath.row]
        let relative = ecgData.getRelativePosition(of: cellKey)
        ecgView.scrollTo(point: relative, relative: true)
    }
    
}
