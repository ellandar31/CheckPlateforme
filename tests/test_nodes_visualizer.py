"""Visualiseur nodes autonome, sans requête réseau."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from playwright.sync_api import sync_playwright

HTML = Path(__file__).resolve().parents[1] / 'visualizer/nodes.html'


class NodesVisualizerTests(unittest.TestCase):
    def test_offline_nodes_filters_and_validation(self):
        with tempfile.TemporaryDirectory() as directory, sync_playwright() as pw:
            root = Path(directory)
            html = root / 'nodes.html'
            shutil.copyfile(HTML, html)
            node = dict(hostname='rhel01', domain='example.test', fqdn='rhel01.example.test',
                        ip='192.0.2.1', lastUpdate=1700000000,
                        system=dict(versionRedHat='RHEL 9', nameOS='Linux x86_64',
                                    versionJDK='OpenJDK 17', upTime='90061.12', load='0.1 0.2 0.3'),
                        cpu=dict(model='CPU test', nbProc='4', frqProc='2000', bogomips='4000'),
                        memory=dict(memTotal=8388608, memUsed=2097152, memFree=1048576,
                                    swapTotal=0, swapFree=0, swapUsed=0),
                        network=[dict(nom='eth0', tx='9007199254740993', rx='100')],
                        disks=[dict(name='/dev/root', mount='/', total=10485760, used=1048576,
                                    available=9437184, percentUsed='10%')],
                        processes=['1.2 123 user java <img src=x onerror="window.injected=true">'], rpms=[])
            report = root / 'nodes.json'
            report.write_text(json.dumps(dict(nodes=[node, {}, dict(hostname='partial', memory={'memTotal': None})],
                                             id='example', _id={'$oid': 'f'*24})))
            invalid = root / 'invalid.json'
            invalid.write_text('{"nodes":[{"hostname":"bad","processes":[{}]}]}')
            browser = pw.chromium.launch(executable_path=shutil.which('chromium'), args=['--no-sandbox'])
            page = browser.new_page(viewport={'width': 1280, 'height': 900})
            errors, requests = [], []
            page.on('pageerror', lambda error: errors.append(str(error)))
            page.on('request', lambda request: requests.append(request.url))
            page.context.set_offline(True)
            # file:// bloqué par le navigateur géré ; tester le contenu HTML exact.
            page.set_content(html.read_text())
            page.locator('#file').set_input_files(str(report))
            page.wait_for_function("() => document.querySelectorAll('.server').length === 2")
            self.assertIn('1 entrée(s) vide(s)', page.locator('#notice').inner_text())
            content = page.locator('#results').inner_text()
            self.assertIn('8 Gio', content)
            self.assertIn('10 Gio', content)
            self.assertIn('1 j 1 h 1 min', content)
            self.assertIn('UTC', content)
            self.assertIn('Non renseignée', content)
            self.assertIn('9\u202f007\u202f199\u202f254\u202f740\u202f993 octets', content)
            self.assertFalse(page.evaluate('Boolean(window.injected)'))
            self.assertEqual(page.locator('img').count(), 0)
            page.locator('#server').select_option('1')
            self.assertEqual(page.locator('.server').count(), 1)
            self.assertEqual(page.locator('.server h2').inner_text(), 'partial')
            page.locator('#server').select_option('all')
            page.locator('#search').fill('192.0.2.1')
            self.assertEqual(page.locator('.server').count(), 1)
            page.locator('#file').set_input_files(str(invalid))
            page.wait_for_selector('#error', state='visible')
            self.assertEqual(page.locator('.server').count(), 1)
            self.assertTrue(page.pdf().startswith(b'%PDF'))
            page.set_viewport_size({'width': 390, 'height': 844})
            self.assertTrue(page.locator('#file').is_visible())
            page.locator('#clear').click()
            self.assertTrue(page.locator('#welcome').is_visible())
            self.assertEqual(requests, [])
            self.assertFalse(errors, errors)
            browser.close()


if __name__ == '__main__':
    unittest.main()
