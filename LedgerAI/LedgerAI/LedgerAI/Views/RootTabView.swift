import SwiftData
import PhotosUI
import SwiftUI

struct RootTabView: View {
    private let buildBadge = "UI-R71"
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

    private enum TimeFilterScope {
        case month
        case all
    }

    private struct CategorySlice: Identifiable {
        let id: String
        let name: String
        let symbol: String
        let total: Double
    }

    private enum VoiceOverlayState {
        case hidden
        case recognizing
        case recognized
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
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \TransactionRecord.occurredAt, order: .reverse) private var allRecords: [TransactionRecord]
    @Query(sort: \Category.order) private var categories: [Category]
    @Query(sort: \AppSettings.updatedAt, order: .reverse) private var settingsList: [AppSettings]

    @StateObject private var speechService = SpeechRecognizerService()
    @State private var selectedMonth: Date = .now
    @State private var topMode: TopMode = .ledger
    @State private var timeFilterScope: TimeFilterScope = .month
    @State private var showMonthPicker = false
    @State private var monthPickerYear: Int = Calendar.current.component(.year, from: .now)
    @State private var monthPickerMonth: Int = Calendar.current.component(.month, from: .now)
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
    @State private var voiceOverlayState: VoiceOverlayState = .hidden
    @State private var pendingVoiceForm: EditableForm?
    @State private var pendingVoiceForms: [EditableForm] = []
    @State private var isSavingRecognized = false
    @State private var voiceReviewErrorMessage: String?
    @State private var permissionChecked = false
    @State private var initialSyncTriggered = false
    @State private var autoSyncTask: Task<Void, Never>?
    @State private var isBackgroundSyncRunning = false

    private let intakeService = LedgerIntakeService()
    private let syncService = SupabaseSyncService()

    private var isManualEntryEnabled: Bool {
        settingsList.first?.manualEntryEnabled ?? false
    }

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
                        if !shouldShowVoiceOverlay {
                            pageBackground
                                .frame(height: bottomAreaHeight)
                        }
                    }

                    if shouldShowVoiceOverlay {
                        voiceOverlay(bottomSafeInset: safeBottom)
                            .allowsHitTesting(voiceOverlayState == .recognized)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.2), value: shouldShowVoiceOverlay)
                    }

                    bottomDock
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 0)
                        .frame(height: bottomAreaHeight, alignment: .center)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .preferredColorScheme(.light)
            .task {
                try? SeedDataService.seedIfNeeded(context: modelContext)
                if !initialSyncTriggered {
                    initialSyncTriggered = true
                    triggerBackgroundSync("launch")
                }
                if scenePhase == .active {
                    startAutoSyncTicker()
                }
                guard !permissionChecked else { return }
                permissionChecked = true
                _ = await speechService.requestPermission()
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active:
                    triggerBackgroundSync("foreground")
                    startAutoSyncTicker()
                default:
                    stopAutoSyncTicker()
                }
            }
            .onDisappear {
                stopAutoSyncTicker()
            }
            .sheet(isPresented: $showSettingsSheet) {
                SettingsView()
                    .presentationDetents([.large])
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
        switch timeFilterScope {
        case .all:
            return allRecords
        case .month:
            return allRecords.filter { selectedMonthRange.contains($0.occurredAt) }
        }
    }

    private var confirmedMonthRecords: [TransactionRecord] {
        monthRecords.filter { $0.status == .confirmed }
    }

    private var allConfirmedRecords: [TransactionRecord] {
        allRecords.filter { $0.status == .confirmed }
    }

    private var selectedMonthRange: Range<Date> {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth)) ?? selectedMonth
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? .distantFuture
        return monthStart..<monthEnd
    }

    private var monthTitle: String {
        let comps = Calendar.current.dateComponents([.year, .month], from: selectedMonth)
        let year = comps.year ?? Calendar.current.component(.year, from: .now)
        let month = comps.month ?? Calendar.current.component(.month, from: .now)
        return "\(year)年\(month)月"
    }

    private var timeFilterTitle: String {
        switch timeFilterScope {
        case .all:
            return "全部"
        case .month:
            return monthTitle
        }
    }

    private var activeStatsRecords: [TransactionRecord] { confirmedMonthRecords }

    private var activeStatsTotal: Double {
        activeStatsRecords.reduce(0) { $0 + $1.amountCNY }
    }

    private var activeStatsCount: Int {
        activeStatsRecords.count
    }

    private var activeCategorySlices: [CategorySlice] {
        categorySlices(for: activeStatsRecords)
    }

    private var monthDayCountMap: [Int: Int] {
        var result: [Int: Int] = [:]
        for record in allConfirmedRecords where selectedMonthRange.contains(record.occurredAt) {
            let day = Calendar.current.component(.day, from: record.occurredAt)
            result[day, default: 0] += 1
        }
        return result
    }

    private var monthPickerYears: [Int] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: .now)
        let selectedYear = calendar.component(.year, from: selectedMonth)
        let dataYears = allRecords.map { calendar.component(.year, from: $0.occurredAt) }
        let minYear = min(dataYears.min() ?? currentYear, currentYear - 2, selectedYear)
        let maxYear = max(dataYears.max() ?? currentYear, currentYear + 2, selectedYear)
        return Array(minYear...maxYear)
    }

    private var quickMonthOptions: [Date] {
        let calendar = Calendar.current
        let currentMonthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) ?? .now
        var options = (0..<6).compactMap { offset in
            calendar.date(byAdding: .month, value: -offset, to: currentMonthStart)
        }
        let selectedStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth)) ?? selectedMonth
        if !options.contains(where: { sameMonth($0, selectedStart) }) {
            options.append(selectedStart)
        }
        return options.sorted(by: >)
    }

    private var topHeader: some View {
        HStack {
            Menu {
                Button {
                    timeFilterScope = .all
                } label: {
                    if timeFilterScope == .all {
                        Label("全部", systemImage: "checkmark")
                    } else {
                        Text("全部")
                    }
                }

                Divider()

                ForEach(quickMonthOptions, id: \.self) { monthDate in
                    Button {
                        selectedMonth = monthDate
                        timeFilterScope = .month
                    } label: {
                        if timeFilterScope == .month, sameMonth(monthDate, selectedMonth) {
                            Label(monthTitle(for: monthDate), systemImage: "checkmark")
                        } else {
                            Text(monthTitle(for: monthDate))
                        }
                    }
                }

                Divider()

                Button("选择月份…") {
                    let comps = Calendar.current.dateComponents([.year, .month], from: selectedMonth)
                    monthPickerYear = comps.year ?? Calendar.current.component(.year, from: .now)
                    monthPickerMonth = comps.month ?? Calendar.current.component(.month, from: .now)
                    showMonthPicker = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "calendar")
                        .font(.system(size: 18, weight: .semibold))
                    Text(timeFilterTitle)
                        .font(.system(size: 26, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.7))
                )
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

    private func sameMonth(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }

    private func monthTitle(for date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        let year = comps.year ?? Calendar.current.component(.year, from: .now)
        let month = comps.month ?? Calendar.current.component(.month, from: .now)
        return "\(year)年\(month)月"
    }

    private var modePicker: some View {
        Picker("内容", selection: $topMode) {
            ForEach(TopMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .frame(height: 40)
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
                        Text(timeFilterScope == .all ? "还没有记录" : "这个月还没有记录")
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
                    VStack(alignment: .leading, spacing: 14) {
                        Text("资金总览")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.secondary)

                        statisticsOverviewCard
                        statisticsCategorySection
                        if timeFilterScope == .month {
                            monthHeatmapSection
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

    private var statisticsOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(timeFilterScope == .all ? "全部时间总支出" : "\(monthTitle)总支出")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formatCurrency(activeStatsTotal))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
            Text("\(activeStatsCount) 笔已入账")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 244 / 255, green: 248 / 255, blue: 244 / 255),
                            Color(red: 235 / 255, green: 244 / 255, blue: 236 / 255)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 0.5)
        }
    }

    private var statisticsCategorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(timeFilterScope == .all ? "全部时间分类占比" : "\(monthTitle)分类占比")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(formatCurrency(activeStatsTotal))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            if activeCategorySlices.isEmpty {
                Text("这个范围还没有可统计的账单")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 10) {
                    ForEach(activeCategorySlices.prefix(8)) { slice in
                        let ratio = activeStatsTotal > 0 ? (slice.total / activeStatsTotal) : 0
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(slice.name, systemImage: slice.symbol)
                                    .font(.system(size: 14, weight: .medium))
                                Spacer()
                                Text("\(Int((ratio * 100).rounded()))% · \(formatCurrency(slice.total))")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { proxy in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.black.opacity(0.06))
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color(red: 45 / 255, green: 160 / 255, blue: 75 / 255))
                                        .frame(width: max(8, proxy.size.width * ratio))
                                }
                            }
                            .frame(height: 8)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
        }
    }

    private var monthHeatmapSection: some View {
        let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
        let cells = monthHeatmapCells()

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(monthTitle)记账日历")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(monthDayCountMap.count) 天有记录")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(weekday)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let count = monthDayCountMap[day, default: 0]
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(heatmapColor(for: count))
                            .frame(height: 28)
                            .overlay {
                                Text("\(day)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(count > 0 ? .white : .secondary)
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.clear)
                            .frame(height: 28)
                    }
                }
            }

            HStack(spacing: 4) {
                Text("少")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(0...4, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(heatmapColor(for: level))
                        .frame(width: 14, height: 14)
                }
                Text("多")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
        }
    }

    private func categorySlices(for records: [TransactionRecord]) -> [CategorySlice] {
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var bucket: [String: (name: String, symbol: String, total: Double)] = [:]

        for record in records {
            if let categoryID = record.categoryID, let category = categoryMap[categoryID] {
                let key = categoryID.uuidString
                let current = bucket[key] ?? (category.name, category.symbol, 0)
                bucket[key] = (current.name, current.symbol, current.total + record.amountCNY)
            } else {
                let key = "other"
                let current = bucket[key] ?? ("其他", "tray", 0)
                bucket[key] = (current.name, current.symbol, current.total + record.amountCNY)
            }
        }

        return bucket
            .map { key, value in
                CategorySlice(id: key, name: value.name, symbol: value.symbol, total: value.total)
            }
            .sorted { $0.total > $1.total }
    }

    private func monthHeatmapCells() -> [Int?] {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth)) ?? selectedMonth
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }

        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let mondayBasedOffset = (firstWeekday + 5) % 7

        var cells = Array(repeating: Optional<Int>.none, count: mondayBasedOffset)
        cells.append(contentsOf: dayRange.map { Optional($0) })
        while cells.count % 7 != 0 {
            cells.append(nil)
        }
        return cells
    }

    private func heatmapColor(for count: Int) -> Color {
        switch count {
        case 0:
            return Color(red: 236 / 255, green: 240 / 255, blue: 236 / 255)
        case 1:
            return Color(red: 190 / 255, green: 225 / 255, blue: 194 / 255)
        case 2:
            return Color(red: 128 / 255, green: 194 / 255, blue: 140 / 255)
        case 3:
            return Color(red: 72 / 255, green: 163 / 255, blue: 90 / 255)
        default:
            return Color(red: 31 / 255, green: 122 / 255, blue: 60 / 255)
        }
    }

    private func formatCurrency(_ amount: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let formatted = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
        return "¥\(formatted)"
    }

    private var bottomDock: some View {
        VStack(spacing: 6) {
            let isRecognizing = voiceOverlayState == .recognizing
            if voiceOverlayState == .recognized {
                HStack(spacing: 8) {
                    Button {
                        editRecognizedVoice()
                    } label: {
                        Text("编辑")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.primary)
                            .frame(width: 120, height: 50)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(.tertiarySystemFill))
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { @MainActor in
                            await saveRecognizedVoice()
                        }
                    } label: {
                        Group {
                            if isSavingRecognized {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            } else {
                                Text("记一笔")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 50)
                            }
                        }
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isSavingRecognized)
                }
                .frame(height: 52)
            } else {
                HStack(spacing: 16) {
                    PhotosPicker(selection: $selectedBillImageItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.black)
                            .frame(width: 50, height: 50)
                    }
                    .buttonStyle(.plain)
                    .opacity(isRecognizing ? 0 : 1)
                    .allowsHitTesting(!isRecognizing)

                    if isManualEntryEnabled {
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
                        .opacity(isRecognizing ? 0 : 1)
                        .allowsHitTesting(!isRecognizing)
                    }

                    speakButton
                        .opacity(isRecognizing ? 0.01 : 1)
                }
                .frame(height: 52)
                .overlay {
                    if isRecognizing {
                        HStack(spacing: 8) {
                            Image(systemName: "microphone")
                                .font(.system(size: 16, weight: .semibold))
                            Text("松手完成识别")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.accentColor)
                        )
                    }
                }
            }
        }
    }

    private var shouldShowVoiceOverlay: Bool {
        voiceOverlayState != .hidden
    }

    private func voiceOverlay(bottomSafeInset: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)

                HStack {
                    if voiceOverlayState == .recognized {
                        Button {
                            dismissVoiceOverlay(resetTranscript: false)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Color.secondary)
                                .frame(width: 36, height: 36)
                                .background(Circle().fill(Color.white.opacity(0.45)))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear
                            .frame(width: 36, height: 36)
                    }

                    Spacer()

                    Text(voiceOverlayState == .recognized ? "识别完成" : "识别中...")
                        .font(.system(size: 34 / 2, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    Color.clear
                        .frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Image(systemName: "waveform.and.magnifyingglass")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.top, 24)

                Text(highlightedLiveTranscript)
                    .font(.system(size: 17, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .padding(.top, 26)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, minHeight: 64)

                Text(voiceStatusMessage)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 387, alignment: .top)
            .background(
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 34, bottomLeading: 58, bottomTrailing: 58, topTrailing: 34),
                    style: .continuous
                )
                    .fill(.ultraThinMaterial)
                    .overlay(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 34, bottomLeading: 58, bottomTrailing: 58, topTrailing: 34),
                            style: .continuous
                        )
                            .fill(Color.white.opacity(0.38))
                    )
            )
            .overlay(
                UnevenRoundedRectangle(
                    cornerRadii: .init(topLeading: 34, bottomLeading: 58, bottomTrailing: 58, topTrailing: 34),
                    style: .continuous
                )
                    .stroke(Color.white.opacity(0.58), lineWidth: 0.8)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .offset(y: bottomSafeInset)
        }
    }

    private var highlightedLiveTranscript: AttributedString {
        let transcript = speechService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return AttributedString("请继续说消费内容…") }

        let draft = TransactionParser().parse(text: transcript, occurredAt: .now)
        let displayTranscript = transcriptWithFormattedAmounts(transcript, parsedAmount: draft.amountCNY)

        let mutable = NSMutableAttributedString(string: displayTranscript)
        let wholeRange = NSRange(location: 0, length: (displayTranscript as NSString).length)
        mutable.addAttributes([
            .foregroundColor: attributedLabelColor
        ], range: wholeRange)

        if let amountRegex = try? NSRegularExpression(pattern: #"(?:¥\s*)?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d{1,2})?"#) {
            let matches = amountRegex.matches(in: displayTranscript, range: wholeRange)
            for match in matches {
                mutable.addAttribute(.foregroundColor, value: attributedAmountColor, range: match.range)
            }
        }

        if draft.merchant != "未识别商户",
           let merchantRegex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: draft.merchant), options: [.caseInsensitive]) {
            let matches = merchantRegex.matches(in: displayTranscript, range: wholeRange)
            for match in matches {
                mutable.addAttribute(.foregroundColor, value: attributedMerchantColor, range: match.range)
            }
        }

        if let attributed = try? AttributedString(mutable, including: \.uiKit) {
            return attributed
        }
        return AttributedString(displayTranscript)
    }

    private func transcriptWithFormattedAmounts(_ transcript: String, parsedAmount: Double) -> String {
        var result = transcript

        // 1) Normalize all Arabic-number amount tokens to ¥xx.xx.
        let numberPattern = #"(?:¥|￥|rmb|cny)?\s*(?:\d{1,3}(?:[,\s，]\d{3})+|\d+)(?:\.\d{1,2})?\s*(?:元|块|rmb|cny)?"#
        if let regex = try? NSRegularExpression(pattern: numberPattern, options: [.caseInsensitive]) {
            let nsResult = result as NSString
            let fullRange = NSRange(location: 0, length: nsResult.length)
            let matches = regex.matches(in: result, options: [], range: fullRange).reversed()
            var mutable = result
            for match in matches {
                let current = mutable as NSString
                let token = current.substring(with: match.range)
                guard let value = parseTranscriptAmountToken(token), value > 0 else { continue }
                let replacement = "¥\(AmountInputFormatter.display(value))"
                mutable = current.replacingCharacters(in: match.range, with: replacement)
            }
            result = mutable
        }

        guard parsedAmount > 0 else { return result }
        let formatted = "¥\(AmountInputFormatter.display(parsedAmount))"
        if result.contains(formatted) { return result }

        // 2) Replace colloquial Chinese amount phrase (e.g. 两块一) with ¥xx.xx.
        let chineseAmountPattern = #"[零〇一二两三四五六七八九十百千万亿点\d]+(?:元|块)(?:[零〇一二两三四五六七八九十\d]{1,2}(?:角|毛|分)?)?"#
        if let regex = try? NSRegularExpression(pattern: chineseAmountPattern, options: [.caseInsensitive]) {
            let nsResult = result as NSString
            let fullRange = NSRange(location: 0, length: nsResult.length)
            if let match = regex.firstMatch(in: result, options: [], range: fullRange) {
                return nsResult.replacingCharacters(in: match.range, with: formatted)
            }
        }

        // 3) If still not shown, append one normalized amount token for consistency.
        return result + " \(formatted)"
    }

    private func parseTranscriptAmountToken(_ token: String) -> Double? {
        let normalized = token.lowercased()
            .replacingOccurrences(of: "¥", with: "")
            .replacingOccurrences(of: "￥", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "块", with: "")
            .replacingOccurrences(of: "rmb", with: "")
            .replacingOccurrences(of: "cny", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "，", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return Double(normalized)
    }

    private var speakButton: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(Color.accentColor)

            HStack(spacing: 8) {
                Image(systemName: "mic")
                    .font(.system(size: 16, weight: .semibold))
                Text(speechService.isRecording ? "松手完成识别" : "按住说话")
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
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    Picker("年份", selection: $monthPickerYear) {
                        ForEach(monthPickerYears, id: \.self) { year in
                            Text("\(year)年").tag(year)
                        }
                    }
                    .pickerStyle(.wheel)

                    Picker("月份", selection: $monthPickerMonth) {
                        ForEach(1...12, id: \.self) { month in
                            Text("\(month)月").tag(month)
                        }
                    }
                    .pickerStyle(.wheel)
                }
                .frame(height: 180)

                Text("只按月份筛选，不选择具体日期。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding(16)
            .navigationTitle("切换月份")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showMonthPicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        var comps = DateComponents()
                        comps.year = monthPickerYear
                        comps.month = monthPickerMonth
                        comps.day = 1
                        if let date = Calendar.current.date(from: comps) {
                            selectedMonth = date
                            timeFilterScope = .month
                        }
                        showMonthPicker = false
                    }
                }
            }
        }
    }

    private var voiceReviewSheet: some View {
        NavigationStack {
            Form {
                if let voiceReviewErrorMessage {
                    Section {
                        Text(voiceReviewErrorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

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
                        voiceReviewErrorMessage = nil
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
                pendingVoiceForm = nil
                pendingVoiceForms = []
                voiceOverlayState = .recognizing
                voiceStatusMessage = "正在录音，请继续说完整消费信息。"
            } catch {
                voiceStatusMessage = "无法启动录音：\(error.localizedDescription)"
                voiceOverlayState = .hidden
            }
        } else {
            guard speechService.isRecording else { return }
            speechService.stopRecording()
            isHandlingVoice = true
            voiceOverlayState = .recognizing
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
            voiceOverlayState = .hidden
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
                // Multi-segment mode: keep only entries with parsed amount to avoid
                // accidental over-splitting like "买了一个游戏，手柄花了78".
                if recognized.amountCNY > 0 || segments.count == 1 {
                    forms.append(EditableForm(from: recognized))
                }
            } catch {
                continue
            }
        }

        if forms.count > 1, amountMentionCount(in: transcript) <= 1 {
            if let merged = await mergedSingleVoiceForm(from: transcript, fallback: forms) {
                forms = [merged]
            }
        }

        if forms.isEmpty {
            voiceStatusMessage = "语音已转写，但未识别到可入账内容。"
            voiceOverlayState = .hidden
            return
        }

        pendingVoiceForms = forms
        pendingVoiceForm = forms[0]
        voiceStatusMessage = "识别到 \(forms.count) 条记录，请确认后保存。"
        voiceOverlayState = .recognized
    }

    private func splitVoiceEntries(from transcript: String) -> [String] {
        let replaced = transcript
            .replacingOccurrences(of: "然后", with: "\n")
            .replacingOccurrences(of: "再", with: "\n")
            .replacingOccurrences(of: "另外", with: "\n")
            .replacingOccurrences(of: "接着", with: "\n")
            .replacingOccurrences(of: "随后", with: "\n")
            .replacingOccurrences(of: "并且", with: "\n")
            .replacingOccurrences(of: "。", with: "\n")
            .replacingOccurrences(of: "；", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")

        let parts = replaced
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }

        return parts.isEmpty ? [transcript] : parts
    }

    private func amountMentionCount(in text: String) -> Int {
        let pattern = #"(?:¥|￥|rmb|cny)?\s*(?:\d{1,3}(?:[,\s，]\d{3})+|\d+)(?:\.\d{1,2})?\s*(?:元|块|rmb|cny)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.count
    }

    private func mergedSingleVoiceForm(from transcript: String, fallback forms: [EditableForm]) async -> EditableForm? {
        do {
            let recognized = try await intakeService.recognize(
                input: RecognitionInput(source: .voice, text: transcript, image: nil, occurredAt: .now),
                in: modelContext
            )
            if recognized.amountCNY > 0 {
                return EditableForm(from: recognized)
            }
        } catch {
            // Keep fallback if merged recognition fails.
        }

        guard let best = forms.max(by: { lhs, rhs in
            voiceFormPriority(lhs) < voiceFormPriority(rhs)
        }) else {
            return nil
        }
        return best
    }

    private func voiceFormPriority(_ form: EditableForm) -> Int {
        var score = 0
        let merchant = form.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if merchant != "未识别商户" { score += 20 }
        score += min(merchant.count, 24)
        if form.amountCNY > 0 { score += 20 }
        score += Int(form.confidence * 100)
        return score
    }

    private func handlePickedImage(_ item: PhotosPickerItem) async {
        defer { selectedBillImageItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = PlatformImage(data: data) else {
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
            voiceReviewErrorMessage = nil
            showVoiceReviewSheet = true
            voiceStatusMessage = "已识别 1 条账单，请确认后保存。"
        } catch {
            voiceStatusMessage = "图片识别失败：\(error.localizedDescription)"
        }
    }

    private func dismissVoiceOverlay(resetTranscript: Bool = true) {
        voiceOverlayState = .hidden
        pendingVoiceForm = nil
        pendingVoiceForms = []
        if resetTranscript {
            speechService.transcript = ""
        }
    }

    private func hideVoiceOverlayOnly() {
        voiceOverlayState = .hidden
    }

    private func editRecognizedVoice() {
        if pendingVoiceForms.count > 1 {
            voiceForms = pendingVoiceForms
            hideVoiceOverlayOnly()
            showVoiceReviewSheet = true
            return
        }
        guard let form = pendingVoiceForm ?? pendingVoiceForms.first else { return }
        editingRecord = nil
        manualForm = form
        hideVoiceOverlayOnly()
        showManualEntrySheet = true
    }

    @MainActor
    private func saveRecognizedVoice() async {
        guard !isSavingRecognized else { return }
        var forms = pendingVoiceForms
        if forms.isEmpty, let single = pendingVoiceForm {
            forms = [single]
        }
        guard !forms.isEmpty else {
            voiceStatusMessage = "识别结果已失效，请重新语音识别。"
            return
        }

        voiceStatusMessage = "保存中..."
        isSavingRecognized = true
        await Task.yield()
        defer { isSavingRecognized = false }

        let liveText = speechService.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        var successCount = 0
        var savedDates: [Date] = []
        var failedForms: [EditableForm] = []
        var firstSaveError: String?

        for var form in forms {
            if form.amountCNY <= 0 {
                let sourceText = form.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? liveText : form.rawText
                if !sourceText.isEmpty {
                    let reparsed = TransactionParser().parse(text: sourceText, occurredAt: .now)
                    if reparsed.amountCNY > 0 {
                        form.amountCNY = reparsed.amountCNY
                        form.amountText = AmountInputFormatter.display(reparsed.amountCNY)
                    }
                    if form.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || form.merchant == "未识别商户" {
                        form.merchant = reparsed.merchant
                    }
                    if form.rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        form.rawText = sourceText
                    }
                }
            }

            if form.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                form.merchant = "未识别商户"
            }
            guard form.amountCNY > 0 else {
                failedForms.append(form)
                continue
            }

            do {
                let saved = try persistRecognizedForm(form.toRecognizedForm)
                successCount += 1
                savedDates.append(saved.occurredAt)
            } catch {
                failedForms.append(form)
                if firstSaveError == nil {
                    firstSaveError = detailedErrorMessage(error)
                }
            }
        }

        if successCount > 0 && failedForms.isEmpty {
            revealSavedRecords(savedDates)
            voiceStatusMessage = "已保存 \(successCount) 条语音账单。"
            dismissVoiceOverlay()
            triggerBackgroundSync("voice-save")
            return
        }

        if successCount > 0 {
            revealSavedRecords(savedDates)
            pendingVoiceForms = failedForms
            pendingVoiceForm = failedForms.first
            if failedForms.count > 1 {
                voiceForms = failedForms
                hideVoiceOverlayOnly()
                showVoiceReviewSheet = true
            }
            if let firstSaveError {
                voiceStatusMessage = "已保存 \(successCount) 条，剩余 \(failedForms.count) 条（\(firstSaveError)）。"
            } else {
                voiceStatusMessage = "已保存 \(successCount) 条，剩余 \(failedForms.count) 条请确认后保存。"
            }
            triggerBackgroundSync("voice-save-partial")
            return
        }

        pendingVoiceForms = failedForms.isEmpty ? forms : failedForms
        pendingVoiceForm = pendingVoiceForms.first
        if pendingVoiceForms.count > 1 {
            voiceForms = pendingVoiceForms
            hideVoiceOverlayOnly()
            showVoiceReviewSheet = true
            if let firstSaveError {
                voiceStatusMessage = "保存失败：\(firstSaveError)"
            } else {
                voiceStatusMessage = "保存失败，请在列表里核对后重试。"
            }
        } else {
            if let firstSaveError {
                voiceStatusMessage = "保存失败：\(firstSaveError)"
            } else {
                voiceStatusMessage = "保存失败，请编辑后重试。"
            }
            editRecognizedVoice()
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
            triggerBackgroundSync("delete")
        } catch {
            voiceStatusMessage = "删除失败：\(detailedErrorMessage(error))"
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
                revealSavedRecords([manualForm.occurredAt])
            } else {
                let saved = try persistRecognizedForm(
                    RecognizedTransactionForm(
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
                    )
                )
                voiceStatusMessage = "手动账单已保存。"
                revealSavedRecords([saved.occurredAt])
            }
            editingRecord = nil
            showManualEntrySheet = false
            triggerBackgroundSync("manual-save")
        } catch {
            let message = detailedErrorMessage(error)
            manualSaveErrorMessage = message
            voiceStatusMessage = "保存失败：\(message)"
        }
    }

    private func saveVoiceForms() {
        var successCount = 0
        var savedDates: [Date] = []
        var failedForms: [EditableForm] = []
        var firstSaveError: String?
        for var form in voiceForms {
            if form.amountCNY <= 0 {
                let sourceText = form.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sourceText.isEmpty {
                    let reparsed = TransactionParser().parse(text: sourceText, occurredAt: form.occurredAt)
                    if reparsed.amountCNY > 0 {
                        form.amountCNY = reparsed.amountCNY
                        form.amountText = AmountInputFormatter.display(reparsed.amountCNY)
                    }
                    if form.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || form.merchant == "未识别商户" {
                        form.merchant = reparsed.merchant
                    }
                }
            }

            if form.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                form.merchant = "未识别商户"
            }

            guard form.amountCNY > 0 else {
                failedForms.append(form)
                continue
            }

            do {
                let saved = try persistRecognizedForm(form.toRecognizedForm)
                successCount += 1
                savedDates.append(saved.occurredAt)
            } catch {
                failedForms.append(form)
                if firstSaveError == nil {
                    firstSaveError = detailedErrorMessage(error)
                }
            }
        }

        if failedForms.isEmpty {
            voiceForms = []
            showVoiceReviewSheet = false
            voiceReviewErrorMessage = nil
            speechService.transcript = ""
            revealSavedRecords(savedDates)
            voiceStatusMessage = successCount > 0 ? "已保存 \(successCount) 条语音账单。" : "没有可保存的有效账单。"
            if successCount > 0 {
                triggerBackgroundSync("review-save")
            }
            return
        }

        if successCount > 0 {
            revealSavedRecords(savedDates)
        }
        voiceForms = failedForms
        showVoiceReviewSheet = true
        if let firstSaveError {
            let message = "已保存 \(successCount) 条，\(failedForms.count) 条保存失败：\(firstSaveError)"
            voiceReviewErrorMessage = message
            voiceStatusMessage = message
        } else {
            let message = "已保存 \(successCount) 条，\(failedForms.count) 条需要补充金额后重试。"
            voiceReviewErrorMessage = message
            voiceStatusMessage = message
        }
    }

    private func detailedErrorMessage(_ error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let nsError = error as NSError
        if message.isEmpty {
            return "\(nsError.domain)#\(nsError.code)"
        }
        return "\(message) [\(nsError.domain)#\(nsError.code)]"
    }

    private func persistRecognizedForm(_ form: RecognizedTransactionForm) throws -> TransactionRecord {
        do {
            return try intakeService.save(
                form: form,
                in: modelContext,
                forceConfirmed: true
            )
        } catch {
            // Fallback path: if analytics candidate write fails for any reason,
            // keep the core transaction record writable.
            let fallback = TransactionRecord(
                amountCNY: form.amountCNY,
                occurredAt: form.occurredAt,
                merchant: form.merchant,
                channel: form.channel,
                categoryID: form.categoryID,
                note: form.note,
                sourceType: form.sourceType,
                rawText: form.rawText,
                confidence: form.confidence,
                status: .confirmed
            )
            modelContext.insert(fallback)
            do {
                try modelContext.save()
                return fallback
            } catch let fallbackError {
                modelContext.delete(fallback)
                let primary = detailedErrorMessage(error)
                let secondary = detailedErrorMessage(fallbackError)
                throw LedgerIntakeError.persistenceFailed("保存失败：\(primary)；本地兜底失败：\(secondary)")
            }
        }
    }

    private func revealSavedRecords(_ dates: [Date]) {
        guard let latest = dates.max() else { return }
        topMode = .ledger
        guard timeFilterScope == .month else { return }

        let calendar = Calendar.current
        let currentMonth = calendar.dateComponents([.year, .month], from: selectedMonth)
        let savedMonth = calendar.dateComponents([.year, .month], from: latest)
        if currentMonth.year != savedMonth.year || currentMonth.month != savedMonth.month {
            selectedMonth = latest
        }
    }

    private func triggerBackgroundSync(_ trigger: String) {
        Task { @MainActor in
            guard !isBackgroundSyncRunning else { return }
            isBackgroundSyncRunning = true
            defer { isBackgroundSyncRunning = false }
            do {
                _ = try await syncService.sync(in: modelContext, trigger: trigger)
            } catch SupabaseSyncError.syncDisabled {
                // Sync optional; ignore when user has not enabled it.
            } catch SupabaseSyncError.missingCredentials {
                // Settings not completed yet.
            } catch {
                // Keep local save UX stable. Manual sync entry in Settings shows explicit errors.
            }
        }
    }

    private func startAutoSyncTicker() {
        guard autoSyncTask == nil else { return }
        autoSyncTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    triggerBackgroundSync("auto")
                }
            }
        }
    }

    private func stopAutoSyncTicker() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    private var attributedLabelColor: PlatformColor {
#if canImport(UIKit)
        return .label
#elseif canImport(AppKit)
        return .labelColor
#else
        return .black
#endif
    }

    private var attributedAmountColor: PlatformColor {
#if canImport(UIKit)
        return .systemBlue
#elseif canImport(AppKit)
        return .systemBlue
#else
        return .black
#endif
    }

    private var attributedMerchantColor: PlatformColor {
#if canImport(UIKit)
        return .systemPink
#elseif canImport(AppKit)
        return .systemPink
#else
        return .black
#endif
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
    private static let displayFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private static let groupingFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
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
        let fraction = String(fractionRaw.prefix(2))
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
        displayFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
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
        return groupingFormatter.string(from: number) ?? integer
    }
}
