//
//  ECGDataExporterGIF.swift
//  H10ECG
//
//  Created by Boris Golovnev on 10/16/22.
//

import Foundation
import ImageIO
import MobileCoreServices
import CoreGraphics
import UIKit
import UniformTypeIdentifiers

class ECGDataExporterGIF: ECGDataExporter {
    
    override var filename:String { super.filename + ".gif" }
    
    var mmPerSecond = 25.0
    var mmInPoints = 3.0
    var duration = 4.0
    var samplesPerGif = 0
    
    private var _ctx:CGContext!
    private var _destination:CGImageDestination!
    private var _framesAdded = 0
    private var _numFrames = 0
    private var _size = CGSize(width: 480, height: 200)
    private var _scale = 2.0
    private var _baselineAdjustment:CGFloat = 0.0
    
    override func updateParams() {
        exportInfo = "Short 4 second GIF\nanimating currently visible part."
    }
    
    override func doExport() {
        samplesPerGif = Int(data.samplesPerSecond * duration)
        mmInPoints = _size.width / (duration * mmPerSecond)
        
        let middle = (range.lowerBound + samplesPerGif / 2)
        let upper = min(data.numValues, middle + samplesPerGif / 2)
        let lower = max(0, upper - samplesPerGif)
        range = lower..<upper
        
        super.doExport()
        guard let outputURL else {return}
        
        _numFrames = Int(duration * 30)
        let fileProperties = [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0, kCGImagePropertyGIFHasGlobalColorMap:0]]
        _destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString, _numFrames, nil)
        CGImageDestinationSetProperties(_destination, fileProperties as CFDictionary)
        
        adjustSize()
        
        let w = Int(_size.width * _scale)
        let h = Int(_size.height * _scale)
        _ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 4 * w, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        _framesAdded = 0
        while addFrame() {}
        assert(_numFrames == _framesAdded)
        
        CGImageDestinationFinalize(_destination)
        delegate?.dataExporterDidFinish(dataUrl: outputURL)
    }
    
    func adjustSize() {
        let values = data.getData(from: 0 + range.lowerBound, to: range.count + range.lowerBound)
        let path = pathForSeries(series: values, inRect: CGRectMake(0, 0, _size.width, _size.height))
        let pathBounds = path.bounds
        _size.height = max(_size.height, min(480, pathBounds.size.height))
        _baselineAdjustment = (_size.height/2.0 - pathBounds.midY) / 2.0
    }
    
    func addFrame() -> Bool {
        
        _ctx.setFillColor(UIColor.black.cgColor)
        _ctx.fill([CGRect(x: 0, y: 0, width: _size.width * _scale, height: _size.height * _scale)])
        
        _ctx.saveGState()
        _ctx.translateBy(x: 0, y: _size.height * _scale)
        _ctx.scaleBy(x: _scale, y: -_scale)
        
        let progress = Double(_framesAdded) / Double(_numFrames)
        
        let stripeStart = 0
        let stripeEnd = Int(Double(samplesPerGif) * progress)
        
        autoreleasepool {
            drawStripe(from: stripeStart, to: stripeEnd)
            _ctx.restoreGState()
            
            if let frame = _ctx.makeImage() {
                let frameProperties = [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime: Float(1.0/30.0)]];
                CGImageDestinationAddImage(_destination, frame, frameProperties as CFDictionary)
            }
        }
        
        _framesAdded += 1
        delegate?.dataExporterIsExporting(progress: progress)
        
        return _framesAdded != _numFrames
    }
    
    func drawStripe(from:Int, to:Int) {
        
        let stripeRect = CGRect(x: 0, y: 0, width: _size.width, height: _size.height)
        
        if drawGrid {
            //grid
            let mmPath = gridPathForScaleUnit(unit: mmInPoints, inRect: stripeRect)
            _ctx.addPath(mmPath.cgPath)
            _ctx.setLineWidth(0.25)
            _ctx.setStrokeColor(UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.25).cgColor)
            _ctx.strokePath()
            
            let fivemmPath = gridPathForScaleUnit(unit: 5 * mmInPoints, inRect: stripeRect)
            _ctx.addPath(fivemmPath.cgPath)
            _ctx.setLineWidth(0.5)
            _ctx.setStrokeColor(UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.5).cgColor)
            _ctx.strokePath()
            
            let cmPath = gridPathForScaleUnit(unit: 10 * mmInPoints, inRect: stripeRect)
            _ctx.addPath(cmPath.cgPath)
            _ctx.setStrokeColor(UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0).cgColor)
            _ctx.strokePath()
        }
        
        //graph
        let values = data.getData(from: from + range.lowerBound, to: to + range.lowerBound)
        if values.count > 0 {
            var clippedRect = stripeRect
            if values.count < samplesPerGif {
                clippedRect.size.width *= Double(values.count) / Double(samplesPerGif)
            }
            
            _ctx.clip(to: [stripeRect])
            
            let seriesPath = pathForSeries(series: values, inRect: clippedRect)
            _ctx.addPath(seriesPath.cgPath)
            _ctx.setStrokeColor(lineColor.cgColor)
            _ctx.setLineWidth(lineWidth)
            _ctx.setLineJoin(.round)
            _ctx.setLineCap(.round)
            _ctx.strokePath()
            
            if drawPoint {
                let pt = seriesPath.currentPoint
                _ctx.addEllipse(in: CGRect(x: pt.x - 1, y: pt.y - 1, width: 3, height: 3))
                _ctx.strokePath()
            }
        }
    }
    
    
    
    
    
    
    
    
    
    
    var highlightTiles = false
    var drawGrid = false
    var drawPoint = true
    var lineColor = UIColor(red: 0.12, green: 0.90, blue: 0.36, alpha: 1.00)
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
        let y = _size.height / 2.0 + _baselineAdjustment
        let scale = 0.05
        let left = rect.minX
        let width = rect.width
        let count = CGFloat(series.count)
        var counter = CGFloat(0.0)
        let result = UIBezierPath()
        var first = true
        for value in series {
            counter = counter + 1
            let offset = (counter / count) * width
            let norm = y - CGFloat(value) * scale
            if first {
                result.move(to: CGPoint(x: left + offset, y: norm))
                first = false
            } else {
                result.addLine(to: CGPoint(x: left + offset, y: norm))
            }
        }
        return result
    }
    
}
