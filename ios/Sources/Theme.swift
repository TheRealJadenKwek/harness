import SwiftUI
import UIKit

// Monochromatic palette — neutral greys, no color accent.
extension Color {
    static let appBG        = Color(light: 0xF6F6F5, dark: 0x121212)
    static let appSurface   = Color(light: 0xFFFFFF, dark: 0x1E1E1E)
    static let userBubble   = Color(light: 0xE8E8E6, dark: 0x2B2B2B)
    static let claudeAccent = Color(light: 0x1A1A1A, dark: 0xF0F0F0)  // mono "accent" = ink
    static let appText      = Color(light: 0x161616, dark: 0xF2F2F2)
    static let appSecondary = Color(light: 0x787878, dark: 0x9A9A9A)
    static let appBorder    = Color(light: 0xE2E2E0, dark: 0x333333)
    static let codeBG       = Color(light: 0xECECEA, dark: 0x232323)
}

extension Color {
    init(light: UInt, dark: UInt) {
        self = Color(UIColor { trait in
            UIColor(rgb: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(rgb: UInt) {
        self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255.0,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(rgb & 0xFF) / 255.0,
                  alpha: 1.0)
    }
}
