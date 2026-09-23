//
//  InfiniteGraphRendererView.swift
//  InfiniteGraph
//
//  Created by Boris Golovnev on 21/5/21.
//

import UIKit

public class InfiniteGraphRendererView: UIView {
    
    class InfiniteGraphTiledLayer: CATiledLayer {
        override class func fadeDuration() -> CFTimeInterval {
            0
        }
    }
    public override class var layerClass: AnyClass { InfiniteGraphTiledLayer.self }
    
    weak var dataSource:InfiniteGraphDataSource? = nil {
        didSet {
            setNeedsDisplay()
        }
    }
    
    var highlightTiles = false
    var drawGrid = true
    var lineColor = UIColor.black
    var lineWidth = CGFloat(2.0)
    
    func gridPathForScaleUnit(unit:CGFloat, inRect rect:CGRect) -> UIBezierPath {
        let result = UIBezierPath()
        
        let rectTopLeft = rect.origin
        let gridTopLeft = CGPoint(x: ceil(rectTopLeft.x / unit) * unit,
                                  y: ceil(rectTopLeft.y / unit) * unit)
        let rectBottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        var left = gridTopLeft.x
        var top = gridTopLeft.y

        while left < rectBottomRight.x {
            result.move(to: CGPoint(x: left, y: rectTopLeft.y))
            result.addLine(to: CGPoint(x: left, y: rectBottomRight.y))
            left += unit
        }
        
        while top < rectBottomRight.y {
            result.move(to: CGPoint(x: rectTopLeft.x, y: top))
            result.addLine(to: CGPoint(x: rectBottomRight.x, y: top))
            top += unit
        }
        
        return result
    }
    
    func pathForSeries(series:[Int32], inRect rect:CGRect) -> UIBezierPath {
        let y = self.bounds.size.height / 2.0
        let left = rect.minX
        let width = rect.width
        let count = CGFloat(series.count)
        var counter = CGFloat(0.0)
        let result = UIBezierPath()
        var first = true
        for value in series {
            counter = counter + 1
            let offset = (counter / count) * width
            let norm = y - CGFloat(value) * dataSource!.valueScale
            if first {
                result.move(to: CGPoint(x: left + offset, y: norm))
                first = false
            } else {
                result.addLine(to: CGPoint(x: left + offset, y: norm))
            }
        }
        return result
    }
    
    public override func draw(_ rect: CGRect) {
        
        if highlightTiles {
            let bg = UIBezierPath(rect: rect)
            UIColor(red: CGFloat.random(in: 0.75...1), green: CGFloat.random(in: 0.75...1), blue: CGFloat.random(in: 0.75...1), alpha: 1.0).setFill()
            bg.fill()
        }
        
        if drawGrid {
            let mmPath = gridPathForScaleUnit(unit: InfiniteGraphView.screenMm, inRect: rect)
            UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.25).set()
            mmPath.lineWidth = 0.5
            mmPath.stroke()

            let fivemmPath = gridPathForScaleUnit(unit: 5 * InfiniteGraphView.screenMm, inRect: rect)
            UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.5).set()
            fivemmPath.lineWidth = 0.75
            fivemmPath.stroke()
            
            let cmPath = gridPathForScaleUnit(unit: 10 * InfiniteGraphView.screenMm, inRect: rect)
            UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0).set()
            cmPath.stroke()
        }
        
        if let data = dataSource {
            var expanedRect = rect
            expanedRect.origin.x -= 2
            expanedRect.size.width += 4
            
            let indexStart = Int(expanedRect.minX * data.valuesPerPoint)
            let indexEnd = Int(expanedRect.maxX * data.valuesPerPoint)
            
            let values = data.getData(from: indexStart, to: indexEnd)
            //print("requesting from \(indexStart) to \(indexEnd) and got \(values.count) values")
            
            if values.count > 0 {
                var clippedRect = expanedRect
                if values.count < indexEnd - indexStart {
                    clippedRect.size.width = CGFloat(values.count) / data.valuesPerPoint
                }
                
                lineColor.setStroke()
                let seriesPath = pathForSeries(series: values, inRect: clippedRect)
                seriesPath.lineWidth = lineWidth
                seriesPath.lineJoinStyle = .round
                seriesPath.lineCapStyle = .round
                seriesPath.stroke()
            }
        }
        
        super.draw(rect)
    }
}
