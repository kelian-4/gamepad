import SwiftUI

struct ProfilesView: View {
    let currentLayout: PadLayout
    let onApply: (PadLayout) -> Void

    @State private var profiles = PadProfileStore.load()
    @State private var newName = ""
    @State private var pendingApply: PendingApply?
    @State private var pendingDelete: PadProfile?

    private struct PendingApply: Identifiable {
        let id = UUID()
        let title: String
        let layout: PadLayout
    }

    private var cleanName: String {
        PadProfileStore.normalized(newName)
    }

    private var nameExists: Bool {
        profiles.contains { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame }
    }

    var body: some View {
        Form {
            Section("Modèles prêts à l'emploi") {
                ForEach(PadTemplate.all) { template in
                    Button {
                        pendingApply = PendingApply(title: template.title, layout: template.layout)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.title)
                                .foregroundColor(.primary)
                            Text(template.detail)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section("Mes profils") {
                if profiles.isEmpty {
                    Text("Aucun profil enregistré.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        Button {
                            pendingApply = PendingApply(title: profile.name, layout: profile.layout)
                        } label: {
                            Text(profile.name)
                                .foregroundColor(.primary)
                        }
                    }
                    .onDelete { offsets in
                        if let idx = offsets.first { pendingDelete = profiles[idx] }
                    }
                }
            }

            Section {
                TextField("Nom du profil (ex : Forza)", text: $newName)
                Button(nameExists ? "Remplacer ce profil" : "Enregistrer") {
                    profiles = PadProfileStore.upserting(name: cleanName, layout: currentLayout, into: profiles)
                    PadProfileStore.save(profiles)
                    newName = ""
                }
                .disabled(cleanName.isEmpty)
            } header: {
                Text("Enregistrer la disposition actuelle")
            } footer: {
                Text("Le profil garde les positions, les tailles et les éléments masqués. Fais-en un par jeu.")
            }
        }
        .navigationTitle("Profils")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Appliquer « \(pendingApply?.title ?? "") » ?",
            isPresented: Binding(
                get: { pendingApply != nil },
                set: { if !$0 { pendingApply = nil } }
            ),
            presenting: pendingApply
        ) { pending in
            Button("Appliquer", role: .destructive) {
                onApply(pending.layout)
                pendingApply = nil
            }
            Button("Annuler", role: .cancel) {
                pendingApply = nil
            }
        } message: { _ in
            Text("Ta disposition actuelle sera remplacée. Enregistre-la d'abord dans un profil si tu veux la garder.")
        }
        .alert(
            "Supprimer « \(pendingDelete?.name ?? "") » ?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { profile in
            Button("Supprimer", role: .destructive) {
                profiles.removeAll { $0.id == profile.id }
                PadProfileStore.save(profiles)
                pendingDelete = nil
            }
            Button("Annuler", role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text("Cette action est définitive.")
        }
    }
}
