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
            # Synthèse : nom cliquable, jauges, aucun détail CPU/Java développé.
            self.assertEqual(page.locator('.server-link').count(), 2)
            self.assertEqual(page.locator('.server .donut').count(), 1)
            self.assertIn('25 %', page.locator('#results').inner_text())
            self.assertIn('Aucun swap configuré', page.locator('#results').inner_text())
            self.assertNotIn('CPU test', page.locator('#results').inner_text())
            page.get_by_role('button', name='rhel01', exact=True).click()
            self.assertEqual(page.locator('.server-detail').count(), 1)
            content = page.locator('#results').inner_text()
            self.assertIn('8 Gio', content)
            self.assertIn('10 Gio', content)
            self.assertIn('1 j 1 h 1 min', content)
            self.assertIn('UTC', content)
            self.assertIn('9\u202f007\u202f199\u202f254\u202f740\u202f993 octets', content)
            self.assertIn('CPU test', content)
            self.assertIn('Informations applicatives non présentes', content)
            self.assertFalse(page.evaluate('Boolean(window.injected)'))
            self.assertEqual(page.locator('img').count(), 0)
            page.locator('#back').click()
            self.assertEqual(page.locator('.server').count(), 2)
            page.locator('#server').select_option('1')
            self.assertEqual(page.locator('.server').count(), 1)
            self.assertEqual(page.locator('.server h2').inner_text(), 'partial')
            page.locator('#server').select_option('all')
            page.locator('#search').fill('192.0.2.1')
            self.assertEqual(page.locator('.server').count(), 1)
            page.locator('#file').set_input_files(str(invalid))
            page.wait_for_selector('#error', state='visible')
            self.assertEqual(page.locator('.server').count(), 1)
            page.get_by_role('button', name='rhel01', exact=True).click()
            self.assertTrue(page.pdf().startswith(b'%PDF'))
            page.locator('#back').click()
            page.set_viewport_size({'width': 390, 'height': 844})
            self.assertTrue(page.locator('#file').is_visible())
            page.locator('#clear').click()
            self.assertTrue(page.locator('#welcome').is_visible())
            self.assertEqual(requests, [])
            self.assertFalse(errors, errors)
            browser.close()

    def test_gauges_unknown_values_and_application_data(self):
        with tempfile.TemporaryDirectory() as directory, sync_playwright() as pw:
            report = Path(directory) / 'nodes.json'
            report.write_text(json.dumps({'nodes': [
                {'hostname': 'node01', 'system': {'upTime': '5184000'},
                 'memory': {'memTotal': 100, 'memUsed': 32, 'swapTotal': 0, 'swapUsed': 0},
                 'disks': [{'mount': '/', 'percentUsed': '91%'},
                           {'mount': '/data', 'percentUsed': '12%'},
                           {'mount': '/unknown', 'percentUsed': None}]},
                {'hostname': 'unknown', 'memory': {'memTotal': None, 'memUsed': None}}],
                'appServers': [{'hostname': 'node01', 'env': 'dev', 'platform': 'test',
                                'name': 'APS1', 'xmx': '6144', 'port': 8082}]}))
            browser = pw.chromium.launch(executable_path=shutil.which('chromium'), args=['--no-sandbox'])
            page = browser.new_page(viewport={'width': 1280, 'height': 900})
            page.context.set_offline(True)
            page.set_content(HTML.read_text())
            page.locator('#file').set_input_files(str(report))
            page.wait_for_selector('.server-link')
            self.assertIn('2 mois', page.locator('.boot').first.inner_text())
            self.assertEqual(page.locator('.donut svg').first.locator('circle').nth(1).get_attribute('stroke'), '#df514f')
            self.assertEqual(page.locator('.donut').nth(2).get_attribute('aria-label'), '/unknown : Non renseigné')
            self.assertNotIn('NaN', page.locator('#results').inner_text())
            page.get_by_role('button', name='node01', exact=True).focus()
            page.keyboard.press('Enter')
            self.assertIn('APS1', page.locator('.server-detail').inner_text())
            self.assertIn('8082', page.locator('.server-detail').inner_text())
            page.locator('#back').click()
            page.set_viewport_size({'width': 390, 'height': 844})
            self.assertTrue(page.evaluate('document.documentElement.scrollWidth <= window.innerWidth'))
            browser.close()


if __name__ == '__main__':
    unittest.main()
