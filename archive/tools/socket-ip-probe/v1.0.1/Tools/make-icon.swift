import AppKit
import Foundation

let destination = CommandLine.arguments[1]
var chunks = Data()
func be(_ value:Int) -> Data { var v = UInt32(value).bigEndian; return Data(bytes:&v,count:4) }
for (size,key) in [(16,"icp4"),(32,"icp5"),(64,"icp6"),(128,"ic07"),(256,"ic08"),(512,"ic09"),(1024,"ic10")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
    let s = CGFloat(size)
    NSColor(calibratedRed:0.12,green:0.39,blue:0.32,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:s*0.06,y:s*0.06,width:s*0.88,height:s*0.88),xRadius:s*0.21,yRadius:s*0.21).fill()
    let attributes:[NSAttributedString.Key:Any] = [.font:NSFont.monospacedSystemFont(ofSize:s*0.44,weight:.bold),.foregroundColor:NSColor.white]
    let text = "IP" as NSString; let bounds = text.size(withAttributes:attributes)
    text.draw(at:NSPoint(x:(s-bounds.width)/2,y:(s-bounds.height)/2+s*0.02),withAttributes:attributes)
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using:.png,properties:[:])!
    chunks.append(Data(key.utf8)); chunks.append(be(png.count+8)); chunks.append(png)
}
var out = Data("icns".utf8); out.append(be(chunks.count+8)); out.append(chunks)
try out.write(to:URL(fileURLWithPath:destination))
