"""Value: reject exported qualification receipts without complete physical and canonical evidence."""
import copy
import io
import sys
from unittest import mock
import unittest
import subprocess
import shutil
import json
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace

from spectator_browser import validate, validate_fault, validate_departure, validate_host_departure


class SpectatorBrowserTests(unittest.TestCase):
    def test_acceptance_delay_requires_a_scenario_that_reaches_acceptance(self):
        import signalfish_spectator_live as launcher
        for fault in [None, 'viewer-departure', 'host-departure', 'initial-state', 'room-identity']:
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as folder:
                arguments = ['spectator', '--godot', 'unused', '--server', 'unused', '--server-source', 'unused',
                             '--build-receipt', 'unused', '--output', folder, '--browser-viewer', '--acceptance-delay-ms', '1500']
                if fault is not None:
                    arguments += ['--browser-fault', fault]
                with mock.patch.object(sys, 'argv', arguments), mock.patch.object(launcher, 'run') as run, mock.patch('sys.stderr', io.StringIO()):
                    if fault in ['initial-state', 'room-identity']:
                        with self.assertRaisesRegex(SystemExit, '2'):
                            launcher.main()
                        run.assert_not_called()
                    else:
                        launcher.main()
                        run.assert_called_once()

    @unittest.skipUnless(shutil.which('node'), 'Node is required for acceptance process controls')
    # Value: real Node entrypoint rejects held-frame progress and completion before the application HTTP callback.
    def test_acceptance_process_observes_frame_progress_and_actual_acknowledgment(self):
        source = Path(__file__).parent / 'browser/spectator_acceptance.cjs'
        stub = """
const {EventEmitter}=require('node:events');
const fs=require('node:fs');
const failure={reason:'original acceptance operation failed',[require('node:util').inspect.custom](){
  fs.writeFileSync(process.env.FORTRESS_INSPECT_MARKER,'executed');throw Error('custom inspection replaced original failure');
}};
const page=new EventEmitter();
global.window={WebSocket:class {constructor(){this.readyState=1;}close(){this.readyState=3;}}};
page.addInitScript=async(fn,data)=>fn(data);
let route;
page.route=async(_pattern,callback)=>{route=callback;};
page.isClosed=()=>false;
let numericReads=0;
page.evaluate=async(fn,data)=>{
  const value=fn(data);
  if(Number.isSafeInteger(value)) {
    numericReads++;
    if(process.env.FORTRESS_TEST_ACCEPTANCE_MODE==='microtask-progress' && numericReads===2) {
      queueMicrotask(()=>{window.fortressSpectatorFrame=1;});
    }
  }
  return value;
};
page.waitForFunction=async fn=>{if(!fn())throw Error('fixture readiness failed');};
page.goto=async()=>{
  const mode=process.env.FORTRESS_TEST_ACCEPTANCE_MODE;
  window.fortressSpectatorFrame=0;
  window.fortressSpectatorAcceptAcknowledged=false;
  new window.WebSocket();
  const finish=()=>{
    if(mode==='early-departure')window.fortressSpectatorDepartureReady=true;
    if(mode==='early-success')window.fortressSpectatorResult={passed:true};
    window.fortressSpectatorAcceptAcknowledged=true;
    window.fortressSpectatorFrame=8;
    window.fortressSpectatorDepartureReady=true;
    window.fortressSpectatorResult={passed:true};
  };
  if(mode==='no-injection'){finish();return;}
  await route({
    fetch:async()=>{if(mode==='held-progress')window.fortressSpectatorFrame=1;return {};},
    fulfill:async()=>{
      if(mode==='microtask-progress' && window.fortressSpectatorFrame!==1)throw Error('frame race injection did not run');
      finish();
      if(mode==='ack-progress-before-return')await new Promise(resolve=>setImmediate(resolve));
    }
  });
};
const browser={newContext:async()=>{
  if(process.env.FORTRESS_TEST_ACCEPTANCE_MODE==='malicious-inspect')throw failure;
  return {newPage:async()=>page};
},version:()=> 'stub',close:async()=>{}};
module.exports={chromium:{launch:async()=>browser}};
"""
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder)
            package = directory / 'playwright.cjs'
            package.write_text(stub, encoding='utf-8')
            marker = directory / 'inspection-ran'
            runtime = directory / 'runtime.json'
            runtime.write_text(json.dumps({'browser_fault': 'viewer-departure'}), encoding='utf-8')
            for mode, expected_error in [('healthy', None), ('ack-progress-before-return', None),
                                         ('held-progress', 'playback advanced before acceptance acknowledgment'),
                                         ('microtask-progress', 'playback advanced before acceptance acknowledgment'),
                                         ('early-departure', 'playback completed before acceptance acknowledgment'),
                                         ('early-success', 'playback completed before acceptance acknowledgment'),
                                         ('no-injection', 'acceptance response hold was not observed'),
                                         ('malicious-inspect', 'original acceptance operation failed')]:
                environment = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(package), 'FORTRESS_ACCEPT_DELAY_MS': '1',
                               'FORTRESS_TEST_ACCEPTANCE_MODE': mode, 'FORTRESS_INSPECT_MARKER': str(marker)}
                result = subprocess.run(['node', str(source.resolve()), 'http://fixture.invalid', str(runtime)], env=environment,
                                        capture_output=True, encoding='utf-8', timeout=10)
                with self.subTest(mode=mode):
                    self.assertFalse(marker.exists(), 'custom inspection hook must not run')
                    self.assertEqual(result.returncode, 0 if expected_error is None else 1)
                    if expected_error is None:
                        self.assertEqual(result.stderr, '')
                        self.assertEqual(json.loads(result.stdout)['errors'], [])
                    else:
                        self.assertIn(expected_error, result.stderr)

    @unittest.skipUnless(shutil.which('node'), 'Node is required for route ownership process controls')
    def test_acceptance_routes_remain_owned_and_redact_capabilities(self):
        directory = Path(__file__).parent / 'browser'
        stub = r"""
const fs=require('node:fs'),{EventEmitter}=require('node:events');
const phase=process.env.FORTRESS_ROUTE_PHASE;
const reason=phase==='undefined'?undefined:Error('route-'+phase+'-safe\nAuthorization: Bearer REVIEW_SENTINEL\nruntime RUNTIME_CAPABILITY_SENTINEL');
const second=Error('second-route-safe');
const cleanup=Error('cleanup-safe\nAuthorization: Bearer REVIEW_SENTINEL');
const operation=Error('operation-safe');
const stats={closes:0,finished:false};
global.fixture={reason,second,cleanup,operation,stats};
global.window={WebSocket:class {}};
const page=new EventEmitter();
let handler,evaluations=0;
page.addInitScript=async(fn,data)=>fn(data);
page.route=async(_pattern,callback)=>{handler=callback;};
page.isClosed=()=>false;
page.evaluate=async(fn,data)=>{
  evaluations++;
  if((phase==='evaluate' && evaluations===1) || (phase==='release' && evaluations===2))throw reason;
  return fn(data);
};
page.waitForFunction=()=>new Promise(()=>{});
page.goto=async()=>{
  window.fortressSpectatorFrame=0;
  window.fortressSpectatorAcceptAcknowledged=false;
  const start=currentReason=>handler({fetch:async()=>{
    if(phase.startsWith('late'))await new Promise(resolve=>setTimeout(resolve,phase==='late-after-close'?30:8));
    if(['fetch','undefined','late','late-after-close','late-multiple'].includes(phase))throw currentReason;
    return {};
  },fulfill:async()=>{if(phase==='fulfill')throw reason;}});
  start(reason);
  if(phase==='late-multiple')start(second);
  if(phase.startsWith('late'))throw operation;
  return new Promise(()=>{});
};
const browser={newContext:async()=>({newPage:async()=>page}),version:()=> 'stub',close:async()=>{
  stats.closes++;
  await new Promise(resolve=>setTimeout(resolve,phase==='late-after-close'?2:15));
  stats.finished=true;
  if(process.env.FORTRESS_ROUTE_CLOSE_FAILURE==='1')throw cleanup;
}};
module.exports={chromium:{launch:async()=>browser}};
"""
        script = """
const fs=require('node:fs'),path=require('node:path');
const directory=process.argv[1],runtime=process.argv[2],report=process.argv[3];
const runner=require(path.join(directory,'spectator.cjs')),run=runner.run;
runner.run=async signal=>{
  try {return await run(signal);} catch(error) {
    const values=[];
    const visit=value=>{if(value instanceof AggregateError)value.errors.forEach(visit);else values.push(value);};
    visit(error);
    const fixture=global.fixture;
    fs.writeFileSync(report,JSON.stringify({route:values.includes(fixture.reason),cleanup:values.includes(fixture.cleanup),
      operation:values.includes(fixture.operation),second:values.includes(fixture.second),singleIdentity:error===fixture.reason,...fixture.stats}));
    throw error;
  }
};
process.argv=['node',path.join(directory,'spectator_acceptance.cjs'),'http://fixture.invalid',runtime];
require(path.join(directory,'spectator_acceptance.cjs'));
"""
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            package = temporary / 'playwright.cjs'
            package.write_text(stub, encoding='utf-8')
            runtime = temporary / 'runtime.json'
            runtime.write_text(json.dumps({'viewer_token': 'RUNTIME_CAPABILITY_SENTINEL'}), encoding='utf-8')
            for phase in ['fetch', 'evaluate', 'release', 'fulfill', 'undefined', 'late', 'late-after-close', 'late-multiple']:
                for close_failure in [False, True]:
                    report = temporary / (phase + str(close_failure) + '.json')
                    environment = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(package), 'FORTRESS_ACCEPT_DELAY_MS': '1',
                                   'FORTRESS_ROUTE_PHASE': phase, 'FORTRESS_ROUTE_CLOSE_FAILURE': str(int(close_failure))}
                    result = subprocess.run(['node', '--unhandled-rejections=strict', '-e', script, str(directory.resolve()), str(runtime), str(report)],
                                            env=environment, capture_output=True, encoding='utf-8', timeout=10)
                    with self.subTest(phase=phase, close_failure=close_failure):
                        self.assertEqual(result.returncode, 1)
                        self.assertTrue(report.exists(), 'the runner owner must receive the route failure')
                        observed = json.loads(report.read_text(encoding='utf-8'))
                        self.assertTrue(observed['route'], 'the original route reason must reach the owner unchanged')
                        self.assertEqual(observed['cleanup'], close_failure)
                        self.assertEqual(observed['operation'], phase.startswith('late'))
                        self.assertEqual(observed['second'], phase == 'late-multiple')
                        self.assertEqual(observed['closes'], 1)
                        self.assertTrue(observed['finished'])
                        if not close_failure and not phase.startswith('late'):
                            self.assertTrue(observed['singleIdentity'])
                        self.assertIn('runnerFailurePhase', json.loads(result.stdout))
                        self.assertNotIn('REVIEW_SENTINEL', result.stdout + result.stderr)
                        self.assertNotIn('RUNTIME_CAPABILITY_SENTINEL', result.stdout + result.stderr)
                        self.assertNotIn('triggerUncaughtException', result.stderr)
                        self.assertIn('undefined' if phase == 'undefined' else 'route-' + phase + '-safe', result.stderr)

    @unittest.skipUnless(shutil.which('node'), 'Node is required for external failure process controls')
    def test_external_failure_prevents_ready_calls_publishing_success(self):
        source = Path(__file__).parent / 'browser/spectator.cjs'
        stub = """
const {EventEmitter}=require('node:events');
const page=new EventEmitter();
const rpc=name=>{global.trace.push(name);if(global.observedStop)global.lateRPCs.push(name);};
page.addInitScript=async()=>{rpc('addInitScript');};page.goto=async()=>{rpc('goto');};page.waitForFunction=async()=>{rpc('waitForFunction');};
let reads=0;
page.evaluate=async()=>{rpc('evaluate');return ++reads===1?{passed:true}:undefined;};
const browser={newContext:()=>{
  rpc('newContext');
  const pending=Promise.resolve({newPage:async()=>{rpc('newPage');return page;}});
  if(process.env.FORTRESS_EXTERNAL_PHASE.endsWith('context-gap'))pending.then(()=>queueMicrotask(()=>global.rejectExternal(global.originalReason)));
  return pending;
},
  version:()=>{
    if(process.env.FORTRESS_EXTERNAL_PHASE.endsWith('double-report'))queueMicrotask(()=>queueMicrotask(()=>global.rejectExternal(global.originalReason)));
    else if(process.env.FORTRESS_EXTERNAL_PHASE.endsWith('report'))global.rejectExternal(global.originalReason);
    return 'stub';
  },
  close:async()=>{global.closeCalls++;}};
module.exports={chromium:{launch:async()=>browser}};
"""
        script = """
const fs=require('node:fs'),source=process.argv[1],runtime=process.argv[2],report=process.argv[3];
global.originalReason=process.env.FORTRESS_EXTERNAL_PHASE.startsWith('undefined')?undefined:Error('external operation failed');global.closeCalls=0;
global.trace=[];global.lateRPCs=[];global.observedStop=false;
const signal=new Promise((_resolve,reject)=>{global.rejectExternal=reject;});
signal.catch(()=>{global.observedStop=true;global.trace.push('signal-observed');});
if(process.env.FORTRESS_EXTERNAL_PHASE.endsWith('ready'))global.rejectExternal(global.originalReason);
process.argv=['node',source,'http://fixture.invalid',runtime];
require(source).run(signal).catch(error=>{
  fs.writeFileSync(report,JSON.stringify({same:error===global.originalReason,closes:global.closeCalls,lateRPCs:global.lateRPCs,trace:global.trace}));process.exitCode=1;
});
"""
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)
            package = temporary / 'playwright.cjs'
            package.write_text(stub, encoding='utf-8')
            runtime = temporary / 'runtime.json'
            runtime.write_text('{}', encoding='utf-8')
            for phase in ['ready', 'report', 'context-gap', 'double-report',
                          'undefined-ready', 'undefined-report', 'undefined-context-gap', 'undefined-double-report']:
                identity = temporary / (phase + '.json')
                result = subprocess.run(['node', '--unhandled-rejections=strict', '-e', script, str(source.resolve()), str(runtime), str(identity)],
                                        env={**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(package), 'FORTRESS_EXTERNAL_PHASE': phase},
                                        capture_output=True, encoding='utf-8', timeout=10)
                with self.subTest(phase=phase):
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stderr, '')
                    observed = json.loads(identity.read_text(encoding='utf-8'))
                    self.assertTrue(observed['same'])
                    self.assertEqual(observed['closes'], 1)
                    self.assertEqual(observed['lateRPCs'], [], observed['trace'])
                    self.assertIn('runnerFailurePhase', json.loads(result.stdout))

    @unittest.skipUnless(shutil.which('node'), 'Node is required for browser process controls')
    def test_runner_process_rejects_active_request_failure(self):
        source = Path(__file__).parent / 'browser/spectator.cjs'
        scratch = Path(__file__).resolve().parents[2] / '.cache/scratch'
        scratch.mkdir(parents=True, exist_ok=True)
        stub = """
const {EventEmitter}=require('node:events');
const page=new EventEmitter();
page.addInitScript=async()=>{};
page.goto=async()=>{if(process.env.FORTRESS_TEST_REQUEST_FAILURE==='1')page.emit('requestfailed',{});};
page.waitForFunction=async()=>{};
let reads=0;
page.evaluate=async()=>++reads===1?{passed:true}:undefined;
const browser={newContext:async()=>({newPage:async()=>page}),version:()=> 'stub',close:async()=>page.emit('requestfailed',{})};
module.exports={chromium:{launch:async()=>browser}};
"""
        with tempfile.TemporaryDirectory(prefix='spectator-request-', dir=scratch) as folder:
            directory = Path(folder)
            package = directory / 'playwright.cjs'
            package.write_text(stub, encoding='utf-8')
            runtime = directory / 'runtime.json'
            runtime.write_text('{}', encoding='utf-8')
            for failure in [False, True]:
                environment = {**os.environ, 'FORTRESS_PLAYWRIGHT_PACKAGE': str(package), 'FORTRESS_TEST_REQUEST_FAILURE': '1' if failure else '0'}
                result = subprocess.run(['node', str(source.resolve()), 'http://fixture.invalid', str(runtime)], env=environment,
                                        capture_output=True, encoding='utf-8', timeout=10)
                with self.subTest(failure=failure):
                    self.assertEqual(result.stderr, '')
                    self.assertEqual(result.returncode, 1 if failure else 0)
                    report = json.loads(result.stdout)
                    self.assertIs(report['result']['passed'], True)
                    self.assertEqual(report['errors'], ['browser request failed'] if failure else [])

    @unittest.skipUnless(shutil.which('node'), 'Node is required for browser event controls')
    def test_request_failures_are_fatal_until_deliberate_teardown(self):
        source = Path(__file__).parent / 'browser/spectator.cjs'
        script = """
const assert=require('node:assert/strict');
const {EventEmitter}=require('node:events');
const {observeErrors}=require(process.argv[1]);
const page=new EventEmitter(), errors=[];
let closing=false;
observeErrors(page,errors,()=>closing);
page.emit('pageerror',new Error('page failure'));
page.emit('console',{type:()=> 'log',text:()=> 'ignored'});
page.emit('console',{type:()=> 'error',text:()=> 'console failure'});
assert.deepEqual(errors,['page failure','console failure']);
page.emit('requestfailed',{});
assert.equal(errors.length,3,'active request failure must be captured');
closing=true;
page.emit('requestfailed',{});
assert.equal(errors.length,3,'deliberate close must not invent a request failure');
"""
        result = subprocess.run(['node', '-e', script, str(source.resolve())], capture_output=True, encoding='utf-8', timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fault_requires_no_acceptance_completion_or_playback(self):
        browser = {'browser': 'Chromium', 'version': '156.0', 'errors': [],
                   'result': {'passed': False, 'reason': 'browser original-state or membership binding', 'errors': []},
                   'state': {'compared': 0, 'frame': 0, 'simulations': 0, 'accept_pending': False, 'accept_delivered': False}}
        control = SimpleNamespace(accepted_once=False, received=0, done=None)
        validate_fault(1, browser, True, control)
        with self.assertRaises(ValueError):
            validate_fault(1, browser, True, control, 'late browser teardown failure')
        for changes in [{'accepted_once': True}, {'received': 1}, {'done': {}}, {'done': {'complete': True}}]:
            with self.subTest(control=changes), self.assertRaises(ValueError):
                validate_fault(1, browser, True, SimpleNamespace(**{**vars(control), **changes}))
        for field, value in browser['state'].items():
            for bad in [None, True if type(value) is int else 1, 1 if type(value) is int else True, float(value)]:
                with self.subTest(field=field, value=bad), self.assertRaises(ValueError):
                    validate_fault(1, {**browser, 'state': {**browser['state'], field: bad}}, True, control)
        for changes in [{'state': None}, {'state': {}}, {'errors': ['late failure']}, {'result': {}}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_fault(1, {**browser, **changes}, True, control)
        for code, alive in [(0, True), (1, False)]:
            with self.subTest(code=code, alive=alive), self.assertRaises(ValueError):
                validate_fault(code, browser, alive, control)

    def healthy(self):
        host = {'passed': True, 'frames': 48, 'seated_players': 2, 'confirmed': 47, 'host_rollbacks': 46}
        browser = {'browser': 'Chromium', 'version': '156.0', 'errors': [], 'result':
                   {'passed': True, 'frames': 48, 'compared': 48, 'viewer_seated': False, 'paused_turns': 12,
                    'paused_rows': 8, 'viewer_binary_receives': 51, 'catchup_steps': 4}}
        return host, browser

    def test_each_required_observation_rejects_absence_and_numeric_lookalikes(self):
        host, browser = self.healthy()
        validate(host, browser)
        for section in ['host', 'result']:
            row = host if section == 'host' else browser['result']
            for field, value in row.items():
                for bad in [None, 1 if type(value) is bool else True, float(value), 0]:
                    if type(bad) is type(value) and bad == value:
                        continue
                    first, second = copy.deepcopy((host, browser))
                    target = first if section == 'host' else second['result']
                    target[field] = bad
                    with self.subTest(section=section, field=field, value=bad), self.assertRaises(ValueError):
                        validate(first, second)
        for changes in [{'browser': 'Firefox'}, {'version': ''}, {'errors': ['late engine failure']}, {'result': None}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate(host, {**browser, **changes})
        for changes in [{'catchup_steps': 5}, {'catchup_steps': 1}, {'paused_rows': 1}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate(host, {**browser, 'result': {**browser['result'], **changes}})
        for first, second in [(None, browser), (host, None), ({}, {}), (host, {'result': []})]:
            with self.subTest(first=first, second=second), self.assertRaises(ValueError):
                validate(first, second)


    def test_departure_requires_physical_pause_and_host_continuation(self):
        host = {'passed': True, 'frames': 48, 'seated_players': 2, 'confirmed': 47, 'host_rollbacks': 46,
                'viewer_departure_observed': True, 'publication_stopped': True, 'host_frame_at_departure': 16, 'host_resumed_frame': 20}
        browser = {'browser': 'Chromium', 'version': '156.0', 'errors': [], 'departureClosed': True, 'result': {
            'passed': True, 'departure': 'viewer', 'socket_departed': True, 'playback_stopped': True, 'viewer_seated': False,
            'frame': 8, 'compared': 8, 'buffered_rows': 3, 'simulations_before': 8, 'simulations_after': 8}}
        validate_departure(host, browser)
        for section in ['host', 'result']:
            row = host if section == 'host' else browser['result']
            for field, value in row.items():
                alternatives = [None, float(value), True] if type(value) is int else [None, False if value is True else True]
                for bad in alternatives:
                    first, second = copy.deepcopy((host, browser))
                    target = first if section == 'host' else second['result']
                    target[field] = bad
                    with self.subTest(section=section, field=field, bad=bad), self.assertRaises(ValueError):
                        validate_departure(first, second)
        for changes in [{'frame': 20}, {'compared': 7}, {'buffered_rows': 1}, {'simulations_after': 9}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_departure(host, {**browser, 'result': {**browser['result'], **changes}})
        for changes in [{'departureClosed': False}, {'errors': ['late failure']}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_departure(host, {**browser, **changes})

    def test_host_departure_requires_remote_event_before_any_poll(self):
        host = {'passed': True, 'departure': 'host', 'frames': 20, 'confirmed': 19, 'host_rollbacks': 18,
                'socket_closed': True, 'remote_host_departure_observed': True, 'publication_stopped': True, 'viewer_paused_frame': 8}
        browser = {'browser': 'Chromium', 'version': '156.0', 'errors': [], 'departureClosed': False, 'result': {
            'passed': True, 'departure': 'host', 'socket_departed': False, 'playback_stopped': True, 'viewer_seated': False,
            'selected_host_departed': True, 'viewer_binary_receives': 15, 'frame': 8, 'compared': 8,
            'buffered_rows': 3, 'simulations_before': 8, 'simulations_after': 8}}
        validate_host_departure(host, browser)
        for section, row in [('host', host), ('result', browser['result'])]:
            for field, value in row.items():
                for bad in [None, True if type(value) is int else 1, float(value) if type(value) is int else 'foreign']:
                    first, second = copy.deepcopy((host, browser))
                    (first if section == 'host' else second['result'])[field] = bad
                    with self.subTest(section=section, field=field, bad=bad), self.assertRaises(ValueError):
                        validate_host_departure(first, second)
        for changes in [{'selected_host_departed': False}, {'frame': 20}, {'compared': 7}, {'buffered_rows': 1},
                        {'simulations_after': 9}, {'socket_departed': True}, {'viewer_binary_receives': 0}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_host_departure(host, {**browser, 'result': {**browser['result'], **changes}})
        for changes in [{'departureClosed': True}, {'errors': ['late failure']}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_host_departure(host, {**browser, **changes})


if __name__ == '__main__':
    unittest.main()
