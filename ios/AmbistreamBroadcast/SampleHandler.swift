import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {
    private let uploader = SampleUploader()

    override func broadcastStarted(withSetupInfo setupInfo: [String : NSObject]?) {
        // Called when user starts the broadcast
        uploader.start()
    }

    override func broadcastPaused() {
        // User paused the broadcast
    }

    override func broadcastResumed() {
        // User resumed the broadcast
    }

    override func broadcastFinished() {
        // User stopped the broadcast
        uploader.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        uploader.processSampleBuffer(sampleBuffer, with: sampleBufferType)
    }
}
