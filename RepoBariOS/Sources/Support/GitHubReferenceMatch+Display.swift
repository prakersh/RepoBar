import RepoBarCore
import SwiftUI

extension GitHubReferenceMatch {
    var statusLabel: String {
        self.state?.label ?? self.kind.label
    }

    var symbolName: String {
        switch self.kind {
        case .commit:
            "number"
        case .workflowRun:
            "play.circle"
        case .issue, .pullRequest:
            switch self.state {
            case .open:
                "exclamationmark.circle"
            case .closed:
                "checkmark.circle"
            case .merged:
                "arrow.triangle.merge"
            case nil:
                self.kind == .pullRequest ? "arrow.triangle.branch" : "exclamationmark.circle"
            }
        }
    }

    var tint: Color {
        switch self.kind {
        case .commit, .workflowRun:
            .secondary
        case .issue, .pullRequest:
            switch self.state {
            case .open: .green
            case .closed: .purple
            case .merged: .purple
            case nil: .secondary
            }
        }
    }
}
