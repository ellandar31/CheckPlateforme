"""Export nodes autonome : schéma, chaînes sensibles, SSH et identifiants."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/DPI/checknodes.sh'
ROOT_KEYS = {'_id','appModules','appServers','datasources','fluxes','id','info','jobs',
             'licences','metadatas','nodes','readme','referentiels','tablespaces'}
NODE_KEYS = {'lastUpdate','hostname','domain','fqdn','ip','system','processes','cpu',
             'memory','network','disks','rpms'}


class NodesTests(unittest.TestCase):
    def fixtures(self, root):
        commands = {
            'hostname': 'case "$1" in -s) echo node01 ;; -f) echo node01.example.test ;; -I) echo "192.0.2.10 192.0.2.11" ;; esac',
            'java': 'echo \'openjdk version "17.0.test"\' >&2',
            'timeout': 'shift 3; exec "$@"',
            'df': "printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\\n/dev/root 1000 200 800 20%% /\\n/dev/data 2000 1000 1000 50%% /mnt/data with spaces\\n'",
            'ps': 'case "$*" in *args=*) echo \'1.2 123 service java -Dpassword=SYNTHETIC_TEST_ONLY -jar app.jar\' ;; *) echo "1.2 123 service java" ;; esac',
            'ssh': 'case "$*" in *badhost*) printf partial; exit 255 ;; esac; bash -s',
        }
        for name, body in commands.items():
            path = root / name
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o755)
        return dict(os.environ, PATH=str(root) + ':' + os.environ['PATH'])

    def test_standalone_schema_and_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.fixtures(root)
            script = root / SCRIPT.name
            shutil.copyfile(SCRIPT, script)
            for include in (False, True):
                report = root / f'{include}.json'
                command = ['bash', str(script), '--localhost', '--json', str(report)]
                if include:
                    command += ['--include-command-line']
                result = subprocess.run(command, cwd='/', env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                data = json.loads(report.read_text())
                self.assertEqual(set(data), ROOT_KEYS)
                self.assertRegex(data['_id']['$oid'], r'^[0-9a-f]{24}$')
                self.assertRegex(data['id'], r'^[0-9a-f]{40}$')
                self.assertEqual(len(data['nodes']), 1)
                node = data['nodes'][0]
                self.assertEqual(set(node), NODE_KEYS)
                self.assertIsInstance(node['lastUpdate'], int)
                self.assertEqual(node['domain'], 'example.test')
                self.assertEqual(node['fqdn'], 'node01.example.test')
                self.assertEqual(node['ip'], '192.0.2.10')
                self.assertTrue(all(isinstance(x, str) for x in node['cpu'].values()))
                self.assertTrue(all(isinstance(x, int) for x in node['memory'].values()))
                self.assertEqual(node['memory']['swapUsed'], node['memory']['swapTotal']-node['memory']['swapFree'])
                self.assertEqual(node['disks'][1], dict(name='/dev/data', total=2000, used=1000,
                                                      available=1000, percentUsed='50%', mount='/mnt/data with spaces'))
                self.assertEqual(node['rpms'], [])
                self.assertEqual('SYNTHETIC_TEST_ONLY' in report.read_text(), include)
                self.assertTrue(all(isinstance(x, str) for x in node['processes']))
                original = report.read_bytes()
                self.assertEqual(subprocess.run(command, env=env, capture_output=True).returncode, 2)
                self.assertEqual(report.read_bytes(), original)

    def test_inventory_failure_and_explicit_identifiers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.fixtures(root)
            inventory = root / 'hosts.csv'
            inventory.write_text('host;user;port\nbadhost;audit;22\nremote01;audit;2222\n')
            report = root / 'nodes.json'
            result = subprocess.run(['bash', str(SCRIPT), '--inventory', str(inventory),
                                     '--json', str(report), '--id', 'document-test', '--oid', 'f'*24],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            data = json.loads(report.read_text())
            self.assertEqual(data['id'], 'document-test')
            self.assertEqual(data['_id']['$oid'], 'f'*24)
            self.assertEqual(len(data['nodes']), 1)
            self.assertNotIn({}, data['nodes'])
            self.assertIn('nœud omis', result.stderr)

    def test_invalid_inventory_and_oid(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'report.json'
            result = subprocess.run(['bash', str(SCRIPT), '--localhost', '--oid', 'invalid',
                                     '--json', str(report)], capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertFalse(report.exists())

    def test_partial_collection_ps_error_is_not_a_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = self.fixtures(root)
            (root / 'ps').write_text('#!/bin/bash\necho "ps failure" >&2; exit 1\n')
            report = root / 'nodes.json'
            result = subprocess.run(['bash', str(SCRIPT), '--localhost', '--json', str(report)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(report.read_text())['nodes'][0]['processes'], [])


if __name__ == '__main__':
    unittest.main()
