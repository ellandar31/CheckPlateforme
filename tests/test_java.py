"""Collecte /proc, transport SSH simulé et script autonome Java."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'bin/DPI/checkjava.sh'


class JavaTests(unittest.TestCase):
    def test_proc_snapshot_and_arguments(self):
        with tempfile.TemporaryDirectory() as directory:
            proc = Path(directory)
            (proc / 'self').mkdir()
            for pid, name in [(101, 'java'), (102, 'bash'), (103, 'renamed')]:
                process = proc / str(pid)
                process.mkdir()
                (process / 'status').write_text(f'Name:\t{name}\nState:\tS (sleeping)\nPPid:\t1\nUid:\t1000\t1000\t1000\t1000\nVmRSS:\t2048 kB\nThreads:\t12\n')
                (process / 'cmdline').write_bytes(b'java\0-Dkey=a "quoted"\0-jar\0app.jar\0')
                (process / 'exe').symlink_to('/opt/jdk/bin/java' if pid == 103 else '/bin/' + name)
            source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
            for include in (0, 1):
                result = subprocess.run(['bash', '-c', source + '\ncollect_java "$1" "$2" 3>&1 1>&2',
                                         'test', str(include), directory], capture_output=True, text=True)
                data = json.loads(result.stdout)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(data['process_count'], 2)
                self.assertEqual(data['processes'][0]['pid'], 101)
                self.assertEqual(data['processes'][0]['rss_kib'], 2048)
                self.assertEqual(data['processes'][1]['executable'], '/opt/jdk/bin/java')
                self.assertTrue(data['collected_at_utc'].endswith('Z'))
                args = data['processes'][0]['arguments']
                self.assertEqual(args, ['java', '-Dkey=a "quoted"', '-jar', 'app.jar'] if include else None)
            # Une entrée persistante illisible rend le rapport partiel, et non conforme.
            (proc / '101/status').unlink()
            result = subprocess.run(['bash', '-c', source + '\ncollect_java 0 "$1" 3>&1 1>&2',
                                     'test', directory], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(json.loads(result.stdout)['unreadable_count'], 1)

    def test_empty_and_missing_proc(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        with tempfile.TemporaryDirectory() as directory:
            for valid, code in [(False, 2), (True, 0)]:
                if valid:
                    (Path(directory) / 'self').mkdir()
                result = subprocess.run(['bash', '-c', source + '\ncollect_java 0 "$1" 3>&1 1>&2',
                                         'test', directory], capture_output=True, text=True)
                self.assertEqual(result.returncode, code)
                self.assertEqual(json.loads(result.stdout)['processes'], [])

    def test_standalone_remote_continuation_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / SCRIPT.name
            shutil.copyfile(SCRIPT, script)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\ncase "$*" in *badhost*) printf partial; exit 255 ;; esac\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'servers.csv'
            inventory.write_text('host;user;port\nbadhost;audit;22\nremote01;audit;2222\n')
            report = root / 'java.json'
            command = ['bash', str(script), '--inventory', str(inventory), '--json', str(report)]
            result = subprocess.run(command, cwd='/', capture_output=True, text=True,
                                    env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
            data = json.loads(report.read_text())
            self.assertEqual(result.returncode, 2)
            self.assertIsNone(data['java_inventory'][0]['data'])
            self.assertEqual(data['java_inventory'][0]['exit_code'], 255)
            self.assertIsInstance(data['java_inventory'][1]['data']['processes'], list)
            original = report.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(report.read_bytes(), original)

    @unittest.skipUnless(shutil.which('java'), 'Java absent pour le test avec une vraie JVM')
    def test_running_jvm(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Snapshot.java'
            source.write_text('class Snapshot { public static void main(String[] args) throws Exception { System.out.println("READY"); System.out.flush(); Thread.sleep(60000); } }')
            process = subprocess.Popen(['java', str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                # Java 11+ permet de lancer directement un fichier source.
                import select
                ready, _, _ = select.select([process.stdout], [], [], 20)
                self.assertTrue(ready, 'JVM non démarrée dans le délai attendu')
                self.assertEqual(process.stdout.readline().strip(), 'READY')
                report = root / 'report.json'
                result = subprocess.run(['bash', str(SCRIPT), '--localhost', '--json', str(report)], capture_output=True, text=True)
                data = json.loads(report.read_text())['java_inventory'][0]['data']
                self.assertTrue(any(item['pid'] == process.pid for item in data['processes']))
            finally:
                process.terminate()
                process.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()
