import Foundation
import Flutter
import AVKit
import MediaPlayer
import UIKit

final class AirPlayRoutePickerFactory: NSObject, FlutterPlatformViewFactory {
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
        return AirPlayRoutePickerView(frame: frame)
    }
}

final class AirPlayRoutePickerView: NSObject, FlutterPlatformView {
    private let container = UIView()
    private let routePickerView: AVRoutePickerView = {
        let v = AVRoutePickerView(frame: .zero)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.prioritizesVideoDevices = true
        if #available(iOS 13.0, *) {
            v.activeTintColor = .label
            v.tintColor = .label
        }
        return v
    }()

    override init() {
        super.init()
    }

    init(frame: CGRect) {
        super.init()
        container.frame = frame
        container.backgroundColor = .clear
        container.addSubview(routePickerView)
        NSLayoutConstraint.activate([
            routePickerView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            routePickerView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            routePickerView.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            routePickerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])

        // Upewnij się, że mamy kategorię .playback (często już ustawiana w Flutterze)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("AirPlayRoutePickerView: AVAudioSession setup failed: \(error.localizedDescription)")
        }
    }

    func view() -> UIView { container }
}
