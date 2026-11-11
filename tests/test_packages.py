"""Collecte RPM simulée : fonctionnement autonome et gestion des échecs."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/DPI/checkpackages.sh'


class PackageTests(unittest.TestCase):
    def test_standalone_inventory_and_ssh_continuation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / 'checkpackages.sh'
            shutil.copyfile(SCRIPT, script)
            rpm = root / 'rpm'
            rpm.write_text("#!/bin/bash\n[[ $1 == -qa && $2 == --queryformat ]] || exit 9\nprintf 'bash\\t0\\t5.1.8\\t9.el9\\tx86_64\\t1700000000\\n'\nprintf 'kernel\\t1\\t5.14.0\\t100.el9\\tx86_64\\t1700000001\\n'\n")
            rpm.chmod(0o755)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\ncase "$*" in *badhost*) printf partial; exit 255 ;; esac\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'servers.csv'
            inventory.write_text('host;user;port\nlocalhost;;\nbadhost;audit;22\nremote01;audit;2222\n')
            report = root / 'packages.json'
            command = ['bash', str(script), '--inventory', str(inventory), '--json', str(report)]
            result = subprocess.run(command, cwd='/', capture_output=True, text=True,
                                    env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
            data = json.loads(report.read_text())
            self.assertEqual(result.returncode, 2)
            self.assertEqual(data['exit_code'], 2)
            servers = data['package_inventory']
            self.assertEqual(len(servers), 3)
            self.assertIsNone(servers[1]['data'])
            self.assertEqual(servers[1]['exit_code'], 255)
            for index in (0, 2):
                collected = servers[index]['data']
                self.assertEqual(collected['package_count'], 2)
                self.assertIsNone(collected['error'])
                self.assertEqual(collected['packages'][1], dict(name='kernel', epoch=1,
                                  version='5.14.0', release='100.el9', architecture='x86_64',
                                  installed_at_unix=1700000001))
            self.assertIn('bash | 0:5.1.8-9.el9', result.stderr)
            original = report.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(report.read_bytes(), original)

    def test_local_success_empty_failed_and_malformed_rpm(self):
        cases = [("printf 'pkg\\t0\\t1\\t1.el9\\tnoarch\\t0\\n'", 0, 1),
                 ('exit 0', 2, 0),
                 ("printf 'partial'; exit 1", 2, 0),
                 ("printf 'pkg\\t0\\t1\\t1.el9\\tnoarch\\t0\\nbroken\\n'", 2, 0)]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dpkg = root / 'dpkg-query'
            dpkg.write_text('#!/bin/bash\nexit 1\n')
            dpkg.chmod(0o755)
            for index, (body, code, count) in enumerate(cases):
                with self.subTest(body=body):
                    rpm = root / 'rpm'
                    rpm.write_text('#!/bin/bash\n' + body + '\n')
                    rpm.chmod(0o755)
                    report = root / f'{index}.json'
                    result = subprocess.run(['bash', str(SCRIPT), '--localhost', '--json', str(report)],
                                            capture_output=True, text=True,
                                            env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
                    self.assertEqual(result.returncode, code)
                    data = json.loads(report.read_text())['package_inventory'][0]['data']
                    self.assertEqual(data['package_count'], count)
                    self.assertEqual(len(data['packages']), count)
                    self.assertEqual(data['error'] is None, code == 0)

    def test_automatic_apt_fallback_and_debian_versions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rpm = root / 'rpm'
            rpm.write_text('#!/bin/bash\necho "RPM failed" >&2; exit 1\n')
            rpm.chmod(0o755)
            dpkg = root / 'dpkg-query'
            dpkg.write_text("#!/bin/bash\nprintf 'installed\\tbash\\t2:5.2-6ubuntu1\\tamd64\\ninstalled\\tnative\\t1.0\\tall\\nconfig-files\\tremoved\\t1.0-1\\tamd64\\n'\n")
            dpkg.chmod(0o755)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'hosts.csv'
            inventory.write_text('remote01;audit;22\n')
            env = dict(os.environ, PATH=directory + ':' + os.environ['PATH'])
            for remote in (False, True):
                report = root / f'{remote}.json'
                command = ['bash', str(SCRIPT), '--json', str(report)]
                command += ['--inventory', str(inventory)] if remote else ['--localhost']
                result = subprocess.run(command, env=env, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0)
                data = json.loads(report.read_text())['package_inventory'][0]['data']
                self.assertEqual(data['package_manager'], 'dpkg')
                self.assertTrue(data['fallback_used'])
                self.assertTrue(data['rpm_error'])
                self.assertIsNone(data['error'])
                self.assertEqual(data['package_count'], 2)
                package = data['packages'][0]
                self.assertEqual(package['epoch'], 2)
                self.assertEqual(package['version'], '5.2')
                self.assertEqual(package['release'], '6ubuntu1')
                self.assertEqual(package['version_full'], '2:5.2-6ubuntu1')
                self.assertIsNone(package['installed_at_unix'])
                self.assertEqual(data['packages'][1]['release'], '')

    def test_apt_failure_is_not_a_successful_empty_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rpm = root / 'rpm'
            rpm.write_text('#!/bin/bash\nexit 1\n')
            rpm.chmod(0o755)
            for index, body in enumerate(['exit 1', 'exit 0', "printf 'invalid\\n'"]):
                dpkg = root / 'dpkg-query'
                dpkg.write_text('#!/bin/bash\n' + body + '\n')
                dpkg.chmod(0o755)
                report = root / f'{index}.json'
                result = subprocess.run(['bash', str(SCRIPT), '--localhost',
                                         '--json', str(report)], capture_output=True, text=True,
                                        env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
                self.assertEqual(result.returncode, 2)
                data = json.loads(report.read_text())['package_inventory'][0]['data']
                self.assertEqual(data['packages'], [])
                self.assertTrue(data['error'])

    def test_missing_rpm(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        # Aucun accès aux exécutables : la collecte ne doit pas annoncer un succès vide.
        result = subprocess.run(['/bin/bash', '-c', source + '\nPATH=/nonexistent\ncollect_packages 3>&1 1>&2'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn('rpm absente', json.loads(result.stdout)['rpm_error'])


if __name__ == '__main__':
    unittest.main()
