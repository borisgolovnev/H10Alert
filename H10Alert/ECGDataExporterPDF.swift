//
//  ECGDataExporterPDF.swift
//  H10ECG
//
//  Created by Boris Golovnev on 21/09/2022.
//

import UIKit
import CoreGraphics

class ECGDataExporterPDF: ECGDataExporter {
    
    override var filename:String { super.filename + ".pdf" }
    
    var ctx:CGContext!
    
    let PDF_POINT_MM = 0.352777778
    let PDF_MARGIN_MM = 12.0
    let STRIPE_HEIGHT_MM = 40
    let STRIPE_SPACING_MM = 5
    
    let dcf = DateComponentsFormatter()
    
    let attrHeaders: [NSAttributedString.Key : Any] = [.font: UIFont(name: "Menlo-Bold", size: 11)!, .foregroundColor: UIColor.black]
    let attrSubheaders: [NSAttributedString.Key : Any] = [.font: UIFont(name: "Menlo-Bold", size: 9)!, .foregroundColor: UIColor.darkGray]
    let attrInfo: [NSAttributedString.Key : Any] = [.font: UIFont(name: "Menlo-Regular", size: 9)!, .foregroundColor: UIColor.black]
    let attrTimestamps: [NSAttributedString.Key : Any] = [.font: UIFont(name: "Menlo-Regular", size: 8)!, .foregroundColor: UIColor.black]
    let attrRrs: [NSAttributedString.Key : Any] = [.font: UIFont(name: "Menlo-Regular", size: 7)!, .foregroundColor: UIColor.gray]
    
    var contentRect = CGRect.zero
    var paperRect = CGRect.zero
    var samplesPerStripe = 0
    var trailingSamplesPerStripe = 0
    var totalSamplesPerStripe = 0
    var stripesPerPage = 0
    
    var numPages = 0
    var pagesWritten = 0
    var samplesWritten = 0
    
    var strHeader1:NSMutableAttributedString!
    var strHeader2:NSMutableAttributedString!
    var strHeader3:NSMutableAttributedString!
    var strHeader4:NSMutableAttributedString!
    var strHeader5:NSMutableAttributedString!
    var strHeader6:NSMutableAttributedString!
    
    var notes = [Int:NSMutableAttributedString]()
    
    override init(data: ECGData) {
        super.init(data: data)
        
        dcf.allowedUnits = [.hour, .minute, .second]
        
        let bestPaper = UIPrintPaper.bestPaper(forPageSize: CGSize.zero, withPapersFrom: [])
        paperRect = CGRect(x: 0, y: 0, width: bestPaper.paperSize.height, height: bestPaper.paperSize.width)
        contentRect = CGRect(x:PDF_MARGIN_MM, y:PDF_MARGIN_MM,
                             width: paperRect.width * PDF_POINT_MM - 2.0 * PDF_MARGIN_MM,
                             height: paperRect.height * PDF_POINT_MM - 2.0 * PDF_MARGIN_MM)
        let evenWidth = floor(contentRect.width / 10.0) * 10.0 + PDF_POINT_MM / 4.0
        contentRect.origin.x = PDF_MARGIN_MM + (contentRect.width - evenWidth) / 2.0
        contentRect.size.width = evenWidth
        
        let samplesPerMm = data.samplesPerSecond / data.mms
        let timeScale = data.mms / 25.0
        let maxStripeDuration = 10.001 / timeScale
        let maxSamplesPerOneStripe = Int(maxStripeDuration * data.samplesPerSecond)
        totalSamplesPerStripe = Int(contentRect.width * samplesPerMm)
        if totalSamplesPerStripe > maxSamplesPerOneStripe {
            trailingSamplesPerStripe = totalSamplesPerStripe - maxSamplesPerOneStripe
            samplesPerStripe = maxSamplesPerOneStripe
        } else {
            samplesPerStripe = totalSamplesPerStripe
        }
        stripesPerPage = Int(contentRect.height) / (STRIPE_HEIGHT_MM + STRIPE_SPACING_MM)
    }
    
    override func updateParams() {
        super.updateParams()
        
        let samplesPerPage = samplesPerStripe * stripesPerPage
        let samplesPerFirstPage = samplesPerStripe * (stripesPerPage - 1)
        
        var sampleCount = range.count - samplesPerFirstPage
        numPages = 1
        while sampleCount > 0 {
            numPages += 1
            sampleCount -= samplesPerPage
        }
        
        let recordingDate = ECGDataExporter.df.string(from: date)
        let durationSeconds = round(CGFloat(range.count) / data.samplesPerSecond)
        let durationString = dcf.string(from:durationSeconds) ?? "0"
        var numPages = String(numPages) + (numPages > 1 ? " pages" : " page")
        exportInfo = numPages
        
        if let analysis = analysis {
            var numRRs = analysis.waves.filter{$0.type == .r}.count
            if numRRs > 0 { numRRs -= 1 }
            numPages.append(" ")
            numPages.append(String(numRRs))
            numPages.append((numRRs > 1 ? " RR intervals" : " RR interval"))
        }
        
        dcf.unitsStyle = .full
        
        strHeader1 = NSMutableAttributedString(string: "ECG recording from Polar H10 fitness tracker", attributes: attrHeaders)
        strHeader2 = NSMutableAttributedString(string: UIApplication.appString(), attributes: attrSubheaders)
        strHeader3 = NSMutableAttributedString(string: "Starts on: " + recordingDate + "\n", attributes: attrInfo)
        strHeader4 = NSMutableAttributedString(string: String(format: "Duration: %@", durationString), attributes: attrInfo)
        strHeader5 = NSMutableAttributedString(string: String(format: "%d mm/s, %d mm/mV, %.03f Hz", Int(data.mms), Int(data.mmmv), data.samplesPerSecond), attributes: attrInfo)
        strHeader6 = NSMutableAttributedString(string: numPages, attributes: attrInfo)
        
        dcf.unitsStyle = .abbreviated
        
        notes.removeAll()
        for (noteTimestamp, noteString) in data.notes {
            let sampleNumber = data.getSampleNumberAt(timestamp:noteTimestamp)
            if range.contains(sampleNumber) {
                notes[sampleNumber - range.startIndex] = NSMutableAttributedString(string:"*" + noteString, attributes:attrTimestamps)
            }
        }
    }
    
    override func doExport() {
        super.doExport()
        guard let outputURL else {return}
        
        samplesWritten = 0
        pagesWritten = 0
        
        ctx = CGContext(outputURL as CFURL, mediaBox: &paperRect, nil)
        if notesOnly {
            var prevTimestamp = -100
            for ts in notes.keys.sorted() {
                if ts - prevTimestamp < samplesPerStripe { continue }
                _ = addPage(aroundSample: ts)
                prevTimestamp = ts;
            }
        } else {
            while addPage() {}
        }
        ctx.closePDF()
        
        if !notesOnly {
            assert(numPages == pagesWritten)
        }
        delegate?.dataExporterDidFinish(dataUrl: outputURL)
    }
    
    func addPage(aroundSample:Int = -1) -> Bool {
        let margin = PDF_MARGIN_MM / PDF_POINT_MM
        let stripeWithMargin = CGFloat(STRIPE_HEIGHT_MM + STRIPE_SPACING_MM)
        ctx.beginPDFPage(nil)
        ctx.translateBy(x: margin, y: margin)
        
        let firstPage = pagesWritten == 0
        if firstPage {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: contentRect.height / PDF_POINT_MM - PDF_MARGIN_MM / PDF_POINT_MM) //topLeft
            ctx.textPosition = CGPoint(x: 0, y: 0)
            CTLineDraw(CTLineCreateWithAttributedString(strHeader1), ctx)
            ctx.textPosition = CGPoint(x: 0, y: -13)
            CTLineDraw(CTLineCreateWithAttributedString(strHeader2), ctx)
            ctx.textPosition = CGPoint(x: 0, y: -30)
            CTLineDraw(CTLineCreateWithAttributedString(strHeader3), ctx)
            ctx.textPosition = CGPoint(x: 0, y: -42)
            CTLineDraw(CTLineCreateWithAttributedString(strHeader4), ctx)
            ctx.textPosition = CGPoint(x: 0, y: -54)
            CTLineDraw(CTLineCreateWithAttributedString(strHeader5), ctx)
            if !notesOnly {
                ctx.textPosition = CGPoint(x: 0, y: -72)
                CTLineDraw(CTLineCreateWithAttributedString(strHeader6), ctx)
            }
            ctx.restoreGState()
        }
        
        for i in (firstPage ? 1 : 0)..<stripesPerPage {
            let lineTop = CGFloat(stripesPerPage - i) * stripeWithMargin
            ctx.saveGState()
            ctx.translateBy(x: 0, y: lineTop / PDF_POINT_MM)
            ctx.scaleBy(x: 1.0, y: -1.0)
            var stripeStart = samplesWritten
            var stripeEnd = samplesWritten + samplesPerStripe
            if (aroundSample >= 0) {
                let threeStripes = 3 * samplesPerStripe;
                var pageStart = aroundSample - threeStripes / 2 // - Int((0.2 * Double(samplesPerStripe)))
                pageStart -= samplesPerStripe // we want the poi to be in the middle of third stripe of 4
                pageStart = max(0, pageStart)
                stripeStart = pageStart + i * samplesPerStripe
                stripeEnd = stripeStart + samplesPerStripe
                print(stripeStart, stripeEnd)
            }
            
            var allDone = false
            if stripeEnd >= dataSlice.count {
                stripeEnd = dataSlice.count - 1
                allDone = true
            }
            let realWidth = drawStripe(from: stripeStart, to: stripeEnd)
            samplesWritten = stripeEnd
            ctx.restoreGState()
            
            let showHr = UserDefaults.standard.bool(forKey: UserDefaults.Keys.showHR)
            let showRr = UserDefaults.standard.bool(forKey: UserDefaults.Keys.showRR)
            
            if showHr || showRr {
                if let analysis = analysis {
                    let RsThisStripe = analysis.waves.filter{$0.type == .r && $0.globalOffset >= stripeStart && $0.globalOffset < stripeEnd}
                    if RsThisStripe.count > 1 {
                        for i in 1..<RsThisStripe.count {
                            let RRsamples = RsThisStripe[i].globalOffset - RsThisStripe[i - 1].globalOffset
                            let RRms = Int((Double(RRsamples) / data.samplesPerSecond) * 1000)
                            let HR = Int(60000.0 / Double(RRms))
                            let sampleOffset = (RsThisStripe[i - 1].globalOffset + RsThisStripe[i].globalOffset)/2
                            let labelString = NSMutableAttributedString(string:"\(showHr ? HR : RRms)", attributes:attrRrs)
                            
                            let labelRelativePos = Double(sampleOffset - stripeStart) / Double(stripeEnd - stripeStart)
                            let textLine = CTLineCreateWithAttributedString(labelString)
                            let lineOffset = realWidth * labelRelativePos
                            
                            ctx.saveGState()
                            ctx.translateBy(x: lineOffset, y: lineTop / PDF_POINT_MM - 20)
                            ctx.textPosition = CGPoint(x: -4, y: 0)
                            CTLineDraw(textLine, ctx)
                            ctx.restoreGState()
                        }
                    }
                }
            }
            
            
            if withNotes {
                let notesThisStripe = notes.filter{ key, value in key >= stripeStart && key < stripeEnd }
                for (noteSample, noteText) in notesThisStripe {
                    let noteRelativePos = Double(noteSample - stripeStart) / Double(stripeEnd - stripeStart)
                    let textLine = CTLineCreateWithAttributedString(noteText)
                    let lineWidth = CTLineGetBoundsWithOptions(textLine, .excludeTypographicLeading).width
                    var lineOffset = realWidth * noteRelativePos
                    let lineRight = lineOffset + lineWidth
                    if lineRight > realWidth {
                        lineOffset -= lineRight - realWidth
                    }
                    
                    ctx.saveGState()
                    ctx.translateBy(x: lineOffset, y: lineTop / PDF_POINT_MM - 10)
                    ctx.textPosition = CGPoint(x: 0, y: 2)
                    CTLineDraw(textLine, ctx)
                    ctx.restoreGState()
                }
            }
            
            if withTimestamps {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: lineTop / PDF_POINT_MM)
                ctx.textPosition = CGPoint(x: 0, y: 2)
                
                let stripeStartDate = date.addingTimeInterval(Double(stripeStart) / data.samplesPerSecond)
                let stripeTime = ECGDataExporter.df.string(from: stripeStartDate)
                let ts = NSMutableAttributedString(string: stripeTime, attributes: attrTimestamps)
                CTLineDraw(CTLineCreateWithAttributedString(ts), ctx)
                ctx.restoreGState()
            }
            
            if allDone { break }
        }
        
        ctx.endPDFPage()
        pagesWritten += 1
        
        let progress = Double(samplesWritten) / Double(range.count - 1)
        delegate?.dataExporterIsExporting(progress: progress)
        
        return samplesWritten < (dataSlice.count - 1) //skipping up to 500 samples at the end
    }
    
    func drawStripe(from:Int, to:Int) -> Double {
        
        let mmInPoints = 1.0 / PDF_POINT_MM
        let stripeRect = CGRect(x: 0, y: 0,
                                width: contentRect.width / PDF_POINT_MM,
                                height: CGFloat(STRIPE_HEIGHT_MM) / PDF_POINT_MM + PDF_POINT_MM / 4.0)
        
        //grid
        let mmPath = gridPathForScaleUnit(unit: mmInPoints, inRect: stripeRect)
        ctx.addPath(mmPath.cgPath)
        ctx.setLineWidth(0.25)
        ctx.setStrokeColor(UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.25).cgColor)
        ctx.strokePath()

        let fivemmPath = gridPathForScaleUnit(unit: 5 * mmInPoints, inRect: stripeRect)
        ctx.addPath(fivemmPath.cgPath)
        ctx.setLineWidth(0.5)
        ctx.setStrokeColor(UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.5).cgColor)
        ctx.strokePath()
        
        let cmPath = gridPathForScaleUnit(unit: 10 * mmInPoints, inRect: stripeRect)
        ctx.addPath(cmPath.cgPath)
        ctx.setStrokeColor(UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 1.0).cgColor)
        ctx.strokePath()
        
        var result = 0.0
        
        //graph
        let values = data.getData(from: from + range.lowerBound, to: to + range.lowerBound)
        let trailingValues = data.getData(from: to + range.lowerBound, to: min(range.upperBound, to + range.lowerBound + trailingSamplesPerStripe))
        if values.count > 0 {
            var clippedRect = stripeRect
            if values.count < totalSamplesPerStripe {
                clippedRect.size.width *= Double(values.count) / Double(totalSamplesPerStripe)
            }
            result = clippedRect.size.width
            
            ctx.clip(to: [stripeRect])
            
            let seriesPath = pathForSeries(series: values, inRect: clippedRect)
            ctx.addPath(seriesPath.cgPath)
            ctx.setStrokeColor(lineColor.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.strokePath()
            
            if trailingValues.count > 0 {
                var trailingRect = stripeRect
                trailingRect.size.width *= Double(trailingValues.count) / Double(totalSamplesPerStripe)
                trailingRect.origin.x = clippedRect.maxX
                
                let trailingSeriesPath = pathForSeries(series: trailingValues, inRect: trailingRect)
                ctx.addPath(trailingSeriesPath.cgPath)
                ctx.setStrokeColor(trailingLineColor.cgColor)
                ctx.strokePath()
            }
        }
        return result
    }
    
    
    
    
    
    
    
    
    
    
    var highlightTiles = false
    var drawGrid = true
    var lineColor = UIColor.black
    var trailingLineColor = UIColor.lightGray
    var lineWidth = CGFloat(0.75)
    
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
        let y = (CGFloat(STRIPE_HEIGHT_MM) / 2.0) / PDF_POINT_MM
        let scale = (1.0 / PDF_POINT_MM) * data.mmmv / 1000.0
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
