// Generates the video fixture the video-player scenario streams: a 12-second
// 16:9 clip that is a single saturated green frame, small enough (about 17 KB)
// to be committed next to the stubs.
//
//     DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//         xcrun swift UITests/stubs/tools/make_video_fixture.swift \
//         UITests/stubs/fixtures/media/green-16x9-12s.mp4
//
// The shape is the point, not the pixels:
//
//   * H.264 / 480x270 (16:9) / 30 fps / 12 s — a letterbox on EVERY portrait
//     device the suite runs on, which is what the scenario's pixel probe needs
//     (a black band above a green image proves `resizeAspect` is still in
//     force; a filled height would mean the image is being cropped);
//   * one flat colour — a pixel probe on a flat field cannot be fooled by
//     compression noise, and the whole file stays a few kilobytes;
//   * 12 SECONDS, not 3: the scenario asserts the transport's geometry while the
//     page is PLAYING, and a 3 s clip reached `.ended` before those assertions
//     ran — the transport then shows the Replay button and the play/pause row
//     the contract names is gone (measured: `videoPlayerPlayPause` existed=false
//     at t≈56 s of the run);
//   * `shouldOptimizeForNetworkUse` (`moov` before `mdat`) — AVPlayer streams
//     this over HTTP with a Range request for the first two bytes, and a file
//     whose index sits at the end cannot be read that way.
//
// Byte-identical output is not guaranteed (the encoder stamps its own metadata);
// the file is committed because the scenario must run without this script.
//
// Deprecation warnings under a recent macOS SDK (`AVAssetWriter.add(_:)`,
// `startWriting()`, `expectsMediaDataInRealTime`, the pixel-buffer adaptor) are
// expected: this is a one-shot offline generator, not real-time capture, and the
// replacements exist only on newer SDKs than the one the fixture was made with.
import AVFoundation
import CoreVideo
import Foundation

let width = 480
let height = 270
let fps: Int32 = 30
let seconds = 12.0

// 0x00FF00 in 32BGRA: blue, green, red, alpha.
let green: [UInt8] = [0x00, 0xFF, 0x00, 0xFF]

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "green-16x9-3s.mp4")

try? FileManager.default.removeItem(at: output)
try? FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true

let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    // No `AVVideoCompressionPropertiesKey` on purpose. With
    // `AVVideoAverageBitRateKey: 60_000` the encoder PADS the output to the
    // target average bitrate — measured on this host on 2026-10-07: 23 610 bytes
    // (60 kbit/s × 3 s) and 23 785 with a one-keyframe interval, against 4 892
    // bytes for the same frames with the default (content-driven) settings. The
    // committed fixture must stay a few kilobytes, and the content is one flat
    // colour, so the default is both smaller and sufficient.
])
input.expectsMediaDataInRealTime = false

let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ])

guard writer.canAdd(input) else {
    FileHandle.standardError.write(Data("writer refused the video input\n".utf8))
    exit(1)
}
writer.add(input)

guard writer.startWriting() else {
    FileHandle.standardError.write(Data("startWriting failed: \(writer.error as Any)\n".utf8))
    exit(1)
}
writer.startSession(atSourceTime: .zero)

/// Fills `buffer` with the flat green, one row at a time (a byte pattern, so
/// `memset` cannot be used).
func fill(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let line = stride / MemoryLayout<UInt8>.size
    var row = [UInt8](repeating: 0, count: line)
    for pixel in 0..<(line / green.count) {
        for (offset, byte) in green.enumerated() {
            row[pixel * green.count + offset] = byte
        }
    }
    for y in 0..<CVPixelBufferGetHeight(buffer) {
        memcpy(base.advanced(by: y * stride), row, line)
    }
}

let frameCount = Int(seconds * Double(fps))
for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData {
        usleep(2_000)
    }
    guard let pool = adaptor.pixelBufferPool else {
        FileHandle.standardError.write(Data("no pixel buffer pool\n".utf8))
        exit(1)
    }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
          let pixelBuffer = buffer
    else {
        FileHandle.standardError.write(Data("no pixel buffer at frame \(frame)\n".utf8))
        exit(1)
    }
    fill(pixelBuffer)
    guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps))
    else {
        FileHandle.standardError.write(Data("append failed at frame \(frame): \(writer.error as Any)\n".utf8))
        exit(1)
    }
}

input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()

guard writer.status == .completed else {
    FileHandle.standardError.write(Data("finishWriting: \(writer.error as Any)\n".utf8))
    exit(1)
}

// `AVAssetWriter` leaves `<name>.sb-<uuid>` scratch files next to the output
// (measured: three of them, up to 22 KB). They are not the fixture and must not
// land in the repository.
let siblings = (try? FileManager.default.contentsOfDirectory(
    at: output.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
for sibling in siblings where sibling.lastPathComponent.hasPrefix(output.lastPathComponent + ".sb-") {
    try? FileManager.default.removeItem(at: sibling)
}

// Read the file back the way the app will: the scenario's assertions (duration,
// frame size, letterbox) are only meaningful if the fixture really carries them.
let asset = AVURLAsset(url: output)
let duration = (try? await asset.load(.duration).seconds) ?? -1
let track = try await asset.loadTracks(withMediaType: .video).first
let size = (try? await track?.load(.naturalSize)) ?? .zero
let nominal = (try? await track?.load(.nominalFrameRate)) ?? -1
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? -1

// `moov` before `mdat` is what makes the file streamable with a two-byte Range
// probe; a plain byte scan is enough to check the order in a file this size.
let data = (try? Data(contentsOf: output)) ?? Data()
func atomOffset(_ name: String) -> Int? {
    let needle = Array(name.utf8)
    guard data.count > needle.count else { return nil }
    for index in 0..<(data.count - needle.count) {
        if Array(data[index..<(index + needle.count)]) == needle {
            return index
        }
    }
    return nil
}

print("""
    wrote \(output.path)
      bytes     \(bytes ?? -1)
      duration  \(duration)
      size      \(Int(size.width))x\(Int(size.height))
      fps       \(nominal)
      ftyp@\(atomOffset("ftyp") ?? -1) moov@\(atomOffset("moov") ?? -1) mdat@\(atomOffset("mdat") ?? -1)
    """)

let ordered = (atomOffset("moov") ?? .max) < (atomOffset("mdat") ?? .min)
let sharp = abs(duration - seconds) < 0.05
if !(ordered && sharp && bytes > 0 && bytes < 10_000
     && Int(size.width) == width && Int(size.height) == height) {
    FileHandle.standardError.write(Data("fixture does not match the recipe\n".utf8))
    exit(1)
}
