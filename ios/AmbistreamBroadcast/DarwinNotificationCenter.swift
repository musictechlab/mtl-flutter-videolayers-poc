//
//  DarwinNotificationCenter.swift
//  Runner
//
//  Created by Mariusz Smenzyk on 24/09/2025.
//


import Foundation

class DarwinNotificationCenter {
    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}