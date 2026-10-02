import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Binding var settings: PadSettings
    let onResetLayout: () -> Void
    let onEditLayout: () -> Void
    let onClose: () -> Void
    let onBackgroundImageChanged: () -> Void

    @State private var photoItem: PhotosPickerItem?
    @State private var hasCustomImage = CustomBackgroundStorage.exists

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

                Section("Fond") {
                    Picker("Fond", selection: $settings.background) {
                        ForEach(PadBackground.allCases.filter { $0 != .custom }) { bg in
                            HStack {
                                Circle().fill(bg.color).frame(width: 16, height: 16)
                                Text(bg.title)
                            }
                            .tag(bg)
                        }
                    }
                    .pickerStyle(.inline)

                    PhotosPicker(selection: $photoItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo")
                            Text(hasCustomImage ? "Changer la photo" : "Choisir une photo")
                        }
                    }
                    .onChange(of: photoItem) { newItem in
                        guard let newItem else { return }
                        Task {
                            guard let data = try? await newItem.loadTransferable(type: Data.self),
                                  let image = UIImage(data: data) else { return }
                            CustomBackgroundStorage.save(image)
                            hasCustomImage = true
                            settings.background = .custom
                            onBackgroundImageChanged()
                        }
                    }

                    if hasCustomImage {
                        Button("Supprimer la photo de fond", role: .destructive) {
                            CustomBackgroundStorage.clear()
                            hasCustomImage = false
                            if settings.background == .custom { settings.background = .black }
                            onBackgroundImageChanged()
                        }
                    }
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
    SettingsView(settings: .constant(.standard), onResetLayout: {}, onEditLayout: {}, onClose: {}, onBackgroundImageChanged: {})
}
