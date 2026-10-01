//
//  DicomJ2KPart2CollectionCache.swift
//  DicomCore
//
//  Frame ↔ component-collection layout of a JPEG 2000 Part 2 Multi-component object (PS3.5 8.2.4: every frame is a
//  component, every fragment holds one collection) and the bounded cache of the last decoded collection, so
//  sequential frame reads of a volume decode each collection once. Issue #2331.
//

import DicomCodecs
import Foundation

/// The decoded components of one collection codestream, as stored-pixel bytes per frame.
struct DicomJ2KDecodedCollection: Sendable {
    let width: Int
    let height: Int
    let bitsPerSample: Int
    let isSigned: Bool
    /// One little-endian stored-pixel buffer per component (8-bit or 16-bit containers).
    let frames: [Data]
}

/// Which fragment (collection) carries each frame of the object.
struct DicomJ2KPart2ObjectLayout: Sendable, Equatable {
    struct Collection: Sendable, Equatable {
        let fragmentIndex: Int
        let firstFrame: Int
        let componentCount: Int
    }

    let collections: [Collection]
    var frameCount: Int { collections.reduce(0) { $0 + $1.componentCount } }

    /// Reads the SIZ component count of every fragment; the declared frame count must equal their sum.
    static func read(fragments: [Data], declaredFrames: Int) throws -> DicomJ2KPart2ObjectLayout {
        var collections: [Collection] = []
        var next = 0
        for (index, fragment) in fragments.enumerated() {
            let inspection: DicomJ2KCodestreamInspector.Inspection
            do { inspection = try DicomJ2KCodestreamInspector.inspect(fragment) } catch {
                throw DicomJ2KPart2LayoutError.invalidCollection(fragmentIndex: index, reason: "\(error)")
            }
            guard inspection.container == nil else {
                throw DicomJ2KPart2LayoutError.invalidCollection(fragmentIndex: index, reason: "fragments carry raw codestreams, not JP2 files")
            }
            collections.append(.init(fragmentIndex: index, firstFrame: next, componentCount: inspection.components.count))
            next += inspection.components.count
        }
        guard next == declaredFrames else {
            throw DicomJ2KPart2LayoutError.frameCountMismatch(declared: declaredFrames, components: next)
        }
        return DicomJ2KPart2ObjectLayout(collections: collections)
    }

    func collection(containing frame: Int) -> (collection: Collection, component: Int)? {
        guard let collection = collections.first(where: { frame >= $0.firstFrame && frame < $0.firstFrame + $0.componentCount }) else {
            return nil
        }
        return (collection, frame - collection.firstFrame)
    }
}

enum DicomJ2KPart2LayoutError: Error, Equatable, LocalizedError {
    case invalidCollection(fragmentIndex: Int, reason: String)
    case frameCountMismatch(declared: Int, components: Int)

    var errorDescription: String? {
        switch self {
        case .invalidCollection(let index, let reason):
            return "component collection \(index) is not a usable JPEG 2000 codestream: \(reason)"
        case .frameCountMismatch(let declared, let components):
            return "Number of Frames declares \(declared) frame(s) but the component collections carry \(components) component(s)"
        }
    }
}

/// Keeps the most recently decoded collection of one object.
final class DicomJ2KPart2CollectionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var layout: DicomJ2KPart2ObjectLayout?
    private var cached: (fragmentIndex: Int, collection: DicomJ2KDecodedCollection)?

    func layout(or read: () throws -> DicomJ2KPart2ObjectLayout) throws -> DicomJ2KPart2ObjectLayout {
        lock.lock()
        if let layout { lock.unlock(); return layout }
        lock.unlock()
        let value = try read()
        lock.lock(); layout = value; lock.unlock()
        return value
    }

    func collection(fragmentIndex: Int) -> DicomJ2KDecodedCollection? {
        lock.lock(); defer { lock.unlock() }
        guard let cached, cached.fragmentIndex == fragmentIndex else { return nil }
        return cached.collection
    }

    func store(_ collection: DicomJ2KDecodedCollection, fragmentIndex: Int) {
        lock.lock(); cached = (fragmentIndex, collection); lock.unlock()
    }
}
