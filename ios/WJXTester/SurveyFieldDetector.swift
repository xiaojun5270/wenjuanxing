import Foundation
import WebKit

struct DetectedSurveyField: Codable, Equatable, Sendable {
    let topic: Int
    let title: String
}

private enum SurveyFieldDetectionError: LocalizedError {
    case invalidResult
    case noFields
    case timedOut

    var errorDescription: String? {
        switch self {
        case .invalidResult:
            return "无法解析问卷字段。"
        case .noFields:
            return "问卷页面中没有找到可识别的题目。"
        case .timedOut:
            return "读取问卷字段超时。"
        }
    }
}

@MainActor
final class SurveyFieldDetector {
    private var workers: [UUID: SurveyFieldDetectionWorker] = [:]

    func detect(url: URL) async throws -> [DetectedSurveyField] {
        let workerID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let worker = SurveyFieldDetectionWorker(url: url) { [weak self] result in
                    self?.workers.removeValue(forKey: workerID)
                    continuation.resume(with: result)
                }
                workers[workerID] = worker
                worker.start()
                if Task.isCancelled {
                    worker.cancel()
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.workers[workerID]?.cancel()
            }
        })
    }
}

@MainActor
private final class SurveyFieldDetectionWorker: NSObject, WKNavigationDelegate {
    private let url: URL
    private var completion: ((Result<[DetectedSurveyField], Error>) -> Void)?
    private var webView: WKWebView!
    private var isFinished = false
    private var detectionTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        url: URL,
        completion: @escaping (Result<[DetectedSurveyField], Error>) -> Void
    ) {
        self.url = url
        self.completion = completion
        super.init()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(
            frame: CGRect(x: -10_000, y: -10_000, width: 390, height: 844),
            configuration: configuration
        )
        webView.navigationDelegate = self
    }

    func start() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(.failure(SurveyFieldDetectionError.timedOut))
        }
        webView.load(URLRequest(url: url))
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isFinished, detectionTask == nil else { return }
        detectionTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, !self.isFinished else { return }
            await self.readFields()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure(error))
    }

    private func readFields() async {
        let script = """
        (() => {
          const fields = Array.from(document.querySelectorAll('div.field[topic]'))
            .map(field => {
              const topic = Number(field.getAttribute('topic'));
              const label = field.querySelector('.topichtml, .field-label, .topic') || field;
              const title = (label.innerText || label.textContent || '')
                .replace(/\\s+/g, ' ')
                .trim();
              return { topic, title };
            })
            .filter(field => Number.isInteger(field.topic) && field.topic > 0 && field.title);
          return JSON.stringify(fields);
        })();
        """

        do {
            guard let json = try await webView.evaluateJavaScript(script) as? String,
                  let data = json.data(using: .utf8) else {
                finish(.failure(SurveyFieldDetectionError.invalidResult))
                return
            }
            let fields = try JSONDecoder().decode([DetectedSurveyField].self, from: data)
            guard !fields.isEmpty else {
                finish(.failure(SurveyFieldDetectionError.noFields))
                return
            }
            finish(.success(fields))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<[DetectedSurveyField], Error>) {
        guard !isFinished else { return }
        isFinished = true
        detectionTask?.cancel()
        timeoutTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        let callback = completion
        completion = nil
        callback?(result)
    }
}
