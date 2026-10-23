import Foundation
import MeterCore

/// `meter mcp`: a Model Context Protocol server over stdio, so an agent can ask how much of
/// a plan is left and what spent it.
struct MCPServer {
    let app: MeterCLIApplication

    /// Serves until stdin closes, then returns the process exit code.
    func serve() async -> Int32 {
        FileHandle.standardError.write(Data("meter mcp is not implemented yet\n".utf8))
        return 2
    }
}
