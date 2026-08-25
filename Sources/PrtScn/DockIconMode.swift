/// When the app shows a Dock icon (and so appears in the ⌘Tab app switcher).
/// `.whileEditing` keeps it a pure menu-bar app until the editor window opens.
enum DockIconMode: String, CaseIterable, Identifiable {
    case whileEditing
    case always
    case never

    var id: String { rawValue }

    var label: String {
        switch self {
        case .whileEditing: "While Editing"
        case .always: "Always"
        case .never: "Never"
        }
    }
}
