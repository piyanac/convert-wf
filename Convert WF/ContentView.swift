import SwiftUI

// MARK: - 主視圖 (ContentView)
struct ContentView: View {
    // MARK: - 狀態屬性 (State Properties)
    
    @StateObject private var converter = FFmpegConverter()
    @State private var sourceURL: URL?
    
    // ------------------- 轉檔參數 -------------------
    @State private var selectedContainer = "mp4"
    @State private var selectedVideoCodec = "libx264"
    @State private var selectedAudioCodec = "aac"
    @State private var selectedResolution = "original"
    // ------------------------------------------------
    
    let containerOptions = ["mp4", "mov", "mkv", "avi"]
    let videoCodecOptions = [
        "libx264": "H.264 (通用)",
        "libx265": "H.265/HEVC (高效)",
        "copy": "直接複製 (不重新編碼)"
    ]
    let audioCodecOptions = [
        "aac": "AAC (通用)",
        "mp3": "MP3 (廣泛相容)",
        "copy": "直接複製 (不重新編碼)"
    ]
    let resolutionOptions = [
        "original": "維持原始解析度",
        "1920x1080": "1080p (Full HD)",
        "1280x720": "720p (HD)",
        "854x480": "480p (SD)"
    ]

    // MARK: - 視圖主體 (View Body)
    var body: some View {
        VStack(spacing: 15) {
            
            Text("Convert WF")
                .font(.largeTitle)
                .fontWeight(.bold)

            HStack {
                Button(action: selectSourceFile) {
                    Label("選擇來源影片", systemImage: "filemenu.and.selection")
                }
                Text(sourceURL?.lastPathComponent ?? "尚未選擇檔案")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }

            Form {
                Picker("輸出格式 (Container):", selection: $selectedContainer) {
                    // 【修正】將 'uppersased()' 修正為 'uppercased()'
                    ForEach(containerOptions, id: \.self) { Text($0.uppercased()) }
                }
                .pickerStyle(.menu)

                Picker("影像編碼 (Video Codec):", selection: $selectedVideoCodec) {
                    ForEach(videoCodecOptions.keys.sorted(), id: \.self) { key in
                        Text(videoCodecOptions[key]!).tag(key)
                    }
                }
                .pickerStyle(.menu)
                
                Picker("聲音編碼 (Audio Codec):", selection: $selectedAudioCodec) {
                    ForEach(audioCodecOptions.keys.sorted(), id: \.self) { key in
                        Text(audioCodecOptions[key]!).tag(key)
                    }
                }
                .pickerStyle(.menu)
                
                Picker("解析度 (Resolution):", selection: $selectedResolution) {
                    ForEach(resolutionOptions.keys.sorted(by: >), id: \.self) { key in
                        Text(resolutionOptions[key]!).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .disabled(selectedVideoCodec == "copy")
                .onChange(of: selectedVideoCodec) { codec in
                    if codec == "copy" {
                        selectedResolution = "original"
                    }
                }
            }
            .padding(.horizontal, -10)
            
            if selectedVideoCodec == "copy" {
                Text("提示：選擇「直接複製」影像時，無法變更解析度。")
                    .font(.caption)
                    .foregroundColor(.blue)
            }

            // 狀態顯示區域
            Group {
                if converter.conversionComplete {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green).font(.title3)
                        Text(converter.statusMessage).font(.body)
                    }
                } else if converter.isConverting {
                    VStack {
                        ProgressView(value: converter.progress) {
                            Text("轉換進度")
                        } currentValueLabel: {
                            Text("\(Int(converter.progress * 100))%")
                        }
                        Text(converter.statusMessage).font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    ScrollView {
                        Text(converter.statusMessage.isEmpty ? "This is a frontend only. All glory to FFMPEG. " : converter.statusMessage)
                            .font(.caption)
                            .foregroundColor(converter.isError ? .red : .secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(minHeight: 50)

            Button(action: startConversion) {
                Label("開始轉換", systemImage: "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderedProminent)
            .disabled(sourceURL == nil || converter.isConverting)
            .controlSize(.large)
        }
        .padding()
        .frame(minWidth: 480, minHeight: 450)
    }

    private func selectSourceFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url {
            sourceURL = url
            converter.resetStatus()
        }
    }

    private func startConversion() {
        guard let sourceURL = sourceURL else { return }

        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.showsTagField = false
        savePanel.nameFieldStringValue = "\(sourceURL.deletingPathExtension().lastPathComponent)_converted.\(selectedContainer)"

        if savePanel.runModal() == .OK, let destinationURL = savePanel.url {
            let parameters = FFmpegParameters(container: selectedContainer, videoCodec: selectedVideoCodec, audioCodec: selectedAudioCodec, resolution: selectedResolution)
            converter.convert(sourceURL: sourceURL, destinationURL: destinationURL, parameters: parameters)
        }
    }
}

struct FFmpegParameters {
    let container: String, videoCodec: String, audioCodec: String, resolution: String
}

// MARK: - FFmpeg 核心邏輯 (FFmpegConverter)
class FFmpegConverter: ObservableObject {
    @Published var isConverting = false
    @Published var progress: Double = 0.0
    @Published var statusMessage = ""
    @Published var isError = false
    @Published var conversionComplete = false
    
    private var ffmpegProcess: Process?
    private var totalDurationInSeconds: Double = 0.0
    private var accumulatedErrorOutput: String = ""

    func resetStatus() {
        DispatchQueue.main.async {
            self.statusMessage = ""
            self.isError = false
            self.isConverting = false
            self.conversionComplete = false
            self.progress = 0.0
        }
    }

    func convert(sourceURL: URL, destinationURL: URL, parameters: FFmpegParameters) {
        guard let ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) else {
            updateStatus(message: "錯誤：專案內找不到 ffmpeg 執行檔。", isError: true)
            return
        }
        
        self.accumulatedErrorOutput = ""

        DispatchQueue.main.async {
            self.isConverting = true
            self.conversionComplete = false
            self.progress = 0.0
            self.isError = false
            self.statusMessage = "正在準備轉檔..."
        }
        
        Task(priority: .userInitiated) {
            totalDurationInSeconds = await getMediaDuration(path: sourceURL.path, ffmpegPath: ffmpegPath)
            guard totalDurationInSeconds > 0 else {
                updateStatus(message: "錯誤：無法讀取影片長度，請確認檔案是否正常。", isError: true, isConverting: false)
                return
            }
            runConversionProcess(sourceURL: sourceURL, destinationURL: destinationURL, parameters: parameters, ffmpegPath: ffmpegPath)
        }
    }
    
    private func runConversionProcess(sourceURL: URL, destinationURL: URL, parameters: FFmpegParameters, ffmpegPath: String) {
        var arguments = ["-i", sourceURL.path]
        
        arguments += ["-c:v", parameters.videoCodec]
        if parameters.videoCodec != "copy" && parameters.resolution != "original" {
            let scaleValue = parameters.resolution.replacingOccurrences(of: "x", with: ":")
            arguments += ["-vf", "scale=\(scaleValue)"]
        }
        
        arguments += ["-c:a", parameters.audioCodec]
        arguments += [destinationURL.path, "-y"]
        
        print("Executing command: \(ffmpegPath) \(arguments.joined(separator: " "))")
        
        ffmpegProcess = Process()
        guard let ffmpegProcess = ffmpegProcess else { return }
        
        let errorPipe = Pipe()
        ffmpegProcess.executableURL = URL(fileURLWithPath: ffmpegPath)
        ffmpegProcess.arguments = arguments
        ffmpegProcess.standardError = errorPipe
        
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                self.accumulatedErrorOutput += output
                self.parseProgress(from: output)
            }
        }
        
        ffmpegProcess.terminationHandler = { [weak self] process in
            guard let self = self else { return }
            let success = (process.terminationStatus == 0)
            
            DispatchQueue.main.async {
                self.isConverting = false
                if success {
                    self.statusMessage = "轉換完成！"
                    self.conversionComplete = true
                    self.progress = 1.0
                } else {
                    let finalError = self.accumulatedErrorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.statusMessage = "轉換失敗：\n\(finalError.isEmpty ? "ffmpeg 未提供具體錯誤訊息。" : finalError)"
                    self.isError = true
                }
            }
        }
        
        do {
            try ffmpegProcess.run()
        } catch {
            updateStatus(message: "錯誤：無法啟動 ffmpeg 程序 - \(error.localizedDescription)", isError: true, isConverting: false)
        }
    }
    
    private func parseProgress(from output: String) {
        let pattern = "time=([0-9]{2}):([0-9]{2}):([0-9]{2})\\.([0-9]{2})"
        if let range = output.range(of: pattern, options: .regularExpression) {
            let comps = output[range].components(separatedBy: CharacterSet(charactersIn: "=:."))
            if comps.count > 4, let h = Double(comps[1]), let m = Double(comps[2]), let s = Double(comps[3]), let ms = Double(comps[4]) {
                let currentTime = (h * 3600) + (m * 60) + s + (ms / 100)
                DispatchQueue.main.async {
                    if self.totalDurationInSeconds > 0 { self.progress = min(1.0, currentTime / self.totalDurationInSeconds) }
                }
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
                let pattern = "Duration: ([0-9]{2}):([0-9]{2}):([0-9]{2})\\.([0-9]{2})"
                if let range = output.range(of: pattern, options: .regularExpression) {
                    let components = output[range].components(separatedBy: CharacterSet(charactersIn: ":. "))
                     if components.count > 4,
                        let hours = Double(components[2]), let minutes = Double(components[3]),
                        let seconds = Double(components[4]), let milliseconds = Double(components[5]) {
                        return (hours * 3600) + (minutes * 60) + seconds + (milliseconds / 100)
                    }
                }
            }
        } catch { print("無法取得影片長度: \(error)") }
        return 0.0
    }

    private func updateStatus(message: String, isError: Bool, isConverting: Bool? = nil) {
        DispatchQueue.main.async {
            self.statusMessage = message
            self.isError = isError
            if let converting = isConverting { self.isConverting = converting }
        }
    }
}

#Preview { ContentView() }


