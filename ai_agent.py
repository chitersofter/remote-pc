# -*- coding: utf-8 -*-
"""
Local Qwen ~1B AI Agent with Windows Computer Use (CLI / PowerShell execution).
Primary engine: Alder Lake / AVX2 optimized llama.cpp + Qwen2.5-1.5B-Instruct Q4_K_M GGUF (~1 GB RAM).
Fallback engine: HuggingFace Transformers (Qwen/Qwen2.5-1.5B-Instruct).
"""

import atexit
import json
import logging
import os
import re
import site
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from datetime import datetime

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def _ensure_local_venv_packages():
    """Registers local .venv site-packages so fallback packages (e.g. transformers) work under system Python."""
    candidates = [
        os.path.join(BASE_DIR, ".venv", "Lib", "site-packages"),
        os.path.join(
            BASE_DIR,
            ".venv",
            "lib",
            f"python{sys.version_info.major}.{sys.version_info.minor}",
            "site-packages",
        ),
    ]
    existing = {os.path.normcase(os.path.abspath(p)) for p in sys.path if p}
    for sp in candidates:
        if os.path.isdir(sp) and os.path.normcase(os.path.abspath(sp)) not in existing:
            site.addsitedir(sp)
            existing.add(os.path.normcase(os.path.abspath(sp)))


_ensure_local_venv_packages()

RUNTIME_DIR = os.path.join(BASE_DIR, "ai_runtime")
LLAMA_SERVER_EXE = os.path.join(RUNTIME_DIR, "llama-server.exe")
GGUF_MODEL_PATH = os.path.join(RUNTIME_DIR, "qwen2.5-1.5b-instruct-q4_k_m.gguf")
LLAMA_PORT = int(os.environ.get("QWEN_LLAMA_PORT", "5009"))
MODEL_ID = os.environ.get("QWEN_MODEL_ID", "Qwen/Qwen2.5-1.5B-Instruct")

PLAN_JSON_SCHEMA = {
    "type": "object",
    "properties": {
        "tool": {"type": "string", "enum": ["shell", "youtube", "gui", "none"]},
        "command": {"type": "string"},
        "feedback": {"type": "string"},
    },
    "required": ["tool", "command", "feedback"],
    "additionalProperties": False,
}

# Destructive OS-level command patterns that must never be auto-executed
DANGEROUS_PATTERNS = [
    r"\bformat\s+[a-z]:",
    r"\bdiskpart\b",
    r"\bbcdedit\b",
    r"\bcipher\s+/w",
    r"\bvssadmin\s+delete\b",
    r"\bwbadmin\s+delete\b",
    r"\breg\s+delete\s+(?:hklm|hkcr|hkey_local_machine|hkey_classes_root)\b",
    r"\b(?:powershell|pwsh)(?:\.exe)?\b[^\n]*\s-(?:e|ec|enc|encodedcommand)\s+[a-z0-9+/=]{8,}",
    r"\b(?:iex|invoke-expression)\b[^\n]*(?:iwr|irm|invoke-webrequest|invoke-restmethod|downloadstring|https?://)",
    # Deleting Windows / Program Files / SystemRoot / Users root via cmdlets or aliases (ri, rm, rd, del, clc)
    r"\b(?:remove-item|ri|rm|del|erase|rd|rmdir|clear-item|clc)\b[^\n]*(?:"
    r"c:\\windows|c:\\program files|c:\\programdata|"
    r"\$env:windir|\$env:systemroot|%windir%|%systemroot%|\$env:programfiles|"
    r"c:\\users\\?\*(?:\s|['\";]|$)|c:\\users['\"\s]*(?:;|$)|"
    r"['\"]?[a-z]:\\(?:\*)?['\"]?(?:\s|;|$)|\$env:systemdrive\\(?:\*)?(?:\s|['\";]|$)"
    r")",
    # Recursive wipe of entire USERPROFILE, Desktop, Downloads, or Documents root
    r"\b(?:remove-item|ri|rm|clear-item|clc|rd|rmdir|del|erase)\b[^\n]*(?:-recurse|-r\b|/s\b)[^\n]*"
    r"(?:\$env:userprofile|%userprofile%|c:\\users\\[^\\'\";\s]+)"
    r"(?:\\(?:desktop|downloads|documents))?(?:\\?\*)?['\"\s]*(?:;|$)",
    # Also catch when path comes BEFORE -Recurse (e.g., Clear-Item -Path $env:USERPROFILE\Downloads -Recurse)
    r"\b(?:remove-item|ri|rm|clear-item|clc|rd|rmdir|del|erase)\b[^\n]*"
    r"(?:\$env:userprofile|%userprofile%|c:\\users\\[^\\'\";\s]+)"
    r"(?:\\(?:desktop|downloads|documents))?(?:\\?\*)?['\"]?\s+(?:-(?:recurse|r|force|fo)\b|/s\b)",
    r":\(\)\s*\{\s*:\|:&\s*\};:",
]


def is_dangerous_command(command: str) -> bool:
    """Returns True if a shell command looks destructive to the OS or root user directories."""
    if not command or not isinstance(command, str):
        return False
    norm = command.strip().lower().replace("/", "\\")
    raw_low = command.strip().lower()
    for pat in DANGEROUS_PATTERNS:
        if re.search(pat, norm) or re.search(pat, raw_low):
            return True
    return False


def _repair_json_candidate(cand: str) -> list:
    """Generates progressively repaired JSON candidates for Windows paths with single backslashes."""
    repaired_trailing = re.sub(r",\s*}", "}", cand)
    # Escape invalid JSON backslashes like \D, \U, \з, and non-hex \u paths like \users
    escaped_bs = re.sub(r'\\(?!["\\/bfnrtu])', r"\\\\", repaired_trailing)
    escaped_bs = re.sub(r"\\u(?![0-9a-fA-F]{4})", r"\\\\u", escaped_bs)
    return [cand, repaired_trailing, escaped_bs]


def extract_json_or_command(raw_text: str) -> dict:
    """
    Robustly parses Qwen model output into {"tool": ..., "command": ..., "feedback": ...}.
    Handles pure JSON, Windows backslash repairs, markdown-fenced JSON, or fenced PowerShell/CMD blocks.
    """
    if not raw_text or not isinstance(raw_text, str):
        return {"tool": "none", "command": "", "feedback": "Пустой ответ модели"}

    cleaned = raw_text.strip()
    cleaned = re.sub(r"<think>.*?</think>", "", cleaned, flags=re.DOTALL).strip()

    fenced_json = re.search(r"```(?:json)?\s*(\{.*\})\s*```", cleaned, flags=re.DOTALL | re.IGNORECASE)
    candidates = []
    if fenced_json:
        candidates.append(fenced_json.group(1))

    start_idx = cleaned.find("{")
    end_idx = cleaned.rfind("}")
    if start_idx != -1:
        depth = 0
        in_str = False
        esc = False
        for idx in range(start_idx, len(cleaned)):
            ch = cleaned[idx]
            if in_str:
                if esc:
                    esc = False
                elif ch == "\\":
                    esc = True
                elif ch == '"':
                    in_str = False
            else:
                if ch == '"':
                    in_str = True
                elif ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        candidates.append(cleaned[start_idx : idx + 1])
                        break
        if end_idx > start_idx:
            outer = cleaned[start_idx : end_idx + 1]
            if outer not in candidates:
                candidates.append(outer)

    for cand in candidates:
        for attempt in _repair_json_candidate(cand):
            try:
                obj = json.loads(attempt)
                if isinstance(obj, dict):
                    tool = str(obj.get("tool") or "shell").strip().lower()
                    cmd = str(obj.get("command") if obj.get("command") is not None else "").strip()
                    feedback = str(obj.get("feedback") or "Команда выполнена").strip()
                    if tool not in ("shell", "youtube", "gui", "none"):
                        tool = "shell"
                    return {"tool": tool, "command": cmd, "feedback": feedback}
            except Exception:
                continue

    code_match = re.search(
        r"```(?:powershell|ps1|cmd|bat|sh|bash)?\s*(.+?)\s*```",
        cleaned,
        flags=re.DOTALL | re.IGNORECASE,
    )
    if code_match:
        cmd_line = code_match.group(1).strip()
        return {"tool": "shell", "command": cmd_line, "feedback": "Выполняю команду в терминале"}

    return {"tool": "none", "command": "", "feedback": cleaned[:240]}


def run_powershell_command(command: str, timeout: int = 10, dry_run: bool = False) -> dict:
    """
    Executes a Windows PowerShell command safely without flashing a console window
    and without hanging on inherited GUI child pipes.
    """
    command = (command or "").strip()
    if not command:
        return {"ok": False, "exit_code": -1, "stdout": "", "stderr": "Пустая команда"}

    if is_dangerous_command(command):
        return {
            "ok": False,
            "blocked": True,
            "exit_code": -2,
            "stdout": "",
            "stderr": "Команда заблокирована системой безопасности (опасная операция с ОС/диском).",
        }

    if dry_run:
        return {
            "ok": True,
            "exit_code": 0,
            "stdout": f"[DRY-RUN] {command}",
            "stderr": "",
        }

    utf8_prefix = (
        "$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = "
        "[System.Text.UTF8Encoding]::new($false); "
    )
    full_script = utf8_prefix + command
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000) if os.name == "nt" else 0

    try:
        with tempfile.TemporaryFile() as out_f, tempfile.TemporaryFile() as err_f:
            proc = subprocess.Popen(
                [
                    "powershell.exe",
                    "-NoLogo",
                    "-NoProfile",
                    "-NonInteractive",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-Command",
                    full_script,
                ],
                stdin=subprocess.DEVNULL,
                stdout=out_f,
                stderr=err_f,
                creationflags=creation_flags,
            )
            timed_out = False
            try:
                exit_code = proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                proc.kill()
                exit_code = 0

            out_f.seek(0)
            err_f.seek(0)
            stdout_str = out_f.read().decode("utf-8", errors="replace").strip()
            stderr_str = err_f.read().decode("utf-8", errors="replace").strip()

        if len(stdout_str) > 2000:
            stdout_str = stdout_str[:2000] + "\n... [вывод сокращён]"
        if len(stderr_str) > 1000:
            stderr_str = stderr_str[:1000] + "\n... [ошибка сокращена]"

        if timed_out and not stderr_str:
            stdout_str = (stdout_str + "\nПроцесс запущен в фоне.").strip()

        return {
            "ok": exit_code == 0 or timed_out,
            "exit_code": exit_code,
            "stdout": stdout_str,
            "stderr": stderr_str,
        }
    except Exception as exc:
        logging.error(f"PowerShell execution error: {exc}")
        return {"ok": False, "exit_code": -1, "stdout": "", "stderr": str(exc)}


class QwenComputerAgent:
    """
    Manages the local ~1B Qwen model via fast quantized GGUF (llama-server)
    with automatic Transformers fallback, translating voice/text instructions
    into Windows CLI commands (Computer Use) or media/GUI actions.
    """

    def __init__(self, model_id: str = MODEL_ID):
        self.model_id = model_id
        self._backend = None  # "gguf" | "transformers"
        self._llama_proc = None
        self._llama_port = LLAMA_PORT
        self._tokenizer = None
        self._model = None
        self._state = "idle"
        self._error = None
        self._load_lock = threading.Lock()
        self._infer_lock = threading.Lock()
        self._history = deque(maxlen=35)
        atexit.register(self.shutdown)

    def shutdown(self):
        if self._llama_proc is not None:
            try:
                self._llama_proc.terminate()
                self._llama_proc.wait(timeout=3)
            except Exception:
                try:
                    self._llama_proc.kill()
                except Exception:
                    pass
            self._llama_proc = None

    def get_status(self) -> dict:
        return {
            "model": "Qwen2.5-1.5B-Instruct (Q4_K_M)" if self._backend == "gguf" else self.model_id,
            "short_name": "Qwen 1.5B",
            "backend": self._backend or ("gguf" if os.path.exists(GGUF_MODEL_PATH) else "transformers"),
            "state": self._state,
            "ready": self._state == "ready",
            "error": self._error,
            "history_count": len(self._history),
        }

    def get_history(self) -> list:
        return list(self._history)

    def clear_history(self):
        self._history.clear()

    def warm_up_async(self):
        if self._state in ("loading", "ready"):
            return
        threading.Thread(target=self.ensure_loaded, daemon=True).start()

    def _is_llama_server_healthy(self, port: int = None) -> bool:
        target_port = port or self._llama_port
        try:
            req = urllib.request.Request(f"http://127.0.0.1:{target_port}/health")
            with urllib.request.urlopen(req, timeout=1.5) as resp:
                if resp.status != 200:
                    return False
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                if not isinstance(data, dict) or data.get("status") != "ok":
                    return False
            req_m = urllib.request.Request(f"http://127.0.0.1:{target_port}/v1/models")
            with urllib.request.urlopen(req_m, timeout=1.5) as resp_m:
                if resp_m.status != 200:
                    return False
                m_data = json.loads(resp_m.read().decode("utf-8", errors="ignore"))
                return isinstance(m_data, dict) and ("data" in m_data or "models" in m_data)
        except Exception:
            return False

    @staticmethod
    def _pick_available_port(preferred: int) -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            try:
                s.bind(("127.0.0.1", preferred))
                return preferred
            except OSError:
                pass
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind(("127.0.0.1", 0))
            return s.getsockname()[1]

    def _start_gguf_server(self) -> bool:
        if not (os.path.exists(LLAMA_SERVER_EXE) and os.path.exists(GGUF_MODEL_PATH)):
            return False

        if self._is_llama_server_healthy(self._llama_port):
            self._backend = "gguf"
            self._state = "ready"
            return True

        self._llama_port = self._pick_available_port(LLAMA_PORT)
        threads = str(min(6, max(2, (os.cpu_count() or 4) // 2)))
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000) if os.name == "nt" else 0
        cmd = [
            LLAMA_SERVER_EXE,
            "-m",
            GGUF_MODEL_PATH,
            "--host",
            "127.0.0.1",
            "--port",
            str(self._llama_port),
            "-c",
            "2048",
            "-t",
            threads,
            "--log-disable",
        ]
        logging.info(f"[Qwen AI] Starting fast GGUF server on 127.0.0.1:{self._llama_port} (threads={threads})...")
        self._llama_proc = subprocess.Popen(
            cmd,
            cwd=RUNTIME_DIR,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creation_flags,
        )

        deadline = time.time() + 25.0
        while time.time() < deadline:
            if self._llama_proc.poll() is not None:
                break
            if self._is_llama_server_healthy(self._llama_port):
                self._backend = "gguf"
                self._state = "ready"
                logging.info("[Qwen AI] GGUF Q4_K_M engine ready (~1 GB RAM).")
                return True
            time.sleep(0.25)

        return False

    def ensure_loaded(self) -> bool:
        if self._state == "ready":
            if self._backend == "gguf" and self._is_llama_server_healthy():
                return True
            if self._backend == "transformers" and self._model is not None:
                return True

        with self._load_lock:
            if self._state == "ready":
                if self._backend == "gguf" and self._is_llama_server_healthy():
                    return True
                if self._backend == "transformers" and self._model is not None:
                    return True

            self._state = "loading"
            self._error = None

            # 1. Prefer lightweight quantized GGUF engine (~1 GB RAM, <1s response)
            try:
                if self._start_gguf_server():
                    return True
            except Exception as exc:
                logging.warning(f"[Qwen AI] GGUF startup fallback: {exc}")

            # 2. Fallback to HuggingFace Transformers
            try:
                import torch
                from transformers import AutoModelForCausalLM, AutoTokenizer

                cpu_threads = min(6, max(2, (os.cpu_count() or 4) // 2))
                torch.set_num_threads(cpu_threads)
                use_cuda = torch.cuda.is_available()
                dtype = torch.float16 if use_cuda else torch.float32
                tokenizer = AutoTokenizer.from_pretrained(self.model_id)
                model = AutoModelForCausalLM.from_pretrained(
                    self.model_id,
                    dtype=dtype,
                    low_cpu_mem_usage=True,
                )
                if use_cuda:
                    model = model.to("cuda")
                model.eval()
                self._tokenizer = tokenizer
                self._model = model
                self._backend = "transformers"
                self._state = "ready"
                return True
            except Exception as exc:
                self._state = "error"
                self._error = str(exc)
                logging.error(f"[Qwen AI] Failed to load model: {exc}")
                return False

    def _build_messages(self, user_prompt: str) -> list:
        home_fwd = os.path.expanduser("~").replace("\\", "/")
        desktop = f"{home_fwd}/Desktop"
        downloads = f"{home_fwd}/Downloads"
        username = os.environ.get("USERNAME", "User")

        system_prompt = (
            "Ты — встроенный ИИ-агент управления компьютером Windows 11 (Computer Use).\n"
            f"Пользователь: {username}. Рабочий стол: {desktop}. Загрузки: {downloads}.\n"
            "Переведи запрос пользователя в ОДНУ точную команду и верни СТРОГО валидный JSON:\n"
            '{"tool": "shell", "command": "<команда Windows PowerShell 5.1>", "feedback": "<кратко на русском что сделано>"}\n\n'
            "Правила для tool:\n"
            '1) "shell" — реальная команда Windows PowerShell 5.1 (НЕ придумывай несуществующие командлеты!). Внутри команды используй одинарные кавычки \'...\' или экранированные \\"...\\", а в путях прямой слэш /.\n'
            '   - Открыть папку в Проводнике: Start-Process explorer \\"$env:USERPROFILE/Downloads\\"\n'
            '   - Открыть программу/настройки/сайт: Start-Process calc | Start-Process notepad | Start-Process taskmgr | Start-Process \'steam://open/main\' | Start-Process ms-settings:bluetooth | Start-Process ms-settings:nightlight | Start-Process ms-settings:themes\n'
            '   - Закрыть/убить программу: Get-Process notepad,CalculatorApp,calc -ErrorAction SilentlyContinue | Stop-Process -Force; Write-Output \'Закрыто\'\n'
            '   - Очистить ТОЛЬКО корзину (НИКОГДА не удаляй Downloads/Desktop!): Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Output \'Корзина очищена\'\n'
            '   - Загрузка CPU и RAM: $cpu=(Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average; $os=Get-CimInstance Win32_OperatingSystem; $ram=[math]::Round((($os.TotalVisibleMemorySize-$os.FreePhysicalMemory)/$os.TotalVisibleMemorySize)*100,1); Write-Output \\"CPU: $cpu% | RAM: $ram%\\"\n'
            '   - Время работы ПК (аптайм): $u=(Get-Date)-(Get-CimInstance Win32_OperatingSystem).LastBootUpTime; Write-Output \\"Аптайм: $($u.Days) дн. $($u.Hours) ч. $($u.Minutes) мин.\\"\n'
            '   - Локальный IP: ipconfig | Select-String \'IPv4\' | Out-String\n'
            '2) "youtube" — включить видео или музыку на YouTube; в "command" укажи только поисковый запрос.\n'
            '3) "gui" — быстрые действия: "scroll_down", "scroll_up", "play_pause", "fullscreen", "volume_up", "volume_down", "volume_mute", "volume_set:50", "minimize_all", "close_tab", "new_tab", "screenshot".\n\n'
            "Примеры:\n"
            'Запрос: создай папку проект на рабочем столе\n'
            'Ответ: {"tool": "shell", "command": "New-Item -ItemType Directory -Path \\"$env:USERPROFILE/Desktop/проект\\" -Force | Out-Null; Write-Output \\"Папка проект создана\\"", "feedback": "Создал папку «проект» на рабочем столе"}\n'
            'Запрос: создай текстовый файл заметка с текстом купить молоко на рабочем столе\n'
            'Ответ: {"tool": "shell", "command": "Set-Content -Path \\"$env:USERPROFILE/Desktop/заметка.txt\\" -Value \\"купить молоко\\" -Encoding UTF8; Write-Output \\"Файл заметка.txt создан\\"", "feedback": "Создал файл заметка.txt на рабочем столе"}\n'
            'Запрос: открой папку загрузки\n'
            'Ответ: {"tool": "shell", "command": "Start-Process explorer \\"$env:USERPROFILE/Downloads\\"", "feedback": "Открываю папку Загрузки"}\n'
            'Запрос: покажи топ 5 процессов по памяти\n'
            'Ответ: {"tool": "shell", "command": "Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Name, @{N=\'RAM_MB\';E={[math]::Round($_.WorkingSet64/1MB,0)}} | Format-Table -AutoSize | Out-String", "feedback": "Топ-5 процессов по памяти"}\n'
            'Запрос: сколько свободного места на диске C\n'
            'Ответ: {"tool": "shell", "command": "Get-PSDrive C | ForEach-Object { \\"Свободно: $([math]::Round($_.Free/1GB, 1)) ГБ\\" }", "feedback": "Проверил свободное место на диске C"}\n'
            'Запрос: включи видео про космос\n'
            'Ответ: {"tool": "youtube", "command": "космос", "feedback": "Включаю видео про космос на YouTube"}\n'
            "Отвечай ТОЛЬКО валидным JSON."
        )
        return [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt.strip()},
        ]

    def _infer_gguf(self, messages: list) -> str:
        body_dict = {
            "messages": messages,
            "temperature": 0.0,
            "max_tokens": 320,
            "stream": False,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "computer_use_plan",
                    "strict": True,
                    "schema": PLAN_JSON_SCHEMA,
                },
            },
        }
        for attempt_with_schema in (True, False):
            if not attempt_with_schema:
                body_dict.pop("response_format", None)
            payload = json.dumps(body_dict).encode("utf-8")
            req = urllib.request.Request(
                f"http://127.0.0.1:{self._llama_port}/v1/chat/completions",
                data=payload,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=25) as resp:
                    body = json.loads(resp.read().decode("utf-8"))
                    return body["choices"][0]["message"]["content"].strip()
            except urllib.error.HTTPError:
                if attempt_with_schema:
                    continue
                raise

    def _infer_transformers(self, messages: list) -> str:
        import torch

        prompt_text = self._tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
        inputs = self._tokenizer([prompt_text], return_tensors="pt")
        device = next(self._model.parameters()).device
        inputs = {k: v.to(device) for k, v in inputs.items()}
        with torch.inference_mode():
            generated_ids = self._model.generate(
                **inputs,
                max_new_tokens=260,
                do_sample=False,
                pad_token_id=self._tokenizer.eos_token_id,
            )
        out_ids = generated_ids[0][inputs["input_ids"].shape[1] :]
        return self._tokenizer.decode(out_ids, skip_special_tokens=True).strip()

    def _run_messages(self, messages: list) -> dict:
        t0 = time.time()
        with self._infer_lock:
            try:
                if self._backend == "gguf":
                    raw_reply = self._infer_gguf(messages)
                else:
                    raw_reply = self._infer_transformers(messages)
            except Exception as exc:
                logging.error(f"[Qwen AI] Inference error: {exc}")
                return {"status": "error", "message": f"Ошибка генерации ИИ: {exc}"}

        latency_ms = int((time.time() - t0) * 1000)
        parsed = extract_json_or_command(raw_reply)
        parsed["raw_reply"] = raw_reply
        parsed["latency_ms"] = latency_ms
        parsed["status"] = "ok"
        return parsed

    def generate_plan(self, user_prompt: str) -> dict:
        if not user_prompt or not user_prompt.strip():
            return {"status": "error", "message": "Пустой запрос"}

        if not self.ensure_loaded():
            return {
                "status": "error",
                "message": f"Модель ИИ недоступна: {self._error or 'ошибка загрузки'}",
            }

        messages = self._build_messages(user_prompt)
        return self._run_messages(messages)

    def repair_plan(self, user_prompt: str, failed_cmd: str, stderr_text: str) -> dict:
        """One-turn Computer Use self-correction when PowerShell reports a cmdlet/syntax error."""
        if not self.ensure_loaded():
            return {"status": "error", "message": "Модель недоступна"}
        messages = self._build_messages(user_prompt)
        messages.append(
            {
                "role": "assistant",
                "content": json.dumps(
                    {"tool": "shell", "command": failed_cmd, "feedback": "Попытка выполнения"},
                    ensure_ascii=False,
                ),
            }
        )
        err_snippet = (stderr_text or "").strip()[:300]
        messages.append(
            {
                "role": "user",
                "content": (
                    f"Команда завершилась ошибкой Windows PowerShell 5.1:\n{err_snippet}\n"
                    "Исправь команду, используя только стандартные встроенные командлеты PowerShell 5.1, и верни JSON."
                ),
            }
        )
        return self._run_messages(messages)

    def record_execution(self, entry: dict):
        entry["timestamp"] = datetime.now().strftime("%H:%M:%S")
        self._history.appendleft(entry)


agent = QwenComputerAgent()
