import Foundation
import CoreML
import OSLog

/// Host-side RNN-T greedy decoding over the Core ML DecoderStep/JointStep
/// pair — an exact port of the reference loop in the conversion repo's
/// `example_infer.py` and the PyTorch `RNNTGreedyDecoding`:
///
/// ```
/// h = c = zeros(1,1,320); last = blank  // blank embedding row is zeros
/// for t in 0..<enc_len:
///   for _ in 0..<maxSymbolsPerFrame:    // 10
///     dec_out, h_out, c_out = decoder(token: last, h_in: h, c_in: c)
///     k = argmax(joint(enc_t: encoded[t], dec_t: dec_out))
///     if k == blank: break              // state NOT committed on blank
///     ids.append(k); h = h_out; c = c_out; last = k
/// ```
///
/// State resets at the start of every VAD segment. All input buffers are
/// persistent `MLMultiArray`s; the loop allocates nothing per symbol beyond
/// what `prediction(from:)` itself requires.
///
/// NOT thread-safe by design: owned by the engine actor, inference is
/// serialized through it.
final class GigaAMRNNTDecoder {
    static let blankID = 1024
    static let vocabularySize = 1025
    static let predictionHidden = 320
    static let encoderHidden = 768
    static let maxSymbolsPerFrame = 10

    private static let logger = Logger(
        subsystem: "com.livetranslate.ios", category: "coreml-rnnt"
    )

    private let decoderModel: MLModel
    private let jointModel: MLModel

    // Persistent prediction inputs.
    private let tokenInput: MLMultiArray      // Int32 [1,1]
    private let hIn: MLMultiArray             // Float32 [1,1,320]
    private let cIn: MLMultiArray             // Float32 [1,1,320]
    private let encT: MLMultiArray            // Float32, joint's enc_t shape
    private let decT: MLMultiArray            // Float32, joint's dec_t shape

    struct ContractError: Error, CustomStringConvertible {
        let description: String
    }

    init(decoderModel: MLModel, jointModel: MLModel) throws {
        self.decoderModel = decoderModel
        self.jointModel = jointModel

        func requireInput(_ model: MLModel, _ name: String) throws -> MLFeatureDescription {
            guard let desc = model.modelDescription.inputDescriptionsByName[name] else {
                throw ContractError(description: "Core ML model is missing input '\(name)' (got: \(model.modelDescription.inputDescriptionsByName.keys.sorted().joined(separator: ", ")))")
            }
            return desc
        }
        for (model, names) in [
            (decoderModel, ["token", "h_in", "c_in"]),
            (jointModel, ["enc_t", "dec_t"]),
        ] {
            for name in names { _ = try requireInput(model, name) }
        }
        for (model, names) in [
            (decoderModel, ["dec_out", "h_out", "c_out"]),
            (jointModel, ["logits"]),
        ] {
            for name in names where model.modelDescription.outputDescriptionsByName[name] == nil {
                throw ContractError(description: "Core ML model is missing output '\(name)'")
            }
        }

        // Shape the persistent joint inputs from the loaded models' own
        // descriptions so we match whatever the conversion produced.
        func shape(of desc: MLFeatureDescription) -> [NSNumber]? {
            (desc.type == .multiArray) ? desc.multiArrayConstraint?.shape : nil
        }

        let tokenDesc = try requireInput(decoderModel, "token")
        self.tokenInput = try MLMultiArray(
            shape: shape(of: tokenDesc) ?? [1, 1], dataType: .int32
        )
        let hDesc = try requireInput(decoderModel, "h_in")
        self.hIn = try MLMultiArray(
            shape: shape(of: hDesc) ?? [1, 1, 320], dataType: .float32
        )
        let cDesc = try requireInput(decoderModel, "c_in")
        self.cIn = try MLMultiArray(
            shape: shape(of: cDesc) ?? [1, 1, 320], dataType: .float32
        )
        let encDesc = try requireInput(jointModel, "enc_t")
        self.encT = try MLMultiArray(
            shape: shape(of: encDesc) ?? [1, 768], dataType: .float32
        )
        let decDesc = try requireInput(jointModel, "dec_t")
        self.decT = try MLMultiArray(
            shape: shape(of: decDesc) ?? [1, 320], dataType: .float32
        )

        resetState()
    }

    /// Zero h/c and prime the token with blank — "the blank embedding row
    /// is zeros == the reference fresh start".
    private func resetState() {
        zero(hIn)
        zero(cIn)
        let tokenPtr = tokenInput.dataPointer.bindMemory(
            to: Int32.self, capacity: tokenInput.count
        )
        for i in 0..<tokenInput.count {
            tokenPtr[i] = Int32(Self.blankID)
        }
    }

    private func zero(_ array: MLMultiArray) {
        guard array.dataType == .float32 else { return }
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        ptr.initialize(repeating: 0, count: array.count)
    }

    // MARK: - Decoding

    /// Greedy-decode one encoded sequence.
    /// - Parameters:
    ///   - encoded: the encoder output (`encoded`), any float dtype,
    ///     typically [1, 768, T].
    ///   - encodedLength: number of valid time frames.
    /// - Returns: the hypothesis token IDs.
    func decode(encoded: MLMultiArray, encodedLength: Int) throws -> [Int] {
        resetState()

        let encodedShape = encoded.shape.map(\.intValue)
        let timeFrames = min(encodedLength, encodedShape.last ?? 0)
        guard timeFrames > 0, encodedShape.count == 3 else {
            Self.logger.debug("Nothing to decode (len \(encodedLength, privacy: .public), shape \(encodedShape, privacy: .public))")
            return []
        }
        let channels = encodedShape[1]
        let timeDim = encodedShape[2]
        let encStrides = encoded.strides.map(\.intValue)
        let encodedReader = ArrayReader(encoded)

        var hypothesis: [Int] = []
        hypothesis.reserveCapacity(64)

        // Input dictionaries are rebuilt per frame; contents reference the
        // persistent arrays. Keep per-frame allocation out of the symbol loop.
        let decoderInputs = try MLDictionaryFeatureProvider(dictionary: [
            "token": tokenInput, "h_in": hIn, "c_in": cIn,
        ])
        let jointInputs = try MLDictionaryFeatureProvider(dictionary: [
            "enc_t": encT, "dec_t": decT,
        ])

        for t in 0..<timeFrames {
            try autoreleasepool {
                // enc_t <- encoded[0, :, t]
                copyColumn(from: encodedReader, strides: encStrides,
                           timeIndex: t, channels: channels, timeDim: timeDim,
                           into: encT)

                var symbolsThisFrame = 0
                while symbolsThisFrame < Self.maxSymbolsPerFrame {
                    let decOut = try decoderModel.prediction(from: decoderInputs)

                    guard let decOutArray = decOut.featureValue(for: "dec_out")?.multiArrayValue,
                          let hOut = decOut.featureValue(for: "h_out")?.multiArrayValue,
                          let cOut = decOut.featureValue(for: "c_out")?.multiArrayValue
                    else {
                        throw ContractError(description: "DecoderStep outputs missing dec_out/h_out/c_out")
                    }
                    copyLinear(from: decOutArray, into: decT)

                    let jointOut = try jointModel.prediction(from: jointInputs)
                    guard let logits = jointOut.featureValue(for: "logits")?.multiArrayValue else {
                        throw ContractError(description: "JointStep output missing logits")
                    }
                    guard let k = argmaxFirstVocabRow(logits) else {
                        throw ContractError(description: "logits shape \(logits.shape) does not expose a \(Self.vocabularySize)-wide row")
                    }

                    if k == Self.blankID {
                        // Blank: do NOT commit the decoder's h/c — the next
                        // frame must predict from the state of the last
                        // emitted token, exactly like the reference.
                        break
                    }

                    hypothesis.append(k)
                    copyLinear(from: hOut, into: hIn)
                    copyLinear(from: cOut, into: cIn)
                    setToken(k)
                    symbolsThisFrame += 1
                }
            }
        }
        return hypothesis
    }

    // MARK: - Buffer plumbing

    private func setToken(_ id: Int) {
        let ptr = tokenInput.dataPointer.bindMemory(
            to: Int32.self, capacity: tokenInput.count
        )
        ptr[0] = Int32(id)
    }

    /// Copy `source[0, :, timeIndex]` (channel column at one time step)
    /// into `target`. Fast path for contiguous sources.
    private func copyColumn(
        from source: ArrayReader, strides: [Int],
        timeIndex: Int, channels: Int, timeDim: Int, into target: MLMultiArray
    ) {
        let targetReader = ArrayReader(target)
        if strides[2] == 1, strides[1] == timeDim, channels <= target.count {
            // Contiguous: column at channel-stride apart.
            for c in 0..<channels {
                targetReader.store(Float(source.value(atLinearIndex: c * timeDim + timeIndex)), atLinearIndex: c)
            }
        } else {
            for c in 0..<min(channels, target.count) {
                let src = strides[0] * 0 + strides[1] * c + strides[2] * timeIndex
                targetReader.store(Float(source.value(atLinearIndex: src)), atLinearIndex: c)
            }
        }
    }

    /// Element-wise copy honoring each array's strides; element counts must
    /// agree logically (we copy min(count)).
    private func copyLinear(from source: MLMultiArray, into target: MLMultiArray) {
        let src = ArrayReader(source)
        let dst = ArrayReader(target)
        let n = min(source.count, target.count)
        for i in 0..<n {
            dst.store(Float(src.value(atLinearIndex: i)), atLinearIndex: i)
        }
    }

    /// Argmax over the first vocabulary-wide row of `logits`, handling
    /// [1025], [1,1025], [1,1,1025], [1,1,1,1025], … layouts.
    private func argmaxFirstVocabRow(_ logits: MLMultiArray) -> Int? {
        let shape = logits.shape.map(\.intValue)
        let reader = ArrayReader(logits)
        let vocab = Self.vocabularySize

        guard let lastDim = shape.last else { return nil }
        if lastDim == vocab {
            let lastStride = logits.strides.last!.intValue
            var bestIndex = 0
            var bestValue = reader.value(atLinearIndex: 0)
            for j in 1..<vocab {
                let v = reader.value(atLinearIndex: j * lastStride)
                if v > bestValue {
                    bestValue = v
                    bestIndex = j
                }
            }
            return bestIndex
        }
        if logits.count == vocab {
            var bestIndex = 0
            var bestValue = reader.value(atLinearIndex: 0)
            for j in 1..<vocab {
                let v = reader.value(atLinearIndex: j)
                if v > bestValue {
                    bestValue = v
                    bestIndex = j
                }
            }
            return bestIndex
        }
        return nil
    }
}

/// Stride-aware, dtype-aware accessor for MLMultiArray values in Float.
/// Supports float16 / float32 / float64 — an FP16-converted Core ML model
/// may hand back any of them.
struct ArrayReader {
    enum Storage {
        case float16(pointer: UnsafeRawPointer, stride: Int)
        case float32(pointer: UnsafeRawPointer, stride: Int)
        case float64(pointer: UnsafeRawPointer, stride: Int)
        case unsupported(MLMultiArrayDataType)
    }

    private let storage: Storage
    let count: Int

    init(_ array: MLMultiArray) {
        self.count = array.count
        let ptr = UnsafeRawPointer(array.dataPointer)
        switch array.dataType {
        case .float16:
            storage = .float16(pointer: ptr, stride: MemoryLayout<UInt16>.stride)
        case .float32:
            storage = .float32(pointer: ptr, stride: MemoryLayout<Float>.stride)
        case .double:
            storage = .float64(pointer: ptr, stride: MemoryLayout<Double>.stride)
        default:
            storage = .unsupported(array.dataType)
        }
    }

    /// Linear-index read honoring the array's strides.
    func value(atLinearIndex i: Int) -> Float {
        switch storage {
        case .float16(let p, let s):
            let bits = p.load(fromByteOffset: i * s, as: UInt16.self)
            return Float(Float16(bitPattern: bits))
        case .float32(let p, let s):
            return p.load(fromByteOffset: i * s, as: Float.self)
        case .float64(let p, let s):
            return Float(p.load(fromByteOffset: i * s, as: Double.self))
        case .unsupported(let t):
            assertionFailure("Unsupported MLMultiArray dtype \(t)")
            return 0
        }
    }

    /// Linear-index write honoring the array's strides (Float32 targets).
    func store(_ value: Float, atLinearIndex i: Int) {
        switch storage {
        case .float32(let p, let s):
            UnsafeMutableRawPointer(mutating: p).storeBytes(
                of: value, toByteOffset: i * s, as: Float.self
            )
        default:
            assertionFailure("store only supports Float32 targets")
        }
    }
}
