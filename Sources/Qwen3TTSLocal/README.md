# Qwen3TTSLocal

The Qwen3-TTS model code from [speech-swift](https://github.com/soniqo/speech-swift) 0.0.29
(`Sources/Qwen3TTS`, plus the parts of `Sources/MLXCommon` it uses, in `Common/`), under the Apache License 2.0
(`LICENSE`). The rest of speech-swift is still used as a package.

It is kept here so the Listen pane can make several sentences at once. The library's own `synthesizeBatch` makes
every sentence in a batch come out alike and leaves out the chosen voice, so `Qwen3TTS+VoiceBatch.swift` adds a
batched synthesis with the voice that matches the one-sentence path.

Changes from upstream:

- `import MLXCommon` removed; the `Common/` files are compiled into this module instead.
- `MetalBudget.pinMemory`/`unpinMemory` removed (they need `Cmlx`, which mlx-swift doesn't export as a product);
  the wired-memory "pin" policy does nothing here. The app never uses it.
- `Qwen3TTS+VoiceBatch.swift` added, and some `private` members of `Qwen3TTS.swift` made internal for it, with
  two new caches on `Qwen3TTSModel` for its compiled graphs.
- `CodePredictor.swift`: a batch gets one RoPE position per row (see below).
- `synthesizeVoiceBatch` puts each sentence's whole text in the prompt and sends no instruction, as Qwen's own
  `generate_custom_voice` does (see "How the text is fed" below). speech-swift's way is still there as
  `textFeed: .tokenPerStep` to compare against.
- `SpeechTokenizerDecoder.chunkedDecode` decodes 300 frames at a time after 25 frames of context, as Qwen's
  `chunked_decode` does, instead of 25 after 10, and pads each piece's end (see "Decoding" below).

Why the library's batching went wrong, found by comparing each row of a batch with the same sentence made alone:

1. The compiled talker step is a shapeless graph traced with one row; given four rows it returns one. Each batch
   size now gets its own compiled graph (`executeTalkerStepBatch`).
2. MLX's one-step RoPE kernel (`rope_single`, used when there is one position and one new token) only turns the
   first row of a batch. The other rows stayed at position 0, so they never came to an end and ran to their length
   cap. Passing one position per row takes MLX's general kernel instead (talker and code predictor).

`ListenBenchmarkTests.testMakingSeveralAtOnceIsFasterAndSoundsTheSame` checks both with the real model.

How the text is fed, checked against Qwen's `qwen_tts` code
(`qwen_tts/inference/qwen3_tts_model.py`, `qwen_tts/core/models/modeling_qwen3_tts.py`):

1. Qwen's `generate_custom_voice` defaults to `non_streaming_mode=True`: the whole text is in the prompt, each token
   over `codec_pad`, before the first frame of speech. speech-swift used the model's simulated streaming input
   instead, one text token per frame after the first, so the voice only knew the word it was on and the next and
   read word by word, with odd pauses and a tone that wandered from sentence to sentence.
2. Qwen's code drops the instruction for the 0.6B models (`if self.model.tts_model_size in "0b6": instruct = None`),
   which weren't trained with one. speech-swift always sent "Speak naturally." to the built-in voices.

Whole texts make prompts of different lengths, so a batch pads the shorter ones at the front (`prefillPadded`),
masks the padding out of attention, and starts each row's RoPE positions at 0 as they are alone: shifted along by
its padding instead, a row came out noticeably different a step later. The step's mask has the full shape of the
attention scores, since MLX's attention broadcasts a smaller one to the shape the compiled step was traced with,
a key short by the next step. `ListenBenchmarkTests.testPaddedPromptsScoreAsTheyDoAlone` checks a padded batch
against each sentence alone and against the uncached result, and `testWholeSentencePromptsReadNaturally` writes
before and after clips to listen to.

Decoding: speech-swift decoded the codes 25 frames (2 s) at a time, each after 10 frames of context, and every piece
came out short, so about 0.1 s of speech went missing at every 2-second seam and the audio no longer matched a single
pass after it. Even a single pass came out a frame and a half short, clipping the last sound. Qwen's `chunked_decode`
defaults to 300 frames after 25, so most sentences go in one pass. Each piece is now padded at the end to a multiple of
25 frames, with at least two over: the decoder is causal, so this changes nothing before it, gives out the last frame's
last samples, and keeps to a few lengths for the compiled decoder. `ListenBenchmarkTests.testDecodingKeepsEverySample`
checks it with the real model.
