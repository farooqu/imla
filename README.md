# Imla

*Imlāʾ* (إملاء) is Arabic for dictation.

A menu bar dictation app for this Mac. Press a hotkey, talk, and the text lands in whatever field has focus: Slack, a browser, an editor.

Everything runs inside Imla on Metal: speech recognition is NVIDIA's Nemotron Speech Streaming English 0.6B through NeMo-Speech.cpp, and cleanup is "S1-mini" by "Superwhisper" through llama.cpp. Cleanup can use a model in Ollama instead.

## Use

- **⌃⌥Space** (change it in Settings): tap to start, tap again to finish. Or hold it while you talk and let go.
- **Esc** cancels without typing anything.
- Dictation starts only in a text field. Apps that don't report what has focus, such as Chrome, are allowed.
- A small pill under the caret shows what's happening by colour: gray bars follow your voice while listening, blue while transcribing, purple while cleaning up, green when done. Words appear only for errors.
- The menu bar icon has Settings, the LLM toggle, and **Recent Dictations** (click one to copy it).

## How a dictation flows

1. Microphone audio is converted to 16 kHz mono and decoded by Nemotron as you speak, so recognition is nearly done when you stop (the final transcript is ready about 30 ms later).
2. Every vocabulary term biases Nemotron's decoder toward it (native RNNT phrase boosting).
3. Rule-based cleanup replaces "sounds like" spellings with their terms and drops fillers (um, uh) and immediately repeated words.
4. With **Polish with LLM** on, the cleanup model removes remaining fillers, keeps only the corrected version when you backtrack ("Friday, actually make that Thursday"), turns "new paragraph" into a break, and adds punctuation. The built-in S1-mini takes about 50 ms for a typical dictation; it writes numbers as digits and may add paragraph breaks to long dictations. With Ollama, the vocabulary is also sent as a glossary, and Imla warms the model when you start talking. If cleanup fails or returns something that isn't a cleanup (such as an answer to a question you dictated), the rule-cleaned text is used.
5. The text is pasted into the field that was focused when you started, even if focus moved while you talked; your clipboard is restored afterwards. If Imla can't get back to that field, it doesn't paste anywhere else: the text stays on the clipboard and in Recent Dictations.

The last 20 dictations are kept in `~/Library/Application Support/Imla/history.json`.

## Speech model

The model lives in NeMo-Speech.cpp's shared cache, not inside Imla:

```
~/Library/Caches/NeMoSpeech/models/nvidia/nemotron-speech-streaming-en-0.6b/<revision>/nemotron-speech-streaming-en-0.6b.q8_0.spm.gguf
```

(`$NEMO_SPEECH_MODEL_DIR` moves it.) NVIDIA's published GGUF lacks the tokenizer hotword boosting needs, so Imla adds the original tokenizer to it; that's the `.spm.gguf`. The weights are memory-mapped, so any other process using the same file (the voice stack's Nemotron server, say) shares one copy of them. If the file is missing, Settings offers to download the published model (700 MB) and the tokenizer from Hugging Face and build it; the result is checked against a pinned SHA-256.

## Cleanup model

The built-in cleanup model is "S1-mini" by "Superwhisper" (0.6B, Q4_K_M, 484 MB), a Qwen3-0.6B fine-tune trained only to clean up dictation. It lives in the Hugging Face hub cache, where llama.cpp and the Hugging Face tools also look:

```
~/.cache/huggingface/hub/models--superwhisper--s1-mini-GGUF/snapshots/<revision>/s1-mini-q4_k_m.gguf
```

(`$HF_HUB_CACHE` or `$HF_HOME` moves it.) If it's missing, Settings offers to download it; the file is checked against a pinned SHA-256. It runs with a 2K-token context, about 650 words per pass, which keeps it to about 820 MB of memory; longer dictations are cleaned a few sentences at a time, so a backtrack that spans two passes stays as spoken. A part the model can't clean, or that it doesn't finish, stays rule-cleaned. S1-mini follows its own trained prompt, so it doesn't see the vocabulary; terms reach it already corrected by recognition and the rules. Its license (Apache 2.0 with a naming clause) requires calling it "S1-mini" by "Superwhisper".

## Vocabulary

Settings → Vocabulary, or edit `~/Library/Application Support/Imla/config.json`:

```json
{ "term": "Kubernetes", "soundsLike": ["cooper netties"] }
```

- Every term biases the decoder toward it while you speak.
- **Sounds like** lists what recognition writes instead. Each is replaced with the term as a whole word, ignoring case.
- With Ollama cleanup, every term is given to the model as a glossary.

Settings → History shows what was heard next to what was typed, which is the quickest way to spot new misrecognitions to add.

## Build

```sh
./scripts/build-app.sh   # builds the runtime if needed, then builds, signs, installs ~/Applications/Imla.app
./scripts/test.sh        # unit tests
uv run --with pillow scripts/make-icon.py   # rebuilds Resources/AppIcon.icns from AppIcon-source.png
```

`scripts/build-runtime.sh` builds the pinned NeMo-Speech.cpp ASR library (the same commit as the voice stack) and libllama from its llama.cpp submodule, so both share one ggml, into `.runtime/lib`; the app bundles it in `Contents/Frameworks`. It needs CMake, Git, and uv. The scripts use the Command Line Tools toolchain, so they work without accepting the Xcode license. The app is signed with your Apple Development certificate so macOS keeps the Microphone and Accessibility grants across rebuilds.

On first launch, grant **Microphone** and **Accessibility** (needed to paste). Without Accessibility, dictations are copied to the clipboard instead.
