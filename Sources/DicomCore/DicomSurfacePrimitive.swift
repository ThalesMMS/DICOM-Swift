//
//  DicomSurfacePrimitive.swift
//  DicomCore
//

/// One indexed primitive encoded by the Surface Mesh Primitives Module.
public enum DicomSurfacePrimitive: Equatable, Sendable {
    case triangles([UInt32])
    case triangleStrip([UInt32])
    case triangleFan([UInt32])
    case facet([UInt32])
    case line([UInt32])
    case edges([UInt32])
}
