"""Exercise real AppKit termination across isolated, invisible app instances."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

APP = Path(__file__).resolve().parents[1]/'dist/Agent Relay.app/Contents/MacOS/AgentRelay'

class QuitTests(unittest.TestCase):
    def exercise(self, with_manager, slow_worker=False):
        with tempfile.TemporaryDirectory(prefix='relay-quit-') as directory:
            root = Path(directory)
            env = dict(os.environ, AGENT_METER_HOME=directory)
            if slow_worker:
                from test_cli import FAKE
                fake = root/'codex'; fake.write_text(FAKE); fake.chmod(0o700)
                env['AGENT_METER_CODEX'] = str(fake)
                profile = root/'profile'; profile.mkdir()
                subprocess.run([str(APP.parent/'agent-relay'),'import','test','--profile',str(profile)], env=env, check=True, capture_output=True)
                registry = root/'accounts.json'
                data = json.loads(registry.read_text()); data['accounts'][0]['quota']['fetchedAt'] = 0
                registry.write_text(json.dumps(data))
                fake.write_text(FAKE.replace("if method=='account/read':", "if method=='account/read':\n  (profile/'started').touch();time.sleep(2);(profile/'finished').touch()"))
            processes = []
            def start(*args):
                p = subprocess.Popen([str(APP), '--verify-lifecycle', *args], env=env,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                processes.append(p)
                return p
            try:
                manager = start('--manage') if with_manager else None
                if manager:
                    deadline = time.monotonic()+10
                    while not (root/'window.pid').exists():
                        self.assertIsNone(manager.poll())
                        self.assertLess(time.monotonic(),deadline)
                        time.sleep(.05)
                menu = start()
                time.sleep(1)
                self.assertIsNone(menu.poll())
                # The duplicate terminates itself, without coordinating global quit.
                duplicate = start()
                self.assertEqual(duplicate.wait(timeout=10),0)
                self.assertIsNone(menu.poll())
                if manager: self.assertIsNone(manager.poll())
                if slow_worker:
                    deadline = time.monotonic()+10
                    while not (profile/'started').exists():
                        self.assertLess(time.monotonic(),deadline)
                        time.sleep(.05)
                (root/'test-quit').touch()
                self.assertEqual(menu.wait(timeout=15),0)
                if slow_worker: self.assertTrue((profile/'finished').exists())
                if manager:
                    self.assertEqual(manager.wait(timeout=5),0)
                    self.assertFalse((root/'window.pid').exists())
            finally:
                for p in processes:
                    if p.poll() is None:
                        p.terminate()
                        try: p.wait(timeout=5)
                        except subprocess.TimeoutExpired: p.kill();p.wait()
                    p.stderr.close()
    def test_quit_closes_manager(self): self.exercise(True)
    def test_quit_without_manager(self): self.exercise(False)
    def test_quit_waits_for_worker(self): self.exercise(True, slow_worker=True)

if __name__ == '__main__': unittest.main()
