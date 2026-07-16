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
        case .save: "Save to disk"
        case .copy: "Copy to clipboard"
        case .edit: "Open in Editor"
        case .discard: "Discard"
        }
    }
}
