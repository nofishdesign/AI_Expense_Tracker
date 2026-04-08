import SwiftData
import SwiftUI

struct StatisticsView: View {
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

    @Query(sort: \TransactionRecord.occurredAt, order: .reverse) private var allRecords: [TransactionRecord]
    @Query(sort: \Category.order) private var categories: [Category]

    @State private var selectedMonth: Date = .now
    @State private var timeFilterScope: TimeFilterScope = .month
    @State private var showMonthPicker = false
    @State private var monthPickerYear: Int = Calendar.current.component(.year, from: .now)
    @State private var monthPickerMonth: Int = Calendar.current.component(.month, from: .now)

    private var selectedMonthRange: Range<Date> {
        let calendar = Calendar.current
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedMonth)) ?? selectedMonth
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? .distantFuture
        return monthStart..<monthEnd
    }

    private var confirmedMonthRecords: [TransactionRecord] {
        allRecords.filter { $0.status == .confirmed && selectedMonthRange.contains($0.occurredAt) }
    }

    private var allConfirmedRecords: [TransactionRecord] {
        allRecords.filter { $0.status == .confirmed }
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

    private var activeRecords: [TransactionRecord] {
        switch timeFilterScope {
        case .month:
            return confirmedMonthRecords
        case .all:
            return allConfirmedRecords
        }
    }

    private var activeTotal: Double {
        activeRecords.reduce(0) { $0 + $1.amountCNY }
    }

    private var activeCount: Int {
        activeRecords.count
    }

    private var activeCategorySlices: [CategorySlice] {
        categorySlices(for: activeRecords)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
                                .font(.system(size: 17, weight: .semibold))
                            Text(timeFilterTitle)
                                .font(.system(size: 22, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.7))
                        )
                    }
                    .buttonStyle(.plain)

                    statisticsOverviewCard
                    statisticsCategorySection
                    if timeFilterScope == .month {
                        monthHeatmapSection
                    }
                }
                .padding(16)
            }
            .navigationTitle("统计")
        }
        .sheet(isPresented: $showMonthPicker) {
            monthPickerSheet
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

    private var statisticsOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(timeFilterScope == .all ? "全部时间总支出" : "\(monthTitle)总支出")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(formatCurrency(activeTotal))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
            Text("\(activeCount) 笔已入账")
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
                Text(formatCurrency(activeTotal))
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
                        let ratio = activeTotal > 0 ? (slice.total / activeTotal) : 0
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

    private var monthPickerSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    Picker("年份", selection: $monthPickerYear) {
                        ForEach(monthPickerYears, id: \.self) { year in
                            Text("\(year)年").tag(year)
                        }
                    }
#if os(iOS)
                    .pickerStyle(.wheel)
#else
                    .pickerStyle(.menu)
#endif

                    Picker("月份", selection: $monthPickerMonth) {
                        ForEach(1...12, id: \.self) { month in
                            Text("\(month)月").tag(month)
                        }
                    }
#if os(iOS)
                    .pickerStyle(.wheel)
#else
                    .pickerStyle(.menu)
#endif
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
}
