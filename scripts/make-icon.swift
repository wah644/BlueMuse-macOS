import AppKit
import Foundation
let output = URL(fileURLWithPath:CommandLine.arguments[1])
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
func draw(_ pixels:Int,_ name:String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
    let cg = context.cgContext; let size = CGFloat(pixels)
    cg.scaleBy(x:size/1024,y:size/1024)
    let shape = NSBezierPath(roundedRect:NSRect(x:50,y:50,width:924,height:924),xRadius:210,yRadius:210)
    shape.addClip()
    NSGradient(starting:NSColor(calibratedRed:0.025,green:0.10,blue:0.24,alpha:1),ending:NSColor(calibratedRed:0.07,green:0.32,blue:0.52,alpha:1))!.draw(in:NSRect(x:0,y:0,width:1024,height:1024),angle:40)
    for lane in 0..<3 {
        let line = NSBezierPath(); let mid = 330.0+Double(lane)*180
        for x in stride(from:150.0,through:874.0,by:2.0) {
            let t=(x-150)/724
            let amplitude=70*exp(-pow((t-0.5)*2.3,2))
            let y=mid+sin(t*Double.pi*6+Double(lane)*0.7)*amplitude
            if x==150 { line.move(to:NSPoint(x:x,y:y)) } else { line.line(to:NSPoint(x:x,y:y)) }
        }
        [NSColor.systemCyan,NSColor.white,NSColor.systemMint][lane].setStroke()
        line.lineWidth=20; line.lineCapStyle = .round; line.lineJoinStyle = .round; line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
}
for size in [16,32,128,256,512] { try draw(size,"icon_\(size)x\(size).png"); try draw(size*2,"icon_\(size)x\(size)@2x.png") }
