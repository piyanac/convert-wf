import AVFoundation
import Foundation
import UniformTypeIdentifiers

enum WorkflowStep: Int, CaseIterable, Identifiable {
    case source
    case files
    case config
    case progress
    case result

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .source:
            return L10n.tr("workflow.step.import")
        case .files:
            return L10n.tr("workflow.step.files")
        case .config:
            return L10n.tr("workflow.step.config")
        case .progress:
            return L10n.tr("workflow.step.converting")
        case .result:
            return L10n.tr("workflow.step.result")
        }
    }
}

enum ConfigMode: String, CaseIterable, Identifiable {
    case preset
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preset:
            return L10n.tr("config.mode.preset")
        case .manual:
            return L10n.tr("config.mode.manual")
        }
    }
}

struct FFmpegParameters {
    let container: String
    let videoCodec: String
    let audioCodec: String
    let resolution: String
}

struct PersistedConversionSettings: Codable {
    let container: String
    let videoCodec: String
    let audioCodec: String
    let resolution: String
    let selectedPresetRawValue: String
}

struct RecentConversionRecord: Codable, Identifiable {
    let id: UUID
    let outputPath: String
    let displayName: String
    let completedAt: Date
    let summaryText: String

    init(id: UUID = UUID(), outputPath: String, displayName: String, completedAt: Date, summaryText: String) {
        self.id = id
        self.outputPath = outputPath
        self.displayName = displayName
        self.completedAt = completedAt
        self.summaryText = summaryText
    }

    var outputURL: URL {
        URL(fileURLWithPath: outputPath)
    }
}

struct BatchConversionResult {
    let totalCount: Int
    let successCount: Int
    let completedCount: Int
    let failureMessages: [String]
    let wasCancelled: Bool

    var failureCount: Int {
        failureMessages.count
    }
}

enum ConversionPreset: String, CaseIterable, Identifiable {
    case highCompatibilityMP4
    case highCompressionHEVC
    case originalCopy
    case socialShare1080p
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highCompatibilityMP4:
            return L10n.tr("preset.high_compatibility.name")
        case .highCompressionHEVC:
            return L10n.tr("preset.high_compression.name")
        case .originalCopy:
            return L10n.tr("preset.original_copy.name")
        case .socialShare1080p:
            return L10n.tr("preset.social_share.name")
        case .custom:
            return L10n.tr("preset.custom.name")
        }
    }

    var description: String {
        switch self {
        case .highCompatibilityMP4:
            return L10n.tr("preset.high_compatibility.description")
        case .highCompressionHEVC:
            return L10n.tr("preset.high_compression.description")
        case .originalCopy:
            return L10n.tr("preset.original_copy.description")
        case .socialShare1080p:
            return L10n.tr("preset.social_share.description")
        case .custom:
            return L10n.tr("preset.custom.description")
        }
    }

    var container: String {
        switch self {
        case .highCompatibilityMP4, .highCompressionHEVC, .socialShare1080p:
            return "mp4"
        case .originalCopy:
            return "mov"
        case .custom:
            return "mp4"
        }
    }

    var videoCodec: String {
        switch self {
        case .highCompatibilityMP4, .socialShare1080p:
            return "libx264"
        case .highCompressionHEVC:
            return "libx265"
        case .originalCopy:
            return "copy"
        case .custom:
            return "libx264"
        }
    }

    var audioCodec: String {
        switch self {
        case .highCompatibilityMP4, .highCompressionHEVC, .socialShare1080p:
            return "aac"
        case .originalCopy:
            return "copy"
        case .custom:
            return "aac"
        }
    }

    var resolution: String {
        switch self {
        case .socialShare1080p:
            return "1920x1080"
        case .highCompatibilityMP4, .highCompressionHEVC, .originalCopy, .custom:
            return "original"
        }
    }

    func matches(container: String, videoCodec: String, audioCodec: String, resolution: String) -> Bool {
        self.container == container
            && self.videoCodec == videoCodec
            && self.audioCodec == audioCodec
            && self.resolution == resolution
    }
}

struct SourceMediaInfo {
    let filename: String
    let containerDescription: String
    let fileSizeText: String
    let durationText: String
}

func loadSourceMediaInfo(from url: URL) async -> SourceMediaInfo {
    let filename = url.lastPathComponent

    async let fileSizeText = readFileSizeText(from: url)
    async let durationText = readDurationText(from: url)
    let containerDescription = readContainerDescription(from: url)

    return await SourceMediaInfo(
        filename: filename,
        containerDescription: containerDescription,
        fileSizeText: fileSizeText,
        durationText: durationText
    )
}

func makeSuggestedOutputFilename(sourceURL: URL?, container: String) -> String {
    let baseName = sourceURL?.deletingPathExtension().lastPathComponent ?? L10n.tr("filename.default_base")
    return "\(baseName)_converted.\(container)"
}

private func readContainerDescription(from url: URL) -> String {
    let resourceValues = try? url.resourceValues(forKeys: [.contentTypeKey])
    let fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension.uppercased()

    if let contentType = resourceValues?.contentType,
       let preferredExtension = contentType.preferredFilenameExtension?.uppercased() {
        if let fileExtension, fileExtension != preferredExtension {
            return "\(fileExtension) / \(preferredExtension)"
        }
        return preferredExtension
    }

    return fileExtension ?? L10n.tr("common.unavailable")
}

private func readFileSizeText(from url: URL) async -> String {
    if let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(fileSize))
    }

    return L10n.tr("common.unavailable")
}

private func readDurationText(from url: URL) async -> String {
    let asset = AVURLAsset(url: url)

    do {
        let duration = try await asset.load(.duration)
        guard duration.isNumeric else { return L10n.tr("common.unavailable") }

        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds >= 0 else { return L10n.tr("common.unavailable") }
        return formatDuration(seconds: seconds)
    } catch {
        return L10n.tr("common.unavailable")
    }
}

private func formatDuration(seconds: Double) -> String {
    let totalSeconds = Int(seconds.rounded())
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let remainingSeconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    return String(format: "%02d:%02d", minutes, remainingSeconds)
}
