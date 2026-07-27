//
//  Nvmm
//  NvmmApplication.swift
//
//  Override point for customizing the About panel with the Neovim version.
//

import AppKit

@objc(NvmmApplication)
final class NvmmApplication: NSApplication {

    override func orderFrontStandardAboutPanel(_ sender: Any?) {
        let nvimVersion = Bundle.main.object(
            forInfoDictionaryKey: "NvimVersion") as? String

        orderFrontStandardAboutPanel(
            options: [.credits: Self.aboutCredits(nvimVersion: nvimVersion)])
    }

    /// Builds the standard panel's information area without replacing its
    /// application name, icon, or application and build versions.
    nonisolated static func aboutCredits(
        nvimVersion: String?
    ) -> NSAttributedString {
        // mowglii.com link.
        let mowglii = "mowglii.com"
        let credits = NSMutableAttributedString(string: mowglii)
        let linkRange = NSRange(location: 0, length: credits.length)
        let url = URL(string: "https://mowglii.com")!
        credits.addAttribute(.link, value: url, range: linkRange)

        if let nvimVersion, !nvimVersion.isEmpty {
            credits.insert(
                NSAttributedString(string: nvimVersion + "\n\n"), at: 0)
        }

        // Set small system font and centered text.
        let range = NSRange(location: 0, length: credits.length)
        let fontSize = NSFont.systemFontSize(for: .small)
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        credits.addAttribute(.font, value: font, range: range)
        credits.addAttribute(.paragraphStyle, value: para, range: range)

        return credits
    }
}
