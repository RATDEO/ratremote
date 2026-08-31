from __future__ import annotations

import base64
import binascii
import asyncio
import json
import os
import re
import secrets
import tempfile
import threading
from typing import Any

import requests
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field


app = FastAPI(title="RatRemote Inference Server")

MAX_BINARY_BYTES = 32 * 1024 * 1024
MAX_BASE64_CHARACTERS = 45 * 1024 * 1024
MAX_TEXT_CHARACTERS = 32 * 1024
MAX_CONTEXT_CHARACTERS = 256 * 1024


def require_api_key(
    authorization: str | None = Header(default=None),
    x_api_key: str | None = Header(default=None),
) -> None:
    expected = os.getenv("RAT_SERVER_API_KEY", "").strip()
    if not expected:
        raise HTTPException(status_code=503, detail="Server API key is not configured")

    bearer = None
    if authorization and authorization.lower().startswith("bearer "):
        bearer = authorization[7:].strip()

    supplied_keys = [key for key in (x_api_key, bearer) if key]
    if any(secrets.compare_digest(key, expected) for key in supplied_keys):
        return

    raise HTTPException(status_code=401, detail="Invalid or missing API key")


class TranscriptionRequest(BaseModel):
    audioBase64: str = Field(max_length=MAX_BASE64_CHARACTERS)
    mimeType: str = Field(default="audio/wav", max_length=128)
    language: str | None = Field(default=None, max_length=64)


class TranscriptionResponse(BaseModel):
    text: str


class CommandRequest(BaseModel):
    text: str = Field(max_length=MAX_TEXT_CHARACTERS)
    screenshotBase64: str | None = Field(default=None, max_length=MAX_BASE64_CHARACTERS)
    agentMode: bool = False
    screenContext: str | None = Field(default=None, max_length=MAX_CONTEXT_CHARACTERS)


class RemoteAction(BaseModel):
    type: str
    text: str | None = None
    key: str | None = None
    modifiers: list[str] | None = None
    url: str | None = None
    x: float | None = None
    y: float | None = None
    amount: float | None = None


class CommandResponse(BaseModel):
    actions: list[RemoteAction] = Field(default_factory=list)
    spokenSummary: str | None = None


class AutomationStepRequest(BaseModel):
    instruction: str = Field(max_length=MAX_TEXT_CHARACTERS)
    screenshotBase64: str | None = Field(default=None, max_length=MAX_BASE64_CHARACTERS)
    screenContext: str | None = Field(default=None, max_length=MAX_CONTEXT_CHARACTERS)
    stepIndex: int = Field(default=1, ge=1, le=100)
    maxSteps: int = Field(default=12, ge=1, le=100)
    lastActionSummary: str | None = Field(default=None, max_length=MAX_TEXT_CHARACTERS)


class AutomationStepResponse(BaseModel):
    actions: list[RemoteAction] = Field(default_factory=list)
    spokenSummary: str | None = None
    criteriaSummary: str | None = None
    shouldContinue: bool = False
    requiresApproval: bool = False
    safetyNote: str | None = None


class VisionRequest(BaseModel):
    prompt: str = Field(max_length=MAX_TEXT_CHARACTERS)
    imageBase64: str = Field(max_length=MAX_BASE64_CHARACTERS)


class VisionResponse(BaseModel):
    x: float
    y: float
    confidence: float | None = None
    label: str | None = None


def _decode_base64(value: str, payload_name: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise HTTPException(status_code=422, detail=f"Invalid {payload_name} encoding") from exc
    if len(decoded) > MAX_BINARY_BYTES:
        raise HTTPException(status_code=413, detail=f"{payload_name.capitalize()} payload is too large")
    return decoded


@app.get("/health", dependencies=[Depends(require_api_key)])
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "asr": os.getenv("RAT_ASR_BACKEND", "faster-whisper"),
        "llm": os.getenv("RAT_LLM_BACKEND", "ollama"),
        "vision": os.getenv("RAT_VISION_BACKEND", "moondream"),
    }


@app.post("/transcribe", dependencies=[Depends(require_api_key)])
def transcribe(request: TranscriptionRequest) -> TranscriptionResponse:
    backend = os.getenv("RAT_ASR_BACKEND", "faster-whisper")
    audio = _decode_base64(request.audioBase64, "audio")

    if backend == "mock":
        return TranscriptionResponse(text=os.getenv("RAT_MOCK_TRANSCRIPT", ""))

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as handle:
        handle.write(audio)
        path = handle.name

    try:
        if backend == "whispercpp":
            return TranscriptionResponse(text=_transcribe_whispercpp(path, request.language))
        return TranscriptionResponse(text=_transcribe_faster_whisper(path, request.language))
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


@app.post("/transcribe/audio", dependencies=[Depends(require_api_key)])
async def transcribe_audio(
    request: Request,
    language: str | None = Query(default=None),
) -> TranscriptionResponse:
    backend = os.getenv("RAT_ASR_BACKEND", "faster-whisper")
    if backend == "mock":
        return TranscriptionResponse(text=os.getenv("RAT_MOCK_TRANSCRIPT", ""))

    suffix = _audio_suffix(request.headers.get("content-type"))
    content_length = request.headers.get("content-length")
    if content_length and (not content_length.isdigit() or int(content_length) > MAX_BINARY_BYTES):
        raise HTTPException(status_code=413, detail="Audio payload is too large")

    path: str | None = None
    try:
        received = 0
        with tempfile.NamedTemporaryFile(suffix=suffix, delete=False) as handle:
            path = handle.name
            async for chunk in request.stream():
                received += len(chunk)
                if received > MAX_BINARY_BYTES:
                    raise HTTPException(status_code=413, detail="Audio payload is too large")
                handle.write(chunk)
        if backend == "whispercpp":
            text = await asyncio.to_thread(_transcribe_whispercpp, path, language)
        else:
            text = await asyncio.to_thread(_transcribe_faster_whisper, path, language)
        return TranscriptionResponse(text=text)
    finally:
        if path:
            _remove_file(path)


@app.post("/command", dependencies=[Depends(require_api_key)])
def command(request: CommandRequest) -> CommandResponse:
    actions = [] if request.agentMode else _cheap_command_parse(request.text)
    if actions:
        return CommandResponse(actions=actions, spokenSummary="local rule")

    backend = os.getenv("RAT_LLM_BACKEND", "ollama")
    if backend == "mock":
        response = CommandResponse(actions=[], spokenSummary="mock")
    elif backend == "openai-compatible":
        response = _command_openai_compatible(request)
    else:
        response = _command_ollama(request)
    if request.agentMode:
        response.actions = _repair_agent_actions(request.text, response.actions)
    return response


@app.post("/automation/step", dependencies=[Depends(require_api_key)])
def automation_step(request: AutomationStepRequest) -> AutomationStepResponse:
    backend = os.getenv("RAT_LLM_BACKEND", "ollama")
    if backend == "mock":
        response = AutomationStepResponse(
            actions=[],
            spokenSummary="mock automation step",
            shouldContinue=False,
        )
    elif backend == "openai-compatible":
        response = _automation_openai_compatible(request)
    else:
        response = _automation_ollama(request)
    return _guard_automation_response(request, response)


@app.post("/vision/locate", dependencies=[Depends(require_api_key)])
def vision_locate(request: VisionRequest) -> VisionResponse:
    backend = os.getenv("RAT_VISION_BACKEND", "moondream")
    if backend == "mock":
        return VisionResponse(x=0.5, y=0.5, confidence=0.1, label="mock center")
    if backend == "openai-compatible":
        return _vision_openai_compatible(request)
    return _vision_moondream(request)


def _transcribe_faster_whisper(path: str, language: str | None) -> str:
    try:
        from faster_whisper import WhisperModel
    except ImportError as exc:
        raise HTTPException(status_code=500, detail="Install faster-whisper or set RAT_ASR_BACKEND=whispercpp/mock") from exc

    model_name = os.getenv("RAT_WHISPER_MODEL", "large-v3-turbo")
    device = os.getenv("RAT_WHISPER_DEVICE", "auto")
    compute_type = os.getenv("RAT_WHISPER_COMPUTE_TYPE", "auto")
    model, transcribe_lock = _cached_whisper_model(model_name, device, compute_type)
    language = _whisper_language(language)
    with transcribe_lock:
        segments, _ = model.transcribe(path, language=language, vad_filter=True)
    return " ".join(segment.text.strip() for segment in segments).strip()


_WHISPER_CACHE: dict[tuple[str, str, str], tuple[Any, threading.Semaphore]] = {}
_WHISPER_CACHE_LOCK = threading.Lock()


def _cached_whisper_model(model_name: str, device: str, compute_type: str) -> tuple[Any, threading.Semaphore]:
    key = (model_name, device, compute_type)
    with _WHISPER_CACHE_LOCK:
        if key not in _WHISPER_CACHE:
            from faster_whisper import WhisperModel

            concurrency = _positive_int_env("RAT_WHISPER_CONCURRENCY", 1)
            _WHISPER_CACHE[key] = (
                WhisperModel(model_name, device=device, compute_type=compute_type),
                threading.Semaphore(concurrency),
            )
    return _WHISPER_CACHE[key]


def _transcribe_whispercpp(path: str, language: str | None) -> str:
    import subprocess

    binary = os.environ["RAT_WHISPERCPP_BIN"]
    model = os.environ["RAT_WHISPERCPP_MODEL"]
    cmd = [binary, "-m", model, "-f", path, "-otxt"]
    language = _whisper_language(language)
    if language:
        cmd.extend(["-l", language])
    out_path = path + ".txt"
    try:
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        with open(out_path, "r", encoding="utf-8") as handle:
            return handle.read().strip()
    finally:
        _remove_file(out_path)


def _audio_suffix(content_type: str | None) -> str:
    content_type = (content_type or "").split(";", maxsplit=1)[0].strip().lower()
    suffixes = {
        "audio/aiff": ".aiff",
        "audio/aifc": ".aifc",
        "audio/caf": ".caf",
        "audio/mp4": ".m4a",
        "audio/mpeg": ".mp3",
        "audio/wav": ".wav",
        "audio/x-wav": ".wav",
    }
    return suffixes.get(content_type, ".wav")


def _whisper_language(language: str | None) -> str | None:
    language = (language or "").strip()
    if not language:
        return None
    return language.replace("_", "-").split("-", maxsplit=1)[0].lower()


def _positive_int_env(name: str, fallback: int) -> int:
    try:
        value = int(os.getenv(name, str(fallback)))
    except ValueError:
        return fallback
    return max(1, value)


def _remove_file(path: str) -> None:
    try:
        os.unlink(path)
    except OSError:
        pass


def _cheap_command_parse(text: str) -> list[RemoteAction]:
    stripped = text.strip()
    lower = re.sub(r"[\.,!?]+$", "", stripped.lower())
    if not stripped:
        return []
    if lower.startswith("type "):
        return [RemoteAction(type="paste_text", text=stripped[5:].strip())]
    if lower.startswith("transcribe "):
        return [RemoteAction(type="paste_text", text=stripped[11:].strip())]
    if lower in {"press escape", "escape", "esc"}:
        return [RemoteAction(type="key_press", key="escape")]
    if lower in {"fullscreen", "full screen"}:
        return [RemoteAction(type="key_press", key="f", modifiers=["control", "command"])]
    open_match = re.match(r"^(open|launch|start|go to|show me|bring up)\s+(.+)$", lower)
    if open_match:
        target = open_match.group(2).strip()
        site = _site_url(target)
        if site:
            return [RemoteAction(type="open_url", url=site)]
        app = _app_name(target)
        if app:
            return [RemoteAction(type="open_app", text=app)]
    match = re.match(r"^(go to|open)\s+(https?://\S+|\S+\.\S+)$", lower)
    if match:
        url = match.group(2)
        if not url.startswith("http"):
            url = "https://" + url
        return [RemoteAction(type="open_url", url=url)]
    return []


def _site_url(target: str) -> str | None:
    sites = {
        "youtube": "https://www.youtube.com",
        "you tube": "https://www.youtube.com",
        "chatgpt": "https://chatgpt.com",
        "chat gpt": "https://chatgpt.com",
        "google": "https://www.google.com",
        "gmail": "https://mail.google.com",
        "calendar": "https://calendar.google.com",
        "github": "https://github.com",
        "git hub": "https://github.com",
        "linear": "https://linear.app",
        "notion": "https://www.notion.so",
        "reddit": "https://www.reddit.com",
        "x": "https://x.com",
        "twitter": "https://x.com",
    }
    if target in sites:
        return sites[target]
    if target.startswith(("http://", "https://")):
        return target
    if "." in target and " " not in target:
        return "https://" + target
    return None


def _app_name(target: str) -> str | None:
    apps = {
        "safari": "Safari",
        "chrome": "Google Chrome",
        "google chrome": "Google Chrome",
        "chatgpt app": "ChatGPT",
        "chat gpt app": "ChatGPT",
        "chatgpt desktop": "ChatGPT",
        "settings": "System Settings",
        "system settings": "System Settings",
        "preferences": "System Settings",
        "system preferences": "System Settings",
        "code": "Visual Studio Code",
        "vs code": "Visual Studio Code",
        "visual studio code": "Visual Studio Code",
        "cursor": "Cursor",
        "terminal": "Terminal",
        "iterm": "iTerm",
        "iterm2": "iTerm",
        "finder": "Finder",
        "mail": "Mail",
        "messages": "Messages",
        "notes": "Notes",
        "reminders": "Reminders",
        "calendar app": "Calendar",
        "music": "Music",
        "spotify": "Spotify",
        "slack": "Slack",
        "discord": "Discord",
        "zoom": "zoom.us",
        "preview": "Preview",
        "photos": "Photos",
        "calculator": "Calculator",
        "activity monitor": "Activity Monitor",
        "textedit": "TextEdit",
        "text edit": "TextEdit",
        "xcode": "Xcode",
        "docker": "Docker",
        "raycast": "Raycast",
        "obsidian": "Obsidian",
        "notion app": "Notion",
        "figma": "Figma",
    }
    return apps.get(target)


def _command_ollama(request: CommandRequest) -> CommandResponse:
    host = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
    model = os.getenv("RAT_OLLAMA_MODEL", "qwen2.5:3b")
    prompt = _command_prompt(request.text)
    payload: dict[str, Any] = {"model": model, "prompt": prompt, "stream": False, "format": "json"}
    if request.screenshotBase64:
        payload["images"] = [request.screenshotBase64]
    response = requests.post(
        f"{host.rstrip('/')}/api/generate",
        json=payload,
        timeout=120,
    )
    response.raise_for_status()
    payload = response.json().get("response", "{}")
    return _parse_command_json(payload)


def _command_openai_compatible(request: CommandRequest) -> CommandResponse:
    endpoint = os.environ["RAT_OPENAI_BASE_URL"].rstrip("/") + "/chat/completions"
    api_key = os.getenv("RAT_OPENAI_API_KEY", "local")
    model = os.getenv("RAT_OPENAI_MODEL", "qwen")
    user_content: str | list[dict[str, Any]]
    if request.screenshotBase64:
        user_content = [
            {"type": "text", "text": request.text},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + request.screenshotBase64}},
        ]
    else:
        user_content = request.text
    response = requests.post(
        endpoint,
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": _command_system_prompt()},
                {"role": "user", "content": user_content},
            ],
            "response_format": {"type": "json_object"},
        },
        timeout=120,
    )
    response.raise_for_status()
    content = response.json()["choices"][0]["message"]["content"]
    return _parse_command_json(content)


def _automation_ollama(request: AutomationStepRequest) -> AutomationStepResponse:
    host = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
    model = os.getenv("RAT_AUTOMATION_MODEL", os.getenv("RAT_OLLAMA_MODEL", "qwen2.5:3b"))
    prompt = _automation_prompt(request)
    payload: dict[str, Any] = {"model": model, "prompt": prompt, "stream": False, "format": "json"}
    if request.screenshotBase64:
        payload["images"] = [request.screenshotBase64]
    response = requests.post(
        f"{host.rstrip('/')}/api/generate",
        json=payload,
        timeout=120,
    )
    response.raise_for_status()
    payload = response.json().get("response", "{}")
    return _parse_automation_json(payload)


def _automation_openai_compatible(request: AutomationStepRequest) -> AutomationStepResponse:
    endpoint = os.environ["RAT_OPENAI_BASE_URL"].rstrip("/") + "/chat/completions"
    api_key = os.getenv("RAT_OPENAI_API_KEY", "local")
    model = os.getenv("RAT_AUTOMATION_MODEL", os.getenv("RAT_VISION_MODEL", os.getenv("RAT_OPENAI_MODEL", "vision")))
    step_text = _automation_user_prompt(request)
    user_content: str | list[dict[str, Any]]
    if request.screenshotBase64:
        user_content = [
            {"type": "text", "text": step_text},
            {"type": "image_url", "image_url": {"url": "data:image/png;base64," + request.screenshotBase64}},
        ]
    else:
        user_content = step_text
    response = requests.post(
        endpoint,
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": model,
            "messages": [
                {"role": "system", "content": _automation_system_prompt()},
                {"role": "user", "content": user_content},
            ],
            "response_format": {"type": "json_object"},
        },
        timeout=120,
    )
    response.raise_for_status()
    content = response.json()["choices"][0]["message"]["content"]
    return _parse_automation_json(content)


def _parse_command_json(raw: str) -> CommandResponse:
    try:
        data = json.loads(raw)
        actions = data.get("actions", data if isinstance(data, list) else [])
        return CommandResponse(actions=[RemoteAction(**action) for action in actions])
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LLM did not return valid action JSON: {raw[:500]}") from exc


def _parse_automation_json(raw: str) -> AutomationStepResponse:
    try:
        data = json.loads(_strip_code_fence(raw))
        if isinstance(data, list):
            return AutomationStepResponse(actions=[RemoteAction(**action) for action in data], shouldContinue=True)
        if not isinstance(data, dict):
            raise ValueError("automation response must be an object")
        actions = data.get("actions") or []
        return AutomationStepResponse(
            actions=[RemoteAction(**action) for action in actions[:2]],
            spokenSummary=data.get("spokenSummary") or data.get("summary"),
            criteriaSummary=data.get("criteriaSummary") or data.get("criteria"),
            shouldContinue=bool(data.get("shouldContinue", data.get("continue", False))),
            requiresApproval=bool(data.get("requiresApproval", False)),
            safetyNote=data.get("safetyNote") or data.get("safety"),
        )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"LLM did not return valid automation JSON: {raw[:500]}") from exc


def _strip_code_fence(raw: str) -> str:
    content = raw.strip()
    if content.startswith("```"):
        content = re.sub(r"^```(?:json|JSON)?", "", content).strip()
        content = re.sub(r"```$", "", content).strip()
    return content


def _guard_automation_response(request: AutomationStepRequest, response: AutomationStepResponse) -> AutomationStepResponse:
    response.actions = response.actions[:2]
    for action in response.actions:
        if action.type == "wait" and action.amount is not None:
            action.amount = max(0.0, min(10.0, action.amount))
        if action.type == "swipe" and action.amount is not None:
            action.amount = max(0.05, min(0.85, action.amount))

    return response


def _automation_action_allowed(action_type: str) -> bool:
    return True


def _automation_needs_social_approval(request: AutomationStepRequest, response: AutomationStepResponse) -> bool:
    return False


def _repair_agent_actions(text: str, actions: list[RemoteAction]) -> list[RemoteAction]:
    close_action = _close_or_quit_action(text)
    if close_action:
        if not actions or any(action.type in {"close_window", "quit_app", "locate_and_click", "click"} for action in actions):
            return [close_action]
        return actions

    visual_action = _visual_element_action(text)
    if not visual_action or any(action.type == "locate_and_click" for action in actions):
        return actions
    if not actions:
        return [visual_action]
    if any(action.type == "click" for action in actions):
        repaired: list[RemoteAction] = []
        inserted = False
        for action in actions:
            if action.type == "click":
                if not inserted:
                    repaired.append(visual_action)
                    inserted = True
            else:
                repaired.append(action)
        if not inserted:
            repaired.append(visual_action)
        return repaired
    if any(action.type in {"open_url", "open_app"} for action in actions):
        repaired = list(actions)
        if not any(action.type == "wait" for action in repaired):
            repaired.append(RemoteAction(type="wait", amount=2))
        repaired.append(visual_action)
        return repaired
    return actions


def _close_or_quit_action(text: str) -> RemoteAction | None:
    normalized = re.sub(r"[\.,!?]+$", "", text.strip().lower())
    if normalized in {"quit", "exit"}:
        return RemoteAction(type="quit_app")
    for prefix in ("quit ", "exit "):
        if normalized.startswith(prefix):
            target = _normalized_close_target(normalized[len(prefix):])
            return RemoteAction(type="quit_app", text=target or None)

    if normalized in {"close", "close window", "close app", "close this app", "close this window"}:
        return RemoteAction(type="close_window")
    for prefix in ("close ", "shut ", "dismiss "):
        if normalized.startswith(prefix):
            target = _normalized_close_target(normalized[len(prefix):])
            return RemoteAction(type="close_window", text=target or None)
    return None


def _normalized_close_target(target: str) -> str:
    cleaned = re.sub(r"^(the|this|current)\s+", "", target.strip())
    cleaned = re.sub(r"\s+(app|application|window)$", "", cleaned).strip()
    if cleaned in {"app", "application", "window", "this app", "this application", "this window", "current app", "current application", "current window", "the app", "the application", "the window"}:
        return ""
    return cleaned


def _visual_element_action(text: str) -> RemoteAction | None:
    normalized = re.sub(r"[\.,!?]+$", "", text.strip().lower())
    prefixes = (
        "click on ",
        "click ",
        "tap on ",
        "tap ",
        "select ",
        "focus on ",
        "focus ",
        "put the cursor in ",
        "put cursor in ",
    )
    target = None
    for prefix in prefixes:
        if normalized.startswith(prefix):
            target = normalized[len(prefix):].strip()
            break
    if not target:
        return None
    target = re.sub(r"^(the|this|current)\s+", "", target).strip()
    if "search" in target:
        target = f"{target}, specifically the page search input field, not the browser address bar"
    return RemoteAction(type="locate_and_click", text=target)


def _command_system_prompt() -> str:
    return (
        "You are the planner for a Mac computer-use agent. Convert the user's spoken request into JSON only. "
        "Schema: {\"actions\":[{\"type\":\"key_press|paste_text|open_url|open_app|click|locate_and_click|close_window|quit_app|wait|scroll|swipe|run_applescript\","
        "\"text\":string,\"key\":string,\"modifiers\":[string],\"url\":string,\"x\":number,\"y\":number,\"amount\":number}]}. "
        "Available tools: open_url opens a URL; open_app launches or activates a Mac app by name; key_press sends one key with optional modifiers; "
        "paste_text pastes literal text; click clicks the current pointer or absolute screen x/y; wait pauses for amount seconds; scroll uses x/y or amount; "
        "swipe performs a touch-style gesture with text set to left, right, up, or down; "
        "locate_and_click asks the vision backend to find a visible screen target and click it, with text set to the visual target description; "
        "close_window closes the frontmost window, or a named app window when text is set; quit_app quits the frontmost app, or a named app when text is set; "
        "run_applescript runs short AppleScript for Mac actions that cannot be expressed otherwise. "
        "Prefer direct tools for obvious app, URL, keyboard, and text actions. Use locate_and_click for requests such as clicking/focusing a named button/link/field/search bar, "
        "pressing a visible control, or clicking a spoken key on an on-screen keyboard. For webpage fields, describe the page control, not the browser address bar. "
        "When the user names a website or app context for a visible control, use the current screen if it is already there; otherwise open or activate that context, wait, then locate the control. "
        "If you navigate before visual targeting, add wait with amount 2 before locate_and_click. Do not use locate_and_click for close, quit, or exit requests. "
        "For fullscreen use key_press f with modifiers control and command. For close requests use close_window. For quit or exit requests use quit_app. "
        "Use key names like escape, return, tab, left, right, up, down, space, delete, page_up, page_down, home, end, or single letters. "
        "Use modifier names command, control, option, shift. Return an empty actions array if the request is not a computer-control instruction."
    )


def _automation_system_prompt() -> str:
    return (
        "You are the planner for a Mac computer-use automation loop. Return JSON only. "
        "Schema: {\"actions\":[{\"type\":\"key_press|paste_text|open_url|open_app|click|locate_and_click|close_window|quit_app|wait|scroll|swipe\","
        "\"text\":string,\"key\":string,\"modifiers\":[string],\"url\":string,\"x\":number,\"y\":number,\"amount\":number}],"
        "\"spokenSummary\":string,\"criteriaSummary\":string,\"shouldContinue\":boolean,\"requiresApproval\":boolean,\"safetyNote\":string}. "
        "Plan exactly one small next step from the current screenshot/context. Return at most two actions, where the second action may be wait. "
        "If the instruction contains visual criteria, decompose them into an explicit checklist before choosing an action. Put the checklist in criteriaSummary. "
        "Prefer locate_and_click for visible targets and swipe with text left/right/up/down for touch gestures. "
        "For swipe, optional x/y are normalized screen start coordinates; amount is a 0.05-0.85 screen/window fraction. "
        "Set shouldContinue true only when another observe-plan-act step is needed after these actions. "
        "Set shouldContinue false when the task is complete, blocked, ambiguous, or needs user review. "
        "Set requiresApproval true before actions that send messages, post/share/comment, purchase, delete, or run scripts. "
    )


def _command_prompt(text: str) -> str:
    return _command_system_prompt() + "\nUser: " + text + "\nJSON:"


def _automation_user_prompt(request: AutomationStepRequest) -> str:
    return (
        f"Instruction: {request.instruction}\n"
        f"Step: {request.stepIndex} of {request.maxSteps}\n"
        f"Last action: {request.lastActionSummary or 'none'}\n"
        f"Screen context: {request.screenContext or 'not provided'}\n"
        "Return the next automation decision JSON."
    )


def _automation_prompt(request: AutomationStepRequest) -> str:
    return _automation_system_prompt() + "\n" + _automation_user_prompt(request) + "\nJSON:"


def _vision_moondream(request: VisionRequest) -> VisionResponse:
    try:
        from PIL import Image
        import moondream as md
    except ImportError as exc:
        raise HTTPException(status_code=500, detail="Install moondream and pillow, or set RAT_VISION_BACKEND=openai-compatible/mock") from exc

    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as handle:
        handle.write(_decode_base64(request.imageBase64, "image"))
        path = handle.name
    try:
        image = Image.open(path)
        model_id = os.getenv("RAT_MOONDREAM_MODEL", "vikhyatk/moondream2")
        model = _cached_moondream_model(model_id)
        result = model.point(image, request.prompt)
        points = result.get("points") or []
        if not points:
            raise HTTPException(status_code=404, detail="Moondream did not return a point")
        point = points[0]
        return VisionResponse(x=float(point["x"]), y=float(point["y"]), confidence=point.get("confidence"), label=request.prompt)
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


_MOONDREAM_CACHE: dict[str, Any] = {}


def _cached_moondream_model(model_id: str) -> Any:
    if model_id not in _MOONDREAM_CACHE:
        import moondream as md

        api_key = os.getenv("RAT_MOONDREAM_API_KEY")
        if api_key:
            _MOONDREAM_CACHE[model_id] = md.vl(api_key=api_key, model=model_id)
        else:
            _MOONDREAM_CACHE[model_id] = md.vl(model=model_id)
    return _MOONDREAM_CACHE[model_id]


def _vision_openai_compatible(request: VisionRequest) -> VisionResponse:
    endpoint = os.environ["RAT_OPENAI_BASE_URL"].rstrip("/") + "/chat/completions"
    api_key = os.getenv("RAT_OPENAI_API_KEY", "local")
    model = os.getenv("RAT_VISION_MODEL", os.getenv("RAT_OPENAI_MODEL", "vision"))
    response = requests.post(
        endpoint,
        headers={"Authorization": f"Bearer {api_key}"},
        json={
            "model": model,
            "messages": [
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": f"Return JSON only with normalized x and y coordinates for: {request.prompt}"},
                        {"type": "image_url", "image_url": {"url": "data:image/png;base64," + request.imageBase64}},
                    ],
                }
            ],
            "response_format": {"type": "json_object"},
        },
        timeout=120,
    )
    response.raise_for_status()
    content = response.json()["choices"][0]["message"]["content"]
    data = json.loads(content)
    return VisionResponse(x=float(data["x"]), y=float(data["y"]), confidence=data.get("confidence"), label=data.get("label"))
