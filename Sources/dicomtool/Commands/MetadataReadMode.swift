import ArgumentParser

/// The legacy mode preserves inspect's established compatibility behavior.
enum MetadataReadMode: String, ExpressibleByArgument {
    case legacy
    case strict
    case recover
}
