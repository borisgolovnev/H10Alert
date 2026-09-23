//
//  LiveStatusView.swift
//  H10Alert
//
//  Created by Boris Golovnev on 10/06/2026.
//

import UIKit

class LiveStatusView : UIView
{
    
    let topLine = UIView()
    let middleLine = UIView()
    
    let timeLabel = UILabel()
    let timeTitle = UILabel()
    let bpmLabel = UILabel()
    let bpmTitle = UILabel()
    
    
    var bpm:Int = 72 {
        didSet {
            let image = UIImage(systemName: "heart.fill")!.withTintColor(.red, renderingMode: .alwaysOriginal)
            
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: -4, width: image.size.width * 1.4, height: image.size.height * 1.4)

            let symbolString = NSAttributedString(attachment: attachment)

            let result = NSMutableAttributedString(string: "  \(bpm) ")
            result.setAttributes([.font: UIFont.systemFont(ofSize: 24, weight: .semibold)], range: NSRange(location: 0, length: result.length))
            result.append(symbolString)
            
            bpmLabel.attributedText = result
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
        backgroundColor = .clear
        
        topLine.backgroundColor = UIColor(white: 0.5, alpha: 0.5)
        addSubview(topLine)
        
        middleLine.backgroundColor = UIColor(white: 0.5, alpha: 0.5)
        addSubview(middleLine)
        
        timeLabel.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        timeLabel.text = " 24:00:00 "
        timeLabel.sizeToFit()
        addSubview(timeLabel)
        
        timeTitle.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        timeTitle.text = "Recording Time"
        timeTitle.sizeToFit()
        addSubview(timeTitle)
        
        bpmLabel.font = UIFont.systemFont(ofSize: 24, weight: .semibold)
        bpmLabel.textAlignment = .center
        self.bpm = 9000
        bpmLabel.sizeToFit()
        addSubview(bpmLabel)
        
        bpmTitle.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        bpmTitle.text = "BPM"
        bpmTitle.sizeToFit()
        addSubview(bpmTitle)
    }
    
    
    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        let midpoint = b.width * 0.55
        let leftCenter = midpoint / 2.0
        let rightCenter = midpoint + (b.width - midpoint) / 2.0
        topLine.frame = CGRect(x: 0, y: 0, width: b.width, height: 1)
        middleLine.frame = CGRect(x: midpoint, y: 8, width: 1, height: b.height - 16)
        
        timeLabel.center = CGPoint(x: leftCenter, y: b.height * 0.4)
        timeTitle.center = CGPoint(x: leftCenter, y: b.height * 0.67)
        
        bpmLabel.center = CGPoint(x: rightCenter, y: b.height * 0.4)
        bpmTitle.center = CGPoint(x: rightCenter, y: b.height * 0.67)
    }
    
    func clear() {
        timeLabel.text = " 00:00:00 "
        bpm = 0
    }
    
    func setTime(duration:Double) {
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        timeLabel.text = String(format: " %02d:%02d:%02d ", hours, minutes, seconds)
    }
    

}
