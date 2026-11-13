import Foundation

enum SubmissionOutcome: Equatable, Sendable {
    case success(answerNumber: String?, resultURL: URL?)
    case verificationRequired(String)
    case failure(String)
}

enum SurveyError: LocalizedError {
    case invalidResponse
    case missingPageValue(String)
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回了无法识别的响应。"
        case .missingPageValue(let name):
            return "问卷页面缺少必要参数：\(name)。"
        case .invalidURL:
            return "无法生成提交地址。"
        }
    }
}

actor SurveyService {
    static let surveyID = "tghWxdt"
    static let pageURL = URL(string: "https://v.wjx.cn/vm/\(surveyID).aspx")!

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 30
        configuration.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9",
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
        ]
        return URLSession(configuration: configuration)
    }

    func submit(employeeID: String, name: String, dwellSeconds: Int) async throws -> SubmissionOutcome {
        let session = makeSession()
        let startedAt = Date()
        let (pageData, pageResponse) = try await session.data(from: Self.pageURL)
        guard let httpResponse = pageResponse as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode,
              let html = String(data: pageData, encoding: .utf8) else {
            throw SurveyError.invalidResponse
        }

        let startTime = try requiredMatch(
            in: html,
            pattern: #"<input[^>]*\bid=["']starttime["'][^>]*>"#,
            attribute: "value",
            name: "starttime"
        )
        let nonce = try requiredCapture(
            in: html,
            pattern: #"(?:var\s+)?jqnonce\s*=\s*["']([^"']+)"#,
            name: "jqnonce"
        )
        let randomNumber = try requiredCapture(
            in: html,
            pattern: #"(?:var\s+)?rndnum\s*=\s*["']([^"']+)"#,
            name: "rndnum"
        )
        let newAward = capture(
            in: html,
            pattern: #"(?:var\s+)?newAward\s*=\s*["']?([^;"'\s]+)"#
        ) ?? "1"
        let sceneID = capture(
            in: html,
            pattern: #"captchaSceneid\s*=\s*["']([^"']+)"#
        ) ?? "q0hcfsca"

        let elapsed = Date().timeIntervalSince(startedAt)
        let remainingDelay = max(0, Double(dwellSeconds) - elapsed)
        if remainingDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(remainingDelay * 1_000_000_000))
        }

        let interactionCount = Int.random(in: 3...6)
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let answers = "1$\(sanitize(employeeID))}2$\(sanitize(name))"
        let parameters: [(String, String)] = [
            ("starttime", startTime),
            ("cst", String(now)),
            ("submittype", "1"),
            ("ktimes", String(interactionCount)),
            ("rn", randomNumber),
            ("jcn", dataEnc(name, key: interactionCount)),
            ("nw", newAward),
            ("jwt", "4"),
            ("jpm", "70"),
            ("capt", "2"),
            ("t", String(now + Int64.random(in: 1...9))),
            ("wxfs", "100"),
            ("jqnonce", nonce),
            ("jqsign", dataEnc(nonce, key: interactionCount))
        ]

        let query = parameters
            .map { "\($0.0)=\(encodeURIComponent($0.1))" }
            .joined(separator: "&")
        guard let submitURL = URL(
            string: "https://v.wjx.cn/joinnew/processjq.ashx?shortid=\(Self.surveyID)&\(query)"
        ) else {
            throw SurveyError.invalidURL
        }

        var request = URLRequest(url: submitURL)
        request.httpMethod = "POST"
        request.setValue(Self.pageURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://v.wjx.cn", forHTTPHeaderField: "Origin")
        request.setValue("text/plain, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(
            "application/x-www-form-urlencoded; charset=UTF-8",
            forHTTPHeaderField: "Content-Type"
        )
        let body = "submitdata=\(encodeURIComponent(answers))&sceneId=\(encodeURIComponent(sceneID))"
        request.httpBody = body.data(using: .utf8)

        let (responseData, response) = try await session.data(for: request)
        guard let submitResponse = response as? HTTPURLResponse,
              let text = String(data: responseData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SurveyError.invalidResponse
        }
        guard 200..<300 ~= submitResponse.statusCode else {
            return .failure("HTTP \(submitResponse.statusCode)：\(text)")
        }

        let parts = text.components(separatedBy: "〒")
        let code = parts.first ?? ""
        let detail = parts.dropFirst().joined(separator: "〒")
        if code == "10" {
            let resultURL = URL(string: detail, relativeTo: Self.pageURL)?.absoluteURL
            return .success(answerNumber: queryValue("sojumpindex", in: resultURL), resultURL: resultURL)
        }
        if code == "7" || code == "22" {
            return .verificationRequired(detail.isEmpty ? "需要在浏览器内完成安全验证。" : detail)
        }
        return .failure(detail.isEmpty ? text : detail)
    }

    private func requiredCapture(in text: String, pattern: String, name: String) throws -> String {
        guard let value = capture(in: text, pattern: pattern) else {
            throw SurveyError.missingPageValue(name)
        }
        return value
    }

    private func capture(in text: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private func requiredMatch(
        in text: String,
        pattern: String,
        attribute: String,
        name: String
    ) throws -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..., in: text)
              ),
              let tagRange = Range(match.range, in: text) else {
            throw SurveyError.missingPageValue(name)
        }
        let tag = String(text[tagRange])
        let escapedAttribute = NSRegularExpression.escapedPattern(for: attribute)
        let attributePattern = escapedAttribute + #"\s*=\s*["']([^"']*)"#
        guard let value = capture(in: tag, pattern: attributePattern) else {
            throw SurveyError.missingPageValue(name)
        }
        return value
    }

    private func sanitize(_ value: String) -> String {
        let replacements: [(String, String)] = [
            ("$", "ξ"), ("}", "｝"), ("^", "ˆ"), ("|", "¦"), ("!", "！"), ("<", "＜")
        ]
        return replacements.reduce(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            $0.replacingOccurrences(of: $1.0, with: $1.1)
        }
    }

    private func dataEnc(_ value: String, key: Int) -> String {
        let xorKey = UInt16(key % 10 == 0 ? 1 : key % 10)
        let scalars = value.utf16.compactMap { UnicodeScalar(Int($0 ^ xorKey)) }
        return String(scalars.map(Character.init))
    }

    private func encodeURIComponent(_ value: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
        )
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func queryValue(_ name: String, in url: URL?) -> String? {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}
