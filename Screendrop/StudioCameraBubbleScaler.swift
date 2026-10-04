import CoreGraphics
import CoreVideo
import Metal
import MetalPerformanceShaders

/// Aspect-fills camera frames into the bubble's pixel box on the GPU. Core
/// Graphics' high-quality resample of a full camera frame was most of an
/// export's CPU time once the screen moved to Metal; Lanczos here matches
/// its quality and leaves the CPU only a 1:1 clipped draw. Used serially.
nonisolated final class StudioCameraBubbleScaler {
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let scaler: MPSImageLanczosScale
    private let output: CVPixelBuffer
    private let colorSpace: CGColorSpace

    init?(size: CGSize, colorSpace: CGColorSpace) {
        let width = Int(size.width)
        let height = Int(size.height)
        var output: CVPixelBuffer?
        var cache: CVMetalTextureCache?
        guard width > 0, height > 0,
              let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache,
              CVPixelBufferCreate(
                  kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                  [
                      kCVPixelBufferMetalCompatibilityKey: true,
                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
                  ] as CFDictionary,
                  &output
              ) == kCVReturnSuccess,
              let output
        else { return nil }
        self.queue = queue
        self.textureCache = cache
        self.scaler = MPSImageLanczosScale(device: device)
        self.output = output
        self.colorSpace = colorSpace
    }

    /// `fillRect` is where the whole camera frame lands, in top-left pixels
    /// relative to the output box; whatever falls outside is cropped.
    /// Returns nil if the frame can't go through Metal.
    func scale(_ camera: CVPixelBuffer, fillRect: CGRect) -> CGImage? {
        guard let source = texture(for: camera, usage: .shaderRead),
              let destination = texture(for: output, usage: .shaderWrite),
              let sourceTexture = CVMetalTextureGetTexture(source),
              let destinationTexture = CVMetalTextureGetTexture(destination),
              let command = queue.makeCommandBuffer()
        else { return nil }
        var transform = MPSScaleTransform(
            scaleX: Double(fillRect.width) / Double(sourceTexture.width),
            scaleY: Double(fillRect.height) / Double(sourceTexture.height),
            translateX: Double(fillRect.minX),
            translateY: Double(fillRect.minY)
        )
        withUnsafePointer(to: &transform) { pointer in
            scaler.scaleTransform = pointer
            scaler.encode(commandBuffer: command, sourceTexture: sourceTexture, destinationTexture: destinationTexture)
            scaler.scaleTransform = nil
        }
        command.commit()
        withExtendedLifetime((source, destination)) { command.waitUntilCompleted() }
        guard command.status == .completed else { return nil }
        return makeImage()
    }

    private func makeImage() -> CGImage? {
        CVPixelBufferLockBaseAddress(output, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(output),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(output),
                height: CVPixelBufferGetHeight(output),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(output),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        // Copies: the output buffer is overwritten by the next camera frame.
        return context.makeImage()
    }

    private func texture(for buffer: CVPixelBuffer, usage: MTLTextureUsage) -> CVMetalTexture? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var texture: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, attributes, .bgra8Unorm,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture
        ) == kCVReturnSuccess else { return nil }
        return texture
    }
}
