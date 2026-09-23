//
//  ECGView.swift
//  H10ECG
//
//  Created by Boris Golovnev on 27/5/21.
//

import UIKit
import InfiniteGraph

class ECGView: InfiniteGraphView, UIScrollViewDelegate {
    
    private var _parameters:UILabel!
    private var _dateOffset:UILabel!
    private var _dl:CADisplayLink!
    private var _fastForward:UIButton!
    private var _dcf = DateComponentsFormatter()
    private var _tap = UITapGestureRecognizer()
    private let _generator = UINotificationFeedbackGenerator()
    
    var autoScroll = false {
        didSet{
            _dl.isPaused = !autoScroll
        }
    }
    
    override var data: InfiniteGraphDataSource? {
        didSet{
            updateStats()
        }
    }
    
    override func commonInit() {
        super.commonInit()
        
        delegate = self
        backgroundColor = UIColor.clear
        lineColor = UIColor.label
        
        _parameters = UILabel()
        _parameters.font = UIFont(name: "Menlo-Bold", size: 14)
        _parameters.text = "25 mm/s, 10 mm/mV, 130.000 Hz"
        _parameters.sizeToFit()
        _parameters.text = ""
        _parameters.textColor = .label
        addSubview(_parameters)
        
        _dateOffset = UILabel.standardLabel(withText: "| 22h 22m 22s ago")
        _dateOffset.text = ""
        addSubview(_dateOffset)
        
        _fastForward = UIButton(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
        _fastForward.setImage(UIImage(systemName: "arrow.forward.circle"), for: .normal)
        _fastForward.setImage(UIImage(systemName: "arrow.backward.circle"), for: .selected)
        _fastForward.isHidden = true
        _fastForward.addTarget(self, action: #selector(scrollToEnd), for: .touchUpInside)
        addSubview(_fastForward)
        
        _tap.addTarget(self, action: #selector(handleGraphTap))
        addGestureRecognizer(_tap)
        
        _dl = CADisplayLink(target: self, selector: #selector(updateAutoScroll))
        _dl.isPaused = !autoScroll
        _dl.add(to: RunLoop.main, forMode: .default)

        _dcf.unitsStyle = .abbreviated
        _dcf.allowedUnits = [.hour, .minute, .second]
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        _parameters.frame = CGRect(x: bounds.origin.x, y: bounds.size.height - _parameters.frame.height - 4,
                                   width: _parameters.frame.width, height: _parameters.frame.height)
        _dateOffset.frame = CGRect(x: bounds.origin.x - 10 + bounds.size.width/2.0, y: bounds.origin.y + 4,
                                   width: _dateOffset.frame.width, height: _dateOffset.frame.height)
        
        
        _fastForward.frame = CGRect(origin: CGPoint(x: bounds.maxX - 44, y: 0), size: _fastForward.frame.size)
    }
    
    override func drawNew() {
        super.drawNew()
        updateStats()
    }
    
    func updateStats() {
        if let data = self.data as? ECGData {
            _parameters.text = String(format: "%d mm/s, %d mm/mV, %.03f Hz", Int(data.mms), Int(data.mmmv), data.samplesPerSecond)
        }
    }
    
    fileprivate var graphEndTargetPoint:CGFloat {
        let visibleRect = bounds
        //70% of screen width from left
        return visibleRect.minX + (visibleRect.maxX - visibleRect.minX) * 0.7
    }
    
    fileprivate var maxTimestampPoint:CGFloat {
        if let data = data as? ECGData {
            if data.numValues == 0 || data.valuesPerPoint == 0 { return 0 }
            return CGFloat(data.numValues) / data.valuesPerPoint
        }
        return 0
    }
    
    var visibleRange:Range<Int> {
        guard let data = data else { return 0..<0 }
        let start = Int(bounds.minX * data.valuesPerPoint)
        let end = Int(bounds.maxX * data.valuesPerPoint)
        return start..<end
    }
    
    func scrollTo(point:CGFloat, relative:Bool = false) {
        if data != nil {
            let pt = relative ? point * maxTimestampPoint : point
            let halfWidth = bounds.size.width * 0.5
            setContentOffset(CGPoint(x: max(0, pt - halfWidth), y: 0), animated: false)
        }
    }
    
    @objc func scrollToEnd() {
        scrollTo(point: maxTimestampPoint)
    }
    
    @objc func handleGraphTap(_ sender:UITapGestureRecognizer) {
        let locationInParameters = sender.location(in: _parameters)
        if _parameters.bounds.insetBy(dx: -20, dy: -20).contains(locationInParameters) {
            if locationInParameters.x < 80 {
                bump()
                let deadlineTime = DispatchTime.now() + .milliseconds(100)
                DispatchQueue.main.asyncAfter(deadline: deadlineTime) {
                    self.cycleMms()
                }
            } else if locationInParameters.x < 170 {
                bump()
                let deadlineTime = DispatchTime.now() + .milliseconds(100)
                DispatchQueue.main.asyncAfter(deadline: deadlineTime) {
                    self.cycleMmmv()
                }
            }
        } else {
            analyze()
        }
    }
    
    func cycleMms() {
        guard let data = data as? ECGData else { return }
        
        if data.mms == 25.0 {
            data.mms = 50.0
        } else if data.mms == 50.0 {
            data.mms = 10.0
        } else {
            data.mms = 25.0
        }
        
        UserDefaults.standard.set(data.mms, forKey: UserDefaults.Keys.lastUsedMMS)
        
        reset()
        updateStats()
        scrollToEnd()
    }
    
    func cycleMmmv() {
        guard let data = data as? ECGData else { return }
        
        if data.mmmv == 10.0 {
            data.mmmv = 25.0
        } else if data.mmmv == 25.0 {
            data.mmmv = 1.0
        } else if data.mmmv == 1.0 {
            data.mmmv = 5.0
        } else {
            data.mmmv = 10.0
        }
        
        UserDefaults.standard.set(data.mmmv, forKey: UserDefaults.Keys.lastUsedMMMV)
        
        reset()
        updateStats()
        scrollToEnd()
    }
    
    func bump() {
        _generator.notificationOccurred(.success)
    }
    
    func analyze() {
        guard let data = data as? ECGData else { return }
        
        let extra = 300
        let range = min(data.numValues, max(0, visibleRange.lowerBound - extra))..<min(data.numValues, visibleRange.upperBound + extra)
        if range.isEmpty { return }
        
        let analyser = ECGAnalyser(with: data, range: range)
        let left = Double(analyser.timeRange.lowerBound) / analyser.valuesPerPoint
        let right = Double(analyser.timeRange.upperBound) / analyser.valuesPerPoint
        let overlayFrame = CGRect(x:left, y:0, width: right-left, height: bounds.maxY)
        let overlay = ECGAnalyserOverlay(frame: overlayFrame, analyzer: analyser, scale: data.valueScale)
        
//        let sampleData = data.getData(range).map { Double($0)/1000.0 }
//        var detector = PanTompkinsQRSDetector(samplingRate: 200.0)
//        let qrsIndices = detector.detectQRS(ecgSignal: sampleData)
//        overlay.addRRsForIndices(qrsIndices)
//        overlay.extraGraphsToDraw.append(detector.lowPassFiltered)
//        overlay.extraGraphsToDraw.append(detector.bandPassFiltered)
//        overlay.extraGraphsToDraw.append(detector.derivative)
//        overlay.extraGraphsToDraw.append(detector.squared)
//        overlay.extraGraphsToDraw.append(detector.integrated)
        
        addSubview(overlay)
        UIView.animate(withDuration: 0.5, delay: 10, options: []) {
            overlay.alpha = 0
        } completion: { _ in
            overlay.removeFromSuperview()
        }
    }
    
    @objc func updateAutoScroll() {
        if UIApplication.shared.applicationState != .active { return }
        if self.isTracking || self.isDecelerating || self.isDragging { return }
        if let data = data as? ECGData {
            if data.numValues == 0 || data.valuesPerPoint == 0 { return }
            
            let difference = maxTimestampPoint - graphEndTargetPoint
            let absDifference = abs(difference)
            if absDifference < 200 {
                let timeDifference = _dl.targetTimestamp - _dl.timestamp
                let pointDifference = CGFloat(timeDifference) * data.pointsPerSecond + difference / 200.0
                
                var co = contentOffset
                co.x += pointDifference
                co.x = max(0, co.x)
                setContentOffset(co, animated: false)
                
                _fastForward.isHidden = true
            } else {
                _fastForward.isHidden = false
                _fastForward.isSelected = difference < 0
            }
        }
    }
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        _dateOffset.text = ""
        
        if let data = data as? ECGData {
            let screenCenter = bounds.midX
            let graphEnd = maxTimestampPoint
            let difference = screenCenter - graphEnd
            let ago = (difference < 0 && data.isLive) ? " ago" : ""
            let differenceSecs = TimeInterval( (data.isLive ? abs(difference) : difference) / data.pointsPerSecond)
            if let differenceString = _dcf.string(from: differenceSecs), abs(differenceSecs) > 2 {
                _dateOffset.text = "| " + differenceString + ago
            }
        }
    }
    
}
