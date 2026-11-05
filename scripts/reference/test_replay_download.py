"""Value: received browser files cannot qualify with missing, stale or malformed evidence."""
import copy
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path
import tempfile
import unittest

from replay_download import CASES, CONTROL_DIAGNOSTICS, validate_controls, validate_downloads


def fixture(output=None):
    records = []
    for name, frame in CASES:
        received = (name + '-received-bytes').encode()
        if output is not None:
            (output / (name + '.frrp')).write_bytes(received)
            (output / (name + '.png')).write_bytes(b'\x89PNG\r\n\x1a\nfixture')
        records.append({'case': name, 'frame': frame, 'frames': frame, 'bytes': len(received),
                        'sha256': hashlib.sha256(received).hexdigest(), 'filename': name + '.frrp',
                        'canonical': '010203', 'original': '010203', 'replaced': True, 'original_valid': True, 'disconnected_rows': max(0, frame - 17),
                        'seek_disabled': True, 'held_disabled': True})
    return {'cases': records, 'download_events': 3, 'forbidden_events': 0, 'errors': []}


class ReplayDownloadTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('node'), 'Node is required for event/action rejection controls')
    # Value: the real exported collector must retain both rejection orders and allow the owner to finish cleanup.
    def test_event_and_action_rejections_remain_owned_through_cleanup(self):
        source = Path(__file__).parent / 'browser/replay_download.cjs'
        script = """
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {EventEmitter}=require('node:events');
const {replayDownloads}=require(process.argv[1]);
const output=process.argv[2],target=process.argv[3],scenario=process.argv[4];
const page=new EventEmitter(),timeline=[];
let state,stage='none',pending,downloads=0,injections=0,lateClicks=0,dom=false;
const site=target.startsWith('late-')?'late':target==='download-click'?'download':'chooser';
const select=index=>{
  const [name,frame]=[['interior',301],['terminal',610],['initial',0]][index];
  state={case:name,frame,frames:610,canonical:'010203',original:'010203',filename:name+'.frrp',failure:false,
    expected:Buffer.from(JSON.stringify({frame})).toString('base64'),x:1,y:2,open_x:3,open_y:4,
    disabled:false,seeking:false,held:false,statuses_valid:true,original_valid:true};
  stage='none';
};
global.window={fortressReplayDownloadCommand(name,value){
  if(name==='select')select(value);
  if(name==='prepare_download')stage='download';
  if(name==='prepare_import')stage='chooser';
  if(name==='seek'){state.seeking=true;state.disabled=true;stage='none';}
  if(name==='cancel'){state.seeking=false;state.disabled=false;}
  if(name==='hold'){state.held=true;state.disabled=true;stage='none';}
  if(name==='release'){state.held=false;state.disabled=false;}
  if(name==='verify_import')state.statuses_checked=true;
  if(name==='navigate'){state.frame=value;state.disconnected_rows=Math.max(0,value-17);}
},get fortressReplayDownload(){return state;}};
global.document={createElement(){dom=true;return {};},body:{appendChild(){}}};
const act=(name,effect)=>{
  timeline.push('action:'+name);
  if(pending?.target && name===target && scenario!=='healthy'){
    if(scenario==='action-first')return Promise.reject(Error('action-original'));
    return new Promise((_,reject)=>setTimeout(()=>reject(Error('action-original')),8));
  }
  return effect();
};
const settle=value=>{
  if(pending.kind==='download')page.emit('download',value);
  if(!pending.options.predicate || pending.options.predicate(value))pending.resolve(value);
};
const download=()=>{
  const bytes=Buffer.from(state.expected,'base64'),filename=state.filename;
  downloads++;
  settle({suggestedFilename:()=>filename,saveAs:async destination=>fs.writeFileSync(destination,bytes)});
};
const chooser=()=>settle({setFiles:async payload=>{
  const bytes=payload.buffer;
  state.import_replaced=true;state.source_sha256=crypto.createHash('sha256').update(bytes).digest('hex');
  state.frames=JSON.parse(bytes.toString()).frame;state.source_bytes=bytes.length;state.frame=0;
}});
page.waitForEvent=(kind,options)=>{
  const current=kind==='filechooser'?'chooser':downloads===3?'late':'download';
  timeline.push('wait:'+current);
  const selected=current===site && injections===0;
  if(selected)injections++;
  return new Promise((resolve,reject)=>{
    pending={kind,options,resolve,reject,target:selected};
    if(selected && scenario!=='healthy')setTimeout(()=>reject(Error('event-original')),scenario==='event-first'?0:8);
  });
};
page.mouse={click:async()=>{
  if(stage==='download')return act('download-click',download);
  if(stage==='chooser')return act('chooser-click',chooser);
}};
page.locator=()=>({click:async()=>{
  lateClicks++;return act('late-click',()=>settle({suggestedFilename:()=> 'forbidden.frrp'}));
}});
page.evaluate=async(fn,arg)=>{
  dom=false;
  const value=fn(arg);
  if(dom)return act('late-evaluate',()=>value);
  return structuredClone(value);
};
page.goto=async()=>select(0);
page.waitForFunction=async(fn,arg)=>{if(!fn(arg))throw Error('fixture state did not reach required boundary');};
page.waitForTimeout=async()=>{};
page.screenshot=async options=>fs.writeFileSync(options.path,'fixture');
(async()=>{
  let caught=null,result;
  try {result=await replayDownloads(page,'http://fixture.invalid',output,[]);}
  catch(error){caught=error.message;process.exitCode=1;}
  finally {
    fs.writeFileSync(path.join(output,'cleanup-started'),'started');
    await new Promise(resolve=>setTimeout(resolve,30));
    fs.writeFileSync(path.join(output,'cleanup-finished'),'finished');
  }
  console.log(JSON.stringify({caught,injections,lateClicks,timeline,result:result?.result}));
})().catch(error=>{process.exitCode=9;console.error(require('node:util').inspect(error,{customInspect:false,getters:false}));});
"""
        for target in ['download-click', 'chooser-click', 'late-evaluate', 'late-click']:
            for scenario in ['healthy', 'action-first', 'event-first']:
                with self.subTest(target=target, scenario=scenario), tempfile.TemporaryDirectory() as folder:
                    output = Path(folder)
                    environment = {**os.environ, 'FORTRESS_REPLAY_DOWNLOAD_CONTROL': 'late-download' if target.startswith('late-') else ''}
                    result = subprocess.run(['node', '--unhandled-rejections=strict', '-e', script, str(source.resolve()), str(output), target, scenario],
                                            env=environment, capture_output=True, encoding='utf-8', timeout=10)
                    self.assertTrue((output / 'cleanup-finished').exists(), 'late rejection must not interrupt owner cleanup')
                    self.assertEqual(result.stderr, '', 'both rejected promises must remain handled')
                    report = json.loads(result.stdout)
                    expected = None if not target.startswith('late-') else 'replay download forbidden events observed'
                    if scenario != 'healthy':
                        expected = 'action-original' if scenario == 'action-first' else 'event-original'
                    self.assertEqual(report['caught'], expected)
                    self.assertEqual(result.returncode, 0 if expected is None else 1)
                    self.assertEqual(report['injections'], 1, 'the selected pairing must actually execute')
                    site = 'late' if target.startswith('late-') else 'download' if target == 'download-click' else 'chooser'
                    self.assertLess(report['timeline'].index('wait:' + site), report['timeline'].index('action:' + target))
                    if target == 'late-click':
                        self.assertLess(report['timeline'].index('action:late-evaluate'), report['timeline'].index('action:late-click'))
                    if target == 'late-evaluate' and scenario != 'healthy':
                        self.assertEqual(report['lateClicks'], 0, 'failed evaluation must not reach its later click')

    def test_received_files_and_all_three_boundaries_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            value = fixture(output)
            self.assertEqual(validate_downloads(value, output), value)

    def test_table_rejects_wrong_values_and_scalar_type_aliases(self):
        mutations = [(key, value) for key, values in {
            'frame': [True, 301.0, -1, 0, '301'], 'disconnected_rows': [True, 284.0, 0, 283], 'frames': [True, 301.0, 610, '301'],
            'bytes': [True, 1.0, 0, -1], 'sha256': ['', 'a' * 63, 'A' * 64, None],
            'filename': ['../x.frrp', '/x.frrp', 'x', None], 'canonical': ['', '00', '0', None],
            'original': ['00', None], 'replaced': [False, 1], 'original_valid': [False, 1, None], 'seek_disabled': [False, 1],
            'held_disabled': [False, 1], 'case': ['terminal', 0],
        }.items() for value in values]
        mutations += [('download_events', value) for value in [True, 3.0, 2, 4]]
        mutations += [('forbidden_events', value) for value in [False, 0.0, 1]]
        mutations += [('errors', value) for value in [False, None, ['late']]]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            original = fixture(output)
            for key, value in mutations:
                with self.subTest(key=key, value=value):
                    altered = copy.deepcopy(original)
                    target = altered if key in ('download_events', 'forbidden_events', 'errors') else altered['cases'][0]
                    target[key] = value
                    with self.assertRaises(ValueError):
                        validate_downloads(altered, output)
            for name in ('missing', 'duplicate', 'order', 'unknown', 'missing-field'):
                with self.subTest(name=name):
                    altered = copy.deepcopy(original)
                    if name == 'missing':
                        altered['cases'].pop()
                    elif name == 'duplicate':
                        altered['cases'][1] = copy.deepcopy(altered['cases'][0])
                    elif name == 'order':
                        altered['cases'].reverse()
                    elif name == 'unknown':
                        altered['cases'][0]['unknown'] = True
                    else:
                        altered['cases'][0].pop('replaced')
                    with self.assertRaises(ValueError):
                        validate_downloads(altered, output)

    def test_controls_require_exact_complete_failing_inventories(self):
        valid = [{'control': name, 'exit_code': 1, 'diagnostic': diagnostic} for name, diagnostic in CONTROL_DIAGNOSTICS.items()]
        self.assertEqual(validate_controls(valid), valid)
        for name in ('missing', 'duplicate', 'order', 'code', 'bool', 'diagnostic'):
            with self.subTest(name=name):
                altered = copy.deepcopy(valid)
                if name == 'missing':
                    altered.pop()
                elif name == 'duplicate':
                    altered[1] = altered[0]
                elif name == 'order':
                    altered.reverse()
                elif name in ('code', 'bool'):
                    altered[0]['exit_code'] = 0 if name == 'code' else True
                else:
                    altered[0]['diagnostic'] = 'unrelated failure'
                with self.assertRaises(ValueError):
                    validate_controls(altered)

    def test_actual_received_artifact_and_screenshot_are_required(self):
        for mutation in ('missing', 'changed', 'symlink', 'screenshot-missing', 'screenshot-empty'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                value = fixture(output)
                target = output / 'interior.frrp'
                if mutation == 'missing':
                    target.unlink()
                elif mutation == 'changed':
                    target.write_bytes(b'changed')
                elif mutation == 'symlink':
                    target.unlink()
                    target.symlink_to(output / 'terminal.frrp')
                elif mutation == 'screenshot-missing':
                    (output / 'interior.png').unlink()
                else:
                    (output / 'interior.png').write_bytes(b'')
                with self.assertRaises(ValueError):
                    validate_downloads(value, output)


if __name__ == '__main__':
    unittest.main()
