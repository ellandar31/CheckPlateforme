"""Tests du rapport ; Python sert uniquement à la validation en développement."""
import json
import os
from pathlib import Path
import socket
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

    def test_filesystems_json(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        table = ('Filesystem 1024-blocks Used Available Capacity Mounted on\n'
                 '/dev/mapper/root 10000 4000 6000 40% /\n'
                 'tmpfs 2000 0 2000 0% /run\n'
                 '/dev/disk with spaces 3000 1000 2000 34% /mnt/data "quoted"\n')
        result = subprocess.run(['bash', '-c', source + '\nfilesystems_json "$1"', 'test', table],
                                capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        self.assertEqual(len(data), 3)
        self.assertEqual(data[0], dict(device='/dev/mapper/root', mountpoint='/',
                                      size_kib=10000, used_kib=4000,
                                      available_kib=6000, use_percent=40))
        self.assertEqual(data[2]['device'], '/dev/disk with spaces')
        self.assertEqual(data[2]['mountpoint'], '/mnt/data "quoted"')
        result = subprocess.run(['bash', '-c', source + '\nfilesystems_json "$1"',
                                 'test', 'header\ninvalid row'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout), [])

    def test_local_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'local.json'
            command = ['bash', str(SCRIPT), '--localhost', '--json', str(report)]
            result = subprocess.run(command, capture_output=True, text=True)
            data = json.loads(report.read_text())
            self.assertEqual(data['exit_code'], result.returncode)
            self.assertEqual(data['flows'], [])
            self.assertEqual(data['servers'][0]['data']['expectations'], [])
            self.assertIn('INFO CPU', result.stderr)
            metrics = data['servers'][0]['data']
            self.assertGreater(metrics['cpu']['logical_count'], 0)
            self.assertNotIn('filesystems_text', metrics)
            self.assertTrue(metrics['filesystems'])
            for filesystem in metrics['filesystems']:
                self.assertIsInstance(filesystem['size_kib'], int)
                self.assertTrue(filesystem['mountpoint'])
            self.assertEqual(metrics['swap_kib']['used'],
                             metrics['swap_kib']['total'] - metrics['swap_kib']['free'])
            original = report.read_bytes()
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 2)
            self.assertEqual(report.read_bytes(), original)

    def test_inventory_loopback_without_ssh(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ssh = root / 'ssh'
            marker = root / 'ssh-called'
            ssh.write_text('#!/bin/bash\ntouch "' + str(marker) + '"\nexit 255\n')
            ssh.chmod(0o755)
            inventory = root / 'hosts'
            inventory.write_text('host;user;port\nlocalhost;;\n127.0.0.1;;\n::1;;\n')
            report = root / 'report.json'
            subprocess.run(['bash', str(SCRIPT), '--inventory', str(inventory),
                            '--json', str(report)], capture_output=True,
                           env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']))
            self.assertFalse(marker.exists())
            data = json.loads(report.read_text())
            self.assertEqual(len(data['servers']), 3)
            for server in data['servers']:
                self.assertIn('cpu', server['data'])
                self.assertNotEqual(server['exit_code'], 255)

    def test_csv_formats_and_invalid_rows(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        cases = [
            ('server;;', ['server', '', '']),
            ('server;audit;2222', ['server', 'audit', '2222']),
            (' "server" ; "audit" ; "22" ', ['server', 'audit', '22']),
            ('"a""b";;', ['a"b', '', '']),
            ('server audit 22', None),
            ('server,audit,22', None),
            ('server\taudit\t22', None),
            ('server;"audit, team";22', ['server', 'audit, team', '22']),
            ('server;audit;22;', None),
            ('server;audit', None),
            ('"server;audit;22', None),
            ('"server"x;;', None),
        ]
        for line, expected in cases:
            with self.subTest(line=line):
                command = source + '\nparse_csv_line "$1" || exit 2; printf "%s\\0" "${csv_fields[@]}"'
                result = subprocess.run(['bash', '-c', command, 'test', line], capture_output=True)
                if expected is None:
                    self.assertEqual(result.returncode, 2)
                else:
                    self.assertEqual(result.returncode, 0)
                    self.assertEqual(result.stdout.decode().split('\0')[:-1], expected)

    def test_csv_crlf_bom_and_empty_user(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inventory = root / 'hosts.csv'
            inventory.write_bytes(b'\xef\xbb\xbfhost;user;port\r\n# commentaire\r\n\r\n"localhost";;2222')
            report = root / 'report.json'
            subprocess.run(['bash', str(SCRIPT), '--inventory', str(inventory),
                            '--json', str(report)], capture_output=True)
            data = json.loads(report.read_text())
            self.assertEqual(data['servers'][0]['target'], 'localhost')
            self.assertIn('cpu', data['servers'][0]['data'])

    def test_flow_probe_tcp_and_udp(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        def probe(port, protocol='tcp'):
            result = subprocess.run(['bash', '-c', source + '\nprobe_flow 127.0.0.1 "$1" "$2"',
                                     'test', str(port), protocol], capture_output=True, text=True)
            return result.returncode, json.loads(result.stdout)
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            listener.listen()
            port = listener.getsockname()[1]
            rc, data = probe(port)
            self.assertEqual(rc, 0)
            self.assertEqual(data['status'], 'accessible')
        rc, data = probe(port)
        self.assertEqual(rc, 1)
        self.assertEqual(data['status'], 'refused')
        rc, data = probe(port, 'udp')
        self.assertEqual(rc, 2)
        self.assertEqual(data['status'], 'indeterminate')

    def test_optional_matrix_with_remote_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'hosts.csv'
            inventory.write_text('host;user;port\nsource01;audit;2222\n')
            matrix = root / 'flows.csv'
            matrix.write_text('source;destination;port;protocole;description\n'
                              'source01;127.0.0.1;53;udp;"DNS; test"\n')
            report = root / 'report.json'
            result = subprocess.run(['bash', str(SCRIPT), '--inventory', str(inventory),
                                     '--flows', str(matrix), '--json', str(report)],
                                    env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            flows = json.loads(report.read_text())['flows']
            self.assertEqual(flows[0]['source'], 'source01')
            self.assertEqual(flows[0]['description'], 'DNS; test')
            self.assertEqual(flows[0]['result']['status'], 'indeterminate')

    def test_invalid_matrix_before_collection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for row in ['localhost;host;0;tcp;test',
                        'localhost;host;22;ssh;test',
                        'unknown-source;host;22;tcp;test',
                        'localhost;$(touch bad);22;tcp;test']:
                matrix = root / 'flows.csv'
                matrix.write_text(row)
                report = root / 'report.json'
                result = subprocess.run(['bash', str(SCRIPT), '--localhost',
                                         '--flows', str(matrix), '--json', str(report)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertFalse(report.exists())

    def test_flow_timeout_and_dns_status(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        for code, status in [(124, 'timeout'), (3, 'dns_error')]:
            result = subprocess.run(['bash', '-c', source +
                                     '\ntimeout() { return ' + str(code) + '; }\nprobe_flow host 22 tcp'],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(json.loads(result.stdout)['status'], status)

    def test_expectations_comparison_and_missing_mount(self):
        source = SCRIPT.read_text().rsplit('main "$@"', 1)[0]
        command = source + r'''
expected_hosts=(localhost localhost localhost localhost localhost localhost)
expected_resources=(cpu ram swap filesystem_size filesystem_size filesystem_size)
expected_mounts=('' '' '' / /missing /)
expected_operators=(eq ge eq ge ge le)
expected_values=(4 8 0 1 1 2)
expected_units=(count MiB MiB MiB MiB MiB)
cpu_count=4; ram_total=8192; swap_total=0
failed=0; errors=0; disks_ok=1
disks=$'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/root 2048 1024 1024 50% /'
check_expectations localhost >&2
printf '{"checks":%s,"failed":%s,"errors":%s}' "$checks" "$failed" "$errors"
'''
        result = subprocess.run(['bash', '-c', command], capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        self.assertEqual([check['status'] for check in data['checks']],
                         ['pass', 'pass', 'pass', 'pass', 'fail', 'pass'])
        self.assertEqual(data['checks'][1]['expected'], 8192)
        self.assertIsNone(data['checks'][4]['actual'])
        self.assertEqual(data['failed'], 1)
        self.assertEqual(data['errors'], 0)
        result = subprocess.run(['bash', '-c', command.replace('ram_total=8192', "ram_total=''")],
                                capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout)['checks'][1]['status'], 'error')

    def test_expectations_remote_and_optional(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'hosts.csv'
            inventory.write_text('host;user;port\nremote01;audit;22\n')
            expectations = root / 'expected.csv'
            expectations.write_text('host;resource;mountpoint;operator;value;unit\n'
                                    'remote01;cpu;;ge;999999;count\n')
            report = root / 'report.json'
            subprocess.run(['bash', str(SCRIPT), '--inventory', str(inventory),
                            '--expectations', str(expectations), '--json', str(report)],
                           env=dict(os.environ, PATH=directory + ':' + os.environ['PATH']),
                           capture_output=True, text=True)
            checks = json.loads(report.read_text())['servers'][0]['data']['expectations']
            self.assertEqual(len(checks), 1)
            self.assertEqual(checks[0]['status'], 'fail')
            self.assertEqual(checks[0]['expected'], 999999)

    def test_invalid_expectations_before_collection(self):
        rows = ['localhost;cpu;;ge;-1;count', 'localhost;ram;;ge;8;GB',
                'localhost;filesystem_available;/;ge;1;MiB',
                'localhost;filesystem_use;/;le;90;percent',
                'localhost;filesystem_size;relative;ge;1;MiB',
                'unknown;cpu;;ge;1;count', 'localhost;cpu;;wrong;1;count',
                'localhost;cpu;;ge;1;count\nlocalhost;cpu;;ge;2;count']
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for row in rows:
                with self.subTest(row=row):
                    expected = root / 'expectations.csv'
                    expected.write_text(row)
                    report = root / 'report.json'
                    result = subprocess.run(['bash', str(SCRIPT), '--localhost',
                                             '--expectations', str(expected), '--json', str(report)],
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, 2)
                    self.assertFalse(report.exists())

    def test_remote_transport_and_continuation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ssh = root / 'ssh'
            ssh.write_text('#!/bin/bash\ncase "$*" in *badhost*) printf partial; exit 255 ;; esac\nbash -s\n')
            ssh.chmod(0o755)
            inventory = root / 'hosts'
            inventory.write_text('host;user;port\nbadhost;;\ngoodhost;;\n')
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
