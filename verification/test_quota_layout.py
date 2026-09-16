"""Render real AppKit layouts with changing quota data, without showing windows."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/Agent Meter Preview.app/Contents/MacOS/AgentMeterPreview'

class QuotaLayoutTests(unittest.TestCase):
    def test_track_width_stays_constant_across_accounts_and_refresh_data(self):
        with tempfile.TemporaryDirectory() as directory:
            def quota(used, minutes):
                return dict(usedPercent=used, windowDurationMins=minutes, resetsAt=1800000000)
            def account(index, primary, secondary):
                return dict(id=str(index), alias='Account '+str(index), provider='codex', email='test@example.invalid', plan='pro', profilePath=directory, managed=False, createdAt=0,
                            quota=dict(primary=primary, secondary=secondary, fetchedAt=0, resetCards=0))
            snapshots = [
                [account(0,quota(0,10080),None),account(1,quota(100,10080),None)],
                [account(0,quota(13,300),quota(77,10080)),account(1,quota(100,10080),None)],
                [account(0,None,None),account(1,quota(9,300),quota(1,10080))],
            ]
            baseline = None
            for accounts in snapshots:
                (Path(directory)/'accounts.json').write_text(json.dumps(dict(version=1,accounts=accounts,selectedID='0')))
                proc = subprocess.run([str(APP),'--verify-quota-layout'],env=dict(os.environ,AGENT_METER_HOME=directory),text=True,capture_output=True,check=True,timeout=20)
                sizes=json.loads(proc.stdout)
                for widths in sizes:
                    self.assertGreaterEqual(len(widths),2)
                    self.assertGreater(min(widths),100)
                    self.assertLess(max(widths)-min(widths),0.5, widths)
                current=[widths[0] for widths in sizes]
                if baseline is None: baseline=current
                else:
                    for before,after in zip(baseline,current): self.assertAlmostEqual(before,after,delta=0.5)

if __name__ == '__main__': unittest.main()
