import Foundation
import AVFoundation
import CoreVideo
let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath:path)
if FileManager.default.fileExists(atPath:path) { print("Sample exists; not overwritten"); exit(0) }
let writer = try AVAssetWriter(outputURL:url,fileType:.mp4)
let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:640,AVVideoHeightKey:360])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:640,kCVPixelBufferHeightKey as String:360])
writer.add(input); writer.startWriting();writer.startSession(atSourceTime:.zero)
for frame in 0..<360 {
 while !input.isReadyForMoreMediaData {Thread.sleep(forTimeInterval:0.005)}
 var buffer:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,640,360,kCVPixelFormatType_32ARGB,nil,&buffer)
 let pixel=buffer!;CVPixelBufferLockBaseAddress(pixel,[])
 let base=CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to:UInt8.self);let stride=CVPixelBufferGetBytesPerRow(pixel)
 for y in 0..<360 {for x in 0..<640 {let i=y*stride+x*4;base[i]=255;base[i+1]=UInt8(frame/2%255);base[i+2]=UInt8(x/3%255);base[i+3]=UInt8(y/2%255)}}
 CVPixelBufferUnlockBaseAddress(pixel,[])
 guard adaptor.append(pixel,withPresentationTime:CMTime(value:Int64(frame),timescale:30)) else {fatalError(writer.error!.localizedDescription)}
}
input.markAsFinished();let semaphore=DispatchSemaphore(value:0);writer.finishWriting {semaphore.signal()};semaphore.wait();guard writer.status == .completed else{fatalError(writer.error!.localizedDescription)};print("Generated 12-second silent H.264 sample: \(path)")
