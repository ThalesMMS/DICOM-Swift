import Foundation

extension DCMDecoder {
    /// Lazily parses metadata for a DICOM tag, caches a formatted `"description: value"` entry, and returns the cached string.
    ///
    /// Parses the tag using cached metadata and the decoder's reader, stores the resulting formatted string in `dicomInfoDict[tag]`, and returns it. If the tag metadata is missing or the reader is unavailable, no cache entry is created and the function returns `nil`.
    /// - Parameter tag: The numeric DICOM tag key to parse.
    /// - Returns: The cached `"description: value"` string for the tag, or `nil` if metadata or reader is unavailable.
    private func parseTagOnDemand(tag: Int) -> String? {
        // Check if tag exists in lazy metadata cache
        guard let metadata = tagMetadataCache[tag] else {
            return nil
        }

        // Get tag description from dictionary
        var description = dict.value(forTag: tag) ?? "---"

        // For implicit VR, extract VR from description
        if metadata.vr == .implicitRaw {
            if description.count >= 2 {
                description = String(description.dropFirst(2))
            }
        }

        // Read value from file using reader
        guard let reader = reader else {
            return nil
        }

        var value: String?
        var offset = metadata.offset
        let characterSet = activeCharacterSet

        // Read value based on VR type (mirroring headerInfo logic)
        switch metadata.vr {
        case .FD, .FL:
            // Skip numeric values not needed in text form
            break

        case .AE, .AS, .AT, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UI, .UR, .UT:
            value = reader.readString(length: metadata.elementLength, location: &offset, characterSet: characterSet)

        case .US:
            if metadata.elementLength == 2 {
                let s = reader.readShort(location: &offset)
                value = String(s)
            } else {
                // Multiple unsigned shorts separated by spaces
                var vals = [String]()
                let count = metadata.elementLength / 2
                for _ in 0..<count {
                    vals.append(String(reader.readShort(location: &offset)))
                }
                value = vals.joined(separator: " ")
            }

        case .implicitRaw:
            // Interpret as a string unless extremely long
            let s = reader.readString(length: metadata.elementLength, location: &offset, characterSet: characterSet)
            if metadata.elementLength <= 44 {
                value = s
            } else {
                value = nil
            }

        case .SQ:
            // Sequences not fully parsed in lazy mode
            value = ""

        default:
            // Unknown VR: skip
            value = ""
        }

        // Build the formatted string
        let formattedInfo: String
        if let val = value, !val.isEmpty {
            formattedInfo = "\(description): \(val)"
        } else {
            formattedInfo = "\(description): "
        }

        // Store in dicomInfoDict for future access
        dicomInfoDict[tag] = formattedInfo

        return formattedInfo
    }

    /// Collects all DICOM tag keys present in the decoder's cached info or metadata.
    /// - Returns: An array of unique tag keys present in either the cached info dictionary or the tag metadata cache.
    func allTagKeys() -> [Int] {
        synchronized {
            allTagKeysUnsafe()
        }
    }

    /// Collects all tag keys without taking the decoder lock. Callers must already hold the lock.
    private func allTagKeysUnsafe() -> [Int] {
        Array(Set(dicomInfoDict.keys).union(tagMetadataCache.keys))
    }

    /// Capture the decoder's current DICOM data as a Data snapshot while holding the decoder lock.
    /// - Returns: A snapshot (copy) of the decoder's current `dicomData`.
    func dicomDataSnapshot() -> Data {
        synchronized { dicomData }
    }

    /// The current byte count of the decoder's buffered DICOM data.
    /// - Returns: The number of bytes in the decoder's internal DICOM data buffer.
    func dicomDataCount() -> Int {
        synchronized { dicomData.count }
    }

    /// Thread-safe access to the decoder's current little-endian flag.
    /// - Returns: `true` if the decoder is using little-endian byte order, `false` otherwise.
    func currentLittleEndian() -> Bool {
        synchronized { littleEndian }
    }

    /// Provides the current rescale intercept and slope used to convert stored pixel values to real-world values.
    /// - Returns: A tuple `(intercept: Double, slope: Double)` where `intercept` is the rescale intercept and `slope` is the rescale slope.
    func currentRescaleParameters() -> (intercept: Double, slope: Double) {
        synchronized { (rescaleIntercept, rescaleSlope) }
    }

    /// Indicates whether the decoder currently holds any decoded pixel buffer.
    /// - Returns: `true` if any of the 8-bit, 16-bit, or 24-bit pixel buffer storage is present, `false` otherwise.
    func hasDecodedPixelBuffers() -> Bool {
        synchronized {
            pixels8 != nil || pixels16 != nil || pixels24 != nil
        }
    }

    /// Retrieve the stored display value for a DICOM tag, parsing the tag lazily if it has not yet been parsed.
    /// Must be called while holding the decoder's synchronization lock.
    /// - Parameter tag: The integer DICOM tag to retrieve (group/element packed as Int).
    /// - Returns: The tag's value string with any leading description and colon removed and trimmed; an empty string if the tag is missing or has no value.
    func infoUnsafe(for tag: Int) -> String {
        // OPTIMIZATION: Check cache first for frequently accessed tags
        if DCMDecoder.frequentTags.contains(tag), let cached = cachedInfo[tag] {
            return cached
        }

        // Check if tag needs lazy parsing
        if dicomInfoDict[tag] == nil {
            _ = parseTagOnDemand(tag: tag)
        }

        guard let info = dicomInfoDict[tag] else {
            return ""
        }

        // Split on the first colon to remove the VR description
        let result: String
        if let range = info.range(of: ":") {
            result = String(info[range.upperBound...].trimmingCharacters(in: .whitespaces))
        } else {
            result = info
        }

        // Cache frequently accessed tags
        if DCMDecoder.frequentTags.contains(tag) {
            cachedInfo[tag] = result
        }

        return result
    }

    /// Retrieve the stored or lazily parsed value string for the specified DICOM tag.
    /// - Parameter tag: The DICOM tag key as an integer.
    /// - Returns: The tag's value string, or an empty string if the value is missing or unavailable.
    public func info(for tag: Int) -> String {
        return synchronized {
            return infoUnsafe(for: tag)
        }
    }

    /// Retrieves the integer value for a DICOM tag.
    /// - Parameter tag: The DICOM tag identifier.
    /// - Returns: The integer value for the tag, or `nil` if the tag is missing or cannot be parsed as an integer.
    public func intValue(for tag: Int) -> Int? {
        return synchronized {
            let stringValue = infoUnsafe(for: tag)
            return Int(stringValue)
        }
    }

    /// Retrieve the numeric value of a DICOM tag.
    /// - Parameter tag: The DICOM tag key (combined group/element as an `Int`).
    /// - Returns: `Double` if the tag's value parses as a number, `nil` otherwise.
    public func doubleValue(for tag: Int) -> Double? {
        return synchronized {
            let stringValue = infoUnsafe(for: tag)
            return Double(stringValue)
        }
    }

}
