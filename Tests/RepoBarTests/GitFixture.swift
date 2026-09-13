import Foundation
@testable import RepoBarCore

@discardableResult
func runGit(_ arguments: [String], in directory: URL) throws -> String {
    let result = try GitProcessRunner.run(arguments, in: directory, timeout: 30)
    guard result.terminationStatus == 0 else {
        throw GitFixtureError.commandFailed(arguments: arguments, output: result.stdout, error: result.stderr)
    }

    return result.stdout
}

private enum GitFixtureError: Error {
    case commandFailed(arguments: [String], output: String, error: String)
}
