// Draws the disk-image window's background.
//
// The instructions exist twice on purpose. The `--eula` panel cannot be
// skipped, but it is dismissed in one click and is gone before the window that
// needs it appears; this is the copy that is still on screen while somebody is
// dragging the app across, and still there when they come back because it did
// not open. Neither one on its own is enough.
//
// Run it from the repo root; it writes dmg-background.tiff and cleans up after
// itself. The output is committed, so a build needs neither Swift nor this file.
import AppKit
import Foundation

let W: CGFloat = 700, H: CGFloat = 520

let ink      = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
let muted    = NSColor(srgbRed: 0.42, green: 0.40, blue: 0.37, alpha: 1)
let accent   = NSColor(srgbRed: 0.91, green: 0.71, blue: 0.29, alpha: 1)  // #e8b54a
let paper    = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
let rule     = NSColor(srgbRed: 0.89, green: 0.86, blue: 0.81, alpha: 1)

// AppKit draws from the bottom left; every measurement below is from the top.
func fromTop(_ y: CGFloat) -> CGFloat { H - y }

func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ colour: NSColor,
          x: CGFloat, top: CGFloat, width: CGFloat, align: NSTextAlignment = .left) {
  let para = NSMutableParagraphStyle()
  para.alignment = align
  para.lineSpacing = 3
  let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: size, weight: weight),
    .foregroundColor: colour,
    .paragraphStyle: para,
  ]
  NSAttributedString(string: s, attributes: attrs)
    .draw(in: NSRect(x: x, y: fromTop(top) - size * 3, width: width, height: size * 3))
}

func render(scale: CGFloat, to path: String) {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: W, height: H)

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  paper.setFill()
  NSRect(x: 0, y: 0, width: W, height: H).fill()
  accent.setFill()
  NSRect(x: 0, y: fromTop(5), width: W, height: 5).fill()

  text("Install Mahfin Desktop", 27, .semibold, ink, x: 0, top: 46, width: W, align: .center)
  text("Drag the app onto the Applications folder",
       14, .regular, muted, x: 0, top: 80, width: W, align: .center)

  // The two icons are placed by create-dmg at y=195; this sits between them.
  text("\u{2192}", 40, .thin, rule, x: 300, top: 212, width: 100, align: .center)

  rule.setFill()
  NSRect(x: 64, y: fromTop(300), width: W - 128, height: 1).fill()

  text("It will not open the first time. That is macOS, not a fault.",
       16, .semibold, ink, x: 0, top: 336, width: W, align: .center)

  let steps = [
    "Open it from Applications. macOS says it cannot check the app. Click Done \u{2014} not Move to Trash.",
    "Apple menu \u{203A} System Settings \u{203A} Privacy & Security, scroll to Security, click Open Anyway.",
    "Open the app once more, and click Open Anyway in the dialog.",
  ]
  var top: CGFloat = 372
  for (i, step) in steps.enumerated() {
    text("\(i + 1)", 15, .bold, accent, x: 66, top: top, width: 20)
    text(step, 13, .regular, ink, x: 90, top: top + 1, width: W - 150)
    top += 38
  }

  text("Once only. Every launch after that one opens straight away.",
       12, .regular, muted, x: 0, top: 496, width: W, align: .center)

  NSGraphicsContext.restoreGraphicsState()
  try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: path))
}

// Finder shows a background picture at its natural size rather than scaling it,
// so the 1x image has to match the window exactly. The 2x copy rides along in a
// multi-representation TIFF, which is how the text stays sharp on a retina
// display; tiffutil's -cathidpicheck is what marks the pair as one image at two
// scales instead of two unrelated pages.
let one = "bundle/osx/dmg-background.png", two = "bundle/osx/dmg-background@2x.png"
render(scale: 1, to: one)
render(scale: 2, to: two)

let combine = Process()
combine.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
combine.arguments = ["-cathidpicheck", one, two, "-out", "bundle/osx/dmg-background.tiff"]
try combine.run()
combine.waitUntilExit()
guard combine.terminationStatus == 0 else { exit(combine.terminationStatus) }

for intermediate in [one, two] { try? FileManager.default.removeItem(atPath: intermediate) }
print("wrote bundle/osx/dmg-background.tiff")
