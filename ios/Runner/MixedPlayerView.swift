import Foundation
import Flutter
import AVFoundation
import AVKit
import UIKit

// === Factory ===
final class MTLMixedFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: (FlutterBinaryMessenger & NSObjectProtocol)

    init(binaryMessenger: (FlutterBinaryMessenger & NSObjectProtocol)) {
        self.messenger = binaryMessenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        let v = MTLMixedPlatformView()
        v.bootstrap(frame: frame, viewId: viewId, messenger: messenger, arguments: args)
        return v
    }
}

// === PlatformView ===
final class MTLMixedPlatformView: NSObject, FlutterPlatformView {
    private let container = UIView()
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var mixInstruction: MixInstruction?
    private var videoComposition: AVMutableVideoComposition?

    override init() {
        super.init()
        container.backgroundColor = .black
    }

    func bootstrap(frame: CGRect,
                   viewId: Int64,
                   messenger: (FlutterBinaryMessenger & NSObjectProtocol),
                   arguments: Any?) {
        container.frame = frame

        let channel = FlutterMethodChannel(
            name: "mtl.mixedplayer/\(viewId)",
            binaryMessenger: messenger,
            codec: FlutterStandardMethodCodec.sharedInstance()
        )

        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "dealloc", message: nil, details: nil))
                return
            }
            switch call.method {
            case "load":
                guard let a = call.arguments as? [String: Any],
                      let base = a["baseUrl"] as? String,
                      let overlay = a["overlayUrl"] as? String
                else {
                    result(FlutterError(code: "args", message: "baseUrl/overlayUrl required", details: nil))
                    return
                }
                let extra = (a["extraAudioUrl"] as? String).flatMap(URL.init(string:))
                let opacity = (a["overlayOpacity"] as? Double).map(CGFloat.init) ?? 0.7
                do {
                    try self.load(baseURL: URL(string: base)!,
                                  overlayURL: URL(string: overlay)!,
                                  extraAudioURL: extra,
                                  opacity: opacity)
                    result(nil)
                } catch {
                    result(FlutterError(code: "load", message: error.localizedDescription, details: nil))
                }

            case "play":
                self.player?.play(); result(nil)

            case "pause":
                self.player?.pause(); result(nil)

            case "seek":
                if let ms = (call.arguments as? [String: Any])?["ms"] as? Int {
                    let t = CMTime(milliseconds: ms)
                    self.player?.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                result(nil)

            case "setOpacity":
                if let v = (call.arguments as? [String: Any])?["value"] as? Double {
                    self.mixInstruction?.foregroundOpacity = CGFloat(max(0.0, min(1.0, v)))
                    if let item = self.player?.currentItem {
                        item.videoComposition = self.videoComposition // odśwież
                    }
                }
                result(nil)

            case "dispose":
                self.teardown(); result(nil)

            default:
                result(FlutterMethodNotImplemented)
            }
        }

        // Audio session
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { NSLog("AVAudioSession error: \(error.localizedDescription)") }
    }

    func view() -> UIView { container }

    private func teardown() {
        player?.pause()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
        videoComposition = nil
        mixInstruction = nil
    }

    private func load(baseURL: URL, overlayURL: URL, extraAudioURL: URL?, opacity: CGFloat) throws {
        teardown()

        let assetBG = AVURLAsset(url: baseURL)
        let assetFG = AVURLAsset(url: overlayURL)

        let comp = AVMutableComposition()

        // VIDEO
        guard
            let bgTrack = assetBG.tracks(withMediaType: .video).first,
            let fgTrack = assetFG.tracks(withMediaType: .video).first,
            let compBG = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let compFG = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw NSError(domain: "mtl.mixer", code: 100) }

        let dur = min(assetBG.duration, assetFG.duration)
        try compBG.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: bgTrack, at: .zero)
        try compFG.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: fgTrack, at: .zero)

        // AUDIO
        let audioMix = AVMutableAudioMix()
        var params: [AVMutableAudioMixInputParameters] = []

        if let aBG = assetBG.tracks(withMediaType: .audio).first,
           let compABG = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compABG.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aBG, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: compABG); p.setVolume(1.0, at: .zero)
            params.append(p)
        }
        if let aFG = assetFG.tracks(withMediaType: .audio).first,
           let compAFG = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try compAFG.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: aFG, at: .zero)
            let p = AVMutableAudioMixInputParameters(track: compAFG); p.setVolume(0.0, at: .zero)
            params.append(p)
        }
        if let extra = extraAudioURL {
            let aAsset = AVURLAsset(url: extra)
            if let aT = aAsset.tracks(withMediaType: .audio).first,
               let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try compA.insertTimeRange(CMTimeRange(start: .zero, duration: min(dur, aAsset.duration)), of: aT, at: .zero)
                let p = AVMutableAudioMixInputParameters(track: compA); p.setVolume(1.0, at: .zero)
                params.append(p)
            }
        }
        audioMix.inputParameters = params

        // VIDEO composition
        let vcomp = AVMutableVideoComposition()
        vcomp.customVideoCompositorClass = AlphaBlendCompositor.self
        vcomp.renderSize = bgTrack.naturalSize
        let fps = max(1.0, Double(bgTrack.nominalFrameRate == 0 ? 30 : bgTrack.nominalFrameRate))
        vcomp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))

        let instr = MixInstruction(timeRange: CMTimeRange(start: .zero, duration: dur),
                                   bg: compBG.trackID, fg: compFG.trackID, opacity: opacity)
        vcomp.instructions = [instr]

        let item = AVPlayerItem(asset: comp)
        item.videoComposition = vcomp
        item.audioMix = audioMix

        let pl = AVPlayer(playerItem: item)
        pl.automaticallyWaitsToMinimizeStalling = true

        let layer = AVPlayerLayer(player: pl)
        layer.videoGravity = .resizeAspect
        layer.frame = container.bounds
        container.layer.addSublayer(layer)

        // keep refs
        self.player = pl
        self.playerLayer = layer
        self.videoComposition = vcomp
        self.mixInstruction = instr

        // layout
        container.layer.setNeedsLayout()
        container.layoutIfNeeded()
    }

    deinit { teardown() }
}

fileprivate extension CMTime {
    init(milliseconds: Int) { self.init(value: CMTimeValue(milliseconds), timescale: 1000) }
}