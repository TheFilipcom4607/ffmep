import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Vision

/// Removes photo backgrounds on this Mac: with BiRefNet when it's downloaded and chosen, otherwise with Vision.
/// Runs on the full-resolution image: resizing first would throw away edge detail.
enum BackgroundRemover {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    struct Outcome {
        /// Nil when no subject was found.
        var image: CGImage?
        var note: String?
    }

    static func apply(_ style: BackgroundStyle, detector: SubjectDetector, to image: CGImage) throws -> Outcome {
        guard style.removesBackground else { return Outcome(image: image) }
        let source = CIImage(cgImage: image)

        var note: String?
        var mask: CIImage?
        if detector == .biRefNet, SubjectModel.isInstalled {
            do {
                mask = try modelMask(for: image, source: source)
                if mask == nil { return Outcome(image: nil) }
            } catch {
                note = "Background model failed, used Apple's"
            }
        }
        if mask == nil {
            mask = try subjectMask(for: image, source: source)
        }
        guard let mask else { return Outcome(image: nil, note: note) }

        let background = style == .white
            ? CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1)).cropped(to: source.extent)
            : CIImage(color: .clear).cropped(to: source.extent)

        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = source
        blend.backgroundImage = background
        blend.maskImage = mask
        guard let output = blend.outputImage?.cropped(to: source.extent) else { return Outcome(image: nil, note: note) }
        // Render back into the photo's own colour space: forcing sRGB would squeeze a Display P3
        // photo into a smaller gamut and visibly dull saturated colours.
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        if space.model != .rgb { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        return Outcome(image: ciContext.createCGImage(output, from: source.extent, format: .RGBA8, colorSpace: space), note: note)
    }

    /// BiRefNet's matte in the alpha channel, or nil when nothing in the photo reads as a subject.
    /// Its edges are already crisp and follow the photo, so it's used as is.
    private static func modelMask(for image: CGImage, source: CIImage) throws -> CIImage? {
        let matte = try SubjectMatte.shared.matte(for: image, extent: source.extent)
        guard let peak = ciContext.createCGImage(matte.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: source.extent)]),
                                                 from: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil),
              let pixel = peak.dataProvider?.data.flatMap({ CFDataGetBytePtr($0) }),
              pixel[0] >= 128 else { return nil }
        return alphaFromRed(matte).cropped(to: source.extent)
    }

    /// Moves a matte from the red channel into alpha, clamped to 0…1.
    private static func alphaFromRed(_ matte: CIImage) -> CIImage {
        let move = CIFilter.colorMatrix()
        move.inputImage = matte
        move.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        move.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        move.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        move.aVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        move.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        return (move.outputImage ?? matte).applyingFilter("CIColorClamp")
    }

    /// A full-resolution matte covering every detected subject, in its alpha channel.
    ///
    /// Vision's scaled mask follows the photo's real edges but fades over ~0.5% of the frame and
    /// wobbles where the subject meets similar-looking background. A blur sized to the photo evens
    /// out the wobble, then a steep ramp around a slightly inward threshold makes the edge crisp
    /// again (a few pixels of anti-aliasing) without keeping background colour along it.
    ///
    /// Tried and rejected: upscaling Vision's native 512×512 mask (it is nearly binary, so edges
    /// come out as visible stair steps), CIEdgePreserveUpsample (barely moves the edge), and a
    /// guided-filter refinement (smears background colour into a halo, ~11s per photo).
    private static func subjectMask(for image: CGImage, source: CIImage) throws -> CIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }

        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        // No colour space: the mask is coverage, and colour-managing it bends the edge ramp.
        let matte = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])

        let target = source.extent
        let longSide = max(target.width, target.height)
        let sigma = longSide * 0.004
        let visionSoftness = longSide / 570
        let edgeWidth = max(1.5, longSide / 1150)
        // A blurred edge's midpoint slope is 1/(σ·√2π); scale it so the edge spans `edgeWidth` pixels.
        let gain = (sigma * sigma + visionSoftness * visionSoftness).squareRoot() * (2 * .pi).squareRoot() / edgeWidth
        let threshold: CGFloat = 0.6

        let blurred = matte.clampedToExtent().applyingGaussianBlur(sigma: sigma)
        let ramp = CIFilter.colorMatrix()
        ramp.inputImage = blurred
        ramp.rVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        ramp.gVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        ramp.bVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        ramp.aVector = CIVector(x: gain, y: 0, z: 0, w: 0)
        ramp.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0.5 - threshold * gain)
        guard let alpha = ramp.outputImage else { return nil }
        return alpha.applyingFilter("CIColorClamp").cropped(to: target)
    }
}
