import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from unittest.mock import patch

from test_net_tune import LocalFixture, NETWORK
from net_tune import parser
from net_tune_bench import MIB
from net_tune_observe import attach_downloads, socket_row
from net_tune_optimize import CONTROL_RESERVE, DEFAULT_URL, MEMORY_BOOTSTRAP, Backend, optimize
from net_tune_system import BASE_MSS, CC, MTU_PROBING, TuneError
from net_tune_trial import design, initial_settings, recover, reserve_lease, save, snapshot
from net_tune_web import WEB_FORMAT


class ObservationTests(unittest.TestCase):
    def test_closed_sender_counters_and_unknown_retransmissions(self):
        prefix = 'UNCONN 0 0 192.0.2.1:443 192.0.2.2:12345 ino:0 sk:abc cubic wscale:7,7 '
        row = socket_row(prefix + 'bytes_sent:11000 bytes_acked:10001 bytes_retrans:1000', 9.)
        self.assertEqual(row['retransmitted_bytes'], 1000)
        self.assertEqual(row['cc'], 'cubic')
        self.assertEqual(socket_row(prefix + 'bytes_sent:10000 bytes_acked:10001', 9.)['retransmitted_bytes'], 0)
        self.assertIsNone(socket_row(prefix + 'bytes_sent:10000 bytes_acked:10001 retrans:0/2', 9.)['retransmitted_bytes'])
        closed = prefix.replace('cubic wscale:', 'ts sack wscale:') + 'bytes_sent:10000 bytes_acked:10001'
        self.assertIsNone(socket_row(closed, 9.)['cc'])
        self.assertIsNone(socket_row('not a socket', 9.))

    def test_ambiguous_failed_or_incomplete_observations_are_not_zero(self):
        report = {'matrix':[{'kind':'download'}], 'attempts':[{'case':0,'round':1,'start':10.,'end':11.,
                  'sample':{'complete':True,'bytes':MIB,'retransmitted_bytes':None}}]}
        event = {'id':'one','time':11.1,'bytes_acked':MIB+100,'retransmitted_bytes':500,'cc':'bbr'}
        observation = {'complete':True,'events':[event]}
        result = attach_downloads(copy.deepcopy(report), observation)
        self.assertEqual(result['attempts'][0]['sample']['retransmitted_bytes'], 500)
        for bad in [{'complete':False,'events':[event]}, {'complete':True,'events':[event,{**event,'id':'two'}]}]:
            self.assertIsNone(attach_downloads(copy.deepcopy(report),bad)['attempts'][0]['sample']['retransmitted_bytes'])
        report['attempts'][0]['sample']['complete'] = False
        self.assertIsNone(attach_downloads(report,observation)['attempts'][0]['sample']['retransmitted_bytes'])


class TrialTests(LocalFixture):
    def setUp(self):
        super().setUp()
        self.link = {'ifindex':7,'address':'02:00:00:00:00:01','max_segs':65535}
        self.host.gso_state = lambda interface:copy.deepcopy(self.link)
        self.host.set_gso_max_segs = lambda interface,value:self.link.update(max_segs=value)
        self.host.default_ipv4_route = lambda:{'tokens':['default','dev','eth0'],'interface':'eth0','initcwnd':None}
        self.host.values.update({BASE_MSS:'1024',MTU_PROBING:'0','net.ipv4.tcp_rto_min_us':'200000'})

    def test_general_gso_plan_and_history_recover_actual_initial_values(self):
        before = snapshot(self.host,self.store)
        first = self.store.apply(design(self.host,self.store,'eth0',{'gso_max_segs':1}))
        second = self.store.apply(design(self.host,self.store,'eth0',{'mtu_probe_mss':1290,'mtu_probing':2}))
        settings = initial_settings(self.store,snapshot(self.host,self.store))
        self.assertEqual(settings,{'gso_max_segs':65535,'mtu_probe_mss':1024,'mtu_probing':0})
        temporary = self.store.apply(design(self.host,self.store,'eth0',settings))
        self.assertEqual(snapshot(self.host,self.store),before)
        self.store.rollback(temporary)
        self.assertEqual(self.link['max_segs'],1)
        self.store.rollback(second);self.store.rollback(first)
        self.assertEqual(snapshot(self.host,self.store),before)

    def test_journal_hook_precedes_first_write_and_failed_hook_never_mutates(self):
        plan = self.plan('--cc','bbr')
        ids = []
        def remember(identifier):
            self.assertFalse(self.host.writes)
            ids.append(identifier)
        identifier = self.store.apply(plan,journal_hook=remember)
        self.assertEqual(ids,[identifier])
        self.store.rollback(identifier)
        before = list(self.host.writes)
        with self.assertRaises(OSError):
            self.store.apply(plan,journal_hook=lambda _:(_ for _ in ()).throw(OSError('lease disk full')))
        self.assertEqual(self.host.writes,before)

    def test_initial_configuration_does_not_mix_network_namespaces(self):
        self.store.apply(self.plan('--cc','bbr'))
        self.host.scope_data['netns'] += 1
        self.assertEqual(initial_settings(self.store,snapshot(self.host,self.store)),{})

    def test_recovery_never_overwrites_foreign_change(self):
        baseline = snapshot(self.host,self.store)
        identifier = self.store.apply(self.plan('--cc','bbr'))
        path = self.root/'lease';path.mkdir()
        state = {'state':'active','baseline':baseline,'transactions':[identifier]}
        self.host.values[CC] = 'reno'
        result = recover(self.host,self.store,path,state)
        self.assertEqual(result['state'],'recovery_required')
        self.assertEqual(self.host.values[CC],'reno')

    def test_exclusive_lease_and_recovery_of_expired_trial(self):
        baseline = snapshot(self.host, self.store)
        path, state = reserve_lease(self.host, self.store, baseline, {'cc':'bbr'}, 'a'*32)
        with self.assertRaisesRegex(TuneError, '已有试验'):
            reserve_lease(self.host, self.store, baseline, {'cc':'bbr'}, 'b'*32)
        state['transactions'] = [self.store.apply(self.plan('--cc','bbr'))]
        state['expires'] = time.monotonic()-1
        save(path/'state.json', state)
        reserve_lease(self.host, self.store, baseline, {'cc':'bbr'}, 'b'*32)
        self.assertEqual(snapshot(self.host,self.store),baseline)
        self.assertEqual(json.loads((path/'state.json').read_text())['state'],'rolled_back')


class SimulatedBackend:
    def __init__(self):
        self.changed = False
        self.begins = 0
        self.calls = []
        self.events = []
        self.baseline = {'interface':'eth0','original':True}
        plan = {'sysctl':[{'key':MTU_PROBING,'before':'0','after':'1','reason':'test'}], 'shape':None,'config':None,'notes':[]}
        self.preview = {'baseline':self.baseline,'candidates':[{'name':'candidate','settings':{'mtu_probing':1},'plan':plan}],'skipped':[]}

    def prepare(self):self.calls.append('prepare')
    def close(self):self.calls.append('close')
    def call(self,request):
        op=request['op'];self.calls.append(op)
        if op=='preview':return copy.deepcopy(self.preview)
        if op=='begin':
            self.changed=True;self.begins+=1
            return {'id':request['id'],'state':{}}
        if op=='finish':
            if not request.get('keep'):self.changed=False
            return {'state':'kept' if request.get('keep') else 'rolled_back'}
        if op=='observe_start':
            self.events=[]
            return {'id':'observe','ready':True,'epoch':time.time()}
        if op=='observe_stop':return {'complete':True,'events':self.events,'method':'test'}
        if op=='snapshot':return {'changed':True} if self.changed else self.baseline
        return {}


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.output=Path(self.temporary.name)/'report'
        self.backend=SimulatedBackend()
        self.failure=None
        self.confirm_slow=False
        self.no_retrans=False

    def args(self,*extra):
        args=parser().parse_args(['optimize','--mode','daily','--idle-seconds','1','--budget-mib','64','--output',str(self.output),*extra])
        args.url=[DEFAULT_URL]
        return args

    def measure(self,host,args):
        matrix=[{'kind':k,'max_bytes':MIB,'concurrency':1,'target':'fixed'} for k in ('short','download','concurrent','idle')]
        if args.dry_run:return {'planned_reserved_bytes':MIB,'matrix':matrix}
        if self.backend.changed and self.failure:raise self.failure
        seconds=4. if not self.backend.changed else (6. if self.confirm_slow and self.backend.begins==2 else 2.)
        attempts=[];zero=time.time()
        for round_no in range(1,args.rounds+1):
            for index,case in enumerate(matrix):
                start=zero+round_no*40+index*6
                sample={'complete':True,'seconds':seconds,'bytes':MIB,'ttfb_seconds':seconds/4,'edge':'fixed-edge','retransmitted_bytes':None}
                attempts.append({'round':round_no,'case':index,'start':start,'end':start+seconds,'sample':sample})
                if case['kind']=='download' and not self.no_retrans:
                    self.backend.events.append({'id':str(round_no),'time':start+seconds+.1,'bytes_acked':MIB+100,
                                                'retransmitted_bytes':100 if self.backend.changed else 1000,'cc':'bbr'})
        return {'format':WEB_FORMAT,'complete':True,'stop_reason':None,'observer_scope':{'machine':'fixture'},
                'path':{'target':'fixed'},'matrix':matrix,'attempts':attempts,'summary':[]}

    def run_workflow(self,args):
        with patch('net_tune_optimize.os.geteuid',return_value=0),patch('net_tune_optimize.time.sleep'),patch('net_tune.show_plan'):
            return optimize(args,backend=self.backend,measure=self.measure,progress=lambda _:None)

    def test_default_preview_never_deploys_measures_or_creates_output(self):
        result=self.run_workflow(self.args())
        self.assertEqual(result['state'],'preview')
        self.assertEqual(self.backend.calls,['preview'])
        self.assertFalse(self.output.exists())

    def test_independent_confirmation_and_health_required_before_keep(self):
        result=self.run_workflow(self.args('--apply','--yes'))
        self.assertEqual(result['state'],'verified_improvement_retained')
        self.assertEqual(self.backend.begins,3)
        self.assertEqual([p['label'] for p in result['phases']],['candidate0-A1','candidate0-B1','candidate0-B2','candidate0-A2','final-health'])
        self.assertEqual(result['charged_bytes'],CONTROL_RESERVE+5*MIB)

    def test_failed_confirmation_restores_original(self):
        self.confirm_slow=True
        result=self.run_workflow(self.args('--apply','--yes'))
        self.assertEqual(result['state'],'no_confirmed_improvement')
        self.assertFalse(self.backend.changed)
        self.assertIsNone(result['selected'])

    def test_failure_or_interrupt_preserves_budget_and_rolls_back(self):
        for failure in (TuneError('injected transport failure'),KeyboardInterrupt()):
            self.output=Path(self.temporary.name)/('interrupt' if isinstance(failure,KeyboardInterrupt) else 'failure')
            self.backend=SimulatedBackend();self.failure=failure
            result=self.run_workflow(self.args('--apply','--yes'))
            self.assertFalse(self.backend.changed)
            self.assertEqual(result['charged_bytes'],CONTROL_RESERVE+2*MIB)
            self.assertTrue((self.output/'report.json').exists())

    def test_proxy_without_sender_evidence_cannot_be_kept(self):
        self.no_retrans=True
        result=self.run_workflow(self.args('--apply','--yes','--ssh','root@fixture','--proxy','socks5://127.0.0.1:1080','--service-port','443'))
        self.assertEqual(result['state'],'no_confirmed_improvement')
        self.assertFalse(self.backend.changed)

    def test_insufficient_budget_rejected_before_deployment(self):
        args=self.args('--apply','--yes');args.budget_mib=33
        with self.assertRaisesRegex(TuneError,'预算至少'):
            self.run_workflow(args)
        self.assertEqual(self.backend.calls,['preview'])
        self.assertFalse(self.output.exists())

    def test_lost_begin_reply_and_persistence_failure_are_recovered(self):
        for operation in ('begin','persist','finish'):
            self.output=Path(self.temporary.name)/operation
            self.backend=SimulatedBackend()
            original=self.backend.call
            failed=False
            def failure(request):
                nonlocal failed
                value=original(request)
                if request['op']==operation and (operation!='finish' or request.get('keep')) and not failed:
                    failed=True
                    raise TuneError('lost reply or persistence failure')
                return value
            self.backend.call=failure
            result=self.run_workflow(self.args('--apply','--yes','--persist'))
            self.assertTrue(failed)
            self.assertFalse(self.backend.changed)
            self.assertEqual(result['state'],'failed')
            self.assertEqual(result['trials'][-1]['result'],'rolled_back')

    def test_declined_preview_has_no_side_effects(self):
        with patch('builtins.input',return_value=''):
            result=self.run_workflow(self.args('--apply'))
        self.assertEqual(result['state'],'cancelled')
        self.assertEqual(self.backend.calls,['preview'])
        self.assertFalse(self.output.exists())

    def test_impossible_idle_deadline_rejected_before_deployment(self):
        with self.assertRaisesRegex(TuneError,'空闲等待'):
            self.run_workflow(self.args('--apply','--yes','--idle-seconds','300','--deadline','30'))
        self.assertEqual(self.backend.calls,['preview'])
        self.assertFalse(self.output.exists())

    def test_unavailable_sender_observer_stops_before_network_load(self):
        original=self.backend.call
        def unavailable(request):
            value=original(request)
            return {**value,'ready':False,'error':'not supported'} if request['op']=='observe_start' else value
        self.backend.call=unavailable
        result=self.run_workflow(self.args('--apply','--yes','--ssh','root@fixture','--proxy','socks5://127.0.0.1:1080','--service-port','443'))
        self.assertEqual(result['state'],'failed')
        self.assertEqual(self.backend.begins,0)
        self.assertEqual(result['charged_bytes'],CONTROL_RESERVE+MIB)

    def test_ssh_memory_preview_loads_same_bundle_without_files(self):
        backend=Backend('unused')
        with tempfile.TemporaryDirectory() as directory:
            payload={'sources':backend.sources,'request':{'op':'preview'}}
            result=subprocess.run([sys.executable,'-B','-c',MEMORY_BOOTSTRAP],input=json.dumps(payload),
                                  text=True,capture_output=True,cwd=directory,timeout=15)
            self.assertEqual(result.returncode,0,result.stderr+result.stdout)
            self.assertIn('candidates',json.loads(result.stdout)['result'])
            self.assertEqual(list(Path(directory).iterdir()),[])


class BootstrapTests(unittest.TestCase):
    def test_archive_entry_includes_integrated_modules_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);binary=root/'bin';binary.mkdir()
            archive=root/'tools.zip'
            with zipfile.ZipFile(archive,'w') as bundle:
                for path in NETWORK.glob('net_tune*.py'):
                    bundle.write(path,'tools-main/network/'+path.name)
            wrapper=root/'net_tune.sh';wrapper.write_text((NETWORK/'net_tune.sh').read_text())
            curl=binary/'curl'
            curl.write_text('#!/usr/bin/env python3\nimport os,shutil,sys\nshutil.copyfile(os.environ["NET_TUNE_TEST_ARCHIVE"],sys.argv[sys.argv.index("--output")+1])\n')
            curl.chmod(0o700)
            env={**os.environ,'PATH':str(binary)+':'+os.environ['PATH'],'TMPDIR':str(root),'NET_TUNE_TEST_ARCHIVE':str(archive)}
            before=set(root.iterdir())
            result=subprocess.run(['bash',str(wrapper),'optimize','--dry-run','--json'],env=env,text=True,capture_output=True,timeout=20)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['state'],'preview')
            self.assertEqual(set(root.iterdir()),before)


@unittest.skipUnless(os.environ.get('NET_TUNE_NETNS_TEST')=='1','set NET_TUNE_NETNS_TEST=1')
class RecoveryNamespaceTests(unittest.TestCase):
    def isolated(self,body,timeout=35):
        script='''set -eu
cd "$1"
mount -t tmpfs none /var/lib
ip link set lo up
ip link add test0 type veth peer name test1
ip link set test0 up
ip link set test1 up
ip -4 route add default dev test0
python3 -B - <<'PY'
'''+body+'\nPY\n'
        result=subprocess.run(['unshare','-Urnmpf','--mount-proc','sh','-ec',script,'test',str(NETWORK)],text=True,capture_output=True,timeout=timeout)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)

    def test_detached_guard_recovers_after_controller_sigkill(self):
        self.isolated('''
import json,os,signal,subprocess,sys,time
from pathlib import Path
from net_tune_trial import rpc,lease_lock,save
before=rpc({'op':'preview'})['baseline']
code="from net_tune_trial import rpc;import json,time;from pathlib import Path;r=rpc({'op':'begin','baseline':"+repr(before)+",'settings':{'gso_max_segs':1}});Path('/var/lib/controller-result').write_text(json.dumps(r));time.sleep(100)"
p=subprocess.Popen([sys.executable,'-B','-c',code])
until=time.monotonic()+8
while not Path('/var/lib/controller-result').exists() and time.monotonic()<until:time.sleep(.05)
assert Path('/var/lib/controller-result').exists()
r=json.loads(Path('/var/lib/controller-result').read_text());path=Path('/var/lib/net-tune/experiments')/r['id']
assert rpc({'op':'snapshot'})['gso']['max_segs']==1
os.kill(p.pid,signal.SIGKILL);p.wait()
with lease_lock(path):
 s=json.loads((path/'state.json').read_text());s['expires']=time.monotonic()+.3;save(path/'state.json',s)
until=time.monotonic()+8
while time.monotonic()<until:
 s=json.loads((path/'state.json').read_text())
 if s['state']!='active':break
 time.sleep(.05)
assert s['state']=='rolled_back',s
assert rpc({'op':'snapshot'})==before
''')

    def test_real_sender_close_observer_matches_download(self):
        self.isolated('''
import http.server,json,socket,threading,time,urllib.request
from net_tune_trial import rpc
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  self.send_response(200);self.send_header('Content-Length','1048576');self.end_headers()
  for _ in range(16):self.wfile.write(b'x'*65536);self.wfile.flush();time.sleep(.05)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
try:
 observer=rpc({'op':'observe_start','port':server.server_port,'seconds':10})
 assert observer['ready'],observer
 with urllib.request.urlopen('http://127.0.0.1:'+str(server.server_port),timeout=5) as response:assert len(response.read())==1048576
 time.sleep(.5)
 result=rpc({'op':'observe_stop','id':observer['id']})
 assert result['complete'],result
 assert any(e['bytes_acked']>=1048576 and e['retransmitted_bytes']==0 and e['cc'] for e in result['events']),result
finally:server.shutdown();server.server_close()
''')
