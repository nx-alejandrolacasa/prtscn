/// What happens to a capture when the preview is dismissed without the user
/// choosing an action (auto-dismiss timeout or Esc).
enum DefaultAction: String, CaseIterable, Identifiable {
    case save
    case copy
    case edit
    case discard

    var id: Self { self }

    var label: String {
        switch self {
        case .save: "Save to disk"
        case .copy: "Copy to clipboard"
        case .edit: "Open in Preview"
        case .discard: "Discard"
        }
    }
}
