import Foundation

/// A plain class purely so `Bundle(for:)` has something to resolve — structs
/// cannot be handed to it.
private final class LocatorMarker {}

/// Finds the built `AIToolKitTestPlugin` binary.
///
/// This is harder than it looks, and it has now been wrong twice, in opposite
/// directions:
///
/// - `Bundle.main` fails on **macOS**: `swift test` runs swift-testing suites
///   out of process through `swiftpm-testing-helper`, so `Bundle.main` resolves
///   into the toolchain rather than the package's build products.
/// - `Bundle(for:)` fails on **Linux**: there is no `.xctest` bundle to resolve
///   against — the test runner is a plain executable — so the derived directory
///   is wrong and the binary is simply not there.
///
/// Rather than bet on one mechanism per platform, this tries every candidate it
/// knows and returns the first that actually exists. That way a third platform
/// difference produces a *diagnosable* failure instead of the bare
/// `NSCocoaErrorDomain Code=260 "The file doesn't exist."` that the Linux CI job
/// reported — an error which says nothing about what was looked for or where.
enum TestPluginLocator {

    static let binaryName = "AIToolKitTestPlugin"

    struct NotFound: Error, CustomStringConvertible {
        let searched: [String]
        var description: String {
            """
            Could not find the built `\(binaryName)` executable. Looked in:
            \(searched.map { "  - \($0)" }.joined(separator: "\n"))
            If this is a new platform or a changed SwiftPM layout, add its build
            products directory to TestPluginLocator.candidateDirectories().
            """
        }
    }

    /// Every directory the built plugin might plausibly sit in, most likely
    /// first. Duplicates are harmless — the caller stops at the first hit.
    static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []

        // macOS: the `.xctest` bundle's parent is the build products directory.
        let bundleDir = Bundle(for: LocatorMarker.self).bundleURL
        dirs.append(bundleDir.deletingLastPathComponent())
        dirs.append(bundleDir)

        // Linux: the test runner is a plain executable sitting in the build
        // products directory, so `Bundle.main` is that directory.
        dirs.append(Bundle.main.bundleURL)
        dirs.append(Bundle.main.bundleURL.deletingLastPathComponent())

        // Last resort, and the only one that does not go through Foundation's
        // bundle machinery at all: the running executable's own directory.
        if let argv0 = CommandLine.arguments.first {
            let exe = URL(fileURLWithPath: argv0).deletingLastPathComponent()
            dirs.append(exe)
        }

        return dirs
    }

    /// The plugin binary, or a `NotFound` naming everywhere that was tried.
    static func url() throws -> URL {
        let fm = FileManager.default
        var searched: [String] = []

        for dir in candidateDirectories() {
            let candidate = dir.appendingPathComponent(binaryName)
            searched.append(candidate.path)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw NotFound(searched: searched)
    }
}
