import Accelerate
import CoreVideo

/// CPU-only transfer: iOS may deny application Metal work after backgrounding.
/// Both the VT decoder and AVPlayerItemVideoOutput supply BGRA for this path.
enum PiPPixelTransfer {
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
        // Scaling treats all four channels equally, preserving BGRA ordering.
        return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
    }
}
