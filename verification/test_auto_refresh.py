"""Verify the real menu process refreshes cached quotas without a user click."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from test_cli import FAKE

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / 'dist/Agent Meter Preview.app/Contents/MacOS'

class AutoRefreshTests(unittest.TestCase):
    def test_refreshes_all_accounts_on_launch_and_again_after_30_seconds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = root/'codex'; fake.write_text(FAKE); fake.chmod(0o700)
            env = dict(os.environ, AGENT_METER_HOME=str(root/'meter'), AGENT_METER_CODEX=str(fake))
            for alias in ['a','b']:
                profile=root/alias;profile.mkdir()
                subprocess.run([str(BIN/'agent-meter'),'import',alias,'--profile',str(profile)],env=env,check=True,capture_output=True)
            registry=root/'meter/accounts.json'
            data=json.loads(registry.read_text())
            for account in data['accounts']: account['quota']['fetchedAt']=0
            registry.write_text(json.dumps(data))
            process=subprocess.Popen([str(BIN/'AgentMeterPreview'),'--verify-auto-refresh'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
            def wait_for_newer(previous, timeout):
                deadline=time.monotonic()+timeout
                while time.monotonic()<deadline:
                    if process.poll() is not None: self.fail(process.stderr.read().decode())
                    times=[account['quota']['fetchedAt'] for account in json.loads(registry.read_text())['accounts']]
                    if all(current>old for current,old in zip(times,previous)): return times
                    time.sleep(0.1)
                self.fail('Menu process did not refresh both accounts in time')
            try:
                first=wait_for_newer([0,0],15)
                second=wait_for_newer(first,45)
                for old,new in zip(first,second):
                    self.assertGreaterEqual(new-old,29)
                    self.assertLess(new-old,45)
            finally:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill();process.wait()
                process.stderr.close()

if __name__ == '__main__': unittest.main()
