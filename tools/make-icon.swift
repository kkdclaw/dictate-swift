// Иконка Dictate: «голос становится текстом» — белый микрофон и три строки текста на тёплом градиенте.
// swift tools/make-icon.swift <out.png> [размер]  → PNG; Resources/AppIcon.icns собирает tools/make-icon.sh
import AppKit

let out = CommandLine.arguments[1]
let S = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "1024")!)
let k = S / 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// подложка по сетке иконок macOS: 824×824 в центре, скругление 185
let r = CGRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
let shape = CGPath(roundedRect: r, cornerWidth: 185 * k, cornerHeight: 185 * k, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12 * k), blur: 28 * k, color: NSColor.black.withAlphaComponent(0.28).cgColor)
ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(srgbRed: 1.00, green: 0.55, blue: 0.33, alpha: 1).cgColor,
                               NSColor(srgbRed: 0.89, green: 0.20, blue: 0.33, alpha: 1).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
// лёгкий блик сверху
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.midY), options: [])
ctx.restoreGState()

// микрофон — SF Symbol, белый
let cfg = NSImage.SymbolConfiguration(pointSize: 330 * k, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let mic = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let ms = mic.size
    mic.draw(in: CGRect(x: (S - ms.width) / 2, y: 448 * k, width: ms.width, height: ms.height))
}
// три строки текста: голос → текст
ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
let lines: [(CGFloat, CGFloat)] = [(330, 362), (330, 312), (330, 262)]
let widths: [CGFloat] = [364, 300, 196]
for (i, (x, y)) in lines.enumerated() {
    let rr = CGRect(x: x * k, y: y * k, width: widths[i] * k, height: 26 * k)
    ctx.addPath(CGPath(roundedRect: rr, cornerWidth: 13 * k, cornerHeight: 13 * k, transform: nil)); ctx.fillPath()
}
// курсор в конце последней строки
ctx.setFillColor(NSColor.white.cgColor)
ctx.addPath(CGPath(roundedRect: CGRect(x: (330 + 196 + 36) * k, y: 248 * k, width: 14 * k, height: 54 * k),
                   cornerWidth: 7 * k, cornerHeight: 7 * k, transform: nil)); ctx.fillPath()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
