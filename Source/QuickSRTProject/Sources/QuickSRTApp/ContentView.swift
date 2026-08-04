import AppKit
import SwiftUI
import Translation

struct ContentView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var activeLanguagePicker: LanguagePickerKind?
    @State private var preparedTranslators: [TranslationPair: AppleSubtitleTranslator] = [:]
    @State private var translationStates: [TranslationPair: TranslationPreparationState] = [:]
    @State private var translationSessionGeneration = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    QuickSRTPalette.backdropTop,
                    QuickSRTPalette.backdropMiddle,
                    QuickSRTPalette.backdropBottom
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                header
                controlBar
                progressPanel
                queuePanel
                modelStrip
                outputPanel
                versionFooter
            }
            .padding(20)
            .background(QuickSRTPalette.shellFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(QuickSRTPalette.shellStroke, lineWidth: 1)
            )
            .shadow(color: QuickSRTPalette.shadow, radius: 28, y: 18)
            .padding(18)

            if let picker = activeLanguagePicker {
                languagePickerOverlay(picker)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }

            translationSessionHosts
        }
        .clipped()
        .preferredColorScheme(preferredColorScheme)
        .environment(\.locale, Locale(identifier: model.appLanguage.localeIdentifier))
        .onChange(of: model.recognitionLanguage) { _, _ in
            pruneTranslationSessions()
        }
        .onChange(of: model.subtitleLanguages) { _, _ in
            pruneTranslationSessions()
        }
        .onChange(of: model.queueJobs) { _, _ in
            pruneTranslationSessions()
        }
        .onChange(of: model.nextQueueJobID) { _, _ in
            startNextQueueJobIfPossible()
        }
        .onChange(of: model.translatorResetRevision) { _, _ in
            restartTranslationSessions()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("QuickSRT")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(QuickSRTPalette.text)
                }

                Text(model.text(.tagline))
                    .font(.system(size: 13))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
                    .lineLimit(2)
            }

            Spacer()

            HStack(spacing: 8) {
                appearanceButton
                interfaceLanguageButton
            }
        }
    }

    private var preferredColorScheme: ColorScheme {
        switch model.appearanceMode {
        case .light: return .light
        case .dark: return .dark
        }
    }

    private var appearanceButton: some View {
        Button {
            model.cycleAppearance()
        } label: {
            Image(systemName: "moon.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 24, height: 30)
        }
        .quickSRTButtonStyle()
        .help(model.appearanceHelpText)
        .accessibilityLabel(model.appearanceHelpText)
    }

    private var interfaceLanguageButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                activeLanguagePicker = .interface
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                Text(model.appLanguage.shortCode)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
            }
            .padding(.horizontal, 4)
            .frame(height: 30)
        }
        .quickSRTButtonStyle()
        .help(model.text(.interfaceLanguage))
        .accessibilityLabel(model.text(.interfaceLanguage))
        .accessibilityValue(model.appLanguage.nativeName)
    }

    private var versionFooter: some View {
        let versionText = AppVersionInfo().displayText(language: model.appLanguage)
        let accessibilityText = TextKey.applicationAccessibilityFormat.formatted(
            language: model.appLanguage,
            arguments: [versionText]
        )

        return HStack {
            Text(versionText)
                .font(.footnote)
                .foregroundStyle(QuickSRTPalette.secondaryText)
                .accessibilityLabel(accessibilityText)
                .allowsHitTesting(false)

            Link("GitHub", destination: AppLinks.github)
                .font(.footnote)
                .help("GitHub")

            Spacer()
        }
    }

    private var controlBar: some View {
        HStack(alignment: .center, spacing: 10) {
            chooseVideoButton
            selectedVideoPill

            Divider()
                .frame(height: 34)
                .padding(.horizontal, 2)

            languagePairControls
            Spacer(minLength: 12)
            durationLabel
            Spacer(minLength: 12)
            startButton
            stopButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(QuickSRTPalette.barFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QuickSRTPalette.panelStroke, lineWidth: 1)
        )
    }

    private var chooseVideoButton: some View {
        Button {
            model.selectVideo()
        } label: {
            Label(model.text(.queueAdd), systemImage: "video.badge.plus")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 28)
        }
        .controlSize(.large)
        .quickSRTButtonStyle()
        .accessibilityIdentifier("queue.addVideo")
        .disabled(model.isDownloadingModel)
    }

    private var selectedVideoPill: some View {
        InfoPill(icon: "doc.text", text: model.selectedFileName)
            .frame(minWidth: 174, idealWidth: 210, maxWidth: 236)
    }

    private var durationLabel: some View {
        Label(model.durationText, systemImage: "clock")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(QuickSRTPalette.secondaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .combine)
    }

    private var languagePairControls: some View {
        HStack(spacing: 6) {
            languageButton(
                title: model.text(.sourceLanguage),
                language: model.recognitionLanguage,
                icon: "waveform",
                picker: .source
            )

            Image(systemName: "arrow.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(QuickSRTPalette.secondaryText)
                .accessibilityHidden(true)

            targetLanguagesButton
        }
    }

    private func languageButton(
        title: String,
        language: RecognitionLanguage,
        icon: String,
        picker: LanguagePickerKind
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                activeLanguagePicker = picker
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(QuickSRTPalette.secondaryText)
                    Text(language.targetPickerTitle(model.appLanguage))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
            }
            .frame(minWidth: 126, idealWidth: 142, minHeight: 30, alignment: .leading)
        }
        .controlSize(.large)
        .quickSRTButtonStyle()
        .disabled(!model.canEditSelectedJob)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(language.targetPickerTitle(model.appLanguage))
    }

    private var targetLanguagesButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                activeLanguagePicker = .target
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "captions.bubble")
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.text(.subtitleLanguage))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(QuickSRTPalette.secondaryText)
                    Text(model.subtitleLanguageSummary)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
                translationReadinessIndicator
            }
            .frame(minWidth: 176, idealWidth: 205, minHeight: 30, alignment: .leading)
        }
        .controlSize(.large)
        .quickSRTButtonStyle()
        .disabled(!model.canEditSelectedJob)
        .help(model.text(.subtitleLanguage))
        .accessibilityLabel(model.text(.subtitleLanguage))
        .accessibilityValue(model.subtitleLanguageSummary)
    }

    @ViewBuilder
    private var translationReadinessIndicator: some View {
        switch aggregateTranslationState {
        case .preparing:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(QuickSRTPalette.success)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
        case .notRequired:
            EmptyView()
        }
    }

    private func languagePickerOverlay(_ picker: LanguagePickerKind) -> some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: closeLanguagePicker)

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: picker.symbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(QuickSRTPalette.accent)
                        .frame(width: 34, height: 34)
                        .background(QuickSRTPalette.accent.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                    Text(model.text(picker.titleKey))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(QuickSRTPalette.text)

                    Spacer()

                    Button(action: closeLanguagePicker) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .background(QuickSRTPalette.pillFill)
                    .clipShape(Circle())
                    .help(model.text(.close))
                    .accessibilityLabel(model.text(.close))
                }

                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())],
                    spacing: 10
                ) {
                    if picker == .interface {
                        ForEach(AppLanguage.allCases) { language in
                            interfaceLanguageChoice(language)
                        }
                    } else {
                        ForEach(RecognitionLanguage.allCases) { language in
                            subtitleLanguageChoice(language, picker: picker)
                        }
                    }
                }

                if picker == .target {
                    Divider()

                    HStack {
                        Text("\(model.selectedSubtitleLanguages.count) / \(RecognitionLanguage.allCases.count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(QuickSRTPalette.secondaryText)

                        Spacer()

                        Button(model.text(.done), action: closeLanguagePicker)
                            .controlSize(.large)
                            .buttonStyle(.borderedProminent)
                            .tint(QuickSRTPalette.accent)
                            .disabled(model.selectedSubtitleLanguages.isEmpty)
                    }
                }
            }
            .padding(20)
            .frame(width: 470)
            .background(.ultraThinMaterial)
            .background(QuickSRTPalette.panelFill)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.95), lineWidth: 1)
            )
            .shadow(color: QuickSRTPalette.shadow, radius: 30, y: 14)
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func interfaceLanguageChoice(_ language: AppLanguage) -> some View {
        let selected = language == model.appLanguage
        return Button {
            model.appLanguage = language
            closeLanguagePicker()
        } label: {
            languageChoiceLabel(
                nativeName: language.nativeName,
                code: language.shortCode,
                selected: selected,
                beta: false
            )
        }
        .buttonStyle(.plain)
    }

    private func subtitleLanguageChoice(
        _ language: RecognitionLanguage,
        picker: LanguagePickerKind
    ) -> some View {
        let selected = picker == .source
            ? language == model.recognitionLanguage
            : model.subtitleLanguages.contains(language)
        return Button {
            if picker == .source {
                model.recognitionLanguage = language
                closeLanguagePicker()
            } else {
                model.toggleSubtitleLanguage(language)
            }
        } label: {
            languageChoiceLabel(
                nativeName: language.nativeName,
                code: language.title,
                selected: selected,
                beta: picker == .source && language.isBeta
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.canEditSelectedJob)
    }

    private func languageChoiceLabel(
        nativeName: String,
        code: String,
        selected: Bool,
        beta: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.white : QuickSRTPalette.secondaryText)
            Text(nativeName)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if beta {
                Text(model.text(.beta))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(selected ? Color.white.opacity(0.2) : Color.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            Text(code)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(selected ? Color.white.opacity(0.9) : QuickSRTPalette.secondaryText)
        }
        .foregroundStyle(selected ? Color.white : QuickSRTPalette.text)
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(selected ? QuickSRTPalette.accent : QuickSRTPalette.pillFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.clear : QuickSRTPalette.panelStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var translationCanStart: Bool {
        !model.selectedSubtitleLanguages.isEmpty
            && requiredTranslationPairs.allSatisfy { translationStates[$0] == .ready }
    }

    private var requiredTranslationPairs: [TranslationPair] {
        model.requiredTranslationPairs
    }

    private var aggregateTranslationState: TranslationPreparationState {
        let pairs = requiredTranslationPairs
        guard !pairs.isEmpty else { return .notRequired }
        if pairs.contains(where: { translationStates[$0] == .failed }) {
            return .failed
        }
        return pairs.allSatisfy { translationStates[$0] == .ready } ? .ready : .preparing
    }

    private var translationSessionHosts: some View {
        ForEach(requiredTranslationPairs) { pair in
            TargetTranslationSessionHost(
                pair: pair,
                onPreparing: {
                    translationStates[pair] = .preparing
                },
                onReady: { translator in
                    preparedTranslators[pair] = translator
                    translationStates[pair] = .ready
                    startNextQueueJobIfPossible()
                },
                onFailure: { error in
                    preparedTranslators[pair] = nil
                    translationStates[pair] = .failed
                    model.presentTranslationError(error)
                }
            )
            .id("\(pair.id)-\(translationSessionGeneration)")
            .frame(width: 0, height: 0)
            .hidden()
        }
    }

    private func closeLanguagePicker() {
        withAnimation(.easeOut(duration: 0.14)) {
            activeLanguagePicker = nil
        }
    }

    private func pruneTranslationSessions() {
        let required = Set(requiredTranslationPairs)
        for pair in preparedTranslators.keys where !required.contains(pair) {
            preparedTranslators[pair]?.cancel()
            preparedTranslators[pair] = nil
            translationStates[pair] = nil
        }
        for pair in translationStates.keys where !required.contains(pair) {
            translationStates[pair] = nil
        }
    }

    private func restartTranslationSessions() {
        preparedTranslators.values.forEach { $0.cancel() }
        preparedTranslators = [:]
        translationStates = [:]
        translationSessionGeneration += 1
    }

    private var startButton: some View {
        Button {
            let translators = preparedTranslatorMap
            model.start(translators: translators)
        } label: {
            Label(model.text(.queueStart), systemImage: "play.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 28)
        }
        .keyboardShortcut(.defaultAction)
        .controlSize(.large)
        .quickSRTButtonStyle(prominent: true)
        .tint(QuickSRTPalette.accent)
        .accessibilityIdentifier("queue.start")
        .disabled(!model.canStart || !translationCanStart)
    }

    private var stopButton: some View {
        Button {
            model.stop()
        } label: {
            Label(model.text(.queuePause), systemImage: "pause.fill")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(minHeight: 28)
        }
        .controlSize(.large)
        .quickSRTButtonStyle()
        .accessibilityIdentifier("queue.pause")
        .disabled(!model.isQueueActive)
    }

    private var preparedTranslatorMap: [TranslationPair: SubtitleTranslating] {
        Dictionary(uniqueKeysWithValues: requiredTranslationPairs.compactMap { pair in
            preparedTranslators[pair].map { (pair, $0 as SubtitleTranslating) }
        })
    }

    private func startNextQueueJobIfPossible() {
        guard model.isQueueActive, model.nextQueueJobID != nil else { return }
        let needed = Set(model.requiredTranslationPairs)
        guard needed.allSatisfy({ translationStates[$0] == .ready }) else { return }
        model.continueQueue(translators: preparedTranslatorMap)
    }

    private var progressPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(model.text(.progress))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(QuickSRTPalette.text)
                Spacer()
                if !model.currentETAText.isEmpty {
                    Text(model.currentETAText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(QuickSRTPalette.secondaryText)
                }
                Text("\(Int((model.progressValue * 100).rounded()))%")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
            }

            ProgressView(value: model.progressValue)
                .progressViewStyle(.linear)
                .tint(.blue)

            VStack(spacing: 0) {
                ForEach(PipelineStage.allCases) { stage in
                    StepRow(
                        stage: stage,
                        title: model.text(stage.key),
                        state: stepState(for: stage),
                        trailing: trailingText(for: stage),
                        accessibilityState: stepAccessibilityState(for: stage)
                    )
                }
            }

            Divider()

            HStack(spacing: 6) {
                Text(completionSummaryPrefix)
                    .font(.system(size: 13))
                    .foregroundStyle(QuickSRTPalette.secondaryText)

                if let outputURL = model.outputURL {
                    Text(outputDisplayName(outputURL))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if !model.outputURLs.isEmpty {
                    Button {
                        model.openOutputInFinder()
                    } label: {
                        Label(model.text(.openSRT), systemImage: "folder")
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(18)
        .background(QuickSRTPalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QuickSRTPalette.panelStroke, lineWidth: 1)
        )
    }

    private var queuePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(model.text(.queueTitle), systemImage: "list.number")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(QuickSRTPalette.text)
                Spacer()
                Text(TextKey.videosCountFormat.formatted(
                    language: model.appLanguage,
                    arguments: [Int64(model.queueJobs.count)]
                ))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(QuickSRTPalette.secondaryText)
            }

            if model.queueJobs.isEmpty {
                Text(model.text(.queueEmpty))
                    .font(.system(size: 12))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(model.queueJobs.enumerated()), id: \.element.id) { index, job in
                            queueRow(job, index: index)
                        }
                    }
                }
                .frame(height: 112)
            }
        }
        .padding(12)
        .background(QuickSRTPalette.stripFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QuickSRTPalette.panelStroke, lineWidth: 1)
        )
    }

    private func queueRow(_ job: TranscriptionQueueJob, index: Int) -> some View {
        let selected = model.selectedQueueJobID == job.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: queueSymbol(job.state))
                    .foregroundStyle(queueColor(job.state))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.videoURL.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(QuickSRTPalette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(job.sourceLanguage.title) → \(job.selectedTargets.map(\.title).joined(separator: ", ")) · \(model.queueDurationText(for: job)) · \(model.queueStateText(job.state))")
                        .font(.system(size: 10))
                        .foregroundStyle(QuickSRTPalette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if job.state == .running {
                    Button {
                        model.cancelActiveAndContinue()
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .buttonStyle(.plain)
                    .help(model.text(.queueCancelCurrent))
                } else {
                    Button { model.moveQueueJob(job.id, offset: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == 0 || model.isQueueActive || !job.state.isEditable)
                    .help(model.text(.queueMoveUp))

                    Button { model.moveQueueJob(job.id, offset: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == model.queueJobs.count - 1 || model.isQueueActive || !job.state.isEditable)
                    .help(model.text(.queueMoveDown))

                    Button { model.removeQueueJob(job.id) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .disabled(job.state == .inspecting)
                    .help(model.text(.queueRemove))
                }
            }

            if job.state == .running || job.progressValue > 0 {
                ProgressView(value: job.progressValue)
                    .progressViewStyle(.linear)
                    .tint(queueColor(job.state))
            }

            if let checkText = model.languageCheckText(for: job) {
                HStack(spacing: 8) {
                    Text(checkText)
                        .font(.system(size: 10))
                        .foregroundStyle(job.state == .needsAttention ? Color.orange : QuickSRTPalette.secondaryText)
                        .lineLimit(2)
                    Spacer()
                    if case let .mismatch(result) = job.languageCheck {
                        if result.recognizedLanguage != nil {
                            Button(model.text(.useDetectedLanguage)) {
                                model.useDetectedLanguage(for: job.id)
                            }
                            .controlSize(.mini)
                        }
                        Button(model.text(.keepSelectedLanguage)) {
                            model.keepSelectedLanguage(for: job.id)
                        }
                        .controlSize(.mini)
                    } else if case .failed = job.languageCheck {
                        Button(model.text(.retryDetection)) {
                            model.retryLanguageDetection(for: job.id)
                        }
                        .controlSize(.mini)
                        Button(model.text(.continueSelected)) {
                            model.keepSelectedLanguage(for: job.id)
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(selected ? QuickSRTPalette.accent.opacity(0.10) : QuickSRTPalette.pillFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? QuickSRTPalette.accent.opacity(0.55) : QuickSRTPalette.panelStroke, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { model.selectQueueJob(job.id) }
    }

    private func queueSymbol(_ state: TranscriptionQueueJobState) -> String {
        switch state {
        case .waitingForInspection, .waitingForTranslation: return "clock"
        case .inspecting, .running: return "arrow.triangle.2.circlepath"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .ready: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle.fill"
        case .completedWithWarnings: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "nosign"
        }
    }

    private func queueColor(_ state: TranscriptionQueueJobState) -> Color {
        switch state {
        case .running, .inspecting: return QuickSRTPalette.accent
        case .completed, .ready: return QuickSRTPalette.success
        case .needsAttention, .completedWithWarnings, .paused: return .orange
        case .failed: return .red
        case .cancelled, .waitingForInspection, .waitingForTranslation: return QuickSRTPalette.secondaryText
        }
    }

    private func outputDisplayName(_ firstURL: URL) -> String {
        let additional = model.outputURLs.count - 1
        return additional > 0 ? "\(firstURL.lastPathComponent)  +\(additional)" : firstURL.lastPathComponent
    }

    private var modelStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(QuickSRTPalette.accent.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(model.text(.modelTitle))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(QuickSRTPalette.text)

                    ModelBadge(
                        text: modelBadgeText,
                        color: modelBadgeColor
                    )
                }

                Text(modelDetailText)
                    .font(.system(size: 11))
                    .foregroundStyle(QuickSRTPalette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(model.isModelInstalled ? model.text(.approximateModelSize) : model.text(.modelRepo))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(QuickSRTPalette.secondaryText)
                .lineLimit(1)

            if model.isDownloadingModel {
                ProgressView()
                    .controlSize(.small)
                Button {
                    model.stopModelDownload()
                } label: {
                    Image(systemName: "xmark")
                }
                .help(model.text(.modelStopDownload))
                .accessibilityLabel(model.text(.modelStopDownload))
                .accessibilityIdentifier("model.cancelDownload")
            } else if model.isModelInstalled {
                Button {
                    model.downloadModel()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help(model.text(.modelUpdate))
                .accessibilityLabel(model.text(.modelUpdate))
                .accessibilityIdentifier("model.update")
                .disabled(model.isRunning || model.isInspecting)

                Button {
                    model.chooseExistingModel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(model.text(.modelChooseExisting))
                .accessibilityLabel(model.text(.modelChooseExisting))
                .disabled(model.isRunning || model.isInspecting)

                Button {
                    model.openModelFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .help(model.text(.modelOpenFolder))
                .accessibilityLabel(model.text(.modelOpenFolder))
            } else {
                Button {
                    model.chooseExistingModel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .help(model.text(.modelChooseExisting))
                .accessibilityLabel(model.text(.modelChooseExisting))

                Button {
                    model.downloadModel()
                } label: {
                    Label(model.text(.modelDownload), systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(QuickSRTPalette.accent)
                .accessibilityIdentifier("model.download")
                .disabled(model.isRunning || model.isInspecting)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(QuickSRTPalette.modelFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QuickSRTPalette.panelStroke, lineWidth: 1)
        )
    }

    private var outputPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.text(.lastOutput))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(QuickSRTPalette.text)
                Spacer()
                Button {
                    model.clearLog()
                } label: {
                    Label(model.text(.clear), systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(model.logText.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(QuickSRTPalette.outputHeaderFill)

            ScrollView {
                Text(model.logText.isEmpty ? model.text(.emptyLog) : model.logText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(QuickSRTPalette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
            .frame(height: 112)
        }
        .background(QuickSRTPalette.panelFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(QuickSRTPalette.panelStroke, lineWidth: 1)
        )
    }

    private var modelBadgeText: String {
        if model.isDownloadingModel {
            return model.text(.modelDownloading)
        }

        return model.isModelInstalled ? model.text(.modelInstalled) : model.text(.modelMissing)
    }

    private var modelBadgeColor: Color {
        if model.isDownloadingModel {
            return QuickSRTPalette.accent
        }

        return model.isModelInstalled ? QuickSRTPalette.success : .red
    }

    private var modelDetailText: String {
        if model.isDownloadingModel {
            return model.text(.modelRepo)
        }

        if model.isModelInstalled {
            return model.modelLocationText
        }
        return model.text(.modelMissingDetail)
    }

    private func stepState(for stage: PipelineStage) -> StepVisualState {
        if let stoppedStage = model.stoppedStage {
            if stage.order < stoppedStage.order {
                return .done
            }

            if stage == stoppedStage {
                return .stopped
            }

            return .pending
        }

        if let failedStage = model.failedStage {
            if stage.order < failedStage.order {
                return .done
            }

            if stage == failedStage {
                return .failed
            }

            return .pending
        }

        if model.finishedSuccessfully {
            return .done
        }

        if model.finishedWithPartialExport {
            return stage == .done ? .warning : .done
        }

        guard let current = model.currentStage else {
            return .pending
        }

        if stage.order < current.order {
            return .done
        }

        if stage == current {
            return model.isRunning || model.isInspecting ? .active : .done
        }

        return .pending
    }

    private func trailingText(for stage: PipelineStage) -> String {
        if stage == .done && model.finishedSuccessfully {
            return model.text(.completed)
        }

        if stage == .done && model.finishedWithPartialExport {
            return model.text(.queueCompletedWarnings)
        }

        let state = stepState(for: stage)
        switch state {
        case .done:
            return model.stageTimingText[stage] ?? model.text(.ok)
        case .active:
            return model.stageTimingText[stage] ?? ""
        case .failed:
            return model.text(.error)
        case .warning:
            return model.text(.queueCompletedWarnings)
        case .stopped:
            return model.text(.stopped)
        case .pending:
            return ""
        }
    }

    private func stepAccessibilityState(for stage: PipelineStage) -> String {
        switch stepState(for: stage) {
        case .pending: return model.text(.pending)
        case .active: return model.text(.progress)
        case .done: return model.text(.completed)
        case .failed: return model.text(.error)
        case .warning: return model.text(.queueCompletedWarnings)
        case .stopped: return model.text(.stopped)
        }
    }

    private var completionSummaryPrefix: String {
        if model.finishedSuccessfully {
            return model.text(.finishedPrefix)
        }
        if model.finishedWithPartialExport {
            return model.text(.queueCompletedWarnings)
        }
        return model.outputLanguageNote
    }
}

private enum LanguagePickerKind: Equatable {
    case interface
    case source
    case target

    var titleKey: TextKey {
        switch self {
        case .interface: return .selectInterfaceLanguage
        case .source: return .selectSourceLanguage
        case .target: return .selectSubtitleLanguage
        }
    }

    var symbol: String {
        switch self {
        case .interface: return "globe"
        case .source: return "waveform"
        case .target: return "captions.bubble"
        }
    }
}

private struct TargetTranslationSessionHost: View {
    let pair: TranslationPair
    let onPreparing: () -> Void
    let onReady: (AppleSubtitleTranslator) -> Void
    let onFailure: (Error) -> Void

    @State private var configuration: TranslationSession.Configuration

    init(
        pair: TranslationPair,
        onPreparing: @escaping () -> Void,
        onReady: @escaping (AppleSubtitleTranslator) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        self.pair = pair
        self.onPreparing = onPreparing
        self.onReady = onReady
        self.onFailure = onFailure

        let source = Locale.Language(identifier: pair.source.translationLocaleIdentifier)
        let target = Locale.Language(identifier: pair.target.translationLocaleIdentifier)
        let initialConfiguration: TranslationSession.Configuration
#if compiler(>=6.2)
        if #available(macOS 26.4, *) {
            initialConfiguration = TranslationSession.Configuration(
                source: source,
                target: target,
                preferredStrategy: .highFidelity
            )
        } else {
            initialConfiguration = TranslationSession.Configuration(source: source, target: target)
        }
#else
        initialConfiguration = TranslationSession.Configuration(source: source, target: target)
#endif
        _configuration = State(initialValue: initialConfiguration)
    }

    var body: some View {
        Color.clear
            .translationTask(configuration) { session in
                onPreparing()
                let source = Locale.Language(identifier: pair.source.translationLocaleIdentifier)
                let target = Locale.Language(identifier: pair.target.translationLocaleIdentifier)
                let availability: LanguageAvailability
#if compiler(>=6.2)
                if #available(macOS 26.4, *) {
                    availability = LanguageAvailability(preferredStrategy: .highFidelity)
                } else {
                    availability = LanguageAvailability()
                }
#else
                availability = LanguageAvailability()
#endif

                let status = await availability.status(from: source, to: target)
                guard status != .unsupported else {
                    onFailure(QuickSRTError.translationPairUnsupported(
                        source: pair.source,
                        target: pair.target
                    ))
                    return
                }

                do {
                    let translator = AppleSubtitleTranslator(session: session)
                    try await translator.prepare()
                    try Task.checkCancellation()
                    onReady(translator)
                    await translator.holdSession()
                } catch is CancellationError {
                    return
                } catch {
                    onFailure(QuickSRTError.translationFailed(error.localizedDescription))
                }
            }
    }
}

private enum TranslationPreparationState: Equatable {
    case preparing
    case ready
    case notRequired
    case failed
}

private struct InfoPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(QuickSRTPalette.secondaryText)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(QuickSRTPalette.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(QuickSRTPalette.pillFill)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(QuickSRTPalette.panelStroke, lineWidth: 1)
        )
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(QuickSRTPalette.text)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(QuickSRTPalette.text)
                .lineLimit(2)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ModelBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

private struct StepRow: View {
    let stage: PipelineStage
    let title: String
    let state: StepVisualState
    let trailing: String
    let accessibilityState: String

    var body: some View {
        let accessibilityValue = [accessibilityState, trailing]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")

        HStack(spacing: 14) {
            Image(systemName: state.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 22)
                .accessibilityHidden(true)

            Image(systemName: stage.symbol)
                .font(.system(size: 17))
                .foregroundStyle(QuickSRTPalette.text)
                .frame(width: 24)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 15, weight: stage == .done ? .semibold : .regular))
                .foregroundStyle(state == .active ? QuickSRTPalette.accent : QuickSRTPalette.text)

            Spacer()

            Text(trailing)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(state.trailingColor)
        }
        .frame(height: 38)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

private enum StepVisualState {
    case pending
    case active
    case done
    case warning
    case failed
    case stopped

    var symbol: String {
        switch self {
        case .pending: return "circle"
        case .active: return "smallcircle.filled.circle"
        case .done: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .stopped: return "stop.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return QuickSRTPalette.secondaryText
        case .active: return QuickSRTPalette.accent
        case .done: return QuickSRTPalette.success
        case .warning: return .orange
        case .failed: return .red
        case .stopped: return .orange
        }
    }

    var trailingColor: Color {
        switch self {
        case .active: return QuickSRTPalette.accent
        case .failed: return .red
        case .done: return QuickSRTPalette.successText
        case .warning, .stopped: return .orange
        case .pending: return QuickSRTPalette.secondaryText
        }
    }
}

private enum QuickSRTPalette {
    static let backdropTop = adaptive(
        light: NSColor(red: 0.82, green: 0.91, blue: 1.0, alpha: 1),
        dark: NSColor(red: 0.055, green: 0.085, blue: 0.15, alpha: 1)
    )
    static let backdropMiddle = adaptive(
        light: NSColor(red: 0.98, green: 0.995, blue: 1.0, alpha: 1),
        dark: NSColor(red: 0.075, green: 0.105, blue: 0.17, alpha: 1)
    )
    static let backdropBottom = adaptive(
        light: NSColor(red: 0.74, green: 0.88, blue: 1.0, alpha: 1),
        dark: NSColor(red: 0.035, green: 0.07, blue: 0.13, alpha: 1)
    )
    static let shellFill = adaptive(
        light: NSColor(red: 0.965, green: 0.985, blue: 1.0, alpha: 0.94),
        dark: NSColor(red: 0.09, green: 0.115, blue: 0.17, alpha: 0.94)
    )
    static let shellStroke = adaptive(light: NSColor.white.withAlphaComponent(0.9), dark: NSColor.white.withAlphaComponent(0.14))
    static let panelFill = adaptive(
        light: NSColor(red: 0.985, green: 0.992, blue: 1.0, alpha: 0.96),
        dark: NSColor(red: 0.105, green: 0.13, blue: 0.19, alpha: 0.96)
    )
    static let barFill = adaptive(
        light: NSColor(red: 0.94, green: 0.975, blue: 1.0, alpha: 0.92),
        dark: NSColor(red: 0.085, green: 0.12, blue: 0.19, alpha: 0.92)
    )
    static let stripFill = adaptive(
        light: NSColor(red: 0.955, green: 0.985, blue: 1.0, alpha: 0.9),
        dark: NSColor(red: 0.08, green: 0.115, blue: 0.18, alpha: 0.92)
    )
    static let modelFill = panelFill
    static let outputHeaderFill = stripFill
    static let pillFill = adaptive(light: NSColor.white.withAlphaComponent(0.78), dark: NSColor.white.withAlphaComponent(0.07))
    static let panelStroke = adaptive(
        light: NSColor(red: 0.48, green: 0.58, blue: 0.68, alpha: 0.18),
        dark: NSColor.white.withAlphaComponent(0.13)
    )
    static let text = adaptive(
        light: NSColor(red: 0.06, green: 0.075, blue: 0.095, alpha: 1),
        dark: NSColor(red: 0.93, green: 0.95, blue: 0.98, alpha: 1)
    )
    static let secondaryText = adaptive(
        light: NSColor(red: 0.36, green: 0.40, blue: 0.46, alpha: 1),
        dark: NSColor(red: 0.64, green: 0.69, blue: 0.77, alpha: 1)
    )
    static let accent = Color(red: 0.11, green: 0.42, blue: 0.93)
    static let success = Color(red: 0.28, green: 0.66, blue: 0.31)
    static let successText = adaptive(
        light: NSColor(red: 0.18, green: 0.45, blue: 0.17, alpha: 1),
        dark: NSColor(red: 0.48, green: 0.82, blue: 0.48, alpha: 1)
    )
    static let shadow = adaptive(
        light: NSColor(red: 0.08, green: 0.20, blue: 0.36, alpha: 0.18),
        dark: NSColor.black.withAlphaComponent(0.42)
    )

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

private extension View {
    @ViewBuilder
    func quickSRTButtonStyle(prominent: Bool = false) -> some View {
#if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
#else
        if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
#endif
    }
}

private extension PipelineStage {
    var order: Int {
        switch self {
        case .checkingVideo: return 0
        case .extractingAudio: return 1
        case .transcribingSpeech: return 2
        case .translatingSubtitles: return 3
        case .savingSRT: return 4
        case .done: return 5
        }
    }

    var symbol: String {
        switch self {
        case .checkingVideo: return "movieclapper"
        case .extractingAudio: return "waveform"
        case .transcribingSpeech: return "captions.bubble"
        case .translatingSubtitles: return "character.book.closed"
        case .savingSRT: return "doc.text"
        case .done: return "checkmark.seal"
        }
    }
}
