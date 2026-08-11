import SwiftUI

enum ProfileEditorMode {
    case create
    case rename(profileID: UUID, currentName: String)

    var title: String {
        switch self {
        case .create: "New Profile"
        case .rename: "Rename Profile"
        }
    }

    var actionTitle: String {
        switch self {
        case .create: "Create Profile"
        case .rename: "Save Name"
        }
    }

    var initialName: String {
        switch self {
        case .create: ""
        case .rename(_, let currentName): currentName
        }
    }
}

struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SpriteStore

    let mode: ProfileEditorMode

    @State private var name: String
    @FocusState private var nameIsFocused: Bool

    init(mode: ProfileEditorMode) {
        self.mode = mode
        _name = State(initialValue: mode.initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(mode.title)
                    .font(.title2.weight(.black))
                Text("Profiles keep recording imports, levels, and mastery completely separate.")
                    .foregroundStyle(.secondary)
            }

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.title3.weight(.semibold))
                .focused($nameIsFocused)
                .onSubmit(save)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button(mode.actionTitle, action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 440, height: 220)
        .background(AnimatedBackground())
        .onAppear {
            nameIsFocused = true
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case .create:
            store.createProfile(named: trimmedName)
        case .rename(let profileID, _):
            store.renameProfile(profileID, to: trimmedName)
        }
        dismiss()
    }
}
