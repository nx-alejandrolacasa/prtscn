/// Pixel density of exported captures. On a HiDPI (Retina) display the raw
/// capture is at the display's backing scale; these choices control whether
/// exports keep that density or are resampled to standard (1-point-per-pixel)
/// resolution. On a standard display every choice behaves like `native`.
///
/// Save and Copy are configured independently (Settings → Capture): the
/// clipboard can only hold one image, so Copy has no `both`.
enum SaveResolution: String, CaseIterable, Identifiable {
    case native
    case downscaled
    case both

    var id: Self { self }

    var label: String {
        switch self {
        case .native: "Native"
        case .downscaled: "Downscaled"
        case .both: "Both"
        }
    }
}

enum CopyResolution: String, CaseIterable, Identifiable {
    case native
    case downscaled

    var id: Self { self }

    var label: String {
        switch self {
        case .native: "Native"
        case .downscaled: "Downscaled"
        }
    }
}
