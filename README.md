# Blah

![Blah: hold the key, speak while the particle orb appears, then release to insert the transcript into your app.](Artwork/readme/banner.png)

A small native Swift dictation app for macOS 27, inspired by [Hex](https://github.com/kitlangton/Hex). Hold a key, speak, and paste the transcript into your app. Transcription and optional formatting run locally. This is a source-only project: build and sign your own copy.

> [!WARNING]
> This application was built entirely with gpt-6-astra. Use it at your own risk.

## Use

- Hold your dictation key to record. Release to transcribe and paste.
- Double-tap to record hands-free. Tap again to finish. Escape cancels.
- Left-click the menu bar icon to paste the last transcription or quit. Right-click for Settings.
- In General, click your dictation key and press a replacement. Letters, numbers, and standalone modifiers work too. Choose models, formatting, orb position, and launch at login there.
- Arrange microphones by priority. Blah uses the first available one, remembers disconnected microphones, and adds new ones at the bottom.
- Add word or phrase corrections in Replacements, with Match case and Whole words options for each rule. Rules run from top to bottom after formatting, including when formatting is off or fails.
- Browse, search, and copy previous dictations in Transcript History, including the original text before formatting.

Enable Microphone, Input Monitoring, and Accessibility when prompted. The default key is Globe / Fn. Set "Press Globe key to" to "Do Nothing" in macOS Keyboard settings. A plain key such as P is reserved for dictation when pressed alone; combinations such as Command-P still work. Escape cancels key selection, and Caps Lock cannot be used for hold-to-dictate.

If formatting fails, Blah uses the original transcript. If it cannot paste, the transcript stays on the clipboard.

## Models

In Settings → Models, filter by the language you speak, download a model, then choose Use. You can also select downloaded models in General.

| Model | Purpose | Languages | Download |
| --- | --- | --- | --- |
| Parakeet Unified English / v2 | Transcription | English | About 730 MB |
| Parakeet v3 | Transcription | 25, including English, French, and Russian | 740 MB |
| Whisper large-v3-turbo | Transcription | 100, including English, French, and Russian | 886 MB |
| Qwen3-ASR 0.6B | Transcription | 30, including English, French, and Russian | 850 MB |
| S1-mini by Superwhisper | Formatting | English only | 484 MB |
| Qwen3 4B | Experimental formatting | Multilingual, including English, French, and Russian | 2.5 GB |

Whisper and Qwen3-ASR let you choose the spoken language or detect it automatically. Parakeet v3 recognizes its supported languages automatically. For English spoken with a French or Russian accent, choose English. Language coverage does not guarantee accuracy for a particular accent; compare models on recordings from the people using them.

Qwen3 4B is a general language model prompted to clean up text while preserving its language. It may rephrase more than S1-mini. S1-mini is specialized for English; Blah skips it when text language detection confidently identifies another language. Select Off to keep the transcript without model formatting. Failed formatting keeps the original transcript.

The language lists follow the exact model versions: [Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), [Whisper](https://github.com/openai/whisper/blob/main/whisper/tokenizer.py), [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-0.6B), [S1-mini](https://huggingface.co/superwhisper/s1-mini), and [Qwen3](https://qwenlm.github.io/blog/qwen3/). The Models page shows each model's full language list and source.

Existing Hex models can be reused. The default folder is `~/Library/Application Support/voice-control/models`; choose another folder in Models if needed. Model weights are downloaded separately from the app. See [third-party notices](THIRD_PARTY_NOTICES.md) for the runtimes and model sources.

## History

Blah keeps the latest 2,000 transcripts. New entries replace the oldest when the limit is reached. Audio is not saved.

History is stored as JSONL at:

```text
~/Library/Application Support/Blah/history.jsonl
```

Use the file menu in Transcript History to open it or reveal it in Finder. You can edit entries or delete whole lines with a text editor. Save edits before dictating again.

## Build and sign

Requires an Apple silicon Mac, macOS 27, Xcode 27, CMake, Python 3, and OpenSSL available in your shell. Open Xcode once to finish its setup, then run from the cloned repository:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./scripts/run.sh
```

This builds, signs, installs into `/Applications/Blah.app`, and launches it. Use `./scripts/build.sh` to build and sign without installing. Run the installed copy: launching from the project folder can cause macOS to hide the app's menu bar icon. The first build downloads and compiles the native inference libraries; later builds reuse them.

Signing is automatic. The first build creates your own self-signed development certificate in a private keychain under `~/Library/Application Support/Blah/Signing`. Later builds reuse it so privacy permissions can survive updates. Keep that directory private and intact. No paid Apple Developer account or notarization is needed for this local build. The scripts do not change system certificate trust or your default keychain.

## License

[MIT](LICENSE). See [third-party notices](THIRD_PARTY_NOTICES.md) for dependencies and model licenses.

## Why can't I just download the binary?

Because I'm not paying Apple $100 a year for this shit. That's what Developer ID signing and notarization would cost, even for a free app. I could ship an unnotarized binary, but you'd still have to deal with macOS security warnings.

Once the build tools above are installed, run `./scripts/run.sh` and you have the app ready. You also get all the source code, so you can see what it does and change whatever you want.
