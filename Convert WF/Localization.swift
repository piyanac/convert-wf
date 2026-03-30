import Foundation

enum L10n {
    static func tr(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), locale: Locale.current, arguments: arguments)
    }

    static func number(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .none)
    }

    static func ffmpegFailureMessage(_ detail: String) -> String {
        format("ffmpeg.error.conversion_failed", detail)
    }

    static func ffmpegFailurePrefix() -> String {
        format("ffmpeg.error.conversion_failed", "__DETAIL__")
            .replacingOccurrences(of: "__DETAIL__", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func trimFFmpegFailureDetail(from message: String) -> String {
        var trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = ffmpegFailurePrefix()

        if trimmed.hasPrefix(prefix) {
            trimmed.removeFirst(prefix.count)
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }
}
