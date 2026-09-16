#!/usr/bin/env python3
"""Measure all Preview-owned resident processes in bytes (not virtual size/RSS)."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/Agent Relay.app/Contents/MacOS/AgentRelay'


def footprint(pid):
    result = subprocess.run(['/usr/bin/footprint', '-p', str(pid), '-f', 'bytes', '--noCategories'], capture_output=True, text=True, timeout=30)
    match = re.search(r'phys_footprint:\s*([\d,]+)', result.stdout)
    if not match:
        raise RuntimeError('footprint did not return a byte count')
    return int(match.group(1).replace(',', ''))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--home', required=True, type=Path)
    parser.add_argument('--cycles', type=int, default=10)
    parser.add_argument('--bridge-pid', type=int)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    env = dict(os.environ, AGENT_METER_HOME=str(args.home))
    marker = args.home / 'menu-smoke-done'
    marker.unlink(missing_ok=True)
    resident = subprocess.Popen([str(APP), '--smoke-menu-cycles', str(args.cycles)], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    samples = []
    def sample(phase):
        own = footprint(resident.pid)
        bridge = footprint(args.bridge_pid) if args.bridge_pid else 0
        record = {'phase': phase, 'menu_bytes': own, 'bridge_bytes': bridge, 'total_bytes': own+bridge}
        samples.append(record)
        print(json.dumps(record), flush=True)
    try:
        deadline = time.monotonic()+30
        while not marker.exists() and resident.poll() is None and time.monotonic()<deadline: time.sleep(.1)
        if not marker.exists(): raise RuntimeError('menu smoke did not finish')
        sample('after-menu-cycles')
        for index in range(args.cycles):
            result = subprocess.run([str(APP), '--manage', '--smoke-seconds', '0.3'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)
            if result.returncode != 0: raise RuntimeError('manager did not close cleanly')
            if index in [0, args.cycles-1]: sample('after-window-cycle-'+str(index+1))
        time.sleep(3)
        sample('settled')
        leak = subprocess.run(['/usr/bin/leaks', str(resident.pid)], capture_output=True, text=True, timeout=30)
        summary = re.findall(r'\d+ leaks? for \d+ total leaked bytes', leak.stdout)
        result = {'accounts':len(json.loads((args.home/'accounts.json').read_text())['accounts']),
                  'menu_cycles':args.cycles,'window_cycles':args.cycles,'samples':samples,
                  'within_30mb':all(x['total_bytes']<=30_000_000 for x in samples),
                  'leaks_summary':summary,'leaks_exit_code':leak.returncode,
                  'eight_hour_soak_completed':False}
        if args.output: args.output.write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps({k:v for k,v in result.items() if k!='samples'}),flush=True)
    finally:
        resident.terminate();resident.wait(timeout=10)
        marker.unlink(missing_ok=True)

if __name__ == '__main__': main()
