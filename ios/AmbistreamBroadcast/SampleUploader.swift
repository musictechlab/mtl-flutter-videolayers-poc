import Foundation
import ReplayKit

class SampleUploader {
    private let connection = SocketConnection()
    private let notif = DarwinNotificationCenter()

    func start() {
        connection.connect()
        notif.post("BroadcastStarted")
    }

    func stop() {
        connection.disconnect()
        notif.post("BroadcastStopped")
    }

    func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        switch type {
        case .video:
            connection.send(sampleBuffer, kind: "video")
        case .audioApp:
            connection.send(sampleBuffer, kind: "audioApp")
        case .audioMic:
            connection.send(sampleBuffer, kind: "audioMic")
        @unknown default:
            break
        }
    }
}
 
