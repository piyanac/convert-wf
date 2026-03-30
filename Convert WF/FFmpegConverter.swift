import Foundation

enum FFmpegConversionOutcome {
    case success
    case failure(String)
    case cancelled
}

final class FFmpegConverter: ObservableObject {
    @Published var isConverting = false
    @Published var progress = 0.0
    @Published var statusMessage = ""
    @Published var isError = false
    @Published var conversionComplete = false
    @Published var wasCancelled = false
    @Published var lastOutputURL: URL?
    @Published var lastCompletedAt: Date?
    @Published var lastRunSummary: String?

    private var ffmpegProcess: Process?
    private var totalDurationInSeconds = 0.0
    private var accumulatedErrorOutput = ""
    private var pendingCancellationRequest = false
    private var activeRunID = UUID()
    private var currentCompletion: ((FFmpegConversionOutcome) -> Void)?
    private var currentRunSummary: String?
    private var currentDestinationURL: URL?

    func resetStatus(clearLastResult: Bool = false) {
        let applyReset = {
            self.statusMessage = ""
            self.isError = false
            self.isConverting = false
            self.conversionComplete = false
            self.wasCancelled = false
            self.progress = 0.0
            self.pendingCancellationRequest = false
            self.currentCompletion = nil
            self.currentRunSummary = nil
            self.currentDestinationURL = nil
            if clearLastResult {
                self.lastOutputURL = nil
                self.lastCompletedAt = nil
                self.lastRunSummary = nil
            }
        }

        if Thread.isMainThread {
            applyReset()
        } else {
            DispatchQueue.main.sync(execute: applyReset)
        }
    }

    func convert(
        sourceURL: URL,
        destinationURL: URL,
        parameters: FFmpegParameters,
        runSummary: String? = nil,
        completion: ((FFmpegConversionOutcome) -> Void)? = nil
    ) {
        guard let ffmpegPath = bundledFFmpegURL()?.path else {
            let message = L10n.tr("ffmpeg.error.binary_missing")
            updateStatus(message: message, isError: true)
            completion?(.failure(message))
            return
        }

        activeRunID = UUID()
        let runID = activeRunID
        accumulatedErrorOutput = ""
        pendingCancellationRequest = false
        currentCompletion = completion
        currentRunSummary = runSummary
        currentDestinationURL = destinationURL

        DispatchQueue.main.async {
            self.isConverting = true
            self.conversionComplete = false
            self.progress = 0.0
            self.isError = false
            self.wasCancelled = false
            self.statusMessage = L10n.tr("ffmpeg.status.preparing")
        }

        Task(priority: .userInitiated) {
            let duration = await getMediaDuration(path: sourceURL.path, ffmpegPath: ffmpegPath)
            guard runID == self.activeRunID else { return }

            if self.pendingCancellationRequest {
                self.finishCancelled()
                return
            }

            self.totalDurationInSeconds = duration
            guard duration > 0 else {
                self.finishFailure(L10n.tr("ffmpeg.error.read_duration"))
                return
            }

            self.runConversionProcess(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                parameters: parameters,
                ffmpegPath: ffmpegPath,
                runID: runID
            )
        }
    }

    func cancelConversion() {
        pendingCancellationRequest = true

        DispatchQueue.main.async {
            guard self.isConverting else { return }
            self.statusMessage = L10n.tr("ffmpeg.status.canceling")
        }

        if let process = ffmpegProcess, process.isRunning {
            process.terminate()
        } else {
            finishCancelled()
        }
    }

    private func runConversionProcess(
        sourceURL: URL,
        destinationURL: URL,
        parameters: FFmpegParameters,
        ffmpegPath: String,
        runID: UUID
    ) {
        var arguments = ["-y", "-i", sourceURL.path]

        arguments += ["-c:v", parameters.videoCodec]
        if parameters.videoCodec != "copy" && parameters.resolution != "original" {
            let scaleValue = parameters.resolution.replacingOccurrences(of: "x", with: ":")
            arguments += ["-vf", "scale=\(scaleValue)"]
        }

        arguments += ["-c:a", parameters.audioCodec]
        arguments += [destinationURL.path]

        let process = Process()
        ffmpegProcess = process

        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        process.standardError = errorPipe

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self.accumulatedErrorOutput += output
                self.parseProgress(from: output)
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            guard runID == self.activeRunID else { return }

            errorPipe.fileHandleForReading.readabilityHandler = nil
            self.ffmpegProcess = nil

            if self.pendingCancellationRequest || process.terminationReason == .uncaughtSignal {
                self.finishCancelled()
                return
            }

            if process.terminationStatus == 0 {
                self.finishSuccess()
            } else {
                let finalError = self.accumulatedErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                self.finishFailure(
                    L10n.ffmpegFailureMessage(
                        finalError.isEmpty ? L10n.tr("error.ffmpeg.no_detail") : finalError
                    )
                )
            }
        }

        do {
            try process.run()
        } catch {
            finishFailure(L10n.format("ffmpeg.error.launch_failed", error.localizedDescription))
        }
    }

    private func bundledFFmpegURL() -> URL? {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("ffmpeg", isDirectory: false)

        if FileManager.default.isExecutableFile(atPath: helperURL.path) {
            return helperURL
        }

        // Keep a fallback during local transitions in case an older build still embeds ffmpeg as a resource.
        if let legacyPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return URL(fileURLWithPath: legacyPath)
        }

        return nil
    }

    private func finishSuccess() {
        let destinationURL = currentDestinationURL
        let summary = currentRunSummary
        let completion = currentCompletion

        DispatchQueue.main.async {
            self.isConverting = false
            self.statusMessage = L10n.tr("ffmpeg.status.complete")
            self.conversionComplete = true
            self.progress = 1.0
            self.isError = false
            self.wasCancelled = false
            self.lastOutputURL = destinationURL
            self.lastCompletedAt = Date()
            self.lastRunSummary = summary
            self.currentCompletion = nil
            self.currentRunSummary = nil
            self.currentDestinationURL = nil
            completion?(.success)
        }
    }

    private func finishFailure(_ message: String) {
        let completion = currentCompletion

        DispatchQueue.main.async {
            self.isConverting = false
            self.conversionComplete = false
            self.isError = true
            self.wasCancelled = false
            self.statusMessage = message
            self.currentCompletion = nil
            self.currentRunSummary = nil
            self.currentDestinationURL = nil
            completion?(.failure(message))
        }
    }

    private func finishCancelled() {
        let completion = currentCompletion

        DispatchQueue.main.async {
            self.isConverting = false
            self.conversionComplete = false
            self.isError = false
            self.wasCancelled = true
            self.progress = 0.0
            self.statusMessage = L10n.tr("ffmpeg.status.cancelled")
            self.currentCompletion = nil
            self.currentRunSummary = nil
            self.currentDestinationURL = nil
            completion?(.cancelled)
        }
    }

    private func parseProgress(from output: String) {
        guard let currentTime = parseTimestamp(
            in: output,
            pattern: #"time=([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?"#,
            skipMatches: 0
        ) else {
            return
        }

        DispatchQueue.main.async {
            if self.totalDurationInSeconds > 0 {
                self.progress = min(1.0, currentTime / self.totalDurationInSeconds)
            }
        }
    }

    private func getMediaDuration(path: String, ffmpegPath: String) async -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ["-i", path]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                if let duration = parseTimestamp(
                    in: output,
                    pattern: #"Duration:\s*([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?"#,
                    skipMatches: 0
                ) {
                    return duration
                }
            }
        } catch {
            print("Could not read media duration: \(error)")
        }

        return 0.0
    }

    private func updateStatus(message: String, isError: Bool) {
        DispatchQueue.main.async {
            self.statusMessage = message
            self.isError = isError
            self.isConverting = false
        }
    }

    private func parseTimestamp(in text: String, pattern: String, skipMatches: Int) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)
        guard matches.count > skipMatches else { return nil }

        let match = matches[skipMatches]
        guard let hoursRange = Range(match.range(at: 1), in: text),
              let minutesRange = Range(match.range(at: 2), in: text),
              let secondsRange = Range(match.range(at: 3), in: text) else {
            return nil
        }

        let fractionalSeconds: Double
        if let fractionRange = Range(match.range(at: 4), in: text) {
            let fractionText = String(text[fractionRange])
            fractionalSeconds = (Double("0.\(fractionText)") ?? 0)
        } else {
            fractionalSeconds = 0
        }

        guard let hours = Double(text[hoursRange]),
              let minutes = Double(text[minutesRange]),
              let seconds = Double(text[secondsRange]) else {
            return nil
        }

        return (hours * 3600) + (minutes * 60) + seconds + fractionalSeconds
    }
}
