import SwiftUI

struct OverviewGauges: View {
    @ObservedObject var model: ServerModel

    var body: some View {
        let running = model.state == .running
        let sample = running ? model.samples.last : nil
        let cores = max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let heapLimit = sample?.maxHeapGB ?? Double((model.sessionSettings ?? model.settings).memoryGB)
        let limit = (model.sessionSettings ?? model.settings).maxPlayers
        let players = running ? model.players.count : nil

        HStack(spacing: 8) {
            CountingCPUDial(target: sample?.cpu, cores: cores)
            PerformanceDial(label: "Server heap", value: sample.map { $0.heapGB.formatted(.number.precision(.fractionLength(1))) + " GB" },
                            scale: "of \(heapLimit.formatted(.number.precision(.fractionLength(0...2)))) GB heap limit", fraction: sample.map { $0.heapGB / $0.maxHeapGB })
            PerformanceDial(label: "Players online", value: players.map { String($0) },
                            scale: "of \(limit) slots", fraction: players.map { Double($0) / Double(max(1, limit)) })
        }
        if sample == nil {
            Text(running ? "Waiting for a performance sample…" : "Start the server to see live readings.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct CountingCPUDial: View {
    let target: Double?
    let cores: Int
    @ViewState<Double> private var displayed = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let reading = target.map { reduceMotion ? $0 : displayed }
        let coreLoad = reading.map { $0 / 100 }
        PerformanceDial(label: "Server CPU", value: reading.map { format($0) },
                        scale: "\(cores) cores · 100% each", fraction: coreLoad.map { $0 / Double(cores) },
                        coreCount: cores, coresUsed: coreLoad)
            .accessibilityValue(target.map { format($0) } ?? "Awaiting live reading")
            .task(id: target) {
                guard let target else { displayed = 0; return }
                while !Task.isCancelled {
                    if reduceMotion { displayed = target; return }
                    displayed = Self.nextValue(from: displayed, to: target)
                    if displayed == target { return }
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
    }

    // Retarget from the visible number when a fresh sample arrives mid-count.
    static func nextValue(from current: Double, to target: Double) -> Double {
        let difference = target - current
        let step = max(1, (current * 0.05).rounded())
        if abs(difference) <= step { return target }
        return difference > 0 ? current + step : current - step
    }

    private func format(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...1))) + "%"
    }
}

struct PerformanceDial: View {
    let label: String
    let value: String?
    let scale: String
    let fraction: Double?
    var coreCount: Int? = nil
    var coresUsed: Double? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let progress = min(max(fraction ?? 0, 0), 1)
        let stroke = StrokeStyle(lineWidth: 7, lineCap: .round)
        VStack(spacing: 2) {
            ZStack {
                Circle().trim(from: 0, to: 0.75)
                    .stroke(.secondary.opacity(0.25), style: stroke)
                    .rotationEffect(.degrees(135))
                if fraction != nil {
                    Circle().trim(from: 0, to: 0.75 * progress)
                        .stroke(.tint, style: stroke)
                        .rotationEffect(.degrees(135))
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .offset(x: 47)
                        .rotationEffect(.degrees(135 + 270 * progress))
                }
                Text(value ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .frame(width: 94, height: 94)
            .overlay(alignment: .leading) {
                if let count = coreCount {
                    CoreLoadDots(count: count, load: coresUsed)
                        .offset(x: 104)
                }
            }
            .animation(reduceMotion || coreCount != nil ? nil : .easeInOut(duration: 0.75), value: progress)
            Text(label).font(.subheadline.weight(.semibold))
            Text(scale).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .help(coreCount == nil ? label : CoreLoadDots.explanation)
        .accessibilityValue(value.map { "\($0), \(scale)" } ?? "Awaiting live reading")
    }
}

private struct CoreLoadDots: View {
    let count: Int
    let load: Double?
    static let explanation = "Each dot represents one core’s worth of server CPU time. Gray is unused, green is partially used, and red is fully used. An outline means there is no reading yet."

    var body: some View {
        let columns = [GridItem(.fixed(6), spacing: 3), GridItem(.fixed(6))]
        LazyVGrid(columns: columns, spacing: count > 20 ? 1 : 4) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(color(for: index))
                    .overlay { Circle().strokeBorder(.secondary.opacity(load == nil ? 0.5 : 0), lineWidth: 1) }
                    .frame(width: 6, height: 6)
            }
        }
        .frame(width: 15)
        .accessibilityHidden(true)
    }

    private func color(for index: Int) -> Color {
        guard let load else { return .clear }
        let usage = load - Double(index)
        if usage >= 1 { return .red }
        if usage > 0 { return .green }
        return .gray.opacity(0.55)
    }
}
