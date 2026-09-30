import SwiftUI

struct SettingsView: View {
    @Binding var settings: PadSettings
    let onResetLayout: () -> Void
    let onEditLayout: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Style") {
                    Picker("Preset", selection: $settings.preset) {
                        ForEach(PadPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Taille des boutons") {
                    HStack {
                        Image(systemName: "circle")
                            .font(.caption)
                        Slider(value: $settings.globalScale, in: 0.7...1.6, step: 0.05)
                        Image(systemName: "circle.fill")
                    }
                    Text("\(Int(settings.globalScale * 100)) %")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Retour haptique") {
                    Toggle("Vibrations", isOn: $settings.hapticsEnabled)
                }

                Section("Disposition") {
                    Button("Modifier la disposition") { onEditLayout() }
                    Button("Réinitialiser la disposition", role: .destructive) { onResetLayout() }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminé") { onClose() }
                }
            }
        }
        .onChange(of: settings) { newValue in newValue.save() }
    }
}

#Preview {
    SettingsView(settings: .constant(.standard), onResetLayout: {}, onEditLayout: {}, onClose: {})
}
