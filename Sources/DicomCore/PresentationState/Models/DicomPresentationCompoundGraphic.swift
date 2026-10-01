import Foundation

public struct DicomPresentationCompoundGraphic: Equatable, Sendable {
    public static let supportedTypes: Set<String> = [
        "MULTILINE", "INFINITELINE", "CUTLINE", "RANGELINE", "RULER",
        "AXIS", "CROSSHAIR", "ARROW", "RECTANGLE", "ELLIPSE"
    ]

    public let instanceID: UInt32
    public let units: String
    public let graphicType: String
    public let graphicData: [Double]
    public let graphicFilled: Bool?
    public let rotationAngle: Double?
    public let rotationPoint: SIMD2<Double>?
    public let gapLength: Double?
    public let diameterOfVisibility: Double?
    public let tickAlignment: String?
    public let tickLabelAlignment: String?
    public let showsTickLabels: Bool?
    public let majorTicks: [DicomPresentationCompoundGraphicMajorTick]
    public let lineStyle: DicomPresentationCompoundGraphicLineStyle?
    public let fillStyle: DicomPresentationCompoundGraphicFillStyle?
    public let textStyle: DicomPresentationCompoundGraphicTextStyle?
    public let graphicGroupID: UInt32?

    public init(
        instanceID: UInt32,
        units: String,
        graphicType: String,
        graphicData: [Double],
        graphicFilled: Bool? = nil,
        rotationAngle: Double? = nil,
        rotationPoint: SIMD2<Double>? = nil,
        gapLength: Double? = nil,
        diameterOfVisibility: Double? = nil,
        tickAlignment: String? = nil,
        tickLabelAlignment: String? = nil,
        showsTickLabels: Bool? = nil,
        majorTicks: [DicomPresentationCompoundGraphicMajorTick] = [],
        lineStyle: DicomPresentationCompoundGraphicLineStyle? = nil,
        fillStyle: DicomPresentationCompoundGraphicFillStyle? = nil,
        textStyle: DicomPresentationCompoundGraphicTextStyle? = nil,
        graphicGroupID: UInt32? = nil
    ) {
        self.instanceID = instanceID
        self.units = units.dicomGSPSNonEmptyValue?.uppercased() ?? "PIXEL"
        self.graphicType = graphicType.dicomGSPSNonEmptyValue?.uppercased() ?? ""
        self.graphicData = graphicData
        self.graphicFilled = graphicFilled
        self.rotationAngle = rotationAngle
        self.rotationPoint = rotationPoint
        self.gapLength = gapLength
        self.diameterOfVisibility = diameterOfVisibility
        self.tickAlignment = tickAlignment?.dicomGSPSNonEmptyValue?.uppercased()
        self.tickLabelAlignment = tickLabelAlignment?.dicomGSPSNonEmptyValue?.uppercased()
        self.showsTickLabels = showsTickLabels
        self.majorTicks = majorTicks
        self.lineStyle = lineStyle
        self.fillStyle = fillStyle
        self.textStyle = textStyle
        self.graphicGroupID = graphicGroupID
    }

    public var isStructurallyRenderable: Bool {
        guard ["PIXEL", "DISPLAY"].contains(units),
              Self.supportedTypes.contains(graphicType),
              graphicData.allSatisfy(\.isFinite),
              rotationAngle?.isFinite != false,
              rotationAngle.map({ (0...360).contains($0) }) != false,
              rotationPoint?.x.isFinite != false,
              rotationPoint?.y.isFinite != false,
              gapLength?.isFinite != false,
              diameterOfVisibility?.isFinite != false,
              stylesAreRenderable else {
            return false
        }
        if rotationAngle != nil, rotationPoint == nil { return false }
        switch graphicType {
        case "MULTILINE":
            return graphicData.count >= 4 && graphicData.count.isMultiple(of: 4)
        case "INFINITELINE", "CUTLINE":
            return units == "DISPLAY" && graphicData.count == 4 && rotationPoint != nil
                && (gapLength ?? -1) >= 0
        case "RANGELINE", "ARROW":
            return graphicData.count == 4
        case "RULER":
            return graphicData.count == 4 && hasRequiredTickAttributes
        case "AXIS":
            return graphicData.count == 4 && hasRequiredTickAttributes && majorTicks.count >= 2
                && majorTicks.allSatisfy { $0.position.isFinite && (0...1).contains($0.position) }
        case "CROSSHAIR":
            return units == "DISPLAY" && graphicData.count == 2 && hasRequiredTickAttributes
                && tickAlignment == "CENTER" && (gapLength ?? -1) >= 0 && (diameterOfVisibility ?? 0) > 0
        case "RECTANGLE", "ELLIPSE":
            return graphicData.count == 4 && graphicFilled != nil
                && (graphicFilled != true || fillStyle != nil)
        default:
            return false
        }
    }

    private var hasRequiredTickAttributes: Bool {
        guard let tickAlignment, let tickLabelAlignment, showsTickLabels != nil else { return false }
        return ["BOTTOM", "CENTER", "TOP"].contains(tickAlignment)
            && ["BOTTOM", "TOP"].contains(tickLabelAlignment)
    }

    private var stylesAreRenderable: Bool {
        let opacityRange = 0.0...1.0
        if let lineStyle {
            guard lineStyle.patternOnOpacity.map(opacityRange.contains) != false,
                  lineStyle.patternOffOpacity.map(opacityRange.contains) != false,
                  lineStyle.lineThickness.map({ $0.isFinite && $0 > 0 }) != false,
                  lineStyle.lineDashingStyle.map({ ["SOLID", "DASHED"].contains($0) }) != false,
                  lineStyle.lineDashingStyle != "DASHED" || lineStyle.linePattern != nil,
                  shadowIsRenderable(
                      style: lineStyle.shadowStyle,
                      offsetX: lineStyle.shadowOffsetX,
                      offsetY: lineStyle.shadowOffsetY,
                      color: lineStyle.shadowColorCIELabValue,
                      opacity: lineStyle.shadowOpacity
                  ) else {
                return false
            }
        }
        if let fillStyle {
            guard fillStyle.patternOnOpacity.map(opacityRange.contains) != false,
                  fillStyle.patternOffOpacity.map(opacityRange.contains) != false,
                  fillStyle.fillMode.map({ ["SOLID", "STIPPELED"].contains($0) }) != false,
                  fillStyle.fillMode != "STIPPELED" || fillStyle.fillPattern?.count == 128 else {
                return false
            }
        }
        if let textStyle {
            guard shadowIsRenderable(
                style: textStyle.shadowStyle,
                offsetX: textStyle.shadowOffsetX,
                offsetY: textStyle.shadowOffsetY,
                color: textStyle.shadowColorCIELabValue,
                opacity: textStyle.shadowOpacity
            ) else {
                return false
            }
        }
        return true
    }

    private func shadowIsRenderable(
        style: String?,
        offsetX: Double?,
        offsetY: Double?,
        color: [UInt16],
        opacity: Double?
    ) -> Bool {
        guard let style else { return true }
        guard ["OFF", "NORMAL", "OUTLINED"].contains(style) else { return false }
        if style == "OFF" { return true }
        return offsetX?.isFinite == true && offsetY?.isFinite == true
            && color.count == 3 && opacity.map { (0...1).contains($0) } == true
    }
}
