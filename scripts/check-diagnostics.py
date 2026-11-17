#!/usr/bin/env python3
"""Check the actual shared CLI in isolated data; never collect a user's logs."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='.build/debug/tide-island-bridge')
    parser.add_argument('--temporary-root')
    args = parser.parse_args()
    binary = str(Path(args.binary).resolve(strict=True))
    environment = {'PATH': os.defpath, 'LANG': 'en_US.UTF-8'}
    checks = 0
    with tempfile.TemporaryDirectory(prefix='tide-diagnostics-', dir=args.temporary_root) as directory:
        root = Path(directory)

        def call(*argv):
            return subprocess.run([binary, *argv], env=environment, capture_output=True, text=True, timeout=20)

        def report(*argv):
            result = call('diagnostics', *argv)
            assert result.returncode == 0 and not result.stderr, result.stderr
            assert len(result.stdout.encode()) <= 16 * 1024
            return json.loads(result.stdout)

        def snapshot():
            return {str(p.relative_to(root)): p.read_bytes() for p in root.rglob('*') if p.is_file() and not p.is_symlink()}

        default = report()
        assert default['scope'] == 'versionsOnly' and 'inventory' not in default and 'sessions' not in default
        assert default['versions']['codexContract'] == '0.169.0'
        assert not default['versions']['installedCodexQueried'] and not default['nativeRuntimeVerified']
        checks += 1
        inbox = root / 'Events'
        for index in range(2):
            result = call('emit', '--session', 'private-session', '--project', 'private-project',
                          '--phase', 'working', '--inbox', str(inbox))
            assert result.returncode == 0, result.stderr
        (inbox / '11111111-1111-1111-1111-111111111111.json').write_text('private-body')
        before = snapshot()
        inventory = report('--inbox', str(inbox))
        assert inventory['scope'] == 'offlineInventory' and inventory['inventory']['acceptedEventFiles'] == 2
        assert inventory['inventory']['rejectionCounts'] == {'malformed': 1}
        assert not inventory['inventory']['runtimeStateAssessed'] and 'sessions' not in inventory
        serialized = json.dumps(inventory)
        for forbidden in ['private-', str(root), '11111111-1111-1111-1111-111111111111']:
            assert forbidden not in serialized
        assert snapshot() == before
        checks += 1
        missing = root / 'missing'
        failure = report('--inbox', str(missing))
        assert failure['inventory']['state'] == 'unavailable' and failure['inventory']['problem'] == 'unsafeDirectory'
        assert 'acceptedEventFiles' not in failure['inventory'] and not missing.exists()
        checks += 1
        failure = report('--inbox', str(inbox), '--scan-limit', '1')
        assert failure['inventory']['problem'] == 'limitExceeded' and 'acceptedEventFiles' not in failure['inventory']
        assert snapshot() == before
        checks += 1
        for argv in [('--inbox', 'relative'), ('--output', 'relative.json'), ('--scan-limit', '2'),
                     ('--inbox', str(inbox), '--scan-limit', '0'), ('--inbox', str(inbox), '--read-budget-bytes', '0'),
                     ('--unknown', 'private-value'), ('--inbox', str(inbox), '--inbox', str(inbox))]:
            result = call('diagnostics', *argv)
            assert result.returncode != 0 and not result.stdout and 'private-value' not in result.stderr
        checks += 1
        output = root / 'report.json'
        saved = report('--inbox', str(inbox), '--output', str(output))
        assert saved == {'exported': True, 'schema_version': 1}
        assert stat.S_IMODE(output.stat().st_mode) == 0o600
        assert json.loads(output.read_text())['scope'] == 'offlineInventory'
        saved_bytes = output.read_bytes()
        checks += 1
        result = call('diagnostics', '--output', str(output))
        assert result.returncode != 0 and not result.stdout and output.read_bytes() == saved_bytes
        assert str(root) not in result.stderr
        checks += 1
        for destination in [inbox / 'report.json', root / 'State' / 'report.json']:
            result = call('diagnostics', '--inbox', str(inbox), '--output', str(destination))
            assert result.returncode != 0 and not result.stdout and not destination.exists()
        checks += 1
        alias = root / 'alias'
        alias.symlink_to(inbox, target_is_directory=True)
        result = call('diagnostics', '--inbox', str(inbox), '--output', str(alias / 'report.json'))
        assert result.returncode != 0 and not result.stdout
        checks += 1
        linked = root / 'linked.json'
        linked.symlink_to(output)
        result = call('diagnostics', '--output', str(linked))
        assert result.returncode != 0 and output.read_bytes() == saved_bytes
        checks += 1
        capability = call('capabilities')
        assert capability.returncode == 0
        diagnostic = json.loads(capability.stdout)['diagnostics']
        assert diagnostic['schema_version'] == 1 and diagnostic['default_scope'] == 'versionsOnly'
        assert not diagnostic['uploads'] and not diagnostic['writes_source_data']
        checks += 1
    print(json.dumps({'status': 'passed', 'checks': checks, 'scope': 'isolated-shared-cli', 'native_verified': False}))


if __name__ == '__main__':
    main()
