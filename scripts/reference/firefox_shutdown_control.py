#!/usr/bin/env python3
"""Exercise Firefox shutdown; callers verify the supplied installation against the pinned archive."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import stat
import subprocess
import time

from fetch import MANIFEST, ROOT, digest, load_manifest
from ownership_probes import tool_inventory

LIMIT = 65536
MARKER = 'FORTRESS_LATE_PROFILE_LOCK '
SCRIPT = '''
Services.prefs.setIntPref("toolkit.shutdown.fastShutdownStage", arguments[0]);
const profiles = Cc["@mozilla.org/toolkit/profile-service;1"].getService(Ci.nsIToolkitProfileService);
const profile = profiles.createProfile(Services.dirsvc.get("ProfD", Ci.nsIFile), "fortress-shutdown-control", "control");
profile.rootDir = Services.dirsvc.get("GreD", Ci.nsIFile);
const marker = profile.rootDir.clone();
marker.append("lock");
Services.obs.addObserver(function lateLock() {
  Services.obs.removeObserver(lateLock, "profile-before-change");
  let before = false;
  try { before = marker.isSymlink(); }
  catch (error) { if (error.result !== Cr.NS_ERROR_FILE_NOT_FOUND) throw error; }
  globalThis.__fortressLateLock = profile.lock({});
  const acquired = globalThis.__fortressLateLock.directory.equals(profile.rootDir);
  dump("FORTRESS_LATE_PROFILE_LOCK " + JSON.stringify({before, acquired, after:marker.isSymlink(),
    stage:Services.prefs.getIntPref("toolkit.shutdown.fastShutdownStage")}) + "\\n");
}, "profile-before-change");
return Services.prefs.getIntPref("toolkit.shutdown.fastShutdownStage");
'''


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inventory(root):
    result = {}
    for entry in sorted(root.rglob('*')):
        key = entry.relative_to(root).as_posix()
        if entry.is_symlink():
            result[key] = {'symlink': os.readlink(entry)}
        elif entry.is_file():
            result[key] = {'sha256': digest(entry), 'mode': stat.S_IMODE(entry.stat().st_mode)}
        elif entry.is_dir():
            result[key] = {'directory': True, 'mode': stat.S_IMODE(entry.stat().st_mode)}
        else:
            raise ValueError('unsupported Firefox runtime entry')
    return result


def control_sources():
    paths = (Path(__file__).resolve(), Path(tool_inventory.__code__.co_filename).resolve(), Path(digest.__code__.co_filename).resolve(), MANIFEST)
    return {path.relative_to(ROOT).as_posix(): digest(path) for path in paths}


class Marionette:
    def __init__(self, connection, deadline):
        self.connection, self.deadline, self.sequence = connection, deadline, 0

    def receive(self):
        deadline = min(self.deadline, time.monotonic() + 15)

        def read(size):
            remaining = deadline - time.monotonic()
            require(remaining > 0, 'Marionette packet deadline exceeded')
            self.connection.settimeout(remaining)
            value = self.connection.recv(size)
            require(value, 'Marionette closed during a packet')
            return value

        header = b''
        while True:
            value = read(1)
            if value == b':':
                break
            require(value.isdigit() and len(header) < 6, 'invalid Marionette frame header')
            header += value
        require(header and 0 < int(header) <= LIMIT, 'invalid Marionette frame size')
        payload = b''
        while len(payload) < int(header):
            payload += read(int(header) - len(payload))
        return json.loads(payload.decode('utf-8'), parse_constant=lambda _: require(False, 'nonfinite Marionette JSON'))

    def call(self, command, arguments):
        self.sequence += 1
        payload = json.dumps([0, self.sequence, command, arguments]).encode('utf-8')
        require(len(payload) <= LIMIT, 'Marionette request too large')
        self.connection.settimeout(max(.001, min(15, self.deadline - time.monotonic())))
        self.connection.sendall(str(len(payload)).encode('ascii') + b':' + payload)
        response = self.receive()
        require(isinstance(response, list) and len(response) == 4 and all(type(value) is int for value in response[:2]) and
                response[:2] == [1, self.sequence], 'unexpected Marionette response')
        require(response[2] is None, 'Marionette command failed: ' + command + ': ' + json.dumps(response[2], ensure_ascii=True)[:400])
        return response[3]


def connect(process, port, deadline):
    deadline = min(deadline, time.monotonic() + 15)
    while process.poll() is None and time.monotonic() < deadline:
        try:
            return socket.create_connection(('127.0.0.1', port), timeout=min(1, max(.001, deadline - time.monotonic())))
        except OSError:
            time.sleep(.05)
    raise ValueError('Firefox Marionette readiness failed')


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def group_alive(group):
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit():
            try:
                fields = (entry / 'stat').read_bytes().rsplit(b')', 1)[1].split()
            except (FileNotFoundError, ProcessLookupError):
                continue
            if int(fields[2]) == group and fields[0] not in (b'Z', b'X'):
                return True
    return False


def wait_group(process, deadline):
    while time.monotonic() < deadline:
        process.poll()
        if not group_alive(process.pid):
            return True
        time.sleep(min(.01, max(0, deadline - time.monotonic())))
    return False


def cleanup_group(process, deadline):
    deadline = min(deadline, time.monotonic() + 1)
    signals = []
    for signum in (signal.SIGTERM, signal.SIGKILL):
        process.poll()
        if not group_alive(process.pid):
            return signals
        try:
            os.killpg(process.pid, signum)
            signals.append(signal.Signals(signum).name)
        except ProcessLookupError:
            pass
        if wait_group(process, min(deadline, time.monotonic() + (.2 if signum == signal.SIGTERM else 1))):
            return signals
    raise ValueError('Firefox process group cleanup timed out after ' + ','.join(signals))


def run_stage(source, output, work_dir, stage, expected_version, frozen, original):
    owned = output / f'stage-{stage}'
    owned.mkdir()
    work = work_dir / f'stage-{stage}'
    work.mkdir()
    runtime, profile = work / 'firefox', work / 'profile'
    shutil.copytree(source, runtime)
    require(tool_inventory({'installation': runtime}) == frozen, 'copied Firefox runtime differs')
    before = inventory(runtime)
    require(before == original, 'copied Firefox entry inventory differs')
    save(owned / 'before.json', before)
    profile.mkdir()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    prefs = {'marionette.port': port, 'browser.startup.homepage': 'about:blank', 'app.update.auto': False}
    (profile / 'user.js').write_text(''.join(f'user_pref({json.dumps(k)}, {json.dumps(v)});\n' for k, v in prefs.items()), encoding='utf-8')
    receipt = {'lock_mechanism': 'nsIToolkitProfile.lock', 'stage': stage, 'profile_preferences': prefs, 'runtime_preferences': {'toolkit.shutdown.fastShutdownStage': stage}}
    process = None
    try:
        with (owned / 'browser.log').open('wb') as log:
            cleanup_deadline = time.monotonic() + 30
            process = subprocess.Popen([str(runtime / 'firefox'), '--headless', '--no-remote', '--marionette', '--remote-allow-system-access',
                                        '--profile', str(profile), 'about:blank'], stdout=log, stderr=log, start_new_session=True)
            deadline = cleanup_deadline - 1
            with connect(process, port, deadline) as connection:
                peer = Marionette(connection, deadline)
                require(peer.receive() == {'applicationType': 'gecko', 'marionetteProtocol': 3}, 'unexpected Marionette handshake')
                session = peer.call('WebDriver:NewSession', {'capabilities': {'alwaysMatch': {'acceptInsecureCerts': False}}})
                capabilities = session['capabilities']
                require(capabilities['browserVersion'] == expected_version and capabilities['moz:processID'] == process.pid, 'unexpected Firefox identity')
                receipt['capabilities'] = capabilities
                peer.call('Marionette:SetContext', {'value': 'chrome'})
                readback = peer.call('WebDriver:ExecuteScript', {'script': SCRIPT, 'args': [stage], 'newSandbox': False, 'sandbox': 'system'})
                require(isinstance(readback, dict) and type(readback.get('value')) is int and readback == {'value': stage},
                        'shutdown preference was not applied')
                receipt['actual_stage_before_quit'] = readback['value']
                peer.call('Marionette:Quit', {'flags': ['eForceQuit']})
            require(process.wait(timeout=max(.001, min(15, deadline - time.monotonic()))) == 0, 'Firefox did not exit normally')
            require(wait_group(process, deadline), 'Firefox descendants outlived normal shutdown')
        callbacks = [json.loads(line[len(MARKER):]) for line in (owned / 'browser.log').read_text(encoding='utf-8').splitlines() if line.startswith(MARKER)]
        require(callbacks == [{'before': False, 'acquired': True, 'after': True, 'stage': stage}], 'late native profile lock was not exercised')
        require(all(type(callbacks[0][key]) is bool for key in ('before', 'acquired', 'after')) and type(callbacks[0]['stage']) is int,
                'invalid late native profile lock observation')
        after = inventory(runtime)
        save(owned / 'after.json', after)
        if stage == 1:
            target = os.readlink(runtime / 'lock')
            require(target.endswith(':+' + str(process.pid)), 'updater lock names another process')
            require(after == {**before, 'lock': {'symlink': target}}, 'unexpected runtime change in the fast-shutdown control')
            try:
                tool_inventory({'installation': runtime})
            except ValueError as error:
                require(str(error) == 'ownership runtime input is symlinked: installation/lock', 'unexpected runtime rejection')
                receipt['runtime_guard'] = {'accepted': False, 'error': str(error)}
            else:
                raise ValueError('runtime guard accepted the retained lock')
        else:
            require(after == before and tool_inventory({'installation': runtime}) == frozen, 'complete shutdown changed the runtime')
            receipt['runtime_guard'] = {'accepted': True}
        receipt.update(passed=True, exit_code=process.returncode, callback=callbacks[0])
    except Exception as error:
        receipt.update(passed=False, error=str(error)[:300])
        raise
    finally:
        try:
            if process is not None:
                receipt['cleanup_signals'] = cleanup_group(process, cleanup_deadline)
                require(not receipt.get('passed') or not receipt['cleanup_signals'], 'normal shutdown required forced cleanup')
        except Exception as error:
            receipt.update(passed=False, cleanup_error=str(error)[:300])
            raise
        finally:
            save(owned / 'after.json', inventory(runtime))
            save(owned / 'receipt.json', receipt)
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--firefox', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--work-dir', required=True, type=Path)
    args = parser.parse_args()
    require(not args.firefox.is_symlink(), 'Firefox executable must not be symlinked')
    executable, output, work_dir = args.firefox.resolve(strict=True), args.output.resolve(), args.work_dir.resolve()
    source = executable.parent
    require(executable.name == 'firefox' and (source / 'application.ini').is_file() and (source / 'omni.ja').is_file(), 'expected a Firefox installation')
    require(not output.is_relative_to(source) and not source.is_relative_to(output), 'output overlaps Firefox installation')
    require(not any(work_dir.is_relative_to(path) or path.is_relative_to(work_dir) for path in (source, output)), 'work directory overlaps inputs or output')
    frozen = tool_inventory({'installation': source})
    require((source / '.parentlock').read_bytes() == b'', 'expected preseeded empty Firefox runtime lock')
    output.mkdir(parents=True)
    work_dir.mkdir(parents=True)
    frozen_sources = control_sources()
    save(output / 'control-sources.json', frozen_sources)
    original = inventory(source)
    save(output / 'original.json', original)
    try:
        receipts = []
        for stage in (1, 0):
            require(control_sources() == frozen_sources, 'shutdown-control source changed')
            receipts.append(run_stage(source, output, work_dir, stage, load_manifest()['browser']['firefox_version'], frozen, original))
        require(tool_inventory({'installation': source}) == frozen and inventory(source) == original, 'original Firefox runtime changed')
        require(control_sources() == frozen_sources, 'shutdown-control source changed')
        save(output / 'result.json', {'passed': True, 'stages': receipts, 'sources': frozen_sources})
        print(json.dumps({'passed': True, 'stages': [receipt['stage'] for receipt in receipts]}))
    finally:
        save(output / 'original-after.json', inventory(source))


if __name__ == '__main__':
    main()
