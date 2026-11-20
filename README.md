<p align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Imla icon: a reed pen writing past a sound wave">
</p>

<h1 align="center">Imla</h1>

<p align="center">
  <b>Dictation that keeps up with you.</b><br>
  Imla transcribes while you speak, so when you stop, the text is already there:<br>
  cleaned up and pasted in about a tenth of a second. Private and on-device, for macOS.
</p>

<p align="center">
  <a href="https://github.com/farooqu/imla/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/farooqu/imla?label=release&color=2f7d4f"></a>
  <img alt="macOS 26 or later" src="https://img.shields.io/badge/macOS-26%2B-555">
  <img alt="Apple silicon" src="https://img.shields.io/badge/Apple%20silicon-required-555">
</p>

*Imlāʾ* (إملاء) is Arabic for dictation: a scholar speaks, and the scribe writes down every word.

- **Instant:** speech recognition streams. Imla transcribes as you talk instead of after you stop, so the final words are ready about 30 ms after you finish, and cleanup adds about 50 ms.
- **Clean:** fillers, stutters, and self-corrections ("Friday, actually make that Thursday") are cleaned up before the text is pasted, and "new paragraph" starts one.
- **Your words:** a vocabulary of names and jargon steers recognition toward them and fixes the usual misspellings.
- **Back where you started:** the text goes into the field you were typing in when you started, even if something else took focus while you talked.
- **Private:** speech recognition (NVIDIA's Nemotron Speech Streaming English 0.6B) and cleanup ("S1-mini" by "Superwhisper") run on your Mac's GPU, so nothing you say leaves it. Cleanup can use a model in [Ollama](https://ollama.com) instead.

## Install

1. Download `Imla.dmg` from the [latest release](https://github.com/farooqu/imla/releases/latest), open it, and drag Imla onto the Applications folder next to it.
2. Open Imla. The first time, macOS refuses: it says Apple could not verify that Imla is free of malware, and offers to move it to the Trash. That's expected; see [First launch](#first-launch) below.
3. The welcome window walks you through setup, saying what each step is for before macOS asks:
   - **Microphone**, to hear you while you dictate.
   - **Device Control and Data Access** (called **Accessibility** on macOS 26), in System Settings → Privacy & Security. It lets Imla find the field your cursor is in and paste there. macOS describes everything this permission could allow; Imla uses it only to paste.
   - **Models**: download the speech and cleanup models (about 1.2 GB together).

Imla checks for updates daily, downloads them in the background, and restarts into the new version as soon as you're not dictating; **Check for Updates…** in the menu checks now.

### First launch

Apple checks apps from outside the App Store for malware ("notarization") only when their developer pays for an Apple Developer account. Imla isn't notarized, so the first time you open it, macOS shows a warning that Apple could not verify Imla is free of malware, with **Done** and **Move to Trash** buttons. Imla is signed, but by its own certificate rather than one from Apple. To open it anyway:

1. Click **Done**, not Move to Trash.
2. Open **System Settings → Privacy & Security** and scroll down to **Security**. There's a message that Imla was blocked; click **Open Anyway** next to it and enter your password.
3. Open Imla again and click **Open Anyway** once more in the dialog that appears.

macOS remembers this, and updates don't ask again: Sparkle installs them without the quarantine flag that a browser download gets. If you'd rather use Terminal, `xattr -dr com.apple.quarantine /Applications/Imla.app` does the same before the first launch.

## Use

| Key | What it does |
|---|---|
| **⌃⌥Space** | Tap to start and tap again to finish, or hold it while you talk. Change it in Settings. |
| **Esc** | Cancel without typing anything. |
| **Menu bar icon** | Settings, the LLM toggle, and **Recent Dictations** (click one to copy it). |

Click into a text field before you start: Imla won't start without one. Apps that don't report what has focus, such as Chrome, are allowed.

A small pill under the caret shows what's happening by colour: gray bars follow your voice while you speak, blue while transcribing, purple while cleaning up, green when done. Turn on **Show live transcript** in Settings to see the words scroll by instead of the bars while you speak. Otherwise, words appear in the pill only when something needs your attention.

### Where your text goes

Imla remembers the field your cursor was in when you started, and pastes the text there when you're done, even if you switched apps or a notification took focus while you talked. Your clipboard is put back the way it was afterwards.

If Imla can't paste, the text is never lost or typed into the wrong place:

- **It can't get back to that field**, for example because you closed the window: the text is on the clipboard, ready for ⌘V, and the pill says so.
- **Device Control and Data Access (Accessibility) isn't allowed:** Imla can't paste into other apps, so every dictation goes to the clipboard instead.
- **Either way,** the last 20 dictations are in **Recent Dictations** in the menu and in **Settings → History**, which also shows what was heard and how quickly the text was ready.

## Vocabulary

Add names, jargon, and abbreviations in Settings → Vocabulary, or in `~/Library/Application Support/Imla/config.json`:

```json
{ "term": "Kubernetes", "soundsLike": ["cooper netties"] }
```

- Every term biases the decoder toward it while you speak.
- **Sounds like** lists what recognition writes instead. Each is replaced with the term as a whole word, ignoring case.
- With Ollama cleanup, every term is given to the model as a glossary.

Settings → History shows what was heard next to what was typed, which is the quickest way to spot misrecognitions to add.

## Resource usage

Measured on an M4 Max with both built-in models loaded:

| | Measured |
|---|---|
| Download | App 6 MB; speech model 700 MB; cleanup model 484 MB |
| Memory | About 950 MB resident, of which about 400 MB is Imla's own; the rest is the memory-mapped model files, which macOS can page out and which other apps using the same files share |
| Speed | Final transcript about 30 ms after you stop; cleanup about 50 ms for a typical dictation; an 850-word dictation about 3 s |

Turning off **Polish with LLM**, or using Ollama for cleanup, unloads S1-mini.

## How it works

1. Microphone audio is converted to 16 kHz mono and decoded by Nemotron as you speak, so recognition is nearly done when you stop.
2. Every vocabulary term biases Nemotron's decoder toward it (RNNT phrase boosting).
3. Rule-based cleanup replaces "sounds like" spellings with their terms and drops fillers (um, uh) and immediately repeated words.
4. With **Polish with LLM** on, the cleanup model removes remaining fillers, keeps only the corrected version when you backtrack ("Friday, actually make that Thursday"), turns "new paragraph" into a break, and adds punctuation. S1-mini writes numbers as digits and may add paragraph breaks to long dictations. Its **Style** setting picks the register, from Casual (all lowercase) to Formal (no contractions), and dictations into Mail or Outlook get email layout: a greeting and sign-off you say go on their own lines. History shows which style each dictation used. With Ollama, the vocabulary is also sent as a glossary, and Imla warms the model when you start talking. If cleanup fails or returns something that isn't a cleanup (such as an answer to a question you dictated), the rule-cleaned text is used.
5. The text is pasted where you started; see [Where your text goes](#where-your-text-goes).

### Speech model

The model lives in NeMo-Speech.cpp's shared cache, not inside Imla:

```
~/Library/Caches/NeMoSpeech/models/nvidia/nemotron-speech-streaming-en-0.6b/<revision>/nemotron-speech-streaming-en-0.6b.q8_0.spm.gguf
```

`$NEMO_SPEECH_MODEL_DIR` moves it. NVIDIA's published GGUF lacks the tokenizer that phrase boosting needs, so Imla adds the original tokenizer to it; that's the `.spm.gguf`. The weights are memory-mapped, so another process using the same file shares one copy of them. Settings downloads the published model and tokenizer from Hugging Face and builds the file; the result is checked against a pinned SHA-256.

### Cleanup model

The built-in cleanup model is "S1-mini" by "Superwhisper" (0.6B, Q4_K_M), a Qwen3-0.6B fine-tune trained only to clean up dictation. It lives in the Hugging Face hub cache, where llama.cpp and the Hugging Face tools also look:

```
~/.cache/huggingface/hub/models--superwhisper--s1-mini-GGUF/snapshots/<revision>/s1-mini-q4_k_m.gguf
```

`$HF_HUB_CACHE` or `$HF_HOME` moves it. The download is checked against a pinned SHA-256. It runs with a 2K-token context, about 650 words per pass; longer dictations are cleaned a few sentences at a time, so a backtrack that spans two passes stays as spoken. A part the model can't clean, or doesn't finish, stays rule-cleaned. S1-mini follows its own trained prompt, so it doesn't see the vocabulary; terms reach it already corrected by recognition and the rules. Its license (Apache 2.0 with a naming clause) requires calling it "S1-mini" by "Superwhisper".

## Building from source

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for building, testing, and releasing.
