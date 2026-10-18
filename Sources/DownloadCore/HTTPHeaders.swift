import Foundation

public enum HTTPHeaders {
    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" // l10n-ignore

    /// Headers the engine owns; callers (browser extensions) may not override them.
    private static let reserved: Set<String> = [
        "host", "range", "if-range", "content-length", "accept-encoding", "connection", "transfer-encoding",
    ]

    /// Applies caller headers after stripping CR/LF (header injection) and engine-owned fields,
    /// then pins `Accept-Encoding: identity`.
    ///
    /// The identity pin matters: URLSession advertises gzip/br by default and transparently
    /// decompresses, which makes `Content-Length` and byte ranges refer to *compressed* bytes.
    static func apply(_ headers: [String: String], to request: inout URLRequest) {
        for (name, value) in headers {
            let cleanName = sanitize(name)
            guard !cleanName.isEmpty, !reserved.contains(cleanName.lowercased()) else { continue }
            let cleanValue = sanitize(value)
            guard !cleanValue.isEmpty else { continue }
            request.setValue(cleanValue, forHTTPHeaderField: cleanName)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    static func sanitize(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" && $0 != "\0" })
            .trimmingCharacters(in: .whitespaces)
    }
}
