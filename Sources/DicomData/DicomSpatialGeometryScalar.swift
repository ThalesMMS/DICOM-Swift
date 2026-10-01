import Foundation

/// Exact expansion arithmetic for degree <= 3 predicates over binary32 coordinates.
/// Products stay within normal binary64 range; FMA captures multiplication roundoff.
/// Radius bounds the effect of half a storage ULP per input, rather than a fixed spatial tolerance.
struct DicomSpatialGeometryScalar {
    private var terms: [Double]
    let radius: Double

    init(_ value: Double) {
        terms = value == 0 ? [] : [value]
        radius = Double(Float(value).ulp) / 2
    }

    private init(terms: [Double], radius: Double) { self.terms = terms; self.radius = radius }
    var isZero: Bool { terms.isEmpty }
    var sign: Double { terms.last ?? 0 }
    var magnitude: Double { terms.reduce(0) { ($0 + abs($1)).nextUp } }
    var zero: DicomAttributeRule.Truth {
        if isZero { return .satisfied }
        let tail = terms.dropLast().reduce(0) { ($0 + abs($1)).nextUp }
        let lower = (abs(sign) - tail).nextDown
        return lower > radius ? .unsatisfied : .undetermined
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        var result = lhs.terms
        for term in rhs.terms { grow(&result, by: term) }
        return .init(terms: result, radius: (lhs.radius + rhs.radius).nextUp)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        lhs + .init(terms: rhs.terms.map { -$0 }, radius: rhs.radius)
    }

    static func * (lhs: Self, rhs: Self) -> Self {
        var result: [Double] = []
        for first in lhs.terms {
            for second in rhs.terms {
                let product = first * second
                grow(&result, by: fma(first, second, -product))
                grow(&result, by: product)
            }
        }
        let firstError = (lhs.magnitude * rhs.radius).nextUp
        let secondError = (rhs.magnitude * lhs.radius).nextUp
        let crossError = (lhs.radius * rhs.radius).nextUp
        let radius = ((firstError + secondError).nextUp + crossError).nextUp
        return .init(terms: result, radius: radius)
    }

    /// Error-free TwoSum, growing a nonoverlapping expansion with zero elimination.
    private static func grow(_ expansion: inout [Double], by value: Double) {
        guard value != 0 else { return }
        var carry = value
        var result: [Double] = []
        for term in expansion {
            let sum = carry + term
            let recovered = sum - carry
            let error = (carry - (sum - recovered)) + (term - recovered)
            if error != 0 { result.append(error) }
            carry = sum
        }
        if carry != 0 { result.append(carry) }
        expansion = result
    }
}
