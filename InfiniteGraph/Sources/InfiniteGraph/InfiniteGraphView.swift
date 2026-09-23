//
//  InfiniteGraphView.swift
//  InfiniteGraph
//
//  Created by Boris Golovnev on 21/5/21.
//

import UIKit
import IRLSize

open class InfiniteGraphView: UIScrollView {
    
    public static var screenMm:CGFloat = {
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return 5
        }
        let screenWidth = max(40.0, CGFloat(UIDevice.current.mainScreenPhysicalSizeMm.width))
        return UIScreen.main.fixedCoordinateSpace.bounds.width / screenWidth
    }()
    
    open var data:InfiniteGraphDataSource? {
        get {renderer.dataSource}
        set {renderer.dataSource = newValue}
    }
    
    open var lineColor:UIColor {
        get {renderer.lineColor}
        set {renderer.lineColor = newValue}
    }
    
    open var lineWidth:CGFloat {
        get {renderer.lineWidth}
        set {renderer.lineWidth = newValue}
    }
    
    
    var renderer = InfiniteGraphRendererView()
    var lastDrawnTimestamp:TimeInterval = 0
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required public init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
    
    open func commonInit() {
        renderer.backgroundColor = UIColor.clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        addSubview(renderer)
    }
    
    open override var contentSize: CGSize {
        didSet {
            (renderer.layer as! CATiledLayer).tileSize = CGSize(width: frame.size.width / 2 * UIScreen.main.scale, height: contentSize.height * UIScreen.main.scale)
            renderer.frame = CGRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height)
        }
    }
    
    open func redrawCurrent() {
        renderer.setNeedsDisplay(self.bounds)
    }
    
    var drawnValues:Int = 0
    open func drawNew() {
        if let data = renderer.dataSource {
            let newNumValues = data.numValues
            if drawnValues == newNumValues { return }
            
            let newDurationPoint = CGFloat(newNumValues) / data.valuesPerPoint
            let oldDurationPoint = CGFloat(drawnValues) / data.valuesPerPoint
            let rectToRedraw = CGRect(x: oldDurationPoint, y: 0, width: newDurationPoint - oldDurationPoint, height: contentSize.height)
            
            renderer.setNeedsDisplay(rectToRedraw)
            drawnValues = newNumValues
        }
    }
    
    open func reset() {
        self.setContentOffset(CGPoint.zero, animated: false)
        renderer.setNeedsDisplay()
    }
    
}
