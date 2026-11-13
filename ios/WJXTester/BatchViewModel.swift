import Foundation
import Combine
import UIKit

enum RosterMode: String, CaseIterable, Identifiable, Sendable {
    case name = "姓名"
    case employeeID = "工号"
    case email = "邮箱"

    var id: Self { self }

    var defaultTopic: Int {
        switch self {
        case .name: return 2
        case .employeeID: return 1
        case .email: return 3
        }
    }

    var placeholder: String {
        switch self {
        case .name: return "张三\n李四"
        case .employeeID: return "100001\n100002"
        case .email: return "test001@example.com\ntest002@example.com"
        }
    }

    var keyboardType: UIKeyboardType {
        switch self {
        case .email: return .emailAddress
        case .name, .employeeID: return .default
        }
    }
}

enum BatchStartMode: String, CaseIterable, Identifiable {
    case immediate = "立即"
    case scheduled = "定时"

    var id: Self { self }
}

enum BatchLogLevel {
    case info
    case success
    case warning
    case error
}

struct BatchLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let level: BatchLogLevel
    let message: String
}

struct BatchEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let value: String
    let mode: RosterMode
    let topic: Int
}

enum BatchEntryState: Equatable, Sendable {
    case queued
    case running
    case success(String?)
    case verificationRequired(String)
    case failed(String)
    case cancelled

    var isFinished: Bool {
        switch self {
        case .queued, .running:
            return false
        case .success, .verificationRequired, .failed, .cancelled:
            return true
        }
    }
}

struct BatchItem: Identifiable, Equatable {
    let entry: BatchEntry
    var state: BatchEntryState

    var id: UUID { entry.id }
}

private enum BatchExecutionResult: Sendable {
    case outcome(SubmissionOutcome)
    case failed(String)
    case cancelled
}

private struct BatchCompletion: Sendable {
    let id: UUID
    let result: BatchExecutionResult
}

private enum BatchInputError: LocalizedError {
    case empty
    case tooMany(Int)
    case invalidLine(Int, String)

    var errorDescription: String? {
        switch self {
        case .empty:
            return "请先输入名单。"
        case .tooMany(let count):
            return "当前有 \(count) 条，单次最多处理 500 条。"
        case .invalidLine(let line, let reason):
            return "第 \(line) 行格式错误：\(reason)"
        }
    }
}

@MainActor
final class BatchViewModel: ObservableObject {
    @Published var surveyURLString: String {
        didSet { UserDefaults.standard.set(surveyURLString, forKey: "surveyURL") }
    }
    @Published var rawList = ""
    @Published var rosterMode = RosterMode.name {
        didSet {
            topicNumber = rosterMode.defaultTopic
            items = []
            errorMessage = nil
        }
    }
    @Published var topicNumber = RosterMode.name.defaultTopic
    @Published var startMode = BatchStartMode.immediate {
        didSet {
            if startMode == .scheduled && scheduledDate <= Date().addingTimeInterval(1) {
                scheduledDate = Date().addingTimeInterval(5 * 60)
            }
        }
    }
    @Published var scheduledDate = Date().addingTimeInterval(5 * 60)
    @Published private(set) var scheduledAt: Date?
    @Published var dwellSeconds = 6
    @Published var concurrency = 3
    @Published var isAuthorized = false
    @Published var isRunning = false
    @Published var showsConfirmation = false
    @Published var items: [BatchItem] = []
    @Published private(set) var logs: [BatchLogEntry] = []
    @Published var errorMessage: String?

    private let service = SurveyService()
    private var executionTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        surveyURLString = UserDefaults.standard.string(forKey: "surveyURL")
            ?? SurveyTarget.defaultURLString
    }

    var surveyURL: URL? {
        SurveyTarget.parse(surveyURLString)
    }

    func reloadSurveyURL() {
        guard !isRunning,
              let saved = UserDefaults.standard.string(forKey: "surveyURL"),
              saved != surveyURLString else { return }
        surveyURLString = saved
    }

    var inputCount: Int {
        normalizedLines.count
    }

    var completedCount: Int {
        items.filter { $0.state.isFinished }.count
    }

    var successCount: Int {
        items.filter {
            if case .success = $0.state { return true }
            return false
        }.count
    }

    var canStart: Bool {
        surveyURL != nil
            && inputCount > 0 && inputCount <= 500
            && (1...200).contains(topicNumber)
            && isAuthorized && !isRunning
    }

    var isWaitingForSchedule: Bool {
        isRunning && scheduledAt != nil
    }

    func loadExample() {
        rawList = (1...10).map { index in
            switch rosterMode {
            case .name:
                return "测试\(String(format: "%03d", index))"
            case .employeeID:
                return String(100_000 + index)
            case .email:
                return "test\(String(format: "%03d", index))@example.com"
            }
        }.joined(separator: "\n")
        items = []
        errorMessage = nil
    }

    func clear() {
        guard !isRunning else { return }
        rawList = ""
        items = []
        errorMessage = nil
    }

    func clearLogs() {
        logs = []
    }

    func requestStart() {
        guard canStart else { return }
        if startMode == .scheduled && scheduledDate <= Date().addingTimeInterval(1) {
            errorMessage = "定时时间必须晚于当前时间。"
            appendLog(.warning, errorMessage ?? "定时时间无效")
            return
        }
        do {
            _ = try parseEntries()
            errorMessage = nil
            showsConfirmation = true
        } catch {
            errorMessage = error.localizedDescription
            appendLog(.error, error.localizedDescription)
        }
    }

    func start() {
        guard canStart else { return }
        if startMode == .scheduled && scheduledDate <= Date() {
            errorMessage = "定时时间已过，请重新选择。"
            appendLog(.warning, errorMessage ?? "定时时间已过")
            return
        }
        guard let selectedSurveyURL = surveyURL else {
            errorMessage = "请输入有效的 HTTPS 问卷地址。"
            appendLog(.error, errorMessage ?? "问卷地址无效")
            return
        }
        let entries: [BatchEntry]
        do {
            entries = try parseEntries()
        } catch {
            errorMessage = error.localizedDescription
            appendLog(.error, error.localizedDescription)
            return
        }

        items = entries.map { BatchItem(entry: $0, state: .queued) }
        errorMessage = nil
        isRunning = true

        let selectedConcurrency = concurrency
        let selectedDwell = dwellSeconds
        if startMode == .scheduled {
            let fireDate = scheduledDate
            scheduledAt = fireDate
            appendLog(
                .info,
                "已设置定时任务：\(entries.count) 条，计划 \(fireDate.formatted(date: .abbreviated, time: .shortened)) 开始"
            )
            executionTask = Task { [weak self] in
                guard let self else { return }
                let delay = max(0, fireDate.timeIntervalSinceNow)
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                scheduledAt = nil
                appendLog(.info, "定时时间已到，开始提交")
                beginBackgroundExecution()
                await run(
                    entries: entries,
                    surveyURL: selectedSurveyURL,
                    concurrency: selectedConcurrency,
                    dwellSeconds: selectedDwell
                )
            }
            return
        }

        scheduledAt = nil
        appendLog(.info, "开始批量提交：\(entries.count) 条，并发 \(selectedConcurrency)")
        beginBackgroundExecution()
        executionTask = Task { [weak self] in
            guard let self else { return }
            await run(
                entries: entries,
                surveyURL: selectedSurveyURL,
                concurrency: selectedConcurrency,
                dwellSeconds: selectedDwell
            )
        }
    }

    func cancel() {
        appendLog(.warning, isWaitingForSchedule ? "定时任务已取消" : "已请求停止运行任务")
        executionTask?.cancel()
        if scheduledAt != nil {
            for index in items.indices where !items[index].state.isFinished {
                items[index].state = .cancelled
            }
            scheduledAt = nil
            isRunning = false
            executionTask = nil
        }
    }

    private func run(
        entries: [BatchEntry],
        surveyURL: URL,
        concurrency: Int,
        dwellSeconds: Int
    ) async {
        await withTaskGroup(of: BatchCompletion.self) { group in
            var nextIndex = 0
            let initialCount = min(concurrency, entries.count)

            for _ in 0..<initialCount {
                let entry = entries[nextIndex]
                nextIndex += 1
                mark(entry.id, as: .running)
                appendLog(.info, "\(entry.mode.rawValue) \(entry.value)：开始提交")
                add(entry, surveyURL: surveyURL, dwellSeconds: dwellSeconds, to: &group)
            }

            while let completion = await group.next() {
                apply(completion)

                if Task.isCancelled {
                    group.cancelAll()
                    continue
                }

                if nextIndex < entries.count {
                    let entry = entries[nextIndex]
                    nextIndex += 1
                    mark(entry.id, as: .running)
                    appendLog(.info, "\(entry.mode.rawValue) \(entry.value)：开始提交")
                    add(entry, surveyURL: surveyURL, dwellSeconds: dwellSeconds, to: &group)
                }
            }
        }

        if Task.isCancelled {
            let responseCount = items.filter {
                switch $0.state {
                case .success, .verificationRequired, .failed:
                    return true
                case .queued, .running, .cancelled:
                    return false
                }
            }.count
            for index in items.indices where !items[index].state.isFinished {
                items[index].state = .cancelled
            }
            appendLog(
                .warning,
                "任务已停止：收到响应 \(responseCount) / \(items.count)，成功 \(successCount)"
            )
        } else {
            appendLog(.success, "批量任务完成：成功 \(successCount) / \(items.count)")
        }
        isRunning = false
        scheduledAt = nil
        executionTask = nil
        endBackgroundExecution()
    }

    private func add(
        _ entry: BatchEntry,
        surveyURL: URL,
        dwellSeconds: Int,
        to group: inout TaskGroup<BatchCompletion>
    ) {
        let service = service
        group.addTask {
            if Task.isCancelled {
                return BatchCompletion(id: entry.id, result: .cancelled)
            }
            do {
                let outcome = try await service.submit(
                    surveyURL: surveyURL,
                    answers: [entry.topic: entry.value],
                    identityValue: entry.mode == .name ? entry.value : nil,
                    dwellSeconds: dwellSeconds
                )
                return BatchCompletion(id: entry.id, result: .outcome(outcome))
            } catch is CancellationError {
                return BatchCompletion(id: entry.id, result: .cancelled)
            } catch {
                return BatchCompletion(id: entry.id, result: .failed(error.localizedDescription))
            }
        }
    }

    private func apply(_ completion: BatchCompletion) {
        let entry = items.first(where: { $0.id == completion.id })?.entry
        let prefix = entry.map { "\($0.mode.rawValue) \($0.value)" } ?? "记录"
        switch completion.result {
        case .outcome(.success(let answerNumber, _)):
            mark(completion.id, as: .success(answerNumber))
            let suffix = answerNumber.map { "，答卷号 \($0)" } ?? ""
            appendLog(.success, "\(prefix)：提交成功\(suffix)")
        case .outcome(.verificationRequired(let message)):
            mark(completion.id, as: .verificationRequired(message))
            appendLog(.warning, "\(prefix)：需要安全验证，\(message)")
        case .outcome(.failure(let message)), .failed(let message):
            mark(completion.id, as: .failed(message))
            appendLog(.error, "\(prefix)：提交失败，\(message)")
        case .cancelled:
            mark(completion.id, as: .cancelled)
            appendLog(.warning, "\(prefix)：已取消")
        }
    }

    private func appendLog(_ level: BatchLogLevel, _ message: String) {
        logs.insert(
            BatchLogEntry(timestamp: Date(), level: level, message: message),
            at: 0
        )
        if logs.count > 500 {
            logs.removeLast(logs.count - 500)
        }
    }

    private func mark(_ id: UUID, as state: BatchEntryState) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
    }

    private var normalizedLines: [String] {
        rawList
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseEntries() throws -> [BatchEntry] {
        let lines = normalizedLines
        guard !lines.isEmpty else { throw BatchInputError.empty }
        guard lines.count <= 500 else { throw BatchInputError.tooMany(lines.count) }

        var usedValues = Set<String>()
        var entries: [BatchEntry] = []

        for (offset, line) in lines.enumerated() {
            let lineNumber = offset + 1
            guard line.count <= 254 else {
                throw BatchInputError.invalidLine(lineNumber, "内容过长")
            }
            if rosterMode == .email && !isValidEmail(line) {
                throw BatchInputError.invalidLine(lineNumber, "邮箱格式无效")
            }
            let duplicateKey = rosterMode == .email ? line.lowercased() : line
            guard usedValues.insert(duplicateKey).inserted else {
                throw BatchInputError.invalidLine(lineNumber, "\(rosterMode.rawValue)重复")
            }
            entries.append(
                BatchEntry(id: UUID(), value: line, mode: rosterMode, topic: topicNumber)
            )
        }
        return entries
    }

    private func isValidEmail(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix(".") else {
            return false
        }
        return true
    }

    private func beginBackgroundExecution() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Batch survey submission") {
            Task { @MainActor [weak self] in
                self?.appendLog(.warning, "系统后台执行时间已用尽，任务即将停止")
                self?.cancel()
            }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
