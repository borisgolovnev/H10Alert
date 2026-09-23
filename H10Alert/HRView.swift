//
//  HRView.swift
//  H10ECG
//
//  Created by Boris Golovnev on 18/07/2022.
//

import UIKit

class HRView: UIView {
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    override func awakeFromNib() {
        super.awakeFromNib()
        commonInit()
    }
    
    func commonInit() {
        backgroundColor = .clear
    }
    
    weak var data:ECGData? {
        didSet{
            setNeedsDisplay()
        }
    }
    weak var analysis:ECGAnalyserAnalysis? {
        didSet{
            setNeedsDisplay()
        }
    }
    
    override func draw(_ rect: CGRect) {

        let heartRates = data?.heartRates ?? analysis?.heartRates
        let numSamples = heartRates?.count ?? 0
        guard numSamples > 2 else {
            return
        }
        
        let w = bounds.width / 2.0
        let samplesPerPixel = max(1, Int(floor(Double(numSamples) / Double(w))))
        let scale = bounds.width / Double(numSamples / samplesPerPixel)
        
        var minPoints = [CGFloat]()
        var points = [CGPoint]()
        var maxPoints = [CGFloat]()
        for i in stride(from: 0, to: numSamples, by: samplesPerPixel) {
            var sumHr = 0
            var minHr = 9000
            var maxHr = 0
            let bucketEnd = min(i + samplesPerPixel, numSamples)
            for ii in i..<bucketEnd {
                let hr = Int(heartRates![ii])
                sumHr += hr
                minHr = min(hr, minHr)
                maxHr = max(hr, maxHr)
            }
            let bucketCount = bucketEnd - i
            let avg = Double(sumHr) / Double(bucketCount)
            
            points.append(CGPoint(x: Double(i / samplesPerPixel) * scale, y: bounds.height - avg / 2.0))
            minPoints.append(bounds.height - CGFloat(minHr) / 2.0)
            maxPoints.append(bounds.height - CGFloat(maxHr) / 2.0)
        }

        if let ctx = UIGraphicsGetCurrentContext() {
            
            //draw levels
            ctx.setLineWidth(0.25)
            ctx.setStrokeColor(UIColor.lightGray.cgColor)
            for bpm in [60.0, 100.0, 120.0, 160.0] {
                let level = bounds.height - bpm / 2.0
                ctx.move(to: CGPoint(x: 0, y: level))
                ctx.addLine(to: CGPoint(x: bounds.width, y: level))
                ctx.strokePath()
            }
            
            //draw minmax
            ctx.setStrokeColor(UIColor.clear.cgColor)
            ctx.setFillColor(UIColor(white: 0.5, alpha: 0.5).cgColor)
            ctx.move(to: CGPoint(x: points.first!.x, y: maxPoints.first!))
            for i in 1..<points.count {
                ctx.addLine(to: CGPoint(x: points[i].x, y: maxPoints[i]))
            }
            ctx.addLine(to: CGPoint(x: points.last!.x, y: minPoints.last!))
            for i in 1..<points.count {
                let reverseI = points.count - i - 1
                ctx.addLine(to: CGPoint(x: points[reverseI].x, y: minPoints[reverseI]))
            }
            ctx.addLine(to: CGPoint(x: points.first!.x, y: maxPoints.first!))
            ctx.fillPath()
            
            //draw avg
            ctx.setStrokeColor(UIColor.label.cgColor)
            ctx.setLineWidth(2.0)
            ctx.setLineJoin(.round)
            ctx.move(to: points.first!)
            for i in 1..<points.count {
                ctx.addLine(to: points[i])
            }
            ctx.strokePath()
        }
    }
    
    override func setNeedsDisplay() {
        super.setNeedsDisplay(bounds)
    }
    
}
