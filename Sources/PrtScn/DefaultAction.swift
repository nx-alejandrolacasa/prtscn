/// What happens to a capture when the preview auto-dismisses on timeout
/// without the user choosing an action. (Esc is different: it always
/// discards — see PreviewCard's escape handler.)
enum DefaultAction: String, CaseIterable, Identifiable {
    case save
    case copy
    case edit
    case discard

    var id: Self { self }

    var label: String {
        switch self {
        case .save: String(localized: "Export to disk")
        case .copy: String(localized: "Copy to clipboard")
        case .edit: String(localized: "Open in Editor")
        case .discard: String(localized: "Discard")
        }
    }
}
