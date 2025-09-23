//
//  Atomic.swift
//  Runner
//
//  Created by Mariusz Smenzyk on 24/09/2025.
//


import Foundation

final class Atomic<T> {
    private let queue = DispatchQueue(label: "atomic.queue", attributes: .concurrent)
    private var _value: T

    init(_ value: T) {
        _value = value
    }

    var value: T {
        get { queue.sync { _value } }
        set { queue.async(flags: .barrier) { self._value = newValue } }
    }
}
