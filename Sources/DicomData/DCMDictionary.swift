//
//  DCMDictionary.swift
//
//  A lightweight wrapper around the property list used to
//  look up human‑readable names for DICOM tags.
//  The Swift 6 port retains the
//  original semantics while embracing Swift idioms such as
//  singletons and generics.
//
//  The dictionary itself is stored in ``DCMDictionary.plist``
//  which must reside in the main bundle.  The keys in that
//  file are hexadecimal strings corresponding to the 32‑bit
//  tag and the values are two character VR codes followed by
//  a textual description.  The caller is responsible for
//  splitting the VR and description when needed.
//
//  Note: this class does not attempt to verify the contents
//  of the plist; if the file is missing or malformed the
//  dictionary will simply be empty.  Accesses to unknown keys
//  return ``nil`` rather than throwing.
//

import Foundation

/// Facade for looking up DICOM tag descriptions from a
/// bundled property list.  Unlike the Objective‑C version,
/// this implementation does not rely on `NSObject` or manual
/// memory management.  Instead, the bundled property lists are
/// loaded once per process and every instance references the same
/// immutable storage.
///
/// **Migration:** This class now supports dependency injection.
/// Use the public initializer to create instances instead of
/// relying on the deprecated singleton.
public final class DCMDictionary: DicomDictionaryProtocol, @unchecked Sendable {
    /// Underlying storage for the tag mappings.  Keys are hex strings
    /// (e.g. ``"00020002"``) and values begin with the two character VR.
    private typealias RawDictionary = [String: String]

    private struct Storage {
        let valuesByKey: RawDictionary
        let valuesByTag: [Int: String]
    }

    private static let sharedStorage: Storage = loadStorage()

    private let storage: Storage
    private let localDefinitions: [Int: DicomDictionaryDefinition]

    private static func loadStorage() -> Storage {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif

        let logger = DicomLogger.make(subsystem: "com.dicomviewer", category: "DCMDictionary")
        #if DEBUG
        logger.debug("Loading shared DCMDictionary resources")
        #endif
        let splitResourceNames = [
            "DCMDictionary-Core",
            "DCMDictionary-Imaging",
            "DCMDictionary-RTAndSpecial"
        ]

        var mergedDictionary: RawDictionary = [:]
        var loadedSplitResources = true
        for resourceName in splitResourceNames {
            guard let url = bundle.url(forResource: resourceName, withExtension: "plist") else {
                loadedSplitResources = false
                break
            }

            do {
                let data = try Data(contentsOf: url)
                let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                guard let partialDictionary = plist as? RawDictionary else {
                    loadedSplitResources = false
                    break
                }
                mergedDictionary.merge(partialDictionary) { _, new in new }
            } catch {
                loadedSplitResources = false
                #if DEBUG
                logger.warning("Error parsing \(resourceName).plist: \(error)")
                #endif
                break
            }
        }

        if loadedSplitResources {
            return Storage(valuesByKey: mergedDictionary, valuesByTag: integerKeyedDictionary(from: mergedDictionary))
        }

        guard let url = bundle.url(forResource: "DCMDictionary", withExtension: "plist") else {
            // If neither the split plists nor the legacy plist can be located we log a warning once.
            #if DEBUG
            logger.warning("DCMDictionary resources not found in bundle")
            #endif
            return Storage(valuesByKey: [:], valuesByTag: [:])
        }
        do {
            let data = try Data(contentsOf: url)
            let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let dictionary = plist as? RawDictionary ?? [:]
            return Storage(valuesByKey: dictionary, valuesByTag: integerKeyedDictionary(from: dictionary))
        } catch {
            // Parsing errors will result in an empty dictionary.  We
            // deliberately avoid throwing here to allow clients to
            // continue operating even if metadata is missing.
            #if DEBUG
            logger.warning("Error parsing DCMDictionary.plist: \(error)")
            #endif
            return Storage(valuesByKey: [:], valuesByTag: [:])
        }
    }

    private static func integerKeyedDictionary(from dictionary: RawDictionary) -> [Int: String] {
        dictionary.reduce(into: [Int: String](minimumCapacity: dictionary.count)) { result, element in
            guard let tag = Int(element.key, radix: 16) else { return }
            result[tag] = element.value
        }
    }

    // MARK: - Initialization

    /// Public initializer for dependency injection.
    /// Creates a new instance sharing the dictionary resources loaded from the bundle.
    public init() {
        storage = Self.sharedStorage
        localDefinitions = [:]
    }

    package init(entries: [String: String]) {
        storage = Storage(valuesByKey: entries, valuesByTag: Self.integerKeyedDictionary(from: entries))
        localDefinitions = [:]
    }

    public enum ExtensionFailure: Error, Equatable, Sendable {
        case invalidTag(Int)
        case shadowsStandard(Int)
    }

    /// Registers unassigned public tags. Private definitions require a creator and
    /// belong in DicomPrivateDictionary, not this tag-only registry.
    public init(extendingWith definitions: [Int: DicomDictionaryDefinition]) throws {
        let standard = DCMDictionary()
        for (tag, definition) in definitions {
            guard (0...Int(UInt32.max)).contains(tag), (tag >> 16).isMultiple(of: 2),
                  tag >> 16 != 0xFFFE, definition.isValid else { throw ExtensionFailure.invalidTag(tag) }
            guard standard.definition(forTag: tag) == nil, standard.value(forTag: tag) == nil else {
                throw ExtensionFailure.shadowsStandard(tag)
            }
        }
        storage = Self.sharedStorage
        localDefinitions = definitions
    }

    public var standardEdition: String? { DicomStandardDictionary.shared.edition }

    public func definition(forTag tag: Int) -> DicomDictionaryDefinition? {
        localDefinitions[tag] ?? DicomStandardDictionary.shared.definition(for: tag)
    }

    // MARK: - DicomDictionaryProtocol Implementation

    /// Returns the raw value associated with the supplied key.  The
    /// caller must split the VR code from the description if
    /// necessary.  Keys are expected to be eight hexadecimal
    /// characters representing the 32‑bit DICOM tag.
    ///
    /// - Parameter key: A hexadecimal string identifying a DICOM tag.
    /// - Returns: The string from the plist if present, otherwise
    ///   `nil`.
    public func value(forKey key: String) -> String? {
        if let value = storage.valuesByKey[key] {
            return value
        }
        guard let tag = Int(key, radix: 16) else {
            return nil
        }
        return value(forTag: tag)
    }

    /// Returns the raw value associated with the supplied integer tag.
    /// This avoids formatting hot parse-loop tags as hex strings.
    public func value(forTag tag: Int) -> String? {
        if let definition = localDefinitions[tag] { return definition.legacyVR.code + definition.name }
        if let value = storage.valuesByTag[tag] {
            return value
        }
        if let definition = DicomStandardDictionary.shared.definition(for: tag) {
            return definition.legacyVR.code + definition.name
        }
        let group = (tag >> 16) & 0xFFFF
        guard group >= 0x6000, group <= 0x601E, group.isMultiple(of: 2) else {
            return nil
        }
        return storage.valuesByTag[0x6000_0000 | (tag & 0xFFFF)]
    }

    /// Returns just the VR code for a given tag
    /// - Parameter key: A hexadecimal string identifying a DICOM tag
    /// - Returns: The VR code (first 2 characters) or nil if not found
    public func vrCode(forKey key: String) -> String? {
        guard let value = value(forKey: key),
              value.count >= 2 else { return nil }
        return String(value.prefix(2))
    }

    /// Returns just the VR code for a given integer tag.
    public func vrCode(forTag tag: Int) -> String? {
        guard let value = value(forTag: tag),
              value.count >= 2 else { return nil }
        return String(value.prefix(2))
    }

    /// Returns just the description for a given tag
    /// - Parameter key: A hexadecimal string identifying a DICOM tag
    /// - Returns: The description (after "XX:") or nil if not found
    public func description(forKey key: String) -> String? {
        guard let value = value(forKey: key),
              !value.isEmpty else { return nil }
        return description(from: value)
    }

    /// Returns just the description for a given integer tag.
    public func description(forTag tag: Int) -> String? {
        guard let value = value(forTag: tag),
              !value.isEmpty else { return nil }
        return description(from: value)
    }

    private func description(from value: String) -> String {
        if let colonIndex = value.firstIndex(of: ":") {
            return String(value[value.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
        } else {
            // Many dictionary entries are stored as "<VR><description>" without a colon separator.
            // Strip the 2-character VR prefix if present; otherwise return the raw string.
            if value.count > 2 {
                return String(value.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else {
                return value
            }
        }
    }

    /// Formats a tag as a standard DICOM tag string
    /// - Parameter tag: The 32-bit tag value
    /// - Returns: Formatted tag string in the format "(XXXX,XXXX)"
    public func formatTag(_ tag: UInt32) -> String {
        let group = (tag >> 16) & 0xFFFF
        let element = tag & 0xFFFF
        return String(format: "(%04X,%04X)", group, element)
    }
}
