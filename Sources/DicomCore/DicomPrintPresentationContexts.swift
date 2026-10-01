struct DicomPrintPresentationContexts {
    let resolvedMode: DicomResolvedPrintMode
    let filmSession: DicomAcceptedPresentationContext
    let filmBox: DicomAcceptedPresentationContext
    let imageBox: DicomAcceptedPresentationContext
    let printer: DicomAcceptedPresentationContext?

    var imageBoxSOPClassUID: String {
        switch resolvedMode {
        case .grayscale: DicomNetworkUID.basicGrayscaleImageBoxSOPClass
        case .color: DicomNetworkUID.basicColorImageBoxSOPClass
        }
    }

    static func resolve(
        requestedMode: DicomPrintMode,
        association: DicomAssociation
    ) throws -> DicomPrintPresentationContexts {
        let candidates: [DicomResolvedPrintMode]
        switch requestedMode {
        case .automatic: candidates = [.color, .grayscale]
        case .grayscale: candidates = [.grayscale]
        case .color: candidates = [.color]
        }

        for candidate in candidates {
            if let contexts = make(resolvedMode: candidate, association: association) {
                return contexts
            }
        }
        throw DicomPrintManagementError.printModeNotNegotiated(requestedMode)
    }

    private static func make(
        resolvedMode: DicomResolvedPrintMode,
        association: DicomAssociation
    ) -> DicomPrintPresentationContexts? {
        let metaSOPClassUID: String
        let imageBoxSOPClassUID: String
        switch resolvedMode {
        case .grayscale:
            metaSOPClassUID = DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
            imageBoxSOPClassUID = DicomNetworkUID.basicGrayscaleImageBoxSOPClass
        case .color:
            metaSOPClassUID = DicomNetworkUID.basicColorPrintManagementMetaSOPClass
            imageBoxSOPClassUID = DicomNetworkUID.basicColorImageBoxSOPClass
        }

        if let meta = association.acceptedPresentationContext(for: metaSOPClassUID) {
            return DicomPrintPresentationContexts(
                resolvedMode: resolvedMode,
                filmSession: meta,
                filmBox: meta,
                imageBox: meta,
                printer: association.acceptedPresentationContext(for: DicomNetworkUID.printerSOPClass) ?? meta
            )
        }

        guard let filmSession = association.acceptedPresentationContext(
            for: DicomNetworkUID.basicFilmSessionSOPClass
        ), let filmBox = association.acceptedPresentationContext(
            for: DicomNetworkUID.basicFilmBoxSOPClass
        ), let imageBox = association.acceptedPresentationContext(for: imageBoxSOPClassUID) else {
            return nil
        }
        return DicomPrintPresentationContexts(
            resolvedMode: resolvedMode,
            filmSession: filmSession,
            filmBox: filmBox,
            imageBox: imageBox,
            printer: association.acceptedPresentationContext(for: DicomNetworkUID.printerSOPClass)
        )
    }
}
