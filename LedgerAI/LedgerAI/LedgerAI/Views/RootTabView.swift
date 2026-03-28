import SwiftData
import PhotosUI
import SwiftUI

struct RootTabView: View {
    private let buildBadge = "UI-R15"
    private let pageBackground = Color.white
    private let topGrayBackground = Color(red: 237 / 255, green: 237 / 255, blue: 237 / 255)
    private let cardBorder = Color(red: 229 / 255, green: 229 / 255, blue: 234 / 255)
    private let ledgerRowHeight: CGFloat = 76

    private enum TopMode: String, CaseIterable, Identifiable {
        case ledger
        case stats

        var id: String { rawValue }

        var title: String {
            switch self {
            case .ledger: return "账单"
            case .stats: return "统计"
            }
        }
    }

    private struct EditableForm: Identifiable {
        let id = UUID()
        var sourceType: InputSourceType
        var rawText: String
        var amountCNY: Double
        var amountText: String
        var occurredAt: Date
        var merchant: String
        var channel: PaymentChannel
        var categoryID: UUID?
        var categoryName: String
        var confidence: Double
        var note: String
        var engine: RecognitionEngine
        var engineDetail: String?

        init(
            sourceType: InputSourceType,
            rawText: String,
            amountCNY: Double,
            amountText: String? = nil,
            occurredAt: Date,
            merchant: String,
            channel: PaymentChannel,
            categoryID: UUID?,
            categoryName: String,
            confidence: Double,
            note: String,
            engine: RecognitionEngine,
            engineDetail: String? = nil
        ) {
            self.sourceType = sourceType
            self.rawText = rawText
            self.amountCNY = amountCNY
            self.amountText = amountText ?? AmountInputFormatter.display(amountCNY)
            self.occurredAt = occurredAt
            self.merchant = merchant
            self.channel = channel
            self.categoryID = categoryID
            self.categoryName = categoryName
            self.confidence = confidence
            self.note = note
            self.engine = engine
            self.engineDetail = engineDetail
        }

        init(from form: RecognizedTransactionForm) {
            sourceType = form.sourceType
            rawText = form.rawText
            amountCNY = form.amountCNY
            amountText = AmountInputFormatter.display(form.amountCNY)
            occurredAt = form.occurredAt
            merchant = form.merchant
            channel = form.channel
            categoryID = form.categoryID
            categoryName = form.categoryName
            confidence = form.confidence
            note = form.note
            engine = form.engine
            engineDetail = form.engineDetail
        }

        var toRecognizedForm: RecognizedTransactionForm {
            RecognizedTransactionForm(
                sourceType: sourceType,
                rawText: rawText,
                amountCNY: AmountInputFormatter.parse(amountText) ?? amountCNY,
                occurredAt: occurredAt,
                merchant: merchant,
                channel: channel,
                categoryID: categoryID,
                categoryName: categoryName,
                confidence: confidence,
                note: note,
                engine: engine,
                engineDetail: engineDetail
            )
        }
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse) private var allRecords: [TransactionRecord]
    @Query(sort: \Category.order) private var categories: [Category]

    @StateObject private var speechService = SpeechRecognizerService()
    @State private var selectedMonth: Date = .now
    @State private var topMode: TopMode = .ledger
    @State private var showMonthPicker = false
    @State private var showSettingsSheet = false
    @State private var showVoiceReviewSheet = false
    @State private var showManualEntrySheet = false
    @State private var editingRecord: TransactionRecord?
    @State private var pendingDeleteRecord: TransactionRecord?
    @State private var isManualSaving = false
    @State private var manualSaveErrorMessage: String?
    @State private var selectedBillImageItem: PhotosPickerItem?
    @State private var voiceForms: [EditableForm] = []
    @State private var manualForm = EditableForm(
        sourceType: .text,
        rawText: "",
        amountCNY: 0,
        amountText: "",
        occurredAt: .now,
        merchant: "",
        channel: .unknown,
        categoryID: nil,
        categoryName: "未分类",
        confidence: 1,
        note: "",
        engine: .local
    )
    @State private var ledgerCardScrollOffset: CGFloat = 0
    @State private var voiceStatusMessage = "长按 Speak 开始语音记账。"
    @State private var isHandlingVoice = false
    @State private var permissionChecked = false

    private let intakeService = LedgerIntakeService()

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let safeTop = proxy.safeAreaInsets.top
                let safeBottom = proxy.safeAreaInsets.bottom
                // Visual distance from gray container bottom to screen bottom should be 114px.
                // Since current layout is inside safe-area, subtract bottom inset here.
                let bottomAreaHeight: CGFloat = max(56, 114 - safeBottom)
                let topContainerShape = UnevenRoundedRectangle(
                    cornerRadii: .init(
                        topLeading: 0,
                        bottomLeading: 40,
                        bottomTrailing: 40,
                        topTrailing: 0
                    ),
                    style: .continuous
                )

                ZStack {
                    pageBackground
                        .ignoresSafeArea()

                    VStack(spacing: 0) {
                        VStack(spacing: 10) {
                            topHeader
                            modePicker
                            topContent
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, safeTop + 8)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(topGrayBackground)
                        .clipShape(topContainerShape)
                        .overlay {
                            topContainerShape
                                .stroke(cardBorder, lineWidth: 0.5)
                        }
                        .overlay(alignment: .bottom) {
                            // Figma-like inner shadow attached to bottom curved edge.
                            topContainerShape
                                .stroke(Color.black.opacity(0.08), lineWidth: 8)
                                .blur(radius: 12)
                                .offset(y: 4)
                                .mask(
                                    topContainerShape.fill(
                                        LinearGradient(
                                            colors: [.clear, .black],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                                )
                        }
                        .ignoresSafeArea(edges: .top)

                        bottomDock
                            .padding(.horizontal, 20)
                            .padding(.top, 6)
                            .padding(.bottom, 0)
                            .frame(height: bottomAreaHeight, alignment: .center)
                            .background(pageBackground)
                    }
                }
            }
            .preferredColorScheme(.light)
            .task {
                try? SeedDataService.seedIfNeeded(context: modelContext)
                guard !permissionChecked else { return }
                permissionChecked = true
                _ = await speechService.requestPermission()
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showMonthPicker) {
                monthPickerSheet
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showVoiceReviewSheet) {
                voiceReviewSheet
            }
            .sheet(isPresented: $showManualEntrySheet) {
                manualEntrySheet
            }
            .onChange(of: selectedBillImageItem) { _, newItem in
                guard let newItem else { return }
                Task { await handlePickedImage(newItem) }
            }
            .onChange(of: showManualEntrySheet) { _, visible in
                if !visible {
                    editingRecord = nil
                }
            }
            .alert("确认删除这条账单？", isPresented: deleteAlertBinding) {
                Button("取消", role: .cancel) {
                    pendingDeleteRecord = nil
                }
                Button("删除", role: .destructive) {
                    guard let record = pendingDeleteRecord else { return }
                    deleteRecord(record)
                    pendingDeleteRecord = nil
                }
            } message: {
                Text("删除后无法恢复。")
            }
            .alert("保存失败", isPresented: manualSaveErrorBinding) {
                Button("我知道了", role: .cancel) {
                    manualSaveErrorMessage = nil
                }
            } message: {
                Text(manualSaveErrorMessage ?? "请检查输入后重试。")
            }
        }
    }

    private var monthRecords: [TransactionRecord] {
        allRecords.filter { selectedMonthRange.contains($0.occurredAt) }
    }

    private var confirmedMonthRecords: [TransactionRecord] {
        monthRecords.filter { $0.status == .confirmed }
    }

    private var selectedMonthRange: Range<Date> {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth)) ?? selectedMonth
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? .distantFuture
        return monthStart..<monthEnd
    }

    private var monthTitle: String {
        let month = Calendar.current.component(.month, from: selectedMonth)
        let cnMonths = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        guard (1...12).contains(month) else { return "本月" }
        return "\(cnMonths[month - 1])月"
    }

    private var monthTotal: Double {
        confirmedMonthRecords.reduce(0) { $0 + $1.amountCNY }
    }

    private var monthCount: Int {
        confirmedMonthRecords.count
    }

    private var topHeader: some View {
        HStack {
            Button {
                showMonthPicker = true
            } label: {
                HStack(spacing: 4) {
                    Text(monthTitle)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.black)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.black)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showSettingsSheet = true
            } label: {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(buildBadge)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.black.opacity(0.45))

                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(width: 32, height: 32)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var modePicker: some View {
        Picker("内容", selection: $topMode) {
            ForEach(TopMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(height: 32)
    }

    private var topContent: some View {
        Group {
            if topMode == .ledger {
                ledgerPanel
            } else {
                statisticsPanel
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var ledgerPanel: some View {
        GeometryReader { geo in
            let dividerHeight: CGFloat = 0.5
            let recordsCount = CGFloat(monthRecords.count)
            let contentIdealHeight = recordsCount * ledgerRowHeight + max(0, recordsCount - 1) * dividerHeight
            let maxCardHeight = max(0, geo.size.height - 8)
            let shouldScrollInsideCard = contentIdealHeight > maxCardHeight
            let maxScrollOffset = max(0, (contentIdealHeight + 8) - maxCardHeight)
            let currentScrollOffset = min(max(ledgerCardScrollOffset, 0), maxScrollOffset)
            let remainingContentHeight = max(0, (contentIdealHeight + 8) - currentScrollOffset)
            let minVisibleHeight = ledgerRowHeight + 8
            let cardHeight = shouldScrollInsideCard
                ? max(minVisibleHeight, min(maxCardHeight, remainingContentHeight))
                : min(contentIdealHeight, maxCardHeight)

            VStack(alignment: .leading, spacing: 0) {
                if monthRecords.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 36, weight: .regular))
                            .foregroundStyle(Color.black.opacity(0.35))
                        Text("这个月还没有记录")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.black.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white)
                        .overlay {
                            Group {
                                if shouldScrollInsideCard {
                                    ScrollView {
                                        VStack(spacing: 0) {
                                            rowsContent
                                            Color.clear.frame(height: 8)
                                        }
                                        .background(
                                            GeometryReader { proxy in
                                                Color.clear.preference(
                                                    key: LedgerCardScrollOffsetPreferenceKey.self,
                                                    value: -proxy.frame(in: .named("ledgerCardScroll")).minY
                                                )
                                            }
                                        )
                                    }
                                    .coordinateSpace(name: "ledgerCardScroll")
                                    .scrollIndicators(.hidden)
                                    .onPreferenceChange(LedgerCardScrollOffsetPreferenceKey.self) { value in
                                        ledgerCardScrollOffset = value
                                    }
                                } else {
                                    VStack(spacing: 0) {
                                        rowsContent
                                    }
                                    .onAppear { ledgerCardScrollOffset = 0 }
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(cardBorder, lineWidth: 0.5)
                        }
                        .frame(height: cardHeight, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: monthRecords.count) { _, _ in
                ledgerCardScrollOffset = 0
            }
        }
    }

    @ViewBuilder
    private var rowsContent: some View {
        ForEach(Array(monthRecords.enumerated()), id: \.element.id) { index, record in
            ledgerRow(record)
                .contentShape(Rectangle())
                .onTapGesture {
                    beginEditing(record)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("删除", role: .destructive) {
                        pendingDeleteRecord = record
                    }
                }

            if index < monthRecords.count - 1 {
                Divider()
                    .overlay(cardBorder)
            }
        }
    }

    private func ledgerRow(_ record: TransactionRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: record))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(record.merchant)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .lineLimit(1)

                Text(categoryName(for: record))
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255).opacity(0.6))
                    .lineLimit(1)
            }

            Spacer()

            Text("¥\(record.amountCNY, specifier: "%.2f")")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.black)
        }
        .padding(.horizontal, 16)
        .frame(height: ledgerRowHeight)
    }

    private var statisticsPanel: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.white)
            .overlay {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("本月支出")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("¥\(monthTotal, specifier: "%.2f")")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                            Text("\(monthCount) 笔已入账")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        VStack(spacing: 14) {
                            ForEach(categoryTotals, id: \.0.id) { item in
                                VStack(spacing: 8) {
                                    HStack {
                                        Label(item.0.name, systemImage: item.0.symbol)
                                            .font(.subheadline)
                                        Spacer()
                                        Text("¥\(item.1, specifier: "%.2f")")
                                            .font(.subheadline.weight(.semibold))
                                    }

                                    ProgressView(value: item.1, total: max(monthTotal, 0.01))
                                        .tint(.accentColor)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(cardBorder, lineWidth: 0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var categoryTotals: [(Category, Double)] {
        let grouped = Dictionary(grouping: confirmedMonthRecords, by: \.categoryID)
        let mapped = categories.compactMap { category -> (Category, Double)? in
            let total = grouped[category.id]?.reduce(0) { $0 + $1.amountCNY } ?? 0
            return total > 0 ? (category, total) : nil
        }
        return mapped.sorted { $0.1 > $1.1 }
    }

    private var bottomDock: some View {
        VStack(spacing: 6) {
            if speechService.isRecording || isHandlingVoice {
                Text(voiceStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 16) {
                PhotosPicker(selection: $selectedBillImageItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                Button {
                    editingRecord = nil
                    manualForm = EditableForm(
                        sourceType: .text,
                        rawText: "",
                        amountCNY: 0,
                        amountText: "",
                        occurredAt: .now,
                        merchant: "",
                        channel: .unknown,
                        categoryID: nil,
                        categoryName: "未分类",
                        confidence: 1,
                        note: "",
                        engine: .local
                    )
                    showManualEntrySheet = true
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.black)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)

                speakButton
            }
            .frame(height: 52)
        }
    }

    private var speakButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(Color.accentColor)

            HStack(spacing: 8) {
                Image(systemName: speechService.isRecording ? "waveform" : "mic")
                    .font(.system(size: 16, weight: .semibold))
                Text(isHandlingVoice ? "识别中..." : (speechService.isRecording ? "Listening" : "Speak"))
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.2, maximumDistance: 60)
                .onEnded { _ in }
        )
        .onLongPressGesture(minimumDuration: 0.2, maximumDistance: 60, pressing: { pressing in
            handleVoicePressing(pressing)
        }, perform: {})
    }

    private var monthPickerSheet: some View {
        NavigationStack {
            Form {
                DatePicker("选择月份", selection: $selectedMonth, displayedComponents: [.date])
                    .datePickerStyle(.graphical)
            }
            .navigationTitle("切换月份")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showMonthPicker = false }
                }
            }
        }
    }

    private var voiceReviewSheet: some View {
        NavigationStack {
            Form {
                ForEach(voiceForms.indices, id: \.self) { index in
                    Section("第 \(index + 1) 条") {
                        TextField("商户", text: $voiceForms[index].merchant)
                        HStack(spacing: 8) {
                            Text("¥")
                                .foregroundStyle(.secondary)
                            TextField("金额", text: amountBinding(for: index))
                                .keyboardType(.decimalPad)
                        }
                        DatePicker("支付时间", selection: $voiceForms[index].occurredAt, displayedComponents: [.date, .hourAndMinute])
                        Picker("支付方式", selection: $voiceForms[index].channel) {
                            ForEach(PaymentChannel.allCases, id: \.self) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                        Picker("分类", selection: $voiceForms[index].categoryID) {
                            Text("未分类").tag(Optional<UUID>.none)
                            ForEach(categories) { category in
                                Text(category.name).tag(Optional(category.id))
                            }
                        }
                        TextField("备注（可选）", text: $voiceForms[index].note)
                        Text("置信度：\(Int(voiceForms[index].confidence * 100))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("确认语音识别")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        voiceForms = []
                        showVoiceReviewSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveVoiceForms()
                    }
                }
            }
        }
    }

    private var manualEntrySheet: some View {
        NavigationStack {
            Form {
                Section("手动记账") {
                    TextField("商户", text: $manualForm.merchant)
                    HStack(spacing: 8) {
                        Text("¥")
                            .foregroundStyle(.secondary)
                        TextField("金额", text: $manualForm.amountText)
                            .keyboardType(.decimalPad)
                            .onChange(of: manualForm.amountText) { _, newValue in
                                let formatted = AmountInputFormatter.formatForEditing(newValue)
                                if formatted != newValue {
                                    manualForm.amountText = formatted
                                }
                                manualForm.amountCNY = AmountInputFormatter.parse(formatted) ?? 0
                            }
                    }
                    DatePicker("支付时间", selection: $manualForm.occurredAt, displayedComponents: [.date, .hourAndMinute])
                    Picker("支付方式", selection: $manualForm.channel) {
                        ForEach(PaymentChannel.allCases, id: \.self) { channel in
                            Text(channel.title).tag(channel)
                        }
                    }
                    Picker("分类", selection: $manualForm.categoryID) {
                        Text("未分类").tag(Optional<UUID>.none)
                        ForEach(categories) { category in
                            Text(category.name).tag(Optional(category.id))
                        }
                    }
                    TextField("备注（可选）", text: $manualForm.note)
                }
            }
            .navigationTitle(editingRecord == nil ? "手动输入" : "编辑账单")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        editingRecord = nil
                        showManualEntrySheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saveManualForm()
                    } label: {
                        if isManualSaving {
                            ProgressView()
                        } else {
                            Text("保存")
                        }
                    }
                    .disabled(isManualSaving)
                }
            }
        }
    }

    private func handleVoicePressing(_ pressing: Bool) {
        guard !isHandlingVoice else { return }
        if pressing {
            guard !speechService.isRecording else { return }
            do {
                try speechService.startRecording()
                voiceStatusMessage = "正在录音，请继续说完整消费信息。"
            } catch {
                voiceStatusMessage = "无法启动录音：\(error.localizedDescription)"
            }
        } else {
            guard speechService.isRecording else { return }
            speechService.stopRecording()
            isHandlingVoice = true
            voiceStatusMessage = "识别中..."
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await recognizeVoiceTranscript()
                isHandlingVoice = false
            }
        }
    }

    private func recognizeVoiceTranscript() async {
        let transcript = speechService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            voiceStatusMessage = "没有识别到语音内容，请重试。"
            return
        }

        let segments = splitVoiceEntries(from: transcript)
        var forms: [EditableForm] = []
        for segment in segments {
            do {
                let recognized = try await intakeService.recognize(
                    input: RecognitionInput(source: .voice, text: segment, image: nil, occurredAt: .now),
                    in: modelContext
                )
                forms.append(EditableForm(from: recognized))
            } catch {
                continue
            }
        }

        if forms.isEmpty {
            voiceStatusMessage = "语音已转写，但未识别到可入账内容。"
            return
        }

        voiceForms = forms
        showVoiceReviewSheet = true
        voiceStatusMessage = "识别到 \(forms.count) 条记录，请确认后保存。"
    }

    private func splitVoiceEntries(from transcript: String) -> [String] {
        let replaced = transcript
            .replacingOccurrences(of: "然后", with: "\n")
            .replacingOccurrences(of: "再", with: "\n")
            .replacingOccurrences(of: "另外", with: "\n")
            .replacingOccurrences(of: "。", with: "\n")
            .replacingOccurrences(of: "；", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")

        let parts = replaced
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        return parts.isEmpty ? [transcript] : parts
    }

    private func handlePickedImage(_ item: PhotosPickerItem) async {
        defer { selectedBillImageItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            voiceStatusMessage = "图片读取失败，请重试。"
            return
        }

        isHandlingVoice = true
        voiceStatusMessage = "图片识别中..."
        defer { isHandlingVoice = false }

        let ocrText = await OCRService.recognizeText(from: image).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ocrText.isEmpty else {
            voiceStatusMessage = "图片里没有识别到可用文字。"
            return
        }

        do {
            let recognized = try await intakeService.recognize(
                input: RecognitionInput(
                    source: .screenshot,
                    text: ocrText,
                    image: image,
                    occurredAt: .now
                ),
                in: modelContext
            )
            voiceForms = [EditableForm(from: recognized)]
            showVoiceReviewSheet = true
            voiceStatusMessage = "已识别 1 条账单，请确认后保存。"
        } catch {
            voiceStatusMessage = "图片识别失败：\(error.localizedDescription)"
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteRecord != nil },
            set: { visible in
                if !visible { pendingDeleteRecord = nil }
            }
        )
    }

    private var manualSaveErrorBinding: Binding<Bool> {
        Binding(
            get: { manualSaveErrorMessage != nil },
            set: { visible in
                if !visible { manualSaveErrorMessage = nil }
            }
        )
    }

    private func amountBinding(for index: Int) -> Binding<String> {
        Binding(
            get: { voiceForms[index].amountText },
            set: { newValue in
                let formatted = AmountInputFormatter.formatForEditing(newValue)
                voiceForms[index].amountText = formatted
                voiceForms[index].amountCNY = AmountInputFormatter.parse(formatted) ?? 0
            }
        )
    }

    private func beginEditing(_ record: TransactionRecord) {
        editingRecord = record
        manualForm = EditableForm(
            sourceType: record.sourceType,
            rawText: record.rawText,
            amountCNY: record.amountCNY,
            amountText: AmountInputFormatter.display(record.amountCNY),
            occurredAt: record.occurredAt,
            merchant: record.merchant,
            channel: record.channel,
            categoryID: record.categoryID,
            categoryName: categoryName(for: record),
            confidence: record.confidence,
            note: record.note,
            engine: .local
        )
        showManualEntrySheet = true
    }

    private func deleteRecord(_ record: TransactionRecord) {
        modelContext.delete(record)
        do {
            try modelContext.save()
            voiceStatusMessage = "账单已删除。"
        } catch {
            voiceStatusMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func saveManualForm() {
        guard !isManualSaving else { return }
        isManualSaving = true
        defer { isManualSaving = false }

        let merchant = manualForm.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let amount = AmountInputFormatter.parse(manualForm.amountText) ?? 0
        guard !merchant.isEmpty else {
            manualSaveErrorMessage = "商户名称不能为空。"
            return
        }
        guard amount > 0 else {
            manualSaveErrorMessage = "请输入有效金额。"
            return
        }

        do {
            if let editingRecord {
                editingRecord.merchant = merchant
                editingRecord.amountCNY = amount
                editingRecord.occurredAt = manualForm.occurredAt
                editingRecord.channel = manualForm.channel
                editingRecord.categoryID = manualForm.categoryID
                editingRecord.note = manualForm.note
                editingRecord.updatedAt = .now
                editingRecord.status = .confirmed
                try modelContext.save()
                voiceStatusMessage = "账单已更新。"
            } else {
                _ = try intakeService.save(
                    form: RecognizedTransactionForm(
                        sourceType: .text,
                        rawText: manualForm.rawText.isEmpty ? merchant : manualForm.rawText,
                        amountCNY: amount,
                        occurredAt: manualForm.occurredAt,
                        merchant: merchant,
                        channel: manualForm.channel,
                        categoryID: manualForm.categoryID,
                        categoryName: manualForm.categoryName,
                        confidence: 1,
                        note: manualForm.note,
                        engine: .local,
                        engineDetail: "手动输入"
                    ),
                    in: modelContext,
                    forceConfirmed: true
                )
                voiceStatusMessage = "手动账单已保存。"
            }
            editingRecord = nil
            showManualEntrySheet = false
        } catch {
            manualSaveErrorMessage = error.localizedDescription
            voiceStatusMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func saveVoiceForms() {
        var successCount = 0
        for form in voiceForms {
            let merchant = form.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !merchant.isEmpty, form.amountCNY > 0 else { continue }

            do {
                _ = try intakeService.save(
                    form: form.toRecognizedForm,
                    in: modelContext,
                    forceConfirmed: true
                )
                successCount += 1
            } catch {
                continue
            }
        }

        voiceForms = []
        showVoiceReviewSheet = false
        speechService.transcript = ""
        voiceStatusMessage = successCount > 0 ? "已保存 \(successCount) 条语音账单。" : "没有可保存的有效账单。"
    }

    private func icon(for record: TransactionRecord) -> String {
        guard let categoryID = record.categoryID,
              let category = categories.first(where: { $0.id == categoryID }) else {
            return "questionmark.circle"
        }
        return category.symbol
    }

    private func categoryName(for record: TransactionRecord) -> String {
        guard let categoryID = record.categoryID,
              let category = categories.first(where: { $0.id == categoryID }) else {
            return "未分类"
        }
        return category.name
    }
}

private struct LedgerCardScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum AmountInputFormatter {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    static func formatForEditing(_ input: String) -> String {
        let cleaned = sanitize(input)
        guard !cleaned.isEmpty else { return "" }

        let hasDot = cleaned.contains(".")
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        let rawInteger = String(parts.first ?? "")
        let integerDigits = rawInteger.isEmpty ? "0" : trimLeadingZeros(rawInteger)
        let groupedInteger = grouped(integerDigits)

        guard hasDot else {
            return groupedInteger
        }

        let fractionRaw = parts.count > 1 ? String(parts[1]) : ""
        let fraction = String(fractionRaw.prefix(3))
        return "\(groupedInteger).\(fraction)"
    }

    static func parse(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "¥", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let candidate = normalized == "." ? "0" : normalized
        return Double(candidate)
    }

    static func display(_ value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static func sanitize(_ text: String) -> String {
        var result = ""
        var hasDot = false
        for scalar in text.unicodeScalars {
            if CharacterSet.decimalDigits.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if scalar == ".", !hasDot {
                hasDot = true
                result.append(".")
            }
        }
        return result
    }

    private static func trimLeadingZeros(_ raw: String) -> String {
        let trimmed = raw.drop(while: { $0 == "0" })
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func grouped(_ integer: String) -> String {
        let number = NSDecimalNumber(string: integer)
        guard number != .notANumber else { return integer }
        return formatter.string(from: number) ?? integer
    }
}
