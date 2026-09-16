#!/usr/bin/env python3
"""End-to-end CLI/RPC checks against a fake official process; no real credentials."""
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'dist/Agent Meter Preview.app/Contents/MacOS/agent-meter'
FAKE = '''#!/usr/bin/env python3
import sys,json,os,pathlib,time
profile=pathlib.Path(os.environ['CODEX_HOME'])
if 'app-server' not in sys.argv:
 print(json.dumps({'profile':profile.name,'args':sys.argv[1:],'key_override':'OPENAI_API_KEY' in os.environ}))
 raise SystemExit(0)
mode=(profile/'mode').read_text() if (profile/'mode').exists() else 'normal'
def send(m):
 data=json.dumps(m,ensure_ascii=False)+'\\n'
 # Split responses across several writes, including non-ASCII account names.
 for pos in range(0,len(data),17):
  sys.stdout.write(data[pos:pos+17]);sys.stdout.flush()
for line in sys.stdin:
 m=json.loads(line);method=m.get('method');r={}
 if method=='initialized':continue
 if method=='account/read':
  if mode=='exit': raise SystemExit(3)
  r={'account':{'type':'chatgpt','email':profile.name+'@example.invalid','planType':'pro'}}
 if method=='account/rateLimits/read':
  if mode=='deny':
   send({'id':m['id'],'error':{'code':401,'message':'sensitive-provider-error-must-not-be-logged'}});continue
  r={'rateLimits':{'primary':{'usedPercent':12,'windowDurationMins':300,'resetsAt':1800000000},'secondary':None},'rateLimitResetCredits':{'availableCount':0,'credits':None}}
 if method=='account/login/start':
  (profile/'auth.json').write_text('{}')
  # A completion may arrive before the start response; the client must retain it.
  send({'method':'account/login/completed','params':{'loginId':'test-login','success':True}})
  r={'authUrl':'https://auth.openai.com/authorize?test=1','loginId':'test-login','type':'chatgpt'}
 send({'id':m.get('id'),'result':r})
'''

class CLITests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='agent-meter-cli-test-')
        self.root = Path(self.tmp.name)
        fake = self.root/'codex';fake.write_text(FAKE);fake.chmod(0o700)
        self.env = dict(os.environ, AGENT_METER_HOME=str(self.root/'meter'), AGENT_METER_CODEX=str(fake), OPENAI_API_KEY='test-override')
    def tearDown(self): self.tmp.cleanup()
    def call(self, *args, code=0):
        proc=subprocess.run([str(CLI),*args],env=self.env,capture_output=True,text=True,timeout=15)
        self.assertEqual(proc.returncode,code,proc.stdout+proc.stderr)
        return json.loads(proc.stdout)
    def add(self, alias):
        profile=self.root/alias;profile.mkdir();(profile/'marker').write_text('do-not-change')
        return self.call('import',alias,'--profile',str(profile),'--json')
    def test_plain_codex_resume_follows_selection_in_same_shell(self):
        a=self.add('a');self.add('b')
        sid='99999999-0000-4000-8000-000000000001'
        with sqlite3.connect(self.root/'a'/'state_5.sqlite') as db:
            db.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, updated_at INTEGER, rollout_path TEXT, source TEXT, history_mode TEXT, archived INTEGER)')
            db.execute('INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, ?)', (sid, 'History', str(self.root), 9999999999, '', 'cli', 'paginated', 0))
        env=dict(self.env, AGENT_METER_CLI=str(CLI), METER_HOOK=str(ROOT/'scripts/codex-resume.zsh'), TEST_SESSION=sid, CODEX_PROFILE='old-shell-value')
        script='source "$METER_HOOK"; codex resume "$TEST_SESSION"; "$AGENT_METER_CLI" switch b --cli-only >/dev/null; codex resume "$TEST_SESSION"'
        proc=subprocess.run(['/bin/zsh','-f','-c',script],env=env,capture_output=True,text=True,timeout=15)
        self.assertEqual(proc.returncode,0,proc.stdout+proc.stderr)
        results=[json.loads(line) for line in proc.stdout.splitlines()]
        self.assertEqual([r['profile'] for r in results],['a','b'])
        for result in results:
            self.assertEqual(result['args'][2:],['resume',sid])
            self.assertIn(str(self.root/'a'),result['args'][1])
            self.assertFalse(result['key_override'])

    def test_switch_and_run_are_isolated(self):
        self.add('a');self.add('b')
        self.call('switch','b','--cli-only','--json')
        self.assertEqual(self.call('status','--json')['selected'],'b')
        process=self.call('run','codex','--account','a','--','--version')
        self.assertEqual(process['profile'],'a')
        self.assertEqual(process['args'],['--version'])
        self.assertFalse(process['key_override'])
        self.assertEqual((self.root/'a'/'marker').read_text(),'do-not-change')
        self.assertEqual((self.root/'b'/'marker').read_text(),'do-not-change')
    def test_quota_failure_preserves_cache_and_redacts_raw_error(self):
        account=self.add('a')
        (self.root/'a'/'mode').write_text('deny')
        failed=self.call('quota','a','--json',code=2)[0]
        self.assertEqual(failed['quota'],account['quota'])
        self.assertIn('401',failed['lastError'])
        self.assertNotIn('sensitive-provider',failed['lastError'])
    def test_login_notification_order_and_private_file(self):
        account=self.call('login','工作','--no-open','--json')
        self.assertEqual(account['alias'],'工作')
        self.assertTrue(account['managed'])
        self.assertEqual(os.stat(Path(account['profilePath'])/'auth.json').st_mode & 0o777,0o600)
    def test_failed_identity_does_not_change_default(self):
        self.add('a');self.add('b')
        (self.root/'b'/'mode').write_text('exit')
        self.call('switch','b','--cli-only','--json',code=1)
        self.assertEqual(self.call('status','--json')['selected'],'a')
        (self.root/'b'/'mode').write_text('deny')
        self.call('switch','b','--cli-only','--json',code=1)
        self.assertEqual(self.call('status','--json')['selected'],'a')
    def test_duplicate_alias_and_remove_retains_profile(self):
        self.add('a')
        self.call('import','A','--profile',str(self.root/'a'),'--json',code=1)
        self.call('remove','a','--json')
        self.assertTrue((self.root/'a'/'marker').exists())
        self.assertEqual(self.call('accounts','--json')['accounts'],[])

if __name__ == '__main__': unittest.main()
