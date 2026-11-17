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
// and its sentences came out alike. This follows Qwen's own `generate_custom_voice` instead: the same prompt (voice
// and language), the same sampling with each sentence's own repetition penalty, and each sentence's own length cap.
// A sentence leaves the batch as soon as it ends, so a short one doesn't keep running beside a long one.
//
// The whole sentence goes into the prompt before any speech is made, as Qwen's code does by default
// (`non_streaming_mode=True`). speech-swift fed it one token per frame instead (Qwen's simulated streaming input), so
// the voice only ever knew the word it was on and the next one, and read word by word, with odd pauses and a tone
// that wandered from sentence to sentence. Whole sentences make prompts of different lengths, so shorter ones are
// padded at the front and the padding is masked out of attention.

extension Qwen3TTSModel {
    /// How a sentence's text reaches the model.
    public enum TextFeed: Sendable {
        /// All of it is in the prompt before the first frame of speech, so the voice can phrase the sentence as a
        /// whole. Qwen's default for its built-in voices.
        case wholeText
        /// One token per frame of speech after the first (Qwen's simulated streaming input): the voice reads word by
        /// word. What speech-swift did; kept to compare against.
        case tokenPerStep
    }

    /// Speaks `texts` in one voice, several at once. Returns each text's 24 kHz audio, in order (empty when the model
    /// made none). `instruct` is an instruction to the voice; Qwen's code drops it for the 0.6B models, which weren't
    /// trained with one, so it's nil by default. `checkCancellation` runs between steps and may throw to stop.
    public func synthesizeVoiceBatch(
        texts: [String],
        language: String,
        speaker: String?,
        sampling: SamplingConfig = .default,
        textFeed: TextFeed = .wholeText,
        instruct: String? = nil,
        checkCancellation: () throws -> Void = {}
    ) throws -> [[Float]] {
        let codes = try makeVoiceBatchCodes(
            texts: texts, language: language, speaker: speaker, sampling: sampling, textFeed: textFeed,
            instruct: instruct, checkCancellation: checkCancellation)
        // Turn each sentence's codes into audio.
        return try codes.map { codes in
            try checkCancellation()
            guard let codes else { return [] }
            return codecDecoder.decode(codes: codes)
        }
    }

    /// The codes `synthesizeVoiceBatch` turns into audio: each text's [1, 16, frames], or nil when the model made none.
    func makeVoiceBatchCodes(
        texts: [String],
        language: String,
        speaker: String?,
        sampling: SamplingConfig = .default,
        textFeed: TextFeed = .wholeText,
        instruct: String? = nil,
        checkCancellation: () throws -> Void = {}
    ) throws -> [MLXArray?] {
        guard !texts.isEmpty else { return [] }
        guard let tokenizer else { throw TTSError.tokenizerNotLoaded }
        try checkCancellation()

        let (speakerTokenId, effectiveLanguage) = resolveSpeaker(speaker, language: language, languageExplicit: true)
        guard let languageId = CodecTokens.languageId(for: effectiveLanguage) else {
            throw TTSError.unknownLanguage(effectiveLanguage)
        }
        let instructTokens = instruct.map { prepareInstructTokens(instruct: $0, tokenizer: tokenizer) }
        let codecPrefix = buildCodecPrefix(languageId: languageId, speakerTokenId: speakerTokenId)

        var prompts: [MLXArray] = []
        var trailings: [MLXArray] = []
        var padEmbed: MLXArray?
        for text in texts {
            let textTokens = prepareTextTokens(text: text, tokenizer: tokenizer)
            switch textFeed {
            case .wholeText:
                let (prompt, pad) = buildWholeTextPrompt(
                    textTokens: textTokens, codecPrefixTokens: codecPrefix, instructTokens: instructTokens)
                prompts.append(prompt)
                padEmbed = pad
            case .tokenPerStep:
                // Every prompt is the same length up to the first word; the rest of each text is fed in a token per step.
                let (prefill, trailing, pad) = buildPrefillEmbeddings(
                    textTokens: textTokens, codecPrefixTokens: codecPrefix, instructTokens: instructTokens)
                prompts.append(prefill)
                trailings.append(trailing)
                padEmbed = pad
            }
        }
        guard let padEmbed else { return [] }
        let hiddenSize = config.talker.hiddenSize
        let longestTrailing = trailings.map { $0.dim(1) }.max() ?? 0
        // A text that has run out is fed the pad token, as the one-sentence path does.
        let trailing: MLXArray? = trailings.isEmpty ? nil : concatenated(trailings.map { item in
            let missing = longestTrailing - item.dim(1)
            return missing == 0 ? item : concatenated([item, broadcast(padEmbed, to: [1, missing, hiddenSize])], axis: 1)
        }, axis: 0)  // [B, longestTrailing, D]
        // As in the one-sentence path: the text's own cap, and never more than 2048 frames.
        let caps = texts.map { min(maxTokenCap(for: [$0], tokenizer: tokenizer, sampling: sampling), 2048) }

        // Prefill all prompts at once.
        var (logits, hidden, cache, padding) = prefillPadded(prompts)
        let promptLength = prompts.map { $0.dim(1) }.max() ?? 0
        logits = logits[0..., (promptLength - 1)..<promptLength, 0...]
        hidden = hidden[0..., (promptLength - 1)..<promptLength, 0...]
        var batch = VoiceBatchState(
            rows: Array(texts.indices),
            trailing: trailing,
            seen: MLXArray.zeros([texts.count, config.talker.codecVocabSize], type: Bool.self),
            padding: padding,
            shift: padding)
        batch.cache = cache
        var frames = [[Int32]](repeating: [], count: texts.count)
        try checkCancellation()

        var trailingIndex = 0
        var position = promptLength
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

            // Next step's input: the next token of each text (or the pad token, once it's all in) plus this frame's
            // codes.
            let textEmbed: MLXArray
            if let trailing = batch.trailing, trailingIndex < longestTrailing {
                textEmbed = trailing[0..., trailingIndex..<(trailingIndex + 1), 0...]
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

            (logits, hidden, cache) = executeTalkerStepBatch(
                embeds: stepEmbeds, offset: position, cache: batch.cache, padding: batch.padding, shift: batch.shift)
            batch.cache = cache
            position += 1
        }

        return frames.map { codes in
            let count = codes.count / codeGroups
            guard count > 0 else { return nil }
            return MLXArray(codes).reshaped(count, codeGroups).transposed(1, 0).expandedDimensions(axis: 0)  // [1, 16, T]
        }
    }

    /// The prompt with the whole text in it, as Qwen's `generate` builds it with `non_streaming_mode`:
    /// `[instruct?, <|im_start|>assistant\n, codec prefix (all but its last token) under tts_pad… tts_bos,
    /// every text token and tts_eos each over codec_pad, tts_pad over codec_bos]`. Returns it and the tts_pad
    /// embedding, which every step after it adds.
    func buildWholeTextPrompt(
        textTokens: [Int], codecPrefixTokens: [Int32], instructTokens: [Int]?
    ) -> (prompt: MLXArray, ttsPadEmbed: MLXArray) {
        let hiddenSize = config.talker.hiddenSize
        let textEmbeds = talker.embedText(MLXArray(textTokens.map { Int32($0) }).expandedDimensions(axis: 0))
        let codecEmbeds = talker.embedCodec(MLXArray(codecPrefixTokens).expandedDimensions(axis: 0))
        let codecLength = codecEmbeds.dim(1)
        func special(_ token: Int) -> MLXArray {
            talker.embedText(MLXArray([Int32(token)]).expandedDimensions(axis: 0))  // [1, 1, D]
        }
        let ttsPad = special(CodecTokens.ttsPad)
        let ttsBos = special(CodecTokens.ttsBos)
        let ttsEos = special(CodecTokens.ttsEos)
        func codec(_ token: Int, count: Int) -> MLXArray {
            talker.embedCodec(MLXArray([Int32](repeating: Int32(token), count: count)).expandedDimensions(axis: 0))
        }

        // <|im_start|>assistant\n
        let role = textEmbeds[0..., 0..<3, 0...]
        // The codec prefix but its last token (codec_bos), under tts_pad and then tts_bos.
        let overlay = concatenated([broadcast(ttsPad, to: [1, codecLength - 2, hiddenSize]), ttsBos], axis: 1)
        let prefix = overlay + codecEmbeds[0..., 0..<(codecLength - 1), 0...]
        // The text: everything between the role and the closing `<|im_end|>\n<|im_start|>assistant\n`.
        let textEnd = max(textTokens.count - 5, 3)
        let body = concatenated([textEmbeds[0..., 3..<textEnd, 0...], ttsEos], axis: 1)
        let text = body + codec(CodecTokens.codecPad, count: body.dim(1))
        let start = ttsPad + codec(CodecTokens.codecBos, count: 1)

        var parts = [role, prefix, text, start]
        if let instructTokens {
            parts.insert(talker.embedText(MLXArray(instructTokens.map { Int32($0) }).expandedDimensions(axis: 0)), at: 0)
        }
        return (concatenated(parts, axis: 1), ttsPad)
    }

    /// Runs `prompts` through the talker together. Shorter ones are padded at the front, so every prompt ends at the
    /// same step and the rows step together; attention never looks at the padding, and each row's positions start at 0
    /// as they do alone (a row shifted along by its padding came out noticeably different a step later). Returns the
    /// talker's outputs for every position and how much padding each row has.
    func prefillPadded(_ prompts: [MLXArray]) -> (
        logits: MLXArray, hidden: MLXArray, cache: [(MLXArray, MLXArray)], padding: [Int]
    ) {
        let hiddenSize = config.talker.hiddenSize
        let length = prompts.map { $0.dim(1) }.max() ?? 0
        let padding = prompts.map { length - $0.dim(1) }
        let embeds = concatenated(prompts.map { prompt in
            let missing = length - prompt.dim(1)
            guard missing > 0 else { return prompt }
            return concatenated([MLXArray.zeros([1, missing, hiddenSize]).asType(prompt.dtype), prompt], axis: 1)
        }, axis: 0)  // [B, length, D]
        guard padding.contains(where: { $0 > 0 }) else {
            let (logits, hidden, cache) = talker(inputsEmbeds: embeds, offset: MLXArray(Int32(0)), cache: nil)
            return (logits, hidden, cache, padding)
        }
        let (logits, hidden, cache) = talker(
            inputsEmbeds: embeds,
            offset: MLXArray(padding.map { Int32(-$0) }),
            attentionMask: Self.paddedCausalMask(padding: padding, length: length, dtype: embeds.dtype),
            cache: nil)
        return (logits, hidden, cache, padding)
    }

    /// A causal mask for prompts padded at the front: row `b` sees neither later positions nor its first
    /// `padding[b]`. [B, 1, length, length].
    static func paddedCausalMask(padding: [Int], length: Int, dtype: DType) -> MLXArray {
        let positions = MLXArray(0..<Int32(length))
        let later = positions.reshaped(1, 1, length) .> positions.reshaped(1, length, 1)  // [1, L, L]
        let padded = positions.reshaped(1, 1, length) .< MLXArray(padding.map(Int32.init)).reshaped(-1, 1, 1)  // [B, 1, L]
        return MLX.where(logicalOr(later, padded), MLXArray(Float(-1e9)), MLXArray(Float(0)))
            .expandedDimensions(axis: 1).asType(dtype)
    }

    /// For one step after the prompt: row `b` doesn't see its first `padding[b]` keys. [B, heads, 1, keys], the full
    /// shape of the attention scores: MLX's attention broadcasts a smaller mask to the shape the compiled step was traced
    /// with, which is a key short by the next step.
    static func paddingMask(padding: [Int], heads: Int, keys: Int, dtype: DType) -> MLXArray {
        let positions = MLXArray(0..<Int32(keys)).reshaped(1, 1, 1, keys)
        let padded = positions .< MLXArray(padding.map(Int32.init)).reshaped(-1, 1, 1, 1)
        let mask = MLX.where(padded, MLXArray(Float(-1e9)), MLXArray(Float(0))).asType(dtype)
        return broadcast(mask, to: [padding.count, heads, 1, keys])
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
    /// same step: they started together. `padding` is how many keys at the start of each row's cache to skip, and
    /// `shift` how far back each row's position is from `offset` (its prompt's padding; see `prefillPadded`).
    func executeTalkerStepBatch(
        embeds: MLXArray, offset: Int, cache: [(MLXArray, MLXArray)], padding: [Int] = [], shift: [Int] = []
    ) -> (MLXArray, MLXArray, [(MLXArray, MLXArray)]) {
        let rows = embeds.dim(0)
        let masked = padding.contains { $0 > 0 }
        let positions = shift.isEmpty ? [Int](repeating: offset, count: rows) : shift.map { offset - $0 }
        guard rows > 1 || masked else { return executeTalkerStep(embeds: embeds, offset: positions[0], cache: cache) }
        // One position per row: given a single position, the fused RoPE kernel moves only the first row there and
        // leaves the others at the start, so they never come to an end.
        let offsets = MLXArray(positions.map(Int32.init))
        let layers = config.talker.numLayers
        // The cache comes after the embeddings, the positions and (when masked) the mask.
        let cacheStart = masked ? 3 : 2
        let compiled: ([MLXArray]) -> [MLXArray]
        if let cached = masked ? compiledMaskedBatchTalkerSteps[rows] : compiledBatchTalkerSteps[rows] {
            compiled = cached
        } else {
            let talker = talker
            compiled = compile(inputs: [talker], outputs: [talker], shapeless: true) { inputs in
                var cache: [(MLXArray, MLXArray)] = []
                for layer in 0..<layers {
                    let key: Int = cacheStart + layer * 2
                    cache.append((inputs[key], inputs[key + 1]))
                }
                let (logits, hidden, newCache) = talker(
                    inputsEmbeds: inputs[0], offset: inputs[1], attentionMask: masked ? inputs[2] : nil, cache: cache)
                return [logits, hidden] + newCache.flatMap { [$0.0, $0.1] }
            }
            if masked {
                compiledMaskedBatchTalkerSteps[rows] = compiled
            } else {
                compiledBatchTalkerSteps[rows] = compiled
            }
        }
        var inputs = [embeds, offsets]
        if masked {
            let keys = (cache.first?.0.dim(2) ?? 0) + embeds.dim(1)
            inputs.append(Self.paddingMask(padding: padding, heads: config.talker.numHeads, keys: keys, dtype: embeds.dtype))
        }
        let out = compiled(inputs + cache.flatMap { [$0.0, $0.1] })
        // Typed one step at a time: with MLXArray's arithmetic in play, Swift 6.3 couldn't work out `$0 * 2` in time.
        var newCache: [(MLXArray, MLXArray)] = []
        for layer in 0..<layers {
            let first: Int = 2 + layer * 2
            newCache.append((out[first], out[first + 1]))
        }
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
    /// The text still to feed each row, a token a step (nil when the whole text was in the prompt).
    var trailing: MLXArray?
    /// Tokens each row has made, for the repetition penalty: [B, vocab].
    var seen: MLXArray
    /// How many positions at the start of each row's cache are padding, which attention must skip.
    var padding: [Int]
    /// How far back each row's position is from the step's (its prompt's padding). Unlike `padding`, it stays as it
    /// is when padding is dropped from the cache.
    var shift: [Int]
    var cache: [(MLXArray, MLXArray)] = []

    /// Keeps only the rows at `kept` (`indices` is the same, as an array).
    mutating func keep(_ kept: [Int], indices: MLXArray) {
        rows = kept.map { rows[$0] }
        padding = kept.map { padding[$0] }
        shift = kept.map { shift[$0] }
        guard !kept.isEmpty else { return }
        trailing = trailing?[indices]
        seen = seen[indices]
        cache = cache.map { ($0.0[indices], $0.1[indices]) }
        // Padding every row left has is dropped from the cache, so the last row left needs no mask. Positions are
        // kept as they were: RoPE only cares how far apart two positions are.
        let shared = padding.min() ?? 0
        if shared > 0 {
            cache = cache.map { ($0.0[0..., 0..., shared..., 0...], $0.1[0..., 0..., shared..., 0...]) }
            padding = padding.map { $0 - shared }
        }
    }
}

