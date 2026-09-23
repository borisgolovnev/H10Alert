//
//  ECGAnalyserOverlay.swift
//  H10ECG
//
//  Created by Boris Golovnev on 28/07/2022.
//

import UIKit

class ECGAnalyserOverlay: UIView {
    
    let scale:CGFloat
    let analyzer:ECGAnalyser
    var extraGraphsToDraw = [Any]()
    
    init(frame:CGRect, analyzer:ECGAnalyser, scale:CGFloat) {
        self.analyzer = analyzer
        self.scale = scale
        
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        
        let rWaves = analyzer.waves.filter {$0.type == .r}
        let offsets = rWaves.map { $0.offset }
        addRRsForIndices(offsets, yPos: bounds.midY - 60)
        
        #if DEBUG
        extraGraphsToDraw.append(analyzer.bandpassData)
        extraGraphsToDraw.append(analyzer.integralData)
        extraGraphsToDraw.append(analyzer.thresholds)
        #endif
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func addRRsForIndices(_ qrsIndices:[Int], yPos:Double = 30) {
        if qrsIndices.count > 1 {
            for i in 1..<qrsIndices.count {
                let RRsamples = qrsIndices[i] - qrsIndices[i-1]
                let RRseconds = Double(RRsamples) / analyzer.valuesPerSecond
                let RRms = Int(RRseconds * 1000)
                let HR = Int(round(60.0 / RRseconds))
                let centerx = (CGFloat(qrsIndices[i] + qrsIndices[i-1]) / 2.0) / analyzer.valuesPerPoint + 2
                let showHR = UserDefaults.standard.bool(forKey: UserDefaults.Keys.showHR)
                let showRR = UserDefaults.standard.bool(forKey: UserDefaults.Keys.showRR)
                let string = (showRR ? String(RRms) : "") + "\n" + (showHR ? String(HR) : "")
                let label = UILabel.standardLabel(withText: string)
                label.textAlignment = .center
                label.center = CGPoint(x: centerx, y: yPos)
                addSubview(label)
            }
        }
    }
    
    override func draw(_ rect: CGRect) {
        super.draw(rect)
        
        let colors = [UIColor.red, UIColor.green, UIColor.blue, UIColor.yellow, UIColor.cyan, UIColor.magenta, UIColor.white, UIColor.brown, UIColor.lightGray, UIColor.systemGray]
        var index = 0
        if let ctx = UIGraphicsGetCurrentContext() {
            for samples in extraGraphsToDraw {
                if samples is [Float] {
                    drawSeries(samples as! [Float], inContext: ctx, withColor: colors[index])
                } else if samples is [Double] {
                    drawSeries(samples as! [Double], inContext: ctx, withColor: colors[index])
                } else if samples is [Int32] {
                    drawSeries(samples as! [Int32], inContext: ctx, withColor: colors[index])
                }
                index += 1
            }
        }
    }
    
    func drawSeries(_ series:[Float], inContext ctx:CGContext, withColor color:UIColor, withOffset offset:CGFloat = 0) {
        let ints = series.map {Int32($0)}
        self.drawSeries(ints, inContext: ctx, withColor: color, withOffset: offset)
    }
    
    func drawSeries(_ series:[Double], inContext ctx:CGContext, withColor color:UIColor, withOffset offset:CGFloat = 0) {
        let ints = series.map {Int32($0)}
        self.drawSeries(ints, inContext: ctx, withColor: color, withOffset: offset)
    }
    
    func drawSeries(_ series:[Int32], inContext ctx:CGContext, withColor color:UIColor, withOffset offset:CGFloat = 0) {
        ctx.setLineWidth(1)
        ctx.setStrokeColor(color.cgColor)
        
        let xstep = 1.0 / analyzer.valuesPerPoint
        
        let ymid = bounds.midY
        for i in 0..<series.count {
            let pt = CGPoint(x: xstep + xstep * Double(i),
                             y: offset + ymid - CGFloat(series[i]) * scale)
            if i == 0 {
                ctx.move(to: pt)
            } else {
                ctx.addLine(to: pt)
            }
        }
        
        ctx.strokePath()
    }
    
}
