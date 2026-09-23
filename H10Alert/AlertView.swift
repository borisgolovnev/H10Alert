//
//  AlertView.swift
//  H10Alert
//
//  Created by Boris Golovnev on 15/06/2026.
//

import UIKit
import AVFoundation

class AlertView : UIView {
    
    let lbl = UILabel()
    
    var text:String? {
        get { lbl.text }
        set {
            lbl.text = newValue
            lbl.sizeToFit()
        }
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    func commonInit() {
        backgroundColor = UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)
        
        lbl.textColor = .white
        lbl.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        lbl.text = "Abnormal heart rate"
        lbl.sizeToFit()
        addSubview(lbl)
        
        layer.cornerRadius = 16
        layer.masksToBounds = true
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        lbl.center = CGPoint(x: bounds.width/2.0, y: bounds.height * 0.35)
    }
    
}
