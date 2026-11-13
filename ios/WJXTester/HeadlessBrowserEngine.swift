import Foundation
import WebKit

actor BrowserSubmissionGate {
    private var expectedParticipants: Int
    private var arrivedParticipants = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participants: Int) {
        expectedParticipants = max(0, participants)
    }

    func wait() async {
        arrivedParticipants += 1
        if arrivedParticipants >= expectedParticipants {
            releaseWaiters()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func dropParticipant() {
        expectedParticipants = max(0, expectedParticipants - 1)
        if arrivedParticipants >= expectedParticipants {
            releaseWaiters()
        }
    }

    private func releaseWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class HeadlessBrowserEngine {
    private var workers: [UUID: HeadlessBrowserWorker] = [:]

    func submit(
        id: UUID,
        surveyURL: URL,
        answers: [Int: String],
        dwellSeconds: Int,
        gate: BrowserSubmissionGate
    ) async -> SubmissionOutcome {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                let worker = HeadlessBrowserWorker(
                    surveyURL: surveyURL,
                    answers: answers,
                    dwellSeconds: dwellSeconds,
                    gate: gate
                ) { [weak self] outcome in
                    self?.workers.removeValue(forKey: id)
                    continuation.resume(returning: outcome)
                }
                workers[id] = worker
                worker.start()
                if Task.isCancelled {
                    worker.cancel()
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in
                self?.workers[id]?.cancel()
            }
        })
    }

    func cancelAll() {
        let activeWorkers = Array(workers.values)
        activeWorkers.forEach { $0.cancel() }
    }
}

@MainActor
private final class HeadlessBrowserWorker: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let surveyURL: URL
    private let answers: [Int: String]
    private let dwellSeconds: Int
    private let gate: BrowserSubmissionGate
    private var completion: ((SubmissionOutcome) -> Void)?
    private var webView: WKWebView!
    private var didPrepareForm = false
    private var didSubmit = false
    private var didJoinGate = false
    private var isFinished = false
    private var submitTask: Task<Void, Never>?
    private var probeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(
        surveyURL: URL,
        answers: [Int: String],
        dwellSeconds: Int,
        gate: BrowserSubmissionGate,
        completion: @escaping (SubmissionOutcome) -> Void
    ) {
        self.surveyURL = surveyURL
        self.answers = answers
        self.dwellSeconds = dwellSeconds
        self.gate = gate
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
        webView.uiDelegate = self
    }

    func start() {
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.finish(.failure("隐藏浏览器等待结果超时"))
        }
        webView.load(URLRequest(url: surveyURL))
    }

    func cancel() {
        finish(.failure("已取消"))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isFinished else { return }
        if let outcome = successOutcome(from: webView.url) {
            finish(outcome)
            return
        }
        guard !didPrepareForm else { return }
        didPrepareForm = true
        submitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self, !self.isFinished else { return }
            self.prepareAndScheduleSubmission()
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure("隐藏浏览器加载失败：\(error.localizedDescription)"))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        finish(.failure("隐藏浏览器连接失败：\(error.localizedDescription)"))
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        completionHandler()
        if didSubmit && !message.isEmpty {
            finish(.failure(message))
        }
    }

    private func prepareAndScheduleSubmission() {
        let answersJSON = javascriptObject(answers)
        let fillScript = """
        (() => {
          const answers = \(answersJSON);
          const missing = [];
          Object.entries(answers).forEach(([topic, value]) => {
            const element = document.getElementById(`q${topic}`);
            if (!element) {
              missing.push(topic);
              return;
            }
            element.focus();
            element.value = value;
            element.dispatchEvent(new Event('input', { bubbles: true }));
            element.dispatchEvent(new Event('change', { bubbles: true }));
            element.blur();
          });
          return missing.length ? `missing:${missing.join(',')}` : 'ready';
        })();
        """

        webView.evaluateJavaScript(fillScript) { [weak self] result, error in
            guard let self, !self.isFinished else { return }
            if let error {
                self.finish(.failure("填写问卷失败：\(error.localizedDescription)"))
                return
            }
            if let result = result as? String, result.hasPrefix("missing:") {
                let topics = result.replacingOccurrences(of: "missing:", with: "")
                self.finish(.failure("问卷中未找到题号：\(topics)"))
                return
            }
            self.submitTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(
                    nanoseconds: UInt64(max(1, self.dwellSeconds)) * 1_000_000_000
                )
                guard !Task.isCancelled, !self.isFinished else { return }
                self.didJoinGate = true
                await self.gate.wait()
                guard !Task.isCancelled, !self.isFinished else { return }
                self.clickSubmit()
            }
        }
    }

    private func clickSubmit() {
        didSubmit = true
        let script = """
        (() => {
          const button = document.querySelector('#ctlNext, button[type="submit"], input[type="submit"]');
          if (!button) return 'missing-submit';
          button.click();
          return 'clicked';
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
            guard let self, !self.isFinished else { return }
            if let error {
                self.finish(.failure("点击提交失败：\(error.localizedDescription)"))
                return
            }
            if result as? String == "missing-submit" {
                self.finish(.failure("问卷页面未找到提交按钮"))
                return
            }
            self.startProbingResult()
        }
    }

    private func startProbingResult() {
        probeTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<75 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !self.isFinished else { return }
                if let outcome = self.successOutcome(from: self.webView.url) {
                    self.finish(outcome)
                    return
                }
                await self.probePageState()
            }
        }
    }

    private func probePageState() async {
        let script = """
        (() => {
          const error = document.querySelector('#ValError')?.innerText?.trim() || '';
          if (error && !error.includes('提交')) return `error:${error}`;
          const selectors = [
            '#SM_BTN_WRAPPER', '.sm-pop-inner', '.nc-container',
            '[id*="captcha"]', '[class*="captcha"]'
          ];
          const captchaVisible = selectors.some(selector =>
            Array.from(document.querySelectorAll(selector)).some(element =>
              element.offsetParent !== null && getComputedStyle(element).visibility !== 'hidden'
            )
          );
          return captchaVisible ? 'captcha' : 'waiting';
        })();
        """
        do {
            let state = try await webView.evaluateJavaScript(script) as? String ?? "waiting"
            if state == "captcha" {
                finish(.verificationRequired("隐藏浏览器遇到安全验证"))
            } else if state.hasPrefix("error:") {
                finish(.failure(String(state.dropFirst("error:".count))))
            }
        } catch {
            finish(.failure("读取提交状态失败：\(error.localizedDescription)"))
        }
    }

    private func successOutcome(from url: URL?) -> SubmissionOutcome? {
        guard let url, url.absoluteString.lowercased().contains("complete") else {
            return nil
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: true)
        let answerNumber = components?.queryItems?
            .first(where: { $0.name == "sojumpindex" })?.value
        return .success(answerNumber: answerNumber, resultURL: url)
    }

    private func javascriptObject(_ answers: [Int: String]) -> String {
        let object = Dictionary(uniqueKeysWithValues: answers.map { (String($0.key), $0.value) })
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private func finish(_ outcome: SubmissionOutcome) {
        guard !isFinished else { return }
        isFinished = true
        submitTask?.cancel()
        probeTask?.cancel()
        timeoutTask?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        if !didJoinGate {
            didJoinGate = true
            let gate = gate
            Task { await gate.dropParticipant() }
        }
        let callback = completion
        completion = nil
        callback?(outcome)
    }
}
