"""Run the shared production behavior and the candidate's internal epoch probes."""

import json
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

from drop_failover import check_godot, check_schedule, check_source
from drop_history_contract import require, same
from fetch import CACHE, ROOT, digest
from launch import execute
from run import rust_environment
from source_wire import decode_trace

SCHEDULE = ROOT / 'scripts/oracle/drop_failover_schedule.json'
PROBES = ROOT / 'tests/oracle/drop_failover_source_tests.rs'
RUST_OBSERVER = ROOT / 'scripts/oracle/rust/src/bin/drop_history/failover.rs'
RECEIPT = 'coordinator-failover-receipt.json'


def candidate_probes(tools, source_tree, output, *, offline):
    anchor = '    #[test]\n    fn fallback_promotion_waits_for_grace_and_skips_two_survivors()'
    with TemporaryDirectory(dir=CACHE, prefix='drop-failover-') as temporary:
        staged = Path(temporary) / source_tree.name
        shutil.copytree(source_tree, staged)
        session = staged / 'src/sessions/p2p_session.rs'
        original = session.read_text()
        require(original.count(anchor) == 1, 'candidate test module anchor')
        shutil.copyfile(PROBES, session.with_name(PROBES.name))
        session.write_text(original.replace(anchor, f'    include!("{PROBES.name}");\n\n' + anchor))
        command = [str(tools['cargo']), 'test', '--locked', '--no-default-features', '--manifest-path', str(staged / 'Cargo.toml'),
                   '--target-dir', str(CACHE / 'target/drop-failover-probes'), '--lib', 'scoped_candidate_failover_']
        if offline:
            command.append('--offline')
        command += ['--', '--nocapture', '--test-threads=1']
        # Cargo receives the same pinned rustc as the public-path observer.
        environment = rust_environment()
        environment['RUSTC'] = str(tools['rustc'])
        environment.pop('CARGO_BUILD_RUSTC', None)
        results = []
        for repeat in (1, 2):
            stdout, stderr = execute(command, output / f'candidate-boundaries-{repeat}.log', timeout=600, environment=environment)
            require('test result: ok. 2 passed; 0 failed;' in stdout, 'candidate unit probe completion')
            prefix = 'SOURCE_FAILOVER_PROBE '
            results.append([decode_trace(line[len(prefix):]) for line in stderr.splitlines() if line.startswith(prefix)])
    require(same(*results), 'candidate boundary and replay evidence repeat')
    grace = [{'offset_us': offset, 'local': peer, 'heard_us': heard,
              'acting': 1 if peer == 1 and heard == 0 and offset >= 1_000_000 else None}
             for offset in (999_999, 1_000_000, 1_000_001) for peer, heard in ((1, 0), (1, 10_000), (2, 0))]
    require(same(results[0][:-1], grace), 'exact grace and authority matrix')
    retry = results[0][-1]
    require(all(retry[key] == value for key, value in {'from': 0, 'to': 1, 'target': 4, 'first_epoch': 0,
                                                      'retry_epoch': 1, 'sequence': 1, 'cut': None}.items()),
            'old addressed controls leave same-sequence epoch-one retry open without a cut')
    for name, kind, epoch in [('old_prepare', 18, 0), ('old_inventory', 19, 0), ('retry_prepare', 18, 1), ('retry_inventory', 19, 1)]:
        packet = bytes.fromhex(retry[name])
        require(packet.startswith(b'\xf5\x52\x06\x00') and packet[8:12] == kind.to_bytes(4, 'little')
                and packet[16:20] == b'\x01\x00\x00\x00' and packet[36:40] == epoch.to_bytes(4, 'little'),
                'addressed encoded replay operation')
    return {'grace': grace, 'retry': retry}


def observe(engine, binary, output, parse_godot, tools, source_tree, offline):
    schedule = decode_trace(SCHEDULE.read_text())
    check_schedule(schedule)
    observations = []
    artifacts = {}
    for repeat in (1, 2):
        log = output / f'failover-source-{repeat}.log'
        stdout, stderr = execute([str(binary), '--coordinator-failover', str(SCHEDULE)], log)
        require(not stderr.strip(), 'candidate observer stderr')
        source = decode_trace(stdout)
        artifacts[log.name] = digest(log)
        log = output / f'failover-godot-{repeat}.log'
        stdout, stderr = execute([str(engine), '--headless', '--path', str(ROOT), '--script', 'res://tests/oracle/drop_failover_trace.gd',
                                  '--', str(SCHEDULE)], log)
        godot = parse_godot(stdout, stderr, 'GODOT_FAILOVER ')
        artifacts[log.name] = digest(log)
        observations.append((source, godot))
    require(same(*observations), 'shared physical schedule repeats in fresh processes')
    source, godot = observations[0]
    evidence = {'source': check_source(source, schedule), 'godot': check_godot(godot, schedule)}
    evidence['negative_controls'] = negative_controls(source, godot, schedule)
    evidence['candidate_tests'] = candidate_probes(tools, source_tree, output, offline=offline)
    for repeat in (1, 2):
        log = output / f'candidate-boundaries-{repeat}.log'
        artifacts[log.name] = digest(log)
    return {'schedule': schedule, 'evidence': evidence, 'artifact_sha256': artifacts, 'fresh_process_repeat_equal': True}


def negative_controls(source, godot, schedule):
    cases = [(check_source, source, source['received'][0], 'to', 4, 'receipt retains original addressed'),
             (check_source, source, source['after'][0]['rows'][0], 'bytes', '00', 'original five-slot input'),
             (check_source, source, source['dropped'][0], 'peer', 2, 'all three source survivors'),
             (check_godot, godot, godot['terminal']['1'], 'at_us', 0, 'Godot terminal protocol failure')]
    rejected = []
    for check, trace, record, key, mutation, diagnostic in cases:
        original = record[key]
        record[key] = mutation
        try:
            check(trace, schedule)
        except ValueError as error:
            require(diagnostic in str(error), 'negative control diagnostic: ' + str(error))
            rejected.append(diagnostic)
        else:
            raise ValueError('accepted invalid failover evidence: ' + diagnostic)
        finally:
            record[key] = original
    return rejected
