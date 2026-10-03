import AppKit
import Foundation

let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
let svg="""
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs><linearGradient id="blue" x1="0" y1="0" x2="0.85" y2="1"><stop stop-color="#69C8FF"/><stop offset="0.52" stop-color="#247BEE"/><stop offset="1" stop-color="#234BCD"/></linearGradient><linearGradient id="glass" x2="0" y2="1"><stop stop-color="white" stop-opacity=".24"/><stop offset="1" stop-color="white" stop-opacity=".06"/></linearGradient></defs>
<rect x="64" y="64" width="896" height="896" rx="202" fill="url(#blue)"/>
<rect x="168" y="200" width="688" height="624" rx="128" fill="url(#glass)" stroke="white" stroke-opacity=".28" stroke-width="4"/>
<path d="M284 322 Q284 306 300 317 L555 498 Q575 512 555 526 L300 707 Q284 718 284 702Z" fill="white"/>
<rect x="612" y="430" width="158" height="40" rx="20" fill="white"/>
<rect x="612" y="554" width="124" height="40" rx="20" fill="white" fill-opacity=".88"/>
</svg>
"""
try Data(svg.utf8).write(to:root.appendingPathComponent("AppIcon.svg"))
func image(_ size:Int)->NSBitmapImageRep {
    let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
    let transform=AffineTransform(scale:CGFloat(size)/1024);(transform as NSAffineTransform).concat()
    // Flip to the editable SVG coordinate system.
    let flip=NSAffineTransform();flip.translateX(by:0,yBy:1024);flip.scaleX(by:1,yBy:-1);flip.concat()
    let bg=NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:202,yRadius:202)
    NSGradient(colorsAndLocations:(NSColor(red:0.41,green:0.78,blue:1,alpha:1),0),(NSColor(red:0.14,green:0.48,blue:0.93,alpha:1),0.52),(NSColor(red:0.14,green:0.29,blue:0.80,alpha:1),1))!.draw(in:bg,angle:65)
    let panel=NSBezierPath(roundedRect:NSRect(x:168,y:200,width:688,height:624),xRadius:128,yRadius:128)
    NSGradient(starting:NSColor.white.withAlphaComponent(0.24),ending:NSColor.white.withAlphaComponent(0.06))!.draw(in:panel,angle:90)
    NSColor.white.withAlphaComponent(0.28).setStroke();panel.lineWidth=4;panel.stroke()
    let play=NSBezierPath();play.move(to:NSPoint(x:284,y:322));play.curve(to:NSPoint(x:300,y:317),controlPoint1:NSPoint(x:284,y:306),controlPoint2:NSPoint(x:290,y:310));play.line(to:NSPoint(x:555,y:498));play.curve(to:NSPoint(x:555,y:526),controlPoint1:NSPoint(x:575,y:510),controlPoint2:NSPoint(x:575,y:514));play.line(to:NSPoint(x:300,y:707));play.curve(to:NSPoint(x:284,y:702),controlPoint1:NSPoint(x:290,y:718),controlPoint2:NSPoint(x:284,y:718));play.close();NSColor.white.setFill();play.fill()
    NSColor.white.setFill();NSBezierPath(roundedRect:NSRect(x:612,y:430,width:158,height:40),xRadius:20,yRadius:20).fill()
    NSColor.white.withAlphaComponent(0.88).setFill();NSBezierPath(roundedRect:NSRect(x:612,y:554,width:124,height:40),xRadius:20,yRadius:20).fill()
    NSGraphicsContext.restoreGraphicsState();return rep
}
let set=root.appendingPathComponent("AppIcon.iconset");try FileManager.default.createDirectory(at:set,withIntermediateDirectories:true)
for point in [16,32,128,256,512] { for scale in [1,2] {
    let data=image(point*scale).representation(using:.png,properties:[:])!
    let name="icon_\(point)x\(point)" + (scale == 2 ? "@2x" : "") + ".png"
    try data.write(to:set.appendingPathComponent(name))
    if point*scale == 1024 { try data.write(to:root.appendingPathComponent("AppIcon-1024.png")) }
} }
