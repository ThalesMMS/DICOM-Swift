//
//  DicomFrameMemoryReservation.swift
//  DicomCore
//
//  An admitted working set. Retain until the worker actually exits, including after cancellation.
//  Output accounting transfers to the returned pixel owner.
//
//  Thales Matheus Mendonça Santos — September 2026
//

/// An admitted working set. Retain until the worker actually exits, including
/// after cancellation. Output accounting transfers to the returned pixel owner.
public protocol DicomFrameMemoryReservation: AnyObject, Sendable {
    func retainOutput(byteCount: Int) throws -> any DicomFrameMemoryOwner
    /// Releases the production worker slot after its physical work drains; retained bytes stay charged.
    func finishOperation()
}
