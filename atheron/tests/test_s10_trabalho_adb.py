"""Tests for atheron/s10-trabalho-adb: the policy (decide/check_shell/SyncFilter) and the proxy end to end."""
import asyncio
import gc
import importlib.machinery
import importlib.util
import os
import shutil
import socket
import struct
import subprocess
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("s10_trabalho_adb", os.path.join(HERE, "..", "s10-trabalho-adb"))
_spec = importlib.util.spec_from_loader("s10_trabalho_adb", _loader)
m = importlib.util.module_from_spec(_spec)
_loader.exec_module(m)

CFG = {"uids": {os.getuid()}, "deny_tcp": {5555, 5900, 8022}}

# requests captured from the real adb 1.0.41 client (adb devices, shell, logcat, forward, push, install, uninstall)
# plus what Flutter and Gradle send
ALLOWED = [
    "host:version", "host:devices", "host:devices-l", "host:track-devices", "host-serial:SER123:features",
    "host-serial:adb-SER-x._adb-tls-connect._tcp:get-state",
    "host:tport:serial:SER123", "host:transport:SER123", "host:transport-any", "host:list-forward",
    "host:forward:tcp:0;tcp:1234", "host-serial:SER123:forward:tcp:45123;tcp:43000",
    "host:forward:norebind:tcp:50000;localabstract:flutter", "host:forward:tcp:0;jdwp:4321",
    "host:killforward:tcp:45123", "host-serial:SER123:wait-for-any-device",
    "shell,v2,TERM=tmux-256color,raw:getprop ro.product.model",
    "shell,v2,TERM=tmux-256color:export ANDROID_LOG_TAGS=\"''\"; exec logcat '-d'",
    "shell:logcat -v time -s flutter", "shell,v2,raw:pm list packages com.example.app",
    "shell,v2,TERM=x:cmd package 'uninstall' 'com.example.app'",
    "shell:am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x20000000 "
    "--ez enable-dart-profiling true com.example.app/com.example.app.MainActivity",
    "shell:am force-stop com.example.app", "shell:pm clear com.example.app", "shell:logcat -b crash -d",
    "shell:monkey -p com.example.app -v --throttle 100 50", "shell:dumpsys meminfo com.example.app",
    "shell:echo -n 3f2a > /data/local/tmp/sky.com.example.app.sha1", "shell:cat /data/local/tmp/sky.com.example.app.sha1",
    "shell:rm -f /data/local/tmp/app.apk", "shell:mkdir -p /data/local/tmp/x", "shell:ls /sdcard",
    "shell:dumpsys package com.example.app", "shell:settings get global animator_duration_scale", "shell:wm size",
    "shell:run-as com.example.app ls", "shell:monkey -p com.example.app 1", "shell:uiautomator dump /data/local/tmp/u.xml",
    "shell:screencap -p /data/local/tmp/s.png", "exec:screencap '-p'", "exec:cmd package install-create -r -t -S 3000",
    "abb_exec:settings\0get\0enable_adb_incremental_install_default", "abb_exec:package\0install\0-r\0-S\0003000",
    "sync:", "jdwp:4321", "track-jdwp", "track-app", "framebuffer:", "tcp:43000", "localabstract:scrcpy",
]
ATTACKS = [
    "host:kill", "host:connect:192.0.2.1:5555", "host-serial:SER:connect:192.0.2.1:22", "host:disconnect:",
    "host:pair:123456:192.0.2.1:37000", "host:mdns:services", "host:reconnect", "host-serial:SER:killforward-all",
    "host:forward:tcp:15900;tcp:5900", "host:forward:tcp:0;tcp:5900", "host:forward:tcp:0;tcp:8022",
    "host:forward:tcp:80;tcp:1234", "host:forward:tcp:0;localfilesystem:/data/x", "host:forward:tcp:0;dev:/dev/x",
    "host:killforward:tcp:27183", "host-serial:x:features:connect:192.0.2.1:22",
    "shell:", "shell,v2,TERM=x,raw:", "shell:nc 192.168.1.1 22", "shell:toybox nc 192.168.1.1 22",
    "shell:sh -c 'nc 192.168.1.1 22'", "shell:echo a;nc 192.168.1.1 22", "shell:echo a && nc x 1", "shell:echo a | nc x 1",
    "shell:echo $(nc x 1)", "shell:echo `id`", 'shell:echo "$(id)"', "shell:echo a\nnc x 1", "shell:ls /sdcard/*",
    "shell:echo x > /sdcard/Download/s10-dev/run.sh", "shell:cat /sdcard/x", "shell:rm -rf /sdcard",
    "shell:rm -rf /data/local/tmp/../../../sdcard", "shell:pm uninstall com.termux", "shell:pm disable-user com.tailscale.ipn",
    "shell:pm clear net.christianbeier.droidvnc_ng", "shell:cmd package uninstall moe.shizuku.privileged.api",
    "shell:am start -n com.termux/.app.TermuxActivity", "shell:am force-stop com.tailscale.ipn",
    "shell:am broadcast -n com.termux.boot/.BootReceiver", "shell:pm grant com.termux android.permission.X",
    "shell:pm set-home-activity com.example/.X", "shell:am stack list", "shell:settings put global adb_enabled 0",
    "shell:input text hello", "shell:input tap 1 1", "shell:monkey 100", "shell:monkey -p com.termux 1",
    "shell:run-as com.termux ls", "shell:run-as com.example.app nc 192.168.1.1 22", "shell:run-as com.example.app run-as x ls",
    "shell:uiautomator runtest x", "shell:wm size 100x100", "shell:screencap /sdcard/x.png", "shell:curl http://192.168.1.1",
    "exec:sh", "exec:nc 192.168.1.1 22", "abb_exec:package\0uninstall\0com.termux", "abb_exec:settings\0put\0global\0x\0y",
    "abb_exec:activity\0start\0x", "reverse:forward:tcp:8081;tcp:8081", "reverse:forward:tcp:1;tcp:22", "tcpip:5555",
    "usb:", "root:", "unroot:", "remount:", "reboot:", "backup:-all", "dev:/dev/block/sda", "dev-raw:/dev/tty",
    "sink:100", "source:100", "spin", "reconnect", "tcp:192.0.2.1:22", "tcp:5900", "tcp:8022", "localfilesystem:/x",
    "jdwp:abc", "whatever:", "",
    # from the adversarial review
    "shell:echo hello > /sdcard/x \"'\"", "shell:echo hello >> /sdcard/x \"'\"", "shell:echo a > /data/local/tmp",
    "shell:echo a > /data/local/tmp/x b", "shell:echo a 2>/sdcard/x", "shell:run-as com.example.app echo x > /sdcard/y \"'\"",
    "shell:logcat -v raw -f /sdcard/evil -d", "shell:logcat -c", "shell:logcat -G 16M", "shell:logcat -r 1 -n 2",
    "shell:am instrument -w com.mine.test/androidx.test.runner.AndroidJUnitRunner",
    "shell:pm grant com.mine android.permission.WRITE_SECURE_SETTINGS", "shell:pm revoke com.mine android.permission.X",
    "abb_exec:package\0grant\0com.mine\0android.permission.WRITE_SECURE_SETTINGS",
    "shell:monkey -p com.mine --port 1080", "shell:monkey -p com.mine -f /data/local/tmp/s.txt 1", "shell:monkey -p com.mine",
    "shell:pm clear com.android.systemui", "shell:pm uninstall --user 0 com.android.shell", "shell:am force-stop com.android.systemui",
    "shell:am kill android", "abb_exec:package\0uninstall\0com.samsung.android.app.x", "shell:run-as com.android.shell ls",
    "shell:dumpsys battery set level 1", "shell:dumpsys deviceidle whitelist +com.mine", "shell:dumpsys notification --noredact",
    "shell:dumpsys", "shell:rm -rf /data/local/tmp", "shell:chmod -R 777 /data/local/tmp",
    "shell:chmod --reference=/sdcard/a /data/local/tmp/b", "shell:screenrecord x.mp4", "shell:screencap -p /sdcard/s.png",
    "host-serial:a:b:get-state", "host-serial:192.0.2.5:37215:features", "host-transport-id:5:x:get-state",
    "host-serial:SER:connect:1.2.3.4:5", "host:tport:serial:SER\x01", "tcp:5555", "shell:ls --color=never /sdcard",
    "shell:echo !!", "shell:echo #x > /sdcard/a",
]


class Policy(unittest.TestCase):
    def test_real_client_requests_allowed(self):
        for req in ALLOWED:
            ok, why, _ = m.decide(req, CFG)
            self.assertTrue(ok, "%r was refused: %s" % (req, why))

    def test_attacks_refused(self):
        for req in ATTACKS:
            ok, why, _ = m.decide(req, CFG)
            self.assertFalse(ok, "%r was allowed (%s)" % (req, why))

    def test_kinds(self):
        self.assertEqual(m.decide("host:tport:serial:SER", CFG)[2], "transport")
        self.assertEqual(m.decide("host:transport-any", CFG)[2], "transport")
        self.assertEqual(m.decide("sync:", CFG)[2], "sync")
        self.assertEqual(m.decide("host:devices", CFG)[2], "host")
        self.assertEqual(m.decide("host:forward:tcp:0;tcp:1234", CFG)[2], "host")
        self.assertEqual(m.decide("shell:getprop", CFG)[2], "pipe")

    def test_work_package_prefixes(self):
        cfg = dict(CFG, pkgs=("br.com.empresa",))
        self.assertTrue(m.decide("shell:pm clear br.com.empresa.app", cfg)[0])
        self.assertFalse(m.decide("shell:pm clear com.example.app", cfg)[0])          # not a work app
        self.assertFalse(m.decide("shell:pm clear br.com.empresax.app", cfg)[0])      # prefix must end at a dot
        self.assertTrue(m.decide("shell:run-as br.com.empresa.app ls", cfg)[0])
        self.assertTrue(m.decide("shell:pm clear com.example.app", CFG)[0])           # unset: any non-system app

    def test_mode_parsing_like_adbd(self):
        self.assertEqual(m.parse_mode("33188"), 0o100644)
        self.assertEqual(m.parse_mode("0120777"), 0o120777)
        self.assertEqual(m.parse_mode("0xA1FF"), 0o120777)
        self.assertIsNone(m.parse_mode(" 0120777"))
        self.assertIsNone(m.parse_mode("0o120777"))
        self.assertTrue(m.regular_mode(0o644) and m.regular_mode(0o100644))
        self.assertFalse(m.regular_mode(0o120777) or m.regular_mode(0o020644) or m.regular_mode(None))

    def test_deny_tcp_is_configurable(self):
        self.assertTrue(m.decide("tcp:5900", {"deny_tcp": set()})[0])
        self.assertFalse(m.decide("tcp:43000", {"deny_tcp": {43000}})[0])

    def test_reasons_are_readable(self):
        self.assertIn("lista", m.decide("shell:nc 1.2.3.4 1", CFG)[1])
        self.assertIn("interativo", m.decide("shell:", CFG)[1])
        self.assertIn("protegido", m.decide("shell:pm uninstall com.termux", CFG)[1])


def frame(ident, n, payload=b""):
    return ident + struct.pack("<I", n) + payload


class Sync(unittest.TestCase):
    def run_stream(self, data, step=None):
        f = m.SyncFilter()
        out, err = b"", None
        chunks = [data] if step is None else [data[i:i + step] for i in range(0, len(data), step)]
        for c in chunks:
            o, err = f.feed(c)
            out += o
            if err:
                break
        return out, err

    def test_push_to_tmp_passes_byte_for_byte(self):
        path = b"/data/local/tmp/app.apk"
        data = (frame(b"SND2", len(path), path) + frame(b"SND2", 0o100644) + struct.pack("<I", 0) +
                frame(b"DATA", 5, b"hello") + frame(b"DONE", 1700000000) + frame(b"QUIT", 0))
        for step in (None, 1, 3, 7):
            out, err = self.run_stream(data, step)
            self.assertIsNone(err)
            self.assertEqual(out, data)

    def test_v1_send_and_stat_in_tmp(self):
        p = b"/data/local/tmp/x,33188"
        data = frame(b"SEND", len(p), p) + frame(b"DATA", 2, b"ab") + frame(b"DONE", 0) + frame(b"STA2", 15, b"/data/local/tmp")
        self.assertEqual(self.run_stream(data), (data, None))

    def test_paths_outside_tmp_refused(self):
        for ident, path in ((b"RCV2", b"/sdcard/DCIM/x.jpg"), (b"SND2", b"/sdcard/Download/s10-dev/run.sh"),
                            (b"STA2", b"/sdcard/x.txt"), (b"LIS2", b"/sdcard"), (b"RECV", b"/data/local/tmp/../../../sdcard/x"),
                            (b"SEND", b"/data/local/tmpx/a,33188")):
            out, err = self.run_stream(frame(ident, len(path), path))
            self.assertIsNotNone(err, path)
            self.assertEqual(out, b"")

    def test_symlink_in_any_base_refused(self):
        for mode in (b"0120777", b"0xA1FF", b"0XA1FF", b"41471", b" 41471", b"0o120777", b"", b"33188x"):
            p = b"/data/local/tmp/l," + mode
            self.assertIsNotNone(self.run_stream(frame(b"SEND", len(p), p))[1], mode)
        p = b"/data/local/tmp/ok,0644"
        self.assertIsNone(self.run_stream(frame(b"SEND", len(p), p))[1])

    def test_nul_and_invalid_bytes_refused(self):
        for path in (b"/data/local/tmp/..\0/x", b"/data/local/tmp/\xff\xfe"):
            self.assertIsNotNone(self.run_stream(frame(b"STA2", len(path), path))[1], path)

    def test_send_to_the_tmp_dir_itself_refused(self):
        p = b"/data/local/tmp,33188"
        self.assertIsNotNone(self.run_stream(frame(b"SEND", len(p), p))[1])

    def test_symlink_refused(self):
        p = b"/data/local/tmp/l"
        v2 = frame(b"SND2", len(p), p) + frame(b"SND2", 0o120777) + struct.pack("<I", 0)
        self.assertIsNotNone(self.run_stream(v2)[1])
        v1 = b"/data/local/tmp/l,%d" % 0o120777
        self.assertIsNotNone(self.run_stream(frame(b"SEND", len(v1), v1))[1])

    def test_data_payload_is_not_parsed_as_commands(self):
        p = b"/data/local/tmp/a"
        evil = frame(b"RCV2", 6, b"/sdcard")       # looks like a request, but it is file content
        data = frame(b"SND2", len(p), p) + frame(b"SND2", 0o100644) + struct.pack("<I", 0) + frame(b"DATA", len(evil), evil)
        self.assertEqual(self.run_stream(data, 4), (data, None))

    def test_refusal_shapes(self):
        self.assertEqual(len(m.sync_refusal(b"STA2", "x")), 72)
        self.assertEqual(struct.unpack("<I", m.sync_refusal(b"STA2", "x")[4:8])[0], 13)
        self.assertEqual(m.sync_refusal(b"STAT", "x"), b"STAT" + b"\0" * 12)
        self.assertTrue(m.sync_refusal(b"LIS2", "x").startswith(b"DONE"))
        self.assertTrue(m.sync_refusal(b"RCV2", "fora").startswith(b"FAIL"))
        f = m.SyncFilter()
        f.feed(frame(b"STA2", 7, b"/sdcar"))
        self.assertIsNone(f.refused)                     # incomplete: not judged yet
        f.feed(b"d")
        self.assertEqual(f.refused, b"STA2")

    def test_unknown_message_refused(self):
        self.assertIsNotNone(self.run_stream(frame(b"XXXX", 0))[1])


class FakeServer(threading.Thread):
    """Minimal adb server on a unix socket: records requests, answers like the real one would."""

    def __init__(self, path):
        super().__init__(daemon=True)
        self.path, self.requests, self.streams = path, [], []
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.bind(path)
        self.sock.listen(8)

    def run(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.handle, args=(c,), daemon=True).start()

    def handle(self, c):
        with c:
            while True:
                n = c.recv(4)
                if len(n) < 4:
                    return
                req = b""
                while len(req) < int(n, 16):
                    req += c.recv(int(n, 16) - len(req))
                r = req.decode("latin-1")
                self.requests.append(r)
                if r == "host:version":
                    c.sendall(b"OKAY00040029")
                    return
                if r == "host:devices":
                    body = b"SER123\tdevice\n"
                    c.sendall(b"OKAY%04x" % len(body) + body)
                    return
                if r.startswith("host:tport:"):
                    c.sendall(b"OKAY" + struct.pack("<Q", 9))
                    continue
                if r.startswith("host:transport:BAD"):
                    c.sendall(b"FAIL0010device not found")
                    return
                try:
                    c.sendall(b"OKAY")
                except OSError:
                    return
                data = b""
                while True:
                    try:
                        chunk = c.recv(65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    data += chunk
                self.streams.append(data)
                try:
                    c.sendall(b"Success\n")
                except OSError:
                    pass
                return


def raw(path, *reqs, body=b"", half_close=True):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(5)
    s.connect(path)
    for r in reqs:
        s.sendall(b"%04x" % len(r) + r)
    if body:
        s.sendall(body)
    if half_close:
        s.shutdown(socket.SHUT_WR)
    out = b""
    while True:
        try:
            chunk = s.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        out += chunk
    s.close()
    return out


class Proxy(unittest.TestCase):
    def setUp(self):
        gc.collect()   # finalize sockets of earlier tests now, not later on a reused fd number
        self.d = tempfile.mkdtemp()
        self.up = os.path.join(self.d, "up.sock")
        self.listen = os.path.join(self.d, "broker.sock")
        self.server = FakeServer(self.up)
        self.server.start()
        self.cfg = {"uids": {os.getuid()}, "deny_tcp": {5900, 8022}, "listen": self.listen, "upstream": self.up}
        self.logs = []
        m.log = self.logs.append
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.thread.start()
        asyncio.run_coroutine_threadsafe(self._start(), self.loop).result(5)

    async def _start(self):
        self.srv = await asyncio.start_unix_server(lambda r, w: m.handle(r, w, self.cfg), path=self.listen)

    def tearDown(self):
        async def stop():
            self.srv.close()
            # finish every connection handler of this test before its loop goes away
            tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await self.srv.wait_closed()
        asyncio.run_coroutine_threadsafe(stop(), self.loop).result(5)
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(5)
        self.loop.close()
        self.server.sock.close()
        shutil.rmtree(self.d)

    def test_query_passes(self):
        self.assertEqual(raw(self.listen, b"host:version"), b"OKAY00040029")
        self.assertIn(b"SER123\tdevice", raw(self.listen, b"host:devices"))

    def test_refusal_never_reaches_the_server(self):
        out = raw(self.listen, b"host:connect:192.0.2.1:22")
        self.assertTrue(out.startswith(b"FAIL"))
        self.assertIn(b"recusado", out)
        self.assertNotIn("host:connect:192.0.2.1:22", self.server.requests)
        self.assertTrue(any(l.startswith("RECUSADO") for l in self.logs))

    def test_transport_then_service_then_stream_both_ways(self):
        apk = os.urandom(70000)
        out = raw(self.listen, b"host:tport:serial:SER123", b"abb_exec:package\0install\0-S\00070000", body=apk)
        self.assertEqual(out[:12], b"OKAY" + struct.pack("<Q", 9))
        self.assertEqual(out[12:16], b"OKAY")
        self.assertTrue(out.endswith(b"Success\n"), out[-40:])   # answer after the half-close
        self.assertEqual(self.server.streams[-1], apk)

    def test_refused_service_after_transport(self):
        out = raw(self.listen, b"host:tport:serial:SER123", b"shell:nc 192.168.1.1 22")
        self.assertTrue(out[12:].startswith(b"FAIL"))
        self.assertNotIn("shell:nc 192.168.1.1 22", self.server.requests)

    def test_transport_failure_relayed(self):
        out = raw(self.listen, b"host:transport:BAD")
        self.assertEqual(out, b"FAIL0010device not found")

    def test_sync_outside_tmp_cut(self):
        path = b"/sdcard/x"
        raw(self.listen, b"host:tport:serial:SER123", b"sync:", body=frame(b"RCV2", len(path), path) + frame(b"RCV2", 0))
        self.assertNotIn(path, b"".join(self.server.streams))   # the forbidden request never reached the server
        self.assertTrue(any("fora de /data/local/tmp" in l for l in self.logs), self.logs)

    def test_host_request_is_one_shot(self):
        # bytes after a host request (a second request) never reach the server
        out = raw(self.listen, b"host:devices", b"host:connect:192.0.2.1:22")
        self.assertIn(b"SER123", out)
        self.assertNotIn("host:connect:192.0.2.1:22", self.server.requests)

    def test_bad_header_closes(self):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        s.connect(self.listen)
        s.sendall(b"-001host:kill")
        self.assertEqual(s.recv(100), b"")
        s.close()
        self.assertNotIn("host:kill", self.server.requests)

    def test_connection_limit(self):
        self.cfg["max_conn"] = 0
        out = raw(self.listen, b"host:version")
        self.assertIn(b"demais", out)

    def test_wrong_uid_refused(self):
        self.cfg["uids"] = {os.getuid() + 12345}
        out = raw(self.listen, b"host:version")
        self.assertTrue(out.startswith(b"FAIL"))
        self.assertIn(b"uid", out)
        self.assertEqual(self.server.requests, [])

    @unittest.skipUnless(shutil.which("adb"), "adb not installed")
    def test_real_adb_client(self):
        env = dict(os.environ, ADB_SERVER_SOCKET="localfilesystem:" + self.listen)
        r = subprocess.run(["adb", "devices"], env=env, capture_output=True, text=True, timeout=10)
        self.assertIn("SER123", r.stdout)
        r = subprocess.run(["adb", "connect", "192.0.2.1:5555"], env=env, capture_output=True, text=True, timeout=10)
        self.assertIn("recusado", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
