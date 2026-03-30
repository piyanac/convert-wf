import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ConversionWorkflowStore: ObservableObject {
    private static let persistedSettingsKey = "persistedConversionSettings"
    private static let recentRecordsKey = "recentConversionRecords"
    private static let fixedWindowWidth: CGFloat = 860
    private static let fixedWindowHeight: CGFloat = 620
    private static let completedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    let containerOptions = ["mp4", "mov", "mkv", "avi"]
    var videoCodecOptions: [String: String] {
        [
            "libx264": L10n.tr("codec.video.h264"),
            "libx265": L10n.tr("codec.video.hevc"),
            "copy": L10n.tr("codec.copy")
        ]
    }
    var audioCodecOptions: [String: String] {
        [
            "aac": L10n.tr("codec.audio.aac"),
            "mp3": L10n.tr("codec.audio.mp3"),
            "copy": L10n.tr("codec.copy")
        ]
    }
    var resolutionOptions: [String: String] {
        [
            "original": L10n.tr("resolution.keep_original"),
            "1920x1080": L10n.tr("resolution.1080p"),
            "1280x720": L10n.tr("resolution.720p"),
            "854x480": L10n.tr("resolution.480p")
        ]
    }

    @Published var currentStep: WorkflowStep = .source

    @Published var sourceURLs: [URL] = []
    @Published var sourceMediaInfo: SourceMediaInfo?
    @Published var sourceImportErrorMessage: String?
    @Published var fileActionErrorMessage: String?
    @Published var recentRecords: [RecentConversionRecord] = []

    @Published var selectedPreset: ConversionPreset = .highCompatibilityMP4
    @Published var configMode: ConfigMode = .preset
    @Published var selectedContainer = "mp4"
    @Published var selectedVideoCodec = "libx264"
    @Published var selectedAudioCodec = "aac"
    @Published var selectedResolution = "original"

    @Published var batchSourceQueue: [URL] = []
    @Published var batchOutputDirectoryURL: URL?
    @Published var batchCurrentIndex = 0
    @Published var batchCurrentFileName = ""
    @Published var batchSuccessCount = 0
    @Published var batchFailureMessages: [String] = []
    @Published var batchResult: BatchConversionResult?

    let converter = FFmpegConverter()

    private var isApplyingPreset = false
    private var cancellables = Set<AnyCancellable>()
    private var activeSecurityScopedURLs: [URL] = []

    init() {
        bindConverter()
        loadPersistedStateIfNeeded()
    }

    var primarySourceURL: URL? {
        sourceURLs.first
    }

    var isBatchMode: Bool {
        sourceURLs.count > 1
    }

    var hasSources: Bool {
        !sourceURLs.isEmpty
    }

    var isResolutionLocked: Bool {
        selectedVideoCodec == "copy"
    }

    var canStartConversion: Bool {
        hasSources && !converter.isConverting
    }

    var currentParameters: FFmpegParameters {
        FFmpegParameters(
            container: selectedContainer,
            videoCodec: selectedVideoCodec,
            audioCodec: selectedAudioCodec,
            resolution: selectedResolution
        )
    }

    var selectedSourceFilename: String {
        primarySourceURL?.lastPathComponent ?? L10n.tr("source.none_selected")
    }

    var selectedPresetDescription: String {
        selectedPreset.description
    }

    var presetCards: [ConversionPreset] {
        ConversionPreset.allCases.filter { $0 != .custom }
    }

    var resolutionSummaryText: String {
        if selectedVideoCodec == "copy" {
            return L10n.tr("resolution.keep_original")
        }

        return selectedResolution == "original"
            ? L10n.tr("resolution.keep_original")
            : (resolutionOptions[selectedResolution] ?? selectedResolution)
    }

    var suggestedOutputFilename: String {
        makeSuggestedOutputFilename(sourceURL: primarySourceURL, container: selectedContainer)
    }

    var conversionSummaryText: String {
        let summary = "\(containerDisplayName(selectedContainer)) / \(videoCodecSummaryName(selectedVideoCodec)) / \(audioCodecSummaryName(selectedAudioCodec)) / \(resolutionSummaryText)"
        if isBatchMode {
            return L10n.format("summary.apply_same_settings", L10n.number(sourceURLs.count), summary)
        }
        return L10n.format("summary.output_format", summary)
    }

    var currentRunSummaryText: String {
        "\(containerDisplayName(selectedContainer)) / \(videoCodecSummaryName(selectedVideoCodec)) / \(audioCodecSummaryName(selectedAudioCodec)) / \(resolutionSummaryText)"
    }

    var actionHintText: String {
        if converter.isConverting {
            return isBatchMode ? L10n.tr("hint.batch_running") : L10n.tr("hint.single_running")
        }
        if sourceURLs.isEmpty {
            return L10n.tr("hint.select_video")
        }
        if isBatchMode {
            return L10n.tr("hint.choose_output_folder")
        }
        return L10n.tr("hint.review_and_start")
    }

    var batchOverallProgress: Double {
        guard !batchSourceQueue.isEmpty else { return converter.progress }
        let completedItems = max(batchCurrentIndex - 1, 0)
        return min(1.0, (Double(completedItems) + converter.progress) / Double(batchSourceQueue.count))
    }

    var errorDetailText: String {
        let trimmed = converter.statusMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L10n.tr("error.ffmpeg.no_detail") }

        if let range = trimmed.range(of: "\n") {
            let detail = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? trimmed : detail
        }

        let detail = L10n.trimFFmpegFailureDetail(from: trimmed)
        return detail.isEmpty ? L10n.tr("error.ffmpeg.no_detail") : detail
    }

    var lastOutputExists: Bool {
        fileExists(converter.lastOutputURL)
    }

    var lastCompletedDetailText: String? {
        guard let completedAt = converter.lastCompletedAt else { return converter.lastRunSummary }
        let timeText = Self.completedAtFormatter.string(from: completedAt)
        if let summary = converter.lastRunSummary, !summary.isEmpty {
            return L10n.format("summary.completed_at_with_details", timeText, summary)
        }
        return L10n.format("summary.completed_at", timeText)
    }

    var hasResultState: Bool {
        batchResult != nil || converter.conversionComplete || converter.wasCancelled || converter.isError
    }

    var windowWidth: CGFloat {
        Self.fixedWindowWidth
    }

    var windowHeight: CGFloat {
        Self.fixedWindowHeight
    }

    func canAccess(_ step: WorkflowStep) -> Bool {
        switch step {
        case .source:
            return !converter.isConverting
        case .files:
            return hasSources && !converter.isConverting
        case .config:
            return hasSources && !converter.isConverting
        case .progress:
            return converter.isConverting
        case .result:
            return hasResultState && !converter.isConverting
        }
    }

    func goToStep(_ step: WorkflowStep) {
        guard canAccess(step) else { return }
        currentStep = step
    }

    func goToNextStep() {
        switch currentStep {
        case .source:
            if canAccess(.files) {
                currentStep = .files
            }
        case .files:
            if canAccess(.config) {
                currentStep = .config
            }
        case .config, .progress, .result:
            break
        }
    }

    func goToPreviousStep() {
        switch currentStep {
        case .source:
            break
        case .files:
            if canAccess(.source) {
                currentStep = .source
            }
        case .config:
            if canAccess(.files) {
                currentStep = .files
            }
        case .progress:
            break
        case .result:
            if canAccess(.config) {
                currentStep = .config
            } else if canAccess(.files) {
                currentStep = .files
            } else if canAccess(.source) {
                currentStep = .source
            }
        }
    }

    func applyPreset(_ preset: ConversionPreset) {
        guard preset != .custom else { return }

        isApplyingPreset = true
        configMode = .preset
        selectedPreset = preset
        selectedContainer = preset.container
        selectedVideoCodec = preset.videoCodec
        selectedAudioCodec = preset.audioCodec
        selectedResolution = preset.resolution
        if selectedVideoCodec == "copy" {
            selectedResolution = "original"
        }
        isApplyingPreset = false
    }

    func updateContainer(_ container: String) {
        configMode = .manual
        selectedContainer = container
        syncPresetSelectionFromManualChanges()
    }

    func updateVideoCodec(_ codec: String) {
        configMode = .manual
        selectedVideoCodec = codec
        if codec == "copy" {
            selectedResolution = "original"
        }
        syncPresetSelectionFromManualChanges()
    }

    func updateAudioCodec(_ codec: String) {
        configMode = .manual
        selectedAudioCodec = codec
        syncPresetSelectionFromManualChanges()
    }

    func updateResolution(_ resolution: String) {
        configMode = .manual
        selectedResolution = resolution
        syncPresetSelectionFromManualChanges()
    }

    func updateConfigMode(_ mode: ConfigMode) {
        configMode = mode
        if mode == .preset && selectedPreset == .custom {
            applyPreset(.highCompatibilityMP4)
        }
    }

    func selectSourceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            acceptSourceURLs([url], replaceExisting: true)
        }
    }

    func selectMultipleSourceFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            acceptSourceURLs(panel.urls, replaceExisting: false)
        }
    }

    func clearSources() {
        endSecurityScopedAccess()
        sourceImportErrorMessage = nil
        sourceMediaInfo = nil
        sourceURLs = []
        batchResult = nil
        batchSourceQueue = []
        batchOutputDirectoryURL = nil
        batchCurrentIndex = 0
        batchCurrentFileName = ""
        batchSuccessCount = 0
        batchFailureMessages = []
        converter.resetStatus(clearLastResult: true)
        currentStep = .source
    }

    func acceptSourceURLs(_ urls: [URL], replaceExisting: Bool) {
        let validURLs = urls.filter(isSupportedVideoURL)
        guard !validURLs.isEmpty else {
            sourceImportErrorMessage = L10n.tr("error.source.unsupported_selected")
            return
        }

        sourceImportErrorMessage = nil
        sourceMediaInfo = nil
        batchResult = nil
        batchFailureMessages = []
        converter.resetStatus(clearLastResult: true)

        var merged = replaceExisting ? [] : sourceURLs
        merged.append(contentsOf: validURLs)
        sourceURLs = deduplicatedURLs(merged)
        currentStep = .files

        Task {
            await refreshSourceMediaInfo()
        }
    }

    func handleSourceDrop(providers: [NSItemProvider]) -> Bool {
        let supportedProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.video.identifier)
        }

        guard !supportedProviders.isEmpty else {
            sourceImportErrorMessage = L10n.tr("error.source.unsupported_dropped")
            return false
        }

        Task {
            await importDroppedSources(from: supportedProviders)
        }

        return true
    }

    func startConversion() {
        guard canStartConversion else { return }

        persistCurrentSettings()

        if isBatchMode {
            guard let outputDirectory = chooseBatchOutputDirectory() else {
                return
            }
            _ = beginSecurityScopedAccess(for: sourceURLs + [outputDirectory])
            beginNewRun()
            startBatchConversion(outputDirectory: outputDirectory)
        } else if let sourceURL = primarySourceURL {
            guard let destinationURL = chooseSingleDestinationURL() else {
                return
            }

            _ = beginSecurityScopedAccess(for: [sourceURL, destinationURL.deletingLastPathComponent()])
            beginNewRun()
            converter.convert(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                parameters: currentParameters,
                runSummary: currentRunSummaryText
            ) { [weak self] outcome in
                Task { @MainActor [weak self] in
                    self?.handleSingleOutcome(outcome, destinationURL: destinationURL)
                }
            }
        }
    }

    func cancelConversion() {
        converter.cancelConversion()
    }

    func revealInFinder(_ url: URL?) {
        guard let url else {
            fileActionErrorMessage = L10n.tr("error.output.missing")
            return
        }
        guard fileExists(url) else {
            fileActionErrorMessage = L10n.tr("error.output.not_found")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openOutputFile(_ url: URL?) {
        guard let url else {
            fileActionErrorMessage = L10n.tr("error.output.missing")
            return
        }
        guard fileExists(url) else {
            fileActionErrorMessage = L10n.tr("error.output.not_found")
            return
        }
        if !NSWorkspace.shared.open(url) {
            fileActionErrorMessage = L10n.tr("error.output.cannot_open")
        }
    }

    func resumeEditingSources() {
        currentStep = .source
    }

    func resumeEditingSettings() {
        currentStep = hasSources ? .config : .source
    }

    func containerDisplayName(_ container: String) -> String {
        container.uppercased()
    }

    func videoCodecDisplayName(_ codec: String) -> String {
        videoCodecOptions[codec] ?? codec
    }

    func audioCodecDisplayName(_ codec: String) -> String {
        audioCodecOptions[codec] ?? codec
    }

    func videoCodecSummaryName(_ codec: String) -> String {
        switch codec {
        case "libx264":
            return "H.264"
        case "libx265":
            return "HEVC"
        case "copy":
            return L10n.tr("workflow.config.option.source")
        default:
            return codec
        }
    }

    func audioCodecSummaryName(_ codec: String) -> String {
        switch codec {
        case "aac":
            return "AAC"
        case "mp3":
            return "MP3"
        case "copy":
            return L10n.tr("workflow.config.option.source")
        default:
            return codec
        }
    }

    private func bindConverter() {
        converter.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    private func syncPresetSelectionFromManualChanges() {
        if selectedVideoCodec == "copy" {
            selectedResolution = "original"
        }

        guard !isApplyingPreset else { return }

        if let matchingPreset = ConversionPreset.allCases.first(where: {
            $0 != .custom && $0.matches(
                container: selectedContainer,
                videoCodec: selectedVideoCodec,
                audioCodec: selectedAudioCodec,
                resolution: selectedResolution
            )
        }) {
            selectedPreset = matchingPreset
            return
        }

        selectedPreset = .custom
    }

    private func isSupportedVideoURL(_ url: URL) -> Bool {
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return true
            }
        }

        let supportedExtensions = Set(["mp4", "mov", "m4v", "mkv", "avi", "webm"])
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    private func importDroppedSources(from providers: [NSItemProvider]) async {
        var droppedURLs: [URL] = []
        for provider in providers {
            guard let droppedURL = await loadDroppedFileURL(from: provider) else { continue }
            guard isSupportedVideoURL(droppedURL) else { continue }
            droppedURLs.append(droppedURL)
        }

        if droppedURLs.isEmpty {
            sourceImportErrorMessage = L10n.tr("error.source.no_supported_drop")
            return
        }

        acceptSourceURLs(droppedURLs, replaceExisting: sourceURLs.isEmpty)
    }

    private func loadDroppedFileURL(from provider: NSItemProvider) async -> URL? {
        let typeIdentifiers = [
            UTType.fileURL.identifier,
            UTType.movie.identifier,
            UTType.video.identifier
        ]

        for typeIdentifier in typeIdentifiers where provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
            if typeIdentifier == UTType.fileURL.identifier,
               let url = await loadDroppedItemURL(from: provider, typeIdentifier: typeIdentifier) {
                return url
            }

            if let url = await loadDroppedFileRepresentationURL(from: provider, typeIdentifier: typeIdentifier) {
                return url
            }
        }

        return nil
    }

    private func loadDroppedItemURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? Data,
                   let string = String(data: data, encoding: .utf8),
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }

                if let data = item as? NSData,
                   let string = String(data: data as Data, encoding: .utf8),
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func loadDroppedFileRepresentationURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _, _ in
                continuation.resume(returning: url)
            }
        }
    }

    private func refreshSourceMediaInfo() async {
        guard let primarySourceURL, !isBatchMode else {
            sourceMediaInfo = nil
            return
        }

        let requestedURL = primarySourceURL
        let didAccess = requestedURL.startAccessingSecurityScopedResource()
        let loadedInfo = await loadSourceMediaInfo(from: requestedURL)
        if didAccess {
            requestedURL.stopAccessingSecurityScopedResource()
        }
        guard !Task.isCancelled else { return }
        guard primarySourceURL == requestedURL, !isBatchMode else { return }
        sourceMediaInfo = loadedInfo
    }

    private func beginNewRun() {
        batchResult = nil
        batchSourceQueue = []
        batchOutputDirectoryURL = nil
        batchCurrentIndex = 0
        batchCurrentFileName = ""
        batchSuccessCount = 0
        batchFailureMessages = []
        converter.resetStatus(clearLastResult: true)
        currentStep = .progress
    }

    @discardableResult
    private func beginSecurityScopedAccess(for urls: [URL]) -> Bool {
        endSecurityScopedAccess()

        var accessed: [URL] = []
        for url in deduplicatedURLs(urls.map(\.standardizedFileURL)) {
            let didAccess = url.startAccessingSecurityScopedResource()
            if didAccess {
                accessed.append(url)
            }
        }

        activeSecurityScopedURLs = accessed
        return true
    }

    private func endSecurityScopedAccess() {
        for url in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs = []
    }

    private func chooseSingleDestinationURL() -> URL? {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        savePanel.nameFieldStringValue = suggestedOutputFilename
        if let contentType = UTType(filenameExtension: selectedContainer) {
            savePanel.allowedContentTypes = [contentType]
        }

        guard savePanel.runModal() == .OK, let url = savePanel.url else { return nil }
        return normalizedDestinationURL(from: url, container: selectedContainer)
    }

    private func chooseBatchOutputDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("panel.choose_output_folder")
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func startBatchConversion(outputDirectory: URL) {
        batchSourceQueue = sourceURLs
        batchOutputDirectoryURL = outputDirectory
        batchCurrentIndex = 0
        batchCurrentFileName = ""
        batchSuccessCount = 0
        batchFailureMessages = []
        batchResult = nil
        runNextBatchItem()
    }

    private func runNextBatchItem() {
        guard let outputDirectory = batchOutputDirectoryURL else { return }

        let nextIndex = batchCurrentIndex
        guard nextIndex < batchSourceQueue.count else {
            batchResult = BatchConversionResult(
                totalCount: batchSourceQueue.count,
                successCount: batchSuccessCount,
                completedCount: batchSuccessCount + batchFailureMessages.count,
                failureMessages: batchFailureMessages,
                wasCancelled: false
            )
            endSecurityScopedAccess()
            currentStep = .result
            return
        }

        let sourceURL = batchSourceQueue[nextIndex]
        batchCurrentIndex = nextIndex + 1
        batchCurrentFileName = sourceURL.lastPathComponent

        let destinationURL = outputDirectory.appendingPathComponent(
            makeSuggestedOutputFilename(sourceURL: sourceURL, container: selectedContainer)
        )

        converter.convert(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            parameters: currentParameters,
            runSummary: currentRunSummaryText
        ) { [weak self] outcome in
            Task { @MainActor [weak self] in
                self?.handleBatchOutcome(outcome, sourceURL: sourceURL, destinationURL: destinationURL)
            }
        }
    }

    private func handleSingleOutcome(_ outcome: FFmpegConversionOutcome, destinationURL: URL) {
        if case .success = outcome {
            appendRecentRecord(
                outputURL: destinationURL,
                displayName: destinationURL.lastPathComponent,
                summaryText: currentRunSummaryText
            )
        }

        endSecurityScopedAccess()
        currentStep = .result
    }

    private func handleBatchOutcome(_ outcome: FFmpegConversionOutcome, sourceURL: URL, destinationURL: URL) {
        switch outcome {
        case .success:
            batchSuccessCount += 1
            appendRecentRecord(
                outputURL: destinationURL,
                displayName: destinationURL.lastPathComponent,
                summaryText: currentRunSummaryText
            )
            runNextBatchItem()

        case .failure(let message):
            batchFailureMessages.append(
                L10n.format("batch.failure.item_prefix", sourceURL.lastPathComponent, summarizedFailureText(from: message))
            )
            runNextBatchItem()

        case .cancelled:
            batchResult = BatchConversionResult(
                totalCount: batchSourceQueue.count,
                successCount: batchSuccessCount,
                completedCount: batchSuccessCount + batchFailureMessages.count,
                failureMessages: batchFailureMessages,
                wasCancelled: true
            )
            endSecurityScopedAccess()
            currentStep = .result
        }
    }

    private func normalizedDestinationURL(from url: URL, container: String) -> URL {
        guard !container.isEmpty else { return url }

        let normalizedContainer = container.lowercased()
        let currentExtension = url.pathExtension.lowercased()

        if currentExtension == normalizedContainer {
            return url
        }

        return url.deletingPathExtension().appendingPathExtension(normalizedContainer)
    }

    private func loadPersistedStateIfNeeded() {
        let defaults = UserDefaults.standard

        if let string = defaults.string(forKey: Self.persistedSettingsKey),
           let data = string.data(using: .utf8),
           let settings = try? JSONDecoder().decode(PersistedConversionSettings.self, from: data) {
            applyPersistedSettings(settings)
        }

        if let string = defaults.string(forKey: Self.recentRecordsKey),
           let data = string.data(using: .utf8),
           let records = try? JSONDecoder().decode([RecentConversionRecord].self, from: data) {
            recentRecords = Array(records.prefix(5))
        }
    }

    private func applyPersistedSettings(_ settings: PersistedConversionSettings) {
        isApplyingPreset = true
        selectedContainer = settings.container
        selectedVideoCodec = settings.videoCodec
        selectedAudioCodec = settings.audioCodec
        selectedResolution = settings.resolution
        selectedPreset = ConversionPreset(rawValue: settings.selectedPresetRawValue) ?? .custom
        configMode = selectedPreset == .custom ? .manual : .preset
        isApplyingPreset = false
        syncPresetSelectionFromManualChanges()
    }

    private func persistCurrentSettings() {
        let payload = PersistedConversionSettings(
            container: selectedContainer,
            videoCodec: selectedVideoCodec,
            audioCodec: selectedAudioCodec,
            resolution: selectedResolution,
            selectedPresetRawValue: selectedPreset.rawValue
        )

        if let data = try? JSONEncoder().encode(payload),
           let string = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(string, forKey: Self.persistedSettingsKey)
        }
    }

    private func appendRecentRecord(outputURL: URL, displayName: String, summaryText: String) {
        let newRecord = RecentConversionRecord(
            outputPath: outputURL.path,
            displayName: displayName,
            completedAt: Date(),
            summaryText: summaryText
        )

        recentRecords.removeAll { $0.outputPath == outputURL.path }
        recentRecords.insert(newRecord, at: 0)
        recentRecords = Array(recentRecords.prefix(5))

        if let data = try? JSONEncoder().encode(recentRecords),
           let string = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(string, forKey: Self.recentRecordsKey)
        }
    }

    private func deduplicatedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            let key = url.standardizedFileURL.path
            return seen.insert(key).inserted
        }
    }

    private func summarizedFailureText(from message: String) -> String {
        let trimmed = L10n.trimFFmpegFailureDetail(from: message)
        guard !trimmed.isEmpty else { return L10n.tr("error.ffmpeg.no_detail") }
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        return String(firstLine.prefix(160))
    }

    private func fileExists(_ url: URL?) -> Bool {
        guard let url else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
