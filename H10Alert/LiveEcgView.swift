//
//  LiveEcgView.swift
//  H10Alert
//
//  Created by Boris Golovnev on 10/06/2026.
//


import UIKit

class LiveEcgView : UIView
{
    
    let statusLabel = UILabel()
    
    var sampleRate: Double = 130
    var secondsPerScreen: Double = 4
    var minValue: CGFloat = -2
    var maxValue: CGFloat = 2
    var traceColor: UIColor = UIColor(red: 0.22, green: 1.0, blue: 0.22, alpha: 1.0)
    var traceLineWidth: CGFloat = 1.6
    var eraseBandWidth: CGFloat = 44
    var fadeAlpha: CGFloat = 0.22
 
    private let lock = NSLock()
    private var ring: [Float] = []
    private var capacity = 0
    private var head = 0
    private var tail = 0
    private var count = 0
 
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var sampleAccumulator: Double = 0
 
    private var ctx: CGContext?
    private var ctxScale: CGFloat = 1
    private var ctxWidth = 0
    private var ctxHeight = 0
    private var currentX: CGFloat = 0
    private var lastY: CGFloat = 0
    private var penDown = false
 
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
 
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }
 
    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        layer.contentsGravity = .resize
        configureRing()
        addSubview(statusLabel)
    }
 
    private func configureRing() {
        capacity = max(Int(sampleRate * 6), 1024)
        ring = [Float](repeating: 0, count: capacity)
        head = 0
        tail = 0
        count = 0
    }
 
    func append(_ samples: [Float]) {
        guard capacity > 0, !samples.isEmpty else { return }
        lock.lock()
        for s in samples {
            ring[head] = s
            head = (head + 1) % capacity
            if count == capacity {
                tail = (tail + 1) % capacity
            } else {
                count += 1
            }
        }
        lock.unlock()
    }
 
    private func dequeue(_ n: Int) -> [Float] {
        lock.lock()
        let take = min(n, count)
        if take == 0 {
            lock.unlock()
            return []
        }
        var out = [Float](repeating: 0, count: take)
        var idx = tail
        for i in 0..<take {
            out[i] = ring[idx]
            idx = (idx + 1) % capacity
        }
        tail = (tail + take) % capacity
        count -= take
        lock.unlock()
        return out
    }
 
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startLink()
        } else {
            stopLink()
        }
    }
 
    private func startLink() {
        guard displayLink == nil else { return }
        
        let link = CADisplayLink(target: self, selector: #selector(handleTick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastTimestamp = 0
    }
 
    private func stopLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
 
    override func layoutSubviews() {
        super.layoutSubviews()
        rebuildContextIfNeeded()
        statusLabel.frame = CGRect(x: 10, y: -10, width: bounds.width-20, height: 32)
    }
 
    private func rebuildContextIfNeeded() {
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        if ctx != nil, ctxWidth == w, ctxHeight == h, ctxScale == scale {
            return
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let newCtx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return }
        newCtx.scaleBy(x: scale, y: scale)
        newCtx.setLineCap(.round)
        newCtx.setLineJoin(.round)
        ctx = newCtx
        ctxScale = scale
        ctxWidth = w
        ctxHeight = h
        currentX = 0
        lastY = 0
        penDown = false
    }
 
    @objc private func handleTick(_ link: CADisplayLink) {
        guard let ctx = ctx else { return }
        if lastTimestamp == 0 {
            lastTimestamp = link.timestamp
            return
        }
        var dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        guard dt > 0 else { return }
        if dt > 0.1 { dt = 0.1 }
 
        sampleAccumulator += dt * sampleRate
        let n = Int(sampleAccumulator)
        guard n > 0 else { return }
        sampleAccumulator -= Double(n)
 
        let samples = dequeue(n)
        guard !samples.isEmpty else { return }
 
        let h = bounds.height
        let w = bounds.width
        guard w > 0, h > 0 else { return }
 
        let span = CGFloat(secondsPerScreen * sampleRate)
        let stepX = span > 0 ? w / span : 0
        let range = max(maxValue - minValue, 0.0001)
 
        applyEraseBand(ctx, at: currentX, width: eraseBandWidth, w: w, h: h)
 
        ctx.setBlendMode(.normal)
        ctx.setStrokeColor(traceColor.cgColor)
        ctx.setLineWidth(traceLineWidth)
        ctx.beginPath()
        if penDown {
            ctx.move(to: CGPoint(x: currentX, y: lastY))
        }
 
        for s in samples {
            let norm = min(max((CGFloat(s) - minValue) / range, 0), 1)
            let y = norm * h
            var nx = currentX + stepX
            if nx > w {
                nx -= w
                ctx.move(to: CGPoint(x: nx, y: y))
                currentX = nx
                lastY = y
                penDown = true
                applyEraseBand(ctx, at: currentX, width: eraseBandWidth, w: w, h: h)
                ctx.setBlendMode(.normal)
                ctx.setStrokeColor(traceColor.cgColor)
                ctx.setLineWidth(traceLineWidth)
                continue
            }
            if penDown {
                ctx.addLine(to: CGPoint(x: nx, y: y))
            } else {
                ctx.move(to: CGPoint(x: nx, y: y))
                penDown = true
            }
            currentX = nx
            lastY = y
        }
        ctx.strokePath()
 
        guard let image = ctx.makeImage() else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        layer.contentsScale = ctxScale
        CATransaction.commit()
    }
 
    private func applyEraseBand(_ ctx: CGContext, at x: CGFloat, width bandW: CGFloat, w: CGFloat, h: CGFloat) {
        ctx.setBlendMode(.destinationOut)
        ctx.setFillColor(UIColor(white: 0, alpha: fadeAlpha).cgColor)
        let end = x + bandW
        if end <= w {
            ctx.fill(CGRect(x: x, y: 0, width: bandW, height: h))
        } else {
            ctx.fill(CGRect(x: x, y: 0, width: w - x, height: h))
            ctx.fill(CGRect(x: 0, y: 0, width: end - w, height: h))
        }
        ctx.setBlendMode(.normal)
    }
 
    deinit {
        stopLink()
    }
    
}
