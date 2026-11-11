"""Visualiseur RPM autonome : lecture hors ligne et filtres navigateur."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from playwright.sync_api import sync_playwright

HTML = Path(__file__).resolve().parents[1] / 'visualizer/packages.html'


def package(name, architecture='x86_64'):
    return dict(name=name, epoch=1, version='1.2', release='3.el9',
                architecture=architecture, installed_at_unix=1700000000)


class PackageVisualizerTests(unittest.TestCase):
    def test_standalone_offline_filters_and_errors(self):
        with tempfile.TemporaryDirectory() as directory, sync_playwright() as pw:
            root = Path(directory)
            html = root / 'packages.html'
            shutil.copyfile(HTML, html)
            packages = [package(f'pkg-{index:03}') for index in range(101)]
            packages += [package('<img src=x onerror="window.injected=true">', 'noarch')]
            report = root / 'packages.json'
            report.write_text(json.dumps({'package_inventory': [
                {'target': 'rhel01', 'exit_code': 0, 'data': {
                    'hostname': 'rhel01', 'package_manager': 'rpm', 'package_count': len(packages),
                    'packages': packages, 'error': None, 'exit_code': 0}},
                {'target': 'offline', 'exit_code': 255, 'data': None},
                {'target': 'rpm-error', 'exit_code': 2, 'data': {
                    'hostname': 'rpm-error', 'package_manager': 'rpm', 'package_count': 0,
                    'packages': [], 'error': 'Échec RPM', 'exit_code': 2}}], 'exit_code': 2}))
            wrong = root / 'wrong.json'
            wrong.write_text('{"servers":[],"exit_code":0}')
            broken = root / 'broken.json'
            broken.write_text('not JSON')
            mismatch = root / 'mismatch.json'
            mismatch.write_text(report.read_text().replace('"package_count": 102', '"package_count": 103'))
            browser = pw.chromium.launch(executable_path=shutil.which('chromium'), args=['--no-sandbox'])
            page = browser.new_page(viewport={'width': 1280, 'height': 900})
            errors, requests = [], []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: requests.append(request.url))
            page.context.set_offline(True)
            # file:// bloqué par la politique du navigateur géré : charger le HTML exact.
            page.set_content(html.read_text())
            page.locator('#file').set_input_files(str(report))
            page.wait_for_function("() => document.querySelectorAll('.server').length === 3")
            self.assertEqual(page.locator('tbody tr').count(), 100)
            self.assertIn('Échec RPM', page.locator('#results').inner_text())
            page.get_by_role('button', name='Afficher les 102 packages').click()
            self.assertEqual(page.locator('tbody tr').count(), 102)
            self.assertFalse(page.evaluate('Boolean(window.injected)'))
            self.assertEqual(page.locator('#results img').count(), 0)
            page.locator('#arch').select_option('noarch')
            self.assertEqual(page.locator('tbody tr').count(), 1)
            page.locator('#arch').select_option('all')
            page.locator('#server').select_option('0')
            page.locator('#search').fill('pkg-100')
            self.assertEqual(page.locator('tbody tr').count(), 1)
            self.assertEqual(page.locator('.server').count(), 1)
            self.assertEqual(page.locator('tbody tr td').nth(1).inner_text(), '1')
            self.assertEqual(page.locator('tbody tr td').nth(2).inner_text(), '1.2')
            page.locator('#search').fill('')
            self.assertIn('UTC', page.locator('tbody').inner_text())
            page.locator('#server').select_option('all')
            page.locator('#status').select_option('issues')
            self.assertEqual(page.locator('.server').count(), 2)
            self.assertEqual(page.locator('tbody tr').count(), 0)
            for invalid in (wrong, broken, mismatch):
                page.locator('#file').set_input_files(str(invalid))
                page.wait_for_selector('#error', state='visible')
                self.assertIn('Impossible de lire', page.locator('#error').inner_text())
                self.assertEqual(page.locator('.server').count(), 2)
            self.assertTrue(page.pdf().startswith(b'%PDF'))
            page.set_viewport_size({'width': 390, 'height': 844})
            self.assertTrue(page.locator('#file').is_visible())
            page.locator('#clear').click()
            self.assertTrue(page.locator('#welcome').is_visible())
            self.assertFalse(errors, errors)
            self.assertEqual(requests, [])
            browser.close()

    def test_empty_report(self):
        with tempfile.TemporaryDirectory() as directory, sync_playwright() as pw:
            report = Path(directory) / 'empty.json'
            report.write_text('{"package_inventory":[],"exit_code":0}')
            browser = pw.chromium.launch(executable_path=shutil.which('chromium'), args=['--no-sandbox'])
            page = browser.new_page()
            page.set_content(HTML.read_text())
            page.locator('#file').set_input_files(str(report))
            page.wait_for_function("() => document.querySelector('#results').textContent.includes('aucun serveur')")
            self.assertEqual(page.locator('.server').count(), 0)
            browser.close()


if __name__ == '__main__':
    unittest.main()
