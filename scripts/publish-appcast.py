#!/usr/bin/env python3
"""Publish a feed only after its archive exists, without rewriting app source."""
import base64
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

repo = os.environ.get('GH_REPO','Vagrant-Zero/agent-relay')
root = Path(__file__).resolve().parents[1]
feed = (root/'dist/appcast.xml').read_bytes()
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
def version(data):
    return tuple(map(int,ET.fromstring(data).find('channel/item/enclosure').attrib[ns+'version'].split('.')))
def api(path, payload=None, optional=False):
    args=['gh','api',f'repos/{repo}/{path}']
    if payload is not None: args += ['--method','POST' if path=='git/refs' else 'PUT','--input','-']
    p=subprocess.run(args,input=json.dumps(payload) if payload is not None else None,text=True,capture_output=True)
    if p.returncode and not (optional and '404' in p.stderr):
        raise RuntimeError(p.stderr)
    return json.loads(p.stdout) if p.returncode==0 else None
if api('git/ref/heads/updates',optional=True) is None:
    sha = api('git/ref/heads/main')['object']['sha']
    api('git/refs',{'ref':'refs/heads/updates','sha':sha})
current = api('contents/appcast.xml?ref=updates',optional=True)
if current and version(base64.b64decode(current['content'])) > version(feed):
    print('A newer update feed is already published; leaving it in place.')
else:
    payload=dict(message='Publish signed Agent Relay update feed',branch='updates',content=base64.b64encode(feed).decode())
    if current: payload['sha']=current['sha']
    api('contents/appcast.xml',payload)
    print('Published appcast to updates branch')
