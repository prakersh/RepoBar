---
summary: "Current multi-account authentication, storage, cache and CLI boundaries, plus deferred work."
read_when:
  - Modifying auth/token storage
  - Modifying account settings or app session state
  - Modifying CLI auth commands
---

# Multi-Account Authentication

RepoBar supports multiple saved GitHub.com and Enterprise accounts. The active account drives the existing repository menu, reference monitor and notifications. Account storage and token refresh are scoped independently. Saving several accounts does not make the menu aggregate their repositories.

## Account ownership

`RepoBarCore.Account` derives a stable identity from the lowercased host authority and username, such as `github.com#alice` or `ghe.example.com:8443#bob`. Each account carries its host, API host, authentication method, loopback port and optional client ID. Secrets remain in `TokenStore`.

`AccountManager` owns a `GitHubClient` and OAuth refresher per account. `AppState.bootstrapAccounts()` loads saved accounts, attempts migration when the account list is empty, and selects the active client. The lifecycle's five-minute refresh loop asks the manager to refresh all account-scoped OAuth credentials; PAT accounts do not need token refresh.

`Session` holds the active account’s repository lists. `UserSettings.accountSelection` remains a persisted visibility preference; multi-account menu aggregation is deferred.

## Storage and compatibility

`TokenStore` supports Keychain storage in release builds and file storage for debug builds. OAuth tokens, client credentials and PATs use account-scoped keys, with an index for account enumeration. See [auth storage](auth-storage.md) for key formats, file names and backend selection.

The legacy `default`, `client` and `pat` keys, legacy filename fallback, and single-account settings fields are compatibility contracts for saved installs and downgrades. Migration copies credentials into account-scoped storage and retains legacy entries. Account switching and CLI login mirror the selected account into legacy storage for callers that still use those APIs. Do not remove these paths as unused scaffolding.

REST and GraphQL caches use account-specific SQLite files when an account ID is supplied. Passing no account ID retains the legacy shared cache path. Repository pin/hidden lists are also saved and restored per account.

## User and CLI surfaces

Preferences → Accounts lists saved accounts and supports activation, visibility, verification and removal. The Add Account form supports browser OAuth and PAT authentication.

The CLI supports:

- `accounts list`, `accounts use <id|user@host>` and `accounts remove <id|user@host>`.
- `login --label` and `import-gh-token --label`; successful authentication fetches `/user` and persists the identified account.
- `logout --account` or `logout --all`.
- `status --account`; commands without an explicit selection resolve the active account.

See the [CLI reference](cli.md) for supported options. Proposed flags from earlier design drafts are not part of the command contract.

## Deferred decisions

Notification/reference-monitor fan-out, per-account rate-limit presentation, and menu grouping across accounts need explicit product and identity rules before implementation. In particular, the same repository can be accessible through multiple accounts; notification snapshots and reference matches must retain the producing account before those services aggregate results.

Retiring legacy credential storage also needs a defined migration and downgrade policy. The presence of account-scoped APIs alone is not sufficient reason to remove the old keys.

## Validation

Account model, account manager, token store, settings and CLI account-resolution tests cover the implemented boundaries. Changes to account selection must preserve credential isolation, host/port identity, pin/hidden restoration, and the legacy upgrade path. Exercise the signed built app or CLI as well as unit tests when changing authentication behavior.
