//
// J2KPart1Conformance.swift
// J2KSwift
//
/// # JPEG 2000 Part 1 Conformance Hardening
///
/// Week 256–258 deliverable: ISO/IEC 15444-1 (Part 1 Core) conformance hardening.
///
/// Provides marker-segment validation, codestream syntax checking, numerical
/// precision verification, and a complete Part 1 conformance test suite aligned
/// with the requirements of ISO/IEC 15444-4 (Conformance Testing).
///
/// ## Topics
///
/// ### Conformance Classes
/// - ``J2KDecoderConformanceClass``
///
/// ### Validators
/// - ``J2KMarkerSegmentValidator``
/// - ``J2KCodestreamSyntaxValidator``
/// - ``J2KNumericalPrecisionValidator``
///
/// ### Test Suite
/// - ``J2KPart1ConformanceTestSuite``

import Foundation

// MARK: - Decoder Conformance Class

/// Decoder conformance classes as defined in ISO/IEC 15444-4.
///
/// These classes describe the minimum capability a decoder must possess in order
/// to claim conformance with a given subset of ISO/IEC 15444-1 (JPEG 2000 Part 1).
public enum J2KDecoderConformanceClass: String, Sendable, CaseIterable {
    /// Class-0 – Baseline decoder.
    ///
    /// Supports single-tile, lossless, reversible (5/3) wavelet codestreams only.
    /// This is the minimum required capability for any Part 1 conformant decoder.
    case class0 = "Class-0"

    /// Class-1 – Full Part 1 decoder.
    ///
    /// Supports multi-tile codestreams, lossy compression, and the irreversible (9/7)
    /// wavelet transform in addition to all Class-0 capabilities.
    case class1 = "Class-1"
}

// MARK: - Marker Segment Validator

/// Validates individual JPEG 2000 marker segments for ISO/IEC 15444-1 compliance.
///
/// Each `validate*` method inspects the raw byte content of the supplied `Data`
/// buffer and returns a ``J2KMarkerSegmentValidator/MarkerValidationResult``
/// describing any detected conformance issues.
///
/// All methods are pure functions and are safe to call from any concurrency domain.
public struct J2KMarkerSegmentValidator: Sendable {

    // MARK: Severity

    /// Indicates the significance of a validation finding.
    public enum ValidationSeverity: Sendable {
        /// A mandatory requirement of the standard is violated; the codestream is non-conformant.
        case error
        /// A recommendation is not followed; the codestream may still be decodable.
        case warning
        /// An informational observation that does not affect conformance.
        case info
    }

    // MARK: Issue

    /// A single conformance issue found during validation.
    public struct ValidationIssue: Sendable {
        /// Severity of this issue.
        public let severity: ValidationSeverity
        /// The marker code associated with this issue (e.g. `0xFF4F` for SOC).
        public let marker: UInt16
        /// Human-readable description of the issue.
        public let message: String
        /// Byte offset within the codestream where the issue was detected, or `-1` if not applicable.
        public let byteOffset: Int

        /// Creates a new validation issue.
        public init(
            severity: ValidationSeverity,
            marker: UInt16,
            message: String,
            byteOffset: Int
        ) {
            self.severity = severity
            self.marker = marker
            self.message = message
            self.byteOffset = byteOffset
        }
    }

    // MARK: Result

    /// The result of validating one or more marker segments.
    public struct MarkerValidationResult: Sendable {
        /// `true` when no errors were found; warnings and info findings are permitted.
        public let isCompliant: Bool
        /// All issues discovered during validation.
        public let issues: [ValidationIssue]

        /// Number of error-severity issues.
        public var errorCount: Int {
            issues.filter { $0.severity == .error }.count
        }

        /// Number of warning-severity issues.
        public var warningCount: Int {
            issues.filter { $0.severity == .warning }.count
        }

        /// Creates a new validation result.
        public init(isCompliant: Bool, issues: [ValidationIssue]) {
            self.isCompliant = isCompliant
            self.issues = issues
        }
    }

    // MARK: SOC Validation

    /// Validates that the codestream begins with the SOC marker (0xFF4F).
    ///
    /// Per ISO/IEC 15444-1 §A.4.1, the SOC marker shall be the first two bytes of
    /// every conformant JPEG 2000 codestream.
    ///
    /// - Parameter data: The raw codestream bytes.
    /// - Returns: A ``MarkerValidationResult`` indicating whether the SOC is present and correctly positioned.
    public static func validateSOC(_ data: Data) -> MarkerValidationResult {
        var issues: [ValidationIssue] = []

        guard data.count >= 2 else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF4F,
                message: "Codestream is too short to contain SOC marker (need ≥ 2 bytes, got \(data.count)).",
                byteOffset: 0
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        if data[0] != 0xFF || data[1] != 0x4F {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF4F,
                message: "SOC marker (0xFF4F) not found at byte offset 0; "
                    + "found 0x\(String(format: "%02X%02X", data[0], data[1])) instead.",
                byteOffset: 0
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        return MarkerValidationResult(isCompliant: true, issues: [])
    }

    // MARK: SIZ Validation

    /// Validates the SIZ marker segment (0xFF51) for ISO/IEC 15444-1 §A.5.1 compliance.
    ///
    /// Checks that:
    /// - The marker code is 0xFF51.
    /// - The segment length `Lsiz` is at least 41 bytes (the fixed-length portion).
    /// - `Rsiz` is a recognised profile value.
    /// - `Csiz` (component count) is at least 1.
    ///
    /// - Parameters:
    ///   - data: The raw codestream bytes.
    ///   - offset: Byte offset of the SIZ marker within `data`.
    /// - Returns: A ``MarkerValidationResult`` describing any detected issues.
    public static func validateSIZ(_ data: Data, offset: Int) -> MarkerValidationResult {
        var issues: [ValidationIssue] = []

        // Need at least marker (2) + length (2) at the given offset
        guard offset + 4 <= data.count else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF51,
                message: "Insufficient data at offset \(offset) to read SIZ marker and length.",
                byteOffset: offset
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        // Verify marker code
        if data[offset] != 0xFF || data[offset + 1] != 0x51 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF51,
                message: "Expected SIZ marker (0xFF51) at offset \(offset); "
                    + "found 0x\(String(format: "%02X%02X", data[offset], data[offset + 1])).",
                byteOffset: offset
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        // Read Lsiz (segment length including the 2-byte length field itself)
        let lsiz = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])

        // ISO/IEC 15444-1 §A.5.1: Lsiz = 38 + 3*Csiz, minimum when Csiz=1 → Lsiz=41
        if lsiz < 41 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF51,
                message: "SIZ segment length Lsiz=\(lsiz) is below the minimum of 41.",
                byteOffset: offset + 2
            ))
        }

        // Ensure enough bytes exist in the buffer
        guard offset + 2 + lsiz <= data.count else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF51,
                message: "SIZ segment extends beyond end of data "
                    + "(offset=\(offset), Lsiz=\(lsiz), available=\(data.count - offset - 2)).",
                byteOffset: offset
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        // Read Rsiz (capability / profile)
        let rsiz = (Int(data[offset + 4]) << 8) | Int(data[offset + 5])
        // Recognised Rsiz values: 0 (no profile), 1 (Profile-0), 2 (Profile-1), 0x4000+ (HTJ2K)
        let knownRsiz = rsiz == 0 || rsiz == 1 || rsiz == 2 || (rsiz & 0x4000) != 0
        if !knownRsiz {
            issues.append(ValidationIssue(
                severity: .warning,
                marker: 0xFF51,
                message: "Rsiz=0x\(String(format: "%04X", rsiz)) is not a recognised profile value.",
                byteOffset: offset + 4
            ))
        }

        // Read Csiz (component count) at a fixed position within the SIZ body
        // Fixed fields: Lsiz(2) + Rsiz(2) + Xsiz(4) + Ysiz(4) + XOsiz(4) + YOsiz(4)
        //             + XTsiz(4) + YTsiz(4) + XTOsiz(4) + YTOsiz(4) = 36 bytes after marker
        let csizOffset = offset + 2 + 36  // 2 (marker) + 36 fixed body bytes
        if csizOffset + 2 > data.count {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF51,
                message: "SIZ segment too short to contain Csiz field.",
                byteOffset: csizOffset
            ))
            return MarkerValidationResult(isCompliant: issues.isEmpty, issues: issues)
        }

        let csiz = (Int(data[csizOffset]) << 8) | Int(data[csizOffset + 1])
        if csiz < 1 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF51,
                message: "Csiz=\(csiz) is invalid; at least one component is required.",
                byteOffset: csizOffset
            ))
        }

        return MarkerValidationResult(isCompliant: issues.filter { $0.severity == .error }.isEmpty, issues: issues)
    }

    // MARK: COD Validation

    /// Validates the COD marker segment (0xFF52) for ISO/IEC 15444-1 §A.6.1 compliance.
    ///
    /// Checks that:
    /// - The marker code is 0xFF52.
    /// - The segment length `Lcod` is at least 12 bytes.
    /// - The progression order (`Prog`) is in the range 0–4.
    /// - The number of quality layers is at most 65535.
    /// - The number of decomposition levels is in the range 0–32.
    ///
    /// - Parameters:
    ///   - data: The raw codestream bytes.
    ///   - offset: Byte offset of the COD marker within `data`.
    /// - Returns: A ``MarkerValidationResult`` describing any detected issues.
    public static func validateCOD(_ data: Data, offset: Int) -> MarkerValidationResult {
        var issues: [ValidationIssue] = []

        guard offset + 4 <= data.count else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "Insufficient data at offset \(offset) to read COD marker and length.",
                byteOffset: offset
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        if data[offset] != 0xFF || data[offset + 1] != 0x52 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "Expected COD marker (0xFF52) at offset \(offset); "
                    + "found 0x\(String(format: "%02X%02X", data[offset], data[offset + 1])).",
                byteOffset: offset
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        let lcod = (Int(data[offset + 2]) << 8) | Int(data[offset + 3])

        // ISO/IEC 15444-1 §A.6.1: Lcod ≥ 12
        if lcod < 12 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "COD segment length Lcod=\(lcod) is below the minimum of 12.",
                byteOffset: offset + 2
            ))
        }

        guard offset + 2 + lcod <= data.count else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "COD segment extends beyond end of data.",
                byteOffset: offset
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        // Scod (coding style): 1 byte at offset+4
        // SGcod starts at offset+5: Prog(1) + Layers(2) + MCT(1)
        // SPcod starts at offset+9: NL(1) + ...
        let codBodyStart = offset + 4  // first byte after Lcod

        guard codBodyStart + 8 <= data.count else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "COD segment body too short to read SGcod and SPcod fields.",
                byteOffset: codBodyStart
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        // Progression order: SGcod byte 0 (at codBodyStart + 1, after Scod byte)
        let progressionOrder = Int(data[codBodyStart + 1])
        if progressionOrder > 4 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "Progression order \(progressionOrder) is out of range; "
                    + "valid values are 0–4 (LRCP, RLCP, RPCL, PCRL, CPRL).",
                byteOffset: codBodyStart + 1
            ))
        }

        // Number of quality layers: SGcod bytes 1–2 (big-endian)
        let layers = (Int(data[codBodyStart + 2]) << 8) | Int(data[codBodyStart + 3])
        if layers < 1 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "Number of quality layers must be at least 1; got \(layers).",
                byteOffset: codBodyStart + 2
            ))
        }
        // Per spec the field is 16-bit unsigned, so maximum is 65535 — always satisfied
        // unless the field erroneously signals 0.

        // Decomposition levels NL: SPcod byte 0 (at codBodyStart + 5)
        let nl = Int(data[codBodyStart + 5])
        if nl > 32 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFF52,
                message: "Decomposition levels NL=\(nl) exceeds the maximum of 32.",
                byteOffset: codBodyStart + 5
            ))
        }

        return MarkerValidationResult(isCompliant: issues.filter { $0.severity == .error }.isEmpty, issues: issues)
    }

    // MARK: EOC Validation

    /// Validates that the codestream ends with the EOC marker (0xFFD9).
    ///
    /// Per ISO/IEC 15444-1 §A.4.4, the EOC marker shall be the last two bytes of
    /// every conformant JPEG 2000 codestream.
    ///
    /// - Parameter data: The raw codestream bytes.
    /// - Returns: A ``MarkerValidationResult`` indicating whether the EOC is present and correctly positioned.
    public static func validateEOC(_ data: Data) -> MarkerValidationResult {
        var issues: [ValidationIssue] = []

        guard data.count >= 2 else {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFFD9,
                message: "Codestream is too short to contain EOC marker (need ≥ 2 bytes, got \(data.count)).",
                byteOffset: data.count
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        let lastTwo = data.count - 2
        if data[lastTwo] != 0xFF || data[lastTwo + 1] != 0xD9 {
            issues.append(ValidationIssue(
                severity: .error,
                marker: 0xFFD9,
                message: "EOC marker (0xFFD9) not found at end of codestream "
                    + "(last two bytes: 0x\(String(format: "%02X%02X", data[lastTwo], data[lastTwo + 1]))).",
                byteOffset: lastTwo
            ))
            return MarkerValidationResult(isCompliant: false, issues: issues)
        }

        return MarkerValidationResult(isCompliant: true, issues: [])
    }

    // MARK: Full Codestream Validation

    /// Validates the overall structure of a JPEG 2000 codestream.
    ///
    /// Performs the following checks in order:
    /// 1. SOC (0xFF4F) is the first two bytes.
    /// 2. SIZ (0xFF51) appears immediately after SOC.
    /// 3. EOC (0xFFD9) is the last two bytes.
    /// 4. The forbidden marker 0xFF00 does not appear within scan data.
    ///
    /// - Parameter data: The raw codestream bytes.
    /// - Returns: A combined ``MarkerValidationResult`` aggregating all findings.
    public static func validateCodestream(_ data: Data) -> MarkerValidationResult {
        var allIssues: [ValidationIssue] = []

        // 1. SOC check
        let socResult = validateSOC(data)
        allIssues.append(contentsOf: socResult.issues)

        // 2. SIZ immediately after SOC (offset 2)
        if socResult.isCompliant {
            if data.count < 4 || data[2] != 0xFF || data[3] != 0x51 {
                let found = data.count >= 4
                    ? "0x\(String(format: "%02X%02X", data[2], data[3]))"
                    : "<end of data>"
                allIssues.append(ValidationIssue(
                    severity: .error,
                    marker: 0xFF51,
                    message: "SIZ marker (0xFF51) must immediately follow SOC at offset 2; found \(found).",
                    byteOffset: 2
                ))
            } else {
                let sizResult = validateSIZ(data, offset: 2)
                allIssues.append(contentsOf: sizResult.issues)
            }
        }

        // 3. EOC check
        let eocResult = validateEOC(data)
        allIssues.append(contentsOf: eocResult.issues)

        // 4. Scan the codestream for COD markers (validate progression order) and
        //    forbidden 0xFF00 byte sequences (erroneous byte stuffing).
        if data.count >= 2 {
            var scanIdx = 0
            while scanIdx + 1 < data.count {
                guard data[scanIdx] == 0xFF else { scanIdx += 1; continue }
                let markerByte = data[scanIdx + 1]

                if markerByte == 0x52 {
                    // COD marker — validate its progression order inline
                    let codResult = validateCOD(data, offset: scanIdx)
                    for issue in codResult.issues {
                        // Only propagate errors; warnings from COD are forwarded as-is
                        allIssues.append(issue)
                    }
                    if scanIdx + 3 < data.count {
                        let len = (Int(data[scanIdx + 2]) << 8) | Int(data[scanIdx + 3])
                        scanIdx += max(2, 2 + len)
                    } else {
                        scanIdx += 2
                    }
                    continue
                }

                if markerByte == 0x00 {
                    allIssues.append(ValidationIssue(
                        severity: .warning,
                        marker: 0xFF00,
                        message: "Forbidden byte sequence 0xFF00 found at offset \(scanIdx); "
                            + "this indicates erroneous byte stuffing.",
                        byteOffset: scanIdx
                    ))
                }

                // Advance: standalone markers have no length; others skip by length field
                if markerByte >= 0x30 && markerByte <= 0x3F {
                    scanIdx += 2
                } else if scanIdx + 3 < data.count && markerByte != 0x4F && markerByte != 0xD9 {
                    let len = (Int(data[scanIdx + 2]) << 8) | Int(data[scanIdx + 3])
                    scanIdx += len > 0 ? 2 + len : 2
                } else {
                    scanIdx += 2
                }
            }
        }

        let hasErrors = allIssues.contains { $0.severity == .error }
        return MarkerValidationResult(isCompliant: !hasErrors, issues: allIssues)
    }
}

// MARK: - Codestream Syntax Validator

/// Validates the high-level syntax and marker ordering of a JPEG 2000 codestream.
///
/// Implements checks derived from ISO/IEC 15444-1 §A (Codestream Syntax), verifying
/// that markers appear in the correct order and that tile-part structures are well-formed.
public struct J2KCodestreamSyntaxValidator: Sendable {

    // MARK: Result

    /// The result of a codestream syntax validation.
    public struct SyntaxResult: Sendable {
        /// `true` when no syntax errors were found.
        public let isValid: Bool
        /// Descriptions of syntax errors.
        public let errors: [String]
        /// Descriptions of non-fatal warnings.
        public let warnings: [String]
        /// Total number of distinct markers encountered during the scan.
        public let markerCount: Int

        /// Creates a new syntax result.
        public init(isValid: Bool, errors: [String], warnings: [String], markerCount: Int) {
            self.isValid = isValid
            self.errors = errors
            self.warnings = warnings
            self.markerCount = markerCount
        }
    }

    // MARK: Marker Ordering

    /// Validates the ordering of main header markers in the codestream.
    ///
    /// Per ISO/IEC 15444-1 §A.4–A.6, the required ordering is:
    /// - SOC shall be first.
    /// - SIZ shall immediately follow SOC.
    /// - COD and/or COC shall appear before the first SOT.
    /// - EOC shall be last.
    ///
    /// - Parameter data: The raw codestream bytes.
    /// - Returns: A ``SyntaxResult`` describing ordering compliance.
    public static func validateMarkerOrdering(_ data: Data) -> SyntaxResult {
        var errors: [String] = []
        var warnings: [String] = []
        var markerCount = 0

        guard data.count >= 2 else {
            return SyntaxResult(isValid: false, errors: ["Codestream is empty."], warnings: [], markerCount: 0)
        }

        // SOC must be first
        if data[0] != 0xFF || data[1] != 0x4F {
            errors.append("SOC marker (0xFF4F) not found at byte 0.")
        }

        // Walk the main header to collect marker positions
        var idx = 2
        var foundSIZ = false
        var foundCOD = false
        var foundSOT = false
        var foundEOC = false
        let socIsFirst = (data.count >= 2 && data[0] == 0xFF && data[1] == 0x4F)

        // SIZ must be first marker after SOC
        if socIsFirst && data.count >= 4 {
            if data[2] == 0xFF && data[3] == 0x51 {
                foundSIZ = true
                markerCount += 1
            } else {
                errors.append("SIZ marker (0xFF51) must immediately follow SOC; not found at offset 2.")
            }
        }

        // Scan all markers
        idx = 2
        while idx + 1 < data.count {
            guard data[idx] == 0xFF else {
                idx += 1
                continue
            }
            let markerByte = data[idx + 1]

            switch markerByte {
            case 0x51:  // SIZ
                markerCount += 1
                if !foundSIZ { foundSIZ = true }
                // Skip segment
                if idx + 3 < data.count {
                    let len = (Int(data[idx + 2]) << 8) | Int(data[idx + 3])
                    idx += 2 + len
                } else { idx += 2 }
                continue
            case 0x52:  // COD
                markerCount += 1
                if foundSOT {
                    errors.append("COD marker found after SOT; COD must appear in the main header.")
                } else {
                    foundCOD = true
                }
                if idx + 3 < data.count {
                    let len = (Int(data[idx + 2]) << 8) | Int(data[idx + 3])
                    idx += 2 + len
                } else { idx += 2 }
                continue
            case 0x53, 0x5C, 0x5D, 0x5E, 0x5F, 0x64:
                // COC, QCD, QCC, RGN, POC, COM — skip
                markerCount += 1
                if idx + 3 < data.count {
                    let len = (Int(data[idx + 2]) << 8) | Int(data[idx + 3])
                    idx += 2 + len
                } else { idx += 2 }
                continue
            case 0x90:  // SOT
                markerCount += 1
                foundSOT = true
                if idx + 3 < data.count {
                    let len = (Int(data[idx + 2]) << 8) | Int(data[idx + 3])
                    idx += 2 + len
                } else { idx += 2 }
                continue
            case 0x93:  // SOD
                markerCount += 1
                // After SOD we skip to next tile-part or EOC; for ordering purposes just advance
                idx += 2
                continue
            case 0xD9:  // EOC
                markerCount += 1
                foundEOC = true
                idx += 2
                continue
            default:
                if markerByte >= 0x30 && markerByte <= 0x3F {
                    // Markers with no segment (standalone)
                    markerCount += 1
                    idx += 2
                } else {
                    idx += 1
                }
                continue
            }
        }

        if !foundSIZ {
            errors.append("SIZ marker (0xFF51) not found in codestream.")
        }
        if !foundCOD {
            warnings.append("COD marker (0xFF52) not found in main header; it is strongly recommended.")
        }
        if !foundEOC {
            errors.append("EOC marker (0xFFD9) not found at end of codestream.")
        }

        return SyntaxResult(isValid: errors.isEmpty, errors: errors, warnings: warnings, markerCount: markerCount)
    }

    // MARK: Tile-Part Structure

    /// Validates the tile-part structure within a codestream.
    ///
    /// Each SOT marker segment must eventually be followed by an SOD marker,
    /// as required by ISO/IEC 15444-1 §A.4.2.
    ///
    /// - Parameter data: The raw codestream bytes.
    /// - Returns: A ``SyntaxResult`` describing tile-part structure compliance.
    public static func validateTilePartStructure(_ data: Data) -> SyntaxResult {
        var errors: [String] = []
        var warnings: [String] = []
        var markerCount = 0
        var idx = 0

        while idx + 1 < data.count {
            guard data[idx] == 0xFF else {
                idx += 1
                continue
            }

            let markerByte = data[idx + 1]
            markerCount += 1

            if markerByte == 0x90 {  // SOT
                // Read Psot (tile-part length) to know where the SOD should be
                guard idx + 11 < data.count else {
                    errors.append("SOT marker at offset \(idx) is truncated.")
                    idx += 2
                    continue
                }
                let lsot = (Int(data[idx + 2]) << 8) | Int(data[idx + 3])
                guard lsot >= 10 else {
                    errors.append("SOT segment length Lsot=\(lsot) is below the minimum of 10.")
                    idx += 2
                    continue
                }

                // Search for SOD between current SOT and next SOT/EOC
                let sotEnd = idx + 2 + lsot
                var foundSOD = false
                var searchIdx = sotEnd

                while searchIdx + 1 < data.count {
                    if data[searchIdx] == 0xFF {
                        if data[searchIdx + 1] == 0x93 {  // SOD
                            foundSOD = true
                            markerCount += 1
                            break
                        } else if data[searchIdx + 1] == 0x90 || data[searchIdx + 1] == 0xD9 {
                            // Next SOT or EOC — stop searching
                            break
                        }
                    }
                    searchIdx += 1
                }

                if !foundSOD {
                    errors.append("Tile-part beginning at SOT offset \(idx) has no corresponding SOD marker.")
                }

                idx = sotEnd
                continue
            }

            if markerByte == 0x93 {  // SOD (standalone, already counted above or orphaned)
                idx += 2
                continue
            }

            if markerByte == 0xD9 {  // EOC
                idx += 2
                break
            }

            // Markers with a length field
            if idx + 3 < data.count {
                let len = (Int(data[idx + 2]) << 8) | Int(data[idx + 3])
                if len < 2 {
                    warnings.append("Marker 0xFF\(String(format: "%02X", markerByte)) at offset \(idx) has length \(len) < 2.")
                    idx += 2
                } else {
                    idx += 2 + len
                }
            } else {
                idx += 2
            }
        }

        return SyntaxResult(isValid: errors.isEmpty, errors: errors, warnings: warnings, markerCount: markerCount)
    }

    // MARK: Progression Order

    /// Returns `true` if the given progression order value is valid per ISO/IEC 15444-1 §A.6.1.
    ///
    /// Valid progression orders are:
    /// - 0: LRCP (Layer–Resolution–Component–Position)
    /// - 1: RLCP (Resolution–Layer–Component–Position)
    /// - 2: RPCL (Resolution–Position–Component–Layer)
    /// - 3: PCRL (Position–Component–Resolution–Layer)
    /// - 4: CPRL (Component–Position–Resolution–Layer)
    ///
    /// - Parameter progressionOrder: The raw byte value from the SGcod field of a COD segment.
    /// - Returns: `true` if the value is in the range 0–4 (inclusive).
    public static func validateProgressionOrder(_ progressionOrder: UInt8) -> Bool {
        progressionOrder <= 4
    }
}
