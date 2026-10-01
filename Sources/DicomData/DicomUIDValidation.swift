// Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
// SPDX-License-Identifier: Apache-2.0

/// PS3.5 9.1: decimal components without leading zeros, at most 64 characters.
package func dicomIsValidUID(_ uid: String) -> Bool {
    guard !uid.isEmpty, uid.count <= 64 else { return false }
    let components = uid.split(separator: ".", omittingEmptySubsequences: false)
    return components.count >= 2 && components.allSatisfy {
        !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0 == "0" || !$0.hasPrefix("0"))
    }
}
