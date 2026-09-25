import Foundation
import Testing
@testable import AIToolKit

/// Where a plugin is allowed to write.
///
/// The rule worth pinning is the absence of a fallback. A plugin that guessed a
/// directory when the host supplied none would work on a developer's machine and
/// write into their real config during an isolated run — so "not supplied" has to
/// stay distinguishable from "here it is", all the way to the caller.
@Suite("PluginState")
struct PluginStateTests {

    @Test("the host's directory is used as given")
    func usesWhatTheHostSupplied() {
        let url = PluginState.directory(
            environment: [PluginState.directoryEnvVar: "/tmp/state"])
        #expect(url?.path == "/tmp/state")
    }

    @Test("no directory supplied is nil, never a guess")
    func noFallback() {
        #expect(PluginState.directory(environment: [:]) == nil)
    }

    /// An empty value is a host that set the variable wrongly, which is closer to
    /// not setting it than to naming the current directory.
    @Test("an empty value is treated as absent, not as a relative path")
    func emptyIsAbsent() {
        #expect(PluginState.directory(environment: [PluginState.directoryEnvVar: ""]) == nil)
    }

    @Test("nothing in the environment names a home directory")
    func doesNotConsultHome() {
        let url = PluginState.directory(environment: [
            "HOME": "/Users/someone",
            "ORRERY_USER_HOME": "/Users/someone",
        ])
        #expect(url == nil, "a home in the environment is not a state directory")
    }
}
