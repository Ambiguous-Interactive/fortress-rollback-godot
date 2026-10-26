"""Pinned browser identities for the real exported transport witness."""
import os
from pathlib import Path
import shutil
import zipfile

from fetch import CACHE, fetch

PAIRS = {'chromium': ('chromium', 'chromium'), 'firefox': ('firefox', 'firefox'),
         'chromium-firefox': ('chromium', 'firefox')}


def validate_identity(result, pair, pins):
    preferences = {'webgl.force-enabled': True, 'webgl.disabled': False} if 'firefox' in pair else None
    expected = [{'name': name, 'version': pins['browser'][name + '_version']} for name in pair]
    if (not isinstance(result, dict) or result.get('browsers') != expected
            or result.get('firefox_preferences') != preferences
            or result.get('browser') != '/'.join(pair) or result.get('version') != expected[0]['version']):
        raise ValueError('browser process identities differ from the selected pinned pair')
    for record in result.get('records', []):
        for index, peer in enumerate(record.get('peers', [])):
            display = peer.get('display')
            if pair[index % 2] == 'firefox':
                if (not isinstance(display, dict) or display.get('x') != 80 * index or type(display.get('x')) is not int
                        or display.get('y') != 0 or type(display.get('y')) is not int
                        or any(type(display.get(key)) is not int or not 1 <= display[key] <= 32768
                               for key in ('width', 'height', 'screen_width', 'screen_height'))
                        or display['width'] < 81 or display['screen_width'] <= display['x']):
                    raise ValueError('Firefox window visibility evidence invalid')
            elif display is not None:
                raise ValueError('headless Chromium cannot claim a displayed window')
            if peer.get('browser') != pair[index % 2]:
                raise ValueError('peer browser allocation differs from the selected pair')


def seed_firefox_runtime_lock(installation):
    # Firefox leaves this empty regular file after clean exit. Hash it from the
    # initial installation inventory instead of excluding runtime paths later.
    lock = installation / 'firefox/.parentlock'
    if installation.is_symlink() or lock.parent.is_symlink():
        raise ValueError('Firefox runtime lock parent must not be symlinked')
    try:
        with lock.open('xb'):
            pass
    except FileExistsError as failure:
        raise ValueError('Firefox runtime lock unexpectedly present in fresh archive') from failure


def prepare_firefox(pins, arch, offline, sources, environment, installation=None):
    if not os.environ.get('DISPLAY'):
        raise ValueError('Firefox WebGL witness requires DISPLAY; launch with xvfb-run -a')
    name = f"firefox-{pins['browser']['firefox_revision']}-ubuntu24.04-{arch}.zip"
    archive = fetch(pins['artifacts'][name], name, offline)
    # This archive is built for Ubuntu 24.04; fail explicitly on unsupported hosts.
    release = Path('/etc/os-release').read_text()
    if 'ID=ubuntu\n' not in release or 'VERSION_ID="24.04"' not in release:
        raise ValueError('pinned Firefox witness requires Ubuntu 24.04')
    installation = CACHE / 'webrtc-firefox' / arch if installation is None else Path(installation)
    if installation.exists():
        shutil.rmtree(installation)
    with zipfile.ZipFile(archive) as package:
        package.extractall(installation)
        for member in package.infolist():
            if not member.is_dir():
                (installation / member.filename).chmod((member.external_attr >> 16) & 0o777 or 0o644)
    seed_firefox_runtime_lock(installation)
    sources.update(firefox_archive=archive, firefox_installation=installation,
                   firefox_executable=installation / 'firefox/firefox')
    xdotool = shutil.which('xdotool')
    if xdotool is None:
        raise ValueError('Firefox WebGL witness requires xdotool for owned window placement')
    sources['xdotool'] = Path(xdotool).resolve()
    environment['FORTRESS_XDOTOOL_EXECUTABLE'] = str(sources['xdotool'])
    environment['FORTRESS_FIREFOX_EXECUTABLE'] = str(sources['firefox_executable'])
