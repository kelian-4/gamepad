import SwiftUI
import PhotosUI

struct SettingsView: View {
    @Binding var settings: PadSettings
    let currentLayout: PadLayout
    let onResetLayout: () -> Void
    let onEditLayout: () -> Void
    let onClose: () -> Void
    let onBackgroundImageChanged: () -> Void
    let onImportLayout: (PadLayout) -> Void

    @AppStorage("gamepad.stream.quality") private var streamQuality = "auto"
    @AppStorage("gamepad.stream.brightness") private var streamBrightness = 0.8
    @AppStorage("gamepad.buttons.opacity") private var buttonOpacity = 1.0
    @AppStorage("gamepad.background.beforeScreen") private var backgroundBeforeScreen = PadBackground.black.rawValue
    @State private var photoItem: PhotosPickerItem?
    @State private var hasCustomImage = CustomBackgroundStorage.exists
    @State private var pendingBackground: PadBackground?
    @State private var pendingImage: UIImage?
    @State private var confirmDeleteImage = false
    @State private var confirmResetLayout = false
    @State private var showExportSheet = false
    @State private var showImportPicker = false
    @State private var exportURL: URL?
    @State private var importError: String?

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

                Section("Visibilité des boutons") {
                    HStack {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                        Slider(value: $buttonOpacity, in: 0.15...1.0, step: 0.05)
                        Image(systemName: "eye")
                    }
                    Text("\(Int(buttonOpacity * 100)) %")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Retour haptique") {
                    Toggle("Vibrations", isOn: $settings.hapticsEnabled)
                }

                Section("Fond") {
                    Picker("Fond", selection: Binding(
                        get: { settings.background },
                        set: { newValue in
                            guard newValue != settings.background else { return }
                            pendingBackground = newValue
                        }
                    )) {
                        ForEach(PadBackground.allCases.filter { $0 != .custom && $0 != .screen }) { bg in
                            HStack {
                                Circle().fill(bg.color).frame(width: 16, height: 16)
                                Text(bg.title)
                            }
                            .tag(bg)
                        }
                    }
                    .pickerStyle(.inline)

                    Toggle("Écran du PC", isOn: Binding(
                        get: { settings.background == .screen },
                        set: { enabled in
                            if enabled {
                                if settings.background != .screen { pendingBackground = .screen }
                            } else {
                                let previous = PadBackground(rawValue: backgroundBeforeScreen) ?? .black
                                settings.background = previous == .screen ? .black : previous
                            }
                        }
                    ))

                    if settings.background == .screen {
                        Picker("Qualité du flux", selection: $streamQuality) {
                            Text("Auto").tag("auto")
                            Text("Haute").tag("high")
                            Text("Moyenne").tag("medium")
                            Text("Basse").tag("low")
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            Image(systemName: "sun.min")
                                .font(.caption)
                            Slider(value: $streamBrightness, in: 0.2...1.0, step: 0.05)
                            Image(systemName: "sun.max")
                        }
                        Text("Luminosité du fond : \(Int(streamBrightness * 100)) %")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Text("Affiche l'écran du PC derrière les boutons. Lance le serveur avec --stream, puis scanne son QR code.")
                        .font(.caption)
                        .foregroundColor(.secondary)

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
                            pendingImage = image
                        }
                    }

                    if hasCustomImage {
                        Button("Supprimer la photo de fond", role: .destructive) {
                            confirmDeleteImage = true
                        }
                    }
                }

                Section("Disposition") {
                    NavigationLink("Profils par jeu") {
                        ProfilesView(currentLayout: currentLayout, onApply: onImportLayout)
                    }
                    Button("Modifier la disposition") { onEditLayout() }
                    Button("Exporter la disposition") { exportLayout() }
                    Button("Importer une disposition") { showImportPicker = true }
                    Button("Réinitialiser la disposition", role: .destructive) {
                        confirmResetLayout = true
                    }
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
        .alert(
            "Changer le fond ?",
            isPresented: Binding(
                get: { pendingBackground != nil },
                set: { if !$0 { pendingBackground = nil } }
            ),
            presenting: pendingBackground
        ) { newBackground in
            Button("Appliquer") {
                if newBackground == .screen {
                    backgroundBeforeScreen = settings.background.rawValue
                }
                settings.background = newBackground
                pendingBackground = nil
            }
            Button("Annuler", role: .cancel) {
                pendingBackground = nil
            }
        } message: { newBackground in
            Text("Remplacer le fond actuel par « \(newBackground.title) » ?")
        }
        .alert(
            "Utiliser cette photo comme fond ?",
            isPresented: Binding(
                get: { pendingImage != nil },
                set: { if !$0 { pendingImage = nil; photoItem = nil } }
            )
        ) {
            Button("Appliquer") {
                if let image = pendingImage {
                    CustomBackgroundStorage.save(image)
                    hasCustomImage = true
                    settings.background = .custom
                    onBackgroundImageChanged()
                }
                pendingImage = nil
                photoItem = nil
            }
            Button("Annuler", role: .cancel) {
                pendingImage = nil
                photoItem = nil
            }
        } message: {
            Text("Cette photo remplacera le fond actuel.")
        }
        .alert(
            "Supprimer la photo de fond ?",
            isPresented: $confirmDeleteImage
        ) {
            Button("Supprimer", role: .destructive) {
                CustomBackgroundStorage.clear()
                hasCustomImage = false
                if settings.background == .custom { settings.background = .black }
                onBackgroundImageChanged()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est définitive, la photo actuelle sera supprimée.")
        }
        .alert(
            "Réinitialiser la disposition ?",
            isPresented: $confirmResetLayout
        ) {
            Button("Réinitialiser", role: .destructive) {
                onResetLayout()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Toutes les positions et tailles personnalisées seront perdues et remplacées par la disposition du preset actuel.")
        }
        .alert(
            "Import impossible",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showExportSheet) {
            if let exportURL {
                ShareSheet(items: [exportURL])
            }
        }
        .sheet(isPresented: $showImportPicker) {
            LayoutDocumentPicker { url in
                importLayout(from: url)
            }
        }
    }

    private func exportLayout() {
        guard let data = try? JSONEncoder().encode(currentLayout) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("disposition-gamepad.json")
        do {
            try data.write(to: url, options: .atomic)
            exportURL = url
            showExportSheet = true
        } catch {
            importError = "Impossible d'exporter la disposition."
        }
    }

    private func importLayout(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importError = "Impossible de lire le fichier sélectionné."
            return
        }
        guard let imported = try? JSONDecoder().decode(PadLayout.self, from: data), imported.isPlausible else {
            importError = "Ce fichier ne contient pas une disposition valide."
            return
        }
        onImportLayout(imported)
    }
}

#Preview {
    SettingsView(
        settings: .constant(.standard),
        currentLayout: .standard,
        onResetLayout: {},
        onEditLayout: {},
        onClose: {},
        onBackgroundImageChanged: {},
        onImportLayout: { _ in }
    )
}
