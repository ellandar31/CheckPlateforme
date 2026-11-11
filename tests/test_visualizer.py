"""Validation navigateur du HTML autonome (Playwright requis en développement)."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from playwright.sync_api import sync_playwright

HTML = Path(__file__).resolve().parents[1] / 'visualizer/index.html'


class VisualizerTests(unittest.TestCase):
    def test_offline_reports_and_validation(self):
        with tempfile.TemporaryDirectory() as directory, sync_playwright() as pw:
            root = Path(directory)
            html = root / 'lecture.html'
            shutil.copyfile(HTML, html)
            platform = root / 'plateforme.json'
            platform.write_text(json.dumps({'servers': [
                {'target': '<img src=x onerror="window.injected=true">', 'exit_code': 1,
                 'data': {'hostname': 'rhel01', 'distribution': 'rhel', 'kernel': 'Linux',
                          'cpu': {'logical_count': 4, 'model': 'CPU test'},
                          'ram_kib': {'total': 8388608}, 'swap_kib': {'total': 0},
                          'expectations': [{'resource': 'cpu', 'mountpoint': '', 'operator': 'ge',
                                            'expected': 8, 'actual': 4, 'unit': 'count', 'status': 'fail'}],
                          'filesystems': [{'device': '/dev/root', 'mountpoint': '/', 'size_kib': 10485760,
                                           'used_kib': 1048576, 'available_kib': 9437184, 'use_percent': 10}],
                          'systemd': {'state': 'running'}}},
                {'target': 'inaccessible', 'exit_code': 255, 'data': None}], 'exit_code': 2}))
            flows = root / 'flux.json'
            flows.write_text(json.dumps({'flows': [
                {'source': 'rhel01', 'destination': 'oracle01', 'port': 1521, 'protocole': 'tcp',
                 'description': 'Oracle', 'result': {'status': 'accessible', 'exit_code': 0, 'detail': 'TCP OK'}},
                {'source': 'rhel01', 'destination': 'dns01', 'port': 53, 'protocole': 'udp',
                 'description': 'DNS', 'result': {'status': 'indeterminate', 'exit_code': 2, 'detail': 'Non testé'}}],
                'exit_code': 2}))
            invalid = root / 'invalid.json'
            invalid.write_text('{broken')
            browser = pw.chromium.launch(executable_path=shutil.which('chromium'), args=['--no-sandbox'])
            page = browser.new_page(viewport={'width': 1280, 'height': 900})
            errors, requests = [], []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: requests.append(request.url))
            # Le navigateur géré bloque file:// par politique ; charger exactement
            # le contenu du fichier autonome, sans serveur ni ressource externe.
            page.context.set_offline(True)
            page.set_content(html.read_text())
            page.locator('#file').set_input_files(str(platform))
            page.wait_for_function("() => document.querySelectorAll('.server').length === 2")
            self.assertIn('8 Gio', page.locator('#results').inner_text())
            self.assertIn('10 Gio', page.locator('#results').inner_text())
            self.assertIn('Collecte indisponible', page.locator('#results').inner_text())
            self.assertEqual(page.locator('#results img').count(), 0)
            self.assertFalse(page.evaluate('Boolean(window.injected)'))
            page.locator('#search').fill('inaccessible')
            self.assertEqual(page.locator('.server').count(), 1)
            page.locator('#flows-tab').click()
            page.locator('#file').set_input_files(str(flows))
            page.wait_for_function("() => document.querySelector('#results').textContent.includes('Oracle')")
            page.locator('#filter').select_option('issues')
            self.assertNotIn('Oracle', page.locator('#results').inner_text())
            self.assertIn('Indéterminé', page.locator('#results').inner_text())
            page.locator('#file').set_input_files(str(invalid))
            page.wait_for_selector('#error', state='visible')
            self.assertIn('Impossible de lire', page.locator('#error').inner_text())
            page.locator('#file').set_input_files(str(platform))
            page.wait_for_function("() => document.querySelector('#error').textContent.includes('tableau flows')")
            page.locator('#platform-tab').click()
            self.assertEqual(page.locator('.server').count(), 2)
            pdf = page.pdf()
            self.assertTrue(pdf.startswith(b'%PDF'))
            page.set_viewport_size({'width': 390, 'height': 844})
            self.assertTrue(page.locator('#file').is_visible())
            page.locator('#clear').click()
            self.assertTrue(page.locator('#welcome').is_visible())
            self.assertFalse(errors, errors)
            self.assertEqual(requests, [])
            browser.close()


if __name__ == '__main__':
    unittest.main()
