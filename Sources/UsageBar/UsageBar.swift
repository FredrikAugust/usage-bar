import SwiftUI

struct Window { var used: Double; var resetsAt: Date? }
struct Usage { var session: Window?; var week: Window? }

@main
struct UsageBarApp: App {
    @State private var model = Model()

    init() { NSApplication.shared.setActivationPolicy(.accessory) }

    var body: some Scene {
        MenuBarExtra {
            row("Claude", model.claude)
            row("Codex", model.codex)
            Divider()
            Button("Refresh") { Task { await model.refresh() } }.keyboardShortcut("r")
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: icon(model.claude, model.codex))
        }
    }

    @ViewBuilder func row(_ name: String, _ result: Result<Usage, Error>?) -> some View {
        switch result {
        case nil: Text("\(name): loading…")
        case .failure(let e): Text("\(name): \(e.localizedDescription)")
        case .success(let u):
            if let s = u.session { Text("\(name) 5h: \(left(s))") }
            if let w = u.week { Text("\(name) week: \(left(w))") }
        }
    }

    func left(_ w: Window) -> String {
        let reset = w.resetsAt.map { d in
            " · resets " + d.formatted(Calendar.current.isDateInToday(d) ? .dateTime.hour().minute() : .dateTime.weekday().hour().minute())
        } ?? ""
        return "\(Int(100 - w.used))% left\(reset)"
    }
}

/// Two stacked bars, Claude on top, Codex below; fill = share of the 5h window left (week if there is no 5h limit).
@MainActor func icon(_ top: Result<Usage, Error>?, _ bottom: Result<Usage, Error>?) -> NSImage {
    func bar(_ r: Result<Usage, Error>?, _ color: Color) -> some View {
        let w = (try? r?.get()).flatMap { $0.session ?? $0.week }
        let left = w.map { max(0, 1 - $0.used / 100) } ?? 0
        return ZStack(alignment: .leading) {
            Capsule().fill(color.opacity(0.3))
            Capsule().fill(color).frame(width: 22 * left)
        }
        .frame(width: 22, height: 5)
    }
    // Not a template image, so the colours survive; both read on light and dark menu bars.
    let renderer = ImageRenderer(content: VStack(spacing: 3) {
        bar(top, Color(red: 0.85, green: 0.47, blue: 0.34)) // Claude orange
        bar(bottom, Color(red: 0.25, green: 0.6, blue: 1)) // Codex blue
    })
    renderer.scale = 2
    return renderer.nsImage ?? NSImage()
}

@MainActor @Observable final class Model {
    var claude: Result<Usage, Error>?
    var codex: Result<Usage, Error>?

    init() {
        Task {
            while true {
                await refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    func refresh() async {
        async let c = capture(fetchClaude)
        async let x = capture(fetchCodex)
        (claude, codex) = await (c, x)
    }
}

func capture(_ f: () async throws -> Usage) async -> Result<Usage, Error> {
    do { return .success(try await f()) } catch { return .failure(error) }
}

// MARK: Claude — reuses Claude Code's OAuth token from the login keychain.

struct ClaudeCreds: Decodable { struct O: Decodable { let accessToken: String }; let claudeAiOauth: O }
struct ClaudeUsage: Decodable {
    struct W: Decodable { let utilization: Double?; let resets_at: String? }
    let five_hour: W?, seven_day: W?
}

func fetchClaude() async throws -> Usage {
    let creds = try JSONDecoder().decode(ClaudeCreds.self, from: run("/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"))
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(creds.claudeAiOauth.accessToken)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let u = try await get(ClaudeUsage.self, req)
    func w(_ w: ClaudeUsage.W?) -> Window {
        // resets_at has microseconds, which ISO8601DateFormatter can't parse.
        Window(used: w?.utilization ?? 0, resetsAt: w?.resets_at.flatMap { ISO8601DateFormatter().date(from: $0.replacing(/\.\d+/, with: "")) })
    }
    return Usage(session: w(u.five_hour), week: w(u.seven_day))
}

// MARK: Codex — reuses the ChatGPT token from ~/.codex/auth.json.

struct CodexAuth: Decodable { struct T: Decodable { let access_token: String; let account_id: String? }; let tokens: T }
struct CodexUsage: Decodable {
    struct W: Decodable { let used_percent: Double; let reset_at: Double?; let limit_window_seconds: Double }
    struct RL: Decodable { let primary_window: W?; let secondary_window: W? }
    let rate_limit: RL?
}

func fetchCodex() async throws -> Usage {
    let path = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
    let auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: path)).tokens
    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
    req.setValue("Bearer \(auth.access_token)", forHTTPHeaderField: "Authorization")
    req.setValue(auth.account_id, forHTTPHeaderField: "ChatGPT-Account-Id")
    let u = try await get(CodexUsage.self, req)
    // primary/secondary aren't fixed to 5h/week: some plans only get a weekly limit, sent as primary.
    let windows = [u.rate_limit?.primary_window, u.rate_limit?.secondary_window].compactMap { $0 }
    func w(_ match: (Double) -> Bool) -> Window? {
        windows.first { match($0.limit_window_seconds) }.map { Window(used: $0.used_percent, resetsAt: $0.reset_at.map { Date(timeIntervalSince1970: $0) }) }
    }
    return Usage(session: w { $0 < 86400 }, week: w { $0 >= 86400 })
}

// MARK: Helpers

struct Failure: LocalizedError { let errorDescription: String? }

func get<T: Decodable>(_: T.Type, _ req: URLRequest) async throws -> T {
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw Failure(errorDescription: "HTTP \(code)") }
    return try JSONDecoder().decode(T.self, from: data)
}

func run(_ cmd: String, _ args: String...) throws -> Data {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: cmd)
    p.arguments = args
    p.standardOutput = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure(errorDescription: "\(cmd) exited \(p.terminationStatus)") }
    return data
}
