#!/usr/bin/env python3
"""Load harness for backstage (multi-agent plan, phase 4). Start it through tests/load.sh,
which builds the helpers, runs the non-interference watchdog and cleans up. See
docs/LOAD_TESTING.md.

  load.py run --bin B --work W --app A --pixels P --probe Q <sessions> [workloads] [options]
  load.py worker <config.json>                 one session's client (spawned by `run`)
  load.py finalize <results-dir> <watch.out> <watch-exit-status>

Every session is a separate client process with its own BACKSTAGE_SESSION. Standard library
only, and Python 3.9 syntax, so the stock /usr/bin/python3 on a fresh account runs it.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import time

WORKLOADS = ["idle", "input", "capture", "mixed", "launch", "cycles"]
GATES = ["wrong_target_input", "foreign_pixels", "cross_session_termination"]
FIXTURE_EXE = "BackstageTestApp.app/Contents/MacOS/BackstageTestApp"


# ---------------------------------------------------------------- shared helpers

def bs(binary, session, args, timeout=120):
    """Run one backstage command as `session`. Returns (milliseconds, exit code, JSON or None, text)."""
    env = dict(os.environ)
    env["BACKSTAGE_SESSION"] = session
    started = time.monotonic()
    try:
        proc = subprocess.run([binary] + args, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout)
        code, out = proc.returncode, proc.stdout.decode("utf-8", "replace")
    except subprocess.TimeoutExpired:
        code, out = -1, "timed out after %ss" % timeout
    ms = (time.monotonic() - started) * 1000
    try:
        data = json.loads(out)
    except ValueError:
        data = None
    return ms, code, data, out


def ok(code, data):
    return code == 0 and isinstance(data, dict) and data.get("ok", True) is not False


def rejected(code, data):
    return code == 1 and isinstance(data, dict) and data.get("ok") is False


def ident(pid):
    """A process's start time (tells a live app from a reused PID), or None if it's gone."""
    try:
        out = subprocess.run(["ps", "-o", "stat=,lstart=", "-p", str(pid)], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL).stdout.decode().strip()
    except OSError:
        return None
    if not out or out.startswith("Z"):
        return None
    return out.split(None, 1)[1] if " " in out else out


def write_json(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f, indent=1, sort_keys=True)
    os.rename(tmp, path)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def wait_for_file(path, deadline):
    while not os.path.exists(path):
        if time.time() > deadline or os.getppid() == 1:
            return False
        time.sleep(0.01)
    return True


def sleep_until(t):
    left = t - time.time()
    if left > 0:
        time.sleep(left)


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    k = int(math.ceil(p / 100.0 * len(sorted_values))) - 1
    return sorted_values[max(0, min(len(sorted_values) - 1, k))]


def stats(values, digits=1):
    s = sorted(values)
    if not s:
        return {"n": 0}
    return {"n": len(s), "p50": round(percentile(s, 50), digits), "p95": round(percentile(s, 95), digits),
            "max": round(s[-1], digits), "mean": round(sum(s) / len(s), digits)}


# ---------------------------------------------------------------- worker (one session)

class Worker:
    def __init__(self, cfg):
        self.cfg = cfg
        self.session = cfg["session"]
        self.events = []          # [op, seconds since start, ms, ok]
        self.errors = []
        self.checks = []          # {"gate", "name", "ok", "detail"}
        self.counts = {}
        self.start = None
        self.end = None
        self.pid = None

    def run_bs(self, op, args, timeout=120, record=True):
        ms, code, data, out = bs(self.cfg["bin"], self.session, args, timeout)
        good = ok(code, data)
        if record:
            t = time.time() - self.start if self.start else -1
            self.events.append([op, round(t, 3), round(ms, 2), good])
            if not good:
                self.errors.append({"op": op, "t": round(t, 3), "error": out.strip()[:300]})
            if code == -1:
                self.count("hung:" + op)  # no reply within the timeout; the client was killed
        return ms, code, data, good

    def check(self, gate, name, passed, detail=""):
        self.checks.append({"gate": gate, "name": name, "ok": bool(passed), "detail": detail})

    def count(self, key, n=1):
        self.counts[key] = self.counts.get(key, 0) + n

    def launch(self):
        cfg = self.cfg
        args = ["launch", cfg["app"], "--timeout", "60"]
        for k, v in sorted(cfg["env"].items()):
            args += ["--env", "%s=%s" % (k, v)]
        ms, code, data, good = self.run_bs("launch", args, timeout=180)
        if not good or "pid" not in data:
            self.check("other", "launch", False, "launch failed")
            return False
        self.pid = data["pid"]
        self.launch_ms = ms
        if not data.get("windows"):
            self.check("other", "launch shows a window", False, "no window in launch result")
        return True

    def ready(self, extra=None):
        info = {"session": self.session, "pid": self.pid, "ident": ident(self.pid), "launchMs": round(self.launch_ms, 1)}
        info.update(extra or {})
        write_json(self.cfg["ready"], info)

    def wait_go(self):
        if not wait_for_file(self.cfg["go"], time.time() + 900):
            raise SystemExit("worker %s: no go signal" % self.session)
        time.sleep(0.02)
        return read_json(self.cfg["go"])

    # -- element helpers (unrecorded setup reads)
    def find_ref(self, role, text=None):
        args = ["find", "--role", role] + (["--text", text] if text else [])
        for _ in range(50):
            _, code, data, _ = bs(self.cfg["bin"], self.session, args, 30)
            if ok(code, data) and data.get("elements"):
                return data["elements"][0]
            time.sleep(0.1)
        return None

    def field_value(self, op=None):
        args = ["find", "--role", "textfield"]
        if op:
            _, _, data, good = self.run_bs(op, args, 30)
        else:
            _, code, data, _ = bs(self.cfg["bin"], self.session, args, 30)
            good = ok(code, data)
        if good and data.get("elements"):
            return data["elements"][0].get("value", "")
        return None

    def foreign_marker(self, text):
        for m in self.cfg["markers"]:
            if m != self.cfg["marker"] and m in (text or ""):
                return m
        return None

    def type_and_verify(self, text, field, record_ops):
        """Clears the field, types `text`, and checks this session's own field holds exactly that."""
        if record_ops:
            self.run_bs("set", ["set", field, ""], 30)
            _, _, _, typed = self.run_bs("type", ["type", text, "--ref", field], 60)
        else:
            bs(self.cfg["bin"], self.session, ["set", field, ""], 30)
            typed = ok(*bs(self.cfg["bin"], self.session, ["type", text, "--ref", field], 60)[1:3])
        value = self.field_value("read" if record_ops else None)
        deadline = time.time() + 3
        while value != text and time.time() < deadline:
            time.sleep(0.1)
            value = self.field_value()
        self.count("typed")
        if value != text:
            foreign = self.foreign_marker(value)
            gate = "wrong_target_input" if foreign or typed else "other"
            self.check(gate, "typed text arrived intact", False,
                       "typed %r, field holds %r%s" % (text, value, " (foreign marker %s)" % foreign if foreign else ""))
            self.count("typed_mismatch")
            return False
        return True

    # -- cross-session probes, run once mid-load
    def cross_session(self, go):
        neighbor = go.get("neighbor", {}).get(self.session)
        if not neighbor:
            return
        pid = str(neighbor["pid"])
        _, code, data, _ = bs(self.cfg["bin"], self.session, ["type", "x", "--pid", pid], 30)
        self.check("wrong_target_input", "type --pid <other session's app> rejected", rejected(code, data),
                   "" if rejected(code, data) else "exit %s" % code)
        shot = os.path.join(self.cfg["dir"], "cross-%s.png" % self.session)
        _, code, data, _ = bs(self.cfg["bin"], self.session, ["screenshot", "--pid", pid, "-o", shot], 30)
        self.check("foreign_pixels", "screenshot --pid <other session's app> rejected", rejected(code, data),
                   "" if rejected(code, data) else "exit %s" % code)
        _, code, data, _ = bs(self.cfg["bin"], self.session, ["quit", "--pid", pid], 30)
        self.check("cross_session_termination", "quit --pid <other session's app> rejected", rejected(code, data),
                   "" if rejected(code, data) else "exit %s" % code)

    # -- roles
    def steady(self):
        cfg = self.cfg
        role = cfg["role"]
        if not self.launch():
            self.ready({"failed": True})
            return
        prep = {}
        if role == "input":
            field = self.find_ref("textfield")
            button = self.find_ref("button", "Increment")
            windows = bs(cfg["bin"], self.session, ["windows"], 30)[2] or {}
            frame = (windows.get("windows") or [{}])[0].get("frame")
            if not field or not button or not frame:
                self.check("other", "input setup", False, "field %s button %s frame %s" % (bool(field), bool(button), frame))
                self.ready({"failed": True})
                return
            # The pad is 380x130 at (20, 20) from the content's bottom-left.
            prep = {"field": field["ref"], "button": button["ref"],
                    "pad": [int(frame["x"] + 210), int(frame["y"] + frame["h"] - 85)]}
        self.ready()
        go = self.wait_go()
        self.start, self.end = go["start"], go["end"]
        sleep_until(self.start)
        late = go["late"].get(self.session)   # odd sessions keep working while the others stop
        stop_at = late if late else self.end
        cross_at = self.start + (self.end - self.start) / 2
        crossed = False
        iteration = 0
        while time.time() < stop_at:
            if not crossed and time.time() >= cross_at:
                self.cross_session(go)
                crossed = True
            iteration += 1
            if role == "idle":
                time.sleep(min(0.25, max(0, stop_at - time.time())))
            elif role == "input":
                self.type_and_verify("%s-%d" % (cfg["marker"], iteration), prep["field"], True)
                _, _, _, pressed = self.run_bs("press", ["press", prep["button"]], 30)
                if pressed:
                    self.count("presses")
                _, _, _, clicked = self.run_bs("click", ["click", str(prep["pad"][0]), str(prep["pad"][1])], 30)
                if clicked:
                    self.count("clicks")
            elif role == "capture":
                self.capture_once()
        if not crossed:
            self.cross_session(go)
        if late:
            # Every even session has stopped by now; this app must be the same live process.
            same = ident(self.pid) == read_json(self.cfg["ready"])["ident"]
            self.check("cross_session_termination", "app survived the other sessions' stops", same,
                       "" if same else "pid %s gone or replaced" % self.pid)
        if role == "input":
            self.verify_input()
        self.stop()

    def capture_once(self):
        cfg = self.cfg
        shot = os.path.join(cfg["dir"], "shots", "%s.%s" % (self.session, cfg["format"]))
        args = ["screenshot", "-o", shot] + (["--scale", str(cfg["scale"])] if cfg["scale"] != 1 else [])
        _, _, data, good = self.run_bs("screenshot", args, cfg["op_timeout"])
        if not good:
            return
        self.count("shots")
        size = "%sx%s" % (data.get("width"), data.get("height"))
        self.counts.setdefault("resolutions", {})
        self.counts["resolutions"][size] = self.counts["resolutions"].get(size, 0) + 1
        out = subprocess.run([cfg["pixels"], shot], stdout=subprocess.PIPE).stdout.decode().split()
        if len(out) != 2:
            self.check("other", "pixel count", False, "pixels failed on %s" % shot)
            return
        red, green = int(out[0]), int(out[1])
        own, foreign = (red, green) if cfg["env"]["TESTAPP_PAD"] == "red" else (green, red)
        # Screenshots are points x scale, so one pad (380x130 pt) is ~49,400 x scale^2 pixels, less
        # its white label; the title bar buttons add a few hundred red/green. More than 1.5 pads of
        # the own colour means another same-colour session's pad got in (even in the first shot).
        pad = 380 * 130 * cfg["scale"] ** 2
        bad = []
        if foreign >= max(1000, 0.02 * pad):
            bad.append("%d foreign-colour pixels" % foreign)
        if own < 0.5 * pad:
            bad.append("only %d own-colour pixels (one pad is ~%d)" % (own, pad))
        if own > 1.5 * pad:
            bad.append("%d own-colour pixels: more than one pad (~%d each)" % (own, pad))
        if bad:
            keep = os.path.join(cfg["dir"], "failures")
            os.makedirs(keep, exist_ok=True)
            kept = os.path.join(keep, "%s-%d.%s" % (self.session, self.counts["shots"], cfg["format"]))
            shutil.copyfile(shot, kept)
            self.check("foreign_pixels", "screenshot shows only this session's pad", False, "; ".join(bad) + " (" + kept + ")")
            self.count("bad_shots")

    def verify_input(self):
        cfg = self.cfg
        presses = self.counts.get("presses", 0)
        label = None
        deadline = time.time() + 3
        while time.time() < deadline:
            el = self.find_ref("statictext", "count:")
            label = el.get("value") if el else None
            if label == "count: %d" % presses:
                break
            time.sleep(0.1)
        self.check("wrong_target_input", "Increment count equals this session's presses", label == "count: %d" % presses,
                   "label %r after %d presses" % (label, presses))
        try:
            with open(cfg["env"]["TESTAPP_LOG"]) as f:
                lines = f.read().splitlines()
        except OSError as e:
            self.check("other", "fixture log", False, str(e))
            return
        own = cfg["marker"]
        bad_text = [l for l in lines if l.startswith("text=") and not self.own_text(l[5:], own)]
        self.check("wrong_target_input", "fixture log holds only this session's text", not bad_text,
                   "; ".join(bad_text[:5]))
        clicks = sum(1 for l in lines if l.startswith("pad click "))
        self.check("wrong_target_input", "pad clicks in the log equal this session's clicks",
                   clicks == self.counts.get("clicks", 0), "log %d, sent %d" % (clicks, self.counts.get("clicks", 0)))
        incs = sum(1 for l in lines if l.startswith("inc "))
        self.check("wrong_target_input", "increments in the log equal this session's presses", incs == presses,
                   "log %d, pressed %d" % (incs, presses))

    @staticmethod
    def own_text(value, marker):
        """Typing arrives one character at a time: every value must be a prefix of '<marker>-<n>'."""
        if value == "" or marker.startswith(value):
            return True
        rest = value[len(marker) + 1:]
        return value.startswith(marker + "-") and (rest == "" or rest.isdigit())

    def stop(self):
        _, _, data, good = self.run_bs("stop", ["stop"], 60)
        gone = False
        deadline = time.time() + 6
        while time.time() < deadline:
            if ident(self.pid) is None:
                gone = True
                break
            time.sleep(0.05)
        self.check("other", "own stop quit own app", good and gone, "" if gone else "pid %s still alive" % self.pid)

    def cycle(self):
        go = self.wait_go()
        self.start = go["start"]
        sleep_until(self.start)
        if not self.launch():
            self.ready({"failed": True})
            return
        if self.cfg.get("typecheck"):
            field = self.find_ref("textfield")
            if field:
                self.type_and_verify(self.cfg["marker"], field["ref"], False)
            else:
                self.check("other", "find text field after launch", False, "")
        self.ready()
        if not wait_for_file(self.cfg["release"], time.time() + 900):
            raise SystemExit("worker %s: no release signal" % self.session)
        self.stop()

    def finish(self):
        write_json(self.cfg["result"], {"session": self.session, "role": self.cfg["role"], "pid": self.pid,
                                        "events": self.events, "errors": self.errors, "checks": self.checks,
                                        "counts": self.counts})


def worker_main(path):
    w = Worker(read_json(path))
    try:
        if w.cfg["role"] == "cycle":
            w.cycle()
        else:
            w.steady()
    except Exception as e:  # report instead of dying silently
        w.check("other", "worker crashed", False, repr(e))
        if not os.path.exists(w.cfg["ready"]):
            write_json(w.cfg["ready"], {"session": w.session, "failed": True})
        raise
    finally:
        w.finish()


# ---------------------------------------------------------------- orchestrator probes

def parse_cpu(text):
    seconds = 0.0
    for part in text.replace("-", ":").split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


class Sampler(threading.Thread):
    """Every second: CPU (from cumulative CPU-time deltas, not ps %cpu) and RSS for the daemon,
    WindowServer, the Dock and this run's fixture apps; memory pressure; client process count."""

    def __init__(self, run):
        threading.Thread.__init__(self, daemon=True)
        self.run_ = run
        self.samples = []
        self.halt = threading.Event()

    def run(self):
        prev, prev_t = {}, None
        while not self.halt.is_set():
            t = time.time()
            rows = self.run_.ps()
            daemon = self.run_.daemon_pid()
            groups = {"daemon": [], "windowserver": [], "dock": [], "fixtures": [], "clients": []}
            for pid, cpu, rss, comm in rows:
                if pid == daemon:
                    groups["daemon"].append((pid, cpu, rss))
                elif comm.endswith("/WindowServer"):
                    groups["windowserver"].append((pid, cpu, rss))
                elif comm.endswith("/Dock.app/Contents/MacOS/Dock"):
                    groups["dock"].append((pid, cpu, rss))
                elif self.run_.is_fixture(comm):
                    groups["fixtures"].append((pid, cpu, rss))
                elif comm == self.run_.bin:
                    groups["clients"].append((pid, cpu, rss))
            sample = {"t": t, "pressure": self.run_.pressure_level(), "freePct": self.run_.free_pct()}
            current = {}
            for name, members in groups.items():
                cpu_delta = 0.0
                for pid, cpu, rss in members:
                    current[pid] = cpu
                    if prev_t is not None:
                        cpu_delta += cpu - prev.get(pid, 0.0) if pid in prev else cpu
                sample[name] = {"procs": len(members), "rssMB": round(sum(m[2] for m in members) / 1024.0, 1)}
                if prev_t is not None:
                    sample[name]["cpuPct"] = round(max(0.0, cpu_delta) / (t - prev_t) * 100, 1)
            prev, prev_t = current, t
            self.samples.append(sample)
            self.halt.wait(max(0.0, 1.0 - (time.time() - t)))


class LockProbe(threading.Thread):
    """Times flock(2) on the shared locks every 100 ms (acquire, then release at once): how long
    any client would wait for the app registry (`lock`, exclusive), for `lifecycle.lock` (shared,
    as every launch takes it) and for `capture.lock` (exclusive, as screenshots take it in builds
    that serialize ScreenCaptureKit calls; always free in builds that don't). Per-app locks don't
    contend across sessions here, since each session drives its own app."""

    LOCKS = [("registry", "lock", fcntl.LOCK_EX), ("lifecycle", "lifecycle.lock", fcntl.LOCK_SH),
             ("capture", "capture.lock", fcntl.LOCK_EX)]

    def __init__(self, home, halt, key, name, mode):
        threading.Thread.__init__(self, daemon=True)   # one thread per lock: a long wait on one doesn't thin out the others
        self.path, self.mode, self.key = os.path.join(home, name), mode, key
        self.waits = []
        self.halt = halt

    @classmethod
    def all(cls, home):
        halt = threading.Event()
        return halt, [cls(home, halt, key, name, mode) for key, name, mode in cls.LOCKS]

    def run(self):
        while not self.halt.is_set():
            try:
                fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
            except OSError:
                self.halt.wait(0.1)
                continue
            try:
                started = time.monotonic()
                fcntl.flock(fd, self.mode)
                self.waits.append((time.time(), (time.monotonic() - started) * 1000))
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)
            self.halt.wait(0.1)


# ---------------------------------------------------------------- orchestrator

class Run:
    def __init__(self, a):
        self.a = a
        self.bin = os.path.realpath(a.bin)
        self.work = a.work
        self.home = os.environ["BACKSTAGE_HOME"]
        self.app = os.path.realpath(a.app)
        self.app_exe = os.path.join(self.app, "Contents/MacOS/BackstageTestApp")
        self.n = a.sessions
        self.results = {}
        self.failed_gates = {g: [] for g in GATES}
        self.other_failures = []
        stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.out = os.path.join(a.results, "%s-n%d" % (stamp, self.n))
        os.makedirs(self.out, exist_ok=True)
        with open(os.path.join(self.work, "results-path"), "w") as f:
            f.write(self.out)
        self.anchor = None
        self.children = []

    # -- system probes
    def ps(self):
        out = subprocess.run(["ps", "-A", "-o", "pid=,time=,rss=,comm="], stdout=subprocess.PIPE).stdout.decode("utf-8", "replace")
        rows = []
        for line in out.splitlines():
            parts = line.split(None, 3)
            if len(parts) == 4:
                try:
                    rows.append((int(parts[0]), parse_cpu(parts[1]), int(parts[2]), parts[3]))
                except ValueError:
                    pass
        return rows

    def is_fixture(self, comm):
        return comm == self.app_exe or (comm.endswith(FIXTURE_EXE) and os.path.realpath(comm) == self.app_exe)

    def daemon_pid(self):
        try:
            return read_json(os.path.join(self.home, "daemon.json"))["pid"]
        except (OSError, ValueError, KeyError):
            return None

    def pressure_level(self):
        out = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], stdout=subprocess.PIPE).stdout.decode().strip()
        return int(out) if out.isdigit() else None

    def free_pct(self):
        out = subprocess.run(["memory_pressure", "-Q"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode()
        m = re.search(r"free percentage: (\d+)%", out)
        return int(m.group(1)) if m else None

    def swap_used_mb(self):
        out = subprocess.run(["sysctl", "-n", "vm.swapusage"], stdout=subprocess.PIPE).stdout.decode()
        m = re.search(r"used = ([\d.]+)M", out)
        return float(m.group(1)) if m else None

    def ctl(self, args, timeout=120):
        return bs(self.bin, "load-ctl", args, timeout)

    def list_all(self):
        _, code, data, out = self.ctl(["list", "--all"], 60)
        return data.get("apps", []) if ok(code, data) else None

    def fixtures_alive(self):
        return [pid for pid, _, _, comm in self.ps() if self.is_fixture(comm)]

    def snapshot(self):
        """Live processes, registry entries, lock files and memory, for the leak check."""
        rows = self.ps()
        daemon = self.daemon_pid()
        snap = {"fixtures": sum(1 for r in rows if self.is_fixture(r[3])),
                "clients": sum(1 for r in rows if r[3] == self.bin and r[0] != daemon)}
        apps = self.list_all()
        snap["registered"] = len(apps) if apps is not None else None
        for sub in ("locks", "logs", "wrappers"):
            d = os.path.join(self.home, sub)
            snap[sub + "Files"] = len(os.listdir(d)) if os.path.isdir(d) else 0
        for pid, _, rss, comm in rows:
            if pid == daemon:
                snap["daemonRssMB"] = round(rss / 1024.0, 1)
            elif comm.endswith("/WindowServer"):
                snap["windowserverRssMB"] = round(rss / 1024.0, 1)
        if daemon:
            out = subprocess.run(["lsof", "-n", "-P", "-p", str(daemon)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
            snap["daemonFds"] = max(0, len(out.splitlines()) - 1)
            th = subprocess.run(["ps", "-M", "-p", str(daemon)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
            snap["daemonThreads"] = max(0, len(th.splitlines()) - 1)
        return snap

    # -- probes around a workload
    def start_probes(self, d):
        self.sampler = Sampler(self)
        self.locks_halt, self.locks = LockProbe.all(self.home)
        self.sampler.start()
        for t in self.locks:
            t.start()
        self.probe_stop = os.path.join(d, "probe.stop")
        self.probe_out = os.path.join(d, "shareable.jsonl")
        with open(self.probe_out, "w") as f:
            self.probe = subprocess.Popen([self.a.probe, "shareable", str(self.a.shareable_interval_ms), self.probe_stop,
                                           os.path.join(self.home, "capture.lock")], stdout=f)
        self.children.append(self.probe)
        self.swap_start = self.swap_used_mb()

    def stop_probes(self, window):
        with open(self.probe_stop, "w"):
            pass
        try:
            self.probe.wait(15)
        except subprocess.TimeoutExpired:
            self.probe.kill()
        self.sampler.halt.set()
        self.locks_halt.set()
        self.sampler.join(10)
        for t in self.locks:
            t.join(10)
        lo, hi = window
        shareable, shareable_err, probe_hung = [], None, 0
        for line in open(self.probe_out):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if "error" in e and "t" not in e:
                shareable_err = e["error"]
            elif e.get("hung"):
                probe_hung += 1
                self.other_failures.append("SCShareableContent probe: no reply in 20 s (it exits; later samples are missing)")
            elif e.get("ok") and lo <= e["t"] <= hi:
                shareable.append(e["ms"])
        samples = [s for s in self.sampler.samples if lo <= s["t"] <= hi]
        resources = {}
        for group in ("daemon", "windowserver", "dock", "fixtures", "clients"):
            cpu = [s[group]["cpuPct"] for s in samples if "cpuPct" in s[group]]
            rss = [s[group]["rssMB"] for s in samples]
            procs = [s[group]["procs"] for s in samples]
            resources[group] = {"cpuPctMean": round(sum(cpu) / len(cpu), 1) if cpu else None,
                                "cpuPctMax": max(cpu) if cpu else None,
                                "rssMBMean": round(sum(rss) / len(rss), 1) if rss else None,
                                "rssMBMax": max(rss) if rss else None,
                                "procsMax": max(procs) if procs else 0}
        fixtures = max((s["fixtures"]["procs"] for s in samples), default=0)
        if fixtures and resources["fixtures"]["rssMBMean"] is not None:
            resources["fixtures"]["rssMBPerApp"] = round(resources["fixtures"]["rssMBMax"] / fixtures, 1)
        pressure = [s["pressure"] for s in samples if s["pressure"] is not None]
        free = [s["freePct"] for s in samples if s["freePct"] is not None]
        memory = {"pressureLevelMax": max(pressure) if pressure else None,
                  "pressureLevels": "1 normal, 2 warn, 4 critical",
                  "freePctMin": min(free) if free else None,
                  "swapUsedMBStart": self.swap_start, "swapUsedMBEnd": self.swap_used_mb()}
        locks = dict((t.key, stats([ms for at, ms in t.waits if lo <= at <= hi], 3)) for t in self.locks)
        return {"resources": resources, "memory": memory, "resourceSamples": len(samples),
                "shareableContentMs": stats(shareable) if shareable_err is None else {"n": 0, "error": shareable_err},
                "shareableContentHung": probe_hung,
                "lockWaitMs": locks}

    # -- workers
    def worker_cfg(self, d, i, role, extra=None):
        session = "s%02d" % i
        cfg = {"bin": self.bin, "session": session, "index": i, "role": role, "app": self.app, "dir": d,
               "marker": "m%02dx" % i, "markers": ["m%02dx" % j for j in range(self.n)],
               "scale": self.a.scale, "format": self.a.format, "pixels": self.a.pixels, "op_timeout": self.a.op_timeout,
               "go": os.path.join(d, "go.json"), "release": os.path.join(d, "release"),
               "ready": os.path.join(d, "ready-%s.json" % session), "result": os.path.join(d, "result-%s.json" % session),
               "env": {"TESTAPP_LOG": os.path.join(d, "fixture-%s.log" % session), "TESTAPP_MARKER": "m%02dx" % i,
                       "TESTAPP_PAD": "red" if i % 2 == 0 else "green"}}
        if self.a.accessory:
            cfg["env"]["TESTAPP_ACCESSORY"] = "1"
        cfg.update(extra or {})
        return cfg

    def spawn(self, cfgs):
        procs = []
        for cfg in cfgs:
            path = os.path.join(cfg["dir"], "worker-%s.json" % cfg["session"])
            write_json(path, cfg)
            log = open(os.path.join(cfg["dir"], "worker-%s.log" % cfg["session"]), "w")
            p = subprocess.Popen([sys.executable, os.path.abspath(__file__), "worker", path], stdout=log, stderr=subprocess.STDOUT)
            self.children.append(p)
            procs.append(p)
        return procs

    def wait_ready(self, cfgs, timeout):
        deadline = time.time() + timeout
        ready = {}
        for cfg in cfgs:
            if not wait_for_file(cfg["ready"], deadline):
                raise RuntimeError("session %s never became ready (see %s)" % (cfg["session"], cfg["dir"]))
            ready[cfg["session"]] = read_json(cfg["ready"])
        failed = [s for s, r in ready.items() if r.get("failed")]
        return ready, failed

    def wait_exit(self, procs, timeout):
        deadline = time.time() + timeout
        for p in procs:
            try:
                p.wait(max(1, deadline - time.time()))
            except subprocess.TimeoutExpired:
                p.kill()
                self.other_failures.append("worker %s timed out" % p.args[-1])

    def collect(self, cfgs, window, steady_end=None):
        """Merge worker results: latency per op inside the measured window, errors and checks."""
        by_op, errors_by_op, checks, counts, tail_ops = {}, {}, [], {}, 0
        resolutions = {}
        for cfg in cfgs:
            try:
                r = read_json(cfg["result"])
            except (OSError, ValueError):
                checks.append({"gate": "other", "name": "worker result", "ok": False, "detail": cfg["session"], "session": cfg["session"]})
                continue
            for op, t, ms, good in r["events"]:
                if steady_end is not None and t < 0:
                    continue  # the launch before the window opens; reported as launchMs
                # By start time: a command started inside the window counts however long it took.
                if steady_end is not None and t - ms / 1000.0 > steady_end:
                    tail_ops += 1
                    continue
                if good:
                    by_op.setdefault(op, []).append(ms)
                else:
                    errors_by_op[op] = errors_by_op.get(op, 0) + 1
            for c in r["checks"]:
                c["session"] = cfg["session"]
                checks.append(c)
            for k, v in r["counts"].items():
                if k == "resolutions":
                    for size, n in v.items():
                        resolutions[size] = resolutions.get(size, 0) + n
                else:
                    counts[k] = counts.get(k, 0) + v
            for e in r["errors"][:3]:
                e["session"] = cfg["session"]
                self.other_failures.append("%(session)s %(op)s: %(error)s" % e)
        return by_op, errors_by_op, checks, counts, resolutions, tail_ops

    def record_checks(self, workload, checks):
        summary = {g: {"checked": 0, "failed": 0} for g in GATES + ["other"]}
        for c in checks:
            s = summary[c["gate"]]
            s["checked"] += 1
            if not c["ok"]:
                s["failed"] += 1
                line = "%s/%s: %s %s" % (workload, c["session"], c["name"], c["detail"])
                (self.failed_gates[c["gate"]] if c["gate"] in GATES else self.other_failures).append(line)
        return summary

    def registry_check(self, workload, expected):
        apps = self.list_all()
        n = len(apps) if apps is not None else None
        if n != expected:
            self.other_failures.append("%s: %s apps registered, expected %d" % (workload, n, expected))
        return n

    def anchor_alive(self, workload):
        if ident(self.anchor["pid"]) != self.anchor["ident"]:
            self.failed_gates["cross_session_termination"].append("%s: the anchor session's app died" % workload)

    def settle(self, workload):
        """After a workload: only the anchor app is left, registered and alive."""
        deadline = time.time() + 10
        while time.time() < deadline and len(self.fixtures_alive()) > 1:
            time.sleep(0.2)
        left = self.fixtures_alive()
        if left != [self.anchor["pid"]]:
            self.other_failures.append("%s: fixture processes left after every session stopped: %s" % (workload, left))
        self.registry_check(workload + " teardown", 1)
        self.anchor_alive(workload)

    # -- workloads
    def steady(self, name, roles):
        d = os.path.join(self.work, name)
        os.makedirs(os.path.join(d, "shots"))
        cfgs = [self.worker_cfg(d, i, roles[i]) for i in range(self.n)]
        print("== %s: %d sessions (%s)" % (name, self.n, ", ".join("%d %s" % (roles.count(r), r) for r in sorted(set(roles)))), flush=True)
        self.start_probes(d)
        procs = self.spawn(cfgs)
        ready, failed = self.wait_ready(cfgs, 120 + 10 * self.n)
        if failed:
            self.other_failures.append("%s: sessions failed to start: %s" % (name, failed))
        registered = self.registry_check(name, self.n + 1)
        start = time.time() + 1.0
        end = start + self.a.duration
        tail = min(5.0, max(2.0, self.a.duration / 4))
        late = {c["session"]: end + tail for c in cfgs if c["index"] % 2 == 1}
        neighbor = {}
        if self.n > 1:
            for i, c in enumerate(cfgs):
                neighbor[c["session"]] = ready[cfgs[(i + 1) % self.n]["session"]]
        write_json(cfgs[0]["go"], {"start": start, "end": end, "late": late, "neighbor": neighbor})
        self.wait_exit(procs, self.a.duration + tail + 180)
        probes = self.stop_probes((start, end))
        by_op, errs, checks, counts, resolutions, tail_ops = self.collect(cfgs, (start, end), steady_end=self.a.duration)
        self.settle(name)
        total = sum(len(v) for v in by_op.values())
        result = {"sessions": self.n, "roles": {r: roles.count(r) for r in set(roles)}, "durationS": self.a.duration,
                  "registeredDuringRun": registered,
                  "launchMs": stats([r["launchMs"] for r in ready.values() if "launchMs" in r]),
                  "latencyMs": {op: stats(v) for op, v in sorted(by_op.items())},
                  "opsPerSec": dict([(op, round(len(v) / self.a.duration, 2)) for op, v in sorted(by_op.items())] +
                                    [("total", round(total / self.a.duration, 2))]),
                  "errors": errs, "counts": counts, "tailOps": tail_ops,
                  "checks": self.record_checks(name, checks)}
        if resolutions:
            result["capture"] = {"format": self.a.format, "scale": self.a.scale, "resolutions": resolutions}
        result.update(probes)
        self.results[name] = result

    def cycles(self, name, rounds, typecheck):
        d0 = os.path.join(self.work, name)
        os.makedirs(d0)
        print("== %s: %d rounds of %d concurrent launches, then concurrent stops" % (name, rounds, self.n), flush=True)
        self.start_probes(d0)
        t0 = time.time()
        launch, stop, checks_all, errs, snaps = [], [], [], {}, []
        for r in range(rounds):
            d = os.path.join(d0, "round-%d" % r)
            os.makedirs(d)
            cfgs = [self.worker_cfg(d, i, "cycle", {"typecheck": typecheck}) for i in range(self.n)]
            procs = self.spawn(cfgs)
            start = time.time() + 0.5 + 0.03 * self.n
            write_json(cfgs[0]["go"], {"start": start})
            ready, failed = self.wait_ready(cfgs, 120 + 10 * self.n)
            if failed:
                self.other_failures.append("%s round %d: sessions failed to launch: %s" % (name, r, failed))
            self.registry_check("%s round %d" % (name, r), self.n + 1)
            with open(cfgs[0]["release"], "w"):
                pass
            self.wait_exit(procs, 180)
            by_op, e, checks, _, _, _ = self.collect(cfgs, None)
            launch += by_op.get("launch", [])
            stop += by_op.get("stop", [])
            for op, k in e.items():
                errs[op] = errs.get(op, 0) + k
            checks_all += checks
            self.settle("%s round %d" % (name, r))
            snap = self.snapshot()
            snap["round"] = r
            snaps.append(snap)
        t1 = time.time()
        probes = self.stop_probes((t0, t1))
        result = {"sessions": self.n, "rounds": rounds, "launchMs": stats(launch), "stopMs": stats(stop),
                  "launchesPerSec": round(len(launch) / max(0.001, t1 - t0), 2), "errors": errs,
                  "checks": self.record_checks(name, checks_all), "afterEachRound": snaps}
        if len(snaps) >= 2:
            first, last = snaps[0], snaps[-1]
            growth = {}
            for k in ("daemonRssMB", "daemonFds", "daemonThreads", "windowserverRssMB", "locksFiles", "logsFiles", "wrappersFiles"):
                if k in first and k in last:
                    growth[k] = round(last[k] - first[k], 1)
            result["growthFirstToLastRound"] = growth
            # "clients" (any process running this backstage binary) is informational: other users of the
            # same build would show up there.
            leftovers = [s for s in snaps if s["fixtures"] != 1 or s["registered"] != 1]
            result["leftovers"] = len(leftovers)
            if growth.get("daemonFds", 0) >= len(snaps) - 1 and len(snaps) > 2:
                self.other_failures.append("%s: daemon file descriptors grew by %s over %d rounds" % (name, growth["daemonFds"], len(snaps)))
        result.update(probes)
        self.results[name] = result

    # -- the whole run
    def machine(self):
        def sysctl(key):
            return subprocess.run(["sysctl", "-n", key], stdout=subprocess.PIPE).stdout.decode().strip()
        sw = subprocess.run(["sw_vers"], stdout=subprocess.PIPE).stdout.decode()
        info = {"model": sysctl("hw.model"), "cpu": sysctl("machdep.cpu.brand_string"), "cores": int(sysctl("hw.ncpu")),
                "ramGB": round(int(sysctl("hw.memsize")) / 2 ** 30, 1),
                "macOS": dict(re.findall(r"(\w+):\s+(\S+)", sw)), "hostLoadAvg": sysctl("vm.loadavg")}
        return info

    def build_info(self):
        root = self.a.root

        def git(*args):
            return subprocess.run(["git", "-C", root] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode().strip()
        with open(os.path.join(root, "tests", "TestApp.swift"), "rb") as f:
            fixture = hashlib.sha256(f.read()).hexdigest()[:16]
        return {"gitRevision": git("rev-parse", "--short", "HEAD"), "gitDirty": bool(git("status", "--porcelain", "--", "Sources", "tests")),
                "backstageBinary": self.bin, "fixtureSourceSha256": fixture,
                "fixtureActivationPolicy": "accessory (TESTAPP_ACCESSORY=1)" if self.a.accessory else "regular"}

    def execute(self):
        a = self.a
        print("results: %s" % self.out, flush=True)
        self.results = {}
        meta = {"startedAt": datetime.datetime.now().isoformat(timespec="seconds"), "machine": self.machine(),
                "build": self.build_info(),
                "config": {"sessions": self.n, "workloads": a.workloads, "durationS": a.duration, "launchRounds": a.rounds,
                           "cycles": a.cycles, "captureSessions": a.capture_sessions, "captureScale": a.scale,
                           "captureFormat": a.format, "screenshotTimeoutS": a.op_timeout, "shareableProbeIntervalMs": a.shareable_interval_ms,
                           "lockProbeIntervalMs": 100, "resourceSampleIntervalS": 1,
                           "env": {k: os.environ.get(k) for k in ("BACKSTAGE_WIDTH", "BACKSTAGE_HEIGHT", "BACKSTAGE_MENUBAR")},
                           "smoke": not a.dedicated}}
        # Daemon start on its own, then an anchor app that keeps the daemon (and its memory) alive
        # across workloads: a session's plain `stop` stops the daemon when no app is left.
        ms, code, data, out = self.ctl(["start"], 60)
        if not ok(code, data):
            raise RuntimeError("backstage start failed: " + out)
        meta["daemonStartMs"] = round(ms, 1)
        _, code, status, _ = self.ctl(["status"], 30)
        meta["daemon"] = (status or {}).get("daemon")
        displays = subprocess.run([a.probe, "displays"], stdout=subprocess.PIPE).stdout.decode()
        meta["displays"] = json.loads(displays).get("displays") if displays.strip() else None
        anchor_env = ["--env", "TESTAPP_LOG=%s" % os.path.join(self.work, "anchor.log"), "--env", "TESTAPP_MARKER=anchor"]
        if a.accessory:
            anchor_env += ["--env", "TESTAPP_ACCESSORY=1"]
        ms, code, data, out = bs(self.bin, "anchor", ["launch", self.app, "--timeout", "60"] + anchor_env, 180)
        if not ok(code, data):
            raise RuntimeError("anchor launch failed: " + out)
        self.anchor = {"pid": data["pid"], "ident": ident(data["pid"])}
        meta["anchor"] = {"session": "anchor", "launchMs": round(ms, 1), "note": "one idle fixture kept alive for the whole run"}
        d = os.path.join(self.work, "baseline")
        os.makedirs(d)
        self.start_probes(d)
        t0 = time.time()
        time.sleep(3)
        meta["baseline"] = self.stop_probes((t0, time.time()))
        meta["baseline"]["note"] = "daemon + anchor app only, 3 s"
        meta["leakSnapshotStart"] = self.snapshot()
        k = a.capture_sessions if a.capture_sessions is not None else max(1, self.n // 4)
        for w in a.workloads:
            if w == "idle":
                self.steady("idle", ["idle"] * self.n)
            elif w == "input":
                self.steady("input", ["input"] * self.n)
            elif w == "capture":
                self.steady("capture", ["capture"] * self.n)
            elif w == "mixed":
                self.steady("mixed", ["capture"] * min(k, self.n) + ["input"] * max(0, self.n - k))
            elif w == "launch":
                self.cycles("launch", a.rounds, True)
            elif w == "cycles":
                self.cycles("cycles", a.cycles, False)
        meta["leakSnapshotEnd"] = self.snapshot()
        ms, code, data, out = bs(self.bin, "anchor", ["stop"], 60)
        deadline = time.time() + 10
        while time.time() < deadline and (self.daemon_pid() and ident(self.daemon_pid())):
            time.sleep(0.2)
        meta["finalStop"] = {"ms": round(ms, 1), "ok": ok(code, data),
                             "daemonGone": not (self.daemon_pid() and ident(self.daemon_pid())),
                             "fixturesLeft": self.fixtures_alive()}
        if meta["finalStop"]["fixturesLeft"] or not meta["finalStop"]["daemonGone"]:
            self.other_failures.append("after the last stop: daemon gone=%s, fixtures left %s" % (meta["finalStop"]["daemonGone"], meta["finalStop"]["fixturesLeft"]))
        meta["finishedAt"] = datetime.datetime.now().isoformat(timespec="seconds")
        report = {"meta": meta, "workloads": self.results,
                  "gate": {g: {"failures": len(v), "details": v[:50]} for g, v in self.failed_gates.items()},
                  "otherFailures": self.other_failures[:100]}
        report["passed"] = not self.other_failures and not any(self.failed_gates.values())
        write_json(os.path.join(self.out, "results.json"), report)
        with open(os.path.join(self.out, "summary.md"), "w") as f:
            f.write(summary_md(report))
        return report["passed"]

    def abort(self):
        for p in self.children:
            if p.poll() is None:
                p.kill()


# ---------------------------------------------------------------- reporting

def fmt_stats(s):
    if not s or not s.get("n"):
        return "n=0" + (" (%s)" % s["error"] if s and s.get("error") else "")
    return "%s / %s (n=%d)" % (s["p50"], s["p95"], s["n"])


def summary_md(r):
    m = r["meta"]
    mach = m["machine"]
    lines = ["# backstage load run: %d sessions" % m["config"]["sessions"], ""]
    if m["config"]["smoke"]:
        lines += ["> **Smoke run, not representative.** Run on a working desktop at small scale to prove the",
                  "> harness works; the numbers include whatever else the machine was doing.", ""]
    lines += ["- Result: **%s**" % ("PASS" if r["passed"] else "FAIL"),
              "- Machine: %s, %s, %d cores, %s GB RAM, macOS %s (%s)" % (
                  mach["model"], mach["cpu"], mach["cores"], mach["ramGB"], mach["macOS"].get("ProductVersion"), mach["macOS"].get("BuildVersion")),
              "- Build: %s%s, fixture %s, activation policy %s" % (
                  m["build"]["gitRevision"], " (dirty)" if m["build"]["gitDirty"] else "", m["build"]["fixtureSourceSha256"],
                  m["build"]["fixtureActivationPolicy"])]
    disp = m.get("displays") or []
    lines.append("- Displays: " + "; ".join("%s %dx%d pt (%dx%d px)%s" % (
        "agent" if x["agentDisplay"] else "user", x["points"]["w"], x["points"]["h"], x["pixels"]["w"], x["pixels"]["h"],
        " main" if x["main"] else "") for x in disp))
    c = m["config"]
    lines.append("- Config: duration %ss per steady workload, %s launch rounds, %s leak cycles, capture %s at scale %s, menubar %s" % (
        c["durationS"], c["launchRounds"], c["cycles"], c["captureFormat"], c["captureScale"], c["env"].get("BACKSTAGE_MENUBAR")))
    lines.append("- Daemon start: %s ms. One idle anchor app runs throughout, so sessions + 1 fixtures are live." % m.get("daemonStartMs"))
    lines.append("- Latencies are client wall-clock per CLI command, p50 / p95 ms (n). SCShareableContent and lock waits are")
    lines.append("  external probes (tests/probe.swift every %s ms; flock every 100 ms). The watchdog busy-loops one core." % c["shareableProbeIntervalMs"])
    lines += ["", "## Release gate", "", "| Check | Failures |", "|---|---|"]
    for g, v in r["gate"].items():
        lines.append("| %s | %d |" % (g.replace("_", " "), v["failures"]))
    wd = r.get("watchdog")
    if wd:
        lines.append("| non-interference watchdog | %s |" % ("0" if wd["passed"] else "FAILED"))
    lines += ["", "## Workloads", ""]
    lines += ["| Workload | ops/s | latency p50 / p95 ms (n) | SCShareableContent ms | lock wait ms: registry, capture | daemon CPU % mean/max | WindowServer CPU % mean/max | fixtures CPU % / RSS MB | pressure max |",
              "|---|---|---|---|---|---|---|---|---|"]
    for name, w in r["workloads"].items():
        res = w["resources"]
        if "latencyMs" in w:
            lat = "<br>".join("%s %s" % (op, fmt_stats(s)) for op, s in w["latencyMs"].items()) or "-"
            ops = w["opsPerSec"]["total"]
        else:
            lat = "launch %s<br>stop %s" % (fmt_stats(w["launchMs"]), fmt_stats(w["stopMs"]))
            ops = "%s launches" % w["launchesPerSec"]
        lines.append("| %s | %s | %s | %s | %s | %s / %s | %s / %s | %s / %s | %s |" % (
            name, ops, lat, fmt_stats(w["shareableContentMs"]),
            "%s<br>%s" % (fmt_stats(w["lockWaitMs"]["registry"]), fmt_stats(w["lockWaitMs"].get("capture"))),
            res["daemon"]["cpuPctMean"], res["daemon"]["cpuPctMax"], res["windowserver"]["cpuPctMean"], res["windowserver"]["cpuPctMax"],
            res["fixtures"]["cpuPctMean"], res["fixtures"]["rssMBMax"], w["memory"]["pressureLevelMax"]))
    for name, w in r["workloads"].items():
        hung = dict((k[5:], v) for k, v in (w.get("counts") or {}).items() if k.startswith("hung:"))
        if hung:
            lines.append("")
            lines.append("**Hung commands (%s):** %s, killed after no reply for %ss." % (name, hung, c.get("screenshotTimeoutS")))
    for name, w in r["workloads"].items():
        if "capture" in w:
            lines.append("")
            lines.append("Capture (%s): %s, scale %s, sizes %s." % (name, w["capture"]["format"], w["capture"]["scale"], w["capture"]["resolutions"]))
    cyc = r["workloads"].get("cycles") or r["workloads"].get("launch")
    if cyc:
        lines += ["", "## Leak check (%s)" % ("cycles" if "cycles" in r["workloads"] else "launch rounds"), "",
                  "| Round | fixtures | registered | lock files | daemon RSS MB | daemon fds | daemon threads | WindowServer RSS MB |", "|---|---|---|---|---|---|---|---|"]
        for s in cyc["afterEachRound"]:
            lines.append("| %s | %s | %s | %s | %s | %s | %s | %s |" % (s["round"], s["fixtures"], s["registered"], s["locksFiles"],
                                                                     s.get("daemonRssMB"), s.get("daemonFds"), s.get("daemonThreads"), s.get("windowserverRssMB")))
        if "growthFirstToLastRound" in cyc:
            lines.append("")
            lines.append("Growth first to last round: %s" % cyc["growthFirstToLastRound"])
    b = m["baseline"]["resources"]
    lines += ["", "Baseline (daemon + anchor, 3 s): daemon CPU %s%%, RSS %s MB; WindowServer CPU %s%%, RSS %s MB." % (
        b["daemon"]["cpuPctMean"], b["daemon"]["rssMBMax"], b["windowserver"]["cpuPctMean"], b["windowserver"]["rssMBMax"])]
    if r["otherFailures"] or any(v["failures"] for v in r["gate"].values()):
        lines += ["", "## Failures", ""]
        for g, v in r["gate"].items():
            lines += ["- %s: %s" % (g, d) for d in v["details"][:10]]
        lines += ["- %s" % f for f in r["otherFailures"][:20]]
    return "\n".join(lines) + "\n"


def finalize(out, watch_out, status):
    path = os.path.join(out, "results.json")
    try:
        r = read_json(path)
    except (OSError, ValueError):
        print("no results at %s" % path)
        return 1
    text = open(watch_out).read() if os.path.exists(watch_out) else ""
    passed = status == 0 and "PASS" in text
    r["watchdog"] = {"passed": passed, "exitStatus": status, "output": text.strip().splitlines()[-20:]}
    r["passed"] = r["passed"] and passed
    write_json(path, r)
    with open(os.path.join(out, "summary.md"), "w") as f:
        f.write(summary_md(r))
    print(open(os.path.join(out, "summary.md")).read())
    print("results: %s" % path)
    return 0 if r["passed"] else 1


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "worker":
        worker_main(sys.argv[2])
        return 0
    if len(sys.argv) == 5 and sys.argv[1] == "finalize":
        return finalize(sys.argv[2], sys.argv[3], int(sys.argv[4]))
    p = argparse.ArgumentParser(prog="tests/load.sh", description="backstage load harness (docs/LOAD_TESTING.md)")
    p.add_argument("mode", choices=["run"])
    p.add_argument("sessions", type=int, help="concurrent sessions, e.g. 2, 8, 16, 32")
    p.add_argument("workloads", nargs="?", default="all", help="comma list of %s, or all" % ",".join(WORKLOADS))
    p.add_argument("--duration", type=float, default=30, help="seconds per steady workload (default 30)")
    p.add_argument("--rounds", type=int, default=3, help="cold-launch burst rounds (default 3)")
    p.add_argument("--cycles", type=int, default=10, help="launch/stop cycles for the leak check (default 10)")
    p.add_argument("--capture-sessions", type=int, default=None, help="capturing sessions in the mixed run (default sessions/4, at least 1)")
    p.add_argument("--scale", type=float, default=1.0, help="screenshot --scale (default 1)")
    p.add_argument("--format", choices=["png", "jpg"], default="png")
    p.add_argument("--shareable-interval-ms", type=int, default=250)
    p.add_argument("--op-timeout", type=float, default=60,
                   help="seconds before a screenshot counts as hung and is killed (default 60; backstage's own capture timeout is 20)")
    p.add_argument("--accessory", action="store_true", help="run fixtures with TESTAPP_ACCESSORY=1 (no Dock icons; not with capture or mixed)")
    p.add_argument("--dedicated", action="store_true", help="confirm this is a separate user account or dedicated Mac (required above 4 sessions)")
    p.add_argument("--results", help="results directory (default <repo>/load-results)")
    p.add_argument("--bin", required=True)
    p.add_argument("--work", required=True)
    p.add_argument("--app", required=True)
    p.add_argument("--pixels", required=True)
    p.add_argument("--probe", required=True)
    p.add_argument("--root", required=True)
    a = p.parse_args()
    a.workloads = WORKLOADS if a.workloads == "all" else a.workloads.split(",")
    bad = [w for w in a.workloads if w not in WORKLOADS]
    if bad:
        p.error("unknown workload(s) %s; choose from %s" % (bad, WORKLOADS))
    if a.accessory and set(a.workloads) & {"capture", "mixed"}:
        p.error("--accessory can't be used with capture or mixed: screenshots of .accessory fixtures failed with "
                "'no visible windows on the agent display'. Use idle,input,launch,cycles.")
    if a.sessions < 1:
        p.error("sessions must be at least 1")
    if a.sessions > 4 and not a.dedicated:
        p.error("more than 4 sessions needs --dedicated: run on a separate macOS user account or a dedicated Mac, "
                "never on a desktop someone is using (docs/LOAD_TESTING.md)")
    a.results = os.path.abspath(a.results or os.path.join(a.root, "load-results"))
    run = Run(a)
    try:
        return 0 if run.execute() else 1
    finally:
        run.abort()


if __name__ == "__main__":
    sys.exit(main())
