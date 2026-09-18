#!/usr/bin/env python3
"""Sign the release archive; never print or persist CI signing credentials."""
import base64
from datetime import datetime, timezone
from email.utils import format_datetime
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
info = plistlib.loads((root/'dist/Agent Relay.app/Contents/Info.plist').read_bytes())
version = info['CFBundleShortVersionString']
archive = root/f'dist/Agent-Relay-{version}-macos-arm64.dmg'
signer = root/'.build/artifacts/sparkle/Sparkle/bin/sign_update'
key = os.environ.get('SPARKLE_PRIVATE_KEY')
args = [str(signer), '--ed-key-file']
if key:
    args += ['-']
else:
    args += [str(Path.home()/'.config/agent-relay/private/sparkle-ed25519.key')]
signature = subprocess.run(args+['-p',str(archive)], input=key, text=True, capture_output=True, check=True).stdout.strip()
assert len(base64.b64decode(signature, validate=True)) == 64
# Check against the PUBLIC key embedded in the application, not just the signer key.
subprocess.run(['swift', str(root/'scripts/VerifyUpdate.swift'), str(archive), info['SUPublicEDKey'], signature], check=True)
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
rss = ET.Element('rss', {'version':'2.0'})
channel = ET.SubElement(rss,'channel')
ET.SubElement(channel,'title').text='Agent Relay Updates'
item = ET.SubElement(channel,'item')
ET.SubElement(item,'title').text=f'Agent Relay {version}'
ET.SubElement(item,'pubDate').text=format_datetime(datetime.now(timezone.utc))
ET.SubElement(item,f'{{{ns}}}minimumSystemVersion').text='26.0'
ET.SubElement(item,'enclosure', {
    'url':f'https://github.com/Vagrant-Zero/agent-relay/releases/download/v{version}/{archive.name}',
    'length':str(archive.stat().st_size), 'type':'application/octet-stream',
    f'{{{ns}}}version':info['CFBundleVersion'], f'{{{ns}}}shortVersionString':version,
    f'{{{ns}}}edSignature':signature})
ET.indent(rss)
ET.ElementTree(rss).write(root/'dist/appcast.xml',encoding='utf-8',xml_declaration=True)
print('Signed update feed:',version)
