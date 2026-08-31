# RatRemote

RatRemote is a local macOS remote-control app with an optional inference server. The Mac handles Siri Remote input, pointer movement, screenshots, paste/key/click actions, and permissions; a trusted server can run transcription, command parsing, and vision inference.

RatRemote is fully standalone. Remote input is handled in-process using macOS HID/Bluetooth APIs; no companion app or external remote-control helper is required.

## Features

- Native macOS app with a control window and menu bar shortcut.
- Siri Remote support through macOS GameController and raw HID input.
- Siri-button push-to-talk using the microphone selected in RatRemote.
- Pointer movement and click dispatch on the Mac.
- Configurable default mode:
  - `Dictation`: record speech, transcribe, paste the text directly without calling the LLM. This is the default.
  - `Command`: record speech, transcribe, send transcript to LLM parser, execute returned actions.
  - `Vision`: record a target description, capture the screen, ask the vision backend for a normalized point, then click it.
- Agent hotkey mode always sends the transcribed request to the inference LLM. The LLM can return Mac tool actions such as `open_url`, `open_app`, `key_press`, `paste_text`, `scroll`, `swipe`, `click`, `close_window`, `quit_app`, `wait`, `run_applescript`, or `locate_and_click`.
- Automation Loop mode runs a bounded observe-plan-act loop: RatRemote captures the screen, asks `/automation/step` for one next action, executes it, waits, and repeats until done or the max step limit is reached.
- Automation and agent vision can be scoped to a selected app window from the window picker, so only that window screenshot is sent to the model and normalized vision coordinates map back into that window.
- `locate_and_click` bridges the inference LLM to the computer-use vision backend: the Mac captures a fresh screenshot, Moondream locates the named visible target, and RatRemote clicks the returned point.
- Social, dating, messaging, posting, purchase, delete, and script-like automation steps pause for approval before RatRemote runs the suggested action unless "Allow all approval prompts" is enabled.
- For context-aware UI requests like "click the search bar", the planner should use `locate_and_click`; if it has to navigate first, it can use `open_url`, `wait`, then `locate_and_click`.
- Apple on-device dictation by default using the macOS 26 `DictationTranscriber`/`SpeechAnalyzer` stack when available, with an older on-device `SFSpeechRecognizer` fallback.
- Separate configurable endpoints and API keys for transcription fallback, command inference, and computer-use vision.
- Selectable command-model providers: Automatic, remote server, managed local Gemma 4 E2B, or Apple's native on-device Intelligence model.
- One-time Gemma 4 E2B Q4_0 download and a managed `llama-server` lifecycle for command parsing without a network connection.
- Recordable local transcription hotkey and visible Siri Remote connection status.
- LAN inference server with faster-whisper, Ollama/OpenAI-compatible command parsing, and Moondream/OpenAI-compatible vision hooks.
- Keyboard fallback: `Control-Option-Space` toggles recording.

## Build the Mac app

```bash
chmod +x scripts/build_app.sh
./scripts/build_app.sh
open build/RatRemote.app
```

Builds use an ad-hoc signature by default so a developer identity is never selected or embedded automatically. Set `RATREMOTE_CODESIGN_IDENTITY` explicitly when producing a signed distribution build.

The app needs macOS Accessibility, Microphone, and Screen Recording permissions for the full workflow.
It also needs Speech Recognition permission for Apple on-device dictation.

Holding the Siri button starts and stops an agent-command recording from the microphone selected in RatRemote. macOS routes the Siri Remote's Bluetooth audio stream only to Apple-entitled system services, so RatRemote does not present that protected stream as a working input. Legacy virtual inputs named “Siri Remote Mic” are ignored because they do not receive audio samples.

## Offline command models

Open Settings and choose a provider under **Command Inference**:

- **Automatic** tries Apple Intelligence when available, then an installed local Gemma model, then the configured remote server.
- **Local Gemma 4 E2B** uses the smallest Gemma 4 family model. Click **Download Model** once while connected; the Q4_0 text model is approximately 2.84 GB.
- **Apple Intelligence** uses the native Foundation Models framework. It requires macOS 26 or later on an eligible Mac with Apple Intelligence enabled and its model ready.
- **Remote server** preserves the previous server-only command behavior.

The local model is deliberately limited to simple command actions. It cannot return AppleScript, raw coordinate clicks, or mouse movement. Vision targeting and the multi-step automation loop still use their configured remote services. If the app does not contain `llama-server`, click **Install llama.cpp Runtime** before going offline; RatRemote downloads the matching official macOS release from the llama.cpp GitHub project into its Application Support directory.

Gemma runs through `llama-server`. Development builds discover it in common Homebrew locations and on `PATH`. Release builds should bundle a known compatible helper:

```bash
RAT_LLAMA_SERVER=/absolute/path/to/llama-server ./scripts/build_app.sh
```

The build copies the helper into `RatRemote.app/Contents/MacOS` and signs it with the app. Use a self-contained helper built for every architecture supported by the release. The model itself is downloaded to `~/Library/Application Support/RatRemote/Models` and is not placed inside the app bundle.

Run the command safety and settings tests with the full Xcode toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

## Run the inference server

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export RAT_SERVER_API_KEY="$(openssl rand -hex 32)"
uvicorn rat_inference_server:app --host 127.0.0.1 --port 8787
```

Configure the app endpoints and enter the same API key in each enabled service:

- Transcription fallback URL: `http://127.0.0.1:8787`
- Command inference URL: `http://127.0.0.1:8787`
- Computer-use/Moondream URL: `http://127.0.0.1:8787`

For access from another machine, put the server behind an HTTPS reverse proxy, restrict it to trusted clients with a firewall, and keep API-key authentication enabled. Plain HTTP exposes recordings, screenshots, commands, and credentials to anyone able to observe the network.

## Useful server settings

```bash
export RAT_ASR_BACKEND=faster-whisper
export RAT_WHISPER_MODEL=large-v3-turbo
export RAT_WHISPER_DEVICE=cuda
export RAT_WHISPER_COMPUTE_TYPE=float16
# Optional: allow more simultaneous faster-whisper transcriptions per server process.
# Keep this at 1 unless your GPU/CPU has enough spare memory.
export RAT_WHISPER_CONCURRENCY=1

export RAT_LLM_BACKEND=ollama
export OLLAMA_HOST=http://127.0.0.1:11434
export RAT_OLLAMA_MODEL=qwen2.5:3b

export RAT_VISION_BACKEND=moondream
export RAT_MOONDREAM_MODEL=vikhyatk/moondream2
# Optional for Moondream Cloud or hosted finetunes:
# export RAT_MOONDREAM_API_KEY=...

export RAT_SERVER_API_KEY="replace-with-a-random-secret"
```

Current app builds upload audio to `/transcribe/audio` as raw audio bytes and pass the selected speech locale.
The older `/transcribe` JSON/base64 endpoint remains available for compatibility.
The `faster-whisper` backend keeps its model cached in the server process; `whispercpp` mode uses the configured CLI binary per request.

For OpenAI-compatible local servers, set:

```bash
export RAT_LLM_BACKEND=openai-compatible
export RAT_VISION_BACKEND=openai-compatible
export RAT_OPENAI_BASE_URL=http://127.0.0.1:8000/v1
export RAT_OPENAI_API_KEY=local
export RAT_OPENAI_MODEL=qwen
export RAT_VISION_MODEL=your-vision-model
# Optional: use a separate multimodal planner for /automation/step.
# export RAT_AUTOMATION_MODEL=your-vision-capable-model
```

If your command LLM is multimodal, enable "Include screen context" in the app. For text-only command models, leave it off; the LLM can still request `locate_and_click`, and the separate Moondream endpoint will handle visual targeting.

For smoke tests without models:

```bash
export RAT_ASR_BACKEND=mock
export RAT_MOCK_TRANSCRIPT="type hello from ratremote"
export RAT_LLM_BACKEND=mock
export RAT_VISION_BACKEND=mock
export RAT_SERVER_API_KEY="development-only-secret"
uvicorn rat_inference_server:app --host 127.0.0.1 --port 8787
```

See [SECURITY.md](SECURITY.md) for responsible disclosure and deployment guidance.

## License

RatRemote is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution information.
