import Foundation
import ImageIO
import CoreGraphics

// Owner-approved deterministic cleanup of the approved 1254px sculpted concept.
// Only trim the external alpha contour; never repaint the pane artwork.
guard CommandLine.arguments.count == 3 else { fatalError("Expected source and destination PNG paths") }
let input=URL(fileURLWithPath:CommandLine.arguments[1])
let output=URL(fileURLWithPath:CommandLine.arguments[2])
guard let source=CGImageSourceCreateWithURL(input as CFURL,nil),
      let image=CGImageSourceCreateImageAtIndex(source,0,nil), image.width==1254,image.height==1254 else { fatalError("Expected the approved 1254px master") }
let width=image.width,height=image.height
let color=image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
var pixels=[UInt8](repeating:0,count:width*height*4)
let bitmapInfo=CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
guard let context=CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:bitmapInfo) else {fatalError("Cannot decode source")}
context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
let original=pixels
// A smooth squircle just inside the original base, excluding the generated halo.
let center=626.5,rx=518.5,ry=512.5,power=4.2
func field(_ x:Double,_ y:Double)->Double {pow(abs((x-center)/rx),power)+pow(abs((y-center)/ry),power)}
var changed=0,preserved=0
for y in 0..<height {for x in 0..<width {
    let index=(y*width+x)*4
    let value=field(Double(x)+0.5,Double(y)+0.5)
    let coverage:Double
    if value<0.98 {coverage=1}
    else if value>1.02 {coverage=0}
    else {
        var inside=0
        for sy in 0..<8 {for sx in 0..<8 {
            if field(Double(x)+(Double(sx)+0.5)/8,Double(y)+(Double(sy)+0.5)/8)<=1 {inside+=1}
        }}
        coverage=Double(inside)/64
    }
    if coverage==1 {preserved+=1;continue}
    for channel in 0..<4 {pixels[index+channel]=UInt8((Double(pixels[index+channel])*coverage).rounded())}
    if pixels[index..<index+4] != original[index..<index+4] {changed+=1}
}}
// Prove all interior bytes were retained before encoding.
for y in 0..<height {for x in 0..<width where field(Double(x)+0.5,Double(y)+0.5)<0.98 {
    let i=(y*width+x)*4
    precondition(pixels[i..<i+4]==original[i..<i+4],"Interior artwork changed")
}}
guard let cleanedContext=CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:bitmapInfo),let result=cleanedContext.makeImage(),let destination=CGImageDestinationCreateWithURL(output as CFURL,"public.png" as CFString,1,nil) else {fatalError("Cannot encode output")}
CGImageDestinationAddImage(destination,result,nil)
guard CGImageDestinationFinalize(destination) else {fatalError("PNG write failed")}
print("Cleaned external contour: \(changed) pixels trimmed; \(preserved) interior pixels retained byte-for-byte before encoding.")
// Decode the saved file independently: catch export-buffer or alpha mistakes.
guard let savedSource=CGImageSourceCreateWithURL(output as CFURL,nil),let savedImage=CGImageSourceCreateImageAtIndex(savedSource,0,nil) else {fatalError("Cannot verify saved PNG")}
var saved=[UInt8](repeating:0,count:pixels.count)
let savedContext=CGContext(data:&saved,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:color,bitmapInfo:bitmapInfo)!
savedContext.draw(savedImage,in:CGRect(x:0,y:0,width:width,height:height))
for y in 0..<height {for x in 0..<width {
    let i=(y*width+x)*4,value=field(Double(x)+0.5,Double(y)+0.5)
    if value>1.02 {precondition(saved[i+3]==0,"Stray external alpha survived export")}
    if value<0.9 && original[i+3]==255 {precondition(saved[i..<i+4]==original[i..<i+4],"Saved interior differs from source")}
}}
print("Saved PNG independently verified: clear exterior and unchanged opaque interior.")
