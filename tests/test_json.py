"""Tests du rapport ; Python sert uniquement à la validation en développement."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/checkplateforme.sh'


class JsonReportTests(unittest.TestCase):
    def test_escaping(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        value = 'guillemets " antislash \\ tab\t ligne\n contrôle\x01 français'
        result = subprocess.run(['bash', '-c', source + '\njson_string "$1"', 'test', value],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), value)

    def test_local_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'local.json'
            command = ['bash', str(SCRIPT), '--localhost', '--json', str(report)]
            result = subprocess.run(command, capture_output=True, text=True)
            data = json.loads(report.read_text())
            self.assertEqual(data['exit_code'], result.returncode)
            self.assertIn('INFO CPU', result.stderr)
            metrics = data['servers'][0]['data']
            self.assertGreater(metrics['cpu']['logical_count'], 0)
            self.assertEqual(metrics['swap_kib']['used'],
                             metrics['swap_kib']['total'] - metrics['swap_kib']['free'])
            original = report.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(report.read_bytes(), original)

    def test_remote_transport_and_continuation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\ncase "$*" in *badhost*) printf partial; exit 255 ;; esac\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'hosts'
            inventory.write_text('badhost\ngoodhost\n')
            report = root / 'remote.json'
            result = subprocess.run(['bash', str(SCRIPT), '--inventory', str(inventory),
                                     '--json', str(report)], capture_output=True, text=True,
                                    env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
            data = json.loads(report.read_text())
            self.assertEqual(result.returncode, 2)
            self.assertEqual(data['servers'][0]['exit_code'], 255)
            self.assertIsNone(data['servers'][0]['data'])
            self.assertIn('cpu', data['servers'][1]['data'])


if __name__ == '__main__':
    unittest.main()
