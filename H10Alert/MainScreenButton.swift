//
//  MainScreenButton.swift
//  H10Alert
//
//  Created by Boris Golovnev on 10/06/2026.
//

import UIKit

class MainScreenButton : UIButton {

    private let cornerRadius:CGFloat = 16
    private var fgColor:UIColor = .black
    private var bgColor:UIColor = .clear
    
    override func awakeFromNib() {
        super.awakeFromNib()
        
        layer.borderWidth = 1.5
        layer.cornerRadius = cornerRadius
        layer.masksToBounds = true
        
        fgColor = tintColor
        bgColor = backgroundColor ?? .clear
        
        titleLabel?.textAlignment = .center
 
        applyColors()
    }

    // Re-resolve the CGColors when light/dark appearance changes — a captured
    // CGColor won't adapt to a dynamic UIColor on its own.
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyColors()
        }
    }
 
    private func applyColors() {
        if traitCollection.userInterfaceStyle == .dark {
            layer.borderColor = bgColor.cgColor
            layer.backgroundColor = fgColor.cgColor
            tintColor = bgColor
        } else {
            layer.borderColor = fgColor.cgColor
            layer.backgroundColor = bgColor.cgColor
            tintColor = fgColor
        }
        
        
    }
    
}
