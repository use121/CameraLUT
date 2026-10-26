import SwiftUI
import AVFoundation

/// 手动控制面板：ISO / 快门 / 白平衡 / 对焦
struct ManualPanel: View {
    @ObservedObject var model: CameraModel

    enum Target: String, CaseIterable, Identifiable {
        case iso, shutter, whiteBalance, focus

        var id: String { rawValue }

        var label: String {
            switch self {
            case .iso: return "ISO"
            case .shutter: return "快门"
            case .whiteBalance: return "白平衡"
            case .focus: return "对焦"
            }
        }
    }

    @State private var target: Target = .iso

    var body: some View {
        VStack(spacing: 12) {
            tabs
            sliderRow
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    // MARK: - 分档

    private var tabs: some View {
        HStack(spacing: 6) {
            ForEach(Target.allCases) { item in
                let active = target == item
                let manual = isManual(item)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        target = item
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(item.label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                        Circle()
                            .fill(manual ? Color.black.opacity(0.55) : Color.primary.opacity(0.28))
                            .frame(width: 5, height: 5)
                    }
                    .foregroundStyle(active ? Color.black : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background {
                        Capsule().fill(
                            active
                                ? Color.yellow.opacity(0.85)
                                : Color.primary.opacity(0.09)
                        )
                    }
                }
                .buttonStyle(.pressable)
            }
        }
    }

    // MARK: - 滑条

    private var sliderRow: some View {
        HStack(spacing: 10) {
            Slider(value: binding, in: range)
                .tint(.yellow)

            Text(valueLabel)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .trailing)
                .monospacedDigit()

            Button {
                resetToAuto()
            } label: {
                Text("A")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(isManual(target) ? Color.secondary : Color.black)
                    .frame(width: 32, height: 26)
                    .background {
                        Capsule().fill(
                            isManual(target)
                                ? Color.primary.opacity(0.09)
                                : Color.yellow.opacity(0.85)
                        )
                    }
            }
            .buttonStyle(.pressable)
        }
    }

    // MARK: - 绑定与范围

    private var binding: Binding<Double> {
        switch target {
        case .iso:
            return Binding(
                get: { Double(model.iso) },
                set: { model.setISO(Float($0)) }
            )

        case .shutter:
            return Binding(
                get: { log2(max(model.shutterSeconds, 0.0001)) },
                set: { model.setShutter(pow(2, $0)) }
            )

        case .whiteBalance:
            return Binding(
                get: { Double(model.whiteBalanceTemperature) },
                set: { model.setWhiteBalance(Float($0)) }
            )

        case .focus:
            return Binding(
                get: { Double(model.lensPosition) },
                set: { model.setManualFocus(Float($0)) }
            )
        }
    }

    private var range: ClosedRange<Double> {
        switch target {
        case .iso:
            return Double(model.isoRange.lowerBound)...Double(model.isoRange.upperBound)
        case .shutter:
            let low = log2(max(model.shutterRange.lowerBound, 0.0001))
            let high = log2(max(model.shutterRange.upperBound, 0.0002))
            return low...high
        case .whiteBalance:
            return Double(model.whiteBalanceRange.lowerBound)...Double(model.whiteBalanceRange.upperBound)
        case .focus:
            return 0...1
        }
    }

    private var valueLabel: String {
        switch target {
        case .iso: return model.isoLabel
        case .shutter: return model.shutterLabel
        case .whiteBalance: return model.whiteBalanceLabel
        case .focus:
            return String(format: "%.2f", Double(model.lensPosition))
        }
    }

    // MARK: - 状态

    private func isManual(_ item: Target) -> Bool {
        switch item {
        case .iso, .shutter: return model.manualExposure
        case .whiteBalance: return model.manualWhiteBalance
        case .focus: return model.manualFocus
        }
    }

    private func resetToAuto() {
        switch target {
        case .iso, .shutter: model.resetExposureAuto()
        case .whiteBalance: model.resetWhiteBalanceAuto()
        case .focus: model.resetFocusAuto()
        }
    }
}
