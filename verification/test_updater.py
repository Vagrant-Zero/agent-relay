"""Read a local appcast through Sparkle; isolated bundle ID, no windows/install/network accounts."""
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[1]
FRAMEWORKS=ROOT/'dist/Agent Relay.app/Contents/Frameworks'
class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
class UpdaterTests(unittest.TestCase):
    def test_detects_update_and_rejects_bad_feed(self):
        with tempfile.TemporaryDirectory(prefix='relay-updater-') as directory:
            root=Path(directory); probe=root/'probe'
            subprocess.run(['swiftc',str(ROOT/'verification/updater_probe.swift'),'-F',str(FRAMEWORKS),'-framework','Sparkle','-Xlinker','-rpath','-Xlinker',str(FRAMEWORKS),'-o',str(probe)],check=True,capture_output=True)
            server=ThreadingHTTPServer(('127.0.0.1',0),partial(QuietHandler,directory=directory))
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                app=root/'Probe.app';(app/'Contents/MacOS').mkdir(parents=True)
                executable=app/'Contents/MacOS/probe';executable.write_bytes(probe.read_bytes());executable.chmod(0o700)
                info=plistlib.loads((ROOT/'Resources/Info.plist').read_bytes())
                info.update(CFBundleIdentifier='dev.agent-relay.test.'+uuid.uuid4().hex,CFBundleExecutable='probe',CFBundleVersion='0.1.0',CFBundleShortVersionString='0.1.0',SUEnableAutomaticChecks=False,SUFeedURL=f'http://127.0.0.1:{server.server_port}/appcast.xml',NSAppTransportSecurity={'NSAllowsLocalNetworking':True})
                plist=app/'Contents/Info.plist';plist.write_bytes(plistlib.dumps(info))
                feed=root/'appcast.xml'
                feed.write_text('''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Test</title><item><title>2.0.0</title><enclosure url="https://example.invalid/update.zip" length="1" type="application/octet-stream" sparkle:version="2.0.0"/></item></channel></rss>''')
                result=subprocess.run([str(probe),str(app)],capture_output=True,text=True,timeout=25)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('available:2.0.0',result.stdout)
                feed.write_text('invalid XML')
                result=subprocess.run([str(probe),str(app)],capture_output=True,text=True,timeout=25)
                self.assertEqual(result.returncode,1,result.stdout+result.stderr)
            finally:
                server.shutdown();server.server_close();thread.join(timeout=2)
                subprocess.run(['defaults','delete',info['CFBundleIdentifier']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
if __name__=='__main__':unittest.main()
