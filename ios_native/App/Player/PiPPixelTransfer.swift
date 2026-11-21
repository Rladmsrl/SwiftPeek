import Accelerate
import CoreVideo
import Foundation

/// CPU-only transfer: iOS may deny application Metal work after backgrounding.
/// Both the VT decoder and AVPlayerItemVideoOutput supply BGRA for this path.
enum PiPPixelTransfer {
    private final class ScratchBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pointer: UnsafeMutableRawPointer?
        private var capacity = 0

        func withBuffer(bytes: Int, _ body: (UnsafeMutableRawPointer?) -> vImage_Error) -> vImage_Error {
            lock.lock()
            defer { lock.unlock() }
            if bytes <= 0 { return body(nil) }
            if bytes > capacity {
                pointer?.deallocate()
                pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
                capacity = bytes
            }
            return body(pointer)
        }

        deinit { pointer?.deallocate() }
    }

    private static let scratch = ScratchBuffer()

    static func copy(_ source: CVPixelBuffer, to destination: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(destination) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let sourceData = CVPixelBufferGetBaseAddress(source),
              let destinationData = CVPixelBufferGetBaseAddress(destination) else { return false }
        var input = vImage_Buffer(data: sourceData, height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                                  width: vImagePixelCount(CVPixelBufferGetWidth(source)), rowBytes: CVPixelBufferGetBytesPerRow(source))
        var output = vImage_Buffer(data: destinationData, height: vImagePixelCount(CVPixelBufferGetHeight(destination)),
                                   width: vImagePixelCount(CVPixelBufferGetWidth(destination)), rowBytes: CVPixelBufferGetBytesPerRow(destination))
        if input.width == output.width, input.height == output.height {
            return vImageCopyBuffer(&input, &output, 4, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        let needed = vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageGetTempBufferSize))
        guard needed >= 0 else { return false }
        // Scaling treats all four channels equally, preserving BGRA ordering.
        return scratch.withBuffer(bytes: Int(needed)) { temp in
            vImageScale_ARGB8888(&input, &output, temp, vImage_Flags(kvImageNoFlags))
        } == kvImageNoError
    }
}
