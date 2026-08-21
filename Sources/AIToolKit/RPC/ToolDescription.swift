import Foundation

/// A tool's eight fields, in the shape they take on the wire.
///
/// This is the concrete `Codable` type ``AITool`` deliberately is not: a
/// protocol cannot be `Decodable`, because decoding has to know what to build.
/// Serialization belongs here so the interface stays clean enough for a
/// forwarding proxy to conform to it.
public struct ToolDescription: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let configDirectoryName: String
    public let configDirEnvVar: String?
    public let authLoginCommand: [String]?
    public let installCommand: [String]?
    public let sessionSubdirectories: [String]
    public let ansiColor: String

    public init(
        id: String,
        displayName: String,
        configDirectoryName: String,
        configDirEnvVar: String?,
        authLoginCommand: [String]?,
        installCommand: [String]?,
        sessionSubdirectories: [String],
        ansiColor: String
    ) {
        self.id = id
        self.displayName = displayName
        self.configDirectoryName = configDirectoryName
        self.configDirEnvVar = configDirEnvVar
        self.authLoginCommand = authLoginCommand
        self.installCommand = installCommand
        self.sessionSubdirectories = sessionSubdirectories
        self.ansiColor = ansiColor
    }

    public init(_ tool: any AITool) {
        self.init(
            id: tool.id,
            displayName: tool.displayName,
            configDirectoryName: tool.configDirectoryName,
            configDirEnvVar: tool.configDirEnvVar,
            authLoginCommand: tool.authLoginCommand,
            installCommand: tool.installCommand,
            sessionSubdirectories: tool.sessionSubdirectories,
            ansiColor: tool.ansiColor)
    }
}
