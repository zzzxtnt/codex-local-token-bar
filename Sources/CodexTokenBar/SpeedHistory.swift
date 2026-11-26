import Foundation
import SwiftUI
import Charts

struct SpeedSample: Equatable {
    let date: Date
    let rate: Double?
}

/// In-memory only. A failed read is a gap, never a zero-speed sample.
struct SpeedHistory {
    static let duration: TimeInterval = 600
    private(set) var samples: [SpeedSample] = []

    /// Snap to a real sample, including failed samples; never invent a value in a gap.
    func sample(near date: Date, now: Date) -> SpeedSample? {
        let visible = samples.filter { $0.date > now.addingTimeInterval(-Self.duration) && $0.date <= now }
        guard let nearest = visible.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }),
              abs(nearest.date.timeIntervalSince(date)) <= 20 else { return nil }
        return nearest
    }

    mutating func record(_ rate: Double?, at date: Date) {
        samples.removeAll { $0.date < date.addingTimeInterval(-Self.duration) || $0.date > date }
        let valid = rate.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        samples.append(SpeedSample(date: date, rate: valid))
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }

    func segments(now: Date) -> [[SpeedSample]] {
        var result: [[SpeedSample]] = []
        var current: [SpeedSample] = []
        for sample in samples where sample.date > now.addingTimeInterval(-Self.duration) && sample.date <= now {
            if sample.rate == nil || current.last.map({ sample.date.timeIntervalSince($0.date) > 75 }) == true {
                if !current.isEmpty { result.append(current); current = [] }
            }
            if sample.rate != nil { current.append(sample) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

struct SpeedTrendView: View {
    let history: SpeedHistory
    let currentValue: String
    var subtitle: String = "近 1 分钟均值"
    var accessibilitySummary: String = "每个点为近 1 分钟平均输出"
    var helpText: String = "仅记录本次运行的本地采样。每 30 秒自动采样，手动刷新也会采样；断线表示读取失败或采样中断，退出即清空。"
    @State private var hoveredDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            trend(now: context.date, selectionDate: hoveredDate)
        }
    }

    func trend(now: Date, selectionDate: Date? = nil) -> some View {
        let segments = history.segments(now: now)
        let maximum = max(1, segments.flatMap { $0 }.compactMap(\.rate).max() ?? 0)
        let selection = selectionDate.flatMap { history.sample(near: $0, now: now) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("输出速度").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 4)
                Text(currentValue == "— tok/s" ? "暂不可用" : currentValue)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            HStack(spacing: 4) {
                if let selection {
                    Text(selection.date, format: .dateTime.hour().minute().second())
                    Spacer(minLength: 2)
                    Text(selection.rate.map { String(format: "%.1f tok/s", $0) } ?? "该次采样不可用")
                } else {
                    Text(subtitle)
                    Spacer(minLength: 2)
                    Text(selectionDate == nil ? "移入查看数值" : "此处无采样")
                }
            }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(height: 14)
            Chart {
                ForEach(Array(segments.enumerated()), id: \.offset) { segmentIndex, segment in
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, sample in
                        LineMark(x: .value("时间", sample.date), y: .value("tok/s", sample.rate ?? 0),
                                 series: .value("连续采样", segmentIndex))
                            .foregroundStyle(Color.accentColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("时间", sample.date), y: .value("tok/s", sample.rate ?? 0))
                            .foregroundStyle(Color.accentColor.opacity(0.7)).symbolSize(8)
                    }
                }
                if let selection {
                    RuleMark(x: .value("选择时间", selection.date))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    if let rate = selection.rate {
                        PointMark(x: .value("时间", selection.date), y: .value("tok/s", rate))
                            .foregroundStyle(Color.accentColor).symbolSize(40)
                    }
                }
            }
            .chartXScale(domain: now.addingTimeInterval(-SpeedHistory.duration)...now)
            .chartYScale(domain: 0...(maximum * 1.12))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, maximum / 2, maximum]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel(anchor: .trailing) {
                        if let rate = value.as(Double.self) {
                            Text(rate.formatted(.number.notation(.compactName).precision(.fractionLength(0))))
                                .font(.system(size: 9, design: .monospaced))
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let frame = geometry[proxy.plotAreaFrame]
                                hoveredDate = frame.contains(location)
                                    ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil
                            case .ended: hoveredDate = nil
                            }
                        }
                }
            }
            .overlay {
                if segments.isEmpty { Text("等待有效采样").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(height: 64)
            HStack {
                Text("10 分钟前")
                Spacer()
                Text("现在")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("输出速度折线表，最近 10 分钟，\(accessibilitySummary)，当前 \(currentValue)")
        .help(helpText)
    }
}
