#!/usr/bin/env python3
"""Protocol safety tests with a fake Codex process; uses no accounts or network."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'dist/Agent Meter Preview.app/Contents/MacOS/agent-meter-bridge'
FAKE = '''#!/usr/bin/env python3
import sys,json
for line in sys.stdin:
 m=json.loads(line)
 if m.get("method")=="account/read":
  print(json.dumps({"id":m["id"],"result":{"account":{"email":m.get("params",{}).get("email","meter@example.com"),"type":"chatgpt"}}}),flush=True)
 elif m.get("method")=="largeResponse":
  print(json.dumps({"id":m["id"],"result":{"data":"x"*600000}}),flush=True)
 elif m.get("method")=="emit":
  print(json.dumps(m["event"]),flush=True)
 else:
  print(json.dumps({"id":m.get("id"),"result":{}}),flush=True)
'''

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='agent-meter-bridge-test-')
        self.root = Path(self.directory.name)
        fake = self.root / 'codex'
        fake.write_text(FAKE); fake.chmod(0o700)
        self.state = self.root / 'state.json'
        env = dict(os.environ, AGENT_METER_REAL_CODEX=str(fake),
                   AGENT_METER_EXPECTED_EMAIL='meter@example.com', AGENT_METER_SESSION='test-nonce',
                   AGENT_METER_STATE_PATH=str(self.state))
        self.proc = subprocess.Popen([str(BRIDGE), 'app-server'], env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def tearDown(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=8)
        self.proc.stdout.close(); self.proc.stderr.close()
        state = json.loads(self.state.read_text())
        self.assertFalse(state['accountVerified'])
        self.assertFalse(state['trackingReliable'])
        with self.assertRaises(ProcessLookupError): os.kill(state['childPID'], 0)
        self.directory.cleanup()
    def send(self, value):
        self.proc.stdin.write(json.dumps(value).encode()+b'\n'); self.proc.stdin.flush()
        return json.loads(self.proc.stdout.readline())
    def read_state(self, predicate=lambda s: True):
        deadline = time.monotonic()+3
        while time.monotonic()<deadline:
            if self.state.exists():
                state = json.loads(self.state.read_text())
                if predicate(state): return state
            time.sleep(.02)
        self.fail('state was not updated')
    def test_identity_activity_and_large_responses(self):
        self.send({'id':1,'method':'account/read'})
        self.assertTrue(self.read_state(lambda s:s['accountVerified'])['accountVerified'])
        self.send({'id':2,'method':'largeResponse'})
        self.assertTrue(self.read_state()['trackingReliable'])
        self.send({'id':3,'method':'turn/start','params':{'threadId':'thread1'}})
        self.assertEqual(self.read_state()['activeTurns'],1)
        self.send({'method':'emit','event':{'method':'turn/completed','params':{'threadId':'thread1'}}})
        self.assertEqual(self.read_state()['activeTurns'],0)
        self.send({'method':'emit','event':{'method':'account/updated','params':{'authMode':None}}})
        self.assertFalse(self.read_state()['accountVerified'])
    def test_unknown_large_notification_fails_closed(self):
        self.send({'method':'emit','event':{'method':'turn/started','params':{'data':'x'*600000}}})
        self.assertFalse(self.read_state()['trackingReliable'])
    def test_wrong_identity_is_never_verified(self):
        self.send({'id':1,'method':'account/read'})
        self.assertTrue(self.read_state()['accountVerified'])
        self.send({'id':2,'method':'account/read','params':{'email':'different@example.com'}})
        self.assertFalse(self.read_state()['accountVerified'])

if __name__ == '__main__': unittest.main()
