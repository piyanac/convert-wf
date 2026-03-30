import SwiftUI
import UniformTypeIdentifiers

struct WorkflowShellView: View {
    @ObservedObject var store: ConversionWorkflowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            currentPage

            footer
        }
        .padding(.top, 20)
        .padding(.horizontal, 28)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var currentPage: some View {
        switch store.currentStep {
        case .source:
            SourceLandingView(store: store)
        case .files:
            SelectedFilesView(store: store)
        case .config:
            ConversionConfigView(store: store)
        case .progress:
            ConversionProgressView(store: store)
        case .result:
            ConversionResultView(store: store)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch store.currentStep {
        case .files:
            footerBar {
                HStack(spacing: 12) {
                    FooterTertiaryButton("workflow.files.add_more", action: store.selectMultipleSourceFiles)

                    if store.hasSources {
                        FooterTertiaryButton("workflow.files.clear", role: .destructive, action: store.clearSources)
                    }
                }
            } primary: {
                FooterPrimaryButton("workflow.files.next") {
                    store.goToNextStep()
                }
                .disabled(!store.canAccess(.config))
            }
        case .config:
            footerBar {
                EmptyView()
            } primary: {
                FooterPrimaryButton("workflow.config.start_conversion") {
                    store.startConversion()
                }
                .disabled(!store.canStartConversion)
            }
        case .progress:
            footerBar {
                EmptyView()
            } primary: {
                FooterDangerButton("workflow.progress.cancel") {
                    store.cancelConversion()
                }
            }
        case .result:
            footerBar {
                if store.lastOutputExists {
                    FooterTertiaryButton("workflow.result.show_in_finder") {
                        store.revealInFinder(store.converter.lastOutputURL)
                    }
                }
            } primary: {
                FooterPrimaryButton("workflow.result.quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        default:
            EmptyView()
        }
    }

    private func footerBar<Leading: View, Primary: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder primary: () -> Primary
    ) -> some View {
        VStack(spacing: 18) {
            Divider()

            HStack(alignment: .center, spacing: 16) {
                leading()

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 10) {
                    primary()
                }
                .frame(width: 360, alignment: .trailing)
            }
        }
        .padding(.top, 18)
        .frame(maxWidth: .infinity, alignment: .bottom)
    }
}

struct SourceLandingView: View {
    @ObservedObject var store: ConversionWorkflowStore
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 32)

            VStack(spacing: 18) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(.secondary)

                Text("workflow.source.drop_hint")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("workflow.source.select_files", action: store.selectSourceFile)
                        .buttonStyle(.borderedProminent)

                    Button("workflow.source.add_multiple", action: store.selectMultipleSourceFiles)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 620, minHeight: 260)
            .padding(.horizontal, 28)
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                        style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [6, 6])
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .onTapGesture(perform: store.selectSourceFile)
            .onDrop(
                of: [UTType.movie.identifier, UTType.video.identifier, UTType.fileURL.identifier],
                isTargeted: $isDropTargeted,
                perform: store.handleSourceDrop(providers:)
            )

            if let message = store.sourceImportErrorMessage, !message.isEmpty {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Spacer(minLength: 32)
        }
        .frame(maxWidth: .infinity, minHeight: 380)
    }
}

struct SelectedFilesView: View {
    @ObservedObject var store: ConversionWorkflowStore

    var body: some View {
        List {
            ForEach(store.sourceURLs, id: \.path) { url in
                fileRow(for: url)
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }
        }
        .listStyle(.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(for url: URL) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: store.isBatchMode ? "film.stack" : "video")
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.headline)

                Text(detailText(for: url))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
    }

    private func detailText(for url: URL) -> String {
        if !store.isBatchMode, url == store.primarySourceURL, let media = store.sourceMediaInfo {
            return "\(media.containerDescription) ・ \(media.fileSizeText) ・ \(media.durationText)"
        }
        return url.path
    }
}

struct ConversionConfigView: View {
    @ObservedObject var store: ConversionWorkflowStore

    var body: some View {
        VStack(alignment: .center, spacing: 28) {
            Picker("workflow.config.mode", selection: Binding(
                get: { store.configMode },
                set: { store.updateConfigMode($0) }
            )) {
                ForEach(ConfigMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)

            if store.configMode == .preset {
                presetGrid
            } else {
                manualGrid
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 10)
    }

    private var presetGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 16)],
            spacing: 16
        ) {
            ForEach(store.presetCards) { preset in
                let isSelected = store.selectedPreset == preset && store.configMode == .preset

                Button {
                    store.applyPreset(preset)
                } label: {
                    VStack(spacing: 14) {
                        Image(systemName: iconName(for: preset))
                            .font(.system(size: 34))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                        VStack(spacing: 6) {
                            Text(title(for: preset))
                                .font(.title3)
                                .fontWeight(.semibold)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)

                            Text(subtitle(for: preset))
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var manualGrid: some View {
        VStack(spacing: 24) {
            HStack(alignment: .top, spacing: 28) {
                ManualPickerGroup(title: "workflow.config.group.container") {
                    ManualOptionList(
                        width: 180,
                        options: store.containerOptions.map {
                            ManualOption(id: $0, title: store.containerDisplayName($0))
                        },
                        selectedID: store.selectedContainer,
                        onSelect: store.updateContainer(_:)
                    )
                }

                ManualPickerGroup(title: "workflow.config.group.resolution") {
                    ManualOptionList(
                        width: 180,
                        options: store.resolutionOptions.keys.sorted().map { key in
                            ManualOption(id: key, title: store.resolutionOptions[key] ?? key)
                        },
                        selectedID: store.selectedResolution,
                        isEnabled: !store.isResolutionLocked,
                        onSelect: store.updateResolution(_:)
                    )
                }
            }

            HStack(alignment: .top, spacing: 28) {
                ManualPickerGroup(title: "workflow.config.group.video") {
                    ManualOptionList(
                        width: 180,
                        options: [
                            ManualOption(id: "copy", title: L10n.tr("workflow.config.option.source")),
                            ManualOption(id: "libx264", title: "H.264"),
                            ManualOption(id: "libx265", title: "H.265 / HEVC")
                        ],
                        selectedID: store.selectedVideoCodec,
                        onSelect: store.updateVideoCodec(_:)
                    )
                }

                ManualPickerGroup(title: "workflow.config.group.audio") {
                    ManualOptionList(
                        width: 180,
                        options: [
                            ManualOption(id: "copy", title: L10n.tr("workflow.config.option.source")),
                            ManualOption(id: "aac", title: "AAC"),
                            ManualOption(id: "mp3", title: "MP3")
                        ],
                        selectedID: store.selectedAudioCodec,
                        onSelect: store.updateAudioCodec(_:)
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func iconName(for preset: ConversionPreset) -> String {
        switch preset {
        case .highCompatibilityMP4:
            return "accessibility"
        case .highCompressionHEVC:
            return "arrow.down.right.and.arrow.up.left"
        case .originalCopy:
            return "photo"
        case .socialShare1080p:
            return "globe"
        case .custom:
            return "slider.horizontal.3"
        }
    }

    private func title(for preset: ConversionPreset) -> String {
        switch preset {
        case .highCompatibilityMP4:
            return L10n.tr("workflow.preset.card.compatible.title")
        case .highCompressionHEVC:
            return L10n.tr("workflow.preset.card.smallest.title")
        case .originalCopy:
            return L10n.tr("workflow.preset.card.source_quality.title")
        case .socialShare1080p:
            return L10n.tr("workflow.preset.card.social.title")
        case .custom:
            return L10n.tr("workflow.preset.card.manual.title")
        }
    }

    private func subtitle(for preset: ConversionPreset) -> String {
        switch preset {
        case .highCompatibilityMP4:
            return L10n.tr("workflow.preset.card.compatible.subtitle")
        case .highCompressionHEVC:
            return L10n.tr("workflow.preset.card.smallest.subtitle")
        case .originalCopy:
            return L10n.tr("workflow.preset.card.source_quality.subtitle")
        case .socialShare1080p:
            return L10n.tr("workflow.preset.card.social.subtitle")
        case .custom:
            return ""
        }
    }
}

struct ConversionProgressView: View {
    @ObservedObject var store: ConversionWorkflowStore

    var body: some View {
        VStack(spacing: 24) {
            ProgressView(value: store.isBatchMode ? store.batchOverallProgress : store.converter.progress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 420)

            Text(store.isBatchMode ? L10n.tr("workflow.progress.title.batch") : L10n.tr("workflow.progress.title.single"))
                .font(.title2)
                .fontWeight(.medium)

            Text(progressDetail)
                .font(.callout)
                .foregroundStyle(.secondary)

            if store.isBatchMode {
                List {
                    ForEach(Array(store.batchSourceQueue.enumerated()), id: \.element.path) { index, url in
                        HStack {
                            Text(url.lastPathComponent)
                            Spacer()
                            if store.batchCurrentIndex == index + 1 && store.converter.isConverting {
                                Text("workflow.progress.item.in_progress")
                                    .foregroundStyle(Color.accentColor)
                            } else if store.batchCurrentIndex > index + 1 {
                                Text("workflow.progress.item.done")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: 220)
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 18)
    }

    private var progressDetail: String {
        if store.isBatchMode {
            let fileName = store.batchCurrentFileName.isEmpty ? L10n.tr("workflow.progress.preparing") : store.batchCurrentFileName
            return "\(store.batchCurrentIndex) / \(max(store.batchSourceQueue.count, 1)) ・ \(fileName)"
        }
        return store.converter.statusMessage.isEmpty ? L10n.tr("workflow.progress.preparing") : store.converter.statusMessage
    }
}

struct ConversionResultView: View {
    @ObservedObject var store: ConversionWorkflowStore

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer()
                VStack(spacing: 14) {
                    Image(systemName: resultIcon)
                        .font(.system(size: 72))
                        .foregroundStyle(resultColor)

                    Text(resultTitle)
                        .font(.largeTitle)
                        .fontWeight(.semibold)

                    if !resultMessage.isEmpty {
                        Text(resultMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            }
            .padding(.top, 18)

            resultList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var resultList: some View {
        if let batchResult = store.batchResult {
            List {
                if !batchResult.failureMessages.isEmpty {
                    Section("workflow.result.failed_items") {
                        ForEach(batchResult.failureMessages, id: \.self) { message in
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("workflow.result.selected_files") {
                    ForEach(store.sourceURLs, id: \.path) { url in
                        HStack {
                            Text(url.lastPathComponent)
                            Spacer()
                            if batchResult.failureMessages.contains(where: { $0.hasPrefix(url.lastPathComponent) }) {
                                Text("workflow.result.item.failed")
                                    .foregroundStyle(.orange)
                            } else {
                                Text("workflow.result.item.done")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240)
        } else {
            List {
                ForEach(store.sourceURLs, id: \.path) { url in
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.18))
                            .frame(width: 56, height: 56)
                            .overlay {
                                Image(systemName: "video")
                                    .foregroundStyle(Color.accentColor)
                            }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(url.lastPathComponent)
                                .font(.headline)

                            Text(url == store.primarySourceURL && store.sourceMediaInfo != nil
                                ? "\(store.sourceMediaInfo?.containerDescription ?? "") ・ \(store.sourceMediaInfo?.durationText ?? "")"
                                : url.path)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
        }
    }

    private var resultIcon: String {
        if isSuccessfulResult {
            return "checkmark.circle.fill"
        }
        if store.converter.wasCancelled || store.batchResult?.wasCancelled == true {
            return "stop.circle.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private var resultColor: Color {
        if isSuccessfulResult {
            return .green
        }
        if store.converter.wasCancelled || store.batchResult?.wasCancelled == true {
            return .secondary
        }
        return .orange
    }

    private var isSuccessfulResult: Bool {
        if let batchResult = store.batchResult {
            return batchResult.failureCount == 0 && !batchResult.wasCancelled
        }
        return store.converter.conversionComplete && !store.converter.isError && !store.converter.wasCancelled
    }

    private var resultTitle: String {
        if let batchResult = store.batchResult {
            if batchResult.wasCancelled {
                return L10n.tr("workflow.result.title.cancelled")
            }
            return batchResult.failureCount == 0 ? L10n.tr("workflow.result.title.complete") : L10n.tr("workflow.result.title.finished_with_errors")
        }
        if store.converter.conversionComplete {
            return L10n.tr("workflow.result.title.complete")
        }
        if store.converter.wasCancelled {
            return L10n.tr("workflow.result.title.cancelled")
        }
        return L10n.tr("workflow.result.title.failed")
    }

    private var resultMessage: String {
        if let batchResult = store.batchResult {
            if batchResult.wasCancelled {
                return L10n.format("workflow.result.message.batch_cancelled", L10n.number(batchResult.completedCount), L10n.number(batchResult.totalCount))
            }
            if batchResult.failureCount > 0 {
                return L10n.format("workflow.result.message.batch_partial_failure", L10n.number(batchResult.successCount), L10n.number(batchResult.failureCount))
            }
            return L10n.format("workflow.result.message.batch_complete", L10n.number(batchResult.totalCount))
        }
        if store.converter.conversionComplete {
            return store.lastCompletedDetailText ?? ""
        }
        return store.converter.statusMessage
    }
}

private struct FooterPrimaryButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(.plain)
        .font(.headline.weight(.semibold))
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.72))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(isEnabled ? 1 : 0.45))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.accentColor.opacity(isEnabled ? 0.22 : 0), radius: 10, y: 4)
    }
}

private struct FooterSecondaryButton: View {
    let title: LocalizedStringKey
    var role: ButtonRole?
    var fixedWidth: CGFloat? = 220
    let action: () -> Void

    init(
        _ title: LocalizedStringKey,
        role: ButtonRole? = nil,
        fixedWidth: CGFloat? = 220,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.role = role
        self.fixedWidth = fixedWidth
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
                .padding(.horizontal, 14)
                .frame(maxWidth: fixedWidth == nil ? nil : .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .frame(width: fixedWidth)
    }
}

private struct FooterDangerButton: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: LocalizedStringKey
    let action: () -> Void

    init(_ title: LocalizedStringKey, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(.plain)
        .font(.headline.weight(.semibold))
        .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.72))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color.red.opacity(isEnabled ? 0.92 : 0.42))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.red.opacity(isEnabled ? 0.18 : 0), radius: 8, y: 3)
    }
}

private struct FooterTertiaryButton: View {
    let title: LocalizedStringKey
    var role: ButtonRole?
    let action: () -> Void

    init(_ title: LocalizedStringKey, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }
}

private struct ManualPickerGroup<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
        }
    }
}

private struct ManualOption: Identifiable {
    let id: String
    let title: String
}

private struct ManualOptionList: View {
    let width: CGFloat
    let options: [ManualOption]
    let selectedID: String
    var isEnabled = true
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(options) { option in
                Button {
                    guard isEnabled else { return }
                    onSelect(option.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: selectedID == option.id ? "checkmark" : "")
                            .frame(width: 14, alignment: .leading)
                            .foregroundStyle(.primary)

                        Text(option.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)

                if option.id != options.last?.id {
                    Divider()
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .opacity(isEnabled ? 1 : 0.55)
    }
}
