import CoreImage
import CoreML
import Foundation
import Vision

/// The optional BiRefNet background model: where it comes from and where it lives once installed.
enum SubjectModel {
    static let name = "BiRefNet"
    static let downloadURL = URL(string: "https://github.com/TheFilipcom4607/birefnet-coreml/releases/download/v1.0.0/BiRefNet.mlpackage.zip")!
    static let sha256 = "2d16cfdb709cd447c336cb5376ba302ab5e5866b3392df1f55f5766047f29e73"
    static let downloadBytes: Int64 = 407_932_801
    static let projectURL = URL(string: "https://github.com/TheFilipcom4607/birefnet-coreml")!

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ffmep/Models", isDirectory: true)
    }

    /// The compiled model, ready to load.
    static var compiledURL: URL { directory.appendingPathComponent("BiRefNet.mlmodelc", isDirectory: true) }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: compiledURL.path) }
}

/// Runs BiRefNet on a photo and returns a matte the size of the photo.
///
/// Only one prediction runs at a time: the model needs a couple of GB of GPU memory, and image jobs
/// run many at once. It loads with `.cpuAndGPU` because the Neural Engine can't build a plan for it
/// (it tries for over a minute, then fails).
final class SubjectMatte: @unchecked Sendable {
    static let shared = SubjectMatte()

    private let lock = NSLock()
    private var model: MLModel?
    private var loadedFrom: URL?

    /// Drops the loaded model, e.g. after its files were removed.
    func unload() {
        lock.withLock {
            model = nil
            loadedFrom = nil
        }
    }

    /// Coverage in 0…1 for every pixel of `extent`, as a CIImage whose red channel holds the matte.
    func matte(for image: CGImage, extent: CGRect, modelURL: URL = SubjectModel.compiledURL) throws -> CIImage {
        let (values, width, height) = try lock.withLock { () -> ([Float], Int, Int) in
            let model = try loadedModel(at: modelURL)
            guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
                throw SubjectMatteError.unexpectedModel
            }
            let feature = try MLFeatureValue(cgImage: image, constraint: input, options: [
                .cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue,
            ])
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": feature]))
            guard let buffer = output.featureValue(for: "mask")?.imageBufferValue else {
                throw SubjectMatteError.unexpectedModel
            }
            // Copy out while locked: Core ML may reuse the output buffer for the next prediction.
            return try Self.floats(from: buffer)
        }

        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let small = CIImage(bitmapData: data, bytesPerRow: width * MemoryLayout<Float>.size,
                            size: CGSize(width: width, height: height), format: .Lf, colorSpace: nil)
        return small
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .cropped(to: extent)
    }

    private func loadedModel(at url: URL) throws -> MLModel {
        if let model, loadedFrom == url { return model }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let loaded = try MLModel(contentsOf: url, configuration: config)
        model = loaded
        loadedFrom = url
        return loaded
    }

    /// Reads a one-channel Float16 or Float32 buffer, top row first.
    private static func floats(from buffer: CVPixelBuffer) throws -> ([Float], Int, Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SubjectMatteError.unexpectedModel }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<width { values[y * width + x] = Float(row[x]) }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = (base + y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        default:
            throw SubjectMatteError.unexpectedModel
        }
        return (values, width, height)
    }
}

enum SubjectMatteError: LocalizedError {
    case unexpectedModel

    var errorDescription: String? { "The background model file isn't the expected BiRefNet model." }
}
