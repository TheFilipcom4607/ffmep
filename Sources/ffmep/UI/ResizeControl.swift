import SwiftUI

struct ResizeControl: View {
    let kind: MediaKind
    @Binding var settings: ConversionSettings

    var body: some View {
        Section("Size") {
            Picker("Resize", selection: $settings.resize) {
                ForEach(ResizeOption.choices(for: kind)) { Text($0.title).tag($0) }
            }

            switch settings.resize {
            case .custom:
                LabeledContent("Fit Within") {
                    HStack(spacing: 4) {
                        TextField("Width", value: $settings.customWidth, format: .number.grouping(.never))
                            .frame(width: 58)
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", value: $settings.customHeight, format: .number.grouping(.never))
                            .frame(width: 58)
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                }
            case .percent:
                LabeledContent("Scale") {
                    HStack(spacing: 8) {
                        Slider(value: percentBinding, in: 5...100)
                            .frame(width: 120)
                        Text("\(settings.percent)%")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            default:
                EmptyView()
            }

            if settings.resize != .original {
                Toggle("Don’t Enlarge Smaller Files", isOn: $settings.noUpscale)
            }
        }
    }

    private var percentBinding: Binding<Double> {
        Binding(get: { Double(settings.percent) }, set: { settings.percent = Int($0.rounded()) })
    }
}
