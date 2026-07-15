import CoreGraphics
import Foundation

/// Stitches successive frames of a scrolling capture into one tall image.
///
/// Frames all share the region's size; after each scroll step the stitcher
/// *measures* how far the content actually moved (row-signature matching —
/// never trusting the nominal scroll delta) and appends only the newly
/// revealed strip: the frame's bottom rows when scrolling down, its top rows
/// (prepended) when scrolling up.
final class ScrollStitcher {
    /// Which way the capture walks the content. Scrolling down reveals new
    /// rows at the bottom of each frame; scrolling up (⌘-drag — chats) at
    /// the top.
    enum Direction {
        case down, up
    }

    /// One canvas up front, no alpha channel. `CGImage.cropping(to:)` retains
    /// its parent's full backing store, so accumulating cropped strips would
    /// silently pin every full frame in memory; a single lazily-committed
    /// bitmap keeps the peak at roughly the final image size. The missing
    /// alpha channel also lets the editor skip its transparency-inset scan.
    ///
    /// Downward stitches grow from the canvas top; upward ones from the
    /// bottom (prepending in memory would mean shifting everything).
    private let canvas: CGContext
    private let direction: Direction
    private let widthPx: Int
    private let frameHeightPx: Int
    private let maxHeightPx: Int

    private(set) var stitchedHeightPx: Int

    /// Grayscale row signatures of the previous frame (`signatureWidth`
    /// samples per row, rows top-to-bottom — bitmap memory order).
    private var lastSignature: [UInt8]

    /// Horizontal samples per row. Needs to be fine enough that *different*
    /// text rows get different signatures: repetitive content (terminals —
    /// line-number gutters, blank rows) produces many shallow false minima
    /// when each sample averages ~40 px of glyphs. 160 keeps the SAD search
    /// cheap while giving text rows enough horizontal identity.
    private static let signatureWidth = 160
    /// Never search past `frameHeight − minOverlap`: below this overlap the
    /// match is too flimsy to trust.
    private static let minOverlapPx = 80
    /// Trimmed score at offset 0 below which the frame counts as unchanged
    /// (end of the content reached).
    private static let noChangeThreshold = 2.0
    /// Trimmed best-match score above which we declare the content
    /// untrackable (jumping scrollback, heavy animation) and keep what we
    /// have. Deliberately strict: in TUI content the 12–18 band contains
    /// *wrong* alignments that produce ghosted seams (observed), and a clean
    /// partial beats a long corrupt stitch. Websites score ~0–3 on correct
    /// matches, so they never feel this limit.
    private static let matchThreshold = 12.0
    /// Fraction of rows kept by the trimmed score — the worst quarter is
    /// discarded, so a sticky header, blinking caret, or playing video that
    /// occupies less than ~25 % of the region can't poison an otherwise
    /// perfect alignment (or block end detection).
    private static let trimmedKeepFraction = 0.75

    enum AppendResult {
        case advanced
        case noChange
        case lostTrack
    }

    /// Match numbers from the latest `append` — surfaced in the capture-end
    /// diagnostics so a lost-track report says *why* (score too high at the
    /// best offset vs. best offset pinned at the window edge = overshoot).
    private(set) var lastMatchInfo = "no frames appended"

    /// The previous step's measured offset. In blank or repetitive bands
    /// (terminal chat: whitespace gaps, near-identical code blocks) every
    /// offset scores near zero and the argmin is arbitrary — the classic
    /// cause of duplicated or dropped sections. Identical glide steps move
    /// content by a near-constant amount, so near-ties resolve toward the
    /// previous advance; the penalty (≤ ~5 across the whole window) is far
    /// too small to override real signal, which separates by 20+.
    private var lastAdvance = 0
    private static let consistencyWeight = 0.02
    /// Penalty ceiling: strong enough to decide ties between *equally good*
    /// matches (repeated content scores ~0–2 at both the true and the false
    /// offset), but a genuinely better match — wrong offsets score 20+ —
    /// must always be able to win regardless of distance.
    private static let consistencyCap = 8.0

    private func consistencyPenalty(_ offset: Int) -> Double {
        guard lastAdvance > 0 else { return 0 }
        return min(Double(abs(offset - lastAdvance)) * Self.consistencyWeight,
                   Self.consistencyCap)
    }

    init?(firstFrame: CGImage, maxHeightPx: Int, direction: Direction) {
        self.direction = direction
        widthPx = firstFrame.width
        frameHeightPx = firstFrame.height
        self.maxHeightPx = max(maxHeightPx, frameHeightPx)
        guard widthPx > 0, frameHeightPx > Self.minOverlapPx,
              let context = CGContext(
                  data: nil, width: widthPx, height: self.maxHeightPx,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ),
              let signature = Self.rowSignatures(of: firstFrame)
        else { return nil }
        canvas = context
        canvas.interpolationQuality = .none
        lastSignature = signature
        stitchedHeightPx = frameHeightPx
        // CG rects are bottom-left-origin: the canvas top is its highest y.
        let firstY: CGFloat = direction == .down
            ? CGFloat(self.maxHeightPx - frameHeightPx)   // top — grows down
            : 0                                            // bottom — grows up
        canvas.draw(firstFrame, in: CGRect(
            x: 0, y: firstY, width: CGFloat(widthPx), height: CGFloat(frameHeightPx)
        ))
    }

    /// Aligns `frame` against the previous one and appends the newly revealed
    /// strip (actual movement is measured, never assumed).
    func append(_ frame: CGImage) -> AppendResult {
        guard frame.width == widthPx, frame.height == frameHeightPx,
              let next = Self.rowSignatures(of: frame)
        else {
            lastMatchInfo = "frame size mismatch or signature failure"
            return .lostTrack
        }

        if alignmentTrimmedScore(next, offset: 0) < Self.noChangeThreshold {
            return .noChange
        }

        // Scrolled by d ⇒ one frame's rows [d, H) match the other's [0, H−d)
        // (which frame is shifted depends on the direction — the wrappers
        // below sort that out). Search every offset that leaves the minimum
        // overlap: apps are free to mangle the nominal step (terminals round
        // every wheel event up to whole lines, easily doubling the movement),
        // so no expectation-based bound is safe. Ranking uses the plain mean
        // (cheap, and the abort cutoff prunes hopeless offsets after a few
        // rows); the winner is then accepted or rejected on its trimmed
        // score, which shrugs off sticky headers and animated bands.
        let maxSearch = frameHeightPx - Self.minOverlapPx
        guard maxSearch >= 1 else {
            lastMatchInfo = "frame too short to search"
            return .lostTrack
        }

        var bestOffset = 0
        var bestScore = Double.infinity     // consistency-adjusted, for selection
        for offset in 1...maxSearch {
            let s = alignmentMeanScore(next, offset: offset, rowStride: 2,
                                       abortAbove: bestScore * 3)
                + consistencyPenalty(offset)
            if s < bestScore {
                bestScore = s
                bestOffset = offset
            }
        }
        // Rescore the winner and its immediate neighbors at full row density —
        // a one-pixel misalignment doubles every glyph edge at the seam, so
        // the final offset must come from the finest comparison we have.
        for candidate in max(1, bestOffset - 1)...min(maxSearch, bestOffset + 1) {
            let s = alignmentMeanScore(next, offset: candidate, rowStride: 1,
                                       abortAbove: .infinity)
                + consistencyPenalty(candidate)
            if s < bestScore {
                bestScore = s
                bestOffset = candidate
            }
        }
        let trimmed = alignmentTrimmedScore(next, offset: bestOffset)
        lastMatchInfo = "offset \(bestOffset)/\(maxSearch) (prev \(lastAdvance)), mean "
            + String(format: "%.1f, trimmed %.1f (limit %.0f)",
                     bestScore, trimmed, Self.matchThreshold)
        guard bestOffset > 0, trimmed <= Self.matchThreshold else {
            return .lostTrack
        }

        // The newly revealed band is `bestOffset` rows at the frame's bottom
        // (scrolling down) or top (scrolling up). When the canvas cap clamps
        // the advance, keep the band's rows *adjacent to the seam* — the
        // frame's far edge would leave a gap. Zero advance can only mean the
        // canvas is full, which reads as the end to the caller.
        let advance = min(bestOffset, maxHeightPx - stitchedHeightPx)
        guard advance > 0 else { return .noChange }
        // Crop rects on CGImage are top-left-origin.
        let bandY: CGFloat = direction == .down
            ? CGFloat(frameHeightPx - bestOffset)              // band top
            : CGFloat(bestOffset - advance)                     // band bottom
        guard let strip = frame.cropping(to: CGRect(
            x: 0, y: bandY, width: CGFloat(widthPx), height: CGFloat(advance)
        )) else {
            lastMatchInfo += " — tail crop failed"
            return .lostTrack
        }
        // Canvas draw rects are bottom-left-origin.
        let drawY: CGFloat = direction == .down
            ? CGFloat(maxHeightPx - stitchedHeightPx - advance) // below content
            : CGFloat(stitchedHeightPx)                          // above content
        canvas.draw(strip, in: CGRect(
            x: 0, y: drawY, width: CGFloat(widthPx), height: CGFloat(advance)
        ))
        stitchedHeightPx += advance
        lastSignature = next
        lastAdvance = bestOffset
        return .advanced
    }

    /// The stitched image so far. Built straight from the canvas's used rows
    /// (bitmap memory starts at the visual top: downward stitches occupy the
    /// first rows, upward ones the last), copying only `stitchedHeightPx`
    /// rows instead of snapshotting the whole backing store.
    func makeFinalImage() -> CGImage? {
        guard let base = canvas.data else { return nil }
        let bytesPerRow = canvas.bytesPerRow
        let firstRow = direction == .down ? 0 : maxHeightPx - stitchedHeightPx
        let data = Data(bytes: base.advanced(by: firstRow * bytesPerRow),
                        count: bytesPerRow * stitchedHeightPx)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: widthPx, height: stitchedHeightPx,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Scoring

    /// Scrolling down shifts content up: the *previous* frame's row `d`
    /// aligns with the new frame's row 0. Scrolling up mirrors that — the
    /// *new* frame's row `d` aligns with the previous frame's row 0. Both
    /// wrappers hide the operand order from `append`.
    private func alignmentMeanScore(_ next: [UInt8], offset: Int, rowStride: Int,
                                    abortAbove: Double) -> Double {
        switch direction {
        case .down:
            Self.meanScore(shifted: lastSignature, reference: next,
                           offset: offset, rowStride: rowStride, abortAbove: abortAbove)
        case .up:
            Self.meanScore(shifted: next, reference: lastSignature,
                           offset: offset, rowStride: rowStride, abortAbove: abortAbove)
        }
    }

    private func alignmentTrimmedScore(_ next: [UInt8], offset: Int) -> Double {
        switch direction {
        case .down:
            Self.trimmedScore(shifted: lastSignature, reference: next, offset: offset)
        case .up:
            Self.trimmedScore(shifted: next, reference: lastSignature, offset: offset)
        }
    }

    /// Mean absolute difference per sample between `shifted` moved up by
    /// `offset` rows and `reference`. Bails out early once the running mean
    /// is hopelessly above `abortAbove` — with a 3× margin so a sticky
    /// header's expensive first rows can't kill the true offset.
    private static func meanScore(shifted: [UInt8], reference: [UInt8],
                                  offset: Int, rowStride: Int,
                                  abortAbove: Double) -> Double {
        let width = signatureWidth
        let rows = shifted.count / width - offset
        guard rows > 0, shifted.count == reference.count else { return .infinity }
        var total = 0
        var count = 0
        var aborted = false
        shifted.withUnsafeBufferPointer { shiftedBuffer in
            reference.withUnsafeBufferPointer { referenceBuffer in
                guard let s = shiftedBuffer.baseAddress,
                      let r = referenceBuffer.baseAddress else { return }
                var row = 0
                var processed = 0
                while row < rows {
                    let p = s + (row + offset) * width
                    let n = r + row * width
                    for column in 0..<width {
                        total += abs(Int(p[column]) - Int(n[column]))
                    }
                    count += width
                    row += rowStride
                    processed += 1
                    if processed & 31 == 0, Double(total) / Double(count) > abortAbove {
                        aborted = true
                        return
                    }
                }
            }
        }
        guard !aborted, count > 0 else { return .infinity }
        return Double(total) / Double(count)
    }

    /// Robust score: per-row mean differences, worst quarter discarded. Used
    /// for the accept/reject decisions so a static band (sticky header) or a
    /// permanently animating one (video, spinner, caret) can't dominate.
    private static func trimmedScore(shifted: [UInt8], reference: [UInt8],
                                     offset: Int) -> Double {
        let width = signatureWidth
        let rows = shifted.count / width - offset
        guard rows > 0, shifted.count == reference.count else { return .infinity }
        var rowScores = [Double](repeating: 0, count: rows)
        shifted.withUnsafeBufferPointer { shiftedBuffer in
            reference.withUnsafeBufferPointer { referenceBuffer in
                guard let s = shiftedBuffer.baseAddress,
                      let r = referenceBuffer.baseAddress else { return }
                for row in 0..<rows {
                    let p = s + (row + offset) * width
                    let n = r + row * width
                    var rowTotal = 0
                    for column in 0..<width {
                        rowTotal += abs(Int(p[column]) - Int(n[column]))
                    }
                    rowScores[row] = Double(rowTotal) / Double(width)
                }
            }
        }
        rowScores.sort()
        let kept = max(1, Int(Double(rows) * trimmedKeepFraction))
        return rowScores[0..<kept].reduce(0, +) / Double(kept)
    }

    /// Whether two captures of the same rect show the content at rest — the
    /// controller retakes frames until this holds, so a frame mid smooth-
    /// scroll animation (or mid elastic bounce at the content's end) is
    /// never stitched; such frames match no resting scroll position and
    /// would ghost the seam. Trimmed like the other scores, so a playing
    /// video can't hold the capture hostage.
    static func framesLookSettled(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height,
              let sa = rowSignatures(of: a), let sb = rowSignatures(of: b)
        else { return false }
        return trimmedScore(shifted: sa, reference: sb, offset: 0) < noChangeThreshold
    }

    /// Downsamples a frame to `signatureWidth` grayscale columns in one CG
    /// draw; the raw bitmap buffer *is* the signature matrix (row `y` starts
    /// at byte `y × signatureWidth`, rows in visual top-to-bottom order).
    private static func rowSignatures(of frame: CGImage) -> [UInt8]? {
        let width = signatureWidth
        let height = frame.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(frame, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        return drawn ? buffer : nil
    }
}
