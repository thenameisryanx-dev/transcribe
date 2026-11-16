import AudioCommon
import Foundation
import MLX
import MLXNN

// Added in this copy (not in speech-swift): batched synthesis that sounds like the one-sentence path.
//
// Making speech is one small step of the model per 80 ms of audio, and at one sentence a step leaves most of the GPU
// idle: the time goes into reading the model's weights. Running several sentences through each step reads them once
// for all, so on a base M4 four sentences take about as long as two do one at a time.
//
// The library's `synthesizeBatch` can't be used for this: it leaves out the chosen voice and the repetition penalty,
// and its sentences came out alike. This follows `synthesize(text:language:speaker:...)` step for step instead: the
// same prompt (voice, language and "Speak naturally."), the same sampling with each sentence's own repetition
// penalty, and each sentence's own length cap. A sentence leaves the batch as soon as it ends, so a short one
// doesn't keep running beside a long one.

extension Qwen3TTSModel {
    /// Speaks `texts` in one voice, several at once. Returns each text's 24 kHz audio, in order (empty when the model
    /// made none). `checkCancellation` runs between steps and may throw to stop.
    public func synthesizeVoiceBatch(
        texts: [String],
        language: String,
        speaker: String?,
        sampling: SamplingConfig = .default,
        checkCancellation: () throws -> Void = {}
    ) throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        guard let tokenizer else { throw TTSError.tokenizerNotLoaded }
        try checkCancellation()

        let (speakerTokenId, effectiveLanguage) = resolveSpeaker(speaker, language: language, languageExplicit: true)
        guard let languageId = CodecTokens.languageId(for: effectiveLanguage) else {
            throw TTSError.unknownLanguage(effectiveLanguage)
        }
        let instructTokens = (speakerConfig != nil ? Self.defaultInstruct : nil)
            .map { prepareInstructTokens(instruct: $0, tokenizer: tokenizer) }
        let codecPrefix = buildCodecPrefix(languageId: languageId, speakerTokenId: speakerTokenId)

        // Every prompt is the same length up to the first word; the rest of each text is fed in a token per step.
        var prefills: [MLXArray] = []
        var trailings: [MLXArray] = []
        var padEmbed: MLXArray?
        for text in texts {
            let textTokens = prepareTextTokens(text: text, tokenizer: tokenizer)
            let (prefill, trailing, pad) = buildPrefillEmbeddings(
                textTokens: textTokens, codecPrefixTokens: codecPrefix, instructTokens: instructTokens)
            prefills.append(prefill)
            trailings.append(trailing)
            padEmbed = pad
        }
        guard let padEmbed else { return [] }
        let hiddenSize = config.talker.hiddenSize
        let longestTrailing = trailings.map { $0.dim(1) }.max() ?? 0
        // A text that has run out is fed the pad token, as the one-sentence path does.
        let trailing = concatenated(trailings.map { item in
            let missing = longestTrailing - item.dim(1)
            return missing == 0 ? item : concatenated([item, broadcast(padEmbed, to: [1, missing, hiddenSize])], axis: 1)
        }, axis: 0)  // [B, longestTrailing, D]
        // As in the one-sentence path: the text's own cap, and never more than 2048 frames.
        let caps = texts.map { min(maxTokenCap(for: [$0], tokenizer: tokenizer, sampling: sampling), 2048) }

        var batch = VoiceBatchState(
            rows: Array(texts.indices),
            trailing: trailing,
            seen: MLXArray.zeros([texts.count, config.talker.codecVocabSize], type: Bool.self))
        var frames = [[Int32]](repeating: [], count: texts.count)

        // Prefill all prompts at once.
        let prefill = concatenated(prefills, axis: 0)
        let prefillLength = prefill.dim(1)
        var (logits, hidden, cache) = talker(inputsEmbeds: prefill, offset: MLXArray(Int32(0)), cache: nil)
        logits = logits[0..., (prefillLength - 1)..<prefillLength, 0...]
        hidden = hidden[0..., (prefillLength - 1)..<prefillLength, 0...]
        batch.cache = cache
        try checkCancellation()

        var trailingIndex = 0
        var position = prefillLength
        let codeGroups = config.codePredictor.numCodeGroups
        while !batch.rows.isEmpty {
            try checkCancellation()
            // The first codebook, for every sentence still going.
            let first = Self.sampleFirstCodebook(logits: logits, seen: batch.seen, sampling: sampling)
            eval(first)
            let firstValues = first.asArray(Int32.self)
            let going = firstValues.indices.filter { firstValues[$0] != Int32(CodecTokens.codecEos) }
            var firstTokens = first
            if going.count < batch.rows.count {
                let keep = MLXArray(going.map(Int32.init))
                batch.keep(going, indices: keep)
                firstTokens = first[keep]
                hidden = hidden[keep]
                guard !batch.rows.isEmpty else { break }
            }
            batch.seen = logicalOr(batch.seen, Self.oneHot(firstTokens, count: batch.seen.dim(1)))

            // The other 15 codebooks of this frame.
            let rest = predictCodebooksBatch(hidden: hidden, firstTokens: firstTokens, sampling: sampling)  // [B, 15]
            let frame = concatenated([firstTokens.expandedDimensions(axis: 1), rest], axis: 1)  // [B, 16]
            eval(frame)
            let frameValues = frame.asArray(Int32.self)
            var capped: [Int] = []
            for (row, item) in batch.rows.enumerated() {
                frames[item].append(contentsOf: frameValues[(row * codeGroups)..<((row + 1) * codeGroups)])
                if frames[item].count / codeGroups >= caps[item] { capped.append(row) }
            }

            // Next step's input: the next token of each text plus this frame's codes.
            let textEmbed: MLXArray
            if trailingIndex < longestTrailing {
                textEmbed = batch.trailing[0..., trailingIndex..<(trailingIndex + 1), 0...]
                trailingIndex += 1
            } else {
                textEmbed = broadcast(padEmbed, to: [batch.rows.count, 1, hiddenSize])
            }
            let codecEmbed = talker.embedCodec(firstTokens.expandedDimensions(axis: 1))
                + codePredictor.batchEmbedAllGroupsBatch(rest)
            var stepEmbeds = textEmbed + codecEmbed
            if !capped.isEmpty {
                let remaining = batch.rows.indices.filter { !capped.contains($0) }
                let keep = MLXArray(remaining.map(Int32.init))
                batch.keep(remaining, indices: keep)
                stepEmbeds = stepEmbeds[keep]
                guard !batch.rows.isEmpty else { break }
            }

            (logits, hidden, cache) = executeTalkerStepBatch(embeds: stepEmbeds, offset: position, cache: batch.cache)
            batch.cache = cache
            position += 1
        }

        // Turn each sentence's codes into audio.
        return try frames.map { codes in
            try checkCancellation()
            let count = codes.count / codeGroups
            guard count > 0 else { return [] }
            let codebooks = MLXArray(codes).reshaped(count, codeGroups).transposed(1, 0).expandedDimensions(axis: 0)
            return codecDecoder.decode(codes: codebooks)  // [1, 16, T] → samples
        }
    }

    /// The first codebook's token for each row, sampled as `sampleToken` samples it for one sentence: the codes the
    /// talker mustn't make suppressed (all but end-of-speech), a repetition penalty on the tokens the row already made,
    /// then temperature, top-k and top-p with end-of-speech kept, and a Gumbel-max draw.
    static func sampleFirstCodebook(logits: MLXArray, seen: MLXArray, sampling: SamplingConfig) -> MLXArray {
        var scores = logits.squeezed(axis: 1).asType(.float32)  // [B, V]
        let vocabSize = scores.dim(1)
        let eos = CodecTokens.codecEos
        let indices = MLXArray(0..<Int32(vocabSize))
        let suppressed = logicalAnd(logicalAnd(indices .>= MLXArray(Int32(2048)), indices .< MLXArray(Int32(3072))),
                                    indices .!= MLXArray(Int32(eos)))
        scores = MLX.where(suppressed, MLXArray(Float(-1e9)), scores)

        if sampling.repetitionPenalty != 1.0 {
            let penalty = MLXArray(sampling.repetitionPenalty)
            let penalized = MLX.where(scores .< MLXArray(Float(0)), scores * penalty, scores / penalty)
            scores = MLX.where(seen, penalized, scores)
        }

        if sampling.temperature <= 0 {
            return argMax(scores, axis: 1).asType(.int32)
        }
        scores = scores / MLXArray(sampling.temperature)
        let eosScore = scores[0..., eos..<(eos + 1)]  // [B, 1]

        if sampling.topK > 0 && sampling.topK < vocabSize {
            let threshold = MLX.sorted(scores, axis: 1)[0..., (vocabSize - sampling.topK)..<(vocabSize - sampling.topK + 1)]
            scores = MLX.where(scores .< threshold, MLXArray(Float(-1e9)), scores)
        }
        if sampling.topP < 1.0 {
            let order = argSort(scores, axis: 1)
            let sorted = takeAlong(scores, order, axis: 1)
            let probabilities = softmax(sorted, axis: 1)
            let dropped = (cumsum(probabilities, axis: 1) - probabilities) .> MLXArray(sampling.topP)
            let filtered = MLX.where(dropped, MLXArray(Float(-1e9)), sorted)
            scores = takeAlong(filtered, argSort(order, axis: 1), axis: 1)
        }
        let biasedEos = sampling.eosLogitBias != 0 ? eosScore + MLXArray(sampling.eosLogitBias) : eosScore
        scores = MLX.where(indices .== MLXArray(Int32(eos)), biasedEos, scores)

        return argMax(scores + MLXRandom.gumbel(scores.shape), axis: 1).asType(.int32)
    }

    /// One talker step for every row, compiled for this many rows (see `compiledBatchTalkerSteps`). All rows are at the
    /// same position: they started together.
    func executeTalkerStepBatch(
        embeds: MLXArray, offset: Int, cache: [(MLXArray, MLXArray)]
    ) -> (MLXArray, MLXArray, [(MLXArray, MLXArray)]) {
        let rows = embeds.dim(0)
        guard rows > 1 else { return executeTalkerStep(embeds: embeds, offset: offset, cache: cache) }
        // One position per row: given a single position, the fused RoPE kernel moves only the first row there and
        // leaves the others at the start, so they never come to an end.
        let offsets = MLXArray([Int32](repeating: Int32(offset), count: rows))
        let layers = config.talker.numLayers
        let compiled: ([MLXArray]) -> [MLXArray]
        if let cached = compiledBatchTalkerSteps[rows] {
            compiled = cached
        } else {
            let talker = talker
            compiled = compile(inputs: [talker], outputs: [talker], shapeless: true) { inputs in
                var cache: [(MLXArray, MLXArray)] = []
                for layer in 0..<layers { cache.append((inputs[2 + layer * 2], inputs[3 + layer * 2])) }
                let (logits, hidden, newCache) = talker(inputsEmbeds: inputs[0], offset: inputs[1], cache: cache)
                return [logits, hidden] + newCache.flatMap { [$0.0, $0.1] }
            }
            compiledBatchTalkerSteps[rows] = compiled
        }
        let out = compiled([embeds, offsets] + cache.flatMap { [$0.0, $0.1] })
        let newCache = (0..<layers).map { (out[2 + $0 * 2], out[3 + $0 * 2]) }
        return (out[0], out[1], newCache)
    }

    static func oneHot(_ tokens: MLXArray, count: Int) -> MLXArray {
        tokens.expandedDimensions(axis: 1) .== MLXArray(0..<Int32(count)).expandedDimensions(axis: 0)
    }

    /// The 15 codebooks after the first for each row, as the one-sentence path's compiled frame predicts them.
    func predictCodebooksBatch(hidden: MLXArray, firstTokens: MLXArray, sampling: SamplingConfig) -> MLXArray {
        let batchSize = hidden.dim(0)
        let inputs = concatenated([hidden, talker.embedCodec(firstTokens.expandedDimensions(axis: 1))], axis: 1)  // [B, 2, D]
        let greedy = sampling.temperature <= 0
        let key = CodePredictorFrameCompileKey(greedy: greedy, topK: greedy ? 0 : sampling.topK)
        let compiled: ([MLXArray]) -> [MLXArray]
        if let cached = compiledCodePredictorBatchFrames[key] {
            compiled = cached
        } else {
            let predictor = codePredictor
            // Not shapeless: each batch size gets its own graph, traced the first time it's used.
            compiled = compile(inputs: [predictor], outputs: [predictor], shapeless: false) { inputs in
                [predictor.predictFrameBatch(
                    inputsEmbeds: inputs[0], temperature: inputs[1], gumbels: inputs[2], topK: key.topK, greedy: key.greedy)]
            }
            compiledCodePredictorBatchFrames[key] = compiled
        }
        let groups = config.codePredictor.numCodeGroups - 1
        let vocabSize = config.codePredictor.vocabSize
        let gumbels = greedy
            ? MLXArray.zeros([groups, batchSize, vocabSize])
            : MLXRandom.gumbel([groups, batchSize, vocabSize])
        return compiled([inputs, MLXArray(sampling.temperature), gumbels])[0]
    }
}

extension CodePredictorModel {
    /// `predictFrame` for several rows: `inputsEmbeds` is [B, 2, D] and `gumbels` [15, B, vocab]; returns [B, 15].
    func predictFrameBatch(
        inputsEmbeds: MLXArray,
        temperature: MLXArray,
        gumbels: MLXArray,
        topK: Int,
        greedy: Bool
    ) -> MLXArray {
        let groups = config.numCodeGroups - 1
        var (logits, cache) = self(inputsEmbeds: inputsEmbeds, groupIndex: 0, cache: nil)
        var token = Self.sampleRows(
            logits[0..., (logits.dim(1) - 1)..<logits.dim(1), 0...], temperature: temperature, gumbel: gumbels[0],
            topK: topK, greedy: greedy)
        var tokens = [token]
        for group in 1..<groups {
            let embedding = embedCodecGroup(token.expandedDimensions(axis: 1), groupIndex: group - 1)  // [B, 1, D]
            (logits, cache) = self(inputsEmbeds: embedding, groupIndex: group, cache: cache)
            token = Self.sampleRows(logits, temperature: temperature, gumbel: gumbels[group], topK: topK, greedy: greedy)
            tokens.append(token)
        }
        return stacked(tokens, axis: 1)
    }

    /// `sampleFrameToken` for each row of [B, 1, vocab] logits: temperature, top-k and a Gumbel-max draw.
    static func sampleRows(_ logits: MLXArray, temperature: MLXArray, gumbel: MLXArray, topK: Int, greedy: Bool) -> MLXArray {
        var scores = logits.squeezed(axis: 1).asType(.float32)  // [B, vocab]
        if greedy {
            return argMax(scores, axis: 1).asType(.int32)
        }
        scores = scores / temperature.asType(.float32)
        let vocabSize = scores.dim(1)
        if topK > 0 && topK < vocabSize {
            let threshold = MLX.sorted(scores, axis: 1)[0..., (vocabSize - topK)..<(vocabSize - topK + 1)]
            scores = MLX.where(scores .< threshold, MLXArray(Float(-1e9)), scores)
        }
        return argMax(scores + gumbel, axis: 1).asType(.int32)
    }
}

/// The rows of a batch still being made, and everything that has a row per sentence.
private struct VoiceBatchState {
    /// Which text each row is.
    var rows: [Int]
    var trailing: MLXArray
    /// Tokens each row has made, for the repetition penalty: [B, vocab].
    var seen: MLXArray
    var cache: [(MLXArray, MLXArray)] = []

    /// Keeps only the rows at `kept` (`indices` is the same, as an array).
    mutating func keep(_ kept: [Int], indices: MLXArray) {
        rows = kept.map { rows[$0] }
        guard !kept.isEmpty else { return }
        trailing = trailing[indices]
        seen = seen[indices]
        cache = cache.map { ($0.0[indices], $0.1[indices]) }
    }
}

