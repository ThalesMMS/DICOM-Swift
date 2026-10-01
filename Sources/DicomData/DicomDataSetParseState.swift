struct DicomDataSetParseState {
    let limits: DicomDataSetParseLimits
    let privateDictionary: DicomPrivateDictionary
    let dictionary: DCMDictionary
    let mode: DicomDataSetReadMode?
    let purpose: DicomDataSetPurpose
    let maximumDiagnostics: Int
    private(set) var diagnostics: [DicomDataSetReadResult.Diagnostic] = []
    private(set) var elementCount = 0
    private(set) var itemCount = 0
    let resolvesContext: Bool
    var itemPath: [Int] = []
    var contextualValues: [[Int]: DicomContextualVRResolver.PendingValue] = [:]
    var recordsValidationPaths = false
    private(set) var structuralPath: [DicomValidationReport.PathComponent] = []
    private(set) var omittedPixelDataPaths: [[DicomValidationReport.PathComponent]] = []
    private(set) var omittedPixelDataPathsTruncated = false

    private(set) var pixelDataHeaders: [DicomPixelDataHeaderEvidence] = []
    private(set) var pixelDataHeadersTruncated = false

    mutating func recordPixelDataHeader(tag: Int, vr: DicomVR, length: UInt32, valueOffset: Int) {
        guard recordsValidationPaths else { return }
        guard pixelDataHeaders.count < maximumDiagnostics else { pixelDataHeadersTruncated = true; return }
        pixelDataHeaders.append(.init(path: pathComponents(itemPath + [tag]), vr: vr, valueLength: length, valueOffset: valueOffset))
    }

    mutating func recordOmittedPixelData(tag: Int) {
        guard recordsValidationPaths else { return }
        guard omittedPixelDataPaths.count < maximumDiagnostics else {
            omittedPixelDataPathsTruncated = true
            return
        }
        omittedPixelDataPaths.append(pathComponents(itemPath + [tag]))
    }

    /// Keep the last operation's location independently of the recursion stack,
    /// whose item paths unwind before a caller receives a structural failure.
    mutating func recordStructuralLocation(tag: Int? = nil, item: Int? = nil) {
        guard recordsValidationPaths else { return }
        structuralPath = pathComponents(itemPath)
        if let tag { structuralPath.append(.tag(tag)) }
        if let item { structuralPath.append(.item(item)) }
    }

    init(limits: DicomDataSetParseLimits, privateDictionary: DicomPrivateDictionary = .standard,
         mode: DicomDataSetReadMode? = nil, maximumDiagnostics: Int = 128, resolvesContext: Bool = false,
         dictionary: DCMDictionary = DCMDictionary(), purpose: DicomDataSetPurpose = .instance) {
        self.limits = limits
        self.privateDictionary = privateDictionary
        self.dictionary = dictionary
        self.mode = mode
        self.purpose = purpose
        self.maximumDiagnostics = max(0, maximumDiagnostics)
        self.resolvesContext = resolvesContext
    }

    func diagnostic(_ reason: DicomDataSetReadResult.Diagnostic.Reason, tag: Int, offset: Int,
                    path: [Int]? = nil) -> DicomDataSetReadResult.Diagnostic {
        .init(tag: tag, offset: offset, reason: reason, path: pathComponents(path ?? (itemPath + [tag])))
    }

    private func pathComponents(_ path: [Int]) -> [DicomValidationReport.PathComponent] {
        path.enumerated().map { index, value in
            index.isMultiple(of: 2) ? DicomValidationReport.PathComponent.tag(value) : .item(value)
        }
    }

    mutating func diagnose(_ reason: DicomDataSetReadResult.Diagnostic.Reason, tag: Int, offset: Int,
                           path: [Int]? = nil) throws {
        let diagnostic = diagnostic(reason, tag: tag, offset: offset, path: path)
        guard mode == .recover, diagnostics.count < maximumDiagnostics else { throw diagnostic }
        diagnostics.append(diagnostic)
    }

    mutating func consumeElement() throws {
        guard elementCount < limits.maximumElementCount else {
            throw DicomDataSetParseError.maximumElementCountExceeded(limit: limits.maximumElementCount)
        }
        elementCount += 1
    }

    mutating func consumeItem() throws {
        guard itemCount < limits.maximumItemCount else {
            throw DicomDataSetParseError.maximumItemCountExceeded(limit: limits.maximumItemCount)
        }
        itemCount += 1
    }

    func nestedSequenceDepth(after currentDepth: Int) throws -> Int {
        guard currentDepth < limits.maximumSequenceDepth else {
            throw DicomDataSetParseError.maximumSequenceDepthExceeded(limit: limits.maximumSequenceDepth)
        }
        return currentDepth + 1
    }
}
