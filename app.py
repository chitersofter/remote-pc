# -*- coding: utf-8 -*-
# Remote PC Controller — Qwen ~1B Computer Use AI, Voice, Trackpad & Media Server
import ctypes
import logging
import math
import os
import re
import site
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
import webbrowser
from datetime import datetime, timedelta, timezone

BASE_DIR = os.path.dirname(os.path.abspath(__file__))


def _configure_utf8_console():
    """Prevents UnicodeEncodeError on Russian Windows consoles (cp1251/cp866) when printing status banners."""
    if os.name == "nt":
        try:
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)
            ctypes.windll.kernel32.SetConsoleCP(65001)
        except Exception:
            pass
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except Exception:
                pass


def _ensure_local_venv_packages():
    """
    Ensures packages installed in local .venv (e.g. transformers, accelerate, huggingface_hub)
    remain importable when running via the Windows-Firewall-allowed system Python executable.
    """
    if BASE_DIR not in sys.path:
        sys.path.insert(0, BASE_DIR)
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


_configure_utf8_console()
_ensure_local_venv_packages()

from flask import Flask, jsonify, render_template, request, send_file
from flask_cors import CORS
import psutil
import pyautogui
import pyperclip
import pythoncom
import screen_brightness_control as sbc
import telebot

from ai_agent import agent, run_powershell_command

# Zero artificial pause for maximum responsiveness
pyautogui.FAILSAFE = False
pyautogui.PAUSE = 0.0


def _ensure_ascii_vk_mapping():
    """
    Fixes PyAutoGUI Windows bug where launching app.py while Russian keyboard layout
    is active populates keyboardMapping['a'..'z'] with VkKeyScanA() == -1 (0xFF + Ctrl+Alt+Shift).
    Forces physical Windows VK codes (VK_A..VK_Z = 0x41..0x5A, VK_0..VK_9 = 0x30..0x39).
    """
    if os.name != "nt":
        return
    try:
        import pyautogui._pyautogui_win as pw

        for code in range(ord("a"), ord("z") + 1):
            pw.keyboardMapping[chr(code)] = ord(chr(code).upper())
        for code in range(ord("0"), ord("9") + 1):
            pw.keyboardMapping[chr(code)] = code
    except Exception as exc:
        logging.warning(f"VK mapping patch warning: {exc}")


_ensure_ascii_vk_mapping()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

USERS_FILE = os.path.join(BASE_DIR, "users.txt")
CERT_FILE = os.path.join(BASE_DIR, "cert.pem")
KEY_FILE = os.path.join(BASE_DIR, "key.pem")
APK_FILE = os.path.join(BASE_DIR, "RemotePC.apk")

app = Flask(__name__, template_folder=os.path.join(BASE_DIR, "templates"))
CORS(app)

BOT_TOKEN = os.environ.get("REMOTE_PC_BOT_TOKEN", "").strip()
bot = telebot.TeleBot(BOT_TOKEN) if BOT_TOKEN else None

_CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000) if os.name == "nt" else 0
_brightness_cache = {"val": 50, "ts": 0.0}
_clipboard_lock = threading.Lock()


def _safe_float(val, default: float = 0.0) -> float:
    try:
        if val is None or isinstance(val, bool):
            return default
        f = float(val)
        return f if math.isfinite(f) else default
    except Exception:
        return default


def _safe_int(val, default: int = 0) -> int:
    return int(round(_safe_float(val, float(default))))


def _is_dry_run() -> bool:
    return bool(app.config.get("DRY_RUN"))


def launch_detached(shell_cmd: str):
    """Runs a Windows command detached without flashing a console window or blocking Flask."""
    if _is_dry_run():
        return
    try:
        proc = subprocess.Popen(
            shell_cmd,
            shell=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=_CREATE_NO_WINDOW,
        )
        threading.Thread(target=proc.wait, daemon=True).start()
    except Exception as exc:
        logging.error(f"Detached launch failed ({shell_cmd}): {exc}")


# ==================== SSL Certificate Helper ====================
def ensure_ssl_certs():
    """Generates a self-signed certificate if not present so mobile browsers can use HTTPS for SpeechRecognition."""
    if os.path.exists(CERT_FILE) and os.path.exists(KEY_FILE):
        return CERT_FILE, KEY_FILE
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import NameOID

        key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "RemotePC")])
        cert = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(issuer)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime.now(timezone.utc))
            .not_valid_after(datetime.now(timezone.utc) + timedelta(days=365))
            .sign(key, hashes.SHA256())
        )

        with open(KEY_FILE, "wb") as f:
            f.write(
                key.private_bytes(
                    encoding=serialization.Encoding.PEM,
                    format=serialization.PrivateFormat.TraditionalOpenSSL,
                    encryption_algorithm=serialization.NoEncryption(),
                )
            )

        with open(CERT_FILE, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))

        logging.info("SSL Certificate generated for HTTPS.")
        return CERT_FILE, KEY_FILE
    except Exception as exc:
        logging.error(f"Failed to generate SSL cert: {exc}")
        return None, None


# ==================== Audio Control Helpers ====================
def _get_endpoint_volume():
    from pycaw.pycaw import AudioUtilities

    spk = AudioUtilities.GetSpeakers()
    if spk is None:
        return None
    if hasattr(spk, "EndpointVolume") and spk.EndpointVolume is not None:
        return spk.EndpointVolume
    if hasattr(spk, "Activate"):
        from ctypes import POINTER, cast
        from comtypes import CLSCTX_ALL
        from pycaw.pycaw import IAudioEndpointVolume

        interface = spk.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)
        return cast(interface, POINTER(IAudioEndpointVolume))
    return None


def get_volume_info():
    """Returns current volume percentage (0-100) and mute status."""
    pythoncom.CoInitialize()
    try:
        vol = _get_endpoint_volume()
        if vol is not None:
            scalar = vol.GetMasterVolumeLevelScalar()
            mute = vol.GetMute()
            return {"level": int(round(scalar * 100)), "mute": bool(mute)}
    except Exception as exc:
        logging.warning(f"Audio get error: {exc}")
    finally:
        try:
            pythoncom.CoUninitialize()
        except Exception:
            pass
    return {"level": 50, "mute": False}


def set_volume_level(val):
    """Sets master volume level (0-100)."""
    if _is_dry_run():
        return True
    pythoncom.CoInitialize()
    try:
        vol = _get_endpoint_volume()
        if vol is not None:
            scalar = max(0.0, min(1.0, _safe_float(val, 50.0) / 100.0))
            vol.SetMasterVolumeLevelScalar(scalar, None)
            return True
    except Exception as exc:
        logging.warning(f"Audio set error: {exc}")
    finally:
        try:
            pythoncom.CoUninitialize()
        except Exception:
            pass
    return False


def adjust_volume(delta):
    """Adjusts volume by delta percentage (e.g. +10, -10)."""
    curr = get_volume_info()
    new_vol = max(0, min(100, curr["level"] + _safe_int(delta, 5)))
    return set_volume_level(new_vol)


def toggle_volume_mute():
    """Toggles master volume mute."""
    if _is_dry_run():
        return False
    pythoncom.CoInitialize()
    try:
        vol = _get_endpoint_volume()
        if vol is not None:
            curr = vol.GetMute()
            vol.SetMute(not curr, None)
            return not curr
    except Exception as exc:
        logging.warning(f"Audio mute error: {exc}")
    finally:
        try:
            pythoncom.CoUninitialize()
        except Exception:
            pass
    pyautogui.press("volumemute")
    return False


# ==================== Brightness Helpers ====================
def get_brightness_info():
    """Returns current screen brightness (0-100 int, never None), cached briefly for fast /status."""
    now = time.time()
    if now - _brightness_cache["ts"] < 15.0:
        return _brightness_cache["val"]
    try:
        b = sbc.get_brightness()
        val = None
        if isinstance(b, list):
            for item in b:
                if item is not None:
                    val = int(item)
                    break
        elif b is not None:
            val = int(b)
        if val is not None:
            _brightness_cache["val"] = max(0, min(100, val))
    except Exception:
        pass
    _brightness_cache["ts"] = now
    return _brightness_cache["val"]


def set_brightness_level(val):
    clamped = max(0, min(100, _safe_int(val, 50)))
    _brightness_cache["val"] = clamped
    _brightness_cache["ts"] = time.time()
    if _is_dry_run():
        return True
    try:
        sbc.set_brightness(clamped)
        return True
    except Exception as exc:
        logging.warning(f"Brightness set error: {exc}")
        return False


# ==================== Text / Keyboard Typing ====================
def _send_ctrl_v_vk():
    """Sends physical VK_CONTROL + VK_V so paste works regardless of RU/EN keyboard layout."""
    if os.name == "nt":
        user32 = ctypes.windll.user32
        VK_CONTROL = 0x11
        VK_V = 0x56
        KEYEVENTF_KEYUP = 0x0002
        user32.keybd_event(VK_CONTROL, 0, 0, 0)
        user32.keybd_event(VK_V, 0, 0, 0)
        time.sleep(0.015)
        user32.keybd_event(VK_V, 0, KEYEVENTF_KEYUP, 0)
        user32.keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, 0)
    else:
        pyautogui.hotkey("ctrl", "v")


def type_unicode_text(text):
    """Pastes arbitrary unicode / Russian text via clipboard while preserving user's prior clipboard."""
    if not text or _is_dry_run():
        return
    with _clipboard_lock:
        old_clip = None
        try:
            old_clip = pyperclip.paste()
        except Exception:
            pass
        try:
            pyperclip.copy(text)
            time.sleep(0.04)
            _send_ctrl_v_vk()
            if old_clip is not None and old_clip != text:
                def _restore(saved_clip=old_clip, pasted_text=text):
                    time.sleep(0.22)
                    with _clipboard_lock:
                        try:
                            if pyperclip.paste() == pasted_text:
                                pyperclip.copy(saved_clip)
                        except Exception:
                            pass
                threading.Thread(target=_restore, daemon=True).start()
        except Exception as exc:
            logging.error(f"Type text error: {exc}")


# ==================== YouTube Automation ====================
def search_youtube_first_video(query):
    """Searches YouTube and returns the first matching video ID."""
    try:
        url = "https://www.youtube.com/results?search_query=" + urllib.parse.quote(query)
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
                "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
                "Cookie": "SOCS=CAESEwgDEgk0ODEzNzk0MjQaAmVuIAEaBgiA_LyaBg;",
            },
        )
        with urllib.request.urlopen(req, timeout=7) as resp:
            html = resp.read().decode("utf-8", errors="ignore")
            vids = re.findall(r'"videoId":"([a-zA-Z0-9_\-]{11})"', html)
            if not vids:
                vids = re.findall(r"/watch\?v=([a-zA-Z0-9_\-]{11})", html)
            seen = set()
            unique_vids = [v for v in vids if not (v in seen or seen.add(v))]
            if unique_vids:
                return unique_vids[0]
    except Exception as exc:
        logging.warning(f"YouTube scrape error: {exc}")
    return None


def play_youtube_video(query):
    """
    Opens YouTube video directly if query is provided,
    or opens YouTube homepage if query is empty.
    """
    query = (query or "").strip()
    if not query or query.lower() in ["ютуб", "youtube", "ютюб", "ютубчик"]:
        url = "https://www.youtube.com"
        if not _is_dry_run():
            webbrowser.open(url)
        return {"action": "open_url", "url": url, "feedback": "Открываю YouTube"}

    vid = search_youtube_first_video(query)
    if vid:
        url = f"https://www.youtube.com/watch?v={vid}"
        if not _is_dry_run():
            webbrowser.open(url)
        return {"action": "open_video", "url": url, "videoId": vid, "feedback": f"Включаю видео: {query}"}
    else:
        url = f"https://www.youtube.com/results?search_query={urllib.parse.quote(query)}"
        if not _is_dry_run():
            webbrowser.open(url)
        return {"action": "search_results", "url": url, "feedback": f"Ищу на YouTube: {query}"}


# ==================== Fast-Path Voice Command Parser + AI Delegation ====================
def parse_voice_command(raw_text):
    """
    Parses fast-path media/navigation/system commands in ~0ms and delegates
    general PC / Computer Use instructions to the local Qwen AI agent.
    """
    if not raw_text or not isinstance(raw_text, str):
        return {"status": "error", "message": "Пустая команда"}

    text = raw_text.strip().lower()
    text = re.sub(r"[.,!?\'\"«»]", "", text)
    text = re.sub(r"\s+", " ", text).strip()

    if not text:
        return {"status": "error", "message": "Пустая команда"}

    # 1. Open YouTube homepage
    if re.search(
        r"^(?:ыключи|включи|включить|открой|открыть|запусти|запустить|перейди на|перейти на|вруби|врубить)?\s*(?:ютуб|youtube|ютюб|ютубчик)$",
        text,
    ) or text in ["ютуб", "youtube", "ютюб", "ютубчик"]:
        return {
            "status": "ok",
            "action": "open_url",
            "params": {"url": "https://www.youtube.com"},
            "feedback": "Открываю YouTube",
        }

    # 2. Scrolling down
    scroll_verbs = r"(?:пролестни|пролестнуть|пролистни|пролистнуть|пролистай|пролистать|прокрути|прокрутить|листай|листать|скроль|скролить|скролл|мотай|мотать|крути|крутить)"
    if re.search(rf"^{scroll_verbs}?\s*(?:вниз|дальше)$", text) or text in [
        "вниз",
        "еще вниз",
        "чуть вниз",
        "дальше вниз",
        "листай вниз",
        "скроль вниз",
        "мотай вниз",
        "крути вниз",
        "scroll down",
        "down",
    ]:
        return {
            "status": "ok",
            "action": "scroll",
            "params": {"direction": "down", "amount": 600},
            "feedback": "Листаю вниз",
        }

    # 3. Scrolling up
    if re.search(rf"^{scroll_verbs}?\s*(?:вверх|наверх)$", text) or text in [
        "вверх",
        "наверх",
        "еще вверх",
        "чуть вверх",
        "в начало",
        "листай вверх",
        "скроль вверх",
        "мотай вверх",
        "крути вверх",
        "scroll up",
        "up",
    ]:
        return {
            "status": "ok",
            "action": "scroll",
            "params": {"direction": "up", "amount": 600},
            "feedback": "Листаю вверх",
        }

    # 4. Media Controls
    if text in [
        "пауза",
        "стоп",
        "плей",
        "играй",
        "продолжай",
        "продолжить",
        "паузу",
        "поставь на паузу",
        "поставить на паузу",
        "сними с паузы",
        "снять с паузы",
        "воспроизведение",
        "pause",
        "play",
        "стоп видео",
        "останови",
        "остановить",
    ]:
        return {"status": "ok", "action": "media", "params": {"action": "playpause_yt"}, "feedback": "Пауза / Плей"}

    if text in [
        "полный экран",
        "во весь экран",
        "на весь экран",
        "разверни",
        "развернуть",
        "разверни на весь экран",
        "полноэкранный режим",
        "фулскрин",
        "fullscreen",
    ]:
        return {"status": "ok", "action": "media", "params": {"action": "f"}, "feedback": "Полный экран (F)"}

    if text in ["кинотеатр", "режим кинотеатра"]:
        return {"status": "ok", "action": "key", "params": {"key": "t"}, "feedback": "Режим кинотеатра (T)"}

    if text in ["мини плеер", "картинка в картинке"]:
        return {"status": "ok", "action": "key", "params": {"key": "i"}, "feedback": "Мини-плеер (I)"}

    if any(
        text == p or text.startswith(p)
        for p in [
            "перемотай вперед",
            "перемотка вперед",
            "вперед на 5",
            "вперед на 10",
            "на 10 секунд вперед",
            "на 5 секунд вперед",
        ]
    ):
        return {"status": "ok", "action": "media", "params": {"action": "right"}, "feedback": "Перемотка вперед (5с)"}

    if any(
        text == p or text.startswith(p)
        for p in [
            "перемотай назад",
            "перемотка назад",
            "назад на 5",
            "назад на 10",
            "на 10 секунд назад",
            "на 5 секунд назад",
        ]
    ):
        return {"status": "ok", "action": "media", "params": {"action": "left"}, "feedback": "Перемотка назад (5с)"}

    if text in [
        "следующее",
        "следующий",
        "следующий трек",
        "следующее видео",
        "следующая песня",
        "дальше",
        "переключи",
        "next",
    ]:
        return {"status": "ok", "action": "media", "params": {"action": "nexttrack"}, "feedback": "Следующее видео"}

    if text in [
        "предыдущее",
        "предыдущий",
        "предыдущий трек",
        "предыдущее видео",
        "предыдущая песня",
        "назад трек",
        "prev",
    ]:
        return {"status": "ok", "action": "media", "params": {"action": "prevtrack"}, "feedback": "Предыдущее видео"}

    # Volume Control
    vol_num_match = re.search(
        r"^(?:сделай\s+|поставь\s+|установи\s+)?(?:громкость|звук)\s*(?:на\s*)?(\d{1,3})\s*(?:%|процент\w*)?$",
        text,
    )
    if vol_num_match:
        lvl = max(0, min(100, int(vol_num_match.group(1))))
        return {"status": "ok", "action": "volume", "params": {"level": lvl}, "feedback": f"Громкость {lvl}%"}

    if text in ["максимальная громкость", "звук на максимум", "громкость 100", "звук на полную", "на полную"]:
        return {"status": "ok", "action": "volume", "params": {"level": 100}, "feedback": "Громкость 100%"}

    if text in ["выключи звук", "без звука", "заглуши", "мут", "размуть", "включи звук", "mute", "unmute"]:
        return {"status": "ok", "action": "volume", "params": {"mute_toggle": True}, "feedback": "Звук (вкл/выкл)"}

    vol_up_patterns = [
        "громче",
        "погромче",
        "сделай громче",
        "сделай погромче",
        "прибавь звук",
        "прибавь громкость",
        "прибавить громкость",
        "добавь звук",
        "добавь громкость",
        "увеличь громкость",
        "звук громче",
        "louder",
    ]
    if text in vol_up_patterns:
        return {"status": "ok", "action": "volume", "params": {"delta": 10}, "feedback": "Громче (+10%)"}

    vol_down_patterns = [
        "тише",
        "потише",
        "сделай тише",
        "сделай потише",
        "убавь звук",
        "убавь громкость",
        "убавить громкость",
        "уменьши громкость",
        "звук тише",
        "потише сделай",
        "quieter",
    ]
    if text in vol_down_patterns:
        return {"status": "ok", "action": "volume", "params": {"delta": -10}, "feedback": "Тише (-10%)"}

    # Window & Browser Controls
    if text in [
        "сверни все",
        "свернуть все",
        "рабочий стол",
        "сверни окна",
        "свернуть окна",
        "покажи рабочий стол",
        "сверни",
    ]:
        return {"status": "ok", "action": "minimize", "params": {}, "feedback": "Рабочий стол (Win+D)"}

    if text in ["закрой вкладку", "закрыть вкладку", "закрой эту вкладку"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "w"]}, "feedback": "Вкладка закрыта (Ctrl+W)"}

    if text in ["новая вкладка", "открой новую вкладку", "открыть вкладку"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "t"]}, "feedback": "Новая вкладка (Ctrl+T)"}

    if text in ["следующая вкладка", "следующую вкладку", "переключи вкладку"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "tab"]}, "feedback": "Следующая вкладка"}

    if text in ["предыдущая вкладка", "предыдущую вкладку"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "shift", "tab"]}, "feedback": "Предыдущая вкладка"}

    if text in ["обнови", "обнови страницу", "перезагрузи страницу", "рефреш", "обновить"]:
        return {"status": "ok", "action": "key", "params": {"key": "f5"}, "feedback": "Страница обновлена (F5)"}

    if text in ["переключи окно", "альт таб", "следующее окно"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["alt", "tab"]}, "feedback": "Переключение окна (Alt+Tab)"}

    if text in ["закрой окно", "закрой программу", "закрой приложение"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["alt", "f4"]}, "feedback": "Окно закрыто (Alt+F4)"}

    if text in ["скриншот", "сделай скриншот", "снимок экрана"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["win", "shift", "s"]}, "feedback": "Скриншот экрана"}

    if text in ["скопируй", "копировать"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "c"]}, "feedback": "Скопировано"}

    if text in ["вставь", "вставить"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "v"]}, "feedback": "Вставлено"}

    if text in ["выдели все", "выделить все"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "a"]}, "feedback": "Выделено все"}

    if text in ["отмени", "отменить", "назад"]:
        return {"status": "ok", "action": "hotkey", "params": {"keys": ["ctrl", "z"]}, "feedback": "Отмена (Ctrl+Z)"}

    # App Launchers
    if text in ["открой калькулятор", "калькулятор", "запусти калькулятор", "включи калькулятор", "включить калькулятор"]:
        return {"status": "ok", "action": "app", "params": {"name": "calc"}, "feedback": "Открываю Калькулятор"}

    if text in ["открой телеграм", "телеграм", "телегу", "тг", "включи телеграм", "запусти телеграм"]:
        return {"status": "ok", "action": "app", "params": {"name": "telegram"}, "feedback": "Открываю Telegram"}

    if text in ["открой блокнот", "блокнот", "запусти блокнот", "включи блокнот", "включить блокнот"]:
        return {"status": "ok", "action": "app", "params": {"name": "notepad"}, "feedback": "Открываю Блокнот"}

    if text in ["открой проводник", "проводник", "мои файлы", "запусти проводник", "включи проводник"]:
        return {"status": "ok", "action": "app", "params": {"name": "explorer"}, "feedback": "Открываю Проводник"}

    if text in ["диспетчер задач", "диспетчер", "открой диспетчер задач", "запусти диспетчер задач", "включи диспетчер задач"]:
        return {"status": "ok", "action": "app", "params": {"name": "taskmgr"}, "feedback": "Диспетчер задач"}

    if text in ["экранная клавиатура", "клавиатура", "открой экранную клавиатуру", "включи экранную клавиатуру"]:
        return {"status": "ok", "action": "app", "params": {"name": "osk"}, "feedback": "Экранная клавиатура"}

    if text in ["открой браузер", "браузер", "запусти браузер", "включи браузер", "открой гугл", "гугл"]:
        return {"status": "ok", "action": "open_url", "params": {"url": "https://www.google.com"}, "feedback": "Открываю Браузер"}

    if text in ["открой яндекс", "яндекс"]:
        return {"status": "ok", "action": "open_url", "params": {"url": "https://ya.ru"}, "feedback": "Открываю Яндекс"}

    # System Power
    if text in ["выключи компьютер", "выключи пк", "выруби комп", "вырубить пк", "завершение работы"]:
        return {"status": "ok", "action": "sys", "params": {"act": "shut", "val": 60}, "feedback": "Выключение ПК через 1 мин"}

    if text in ["отмени выключение", "отмена выключения", "не выключай"]:
        return {"status": "ok", "action": "sys", "params": {"act": "shut_cancel"}, "feedback": "Выключение отменено"}

    if text in ["заблокируй", "заблокируй пк", "заблокировать компьютер", "заблокировать пк", "блок"]:
        return {"status": "ok", "action": "sys", "params": {"act": "lock"}, "feedback": "Компьютер заблокирован"}

    if text in ["спящий режим", "сон"]:
        return {"status": "ok", "action": "sys", "params": {"act": "sleep"}, "feedback": "Спящий режим"}

    if text in ["перезагрузи компьютер", "перезагрузи пк", "перезагрузка"]:
        return {"status": "ok", "action": "sys", "params": {"act": "reboot", "val": 60}, "feedback": "Перезагрузка ПК через 1 мин"}

    # Dictation / Typing (preserve original casing for typed content!)
    orig_clean = re.sub(r"\s+", " ", raw_text.strip())
    type_match = re.match(r"^(?:напечатай|введи|напиши|текст)\s+(.+)$", orig_clean, flags=re.IGNORECASE)
    type_cli_exclusion = (
        r"(?:\bв\s+(?:командн|терминал|консол|powershell|cmd|блокнот)|"
        r"\b(?:команд\w+\s+строк|файл\w*|скрипт\w*)\b)"
    )
    if type_match and not re.search(type_cli_exclusion, text):
        content = type_match.group(1)
        return {"status": "ok", "action": "type_text", "params": {"text": content}, "feedback": f"Печатаю: {content}"}

    if text in ["энтер", "ввод", "нажми энтер", "enter"]:
        return {"status": "ok", "action": "key", "params": {"key": "enter"}, "feedback": "Нажат Enter"}

    if text in ["эскейп", "esc"]:
        return {"status": "ok", "action": "key", "params": {"key": "esc"}, "feedback": "Нажат Esc"}

    # 5. Play YouTube Video for explicit media/playback requests
    # Exclude obvious PC/OS tasks (using full Russian inflected stems!) so they route to Qwen Computer Use AI
    pc_task_keywords = (
        r"\b(?:"
        r"папк\w*|файл\w*|диск\w*|процесс\w*|памят\w*|команд\w*|терминал\w*|консол\w*|"
        r"powershell|cmd|настройк\w*|параметр\w*|реестр\w*|служб\w*|корзин\w*|сет[ьию]\w*|"
        r"айпи|ip|пинг|ping|драйвер\w*|устройств\w*|таймер\w*|будильник\w*|архив\w*|"
        r"скрипт\w*|код|блютуз\w*|bluetooth|вайфа\w*|wifi|wi-fi|"
        r"ночн\w+\s+(?:свет|режим)\w*|(?:темн|светл)\w+\s+тем\w*|яркост\w*|громкост\w*|"
        r"стим\w*|steam|дискорд\w*|discord|хром\w*|chrome|калькулятор\w*|блокнот\w*|"
        r"проводник\w*|диспетчер\w*|приложен\w*|программ\w*"
        r")\b"
    )
    explicit_yt = bool(re.search(r"\b(?:на ютубе|в ютубе|на youtube|в youtube)\b", text))
    if explicit_yt or not re.search(pc_task_keywords, text):
        yt_play_match = re.match(
            r"^(?:включить|включи|ыключи|поставить|поставь|воспроизвести|воспроизведи|сыграй|врубить|вруби|"
            r"(?:открой|запусти|найди|покажи)\s+(?:на ютубе|в ютубе|на youtube|видео|песню|песня|клип|трек|музыку|фильм|ролик))\s+(.+)$",
            text,
        )
        if yt_play_match:
            query = yt_play_match.group(1).strip()
            query = re.sub(r"\s*(?:на ютубе|в ютубе|на youtube|в youtube)\s*", " ", query).strip()
            query = re.sub(r"^(?:видео|песню|песня|клип|трек|музыку|фильм|ролик)\s+", "", query).strip()

            if not query or query in ["ютуб", "youtube", "ютюб", "ютубчик"]:
                return {
                    "status": "ok",
                    "action": "open_url",
                    "params": {"url": "https://www.youtube.com"},
                    "feedback": "Открываю YouTube",
                }

            return {
                "status": "ok",
                "action": "play_youtube",
                "params": {"query": query},
                "feedback": f"Включаю видео: {query}",
            }

    # 6. Delegate everything else (open-ended PC tasks, CLI requests, apps, files, settings) to Qwen ~1B Computer Use AI
    return {
        "status": "ok",
        "action": "ai_agent",
        "params": {"prompt": raw_text.strip()},
        "feedback": "Выполняю через Qwen AI...",
    }


def _launch_named_app(name: str):
    if _is_dry_run():
        return
    if name == "calc":
        launch_detached("calc.exe")
    elif name == "notepad":
        launch_detached("notepad.exe")
    elif name == "explorer":
        launch_detached("explorer.exe")
    elif name == "taskmgr":
        launch_detached("taskmgr.exe")
    elif name == "osk":
        launch_detached("osk.exe")
    elif name == "chrome":
        webbrowser.open("https://www.google.com")
    elif name == "youtube":
        webbrowser.open("https://www.youtube.com")
    elif name == "telegram":
        try:
            os.startfile("tg://")
        except Exception:
            launch_detached('start "" "tg://"')


def execute_parsed_command(cmd_obj):
    """Executes the action parsed from a voice command or UI action."""
    action = cmd_obj.get("action")
    params = cmd_obj.get("params", {})
    feedback = cmd_obj.get("feedback", "Команда выполнена")

    if action == "ai_agent":
        ai_res = execute_ai_command(params.get("prompt", ""))
        return ai_res.get("feedback", feedback)

    if _is_dry_run():
        return feedback

    if action == "open_url":
        webbrowser.open(params.get("url", "https://www.youtube.com"))
    elif action == "play_youtube":
        res = play_youtube_video(params.get("query", ""))
        feedback = res.get("feedback", feedback)
    elif action == "scroll":
        direction = params.get("direction", "down")
        amount = int(params.get("amount", 600))
        pyautogui.scroll(-amount if direction == "down" else amount)
    elif action == "media":
        act = params.get("action", "space")
        if act == "playpause_yt":
            # System media key pauses/resumes YouTube, Spotify, VLC without typing 'k' into text inputs
            pyautogui.press("playpause")
        else:
            pyautogui.press(act)
    elif action == "volume":
        if params.get("mute_toggle"):
            toggle_volume_mute()
        elif "level" in params:
            set_volume_level(params["level"])
        elif "delta" in params:
            adjust_volume(params["delta"])
    elif action == "minimize":
        pyautogui.hotkey("win", "d")
    elif action == "key":
        pyautogui.press(params.get("key", "enter"))
    elif action == "hotkey":
        keys = params.get("keys", [])
        if keys:
            pyautogui.hotkey(*keys)
    elif action == "type_text":
        type_unicode_text(params.get("text", ""))
    elif action == "app":
        _launch_named_app(params.get("name", ""))
    elif action == "sys":
        act = params.get("act")
        val = _safe_int(params.get("val"), 60)
        if act == "shut":
            launch_detached(f"shutdown /s /t {val}")
        elif act == "shut_cancel":
            launch_detached("shutdown /a")
        elif act == "lock":
            launch_detached("rundll32.exe user32.dll,LockWorkStation")
        elif act == "sleep":
            launch_detached("rundll32.exe powrprof.dll,SetSuspendState 0,1,0")
        elif act == "reboot":
            launch_detached(f"shutdown /r /t {val}")
        elif act == "bright":
            set_brightness_level(val)

    return feedback


def execute_ai_command(prompt_text: str) -> dict:
    """
    Runs local Qwen ~1B Computer Use planning + executes resulting PowerShell / YouTube / GUI action,
    with 1-turn error self-correction if a PowerShell command fails with stderr.
    """
    plan = agent.generate_plan(prompt_text)
    if plan.get("status") != "ok":
        return {
            "status": "error",
            "ok": False,
            "message": plan.get("message", "Ошибка ИИ"),
            "feedback": plan.get("message", "Ошибка ИИ"),
        }

    tool = plan.get("tool", "shell")
    cmd_str = plan.get("command", "")
    feedback = plan.get("feedback", "Выполнено")
    latency_ms = plan.get("latency_ms", 0)
    stdout = ""
    stderr = ""
    exit_code = 0
    display_cmd = cmd_str
    repaired_used = False

    if tool == "shell":
        ps_res = run_powershell_command(cmd_str, timeout=10, dry_run=_is_dry_run())
        stdout = ps_res.get("stdout", "")
        stderr = ps_res.get("stderr", "")
        exit_code = ps_res.get("exit_code", 0)
        if ps_res.get("blocked"):
            entry = {
                "prompt": prompt_text,
                "tool": "shell",
                "command": cmd_str,
                "stdout": "",
                "stderr": stderr,
                "feedback": stderr,
                "ok": False,
                "latency_ms": latency_ms,
            }
            agent.record_execution(entry)
            return {
                "status": "error",
                "ok": False,
                "blocked": True,
                "action": "ai_blocked",
                "command": cmd_str,
                "stdout": "",
                "stderr": stderr,
                "message": stderr,
                "feedback": stderr,
                "latency_ms": latency_ms,
            }

        # 1-turn Computer Use self-correction if PowerShell returned an error
        if not ps_res.get("ok") and stderr and not _is_dry_run():
            repaired = agent.repair_plan(prompt_text, cmd_str, stderr)
            latency_ms += repaired.get("latency_ms", 0)
            rep_cmd = (repaired.get("command") or "").strip()
            if (
                repaired.get("status") == "ok"
                and repaired.get("tool") == "shell"
                and rep_cmd
                and rep_cmd != cmd_str
            ):
                ps_res2 = run_powershell_command(rep_cmd, timeout=10, dry_run=_is_dry_run())
                if not ps_res2.get("blocked"):
                    ps_res = ps_res2
                    cmd_str = rep_cmd
                    display_cmd = rep_cmd
                    stdout = ps_res.get("stdout", "")
                    stderr = ps_res.get("stderr", "")
                    exit_code = ps_res.get("exit_code", 0)
                    repaired_used = True
                    if repaired.get("feedback"):
                        feedback = repaired["feedback"]

        if not ps_res.get("ok") and stderr:
            feedback = f"{feedback} (ошибка: {stderr.splitlines()[0][:90]})"
    elif tool == "youtube":
        yt_res = play_youtube_video(cmd_str)
        feedback = yt_res.get("feedback", feedback)
        display_cmd = f'Start-Process "{yt_res.get("url", "https://www.youtube.com")}"'
        stdout = f"Открыто: {yt_res.get('url', '')}"
    elif tool == "gui":
        gui_map = {
            "scroll_down": {"action": "scroll", "params": {"direction": "down", "amount": 600}, "feedback": "Листаю вниз"},
            "scroll_up": {"action": "scroll", "params": {"direction": "up", "amount": 600}, "feedback": "Листаю вверх"},
            "play_pause": {"action": "media", "params": {"action": "playpause_yt"}, "feedback": "Пауза / Плей"},
            "fullscreen": {"action": "media", "params": {"action": "f"}, "feedback": "Полный экран"},
            "volume_up": {"action": "volume", "params": {"delta": 10}, "feedback": "Громче (+10%)"},
            "volume_down": {"action": "volume", "params": {"delta": -10}, "feedback": "Тише (-10%)"},
            "volume_mute": {"action": "volume", "params": {"mute_toggle": True}, "feedback": "Звук (вкл/выкл)"},
            "minimize_all": {"action": "minimize", "params": {}, "feedback": "Рабочий стол (Win+D)"},
            "close_tab": {"action": "hotkey", "params": {"keys": ["ctrl", "w"]}, "feedback": "Вкладка закрыта"},
            "new_tab": {"action": "hotkey", "params": {"keys": ["ctrl", "t"]}, "feedback": "Новая вкладка"},
            "screenshot": {"action": "hotkey", "params": {"keys": ["win", "shift", "s"]}, "feedback": "Скриншот экрана"},
        }
        if cmd_str.startswith("volume_set:"):
            lvl = max(0, min(100, _safe_int(cmd_str.split(":", 1)[1], 50)))
            execute_parsed_command({"action": "volume", "params": {"level": lvl}, "feedback": feedback})
            display_cmd = f"[AudioEndpoint] SetMasterVolume({lvl}%)"
        elif cmd_str in gui_map:
            mapped = gui_map[cmd_str]
            feedback = execute_parsed_command(mapped)
            display_cmd = f"[GUI] {cmd_str}"
        else:
            # Fallback if Qwen put a PowerShell snippet inside gui
            ps_res = run_powershell_command(cmd_str, timeout=10, dry_run=_is_dry_run())
            stdout = ps_res.get("stdout", "")
            stderr = ps_res.get("stderr", "")
            exit_code = ps_res.get("exit_code", 0)
            if ps_res.get("blocked"):
                return {
                    "status": "error",
                    "ok": False,
                    "blocked": True,
                    "action": "ai_blocked",
                    "command": cmd_str,
                    "stdout": "",
                    "stderr": stderr,
                    "message": stderr,
                    "feedback": stderr,
                    "latency_ms": latency_ms,
                }
    else:
        display_cmd = ""

    exec_ok = exit_code == 0
    entry = {
        "prompt": prompt_text,
        "tool": tool,
        "command": display_cmd,
        "stdout": stdout,
        "stderr": stderr,
        "feedback": feedback,
        "ok": exec_ok,
        "repaired": repaired_used,
        "latency_ms": latency_ms,
    }
    agent.record_execution(entry)

    return {
        "status": "ok",
        "ok": exec_ok,
        "repaired": repaired_used,
        "action": f"ai_{tool}",
        "tool": tool,
        "command": display_cmd,
        "stdout": stdout,
        "stderr": stderr,
        "exit_code": exit_code,
        "feedback": feedback,
        "latency_ms": latency_ms,
        "model": agent.model_id,
    }


# ==================== Network and Telegram ====================
def _ip_priority(ip: str) -> tuple:
    if ip.startswith("192.168."):
        return (0, ip)
    if ip.startswith("172.20.10.") or ip.startswith("10."):
        return (1, ip)
    if ip.endswith(".1") and ip.startswith("172."):
        return (4, ip)
    if ip.startswith("26.") or ip.startswith("198.18.") or ip.startswith("169.254."):
        return (5, ip)
    return (2, ip)


def get_all_ips():
    ips = set()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        primary = s.getsockname()[0]
        s.close()
        if primary and not primary.startswith("127."):
            ips.add(primary)
    except Exception:
        pass
    try:
        for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
            if not ip.startswith("127."):
                ips.add(ip)
    except Exception:
        pass
    try:
        for iface_addrs in psutil.net_if_addrs().values():
            for snic in iface_addrs:
                if snic.family == socket.AF_INET and not snic.address.startswith("127.") and not snic.address.startswith("169.254."):
                    ips.add(snic.address)
    except Exception:
        pass
    return sorted(ips, key=_ip_priority)


def load_users():
    if os.path.exists(USERS_FILE):
        with open(USERS_FILE, "r", encoding="utf-8", errors="ignore") as f:
            return set(line.strip() for line in f if line.strip())
    return set()


def save_user(chat_id):
    users = load_users()
    if str(chat_id) not in users:
        with open(USERS_FILE, "a", encoding="utf-8") as f:
            f.write(f"{chat_id}\n")


def notify_users():
    ips = get_all_ips()
    http_links = [f"http://{ip}:5000" for ip in ips]
    apk_links = [f"http://{ip}:5000/download/apk" for ip in ips]
    msg = (
        "🔴 Remote PC AI запущен!\n\n"
        "📱 Веб-пульт:\n" + "\n".join(http_links) + "\n\n"
        "📦 Скачать Android APK:\n" + "\n".join(apk_links)
    )
    for uid in load_users():
        try:
            bot.send_message(uid, msg)
        except Exception as exc:
            logging.warning(f"Telegram notify failed for {uid}: {exc}")


# ==================== Flask Routes ====================
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/status", methods=["GET"])
def status():
    """Returns real-time status of the PC and local Qwen AI engine."""
    vol = get_volume_info()
    bright = get_brightness_info()
    bat = None
    try:
        b = psutil.sensors_battery()
        if b:
            bat = {"percent": int(round(b.percent)), "plugged": bool(b.power_plugged)}
    except Exception:
        pass

    ips = get_all_ips()
    return jsonify(
        {
            "status": "ok",
            "volume": vol["level"],
            "mute": vol["mute"],
            "brightness": bright,
            "cpu": psutil.cpu_percent(),
            "ram": psutil.virtual_memory().percent,
            "battery": bat,
            "hostname": socket.gethostname(),
            "ips": ips,
            "preferred_ip": ips[0] if ips else "127.0.0.1",
            "apk_available": os.path.exists(APK_FILE),
            "ai": agent.get_status(),
        }
    )


@app.route("/voice", methods=["POST"])
def voice():
    """
    Handles voice/text command from phone.
    Supports `force_ai: true` (always route through Qwen Computer Use CLI)
    and smart hybrid mode (instant fast-path for media/scroll + Qwen AI for PC tasks).
    """
    data = request.get_json(silent=True) or {}
    text = str(data.get("text", "")).strip()
    force_ai = bool(data.get("force_ai", False))
    if not text:
        return jsonify({"status": "error", "message": "Пустая команда"}), 400

    if force_ai:
        res = execute_ai_command(text)
        code = 403 if res.get("blocked") else (200 if res.get("status") == "ok" else 400)
        return jsonify(res), code

    parsed = parse_voice_command(text)
    if parsed.get("status") == "ok":
        if parsed.get("action") == "ai_agent":
            res = execute_ai_command(text)
            status_code = 403 if res.get("blocked") else (200 if res.get("status") == "ok" else 400)
            return jsonify(res), status_code

        feedback = execute_parsed_command(parsed)
        cmd_desc = f"[FastControl] {parsed.get('action')} {parsed.get('params', {})}"
        agent.record_execution(
            {
                "prompt": text,
                "tool": "fast",
                "command": cmd_desc,
                "stdout": "",
                "stderr": "",
                "feedback": feedback,
                "ok": True,
                "latency_ms": 1,
            }
        )
        return jsonify(
            {
                "status": "ok",
                "action": parsed.get("action"),
                "command": cmd_desc,
                "stdout": "",
                "feedback": feedback,
                "details": parsed,
            }
        )
    return jsonify(parsed), 400


@app.route("/ai", methods=["POST"])
def ai_endpoint():
    """Direct Qwen ~1B Computer Use endpoint: translates natural language to Windows CLI and runs it."""
    data = request.get_json(silent=True) or {}
    prompt = str(data.get("prompt") or data.get("text") or "").strip()
    if not prompt:
        return jsonify({"status": "error", "message": "Введите или скажите запрос для ИИ"}), 400
    res = execute_ai_command(prompt)
    code = 403 if res.get("blocked") else (200 if res.get("status") == "ok" else 400)
    return jsonify(res), code


@app.route("/ai/status", methods=["GET"])
def ai_status():
    return jsonify({"status": "ok", **agent.get_status()})


@app.route("/ai/history", methods=["GET"])
def ai_history():
    return jsonify({"status": "ok", "history": agent.get_history()})


@app.route("/ai/clear", methods=["POST"])
def ai_clear():
    agent.clear_history()
    return jsonify({"status": "ok"})


@app.route("/shell", methods=["POST"])
def shell_endpoint():
    """Executes an explicit PowerShell command from the Computer Use console (with safety guardrails)."""
    data = request.get_json(silent=True) or {}
    cmd_str = str(data.get("command", "")).strip()
    if not cmd_str:
        return jsonify({"status": "error", "message": "Пустая команда"}), 400
    ps_res = run_powershell_command(cmd_str, timeout=12, dry_run=_is_dry_run())
    agent.record_execution(
        {
            "prompt": f"PS> {cmd_str}",
            "tool": "shell",
            "command": cmd_str,
            "stdout": ps_res.get("stdout", ""),
            "stderr": ps_res.get("stderr", ""),
            "feedback": "Команда выполнена" if ps_res.get("ok") else (ps_res.get("stderr") or "Ошибка команды"),
            "ok": ps_res.get("ok", False),
            "latency_ms": 0,
        }
    )
    if ps_res.get("blocked"):
        return jsonify({"status": "error", "blocked": True, "message": ps_res.get("stderr"), **ps_res}), 403
    return jsonify({"status": "ok" if ps_res.get("ok") else "error", **ps_res})


@app.route("/download/apk", methods=["GET"])
def download_apk():
    """Allows downloading the compiled Android APK directly to a phone over Wi-Fi."""
    if not os.path.exists(APK_FILE):
        return jsonify({"status": "error", "message": "Файл RemotePC.apk ещё не собран"}), 404
    return send_file(
        APK_FILE,
        mimetype="application/vnd.android.package-archive",
        as_attachment=True,
        download_name="RemotePC.apk",
    )


@app.route("/yt_search", methods=["POST"])
def yt_search():
    """Searches YouTube and plays the top video."""
    data = request.get_json(silent=True) or {}
    query = str(data.get("query", "")).strip()
    res = play_youtube_video(query)
    return jsonify(res)


@app.route("/cmd", methods=["POST"])
def command():
    """Unified command handler supporting trackpad, keyboard, media, volume, apps, and power."""
    d = request.get_json(silent=True) or {}
    c = d.get("cmd")
    try:
        # Pre-parse numeric fields safely so null/NaN/float strings never raise TypeError/ValueError
        sys_val = _safe_int(d.get("val"), 60)
        vol_val = _safe_int(d.get("val"), 50)
        vol_delta = _safe_int(d.get("delta"), 5)
        sens = _safe_float(d.get("sens"), 1.0)
        move_dx = _safe_float(d.get("dx"), 0.0) * sens
        move_dy = _safe_float(d.get("dy"), 0.0) * sens
        scroll_dy = _safe_int(d.get("dy"), 0)
        raw_btn = str(d.get("btn") or "left").lower()
        btn = raw_btn if raw_btn in ("left", "right", "middle") else "left"

        if _is_dry_run():
            return jsonify({"status": "ok", "dry_run": True})

        if c == "media":
            action = str(d.get("action") or "space")
            if action == "playpause_yt":
                pyautogui.press("playpause")
            else:
                pyautogui.press(action)
        elif c == "minimize":
            pyautogui.hotkey("win", "d")
        elif c == "sys":
            act = d.get("act")
            if act == "shut":
                launch_detached(f"shutdown /s /t {sys_val}")
            elif act == "shut_cancel":
                launch_detached("shutdown /a")
            elif act == "reboot":
                launch_detached(f"shutdown /r /t {sys_val}")
            elif act == "bright":
                set_brightness_level(sys_val)
            elif act == "lock":
                launch_detached("rundll32.exe user32.dll,LockWorkStation")
            elif act == "sleep":
                launch_detached("rundll32.exe powrprof.dll,SetSuspendState 0,1,0")

        # Trackpad actions
        elif c == "move":
            pyautogui.moveRel(move_dx, move_dy, _pause=False)
        elif c == "click":
            if bool(d.get("double", False)):
                pyautogui.doubleClick(button=btn)
            else:
                pyautogui.click(button=btn)
        elif c == "mouse_down":
            pyautogui.mouseDown(button=btn)
        elif c == "mouse_up":
            pyautogui.mouseUp(button=btn)
        elif c == "scroll":
            if scroll_dy != 0:
                pyautogui.scroll(scroll_dy)
            direct = d.get("direction")
            if direct == "down":
                pyautogui.scroll(-600)
            elif direct == "up":
                pyautogui.scroll(600)

        # Keyboard & Typing
        elif c == "key":
            key = str(d.get("key") or "")
            if key:
                pyautogui.press(key)
        elif c == "hotkey":
            keys = [str(k) for k in (d.get("keys") or []) if k]
            if keys:
                pyautogui.hotkey(*keys)
        elif c == "type":
            text = str(d.get("text") or "")
            press_enter = bool(d.get("enter", False))
            type_unicode_text(text)
            if press_enter:
                time.sleep(0.05)
                pyautogui.press("enter")

        # Volume control
        elif c == "volume_set":
            set_volume_level(vol_val)
        elif c == "volume_mute":
            toggle_volume_mute()
        elif c == "volume_adj":
            adjust_volume(vol_delta)

        # App launcher
        elif c == "osk":
            _launch_named_app("osk")
        elif c == "open_app":
            _launch_named_app(str(d.get("name") or ""))
        elif c == "open_url":
            webbrowser.open(str(d.get("url") or "https://www.youtube.com"))
    except Exception as exc:
        logging.error(f"Command execution error: {exc}")
        return jsonify({"status": "error", "message": str(exc)}), 500

    return jsonify({"status": "ok"})


# ==================== Telegram Bot Handlers ====================
def start(message):
    save_user(message.chat.id)
    ips = get_all_ips()
    http_links = "\n".join([f"http://{ip}:5000" for ip in ips])
    https_links = "\n".join([f"https://{ip}:5001" for ip in ips])
    apk_links = "\n".join([f"http://{ip}:5000/download/apk" for ip in ips])
    bot.send_message(
        message.chat.id,
        f"🔴 Remote PC AI активен!\n\n"
        f"📦 Скачать APK на телефон:\n{apk_links}\n\n"
        f"🌐 Веб-пульт (HTTP):\n{http_links}\n\n"
        f"🎙️ Веб-пульт с микрофоном (HTTPS):\n{https_links}",
    )


if bot is not None:
    bot.register_message_handler(start, commands=["start", "apk"])


def start_bot_polling():
    while True:
        try:
            bot.polling(none_stop=True, timeout=20)
        except Exception as exc:
            logging.warning(f"Telegram polling exception: {exc}. Reconnecting in 5s...")
            time.sleep(5)


# ==================== Dual Server Runners ====================
def run_https_server():
    cert, key = ensure_ssl_certs()
    https_port = int(os.environ.get("REMOTE_PC_HTTPS_PORT", "5001"))
    if cert and key and os.path.exists(cert) and os.path.exists(key):
        try:
            logging.info(f"Starting HTTPS server on 0.0.0.0:{https_port}...")
            app.run(host="0.0.0.0", port=https_port, ssl_context=(cert, key), threaded=True, use_reloader=False)
        except Exception as exc:
            logging.warning(f"HTTPS server failed to start: {exc}")


if __name__ == "__main__":
    http_port = int(os.environ.get("REMOTE_PC_HTTP_PORT", "5000"))
    https_port = int(os.environ.get("REMOTE_PC_HTTPS_PORT", "5001"))

    # Preload Qwen ~1B Computer Use model in background so server starts immediately
    if not os.environ.get("REMOTE_PC_SKIP_WARMUP"):
        agent.warm_up_async()

    if bot is not None and not os.environ.get("REMOTE_PC_DISABLE_BOT"):
        # Start Telegram bot thread
        threading.Thread(target=start_bot_polling, daemon=True).start()

        # Notify subscribed users in Telegram
        threading.Thread(target=notify_users, daemon=True).start()

    # Start HTTPS server in background thread for Web Speech API mic access
    threading.Thread(target=run_https_server, daemon=True).start()

    logging.info(f"Starting HTTP server on 0.0.0.0:{http_port}...")
    print("\n" + "=" * 62)
    print("🔴 Remote PC AI (Qwen Computer Use) запущен!")
    for ip in get_all_ips():
        print(f"   📱 Веб-пульт:   http://{ip}:{http_port}")
        print(f"   🎙️ HTTPS:       https://{ip}:{https_port}")
        print(f"   📦 Android APK: http://{ip}:{http_port}/download/apk")
    print("=" * 62 + "\n")
    app.run(host="0.0.0.0", port=http_port, threaded=True, use_reloader=False)