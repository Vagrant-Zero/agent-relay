"""Cross-account routing checks; no credentials, network or real history writes."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('METER_TEST_CLI', str(ROOT / '.build/debug/agent-relay'))).resolve()

class SessionsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.a = self.root / 'account-a'
        self.b = self.root / 'history "quoted"'
        self.a.mkdir(); self.b.mkdir()
        self.project = self.root / 'project'; self.project.mkdir()
        self.sid = '99999999-0000-4000-8000-000000000001'
        with sqlite3.connect(self.b / 'state_5.sqlite') as db:
            db.execute('CREATE TABLE threads (id TEXT, title TEXT, cwd TEXT, updated_at INTEGER, rollout_path TEXT, source TEXT, history_mode TEXT, archived INTEGER)')
            db.execute('INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?, ?)', (self.sid, 'Original conversation', str(self.project), 9999999999, str(self.b/'rollout.jsonl'), 'cli', 'paginated', 0))
        # Planning requires a valid executable path, but must not depend on a real Codex installation.
        self.env = dict(os.environ, AGENT_METER_HOME=str(self.root/'meter'), AGENT_METER_CODEX='/usr/bin/false')
    def tearDown(self): self.tmp.cleanup()
    def run_cli(self, args, check=True):
        return subprocess.run([str(CLI), *args], env=self.env, cwd=self.project, text=True, capture_output=True, check=check)
    def plan(self, *args):
        return json.loads(self.run_cli(['resume','--profile',str(self.a),'--source',str(self.b),'--plan','--json',*args]).stdout)
    def test_routes_history_without_switching_credentials(self):
        result = self.plan(self.sid)
        self.assertEqual(result['profile'],str(self.a))
        self.assertEqual(result['arguments'][2:],['resume',self.sid])
        import tomllib
        self.assertEqual(tomllib.loads(result['arguments'][1])['sqlite_home'],str(self.b))
        self.assertFalse((self.a/'state_5.sqlite').exists())
    def test_last_crosses_profiles_and_preserves_prompt(self):
        result=self.plan('--last','continue here')
        self.assertEqual(result['arguments'][2:],['resume',self.sid,'continue here'])
    def test_picker_noninteractive_does_not_start_empty_thread(self):
        result=self.run_cli(['resume','--profile',str(self.a),'--source',str(self.b)],check=False)
        self.assertNotEqual(result.returncode,0)
    def test_unknown_id_fails_closed(self):
        result=self.run_cli(['resume','--profile',str(self.a),'--source',str(self.b),'unknown'],check=False)
        self.assertNotEqual(result.returncode,0)
    def test_exec_preserves_selected_profile_and_arguments(self):
        fake=self.root/'codex'
        fake.write_text('#!/usr/bin/python3\nimport json,os,sys\nprint(json.dumps({"profile":os.environ["CODEX_HOME"],"args":sys.argv[1:],"api":os.environ.get("OPENAI_API_KEY")}))\n');fake.chmod(0o700)
        self.env.update(AGENT_METER_CODEX=str(fake),OPENAI_API_KEY='test-override')
        result=json.loads(self.run_cli(['run','--profile',str(self.a),'--source',str(self.b),'--','resume',self.sid,'a prompt']).stdout)
        self.assertEqual(result['profile'],str(self.a))
        self.assertEqual(result['args'][2:],['resume',self.sid,'a prompt'])
        self.assertIsNone(result['api'])
    def test_read_only_catalog(self):
        before=(self.b/'state_5.sqlite').read_bytes()
        result=json.loads(self.run_cli(['sessions','--source',str(self.b),'--json']).stdout)
        self.assertTrue(any(s['id']==self.sid for s in result))
        self.assertEqual(before,(self.b/'state_5.sqlite').read_bytes())

if __name__ == '__main__': unittest.main()
