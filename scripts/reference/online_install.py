#!/usr/bin/env python3
"""Create a standalone example project; development tooling stays in this checkout."""
import argparse
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT = '''config_version=5
[application]
config/name="Fortress online example"
run/main_scene="res://examples/online/online.tscn"
[display]
window/size/viewport_width=760
window/size/viewport_height=640
[physics]
common/physics_ticks_per_second=60
[rendering]
renderer/rendering_method="gl_compatibility"
'''
PRESET = '''[preset.0]
name="Web"
platform="Web"
runnable=true
export_filter="all_resources"
include_filter=""
exclude_filter=""
[preset.0.options]
variant/extensions_support=false
variant/thread_support=false
'''


def install_sdk(project, sdk):
    source = sdk / 'addons/signal_fish'
    for filename in ('LICENSE', 'signal_fish_client.gd', 'signal_fish_config.gd', 'webrtc/sf_webrtc_mesh.gd'):
        if not (source / filename).is_file():
            raise ValueError('SDK installation is incomplete: ' + filename)
    shutil.copytree(source, project / 'addons/signal_fish')


def create_project(project, source=ROOT):
    if project.exists() and any(project.iterdir()):
        raise ValueError('destination must be an empty directory')
    project.mkdir(parents=True, exist_ok=True)
    for directory in ('addons/fortress_rollback', 'examples/offline', 'examples/online'):
        shutil.copytree(source / directory, project / directory)
    shutil.copyfile(source / 'LICENSE', project / 'LICENSE')
    (project / 'project.godot').write_text(PROJECT, encoding='utf-8')
    (project / 'export_presets.cfg').write_text(PRESET, encoding='utf-8')


def server_config(source, port):
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('server port must be between 1 and 65535')
    config = json.loads((source / 'config.example.json').read_text(encoding='utf-8'))
    config['port'] = port
    config['session'].update(default_topology='mesh', enable_webrtc=True, enable_direct=False, enable_ice_pregather=False, ice_servers=[])
    config['turn'].update(enabled=False, urls=[], stun_urls=[])
    config['security']['allowed_apps'][0].update(app_id='fortress-live-webrtc', app_name='Local WebRTC rollback example',
                                                max_players_per_room=2, rate_limit_per_minute=100000)
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument('--project', type=Path, help='empty destination, or installed project with --sdk')
    target.add_argument('--server-source', type=Path, help='print local server configuration for the pinned source')
    parser.add_argument('--sdk', type=Path, help='add the extracted SDK to an existing project')
    parser.add_argument('--port', type=int, default=8080)
    args = parser.parse_args()
    if args.server_source:
        if args.sdk:
            parser.error('--sdk requires --project')
        print(json.dumps(server_config(args.server_source, args.port), indent=2))
    elif args.sdk:
        if not (args.project / 'project.godot').is_file():
            raise ValueError('install the example project before adding the SDK')
        install_sdk(args.project, args.sdk)
    else:
        create_project(args.project)


if __name__ == '__main__':
    main()
