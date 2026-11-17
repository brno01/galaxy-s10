import importlib.machinery
import importlib.util
import json
import os
import re
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
_loader = importlib.machinery.SourceFileLoader("cerberus_s10", os.path.join(HERE, "..", "cerberus-s10"))
_spec = importlib.util.spec_from_loader("cerberus_s10", _loader)
m = importlib.util.module_from_spec(_spec)
_loader.exec_module(m)


def fx(name):
    with open(os.path.join(FIX, name)) as f:
        return f.read()


class ParseDevices(unittest.TestCase):
    def test_ok(self):
        d = m.parse_devices(fx("devices_ok.txt"))
        self.assertEqual(d, [{"serial": "R58M12ABCDE", "state": "device", "model": "SM_G973F"}])

    def test_unauthorized_with_daemon_noise(self):
        d = m.parse_devices(fx("devices_unauthorized.txt"))
        self.assertEqual(len(d), 1)
        self.assertEqual(d[0]["state"], "unauthorized")

    def test_none(self):
        self.assertEqual(m.parse_devices(fx("devices_none.txt")), [])

    def test_select(self):
        a = {"serial": "A", "state": "device", "model": "SM_G973F"}
        b = {"serial": "B", "state": "device", "model": "Pixel_6"}
        self.assertEqual(m.select_device([a]), a)
        self.assertEqual(m.select_device([a, b]), a)
        self.assertIsNone(m.select_device([b, dict(b, serial="C")]))
        self.assertEqual(m.select_device([a, b], "B"), b)
        self.assertIsNone(m.select_device([a], "Z"))
        self.assertIsNone(m.select_device([]))


class ParseDumpsys(unittest.TestCase):
    def test_battery(self):
        b = m.parse_battery(fx("battery_a12.txt"))
        self.assertEqual(b["nivel"], 87)
        self.assertAlmostEqual(b["temperatura_c"], 31.2)
        self.assertEqual(b["status"], "charging")
        self.assertEqual(b["plugado"], ["usb"])
        self.assertEqual(b["saude"], "good")
        self.assertEqual(b["tensao_mv"], 4123)

    def test_battery_hot_full(self):
        self.assertEqual(m.parse_battery(fx("battery_hot.txt"))["saude"], "overheat")
        self.assertAlmostEqual(m.parse_battery(fx("battery_hot.txt"))["temperatura_c"], 46.8)
        f = m.parse_battery(fx("battery_full.txt"))
        self.assertEqual((f["nivel"], f["status"]), (100, "full"))

    def test_battery_garbage(self):
        self.assertIsNone(m.parse_battery(""))
        self.assertIsNone(m.parse_battery("error: closed"))

    def test_wakefulness(self):
        self.assertEqual(m.parse_wakefulness(fx("power_awake.txt")), "Awake")
        self.assertEqual(m.parse_wakefulness(fx("power_asleep.txt")), "Asleep")
        self.assertIsNone(m.parse_wakefulness(""))

    def test_wifi(self):
        self.assertEqual(m.parse_wifi(fx("wifi_on.txt")), {"ligado": True, "conectado": True})
        self.assertEqual(m.parse_wifi(fx("wifi_off.txt")), {"ligado": False, "conectado": False})
        self.assertIsNone(m.parse_wifi("nope"))


def fake_run(devices, shell=True):
    def run(cmd):
        if cmd[1] == "start-server":
            return 0, ""
        if cmd[1] == "devices":
            return 0, fx(devices)
        if "battery" in cmd:
            return 0, fx("battery_a12.txt")
        if "power" in cmd:
            return 0, fx("power_awake.txt")
        if "wifi" in cmd:
            return 0, fx("wifi_on.txt")
        return 1, ""
    return run


class Collect(unittest.TestCase):
    def test_device(self):
        s = m.collect(fake_run("devices_ok.txt"), now=1000)
        self.assertTrue(s["conectado"])
        self.assertEqual(s["estado"], "device")
        self.assertEqual(s["bateria"]["nivel"], 87)
        self.assertEqual(s["tela"], "Awake")
        self.assertTrue(s["wifi"]["conectado"])
        self.assertEqual(s["timestamp"], "1970-01-01T00:16:40+00:00")
        json.dumps(s)

    def test_unauthorized(self):
        s = m.collect(fake_run("devices_unauthorized.txt"))
        self.assertFalse(s["conectado"])
        self.assertEqual(s["estado"], "unauthorized")
        self.assertIsNone(s["bateria"])

    def test_offline_and_absent(self):
        self.assertEqual(m.collect(fake_run("devices_offline.txt"))["estado"], "offline")
        s = m.collect(fake_run("devices_none.txt"))
        self.assertEqual((s["estado"], s["conectado"]), ("ausente", False))

    def test_adb_failure_is_absent(self):
        s = m.collect(lambda cmd: (255, ""))
        self.assertEqual(s["estado"], "ausente")

    def test_never_uses_dash_a(self):
        seen = []

        def run(cmd):
            seen.append(cmd)
            return fake_run("devices_ok.txt")(cmd)
        m.collect(run)
        self.assertTrue(all("-a" not in c for c in seen))


def snap(estado="device", nivel=50, temp=30.0):
    return {"estado": estado,
            "bateria": {"nivel": nivel, "temperatura_c": temp} if estado == "device" else None}


def full_snap():
    return {
        "timestamp": "2026-11-16T12:00:00+00:00", "epoch": 1000, "conectado": True, "estado": "device",
        "serial": "R58M12ABCDE",
        "bateria": {"nivel": 87, "temperatura_c": 31.2, "status": "charging", "plugado": ["usb"],
                    "saude": "good", "tensao_mv": 4123},
        "tela": "Awake", "wifi": {"ligado": True, "conectado": True, "ssid": "homenet"},
        "caminhos": {
            "usb": {"ok": True, "estado": "device"},
            "adb_sem_fio": {"ip_lan": "192.0.2.50", "porta": 37123, "ip_tailnet": "100.64.0.10",
                            "ok": False, "ok_tailnet": True, "ativa": "usb"},
            "tailscale": {"ok": True, "ip": "100.64.0.10"},
            "ssh_termux": {"ok": True, "porta": 8022},
            "vnc": {"ok": None, "porta": 5900, "loopback": None},
        },
        "guardiao": {"reparos": ["x"], "reparar": True, "shizuku": {"ok": True}},
    }


class PublicSummary(unittest.TestCase):
    def test_public_summary_whitelist(self):
        out = m.public_summary(full_snap(), m.Alerts(), 1000)
        self.assertEqual(set(out), {"versao", "gerado_em", "bateria", "caminhos", "avisos"})
        self.assertEqual(out["versao"], 1)
        self.assertEqual(out["gerado_em"], 1000)
        self.assertEqual(set(out["bateria"]), {"nivel", "status", "temperatura_c", "saude"})
        self.assertEqual(set(out["caminhos"]), {"usb", "adb_sem_fio", "tailscale", "ssh_termux", "vnc"})
        self.assertEqual(out["caminhos"], {"usb": True, "adb_sem_fio": False, "tailscale": True,
                                           "ssh_termux": True, "vnc": None})
        text = json.dumps(out)
        self.assertIsNone(re.search(r"\d+\.\d+\.\d+\.\d+", text))
        for secret in ("37123", "8022", "5900", "R58M12ABCDE", "homenet", "device", "guardiao", "serial"):
            self.assertNotIn(secret, text)

    def test_public_summary_unknown_path_is_null(self):
        s = full_snap()
        del s["caminhos"]["vnc"]
        del s["caminhos"]["tailscale"]["ok"]
        out = m.public_summary(s, m.Alerts(), 1000)
        self.assertIsNone(out["caminhos"]["vnc"])
        self.assertIsNone(out["caminhos"]["tailscale"])
        s.pop("caminhos")
        out = m.public_summary(s, m.Alerts(), 1000)
        self.assertEqual(out["caminhos"], {k: None for k in ("usb", "adb_sem_fio", "tailscale", "ssh_termux", "vnc")})

    def test_public_summary_no_battery(self):
        s = full_snap()
        s["bateria"] = None
        out = m.public_summary(s, m.Alerts(), 1000)
        self.assertIsNone(out["bateria"])
        self.assertEqual(out["avisos"], [])

    def test_public_summary_alert_codes(self):
        s = full_snap()
        s["bateria"]["temperatura_c"] = 46.0
        self.assertEqual(m.public_summary(s, m.Alerts(), 1000)["avisos"], ["temperatura"])
        s["bateria"].update(temperatura_c=30.0, nivel=100)
        a = m.Alerts(full_hours=1)
        self.assertEqual(m.public_summary(s, a, 1000)["avisos"], [])     # not tracked yet
        a.full_since = 1000 - 3600
        self.assertEqual(m.public_summary(s, a, 1000)["avisos"], ["carga_cheia"])
        a.full_since = 1000 - 3599
        self.assertEqual(m.public_summary(s, a, 1000)["avisos"], [])


class AlertsTest(unittest.TestCase):
    def test_temperature_warns_once_then_repeats_hourly(self):
        a = m.Alerts()
        self.assertEqual(a.evaluate(snap(temp=44.9), 0), [])
        self.assertEqual(len(a.evaluate(snap(temp=45.0), 60)), 1)
        self.assertEqual(a.evaluate(snap(temp=46), 120), [])
        self.assertEqual(len(a.evaluate(snap(temp=46), 60 + 3600)), 1)
        a.evaluate(snap(temp=30), 4000)
        self.assertEqual(len(a.evaluate(snap(temp=47), 4060)), 1)  # re-armed

    def test_unauthorized_and_recovery(self):
        a = m.Alerts()
        self.assertEqual(len(a.evaluate(snap("unauthorized"), 0)), 1)
        self.assertEqual(a.evaluate(snap("unauthorized"), 60), [])
        self.assertEqual(len(a.evaluate(snap("ausente"), 120)), 1)  # changed state
        back = a.evaluate(snap("device"), 180)
        self.assertEqual(len(back), 1)
        self.assertIn("back", back[0])

    def test_absent_repeats_after_hour(self):
        a = m.Alerts()
        a.evaluate(snap("ausente"), 0)
        self.assertEqual(a.evaluate(snap("ausente"), 3599), [])
        self.assertEqual(len(a.evaluate(snap("ausente"), 3600)), 1)

    def test_full_for_24h(self):
        a = m.Alerts()
        day = 86400
        self.assertEqual(a.evaluate(snap(nivel=100), 0), [])
        self.assertEqual(a.evaluate(snap(nivel=100), day - 60), [])
        self.assertEqual(len(a.evaluate(snap(nivel=100), day)), 1)
        self.assertEqual(a.evaluate(snap(nivel=100), day + 60), [])

    def test_full_resets_when_level_drops(self):
        a = m.Alerts()
        a.evaluate(snap(nivel=100), 0)
        a.evaluate(snap(nivel=99), 3600)
        self.assertEqual(a.evaluate(snap(nivel=100), 86400), [])

    def test_full_resets_when_absent(self):
        a = m.Alerts()
        a.evaluate(snap(nivel=100), 0)
        a.evaluate(snap("ausente"), 100)
        a.evaluate(snap(nivel=100), 160)
        self.assertEqual(a.evaluate(snap(nivel=100), 86400 + 100), [])


class AtomicWriter(unittest.TestCase):
    def test_write_mode_and_content(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "estado.json")
            m.write_atomic(p, {"a": "ação"})
            self.assertEqual(json.load(open(p)), {"a": "ação"})
            self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o644)
            self.assertEqual(os.listdir(d), ["estado.json"])

    def test_overwrite_and_no_leftover_on_failure(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "estado.json")
            m.write_atomic(p, {"v": 1})
            with self.assertRaises(TypeError):
                m.write_atomic(p, {"v": object()})
            self.assertEqual(json.load(open(p)), {"v": 1})
            self.assertEqual(os.listdir(d), ["estado.json"])


# ---------------------------------------------------------------- guardian
SECRET = "SEKRET-key-0123456789abcdef"  # gitleaks:allow (fake test value)
SERIAL = "R58M12ABCDE"
TS_IP = "100.64.0.10"


class GuardParsing(unittest.TestCase):
    def test_setting(self):
        self.assertEqual(m.parse_setting("7\n"), "7")
        self.assertEqual(m.parse_setting("null\n"), "")
        self.assertEqual(m.parse_setting(""), "")

    def test_wifi_status(self):
        self.assertTrue(m.parse_wifi_status(fx("cmd_wifi_status_on.txt")))
        self.assertFalse(m.parse_wifi_status(fx("cmd_wifi_status_off.txt")))
        self.assertIsNone(m.parse_wifi_status("error"))

    def test_pid_and_port(self):
        self.assertTrue(m.parse_pid("1234\n"))
        self.assertTrue(m.parse_pid("12 34\n"))
        self.assertFalse(m.parse_pid(""))
        self.assertFalse(m.parse_pid("error: not found"))
        self.assertEqual(m.parse_tls_port("37215\n"), 37215)
        self.assertIsNone(m.parse_tls_port("\n"))
        self.assertIsNone(m.parse_tls_port("0"))
        self.assertIsNone(m.parse_tls_port("abc"))

    def test_wifi_ip(self):
        self.assertEqual(m.parse_wifi_ip(fx("ip_wlan0.txt")), "192.0.2.20")
        self.assertIsNone(m.parse_wifi_ip(""))

    def test_listening(self):
        ports = m.parse_listening(fx("ss_ltn.txt"))
        self.assertEqual(ports[8022], {"0.0.0.0"})
        self.assertEqual(ports[5900], {"127.0.0.1"})
        self.assertIn(41233, ports)
        self.assertEqual(m.parse_listening("garbage"), {})

    def test_whitelist(self):
        t = fx("deviceidle_whitelist.txt")
        self.assertTrue(m.parse_whitelist(t, "com.tailscale.ipn"))
        self.assertTrue(m.parse_whitelist(t, "com.termux"))
        self.assertFalse(m.parse_whitelist(t, "com.termux.boot"))   # not a prefix match
        self.assertFalse(m.parse_whitelist(t, "net.christianbeier.droidvnc_ng"))

    def test_appops_and_activity(self):
        self.assertEqual(m.parse_appop(fx("appops_allow.txt"), "PROJECT_MEDIA"), "allow")
        self.assertEqual(m.parse_appop(fx("appops_default.txt"), "PROJECT_MEDIA"), "default")
        self.assertIsNone(m.parse_appop("No operations.", "PROJECT_MEDIA"))
        self.assertEqual(m.parse_resolve_activity(fx("resolve_activity.txt")), "com.tailscale.ipn/.MainActivity")
        self.assertIsNone(m.parse_resolve_activity("No activity found"))

    def test_a11y_merge_appends(self):
        svc = "net.christianbeier.droidvnc_ng/.InputService"
        self.assertEqual(m.merge_a11y("", svc), svc)
        self.assertEqual(m.merge_a11y("a.b/.C", svc), "a.b/.C:" + svc)
        self.assertEqual(m.merge_a11y("a.b/.C:" + svc, svc), "a.b/.C:" + svc)
        self.assertTrue(m.has_a11y_service("x/y:net.christianbeier.droidvnc_ng/net.christianbeier.droidvnc_ng.InputService",
                                           m.PKG_VNC))

    def test_focus(self):
        self.assertEqual(m.parse_focus(fx("focus_wifi_dialog.txt")), m.WIFI_CONFIRM_FOCUS)
        self.assertNotEqual(m.parse_focus(fx("focus_lookalike.txt")), m.WIFI_CONFIRM_FOCUS)
        self.assertNotEqual(m.parse_focus(fx("focus_launcher.txt")), m.WIFI_CONFIRM_FOCUS)
        self.assertIsNone(m.parse_focus("mCurrentFocus=null"))

    def test_ui_dump_taps(self):
        nodes = m.parse_ui_nodes(fx("ui_wifi_debug_dialog.xml"))
        self.assertEqual(nodes["android:id/alwaysUse"]["bounds"], (42, 783, 676, 839))
        self.assertFalse(nodes["android:id/alwaysUse"]["checked"])
        self.assertEqual(nodes["android:id/button1"]["text"], "Permitir")
        # checkbox first (unchecked), then "Permitir"; centers of the real bounds
        self.assertEqual(m.plan_confirm_taps(nodes), [(359, 811), (512, 898)])
        checked = m.parse_ui_nodes(fx("ui_wifi_debug_dialog_checked.xml"))
        self.assertEqual(m.plan_confirm_taps(checked), [(512, 898)])     # already checked: do not untick
        self.assertIsNone(m.plan_confirm_taps(m.parse_ui_nodes(fx("ui_other_dialog.xml"))))
        self.assertIsNone(m.plan_confirm_taps(m.parse_ui_nodes("not xml")))

    def test_vnc_toggle_label_logic(self):
        for t, want in (("COMEÇAR", True), ("Começar", True), ("START", True), ("start", True),
                        ("PARAR", False), ("STOP", False), ("", False), ("COMEÇAR AGORA", False)):
            self.assertEqual(m.is_start_label(t), want, t)
        self.assertEqual(m.plan_vnc_toggle_tap(m.parse_ui_nodes(fx("ui_vnc_stopped.xml"))), (359, 949))
        self.assertIsNone(m.plan_vnc_toggle_tap(m.parse_ui_nodes(fx("ui_vnc_running.xml"))))
        self.assertIsNone(m.plan_vnc_toggle_tap(m.parse_ui_nodes(fx("ui_vnc_scrolled_up.xml"))))
        self.assertFalse(hasattr(m, "plan_consent_tap"))      # MediaProjection consent is never auto-tapped

    def test_perm_and_shizuku_parsing(self):
        t = fx("dumpsys_package_vnc_perms.txt")
        self.assertFalse(m.parse_perm_granted(t, "android.permission.WRITE_EXTERNAL_STORAGE"))
        self.assertTrue(m.parse_perm_granted(t, "android.permission.READ_EXTERNAL_STORAGE"))
        self.assertIsNone(m.parse_perm_granted("", "android.permission.READ_EXTERNAL_STORAGE"))
        self.assertTrue(m.parse_shizuku_running(fx("ps_shizuku.txt")))
        self.assertFalse(m.parse_shizuku_running(""))
        self.assertFalse(m.parse_shizuku_running("u0_a1 5 1 grep shizuku_server"))

    def test_logcat_port_parsing(self):
        self.assertEqual(m.parse_logcat_tls_port(fx("logcat_tls_port.txt")), 43893)   # last valid one wins
        self.assertIsNone(m.parse_logcat_tls_port("Received tls port=80\nReceived tls port=70000"))
        self.assertIsNone(m.parse_logcat_tls_port(""))

    def test_mdns_parsing(self):
        self.assertEqual(m.parse_mdns_services(fx("mdns_services.txt"), "EXAMPLESERIAL"), [("192.0.2.30", 41234)])
        self.assertEqual(len(m.parse_mdns_services(fx("mdns_services.txt"), None)), 2)
        self.assertEqual(m.parse_mdns_services("", "X"), [])
        self.assertEqual(m.parse_avahi_tls(fx("avahi_tls.txt"), "EXAMPLESERIAL"), [("192.0.2.30", 41234)])
        self.assertEqual(m.parse_avahi_tls("garbage", "X"), [])

    def test_read_secret(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "k")
            self.assertIsNone(m.read_secret(p))
            for content, want in (("  " + SECRET + "\n", SECRET), ("bad key; rm -rf /\n", None), ("", None)):
                with open(p, "w") as f:
                    f.write(content)
                self.assertEqual(m.read_secret(p), want)


class FakePhone:
    """Stateful fake of `adb`: understands the commands the guardian issues."""

    def __init__(self):
        self.s = {("global", "stay_on_while_plugged_in"): "0", ("global", "adb_wifi_enabled"): "0",
                  ("secure", "always_on_vpn_app"): "null", ("secure", "always_on_vpn_lockdown"): "1",
                  ("secure", "enabled_accessibility_services"): "com.other/.Svc",
                  ("secure", "accessibility_enabled"): "0"}
        self.wifi = False
        self.ts = False
        self.idle = {"com.termux"}
        self.projection = "default"
        self.ports = {41233: "*"}
        self.tls = "37215"
        self.calls = []
        self.inputs = []
        self.sigs = {}
        self.mdns_text = ""
        self.screen = None
        self.swipes = 0
        self.keys = []
        self.need_scroll = False
        self.logcat_port = None
        self.logcat_after_toggle = None
        self.toggled_off = False
        self.avahi_text = None
        self.adb_wifi_reverts = False
        self.dialog = False          # wireless debugging confirmation in focus
        self.focus_file = "focus_wifi_dialog.txt"
        self.taps = []
        self.dump_calls = 0
        self.shizuku_installed = True
        self.shizuku_running = False
        self.perms = {"android.permission.WRITE_EXTERNAL_STORAGE": False,
                      "android.permission.READ_EXTERNAL_STORAGE": False}
        self.vnc_works = True
        self.sshd_works = True

    def writes(self):
        return [c for c in self.calls
                if c[:2] == ["settings", "put"] or c[:2] == ["svc", "wifi"] or c[:1] == ["am"]
                or c[:3] == ["dumpsys", "deviceidle", "whitelist"] and len(c) > 3 or c[:2] == ["appops", "set"]]

    def __call__(self, cmd, input_text=None, timeout=15):
        if cmd[0] == "avahi-browse":
            self.calls.append(["avahi-browse"])
            return (0, self.avahi_text) if self.avahi_text is not None else (255, "")
        if cmd[1] != "-s":
            self.calls.append(cmd[1:])
            if cmd[1] == "mdns":
                return 0, self.mdns_text
            return 0, ""
        a = cmd[4:]
        if input_text is not None:
            self.inputs.append(input_text)
            if self.vnc_works:
                self.ports[5900] = "127.0.0.1"
            return 0, ""
        self.calls.append(a)
        if a[:2] == ["settings", "get"]:
            return 0, self.s[(a[2], a[3])] + "\n"
        if a[:2] == ["settings", "put"]:
            if self.adb_wifi_reverts and a[3] == "adb_wifi_enabled":
                return 0, ""    # untrusted network: Android switches it back off
            self.s[(a[2], a[3])] = a[4]
            if a[3] == "adb_wifi_enabled":
                if a[4] == "0":
                    self.toggled_off = True
                elif self.toggled_off and self.logcat_after_toggle:
                    self.logcat_port = self.logcat_after_toggle
            return 0, ""
        if a[:3] == ["cmd", "wifi", "status"]:
            return 0, fx("cmd_wifi_status_on.txt" if self.wifi else "cmd_wifi_status_off.txt")
        if a[:2] == ["svc", "wifi"]:
            self.wifi = True
            return 0, ""
        if a[0] == "pidof":
            return (0, "4321\n") if self.ts else (1, "")
        if a[:3] == ["cmd", "package", "resolve-activity"]:
            if "com.termux" in a:
                return 0, "priority=0\ncom.termux/.app.TermuxActivity\n"
            return 0, fx("resolve_activity.txt")
        if a[:2] == ["am", "start"]:
            if a[3].endswith("droidvnc_ng/.MainActivity"):
                self.screen = "vnc_running" if 5900 in self.ports else "vnc"
            elif a[3].startswith("com.termux/"):
                if self.sshd_works:
                    self.ports[8022] = "0.0.0.0"
            else:
                self.ts = True
            return 0, ""
        if a[:2] == ["am", "startservice"]:
            if self.sshd_works:
                self.ports[8022] = "0.0.0.0"
            return 0, ""
        if a[:3] == ["dumpsys", "deviceidle", "whitelist"]:
            if len(a) == 4:
                self.idle.add(a[3][1:])
                return 0, ""
            return 0, "".join("user,%s,10%03d\n" % (p, i) for i, p in enumerate(sorted(self.idle)))
        if a[:2] == ["appops", "get"]:
            return 0, "PROJECT_MEDIA: %s\n" % self.projection
        if a[:2] == ["appops", "set"]:
            self.projection = "allow"
            return 0, ""
        if a[:2] == ["ss", "-ltn"]:
            return 0, "State Recv-Q Send-Q Local Address:Port Peer Address:Port\n" + "".join(
                "LISTEN 0 8 %s:%d 0.0.0.0:*\n" % (ad, p) for p, ad in self.ports.items())
        if a[0].startswith("logcat"):
            return 0, ("Received tls port=%d\n" % self.logcat_port) if self.logcat_port else ""
        if a[0].startswith("dumpsys window"):
            if self.screen in ("vnc", "vnc_running"):
                return 0, fx("focus_vnc_main.txt")
            if self.screen == "consent":
                return 0, fx("focus_consent.txt")
            return 0, fx(self.focus_file) if self.dialog else fx("focus_launcher.txt")
        if a[:2] == ["uiautomator", "dump"]:
            self.dump_calls += 1
            return 0, ""
        if a[0].startswith("head -c") and a[0].endswith("cerberus-ui.xml"):
            if self.screen == "vnc":
                return 0, fx("ui_vnc_scrolled_up.xml" if self.need_scroll and self.swipes < 1 else "ui_vnc_stopped.xml")
            if self.screen == "vnc_running":
                return 0, fx("ui_vnc_running.xml")
            if self.screen == "consent":
                return 0, fx("ui_consent_dialog.xml")
            return 0, fx("ui_wifi_debug_dialog.xml")
        if a[:2] == ["rm", "-f"]:
            self.removed = a[2]
            return 0, ""
        if a[:2] == ["input", "swipe"]:
            self.swipes += 1
            return 0, ""
        if a[:3] == ["input", "keyevent", "3"]:
            self.keys.append(3)
            self.screen = None
            return 0, ""
        if a[:2] == ["input", "tap"]:
            self.taps.append((int(a[2]), int(a[3])))
            xy = (int(a[2]), int(a[3]))
            if self.screen == "vnc" and xy == (359, 949):
                self.ports[5900] = "127.0.0.1"
                self.screen = "vnc_running"
                return 0, ""
            if (int(a[2]), int(a[3])) == (512, 898) and self.dialog:
                self.adb_wifi_reverts = False
                self.dialog = False
                self.s[("global", "adb_wifi_enabled")] = "1"
            return 0, ""
        if a[:2] == ["pm", "path"]:
            return (0, "package:/data/app/~~x/moe.shizuku.privileged.api-1/base.apk\n") if self.shizuku_installed else (1, "")
        if a[0].startswith("ps -A"):
            return 0, fx("ps_shizuku.txt") if self.shizuku_running else ""
        if a[0].startswith("d=$(dirname"):
            self.shizuku_running = True
            self.shizuku_starts = getattr(self, "shizuku_starts", 0) + 1
            return 0, "shizuku_server pid is 9876\n"
        if a[0].startswith("dumpsys package") and "signatures" in a[0]:
            pkg = a[0].split()[2]
            sig = self.sigs.get(pkg, "3a2b1c9")
            return (0, "    signatures=PackageSignatures{4f1 version:3, signatures:[%s], past signatures:[]}\n" % sig) if sig else (0, "")
        if a[0].startswith("dumpsys package"):
            return 0, "".join("        %s: granted=%s, flags=[ ]\n" % (p, str(g).lower()) for p, g in self.perms.items())
        if a[:2] == ["pm", "grant"]:
            self.perms[a[3]] = True
            return 0, ""
        if a[0] == "getprop":
            return 0, (self.tls if self.s[("global", "adb_wifi_enabled")] == "1" else "") + "\n"
        if a[0] == "ip":
            return 0, fx("ip_wlan0.txt") if self.wifi else ""
        return 1, ""


def make_snap(estado="device"):
    return {"estado": estado, "serial": SERIAL if estado != "ausente" else None,
            "conectado": estado == "device", "epoch": 0}


g_sleeps = []


PASSWORD = "Zx9Qp2Lm"


def make_guardian(phone, probes=None, key=SECRET, pw=PASSWORD, **cfg_over):
    cfg = m.guard_config({})
    cfg.update(pins_file=None)
    cfg.update(cfg_over)
    st = {"tcp": {}, "ping": True}

    def tcp(host, port, banner=None):
        return st["tcp"].get((host, port), False)

    pr = probes or {"tcp": tcp, "ping": lambda ip: st["ping"]}
    logs = []
    g = m.Guardian(phone, cfg, "adb", None, pr, logf=logs.append, read_key=lambda p: key,
                   sleep=lambda s: g_sleeps.append(s), read_pass=lambda p: pw)
    g.st, g.logs = st, logs
    return g


def cyc(g, now, estado="device"):
    snap = make_snap(estado)
    lines = g.cycle(snap, now)
    return snap, lines


class GuardianRepairs(unittest.TestCase):
    def test_converges_then_idempotent(self):
        ph = FakePhone()
        g = make_guardian(ph)
        _, lines = cyc(g, 0)
        ids = [l.split()[1].rstrip(":") for l in lines if l.startswith("REPAIR")]
        for want in ("stay_on", "wifi", "adb_wifi", "vpn_app", "vpn_lockdown", "tailscale_start",
                     "idle_com.tailscale.ipn", "idle_com.termux.boot", "idle_net.christianbeier.droidvnc_ng",
                     "projection", "a11y_service", "a11y_enabled", "vnc_start", "termux_start", "shizuku",
                     "grant_WRITE_EXTERNAL_STORAGE", "grant_READ_EXTERNAL_STORAGE"):
            self.assertIn(want, ids)
        self.assertNotIn("idle_com.termux", ids)   # already whitelisted: no write
        self.assertEqual(ph.s[("global", "stay_on_while_plugged_in")], "7")
        self.assertEqual(ph.s[("secure", "always_on_vpn_app")], "com.tailscale.ipn")
        self.assertEqual(ph.s[("secure", "always_on_vpn_lockdown")], "0")
        self.assertEqual(ph.s[("global", "adb_wifi_enabled")], "1")
        ph.calls.clear()
        _, lines = cyc(g, 30)
        self.assertEqual([l for l in lines if l.startswith("REPAIR")], [])
        self.assertEqual(ph.writes(), [])   # read first, write only on drift

    def test_accessibility_append_not_clobber(self):
        ph = FakePhone()
        cyc(make_guardian(ph), 0)
        self.assertEqual(ph.s[("secure", "enabled_accessibility_services")],
                         "com.other/.Svc:net.christianbeier.droidvnc_ng/.InputService")

    def test_repairs_only_drifted_value(self):
        ph = FakePhone()
        ph.s[("global", "stay_on_while_plugged_in")] = "7"
        ph.wifi = True
        g = make_guardian(ph)
        _, lines = cyc(g, 0)
        ids = [l.split()[1].rstrip(":") for l in lines if l.startswith("REPAIR")]
        self.assertNotIn("stay_on", ids)
        self.assertNotIn("wifi", ids)
        self.assertIn("adb_wifi", ids)

    def test_unreadable_is_not_repaired_blindly(self):
        acts = m.plan_repairs({"stay_on": None, "wifi": None, "ports": None, "idle": {}},
                              m.guard_config({}))
        self.assertEqual(acts, [])

    def test_secret_never_in_argv_or_logs_or_state(self):
        ph = FakePhone()
        g = make_guardian(ph)
        snap, lines = cyc(g, 0)
        cyc(g, 200)
        self.assertEqual(len(ph.inputs), 1)
        self.assertIn(SECRET, ph.inputs[0])            # delivered through stdin only
        self.assertIn("EXTRA_ACCESS_KEY", ph.inputs[0])
        self.assertIn("EXTRA_INTERFACE lo", ph.inputs[0].replace("'", ""))
        self.assertTrue(ph.inputs[0].endswith("exit\n"))
        blob = json.dumps(ph.calls) + "\n".join(g.logs) + json.dumps(snap)
        self.assertNotIn(SECRET, blob)
        self.assertIn(PASSWORD, ph.inputs[0])             # the VNC password travels the same way
        self.assertIn("EXTRA_PASSWORD", ph.inputs[0])
        self.assertNotIn(PASSWORD, blob)

    def test_vnc_without_key_stays_off_by_default(self):
        ph = FakePhone()
        g = make_guardian(ph, key=None)
        cyc(g, 0)
        cyc(g, 200)
        self.assertEqual(ph.inputs, [])
        self.assertEqual(ph.taps.count((359, 949)), 0)
        self.assertFalse([c for c in ph.calls if c[:3] == ["am", "start", "-n"] and "droidvnc" in c[3]])
        self.assertEqual(len([l for l in g.logs if "VNC desligado até rodar" in l]), 1)

    def test_exposed_vnc_without_password_is_force_stopped(self):
        ph = FakePhone()
        ph.ports = {5900: "*", 8022: "0.0.0.0"}
        g = make_guardian(ph, key=None)
        cyc(g, 0)
        self.assertIn(["am", "force-stop", m.PKG_VNC], ph.calls)
        self.assertTrue(any(l.startswith("REPAIR vnc_exposed_stop") for l in g.logs))
        ph2 = FakePhone()
        ph2.ports = {5900: "*", 8022: "0.0.0.0"}
        cyc(make_guardian(ph2), 0)                       # key + password configured: not stopped
        self.assertNotIn(["am", "force-stop", m.PKG_VNC], ph2.calls)
        ph3 = FakePhone()
        ph3.ports = {5900: "127.0.0.1", 8022: "0.0.0.0"}
        cyc(make_guardian(ph3, key=None), 0)             # loopback: never stopped
        self.assertNotIn(["am", "force-stop", m.PKG_VNC], ph3.calls)

    def test_ui_fallback_checks_the_signing_pin(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pins.json")
            with open(path, "w") as f:
                json.dump({m.PKG_VNC: "other"}, f)
            ph = FakePhone()
            g = make_guardian(ph, key=None, allow_unprotected=True, pins_file=path)
            cyc(g, 0)
            self.assertEqual(ph.taps.count((359, 949)), 0)
            self.assertTrue(any("CHANGED" in l for l in g.logs))

    def test_script_rejects_shell_injection(self):
        with self.assertRaises(ValueError):
            m.vnc_start_script("x'; reboot; '", 5900, "lo")
        with self.assertRaises(ValueError):
            m.vnc_start_script(SECRET, 5900, "lo; reboot")

    def test_start_cooldown(self):
        ph = FakePhone()
        ph.vnc_works = False
        g = make_guardian(ph)
        cyc(g, 0)
        cyc(g, 30)
        cyc(g, 100)
        self.assertEqual(len(ph.inputs), 1)       # retried only after the cooldown
        cyc(g, 121)
        self.assertEqual(len(ph.inputs), 2)

    def test_termux_opened_when_sshd_down_and_rate_limited(self):
        ph = FakePhone()
        ph.sshd_works = False
        g = make_guardian(ph)
        cyc(g, 0)
        starts = lambda: [c for c in ph.calls if c[:3] == ["am", "start", "-n"] and c[3].startswith("com.termux/")]
        self.assertEqual(starts(), [["am", "start", "-n", "com.termux/.app.TermuxActivity"]])
        self.assertTrue(any(l.startswith("REPAIR termux_start") and "still down" in l for l in g.logs))
        self.assertIn(3, ph.keys)                                  # HOME afterwards
        self.assertEqual([c for c in ph.calls if "startservice" in c], [])   # RUN_COMMAND is refused for uid shell
        cyc(g, 100)
        self.assertEqual(len(starts()), 1)
        cyc(g, 181)
        self.assertEqual(len(starts()), 2)

    def test_termux_recovers_when_opening_starts_sshd(self):
        ph = FakePhone()
        g = make_guardian(ph)
        cyc(g, 0)
        self.assertTrue(any(l.startswith("REPAIR termux_start") and "sshd up" in l for l in g.logs))

    def test_vnc_ui_start_without_key(self):
        ph = FakePhone()
        g = make_guardian(ph, key=None, allow_unprotected=True)
        cyc(g, 0)
        self.assertEqual(ph.inputs, [])
        self.assertEqual(ph.taps.count((359, 949)), 1)
        self.assertIn(3, ph.keys)
        self.assertTrue(any(l.startswith("REPAIR vnc_start") and "tapped START" in l and "port up" in l for l in g.logs))
        self.assertEqual(ph.removed, m.UI_DUMP)

    def test_vnc_ui_scrolls_at_most_twice(self):
        ph = FakePhone()
        ph.need_scroll = True
        cyc(make_guardian(ph, key=None, allow_unprotected=True), 0)
        self.assertEqual(ph.swipes, 1)
        self.assertIn((359, 949), ph.taps)
        ph2 = FakePhone()
        ph2.need_scroll = True
        orig = ph2.__call__
        ph2.swipes = -99                    # button never appears
        cyc(make_guardian(ph2, key=None, allow_unprotected=True), 0)
        self.assertEqual(ph2.swipes, -97)   # exactly 2 swipes, then gives up
        self.assertNotIn((359, 949), ph2.taps)

    def test_vnc_ui_never_taps_stop_label_or_wrong_focus(self):
        ph = FakePhone()
        g = make_guardian(ph, key=None, allow_unprotected=True)
        ph.ports = {41233: "*"}
        real = ph.__call__

        def running(cmd, input_text=None, timeout=15):
            r = real(cmd, input_text, timeout)
            if cmd[4:6] == ["am", "start"] and cmd[7].endswith("MainActivity"):
                ph.screen = "vnc_running"           # button reads PARAR although port is down
            return r
        g2 = make_guardian(running, key=None, allow_unprotected=True)
        cyc(g2, 0)
        self.assertNotIn((359, 949), ph.taps)
        self.assertTrue(any("not offering START" in l for l in g2.logs))
        ph3 = FakePhone()
        ph3.focus_file = "focus_launcher.txt"
        orig = ph3.__call__

        def wrong_focus(cmd, input_text=None, timeout=15):
            if cmd[4:6] == ["am", "start"] and cmd[7].endswith("MainActivity"):
                return 0, ""                        # activity never reaches the screen
            return orig(cmd, input_text, timeout)
        cyc(make_guardian(wrong_focus, key=None, allow_unprotected=True), 0)
        self.assertEqual(ph3.taps, [])

    def test_vnc_ui_rate_limited(self):
        ph = FakePhone()
        ph.screen = None
        ph.vnc_never = True
        g = make_guardian(ph, key=None, allow_unprotected=True)
        orig = ph.__call__

        def never_up(cmd, input_text=None, timeout=15):
            r = orig(cmd, input_text, timeout)
            ph.ports.pop(5900, None)
            return r
        g = make_guardian(never_up, key=None, allow_unprotected=True)
        cyc(g, 0)
        cyc(g, 60)
        cyc(g, 170)
        self.assertEqual(ph.taps.count((359, 949)), 1)
        cyc(g, 181)
        self.assertEqual(ph.taps.count((359, 949)), 2)

    def test_permissions_granted_once_and_idempotent(self):
        ph = FakePhone()
        g = make_guardian(ph)
        cyc(g, 0)
        grants = [c for c in ph.calls if c[:2] == ["pm", "grant"]]
        self.assertEqual(len(grants), 2)
        self.assertTrue(all(c[2] == m.PKG_VNC for c in grants))
        ph.calls.clear()
        cyc(g, 30)
        self.assertEqual([c for c in ph.calls if c[:2] == ["pm", "grant"]], [])

    def test_shizuku_started_only_when_down_and_rate_limited(self):
        ph = FakePhone()
        g = make_guardian(ph)
        snap, _ = cyc(g, 0)
        self.assertEqual(ph.shizuku_starts, 1)
        self.assertTrue(any(l.startswith("REPAIR shizuku") for l in g.logs))
        snap, _ = cyc(g, 30)
        self.assertEqual(ph.shizuku_starts, 1)
        self.assertEqual(snap["guardiao"]["shizuku"], {"ok": True})
        ph.shizuku_running = False          # died again inside the cooldown
        cyc(g, 60)
        self.assertEqual(ph.shizuku_starts, 1)
        cyc(g, 130)
        self.assertEqual(ph.shizuku_starts, 2)

    def test_shizuku_not_installed_is_ignored(self):
        ph = FakePhone()
        ph.shizuku_installed = False
        snap, _ = cyc(make_guardian(ph), 0)
        self.assertEqual(getattr(ph, "shizuku_starts", 0), 0)
        self.assertIsNone(snap["guardiao"]["shizuku"]["ok"])

    def test_repair_off_only_logs_drift(self):
        ph = FakePhone()
        g = make_guardian(ph, repair=False)
        cyc(g, 0)
        self.assertEqual(ph.writes(), [])
        self.assertEqual(ph.inputs, [])
        self.assertTrue(any("repair off" in l for l in g.logs))

    def test_tailscale_unresolvable_launcher(self):
        acts = m.plan_repairs({"ts_alive": False, "ts_activity": None}, m.guard_config({}))
        self.assertEqual([a["id"] for a in acts], ["tailscale_unresolved"])


class GuardianStuck(unittest.TestCase):
    def test_reverting_wireless_debugging_is_reported_once(self):
        ph = FakePhone()
        ph.adb_wifi_reverts = True
        g = make_guardian(ph)
        g_sleeps.clear()
        cyc(g, 0)
        cyc(g, 30)
        warns = [l for l in g.logs if "rede não confiável para depuração sem fio" in l]
        self.assertEqual(len(warns), 1)
        self.assertIn(3.0, g_sleeps)       # waited before re-reading

    def test_sticking_is_silent(self):
        ph = FakePhone()
        g = make_guardian(ph)
        cyc(g, 0)
        self.assertFalse([l for l in g.logs if "rede não confiável" in l])

    def test_port_not_exposed_publishes_enabled_state_only(self):
        ph = FakePhone()
        ph.tls = ""         # this One UI build: service.adb.tls.port empty
        g = make_guardian(ph)
        cyc(g, 0)
        snap, _ = cyc(g, 30)
        aw = snap["caminhos"]["adb_sem_fio"]
        self.assertEqual((aw["porta"], aw["ativa"], aw["ok"]), (None, True, None))


class VncSecretsAndPins(unittest.TestCase):
    def test_key_without_password_refuses_and_never_uses_ui_fallback(self):
        ph = FakePhone()
        g = make_guardian(ph, pw=None)
        cyc(g, 0)
        self.assertEqual(ph.inputs, [])
        self.assertEqual(ph.taps.count((359, 949)), 0)
        self.assertFalse([c for c in ph.calls if c[:3] == ["am", "start", "-n"] and "droidvnc" in c[3]])
        self.assertTrue(any("without a VNC password" in l for l in g.logs))

    def test_no_key_uses_ui_and_warns_unprotected(self):
        ph = FakePhone()
        g = make_guardian(ph, key=None, allow_unprotected=True)
        cyc(g, 0)
        self.assertEqual(ph.taps.count((359, 949)), 1)
        self.assertTrue(any("UNPROTECTED" in l for l in g.logs))

    def test_script_has_password_and_validates(self):
        sc = m.vnc_start_script(SECRET, 5900, "lo", PASSWORD)
        self.assertIn("EXTRA_PASSWORD '%s'" % PASSWORD, sc)
        self.assertNotIn("EXTRA_PASSWORD", m.vnc_start_script(SECRET, 5900, "lo"))
        for bad in ("short", "toolongpass", "bad'pass;", "Zx9 Qp2L"):
            with self.assertRaises(ValueError):
                m.vnc_start_script(SECRET, 5900, "lo", bad)

    def test_read_password(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "pw")
            for content, want in ((PASSWORD + "\n", PASSWORD), ("short", None), ("has space1", None), ("", None)):
                with open(p, "w") as f:
                    f.write(content)
                self.assertEqual(m.read_password(p), want)
            self.assertIsNone(m.read_password(os.path.join(d, "missing")))

    def test_signature_parse_and_tofu_pins(self):
        t = "signatures=PackageSignatures{4f1 version:3, signatures:[B7C3, a1f0], past signatures:[]}"
        self.assertEqual(m.parse_pkg_signature(t), "a1f0,b7c3")
        self.assertIsNone(m.parse_pkg_signature("nothing"))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "pins.json")
            pins = m.Pins(path)
            self.assertEqual(pins.check("p", "aa"), "new")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(m.Pins(path).check("p", "aa"), "ok")          # persisted
            self.assertEqual(m.Pins(path).check("p", "bb"), "mismatch")
            self.assertEqual(pins.check("p", None), "unknown")

    def test_changed_certificate_blocks_secrets_and_shizuku(self):
        with tempfile.TemporaryDirectory() as d:
            ph = FakePhone()
            g = make_guardian(ph, pins_file=os.path.join(d, "pins.json"))
            cyc(g, 0)                                    # first use: pinned, started
            self.assertEqual(len(ph.inputs), 1)
            self.assertEqual(ph.shizuku_starts, 1)
            self.assertTrue(any("pinned signing digest of %s" % m.PKG_VNC in l for l in g.logs))
            ph2 = FakePhone()
            ph2.sigs = {m.PKG_VNC: "deadbeef", m.PKG_SHIZUKU: "deadbeef"}
            g2 = make_guardian(ph2, pins_file=os.path.join(d, "pins.json"))
            cyc(g2, 0)
            self.assertEqual(ph2.inputs, [])
            self.assertEqual(getattr(ph2, "shizuku_starts", 0), 0)
            self.assertEqual(len([l for l in g2.logs if "CHANGED" in l]), 2)

    def test_unreadable_signature_refuses(self):
        ph = FakePhone()
        ph.sigs = {m.PKG_VNC: ""}
        g = make_guardian(ph)
        cyc(g, 0)
        self.assertEqual(ph.inputs, [])
        self.assertTrue(any("cannot read the signing digest" in l for l in g.logs))


class UiParsingHardening(unittest.TestCase):
    def test_package_filter_and_duplicate_ids(self):
        spoof = ('<hierarchy><node resource-id="android:id/button1" text="Permitir" package="evil.app" '
                 'checked="false" bounds="[0,0][10,10]"/>'
                 '<node resource-id="android:id/button1" text="Permitir" package="com.android.systemui" '
                 'checked="false" bounds="[100,100][200,200]"/></hierarchy>')
        n = m.parse_ui_nodes(spoof, "com.android.systemui")
        self.assertEqual(n["android:id/button1"]["bounds"], (100, 100, 200, 200))
        dup = spoof.replace("evil.app", "com.android.systemui")
        self.assertNotIn("android:id/button1", m.parse_ui_nodes(dup, "com.android.systemui"))   # ambiguous
        self.assertNotIn("android:id/button1", m.parse_ui_nodes(spoof.replace("com.android.systemui", "x"), "com.android.systemui"))

    def test_refuses_dtd_and_huge_xml(self):
        self.assertEqual(m.parse_ui_nodes('<!DOCTYPE x [<!ENTITY a "b">]><hierarchy/>'), {})
        self.assertEqual(m.parse_ui_nodes("<hierarchy>" + " " * (m.MAX_XML + 1) + "</hierarchy>"), {})

    def test_dump_goes_to_shell_owned_path(self):
        self.assertEqual(m.UI_DUMP, "/data/local/tmp/cerberus-ui.xml")


class ServerSocket(unittest.TestCase):
    def test_collect_and_recovery_use_the_unix_socket(self):
        seen = []

        def run(cmd, **k):
            seen.append(cmd)
            return fake_run("devices_none.txt")(cmd)
        m.collect(run, "adb", server_args=["-L", "localfilesystem:/run/x/adb.sock"])
        self.assertEqual(seen[0], ["adb", "-L", "localfilesystem:/run/x/adb.sock", "start-server"])
        ph = FakePhone()
        g = m.Guardian(ph, m.guard_config({}), "adb", None, {"tcp": lambda *a, **k: False, "ping": lambda ip: False},
                       logf=lambda x: None, sleep=lambda s: None, server_args=["-L", "localfilesystem:/s"])
        g.recover_adb("ausente", 0)
        g.recover_adb("ausente", 30)
        starts = [c for c in ph.calls if c[-1:] == ["start-server"]]
        self.assertEqual(starts, [["-L", "localfilesystem:/s", "start-server"]])

    def test_no_tcp_5037_anywhere(self):
        with open(os.path.join(HERE, "..", "cerberus-s10")) as f:
            src = f.read()
        self.assertNotIn("tcp:localhost:5037", src)
        self.assertNotIn("adb -a", src)


class SsidGate(unittest.TestCase):
    def test_parse_ssid(self):
        self.assertEqual(m.parse_wifi_ssid(fx("cmd_wifi_status_on.txt")), "homenet")
        self.assertIsNone(m.parse_wifi_ssid(fx("cmd_wifi_status_off.txt")))
        self.assertIsNone(m.parse_wifi_ssid('SSID: "<unknown ssid>", BSSID'))

    def test_dialog_not_accepted_on_foreign_network(self):
        ph = FakePhone()
        ph.adb_wifi_reverts = True
        ph.dialog = True
        g = make_guardian(ph, home_ssid="outra-rede")
        cyc(g, 0)
        self.assertEqual(ph.taps, [])
        self.assertTrue(any("not the home network" in l for l in g.logs))

    def test_dialog_message_must_name_the_home_network(self):
        nodes = {"android:id/message": {"text": "A rede foo, BSSID x"}}
        # exercised through confirm: foreign text blocks the tap
        ph = FakePhone()
        ph.adb_wifi_reverts = True
        ph.dialog = True
        orig = ph.__call__

        def with_message(cmd, input_text=None, timeout=15):
            r = orig(cmd, input_text, timeout)
            if len(cmd) > 4 and cmd[4].startswith("head -c"):
                x = r[1].replace("</hierarchy>", '<node resource-id="android:id/message" text="rede foo" '
                                 'package="com.android.systemui" checked="false" bounds="[0,0][5,5]"/></hierarchy>')
                return r[0], x
            return r
        g = make_guardian(with_message)
        cyc(g, 0)
        self.assertEqual(ph.taps, [])
        self.assertTrue(any("does not name the home network" in l for l in g.logs))

    def _dialog_phone(self, message=None, status_fix=None):
        ph = FakePhone()
        ph.adb_wifi_reverts = True
        ph.dialog = True
        orig = ph.__call__

        def wrapped(cmd, input_text=None, timeout=15):
            r = orig(cmd, input_text, timeout)
            if message is not None and len(cmd) > 4 and cmd[4].startswith("head -c"):
                node = ('<node resource-id="android:id/message" text="%s" package="com.android.systemui" '
                        'checked="false" bounds="[0,0][5,5]"/>' % message)
                return r[0], r[1].replace("</hierarchy>", node + "</hierarchy>")
            if status_fix and cmd[4:7] == ["cmd", "wifi", "status"]:
                return r[0], status_fix(r[1])
            return r
        return ph, wrapped

    def test_bssid_must_match(self):
        ph, run = self._dialog_phone(status_fix=lambda t: t.replace("02:00:00:00:00:ab", "aa:bb:cc:dd:ee:ff"))
        g = make_guardian(run)
        cyc(g, 0)
        self.assertEqual(ph.taps, [])
        self.assertTrue(any("not the home network" in l for l in g.logs))
        ph2, run2 = self._dialog_phone(status_fix=lambda t: t.replace("02:00:00:00:00:ab", "02:00:00:00:00:ab"))
        cyc(make_guardian(run2), 0)
        self.assertTrue(ph2.taps)                      # case-insensitive match of the real BSSID

    def test_message_must_have_exact_ssid_line(self):
        ph, run = self._dialog_phone(message="Rede homenet-guest")
        cyc(make_guardian(run), 0)
        self.assertEqual(ph.taps, [])
        ph, run = self._dialog_phone(message="Nome da rede&#10;homenet&#10;Endereço (BSSID)")
        cyc(make_guardian(run), 0)
        self.assertTrue(ph.taps)

    def test_ssid_is_not_a_substring_match(self):
        ph, run = self._dialog_phone(status_fix=lambda t: t.replace('"homenet"', '"homenetx"'))
        cyc(make_guardian(run), 0)
        self.assertEqual(ph.taps, [])

    def test_focus_rechecked_right_before_tapping(self):
        ph = FakePhone()
        ph.adb_wifi_reverts = True
        ph.dialog = True
        orig = ph.__call__
        calls = {"n": 0}

        def moving(cmd, input_text=None, timeout=15):
            if len(cmd) > 4 and cmd[4].startswith("dumpsys window"):
                calls["n"] += 1
                if calls["n"] >= 2:
                    ph.dialog = False        # a different window took focus meanwhile
            return orig(cmd, input_text, timeout)
        g = make_guardian(moving)
        cyc(g, 0)
        self.assertEqual(ph.taps, [])
        self.assertTrue(any("focus left" in l for l in g.logs))

    def test_estado_json_is_group_readable_only(self):
        with open(os.path.join(HERE, "..", "cerberus-s10")) as f:
            self.assertIn("write_atomic(path, snap, 0o640)", f.read())


class WifiConfirmDialog(unittest.TestCase):
    def setUp(self):
        self.ph = FakePhone()
        self.ph.adb_wifi_reverts = True
        self.ph.dialog = True
        self.g = make_guardian(self.ph)

    def test_taps_checkbox_then_allow_and_recovers(self):
        cyc(self.g, 0)
        self.assertEqual(self.ph.taps, [(359, 811), (512, 898)])
        self.assertEqual(self.ph.s[("global", "adb_wifi_enabled")], "1")
        self.assertTrue(any(l.startswith("REPAIR adb_wifi_confirm") for l in self.g.logs))
        self.assertFalse([l for l in self.g.logs if "rede não confiável" in l])
        self.assertEqual(self.ph.removed, m.UI_DUMP)      # dump deleted after parsing

    def test_never_taps_without_exact_focus(self):
        self.ph.focus_file = "focus_lookalike.txt"
        cyc(self.g, 0)
        self.assertEqual(self.ph.taps, [])
        self.assertEqual(self.ph.dump_calls, 0)
        self.assertTrue(any("rede não confiável" in l for l in self.g.logs))

    def test_never_taps_when_dialog_not_focused(self):
        self.ph.dialog = False
        cyc(self.g, 0)
        self.assertEqual(self.ph.taps, [])

    def test_rate_limited_to_once_per_two_minutes(self):
        self.ph.taps_ignored = True
        # make the tap ineffective so the dialog stays
        orig = self.ph.__call__

        def no_effect(cmd, input_text=None, timeout=15):
            if len(cmd) > 5 and cmd[4:6] == ["input", "tap"]:
                self.ph.taps.append((int(cmd[6]), int(cmd[7])))
                return 0, ""
            return orig(cmd, input_text, timeout)
        g = make_guardian(no_effect)
        cyc(g, 0)
        n1 = len(self.ph.taps)
        cyc(g, 30)
        cyc(g, 90)
        self.assertEqual(len(self.ph.taps), n1)
        cyc(g, 125)
        self.assertEqual(len(self.ph.taps), 2 * n1)

    def test_no_dialog_actions_when_setting_sticks(self):
        ph = FakePhone()
        cyc(make_guardian(ph), 0)
        self.assertEqual(ph.taps, [])
        self.assertEqual(ph.dump_calls, 0)


class GuardianLogcatPort(unittest.TestCase):
    def test_logcat_is_primary_over_mdns_and_probed_on_tailnet(self):
        ph = FakePhone()
        ph.tls = ""
        ph.logcat_port = 43893
        ph.mdns_text = fx("mdns_services.txt")          # would say 41234: must lose
        g = make_guardian(ph)
        g.st["tcp"] = {(TS_IP, 43893): True}
        cyc(g, 0)
        snap, _ = cyc(g, 30)
        aw = snap["caminhos"]["adb_sem_fio"]
        self.assertEqual(aw["porta"], 43893)
        self.assertTrue(aw["ok_tailnet"] and aw["ok"])
        self.assertNotIn(["mdns", "services"], ph.calls)

    def test_rotated_log_regenerates_port_once_per_ten_minutes(self):
        ph = FakePhone()
        ph.tls = ""
        ph.logcat_after_toggle = 43893
        g = make_guardian(ph)
        g_sleeps.clear()
        cyc(g, 0)
        self.assertEqual(g.last_port, 43893)
        self.assertEqual([l for l in g.logs if l.startswith("REPAIR adb_wifi_port")][0].count("43893"), 1)
        self.assertEqual(g_sleeps[-2:], [2, 3])
        # toggled 0 then 1, in that order
        puts = [c[4] for c in ph.calls if c[:4] == ["settings", "put", "global", "adb_wifi_enabled"]]
        self.assertEqual(puts, ["1", "0", "1"])

    def test_regeneration_rate_limited_and_respects_repair_off(self):
        ph = FakePhone()
        ph.tls = ""
        g = make_guardian(ph)               # logcat never shows a port
        cyc(g, 0)
        n = len([c for c in ph.calls if c[:4] == ["settings", "put", "global", "adb_wifi_enabled"]])
        cyc(g, 30)
        cyc(g, 500)
        self.assertEqual(len([c for c in ph.calls if c[:4] == ["settings", "put", "global", "adb_wifi_enabled"]]), n)
        cyc(g, 601)
        self.assertGreater(len([c for c in ph.calls if c[:4] == ["settings", "put", "global", "adb_wifi_enabled"]]), n)
        ph2 = FakePhone()
        ph2.tls = ""
        ph2.s[("global", "adb_wifi_enabled")] = "1"
        cyc(make_guardian(ph2, repair=False), 0)
        self.assertEqual([c for c in ph2.calls if c[:4] == ["settings", "put", "global", "adb_wifi_enabled"]], [])

    def test_no_regeneration_when_wireless_debugging_stays_off(self):
        ph = FakePhone()
        ph.adb_wifi_reverts = True
        cyc(make_guardian(ph), 0)
        self.assertEqual([c for c in ph.calls if c[:4] == ["settings", "put", "global", "adb_wifi_enabled"]], [["settings", "put", "global", "adb_wifi_enabled", "1"]])


class GuardianTailnetPort(unittest.TestCase):
    def test_port_from_mdns_and_tailnet_probe(self):
        ph = FakePhone()
        ph.tls = ""
        ph.mdns_text = fx("mdns_services.txt")
        g = make_guardian(ph)
        g.st["tcp"] = {(TS_IP, 41234): True}      # reachable over the tailnet only
        cyc(g, 0)
        snap, _ = cyc(g, 30)
        aw = snap["caminhos"]["adb_sem_fio"]
        self.assertEqual((aw["ip_lan"], aw["porta"], aw["ip_tailnet"]), ("192.0.2.20", 41234, TS_IP))
        self.assertTrue(aw["ok"])
        self.assertTrue(aw["ok_tailnet"])

    def test_mdns_ip_used_when_phone_ip_unknown_and_avahi_fallback(self):
        ph = FakePhone()
        ph.tls = ""
        ph.avahi_text = fx("avahi_tls.txt")       # adb mdns returns nothing: falls back to avahi
        g = make_guardian(ph, repair=False)
        ph.s[("global", "adb_wifi_enabled")] = "1"
        snap, _ = cyc(g, 0)
        self.assertEqual(snap["caminhos"]["adb_sem_fio"]["porta"], 41234)
        self.assertIn(["avahi-browse"], ph.calls)

    def test_discovery_works_without_usb_and_skips_when_disabled(self):
        ph = FakePhone()
        ph.mdns_text = fx("mdns_services.txt")
        g = make_guardian(ph)
        snap, _ = cyc(g, 0, "ausente")
        self.assertEqual(snap["caminhos"]["adb_sem_fio"]["porta"], 41234)
        ph2 = FakePhone()
        ph2.mdns_text = fx("mdns_services.txt")
        g2 = make_guardian(ph2, repair=False)
        ph2.s[("global", "adb_wifi_enabled")] = "0"
        ph2.tls = ""
        snap, _ = cyc(g2, 0)
        self.assertIsNone(snap["caminhos"]["adb_sem_fio"]["porta"])
        self.assertNotIn(["mdns", "services"], ph2.calls)


class GuardianPaths(unittest.TestCase):
    def test_publishes_ip_port_and_health(self):
        ph = FakePhone()
        g = make_guardian(ph)
        cyc(g, 0)                       # enables wifi + wireless debugging
        g.st["tcp"] = {("192.0.2.20", 37215): True, (TS_IP, 8022): True}
        snap, _ = cyc(g, 30)
        c = snap["caminhos"]
        self.assertEqual(c["usb"], {"ok": True, "estado": "device"})
        self.assertEqual(c["adb_sem_fio"], {"ip_lan": "192.0.2.20", "porta": 37215, "ip_tailnet": TS_IP,
                                           "ok": True, "ok_tailnet": False, "ativa": True})
        self.assertEqual(c["tailscale"]["ok"], True)
        self.assertEqual(c["ssh_termux"]["ok"], True)
        self.assertEqual(c["vnc"], {"ok": True, "porta": 5900, "loopback": True})
        json.dumps(snap)

    def test_port_cleared_when_wireless_debugging_off(self):
        ph = FakePhone()
        g = make_guardian(ph, repair=False)
        ph.wifi = True
        ph.s[("global", "adb_wifi_enabled")] = "1"
        cyc(g, 0)
        self.assertEqual(g.last_port, 37215)
        ph.s[("global", "adb_wifi_enabled")] = "0"
        snap, _ = cyc(g, 30)
        self.assertIsNone(snap["caminhos"]["adb_sem_fio"]["porta"])
        self.assertFalse(snap["caminhos"]["adb_sem_fio"]["ok"])

    def test_probes_run_even_without_usb_and_keep_last_ip(self):
        ph = FakePhone()
        g = make_guardian(ph)
        cyc(g, 0)
        cyc(g, 30)
        ph.calls.clear()
        g.st["tcp"] = {("192.0.2.20", 37215): True, (TS_IP, 8022): True}
        snap, _ = cyc(g, 60, "ausente")
        self.assertEqual([c for c in ph.calls if c[0] in ("settings", "ss")], [])   # no shell
        c = snap["caminhos"]
        self.assertFalse(c["usb"]["ok"])
        self.assertTrue(c["adb_sem_fio"]["ok"])
        self.assertTrue(c["ssh_termux"]["ok"])
        self.assertIsNone(c["vnc"]["ok"])      # unknown without USB

    def test_ts_probe_off(self):
        ph = FakePhone()
        snap, _ = cyc(make_guardian(ph, ts_probe="off"), 0)
        self.assertIsNone(snap["caminhos"]["tailscale"]["ok"])

    def test_vnc_exposed_warning(self):
        ph = FakePhone()
        ph.ports = {5900: "*", 8022: "0.0.0.0"}
        g = make_guardian(ph, repair=False)
        snap, _ = cyc(g, 0)
        self.assertFalse(snap["caminhos"]["vnc"]["loopback"])
        self.assertTrue(any("non-loopback" in l for l in g.logs))

    def test_seed_from_previous_state(self):
        g = make_guardian(FakePhone())
        g.seed({"caminhos": {"adb_sem_fio": {"ip": "10.0.0.2", "porta": 4444}}})
        self.assertEqual((g.last_ip, g.last_port), ("10.0.0.2", 4444))
        g.seed(None)
        g.seed({})


class TransitionsAndRecovery(unittest.TestCase):
    def test_logs_only_on_change(self):
        t = m.Transitions()
        self.assertEqual(t.update("vnc", True), "path vnc: up")
        self.assertIsNone(t.update("vnc", True))
        self.assertEqual(t.update("vnc", False), "path vnc: down")
        self.assertIsNone(t.update("vnc", False))
        self.assertIsNone(t.update("vnc", None))
        self.assertIsNone(t.update("vnc", False))      # unknown does not reset
        self.assertEqual(t.update("vnc", True), "path vnc: up")

    def test_cycle_logs_transitions_once(self):
        ph = FakePhone()
        g = make_guardian(ph)
        _, l1 = cyc(g, 0)
        cyc(g, 30)      # vnc/ssh come up after the first repairs
        _, l2 = cyc(g, 45)
        self.assertTrue(any(l.startswith("path usb: up") for l in l1))
        self.assertEqual([l for l in l2 if l.startswith("path ")], [])
        g.st["ping"] = False
        _, l3 = cyc(g, 60)
        self.assertIn("path tailscale: down", l3)
        _, l4 = cyc(g, 90)
        self.assertNotIn("path tailscale: down", l4)

    def test_backoff_sequence(self):
        r = m.AdbRecovery(base=30, cap=300, restart_every=300)
        seen = []
        for now in range(0, 1300, 10):
            for a in r.step("ausente", now):
                seen.append((now, a))
        times = [t for t, _ in seen]
        self.assertEqual(times[:6], [0, 30, 90, 210, 450, 750])   # 30,60,120,240,300 gaps
        self.assertEqual(seen[0][1], "reconnect")
        self.assertEqual(seen[1][1], "restart-server")
        restarts = [t for t, a in seen if a == "restart-server"]
        self.assertTrue(all(b - a >= 300 for a, b in zip(restarts, restarts[1:])))

    def test_backoff_resets_on_device_and_offline_variant(self):
        r = m.AdbRecovery()
        self.assertEqual(r.step("offline", 0), ["reconnect-offline"])
        self.assertEqual(r.step("offline", 5), [])
        self.assertEqual(r.step("device", 6), [])
        self.assertEqual(r.step("unauthorized", 7), ["reconnect"])

    def test_cycle_issues_adb_recovery_commands(self):
        ph = FakePhone()
        g = make_guardian(ph)
        cyc(g, 0, "ausente")
        cyc(g, 30, "ausente")
        top = [c for c in ph.calls if c[0] in ("reconnect", "kill-server", "start-server")]
        self.assertEqual(top, [["reconnect"], ["kill-server"], ["start-server"]])


class ProbesIO(unittest.TestCase):
    class Sock:
        def __init__(self, data):
            self.data = data

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def settimeout(self, t):
            pass

        def recv(self, n):
            return self.data[:n]

    def test_tcp_probe(self):
        ok = lambda addr, t: self.Sock(b"SSH-2.0-OpenSSH")
        self.assertTrue(m.tcp_probe("h", 1, connect=ok))
        self.assertTrue(m.tcp_probe("h", 1, banner=b"SSH-", connect=ok))
        self.assertFalse(m.tcp_probe("h", 1, banner=b"HTTP", connect=ok))

        def boom(addr, t):
            raise OSError("refused")
        self.assertFalse(m.tcp_probe("h", 1, connect=boom))

    def test_ping_probe(self):
        seen = []
        self.assertTrue(m.ping_probe("1.2.3.4", lambda c, timeout=0: (seen.append(c), (0, ""))[1]))
        self.assertEqual(seen[0], ["ping", "-c1", "-W2", "1.2.3.4"])
        self.assertFalse(m.ping_probe("1.2.3.4", lambda c, timeout=0: (1, "")))

    def test_config_defaults_and_credentials(self):
        c = m.guard_config({})
        self.assertEqual((c["tailnet_ip"], c["ssh_port"], c["vnc_port"], c["vnc_iface"]),
                         ("100.64.0.10", 8022, 5900, "lo"))
        self.assertEqual(c["key_file"], "/etc/cerberus-s10/vnc-access-key")
        c = m.guard_config({"CREDENTIALS_DIRECTORY": "/run/credentials/x", "S10_REPAIR": "0"})
        self.assertEqual(c["key_file"], "/run/credentials/x/vnc-access-key")
        self.assertFalse(c["repair"])

    def test_default_run_passes_stdin(self):
        rc, out = m.default_run(["cat"], input_text="olá")
        self.assertEqual((rc, out), (0, "olá"))
        self.assertEqual(m.default_run(["/nonexistent-bin"])[0], 255)


class FocusAfterRebootTest(unittest.TestCase):
    """Live (16/11/2026): after a reboot mCurrentFocus was null while the Wi-Fi debugging dialog was the resumed activity."""

    def test_resumed_activity_fallback_matches_wifi_dialog(self):
        live = ("  mCurrentFocus=null\n"
                "    mResumedActivity: ActivityRecord{7d846c3 u0 com.android.systemui/.wifi.WifiDebuggingActivity t3928}\n")
        self.assertEqual(m.parse_focus(live), m.WIFI_CONFIRM_FOCUS)

    def test_window_focus_wins_over_resumed_activity(self):
        text = ("  mCurrentFocus=Window{f479f0c u0 com.termux/com.termux.app.TermuxActivity}\n"
                "    mResumedActivity: ActivityRecord{7d846c3 u0 com.android.systemui/.wifi.WifiDebuggingActivity t3928}\n")
        self.assertEqual(m.parse_focus(text), "com.termux/com.termux.app.TermuxActivity")

    def test_nothing_known(self):
        self.assertIsNone(m.parse_focus("  mCurrentFocus=null\n"))


class DialogSsidQuotedTest(unittest.TestCase):
    """Live (16/11/2026): the dialog shows the SSID in quotes ("homenet"); exact match must still hold."""

    def _lines_ok(self, text, ssid):
        return ssid in [ln.strip().strip('"') for ln in text.splitlines()]

    def test_quoted_and_exact(self):
        self.assertTrue(self._lines_ok('Nome da rede (SSID)\n"homenet"\n', "homenet"))
        self.assertFalse(self._lines_ok('Nome da rede (SSID)\n"homenetx"\n', "homenet"))

    def test_source_uses_quote_strip(self):
        src = open(os.path.join(HERE, "..", "cerberus-s10")).read()
        self.assertIn("ln.strip().strip('\"')", src)


if __name__ == "__main__":
    unittest.main()
