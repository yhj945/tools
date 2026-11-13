import copy
import http.server
import json
import shutil
import threading
import time
import unittest
from unittest.mock import patch

from test_net_tune import LocalFixture
from net_tune import parser
from net_tune_auto import BASELINE_KEYS, RESULTS_FORMAT_V2, choose_results
from net_tune_modes import evaluate_cases
from net_tune_system import CC, MTU_PROBING, TuneError
from net_tune_web import MARGIN, compare_web, paired_web, web_bench


def cases(short=1., download=1., concurrent=1., idle=1.):
    rows=[]
    for kind,ratio,streams in [('short',short,1),('download',download,1),('concurrent',concurrent,4),('idle',idle,1)]:
        a={'complete':True,'seconds':2.,'bytes':1000,'ttfb_seconds':.5,'edge':'LAX','retransmitted_bytes':None}
        b={**a,'seconds':2.*ratio,'ttfb_seconds':.5*ratio}
        rows.append({'kind':kind,'bytes':1000,'concurrency':streams,'target':'fixed-target',
                     'pairs':[{'before':copy.deepcopy(a),'after':copy.deepcopy(b)} for _ in range(4)]})
    return rows


class ModeTests(LocalFixture):
    def test_objective_changes_winner_without_fixed_sysctl_presets(self):
        self.host.gso_state=lambda interface:{**self.host.queue['device'],'max_segs':65535}
        data={'format':RESULTS_FORMAT_V2,'scope':self.host.scope(),'peer':'192.0.2.20','interface':'eth0',
              'baseline':{'sysctl':{k:self.host.sysctl(k) for k in BASELINE_KEYS},
                          'queue':self.host.queue_state('eth0'),'gso':self.host.gso_state('eth0')},
              'candidates':[{'name':'responsive','settings':{'cc':'bbr'},'workloads':cases(short=.8,idle=.8)},
                            {'name':'bulk','settings':{'cc':'reno'},'workloads':cases(download=.6)}]}
        for mode,expected in [('daily','responsive'),('download','bulk')]:
            _,_,plan,choice=choose_results(self.host,self.store,data,parser().parse_args,mode=mode)
            self.assertEqual(choice['selected'],expected)
            self.assertTrue(plan['sysctl'])
            self.assertFalse(self.host.writes)

    def test_faster_average_does_not_hide_timeout_or_bad_tail(self):
        for change in ['timeout','tail','retrans']:
            rows=cases(short=.7,download=.7,concurrent=.7,idle=.7)
            pair=rows[0]['pairs'][0]
            if change=='timeout':pair['after'].update(complete=False,seconds=15.,bytes=0)
            elif change=='tail':pair['after']['seconds']=4.
            else:
                for row in rows:
                    for p in row['pairs']:
                        p['before']['retransmitted_bytes']=0;p['after']['retransmitted_bytes']=100
            self.assertFalse(evaluate_cases(rows,'daily')['eligible'])

    def test_missing_coverage_and_endpoint_change_are_not_accepted(self):
        self.assertFalse(evaluate_cases(cases(short=.7)[:1],'daily')['eligible'])
        rows=cases(short=.7);rows[0]['pairs'][0]['after']['edge']='SJC'
        self.assertFalse(evaluate_cases(rows,'balanced')['eligible'])

    def test_stability_allows_bounded_median_tradeoff_only_with_tail_gain(self):
        rows=cases()
        for row in rows:
            for i,p in enumerate(row['pairs']):
                p['before']['seconds']=4. if i==3 else 2.
                p['after']['seconds']=2.15
        self.assertTrue(evaluate_cases(rows,'stability')['eligible'])
        self.assertFalse(evaluate_cases(rows,'balanced')['eligible'])

    def test_mtu_probe_policy_applies_and_rolls_back(self):
        self.host.values[MTU_PROBING]='2'
        plan=self.plan('--mtu-probing','1')
        identifier=self.store.apply(plan)
        self.assertEqual(self.host.values[MTU_PROBING],'1')
        self.store.rollback(identifier)
        self.assertEqual(self.host.values[MTU_PROBING],'2')
        with self.assertRaises(TuneError):self.plan('--profile','vless','--interface','eth0','--mtu-probing','1')


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def log_message(self,*args):pass
    def do_GET(self):
        if self.path=='/slow':
            self.send_response(200);self.send_header('Transfer-Encoding','chunked');self.end_headers()
            try:
                for _ in range(20):
                    self.wfile.write(b'1\r\nx\r\n');self.wfile.flush();time.sleep(.1)
            except (OSError,ValueError):pass
            return
        n=int(self.headers.get('Range','bytes=0-1023').split('-')[-1])+1
        if self.path=='/too-big':n=2*1024*1024
        self.send_response(503 if self.path=='/failure' else 206)
        self.send_header('Content-Length',str(n));self.send_header('CF-Ray','test-LAX');self.end_headers()
        try:
            left=n
            while left:
                chunk=b'x'*min(left,65536);self.wfile.write(chunk);left-=len(chunk)
        except (OSError,ValueError):pass


@unittest.skipUnless(shutil.which('curl'),'curl is needed for HTTP fixtures')
class WebTests(LocalFixture):
    def setUp(self):
        super().setUp()
        self.server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.server.daemon_threads=True
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.addCleanup(self.server.server_close);self.addCleanup(self.server.shutdown)
        self.url='http://127.0.0.1:'+str(self.server.server_port)

    def args(self,path='/',*extra):
        return parser().parse_args(['web','--url',self.url+path,'--rounds','3','--idle-seconds','1','--mode','daily',*extra])

    def test_real_http_matrix_parallel_and_idle_connection_reuse(self):
        report=web_bench(self.host,self.args())
        self.assertTrue(report['complete'])
        self.assertEqual(len(report['attempts']),12)
        self.assertTrue(all(r['sample']['complete'] for r in report['attempts']))
        for r in report['attempts']:
            case=report['matrix'][r['case']]
            if case['kind']=='idle':
                self.assertTrue(r['sample']['idle_connection_reused'])
                self.assertGreaterEqual(len(r['requests']),2)
        self.assertTrue(paired_web(report,copy.deepcopy(report)))
        result=compare_web(report,copy.deepcopy(report),'balanced')
        self.assertFalse(result['eligible'])
        self.assertLessEqual(report['charged_bytes'],report['budget_bytes'])

    def test_budget_before_first_request_and_failure_not_refunded(self):
        sample={'complete':False,'seconds':1.,'bytes':0,'ttfb_seconds':0.,'edge':'LAX'}
        with patch('net_tune_web.request_group',return_value=[sample]) as request:
            report=web_bench(self.host,self.args('/failure','--budget-mib','1'))
        self.assertEqual(request.call_count,1)
        self.assertEqual(report['charged_bytes'],2*16384+MARGIN)
        self.assertFalse(report['complete'])
        report=web_bench(self.host,self.args('/failure','--budget-mib','1'))
        self.assertFalse(report['attempts'][0]['sample']['complete'])
        self.assertEqual(report['attempts'][0]['sample']['error_kind'],'http_response')
        self.assertEqual(report['summary'][0]['transport_failures'],0)
        self.assertEqual(report['charged_bytes'],2*16384+MARGIN)

    def test_oversized_response_is_a_failure_and_reserved(self):
        report=web_bench(self.host,self.args('/too-big','--budget-mib','1'))
        self.assertFalse(report['attempts'][0]['sample']['complete'])
        self.assertEqual(report['summary'][0]['size_limit_failures'],1)
        self.assertEqual(report['summary'][0]['transport_failures'],0)
        self.assertGreater(report['charged_bytes'],0)

    def test_idle_timeout_is_bounded_even_for_trickling_body(self):
        from net_tune_web import idle_requests
        args=self.args('/slow');args.timeout=.25;args.idle_seconds=.01
        start=time.monotonic()
        rows=idle_requests(self.url+'/slow',16384,args,time.monotonic()+2)
        self.assertLess(time.monotonic()-start,1.5)
        self.assertFalse(any(r['complete'] for r in rows))

    def test_preview_has_no_network_or_file_writes(self):
        before=set(self.root.rglob('*'))
        with patch('net_tune_web.request_group') as request:
            report=web_bench(self.host,self.args('/','--dry-run'))
        request.assert_not_called()
        self.assertEqual(before,set(self.root.rglob('*')))
        self.assertEqual(report['charged_bytes'],0)

    def test_os_failure_retains_reserved_attempt_in_report(self):
        with patch('net_tune_web.request_group',side_effect=OSError('injected spawn failure')):
            report=web_bench(self.host,self.args('/','--budget-mib','1'))
        self.assertFalse(report['complete'])
        self.assertEqual(report['charged_bytes'],2*16384+MARGIN)
        self.assertEqual(report['summary'][0]['failed'],1)
        self.assertIn('injected',report['stop_reason'])

    def test_interrupted_request_keeps_budget_and_partial_report(self):
        with patch('net_tune_web.request_group',side_effect=KeyboardInterrupt()):
            report=web_bench(self.host,self.args('/','--budget-mib','1'))
        self.assertTrue(report['interrupted'])
        self.assertFalse(report['complete'])
        self.assertEqual(report['charged_bytes'],2*16384+MARGIN)
        self.assertEqual(report['summary'][0]['failed'],1)

    def test_idle_first_failure_is_not_hidden_by_fast_second_request(self):
        ok={'complete':True,'seconds':.1,'bytes':1000,'ttfb_seconds':.05,'edge':'LAX','connections_created':0}
        def requests(url,size,count,*args):
            return [{**ok,'complete':False,'seconds':10.},ok.copy()] if count==2 else [ok.copy()]
        with patch('net_tune_web.request_group',side_effect=requests):
            report=web_bench(self.host,self.args())
        idle=[a['sample'] for a in report['attempts'] if report['matrix'][a['case']]['kind']=='idle']
        self.assertTrue(all(not s['complete'] and s['seconds']==10. and not s['idle_connection_reused'] for s in idle))

    def test_compare_rejects_changed_proxy_scope_or_matrix(self):
        before=web_bench(self.host,self.args('/','--dry-run'));before.update(complete=True,dry_run=False)
        for key in ['path','matrix','observer_scope']:
            after=copy.deepcopy(before)
            if key=='matrix':after[key][0]['max_bytes']+=1
            elif key=='path':after[key]['proxy']='http://127.0.0.1:9'
            else:after[key]['machine']='another'
            with self.assertRaises(TuneError):paired_web(before,after)


if __name__=='__main__':unittest.main()
