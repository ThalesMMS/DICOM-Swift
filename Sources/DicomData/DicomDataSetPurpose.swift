//
//  DicomDataSetPurpose.swift
//  DicomData
//
//  Value syntax differs between stored instances and query matching keys. Query validation does not
//  imply that the peer negotiated every matching option.
//
//  Thales Matheus Mendonça Santos — September 2026
//

/// Value syntax differs between stored instances and query matching keys.
/// Query validation does not imply that the peer negotiated every matching option.
public enum DicomDataSetPurpose: Equatable, Sendable {
    case instance
    case query
}
