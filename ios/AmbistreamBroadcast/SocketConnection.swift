//
//  SocketConnection.swift
//  Runner
//
//  Created by Mariusz Smenzyk on 24/09/2025.
//


import Foundation
import ReplayKit

class SocketConnection {
    private var fileHandle: FileHandle?
    private let groupId = "group.com.example.mtlfluttervideolayerspoc"
    private let fileName = "stream.pipe"

    func connect() {
        let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupId)
        guard let url = containerURL?.appendingPathComponent(fileName) else { return }

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    func disconnect() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    func send(_ sampleBuffer: CMSampleBuffer, kind: String) {
        guard let fh = fileHandle else { return }
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: &length, dataPointerOut: &dataPointer)

        if let baseAddress = dataPointer {
            let data = Data(bytes: baseAddress, count: length)
            fh.write(data)
        }
    }
}
