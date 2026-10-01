import Foundation

/// PS3.7 D.3.3.3: zero denotes unlimited; omission denotes (1, 1).
public struct DicomAsynchronousOperationsWindow: Equatable, Sendable {
    public var maximumInvoked: UInt16
    public var maximumPerformed: UInt16

    public init(maximumInvoked: UInt16 = 1, maximumPerformed: UInt16 = 1) {
        self.maximumInvoked = maximumInvoked
        self.maximumPerformed = maximumPerformed
    }

    public func negotiated(with supported: Self) -> Self {
        func limit(_ proposed: UInt16, _ supported: UInt16) -> UInt16 {
            if proposed == 0 { return supported }
            if supported == 0 { return proposed }
            return min(proposed, supported)
        }
        return Self(maximumInvoked: limit(maximumInvoked, supported.maximumInvoked),
                    maximumPerformed: limit(maximumPerformed, supported.maximumPerformed))
    }
}
