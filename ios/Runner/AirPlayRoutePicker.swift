import Foundation
import Flutter
import AVKit
import MediaPlayer
import UIKit

// Fabryka PlatformView
class AirPlayRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect,
                viewIdentifier viewId: Int64,
                arguments args: Any?) -> FlutterPlatformView {
        AirPlayRoutePickerView(frame: frame, viewId: viewId, args: args, messenger: messenger)
    }
}

// Widok z systemowym przyciskiem AirPlay (AVRoutePickerView)
class AirPlayRoutePickerView: NSObject, FlutterPlatformView {
    private let routePickerView: AVRoutePickerView

    init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
        self.routePickerView = AVRoutePickerView(frame: frame)
        super.init()

        if #available(iOS 13.0, *) {
            routePickerView.prioritizesVideoDevices = true
            routePickerView.activeTintColor = .white
            routePickerView.tintColor = .white
        }

        // (opcjonalnie) sesja audio – Flutter też to ustawia
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("AirPlayRoutePickerView: AVAudioSession setup failed: \(error.localizedDescription)")
        }
    }

    func view() -> UIView {
        routePickerView
    }
}
