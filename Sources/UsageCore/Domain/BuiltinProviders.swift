import Foundation

// The providers, products, surfaces and sources that ship with the application.
//
// This is the one place that names a provider. Everything else in the core refers to providers through the
// identifiers defined in the registry, so supporting another provider means adding its definitions here (or
// supplying another registry) together with an adapter.

public extension ProviderID {
    static let anthropic: ProviderID = "anthropic"
    static let openAI: ProviderID = "openai"
}

public extension ProductID {
    static let claudeCode: ProductID = "claude-code"
    static let claudeChat: ProductID = "claude-chat"
    static let codex: ProductID = "codex"
    static let chatGPTWork: ProductID = "chatgpt-work"
    static let chatGPTChat: ProductID = "chatgpt-chat"
}

public extension SurfaceID {
    static let terminal: SurfaceID = "terminal"
    static let vscode: SurfaceID = "vscode"
    static let jetbrains: SurfaceID = "jetbrains"
    static let claudeDesktop: SurfaceID = "claude-desktop"
    static let codexDesktop: SurfaceID = "codex-desktop"
    static let chatGPTDesktop: SurfaceID = "chatgpt-desktop"
    static let unknown: SurfaceID = "unknown"
}

public extension TelemetrySourceID {
    static let claudeTranscripts: TelemetrySourceID = "claude-code-transcripts"
    static let claudeCodeCache: TelemetrySourceID = "claude-code-local-cache"
    static let claudeStatusLine: TelemetrySourceID = "claude-code-statusline"
    static let claudeDesktopCache: TelemetrySourceID = "claude-desktop-plan-cache"
    static let codexRollouts: TelemetrySourceID = "codex-rollouts"
}

public extension ProviderRegistry {
    static let builtin: ProviderRegistry = ProviderRegistry(
        providers: [
            ProviderDefinition(id: .anthropic, name: "Anthropic", shortName: "Claude", symbol: "sparkle"),
            ProviderDefinition(id: .openAI, name: "OpenAI", shortName: "OpenAI", symbol: "circle.hexagongrid"),
        ],
        products: [
            ProductDefinition(id: .claudeCode, provider: .anthropic, name: "Claude Code",
                              observability: "Sessions and per-request tokens are observed from local transcripts. Subscription quota is read from Claude Code's local usage cache; the status line is an optional second source."),
            ProductDefinition(id: .claudeChat, provider: .anthropic, name: "Claude Chat and Cowork",
                              observability: "Not observable. These products leave no usage records on this Mac, although they count toward the same subscription.",
                              isObservable: false),
            ProductDefinition(id: .codex, provider: .openAI, name: "Codex",
                              observability: "Sessions, per-request tokens and quota snapshots are observed from Codex's local session files."),
            ProductDefinition(id: .chatGPTWork, provider: .openAI, name: "ChatGPT Work",
                              observability: "Work sessions run on the Codex engine and are observed from the same session files. They share Codex's allowance."),
            ProductDefinition(id: .chatGPTChat, provider: .openAI, name: "ChatGPT Chat",
                              observability: "Not observable. The ChatGPT app keeps a conversation cache but no token or quota records, and chat limits are separate from Codex.",
                              isObservable: false),
        ],
        surfaces: [
            SurfaceDefinition(id: .terminal, name: "Terminal", symbol: "terminal"),
            SurfaceDefinition(id: .vscode, name: "VS Code", symbol: "chevron.left.forwardslash.chevron.right"),
            SurfaceDefinition(id: .jetbrains, name: "JetBrains IDE", symbol: "curlybraces"),
            SurfaceDefinition(id: .claudeDesktop, name: "Claude Desktop", symbol: "macwindow"),
            SurfaceDefinition(id: .codexDesktop, name: "Codex Desktop", symbol: "macwindow"),
            SurfaceDefinition(id: .chatGPTDesktop, name: "ChatGPT Desktop", symbol: "macwindow.badge.plus"),
            SurfaceDefinition(id: .unknown, name: "Unknown", symbol: "questionmark.app"),
        ],
        pools: [
            QuotaPoolDefinition(key: "claude-subscription", provider: .anthropic, name: "Claude subscription",
                                products: [.claudeCode, .claudeChat],
                                note: "One allowance covers Claude Code and Claude chat. Only Claude Code reports it locally.",
                                standardWindowMinutes: [300, 10080]),
            QuotaPoolDefinition(key: "codex", provider: .openAI, name: "Codex and Work",
                                products: [.codex, .chatGPTWork],
                                note: "Codex and ChatGPT Work draw on one shared allowance on the plans that include both.",
                                standardWindowMinutes: [300, 10080]),
            QuotaPoolDefinition(key: "chatgpt-chat", provider: .openAI, name: "ChatGPT Chat limits",
                                products: [.chatGPTChat],
                                note: "Chat has its own limits. They are not observable locally and are never merged into the Codex allowance.",
                                isObservable: false),
        ],
        sources: [
            TelemetrySourceDefinition(
                id: .claudeTranscripts, provider: .anthropic, products: [.claudeCode], kind: .sessionLogs,
                name: "Claude Code transcripts",
                capabilities: [.sessions, .requestTokens, .cacheTokens, .reasoningTokens, .models, .reportedCost, .liveSessionState],
                limitations: "Covers Claude Code only. Claude chat and Cowork usage leaves no local record."),
            TelemetrySourceDefinition(
                id: .claudeCodeCache, provider: .anthropic, products: [.claudeCode], kind: .quotaFeed,
                name: "Claude Code local usage cache",
                capabilities: [.quotaUtilization, .quotaResetTimes],
                limitations: "Read-only snapshot in Claude Code's .claude.json. Claude Code refreshes it when it fetches usage, so it can be stale. Its layout is version-dependent and undocumented; account identity is reduced to a change-detection hash and is not shown."),
            TelemetrySourceDefinition(
                id: .claudeStatusLine, provider: .anthropic, products: [.claudeCode], kind: .quotaFeed,
                name: "Claude Code status line (optional)",
                capabilities: [.quotaUtilization, .quotaResetTimes],
                limitations: "Optional. Updates only while a terminal Claude Code session is in use, and only for subscribers."),
            TelemetrySourceDefinition(
                id: .claudeDesktopCache, provider: .anthropic, products: [.claudeChat, .claudeCode], kind: .quotaFeed,
                name: "Claude Desktop plan cache (undocumented)",
                capabilities: [.quotaUtilization],
                limitations: "Undocumented, unverified, and has no reset times. Shown only when enabled, and never used for alerts."),
            TelemetrySourceDefinition(
                id: .codexRollouts, provider: .openAI, products: [.codex, .chatGPTWork], kind: .sessionLogs,
                name: "Codex session files",
                capabilities: [.sessions, .requestTokens, .cacheTokens, .reasoningTokens, .models, .quotaUtilization, .quotaResetTimes, .accountIdentity],
                limitations: "Quota figures are snapshots written when a request completes, so they go stale between requests. ChatGPT Chat is not covered."),
        ],
        plans: [
            // Reference prices read 2026-10-22. They are editable in the app and are never used to
            // infer capacity. Only the five-hour nominal multipliers are advertised; the weekly
            // multipliers are deliberately absent, because the provider does not state them.
            SubscriptionPlanDefinition(
                key: "claude-pro", provider: .anthropic, name: "Claude Pro",
                monthlyPriceMicros: 20_000_000, priceAsOf: "2026-10-22",
                nominalMultipliers: [300: 1],
                note: "Reference price; verify it before relying on a cost comparison. Nominal five-hour capacity is the baseline for the Max plans."),
            SubscriptionPlanDefinition(
                key: "claude-max-5x", provider: .anthropic, name: "Claude Max 5x",
                monthlyPriceMicros: 100_000_000, priceAsOf: "2026-10-22",
                nominalMultipliers: [300: 5],
                note: "Reference price. The provider advertises a five-hour allowance five times Pro's, but says nothing about the weekly allowance."),
            SubscriptionPlanDefinition(
                key: "claude-max-20x", provider: .anthropic, name: "Claude Max 20x",
                monthlyPriceMicros: 200_000_000, priceAsOf: "2026-10-22",
                nominalMultipliers: [300: 20],
                note: "Reference price. The advertised five-hour multiplier is four times Max 5x's; this is not evidence about weekly capacity."),
        ])
}
