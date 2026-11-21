import SwiftUI
import Charts

struct PerformanceSample: Identifiable {
    let id = Date()
    let cpu: Double
    let heapBytes: Int64
    let maxHeapBytes: Int64
    var heapGB: Double { Double(heapBytes) / 1_073_741_824 }
    var maxHeapGB: Double { Double(maxHeapBytes) / 1_073_741_824 }

    init?(_ line: String) {
        guard line.hasPrefix("LANTERN_METRICS ") else { return nil }
        let fields = line.split(separator: " ")
        guard fields.count == 4, let cpu = Double(fields[1]), cpu.isFinite, cpu >= 0,
              let used = Int64(fields[2]), let max = Int64(fields[3]),
              used >= 0, max > 0, used <= max else { return nil }
        self.cpu = cpu
        heapBytes = used
        maxHeapBytes = max
    }
}

struct PerformanceReadout: View {
    @ObservedObject var model: ServerModel

    var body: some View {
        if model.state == .running {
            if let sample = model.samples.last {
                HStack(spacing: 28) {
                    metric("CPU", sample.cpu.formatted(.number.precision(.fractionLength(1))) + "%")
                    metric("Heap in use", "\(sample.heapBytes / 1_048_576) MB")
                    metric("Players online", String(model.players.count))
                }
                history("CPU use (%)", value: { $0.cpu })
                history("Java heap used (MB)", value: { Double($0.heapBytes) / 1_048_576 })
                Text("Samples about every 2 seconds. 100% CPU represents one core. Heap usage and limit are reported by the running server JVM.").font(.caption)
                LabeledContent("Java heap limit", value: "\(sample.maxHeapGB.formatted(.number.precision(.fractionLength(0...2)))) GB")
                LabeledContent("Last sample", value: sample.id.formatted(date: .omitted, time: .standard))
                if model.supportsTickQuery {
                    Toggle("Sample tick timing every 30 seconds", isOn: Binding(get: { model.option("tickMonitor") == "true" }, set: { model.settings.put("tickMonitor", String($0)) }))
                    if !model.tickInfo.isEmpty { Text(model.tickInfo).font(.callout) }
                }
            } else { Text("Waiting for a server performance sample…").foregroundStyle(.secondary) }
        } else { Text("Live readings appear when this server is running.").foregroundStyle(.secondary) }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private func history(_ title: String, value: @escaping (PerformanceSample) -> Double) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.subheadline)
            Chart(model.samples) { sample in
                LineMark(x: .value("Time", sample.id), y: .value(title, value(sample)))
                    .symbol(.circle).symbolSize(8)
            }.foregroundStyle(.green).frame(height: 96)
        }
    }
}
