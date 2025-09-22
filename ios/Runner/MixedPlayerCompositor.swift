import AVFoundation
import CoreImage
import UIKit

// Musi być zdefiniowane PRZED użyciem w AlphaBlendCompositor
final class MixInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    let backgroundTrackID: CMPersistentTrackID
    let foregroundTrackID: CMPersistentTrackID
    var foregroundOpacity: CGFloat

    init(timeRange: CMTimeRange, bg: CMPersistentTrackID, fg: CMPersistentTrackID, opacity: CGFloat) {
        self.timeRange = timeRange
        self.backgroundTrackID = bg
        self.foregroundTrackID = fg
        self.foregroundOpacity = opacity
        self.requiredSourceTrackIDs = [NSNumber(value: bg), NSNumber(value: fg)]
    }
}

final class AlphaBlendCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "mtl.mixer.render")
    private let ciContext = CIContext()

    // Akceptujemy NV12 z AVAssetReader
    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    ]
    // Renderujemy do BGRA
    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]

    private var renderContext: AVVideoCompositionRenderContext?

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async {
            guard let dst = request.renderContext.newPixelBuffer(),
                  let instr = request.videoCompositionInstruction as? MixInstruction else {
                request.finish(with: NSError(domain: "mtl.mixer", code: -1))
                return
            }

            let bgBuf = request.sourceFrame(byTrackID: instr.backgroundTrackID)
            let fgBuf = request.sourceFrame(byTrackID: instr.foregroundTrackID)

            guard let bg = bgBuf, let fg = fgBuf else {
                if let only = bgBuf ?? fgBuf {
                    request.finish(withComposedVideoFrame: only)
                } else {
                    request.finish(with: NSError(domain: "mtl.mixer", code: -2))
                }
                return
            }

            let bgImg = CIImage(cvPixelBuffer: bg)
            let fgImg = CIImage(cvPixelBuffer: fg)

            let opacity = max(0.0, min(1.0, instr.foregroundOpacity))
            let fgWithAlpha = fgImg.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)
            ])
            let out = fgWithAlpha.composited(over: bgImg)

            self.ciContext.render(out, to: dst)
            request.finish(withComposedVideoFrame: dst)
        }
    }

    func supportsWideColorSourceFrames() -> Bool { false }
}