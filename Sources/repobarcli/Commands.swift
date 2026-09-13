import Commander
import Foundation
import RepoBarCore

@MainActor
struct RepoBarRoot: ParsableCommand {
    nonisolated static let commandName = "repobar"

    static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: commandName,
            abstract: "RepoBar CLI",
            subcommands: [
                ReposCommand.self,
                RepoCommand.self,
                IssuesCommand.self,
                PullsCommand.self,
                ReleasesCommand.self,
                CICommand.self,
                DiscussionsCommand.self,
                TagsCommand.self,
                BranchesCommand.self,
                ContributorsCommand.self,
                CommitsCommand.self,
                ActivityCommand.self,
                LocalProjectsCommand.self,
                LocalSyncCommand.self,
                LocalRebaseCommand.self,
                LocalResetCommand.self,
                LocalBranchesCommand.self,
                WorktreesCommand.self,
                OpenFinderCommand.self,
                OpenTerminalCommand.self,
                CheckoutCommand.self,
                RefreshCommand.self,
                ContributionsCommand.self,
                ChangelogCommand.self,
                MarkdownCommand.self,
                PinCommand.self,
                UnpinCommand.self,
                HideCommand.self,
                ShowCommand.self,
                ArchivesListCommand.self,
                ArchivesStatusCommand.self,
                ArchivesValidateCommand.self,
                ArchivesUpdateCommand.self,
                ArchivesAddCommand.self,
                ArchivesRemoveCommand.self,
                ArchivesEnableCommand.self,
                ArchivesDisableCommand.self,
                RateLimitsCommand.self,
                ReferenceTranslateCommand.self,
                CacheStatusCommand.self,
                CacheClearCommand.self,
                SettingsShowCommand.self,
                SettingsSetCommand.self,
                LoginCommand.self,
                LogoutCommand.self,
                ImportGHTokenCommand.self,
                StatusCommand.self,
                AccountsListCommand.self,
                AccountsUseCommand.self,
                AccountsRemoveCommand.self
            ],
            defaultSubcommand: ReposCommand.self
        )
    }
}
