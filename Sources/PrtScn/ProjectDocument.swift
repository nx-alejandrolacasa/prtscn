import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A PrtScn project: a document package (a folder Finder shows as one file)
    /// holding the base image and the annotations still as editable data.
    static let prtscnProject = UTType(exportedAs: "com.alejandrolacasa.prtscn.project",
                                      conformingTo: .package)
}

/// The `.prtscn` package layout: `image.png` (the base capture or canvas, after
/// any crop) next to `document.json` (everything else). Annotations stay in
/// the image's pixel space, so reopening restores them exactly; `captureScale`
/// keeps the 1:1 window size and the point readouts right.
struct ProjectDocument: Codable {
    static let currentVersion = 1
    static let imageName = "image.png"
    static let documentName = "document.json"

    var version = Self.currentVersion
    var captureScale: CGFloat
    var nextCounter: Int
    var annotations: [Annotation]

    /// Serialises the package to `url`, replacing anything already there.
    static func write(image: CGImage, document: ProjectDocument, to url: URL) throws {
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(document)
        let package = FileWrapper(directoryWithFileWrappers: [
            imageName: FileWrapper(regularFileWithContents: png),
            documentName: FileWrapper(regularFileWithContents: json),
        ])
        try package.write(to: url, options: .atomic, originalContentsURL: nil)
    }

    static func read(from url: URL) throws -> (image: NSImage, document: ProjectDocument) {
        let json = try Data(contentsOf: url.appendingPathComponent(documentName))
        let document = try JSONDecoder().decode(ProjectDocument.self, from: json)
        guard document.version <= currentVersion else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard let image = NSImage(contentsOf: url.appendingPathComponent(imageName))
        else { throw CocoaError(.fileReadCorruptFile) }
        return (image, document)
    }
}

extension EditTool: Codable {}
extension LineCap: Codable {}
extension LineBend: Codable {}
extension FontDesign: Codable {}

/// Hand-written so the colour travels as `#RRGGBB` (SwiftUI `Color` isn't
/// Codable) and so a file from another version decodes with defaults for
/// anything it lacks instead of failing outright.
extension Annotation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, start, end, color, lineWidth, fontSize, text, fontDesign, number,
             startCap, endCap, startBinding, endBinding, curvature, bend, elbowH, elbowV
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(kind: try c.decode(EditTool.self, forKey: .kind),
                  start: try c.decode(CGPoint.self, forKey: .start),
                  end: try c.decode(CGPoint.self, forKey: .end),
                  color: Color(hex: try c.decode(String.self, forKey: .color)),
                  lineWidth: try c.decode(CGFloat.self, forKey: .lineWidth),
                  fontSize: try c.decode(CGFloat.self, forKey: .fontSize))
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? text
        fontDesign = try c.decodeIfPresent(FontDesign.self, forKey: .fontDesign) ?? fontDesign
        number = try c.decodeIfPresent(Int.self, forKey: .number) ?? number
        startCap = try c.decodeIfPresent(LineCap.self, forKey: .startCap) ?? startCap
        endCap = try c.decodeIfPresent(LineCap.self, forKey: .endCap) ?? endCap
        startBinding = try c.decodeIfPresent(ShapeBinding.self, forKey: .startBinding)
        endBinding = try c.decodeIfPresent(ShapeBinding.self, forKey: .endBinding)
        curvature = try c.decodeIfPresent(CGFloat.self, forKey: .curvature) ?? curvature
        bend = try c.decodeIfPresent(LineBend.self, forKey: .bend) ?? bend
        elbowH = try c.decodeIfPresent(CGFloat.self, forKey: .elbowH) ?? elbowH
        elbowV = try c.decodeIfPresent(CGFloat.self, forKey: .elbowV) ?? elbowV
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(color.hexString, forKey: .color)
        try c.encode(lineWidth, forKey: .lineWidth)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(text, forKey: .text)
        try c.encode(fontDesign, forKey: .fontDesign)
        try c.encode(number, forKey: .number)
        try c.encode(startCap, forKey: .startCap)
        try c.encode(endCap, forKey: .endCap)
        try c.encodeIfPresent(startBinding, forKey: .startBinding)
        try c.encodeIfPresent(endBinding, forKey: .endBinding)
        try c.encode(curvature, forKey: .curvature)
        try c.encode(bend, forKey: .bend)
        try c.encode(elbowH, forKey: .elbowH)
        try c.encode(elbowV, forKey: .elbowV)
    }
}
