import unittest
import json
import os
import sys

# Ensure imports work from current dir
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app import app, parse_voice_command, search_youtube_first_video, get_volume_info, get_brightness_info

class TestRemotePC(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_voice_parser_exact_task_requirements(self):
        """Tests the exact examples provided in the user's prompt."""
        # 1. "ыключи ютуб" -> opens YouTube
        res1 = parse_voice_command("ыключи ютуб")
        self.assertEqual(res1['status'], 'ok')
        self.assertEqual(res1['action'], 'open_url')
        self.assertEqual(res1['params']['url'], 'https://www.youtube.com')

        # Variations of opening YouTube (grammar forms, infinitive, slang)
        yt_phrases = ["включи ютуб", "включить ютуб", "открой ютуб", "открыть ютуб", "запусти ютуб", "ютуб", "youtube"]
        for p in yt_phrases:
            res = parse_voice_command(p)
            self.assertEqual(res['action'], 'open_url', f"Failed for phrase: '{p}'")
            self.assertEqual(res['params']['url'], 'https://www.youtube.com')

        # 2. "пролестни вниз" -> scrolls down
        res2 = parse_voice_command("пролестни вниз")
        self.assertEqual(res2['status'], 'ok')
        self.assertEqual(res2['action'], 'scroll')
        self.assertEqual(res2['params']['direction'], 'down')

        # Russian variations of scrolling down
        scroll_down_phrases = [
            "пролистни вниз", "пролистай вниз", "прокрути вниз", "прокрутить вниз",
            "листай вниз", "листать вниз", "вниз", "еще вниз", "чуть вниз", "мотай вниз"
        ]
        for p in scroll_down_phrases:
            res = parse_voice_command(p)
            self.assertEqual(res['action'], 'scroll', f"Failed for phrase: '{p}'")
            self.assertEqual(res['params']['direction'], 'down')

        # Scrolling up
        scroll_up_phrases = [
            "пролестни вверх", "пролистни вверх", "пролистай вверх", "листай вверх",
            "вверх", "наверх", "еще вверх", "в начало"
        ]
        for p in scroll_up_phrases:
            res = parse_voice_command(p)
            self.assertEqual(res['action'], 'scroll', f"Failed for phrase: '{p}'")
            self.assertEqual(res['params']['direction'], 'up')

        # 3. "включи и название видео и оно включается"
        res3 = parse_voice_command("включи моргенштерн кадиллак")
        self.assertEqual(res3['status'], 'ok')
        self.assertEqual(res3['action'], 'play_youtube')
        self.assertIn('моргенштерн кадиллак', res3['params']['query'])

        res4 = parse_voice_command("включи queen bohemian rhapsody")
        self.assertEqual(res4['action'], 'play_youtube')
        self.assertEqual(res4['params']['query'], 'queen bohemian rhapsody')

        res5 = parse_voice_command("включить котиков")
        self.assertEqual(res5['action'], 'play_youtube')
        self.assertEqual(res5['params']['query'], 'котиков')

        res6 = parse_voice_command("ыключи котиков")
        self.assertEqual(res6['action'], 'play_youtube')
        self.assertEqual(res6['params']['query'], 'котиков')

        res7 = parse_voice_command("поставь песню eminem")
        self.assertEqual(res7['action'], 'play_youtube')
        self.assertIn('eminem', res7['params']['query'])

        res8 = parse_voice_command("включи на ютубе lofi hip hop")
        self.assertEqual(res8['action'], 'play_youtube')
        self.assertEqual(res8['params']['query'], 'lofi hip hop')

    def test_voice_parser_media_controls(self):
        """Tests playback, seek, fullscreen and media hotkeys."""
        self.assertEqual(parse_voice_command("пауза")['action'], 'media')
        self.assertEqual(parse_voice_command("плей")['action'], 'media')
        self.assertEqual(parse_voice_command("стоп")['action'], 'media')
        self.assertEqual(parse_voice_command("полный экран")['action'], 'media')
        self.assertEqual(parse_voice_command("на весь экран")['action'], 'media')
        self.assertEqual(parse_voice_command("кинотеатр")['action'], 'key')
        self.assertEqual(parse_voice_command("мини плеер")['action'], 'key')
        self.assertEqual(parse_voice_command("перемотай вперед")['action'], 'media')
        self.assertEqual(parse_voice_command("перемотай назад")['action'], 'media')
        self.assertEqual(parse_voice_command("следующее видео")['action'], 'media')
        self.assertEqual(parse_voice_command("предыдущее видео")['action'], 'media')

    def test_voice_parser_volume(self):
        """Tests volume control variations."""
        vol_up = ["громче", "погромче", "сделай громче", "сделай погромче", "прибавь звук", "прибавь громкость"]
        for p in vol_up:
            res = parse_voice_command(p)
            self.assertEqual(res['action'], 'volume', f"Failed for {p}")
            self.assertIn('delta', res['params'])
            self.assertGreater(res['params']['delta'], 0)

        vol_down = ["тише", "потише", "сделай тише", "сделай потише", "убавь звук", "убавь громкость"]
        for p in vol_down:
            res = parse_voice_command(p)
            self.assertEqual(res['action'], 'volume', f"Failed for {p}")
            self.assertIn('delta', res['params'])
            self.assertLess(res['params']['delta'], 0)

        res_num1 = parse_voice_command("громкость 50")
        self.assertEqual(res_num1['action'], 'volume')
        self.assertEqual(res_num1['params']['level'], 50)

        res_num2 = parse_voice_command("звук 80")
        self.assertEqual(res_num2['action'], 'volume')
        self.assertEqual(res_num2['params']['level'], 80)

        res_mute = parse_voice_command("выключи звук")
        self.assertEqual(res_mute['action'], 'volume')
        self.assertTrue(res_mute['params'].get('mute_toggle'))

    def test_voice_parser_apps_and_system(self):
        """Tests opening applications, tabs, windows and power controls."""
        self.assertEqual(parse_voice_command("открой калькулятор")['action'], 'app')
        self.assertEqual(parse_voice_command("открой блокнот")['action'], 'app')
        self.assertEqual(parse_voice_command("открой телеграм")['action'], 'app')
        self.assertEqual(parse_voice_command("диспетчер задач")['action'], 'app')
        self.assertEqual(parse_voice_command("сверни все")['action'], 'minimize')
        self.assertEqual(parse_voice_command("закрой вкладку")['action'], 'hotkey')
        self.assertEqual(parse_voice_command("новая вкладка")['action'], 'hotkey')
        self.assertEqual(parse_voice_command("скриншот")['action'], 'hotkey')
        self.assertEqual(parse_voice_command("обнови")['action'], 'key')
        self.assertEqual(parse_voice_command("выключи компьютер")['action'], 'sys')
        self.assertEqual(parse_voice_command("отмени выключение")['action'], 'sys')
        self.assertEqual(parse_voice_command("заблокируй пк")['action'], 'sys')
        self.assertEqual(parse_voice_command("напечатай Привет")['action'], 'type_text')

    def test_voice_endpoint(self):
        """Tests POST /voice endpoint."""
        resp = self.client.post('/voice', json={'text': 'ыключи ютуб'})
        self.assertEqual(resp.status_code, 200)
        data = json.loads(resp.data)
        self.assertEqual(data['status'], 'ok')
        self.assertEqual(data['action'], 'open_url')

        resp2 = self.client.post('/voice', json={'text': 'пролестни вниз'})
        self.assertEqual(resp2.status_code, 200)
        data2 = json.loads(resp2.data)
        self.assertEqual(data2['action'], 'scroll')

        resp_err = self.client.post('/voice', json={'text': ''})
        self.assertEqual(resp_err.status_code, 400)

    def test_status_endpoint(self):
        """Tests GET /status endpoint."""
        resp = self.client.get('/status')
        self.assertEqual(resp.status_code, 200)
        data = json.loads(resp.data)
        self.assertEqual(data['status'], 'ok')
        self.assertIn('volume', data)
        self.assertIn('brightness', data)
        self.assertIn('cpu', data)
        self.assertIn('hostname', data)

    def test_cmd_endpoint(self):
        """Tests POST /cmd endpoint."""
        commands = [
            {'cmd': 'media', 'action': 'space'},
            {'cmd': 'media', 'action': 'playpause_yt'},
            {'cmd': 'move', 'dx': 10, 'dy': -10, 'sens': 1.0},
            {'cmd': 'click', 'btn': 'left'},
            {'cmd': 'scroll', 'dy': -100},
            {'cmd': 'scroll', 'direction': 'down'},
            {'cmd': 'key', 'key': 'esc'},
            {'cmd': 'hotkey', 'keys': ['ctrl', 'c']},
            {'cmd': 'type', 'text': 'Тест', 'enter': False},
            {'cmd': 'volume_set', 'val': 80},
            {'cmd': 'volume_adj', 'delta': 5},
            {'cmd': 'volume_mute'},
            {'cmd': 'open_app', 'name': 'calc'}
        ]
        for c in commands:
            resp = self.client.post('/cmd', json=c)
            self.assertEqual(resp.status_code, 200, f"Failed on command: {c}")

    def test_index_page(self):
        """Tests that index.html renders and contains all critical UI elements."""
        resp = self.client.get('/')
        self.assertEqual(resp.status_code, 200)
        html = resp.data.decode('utf-8')
        self.assertIn('Remote PC', html)
        self.assertIn('ыключи ютуб', html)
        self.assertIn('пролестни вниз', html)
        self.assertIn('touch-surface', html)
        self.assertIn('scroll-strip', html)
        self.assertIn('handsfree', html.lower())
        self.assertIn('soundfeedback', html.lower().replace('-', '').replace(' ', ''))

if __name__ == '__main__':
    unittest.main()
