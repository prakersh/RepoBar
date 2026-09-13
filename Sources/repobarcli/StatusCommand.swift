import Commander
import Foundation
import RepoBarCore

@MainActor
struct StatusCommand: CommanderRunnableCommand {
    nonisolated static let commandName = "status"

    @OptionGroup
    var output: OutputOptions

    @Option(name: .customLong("account"), help: "Account ID or username@host (defaults to active account)")
    var account: String?

    static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: commandName,
            abstract: "Show login state"
        )
    }

    mutating func bind(_ values: ParsedValues) throws {
        self.output.bind(values)
        self.account = try values.decodeOption("account")
    }

    mutating func run() async throws {
        let settings = cliSettingsStore().load()
        // When the user explicitly targets an account, read account-scoped tokens.
        if self.account != nil || settings.accounts.isEmpty == false {
            let resolved: Account
            do {
                resolved = try AccountResolver.resolve(self.account, settings: settings)
            } catch {
                if self.account == nil {
                    // No account configured at all - fall through to legacy path.
                    try await self.runLegacy()
                    return
                }
                throw error
            }
            let tokens = try? TokenStore.shared.loadTokens(accountID: resolved.id)
            let pat = try? TokenStore.shared.loadPAT(accountID: resolved.id)
            let now = Date()
            let expiresAt = tokens?.expiresAt
            let expired = expiresAt.map { $0 <= now }
            let expiresIn = expiresAt.map { RelativeFormatter.string(from: $0, relativeTo: now) }
            let authenticated = tokens != nil || pat != nil
            if self.output.jsonOutput {
                let output = StatusOutput(
                    authenticated: authenticated,
                    host: resolved.host.absoluteString,
                    expiresAt: expiresAt,
                    expiresIn: expiresIn,
                    expired: expired
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(output)
                if let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else if authenticated == false {
                print("Logged out (\(resolved.id)).")
            } else {
                print("Logged in as \(resolved.id).")
                print("Host: \(resolved.host.absoluteString)")
                if let expiresAt {
                    let state = expired == true ? "expired" : "expires"
                    let label = expiresIn ?? expiresAt.formatted()
                    print("\(state.capitalized): \(label)")
                } else {
                    print("Expires: unknown")
                }
            }
            return
        }
        try await self.runLegacy()
    }

    private func runLegacy() async throws {
        let tokens = try TokenStore.shared.load()
        guard let tokens else {
            if self.output.jsonOutput {
                let output = StatusOutput(
                    authenticated: false,
                    host: nil,
                    expiresAt: nil,
                    expiresIn: nil,
                    expired: nil
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(output)
                if let json = String(data: data, encoding: .utf8) {
                    print(json)
                }
            } else {
                print("Logged out.")
            }
            return
        }

        let settings = cliSettingsStore().load()
        let host = (settings.enterpriseHost ?? settings.githubHost).absoluteString
        let now = Date()
        let expiresAt = tokens.expiresAt
        let expired = expiresAt.map { $0 <= now }
        let expiresIn = expiresAt.map { RelativeFormatter.string(from: $0, relativeTo: now) }

        if self.output.jsonOutput {
            let output = StatusOutput(
                authenticated: true,
                host: host,
                expiresAt: expiresAt,
                expiresIn: expiresIn,
                expired: expired
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(output)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            print("Logged in.")
            print("Host: \(host)")
            if let expiresAt {
                let state = expired == true ? "expired" : "expires"
                let label = expiresIn ?? expiresAt.formatted()
                print("\(state.capitalized): \(label)")
            } else {
                print("Expires: unknown")
            }
        }
    }
}
