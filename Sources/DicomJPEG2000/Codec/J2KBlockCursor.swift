//
// J2KBlockCursor.swift
// DicomJPEG2000
//

import Synchronization

/// Hands out positions `0..<count` to the code-block decode workers of one tile, each position once (issue #3051).
/// A worker takes the next position as soon as it finishes a block, so a slower core takes fewer blocks.
final class J2KBlockCursor: Sendable {
    private let position = Atomic<Int>(0)
    private let count: Int

    init(count: Int) {
        self.count = count
    }

    /// The next position, or nil once all `count` positions were handed out.
    func next() -> Int? {
        let taken = position.wrappingAdd(1, ordering: .relaxed).oldValue
        return taken < count ? taken : nil
    }
}
