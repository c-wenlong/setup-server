"""Mocked unit tests for the launcher backend.

No network, no subprocesses, no writes outside a temp dir: every probe and
every Popen is stubbed, and REPO_ROOT / JOBS_DIR / the registry are pointed
at a sandbox. Run from app/web/:

    python3 -m unittest discover -s tests -p 'test_*.py'
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import server  # noqa: E402


# Job steps run on daemon threads that outlive the test which started them: a
# test that calls start_action without waiting returns while its thread has yet
# to reach subprocess.Popen. Restoring the *real* Popen in tearDown therefore
# handed those late steps a live host, and `systemctl --user stop
# manimkc.service` ran for real. So the baseline Popen for the whole run is this
# guard rather than the real one — an unstubbed call cannot reach the box, and
# it is recorded so tearDown can fail the run instead of going quiet.
ESCAPED_POPEN = []


def _forbidden_popen(argv, **kwargs):
    line = " ".join(str(a) for a in argv)
    ESCAPED_POPEN.append(line)
    raise AssertionError(
        "a real subprocess escaped the sandbox: %s — stub subprocess.Popen "
        "(see ControlTestBase.record_popen)" % line)


subprocess.Popen = _forbidden_popen


class FakeProc:
    """A subprocess that never exits: the reaper thread parks on the event,
    so every started job stays 'running' for the duration of the test."""

    def __init__(self, argv, **kwargs):
        import threading
        self.argv = argv
        self.kwargs = kwargs
        self._done = threading.Event()

    def wait(self):
        self._done.wait()
        return 0


class CapturedProc:
    """A subprocess that has already exited, with canned stdout.

    The lifecycle steps only ever wait() on a process; the resources path's
    one `docker ps` reads its output instead, so this is the stub that grows
    communicate() and returncode. Like the others it is a pure fake: nothing
    here can reach the daemon.
    """

    def __init__(self, stdout="", code=0, raises=None):
        self.stdout_text = stdout
        self.returncode = code
        self.raises = raises
        self.killed = False

    def communicate(self, timeout=None):
        if self.raises is not None and not self.killed:
            raise self.raises
        return self.stdout_text, ""

    def kill(self):
        self.killed = True

    def wait(self):
        return self.returncode


class SandboxTest(unittest.TestCase):
    """Base: fresh temp repo + registry + jobs dir, restored on teardown."""

    REGISTRY = {"services": []}

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="launcher-test-")
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(self.repo)

        # Everything a test may monkeypatch is captured here and restored in
        # tearDown, so patches can't leak between test cases.
        self._saved = {
            "REPO_ROOT": server.REPO_ROOT,
            "ALLOWED_ROOTS": server.ALLOWED_ROOTS,
            "REGISTRY_PATH": server.REGISTRY_PATH,
            "JOBS_DIR": server.JOBS_DIR,
            "WEB_DIR": server.WEB_DIR,
            "OVERRIDES_PATH": server.OVERRIDES_PATH,
            "NOTES_PATH": server.NOTES_PATH,
            "USAGE_PATH": server.USAGE_PATH,
            "INSTANCES_DIR": server.INSTANCES_DIR,
            "CGROUP_ROOT": server.CGROUP_ROOT,
            "RESOURCE_TTL": server.RESOURCE_TTL,
            "DOCKER_MAP_TTL": server.DOCKER_MAP_TTL,
            "docker_name_map": server.docker_name_map,
            "probe": server.probe,
            "probe_all": server.probe_all,
            "magicdns_host": server.magicdns_host,
            "services_payload": server.services_payload,
            "_now_iso": server._now_iso,
            "_have_docker_group": server._have_docker_group,
            "_which": server._which,
            "Popen": subprocess.Popen,
        }
        server.REPO_ROOT = os.path.realpath(self.repo)
        server.ALLOWED_ROOTS = [server.REPO_ROOT]
        server.REGISTRY_PATH = os.path.join(self.tmp, "services.json")
        server.JOBS_DIR = os.path.join(self.tmp, "jobs")
        server.WEB_DIR = os.path.join(self.tmp, "web")
        # Never the real ~/services/launcher/overrides.json, notes.json or
        # usage.json.
        server.OVERRIDES_PATH = os.path.join(self.tmp, "state", "overrides.json")
        server.NOTES_PATH = os.path.join(self.tmp, "state", "notes.json")
        server.USAGE_PATH = os.path.join(self.tmp, "state", "usage.json")
        server.INSTANCES_DIR = os.path.join(self.tmp, "state", "instances")
        # Never the real /sys/fs/cgroup either: a tree under the sandbox that
        # a test builds if it cares, and that otherwise simply does not
        # exist, so resources measure nothing rather than this box.
        server.CGROUP_ROOT = os.path.join(self.tmp, "cgroup")
        # The docker map is the only thing in the resources path that shells
        # out, and every payload test renders services with container parts.
        # Default it to "no docker" so an unrelated test can never reach the
        # unstubbed-Popen guard, let alone the daemon; the resource tests
        # restore the real function and stub Popen underneath it.
        server.docker_name_map = lambda: {}

        self.write_registry(self.REGISTRY)
        server._registry_cache["mtime"] = None
        server._registry_cache["data"] = None
        server._probe_cache.clear()
        self.reset_resource_caches()
        server._jobs.clear()
        server._host_cache["value"] = None

    def tearDown(self):
        for k, v in self._saved.items():
            if k == "Popen":
                subprocess.Popen = v
            else:
                setattr(server, k, v)
        server._jobs.clear()
        server._probe_cache.clear()
        server._host_cache["value"] = None
        self.reset_resource_caches()
        shutil.rmtree(self.tmp, ignore_errors=True)
        # _run_steps catches every exception from a step, so the guard's
        # AssertionError dies in the job thread. Surface it here instead. A
        # thread can trip the guard after its own test has finished, so the
        # blame may land on the next test — the argv still names the culprit.
        escaped, ESCAPED_POPEN[:] = list(ESCAPED_POPEN), []
        self.assertEqual(escaped, [], "unstubbed subprocess reached the host")

    def reset_resource_caches(self):
        """No sample, no cached payload and no cached docker map may survive
        into the next test: they are keyed by service name and cgroup path,
        both of which repeat across tests."""
        server._resources_cache.clear()
        server._cpu_samples.clear()
        server._docker_map_cache["at"] = 0.0
        server._docker_map_cache["map"] = {}

    def read_usage_file(self):
        with open(server.USAGE_PATH, encoding="utf-8") as fh:
            return json.load(fh)

    def write_usage_file(self, text):
        os.makedirs(os.path.dirname(server.USAGE_PATH), exist_ok=True)
        with open(server.USAGE_PATH, "w", encoding="utf-8") as fh:
            fh.write(text if isinstance(text, str) else json.dumps(text))

    def stub_docker_ps(self, output="", code=0, raises=None, hangs=None):
        """Stub Popen for the resources path's one `docker ps`.

        Records every argv, exactly like record_popen, so a call that was
        meant to be stubbed and is not still trips the guard rather than
        reaching this box. `raises` fails the spawn itself (no docker at
        all); `hangs` fails the read (a daemon that never answers).
        """
        self.docker_calls = []
        self.docker_procs = []

        def fake(argv, **kwargs):
            self.docker_calls.append(list(argv))
            if raises is not None:
                raise raises
            proc = CapturedProc(output, code, hangs)
            self.docker_procs.append(proc)
            return proc

        subprocess.Popen = fake

    def write_registry(self, doc):
        with open(server.REGISTRY_PATH, "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
        server._registry_cache["mtime"] = None

    def make_env(self, relpath, text):
        """Write a .env inside the sandbox repo; returns its path."""
        path = os.path.join(self.repo, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        return path

    def read_overrides_file(self):
        with open(server.OVERRIDES_PATH, encoding="utf-8") as fh:
            return json.load(fh)

    def read_notes_file(self):
        with open(server.NOTES_PATH, encoding="utf-8") as fh:
            return json.load(fh)

    def write_notes_file(self, text):
        os.makedirs(os.path.dirname(server.NOTES_PATH), exist_ok=True)
        with open(server.NOTES_PATH, "w", encoding="utf-8") as fh:
            fh.write(text if isinstance(text, str) else json.dumps(text))

    def make_script(self, relpath):
        path = os.path.join(self.repo, relpath)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(path, 0o755)
        return path


# ---------------------------------------------------------------- state

class StateDerivationTest(SandboxTest):

    def test_all_four_states(self):
        self.assertEqual(server.derive_state("x/setup.sh", True, True), "active")
        self.assertEqual(server.derive_state("x/setup.sh", True, False), "stopped")
        self.assertEqual(server.derive_state("x/setup.sh", False, False), "available")
        self.assertEqual(server.derive_state(None, False, False), "planned")

    def test_deployed_service_without_setup_is_not_planned(self):
        # ollama has no setup.sh in the repo but does answer on loopback;
        # it must read as live, not unbuilt.
        self.assertEqual(server.derive_state(None, True, True), "active")
        self.assertEqual(server.derive_state(None, True, False), "stopped")

    def test_payload_states_end_to_end(self):
        self.make_script("alpha/setup.sh")
        self.write_registry({"services": [
            {"key": "up", "name": "Up", "tagline": "t", "icon": "camera",
             "url": "https://HOST:1/", "health": "http://127.0.0.1:1/h",
             "marker": None, "setup": "alpha/setup.sh"},
            {"key": "down", "name": "Down", "tagline": "t", "icon": "folder",
             "url": "https://HOST:2/", "health": "http://127.0.0.1:2/h",
             "marker": self.tmp, "setup": "alpha/setup.sh"},
            {"key": "todo", "name": "Todo", "tagline": "t", "icon": "code",
             "url": None, "health": None,
             "marker": os.path.join(self.tmp, "nope"), "setup": "alpha/setup.sh"},
            {"key": "future", "name": "Future", "tagline": "t", "icon": "shield",
             "url": None, "health": None, "marker": None, "setup": None},
        ]})

        server.probe_all = lambda urls: {"http://127.0.0.1:1/h": True,
                                         "http://127.0.0.1:2/h": False}
        server.magicdns_host = lambda: "box.example.ts.net"
        payload = server.services_payload()  # tearDown undoes the patches

        states = {s["key"]: s["state"] for s in payload["services"]}
        self.assertEqual(states, {"up": "active", "down": "stopped",
                                  "todo": "available", "future": "planned"})
        self.assertTrue(payload["services"][0]["active"])
        self.assertTrue(payload["services"][0]["installed"])
        self.assertFalse(payload["services"][2]["installed"])


# ---------------------------------------------------------------- HOST

class HostSubstitutionTest(SandboxTest):

    def test_substitution(self):
        self.assertEqual(
            server.substitute_host("https://HOST:2283/", "box.ts.net"),
            "https://box.ts.net:2283/")
        self.assertEqual(
            server.substitute_host("https://HOST/", "box.ts.net"),
            "https://box.ts.net/")

    def test_null_url_stays_null(self):
        self.assertIsNone(server.substitute_host(None, "box.ts.net"))

    def test_payload_substitutes(self):
        self.write_registry({"services": [
            {"key": "a", "name": "A", "tagline": "t", "icon": "camera",
             "url": "https://HOST:8092/", "health": None,
             "marker": None, "setup": None},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        payload = server.services_payload()
        self.assertEqual(payload["host"], "box.ts.net")
        self.assertEqual(payload["services"][0]["url"], "https://box.ts.net:8092/")

    def test_hostname_fallback_when_tailscale_missing(self):
        def boom(*a, **k):
            raise OSError("no tailscale")
        real = subprocess.run
        subprocess.run = boom
        try:
            server._host_cache["value"] = None
            self.assertTrue(server.magicdns_host())  # some non-empty hostname
        finally:
            subprocess.run = real


# ---------------------------------------------------------------- allowlist

class ScriptResolutionTest(SandboxTest):

    def test_inside_repo_resolves(self):
        path = self.make_script("services/beszel/setup.sh")
        got = server.resolve_script({"setup": "services/beszel/setup.sh"})
        self.assertEqual(got, os.path.realpath(path))

    def test_traversal_outside_roots_is_refused(self):
        outside = os.path.join(self.tmp, "evil", "setup.sh")
        os.makedirs(os.path.dirname(outside))
        with open(outside, "w") as fh:
            fh.write("#!/bin/sh\n")
        with self.assertRaises(server.DeployError) as ctx:
            server.resolve_script({"setup": "../evil/setup.sh"})
        self.assertEqual(ctx.exception.status, 403)

    def test_absolute_path_outside_roots_is_refused(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.resolve_script({"setup": "/bin/sh"})
        self.assertEqual(ctx.exception.status, 403)

    def test_sibling_prefix_is_not_treated_as_inside(self):
        # /repo-evil must not pass a /repo prefix check.
        sibling = self.repo + "-evil"
        os.makedirs(sibling)
        target = os.path.join(sibling, "setup.sh")
        with open(target, "w") as fh:
            fh.write("#!/bin/sh\n")
        with self.assertRaises(server.DeployError) as ctx:
            server.resolve_script({"setup": target})
        self.assertEqual(ctx.exception.status, 403)

    def test_extra_allowed_root_permits_outside_repo(self):
        # manimkc's setup lives at ~/dev/manimkc/server/setup.sh, outside the
        # repo but inside an explicitly allowed root.
        other = os.path.join(self.tmp, "dev")
        script = os.path.join(other, "manimkc", "server", "setup.sh")
        os.makedirs(os.path.dirname(script))
        with open(script, "w") as fh:
            fh.write("#!/bin/sh\n")
        server.ALLOWED_ROOTS = [server.REPO_ROOT, os.path.realpath(other)]
        self.assertEqual(server.resolve_script({"setup": script}),
                         os.path.realpath(script))

    def test_planned_service_cannot_deploy(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.resolve_script({"setup": None})
        self.assertEqual(ctx.exception.status, 400)

    def test_missing_script_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.resolve_script({"setup": "ghost/setup.sh"})
        self.assertEqual(ctx.exception.status, 404)


# ---------------------------------------------------------------- deploy

class DeployTest(SandboxTest):

    def setUp(self):
        super().setUp()
        for key in ("alpha", "bravo", "charlie"):
            self.make_script("%s/setup.sh" % key)
        self.write_registry({"services": [
            {"key": k, "name": k, "tagline": "t", "icon": "code", "url": None,
             "health": None, "marker": None, "setup": "%s/setup.sh" % k}
            for k in ("alpha", "bravo", "charlie")
        ]})
        self.spawned = []

        def fake_popen(argv, **kwargs):
            self.spawned.append((argv, kwargs))
            return FakeProc(argv, **kwargs)

        subprocess.Popen = fake_popen

    def test_unknown_key_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.start_deploy("nope")
        self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(self.spawned, [])

    def test_shell_metacharacter_key_never_reaches_popen(self):
        for evil in ("alpha; rm -rf ~", "../../etc/passwd", "$(id)", "a|b"):
            with self.assertRaises(server.DeployError) as ctx:
                server.start_deploy(evil)
            self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(self.spawned, [])

    def test_popen_uses_argument_list_and_no_shell(self):
        server.start_deploy("alpha")
        argv, kwargs = self.spawned[0]
        self.assertIsInstance(argv, list)
        self.assertFalse(kwargs.get("shell", False))
        self.assertEqual(kwargs["cwd"], os.path.join(self.repo, "alpha"))
        # Every element traces back to the registry-derived script path or a
        # constant; nothing came from the request beyond the looked-up key.
        script = os.path.realpath(os.path.join(self.repo, "alpha", "setup.sh"))
        self.assertIn(script, " ".join(argv))

    def test_build_command_direct_when_group_present(self):
        script = os.path.join(self.repo, "alpha", "setup.sh")
        real = server._have_docker_group
        server._have_docker_group = lambda: True
        try:
            self.assertEqual(server.build_command(script), [script])
        finally:
            server._have_docker_group = real

    def test_build_command_wraps_in_sg_when_group_missing(self):
        script = os.path.join(self.repo, "alpha", "setup.sh")
        real_group, real_which = server._have_docker_group, server._which
        server._have_docker_group = lambda: False
        server._which = lambda n: "/usr/bin/sg" if n == "sg" else None
        try:
            argv = server.build_command(script)
        finally:
            server._have_docker_group, server._which = real_group, real_which
        self.assertEqual(argv[:3], ["/usr/bin/sg", "docker", "-c"])
        self.assertEqual(len(argv), 4)
        self.assertIn("setup.sh", argv[3])

    def test_build_command_falls_back_when_sg_absent(self):
        script = os.path.join(self.repo, "alpha", "setup.sh")
        real_group, real_which = server._have_docker_group, server._which
        server._have_docker_group = lambda: False
        server._which = lambda n: None
        try:
            self.assertEqual(server.build_command(script), [script])
        finally:
            server._have_docker_group, server._which = real_group, real_which

    def test_second_deploy_for_same_key_is_409(self):
        server.start_deploy("alpha")
        with self.assertRaises(server.DeployError) as ctx:
            server.start_deploy("alpha")
        self.assertEqual(ctx.exception.status, 409)

    def test_global_cap_is_429(self):
        server.start_deploy("alpha")
        server.start_deploy("bravo")
        with self.assertRaises(server.DeployError) as ctx:
            server.start_deploy("charlie")
        self.assertEqual(ctx.exception.status, 429)

    def test_finished_job_frees_the_slot(self):
        jid = server.start_deploy("alpha")
        with server._jobs_lock:
            server._jobs[jid]["status"] = "done"
            server._jobs[jid]["exit_code"] = 0
        server.start_deploy("alpha")  # must not raise
        self.assertEqual(len(self.spawned), 2)

    def test_job_payload_shape(self):
        jid = server.start_deploy("alpha")
        payload = server.job_payload(jid)
        self.assertEqual(sorted(payload),
                         ["action", "exit_code", "key", "log", "refused", "status"])
        self.assertEqual(payload["action"], "deploy")
        self.assertEqual(payload["key"], "alpha")
        self.assertEqual(payload["status"], "running")
        self.assertIsNone(server.job_payload("does-not-exist"))


# ---------------------------------------------------------------- job field

class ServiceJobFieldTest(SandboxTest):
    """`job` on each service: what lets a reopened tile reattach to a deploy."""

    # The identity fields, in payload order. `description` joined them so the
    # grid's hover tooltip does not have to fetch each service individually;
    # `author` joined them so the 'c-wenlong' tab can filter on it.
    EIGHT = ["key", "name", "tagline", "group", "description", "author",
             "icon", "url", "state", "installed", "active"]

    def setUp(self):
        super().setUp()
        for key in ("alpha", "bravo"):
            self.make_script("%s/setup.sh" % key)
        self.write_registry({"services": [
            {"key": k, "name": k.title(), "tagline": "t", "icon": "code",
             "url": "https://HOST:1/", "health": None, "marker": None,
             "setup": "%s/setup.sh" % k}
            for k in ("alpha", "bravo")
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)

    def tiles(self):
        return {s["key"]: s for s in server.services_payload()["services"]}

    def finish(self, job_id, status="done", ago=0.0):
        """Mark a job finished, optionally backdated by `ago` seconds."""
        with server._jobs_lock:
            job = server._jobs[job_id]
            job["status"] = status
            job["exit_code"] = 0 if status == "done" else 1
            job["finished"] = time.time() - ago

    # ---- idle

    def test_job_is_null_when_no_deploy_has_run(self):
        for tile in self.tiles().values():
            self.assertIsNone(tile["job"])

    def test_job_is_null_for_keys_without_a_job(self):
        server.start_deploy("alpha")
        tiles = self.tiles()
        self.assertIsNotNone(tiles["alpha"]["job"])
        self.assertIsNone(tiles["bravo"]["job"])

    # ---- running

    def test_running_job_is_reported_with_id_status_and_action_only(self):
        jid = server.start_deploy("alpha")
        job = self.tiles()["alpha"]["job"]
        self.assertEqual(job, {"id": jid, "status": "running",
                               "action": "deploy"})
        self.assertEqual(sorted(job), ["action", "id", "status"])

    def test_reported_id_is_fetchable_from_api_jobs(self):
        # The whole point: the UI can take this id straight to api/jobs/{id}.
        server.start_deploy("alpha")
        jid = self.tiles()["alpha"]["job"]["id"]
        self.assertEqual(server.job_payload(jid)["key"], "alpha")

    def test_running_outranks_an_earlier_finished_job_for_the_same_key(self):
        first = server.start_deploy("alpha")
        self.finish(first, "failed")
        second = server.start_deploy("alpha")
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": second, "status": "running",
                          "action": "deploy"})

    # ---- finished (policy: linger, then disappear)

    def test_recently_finished_job_is_still_reported(self):
        jid = server.start_deploy("alpha")
        self.finish(jid, "done")
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": jid, "status": "done", "action": "deploy"})

    def test_recently_failed_job_is_still_reported(self):
        jid = server.start_deploy("alpha")
        self.finish(jid, "failed")
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": jid, "status": "failed", "action": "deploy"})

    def test_finished_job_stops_being_reported_after_the_linger_window(self):
        jid = server.start_deploy("alpha")
        self.finish(jid, "done", ago=server.JOB_LINGER + 1)
        self.assertIsNone(self.tiles()["alpha"]["job"])
        # Still fetchable directly, though: only the tile hint expired.
        self.assertIsNotNone(server.job_payload(jid))

    def test_most_recent_finished_job_wins(self):
        old = server.start_deploy("alpha")
        self.finish(old, "failed", ago=60)
        new = server.start_deploy("alpha")
        self.finish(new, "done", ago=1)
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": new, "status": "done", "action": "deploy"})

    def test_running_job_never_expires_however_old(self):
        jid = server.start_deploy("alpha")
        with server._jobs_lock:
            server._jobs[jid]["started"] = time.time() - 10 * server.JOB_RETENTION
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": jid, "status": "running", "action": "deploy"})

    # ---- the other eight fields are untouched

    def test_other_fields_are_identical_with_and_without_a_job(self):
        before = {k: {f: v[f] for f in self.EIGHT}
                  for k, v in self.tiles().items()}
        jid = server.start_deploy("alpha")
        during = {k: {f: v[f] for f in self.EIGHT}
                  for k, v in self.tiles().items()}
        self.assertEqual(before, during)
        self.finish(jid, "failed")
        after = {k: {f: v[f] for f in self.EIGHT}
                 for k, v in self.tiles().items()}
        self.assertEqual(before, after)

    def test_no_field_beyond_the_contract_was_added(self):
        # The whole list contract in one assertion: the original eight, then
        # job and control, then the three v3 keys, then the v5 receipt.
        # Anything else appearing here is a key the frontend was never told
        # about.
        server.start_deploy("alpha")
        for tile in self.tiles().values():
            self.assertEqual(list(tile), self.EIGHT + [
                "job", "control", "usage", "deployed_at", "resources", "receipt",
                "removable"])

    # ---- restart

    def test_restart_reports_null_not_a_stale_job(self):
        jid = server.start_deploy("alpha")
        self.assertIsNotNone(self.tiles()["alpha"]["job"])
        # A fresh process has an empty in-memory registry; the log file it
        # wrote is still on disk, and must not resurrect the job.
        self.assertTrue(os.path.isfile(
            os.path.join(server.JOBS_DIR, "%s.log" % jid)))
        server._jobs.clear()
        self.assertIsNone(self.tiles()["alpha"]["job"])
        self.assertIsNone(server.job_payload(jid))

    def test_job_lookup_touches_no_files(self):
        """api/services is polled every 30s by every tab; the job lookup must
        stay in memory. Any open()/scandir() here would be a regression."""
        import builtins
        server.start_deploy("alpha")
        real_open, real_scandir, real_listdir = (
            builtins.open, os.scandir, os.listdir)
        touched = []

        def trap(name):
            def fn(*a, **k):
                touched.append((name, a[0] if a else None))
                raise AssertionError("filesystem access in jobs_by_key")
            return fn

        builtins.open, os.scandir, os.listdir = (
            trap("open"), trap("scandir"), trap("listdir"))
        try:
            index = server.jobs_by_key()
        finally:
            builtins.open, os.scandir, os.listdir = (
                real_open, real_scandir, real_listdir)
        self.assertEqual(touched, [])
        self.assertEqual(index["alpha"]["status"], "running")

    # ---- the registry stays bounded

    def test_old_finished_jobs_are_pruned_from_the_registry(self):
        jid = server.start_deploy("alpha")
        self.finish(jid, "done", ago=server.JOB_RETENTION + 1)
        server.jobs_by_key()
        self.assertNotIn(jid, server._jobs)
        self.assertIsNone(server.job_payload(jid))

    def test_history_is_capped(self):
        for i in range(server.MAX_JOB_HISTORY + 10):
            jid = server.start_deploy("alpha")
            self.finish(jid, "done", ago=i + 1)
        server.jobs_by_key()
        self.assertEqual(len(server._jobs), server.MAX_JOB_HISTORY)

    def test_capping_never_evicts_a_running_job(self):
        running = server.start_deploy("alpha")
        for i in range(server.MAX_JOB_HISTORY + 10):
            jid = server.start_deploy("bravo")
            self.finish(jid, "done", ago=i + 1)
        server.jobs_by_key()
        self.assertIn(running, server._jobs)
        self.assertEqual(server._jobs[running]["status"], "running")


# ---------------------------------------------------------------- routing

class NormalizeTest(unittest.TestCase):

    def test_leading_slash_optional(self):
        self.assertEqual(server.normalize("/api/services"), "api/services")
        self.assertEqual(server.normalize("api/services"), "api/services")

    def test_query_and_fragment_stripped(self):
        self.assertEqual(server.normalize("/api/services?x=1"), "api/services")

    def test_mount_prefix_tolerated(self):
        self.assertEqual(server.normalize("/home/api/services"), "api/services")
        self.assertEqual(server.normalize("/home/healthz"), "healthz")

    def test_root(self):
        self.assertEqual(server.normalize("/"), "")


class HttpTest(SandboxTest):
    """Drives the real handler over a loopback socket on an ephemeral port."""

    def setUp(self):
        super().setUp()
        import threading
        self.make_script("alpha/setup.sh")
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "code",
             "author": "c-wenlong",
             "url": "https://HOST:1/", "health": None, "marker": None,
             "setup": "alpha/setup.sh"},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def get(self, path, method="GET", body=None):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body,
                     headers={"Content-Type": "application/json"} if body else {})
        resp = conn.getresponse()
        data = resp.read().decode()
        status = resp.status
        conn.close()
        return status, data

    def test_healthz(self):
        status, body = self.get("/healthz")
        self.assertEqual(status, 200)
        self.assertEqual(body.strip(), "ok")
        self.assertEqual(self.get("healthz")[0], 200)

    def test_services_shape(self):
        status, body = self.get("/api/services")
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertEqual(doc["host"], "box.ts.net")
        svc = doc["services"][0]
        self.assertEqual(sorted(svc), ["active", "author", "control",
                                       "deployed_at", "description", "group",
                                       "icon", "installed", "job", "key",
                                       "name", "receipt", "removable", "resources",
                                       "state", "tagline", "url", "usage"])
        self.assertEqual(svc["url"], "https://box.ts.net:1/")
        self.assertEqual(svc["author"], "c-wenlong")
        self.assertIsNone(svc["job"])

    def test_services_field_order_is_stable(self):
        # The frontend reads these positionally in places. `description` sits
        # next to the other identity fields (the grid tooltip needs it here,
        # not only on the detail page); `job` and `control` stay appended last.
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(list(doc["services"][0]),
                         ["key", "name", "tagline", "group", "description",
                          "author", "icon", "url", "state", "installed",
                          "active", "job", "control", "usage", "deployed_at",
                          "resources", "receipt", "removable"])

    def test_groups_empty_when_the_registry_has_none(self):
        # An older services.json without a catalog still paints a flat grid.
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(doc["groups"], [])
        self.assertIsNone(doc["services"][0]["group"])

    def test_groups_catalog_and_service_id_round_trip(self):
        self.write_registry({
            "groups": [
                {"id": "daily", "label": "Daily"},
                {"id": "ai", "label": "  AI & automation  "},
                {"id": "", "label": "skip"},
                {"id": "daily", "label": "duplicate"},
                "not-a-dict",
            ],
            "services": [
                {"key": "alpha", "name": "Alpha", "tagline": "t",
                 "group": "daily", "icon": "code", "url": "https://HOST:1/",
                 "health": None, "marker": None, "setup": "alpha/setup.sh"},
            ],
        })
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(doc["groups"], [
            {"id": "daily", "label": "Daily"},
            {"id": "ai", "label": "AI & automation"},
        ])
        self.assertEqual(doc["services"][0]["group"], "daily")
        self.assertEqual(server.service_detail("alpha")["group"], "daily")

    def test_services_list_carries_the_effective_description(self):
        # Without this the hover tooltip has to fetch every service one by
        # one just to show a bubble. An override must win here too, exactly
        # as it does for `name`.
        doc = json.loads(self.get("/api/services")[1])
        tile = {s["key"]: s for s in doc["services"]}["alpha"]
        self.assertEqual(tile["description"],
                         server.service_detail("alpha")["description"])

    def test_running_job_appears_on_its_tile_over_http(self):
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        jid = server.start_deploy("alpha")
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(doc["services"][0]["job"],
                         {"id": jid, "status": "running", "action": "deploy"})

    def test_unknown_path_is_json_404(self):
        status, body = self.get("/api/nope")
        self.assertEqual(status, 404)
        self.assertIn("error", json.loads(body))

    def test_web_missing_gives_503_not_a_crash(self):
        status, body = self.get("/")
        self.assertEqual(status, 503)
        self.assertIn("static/", body)
        # and the API still works right after
        self.assertEqual(self.get("/healthz")[0], 200)

    def test_static_is_served_when_web_exists(self):
        os.makedirs(server.WEB_DIR)
        with open(os.path.join(server.WEB_DIR, "index.html"), "w") as fh:
            fh.write("<h1>hi</h1>")
        with open(os.path.join(server.WEB_DIR, "app.css"), "w") as fh:
            fh.write("body{}")
        self.assertEqual(self.get("/")[1], "<h1>hi</h1>")
        self.assertEqual(self.get("/app.css")[1], "body{}")

    def test_static_traversal_is_404(self):
        os.makedirs(server.WEB_DIR)
        with open(os.path.join(server.WEB_DIR, "index.html"), "w") as fh:
            fh.write("ok")
        secret = os.path.join(self.tmp, "secret.txt")
        with open(secret, "w") as fh:
            fh.write("nope")
        status, _ = self.get("/../secret.txt")
        self.assertEqual(status, 404)

    def test_malformed_json_body_is_400(self):
        status, body = self.get("/api/services/alpha/deploy", "POST", b"{not json")
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(body))

    def test_deploy_unknown_key_is_404_over_http(self):
        status, body = self.get("/api/services/ghost/deploy", "POST")
        self.assertEqual(status, 404)
        self.assertIn("error", json.loads(body))

    def test_no_traceback_leaks(self):
        real = server.services_payload
        server.services_payload = lambda: (_ for _ in ()).throw(RuntimeError("boom"))
        try:
            status, body = self.get("/api/services")
        finally:
            server.services_payload = real
        self.assertEqual(status, 500)
        self.assertEqual(json.loads(body), {"error": "internal error"})
        self.assertNotIn("Traceback", body)


# ---------------------------------------------------------------- probes

class ProbeCacheTest(SandboxTest):

    def test_probe_results_are_cached(self):
        calls = []
        real = server.probe
        server.probe = lambda u: (calls.append(u), True)[1]
        try:
            server.probe_all(["http://127.0.0.1:9/x"])
            server.probe_all(["http://127.0.0.1:9/x"])
        finally:
            server.probe = real
        self.assertEqual(len(calls), 1)

    def test_registry_file_parses_and_is_self_consistent(self):
        """The real services.json must load and satisfy the schema."""
        real_path = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "services.json")
        with open(real_path, encoding="utf-8") as fh:
            doc = json.load(fh)
        keys = set()
        for svc in doc["services"]:
            for field in ("key", "name", "tagline", "icon", "url", "health",
                          "marker", "setup", "env", "description"):
                self.assertIn(field, svc, "%s missing %s" % (svc.get("key"), field))
            self.assertNotIn(svc["key"], keys, "duplicate key")
            keys.add(svc["key"])
            if svc["health"]:
                self.assertTrue(svc["health"].startswith("http://127.0.0.1:"),
                                "health probes must be loopback")
            # Every service says what it is, in this box's terms.
            self.assertIsInstance(svc["description"], str)
            self.assertGreater(len(svc["description"]), 40,
                               "%s needs a real description" % svc["key"])
            self.assertLessEqual(len(svc["description"]), server.MAX_DESCRIPTION)
            self.assertLessEqual(len(svc["name"]), server.MAX_NAME)
            # env is a path or nothing; never a value, never a dict.
            self.assertTrue(svc["env"] is None or isinstance(svc["env"], str))
            if svc["env"]:
                self.assertTrue(svc["env"].endswith(".env"), svc["key"])
            # A planned service has nothing deployed to configure.
            if svc["setup"] is None and svc["key"] != "ollama":
                self.assertIsNone(svc["env"], "%s is planned" % svc["key"])


# ---------------------------------------------------------------- env parsing

class EnvParsingTest(unittest.TestCase):
    """parse_env against what the .env files on this box actually contain."""

    def test_plain_pairs_in_file_order(self):
        parsed = server.parse_env("A=1\nB=2\nC=3\n")
        self.assertEqual(list(parsed), ["A", "B", "C"])
        self.assertEqual(parsed["B"], "2")

    def test_blank_lines_and_comments_are_skipped(self):
        parsed = server.parse_env(
            "# a comment\n\n   \nA=1\n   # indented comment\nB=2\n")
        self.assertEqual(parsed, {"A": "1", "B": "2"})

    def test_only_the_first_equals_splits(self):
        # Real: base64 padding, DSNs, and generated passwords contain '='.
        parsed = server.parse_env("JWT_PRIVATE_KEY=abc==\nURL=http://x/?a=b&c=d\n")
        self.assertEqual(parsed["JWT_PRIVATE_KEY"], "abc==")
        self.assertEqual(parsed["URL"], "http://x/?a=b&c=d")

    def test_matching_quotes_are_stripped(self):
        parsed = server.parse_env("A=\"quoted\"\nB='single'\n")
        self.assertEqual(parsed["A"], "quoted")
        self.assertEqual(parsed["B"], "single")

    def test_mismatched_or_inner_quotes_are_left_alone(self):
        parsed = server.parse_env("A=\"half\nB=say \"hi\" now\nC='\n")
        self.assertEqual(parsed["A"], "\"half")
        self.assertEqual(parsed["B"], "say \"hi\" now")
        self.assertEqual(parsed["C"], "'")

    def test_export_prefix_is_accepted(self):
        parsed = server.parse_env("export A=1\nexport   B=2\nexported=3\n")
        self.assertEqual(parsed, {"A": "1", "B": "2", "exported": "3"})

    def test_malformed_lines_are_ignored_not_fatal(self):
        parsed = server.parse_env(
            "GOOD=1\nnot a pair\n=novalue\n9BAD=x\nA-B=x\nALSO_GOOD=2\n")
        self.assertEqual(parsed, {"GOOD": "1", "ALSO_GOOD": "2"})

    def test_hash_inside_a_value_is_kept(self):
        # Generated passwords here contain '#'; eating it would hand back a
        # wrong secret, which is worse than showing a stray comment.
        self.assertEqual(server.parse_env("P=aa#bb\n")["P"], "aa#bb")

    def test_whitespace_around_name_and_value(self):
        self.assertEqual(server.parse_env("  A = 1 \n"), {"A": "1"})

    def test_repeated_name_takes_the_last_value_at_its_first_position(self):
        parsed = server.parse_env("A=1\nB=2\nA=3\n")
        self.assertEqual(parsed["A"], "3")
        self.assertEqual(list(parsed), ["A", "B"])

    def test_empty_value_is_kept(self):
        self.assertEqual(server.parse_env("EMPTY=\n"), {"EMPTY": ""})

    def test_empty_file(self):
        self.assertEqual(server.parse_env(""), {})


class SecretDetectionTest(unittest.TestCase):
    """By name only, case-insensitive substring. Real names from this box."""

    SECRET = [
        "DB_PASSWORD", "IMMICH_ADMIN_PASSWORD", "BESZEL_ADMIN_PASSWORD",
        "KUMA_ADMIN_PASSWORD", "OWNER_PASSWORD", "REDIS_PASSWORD",
        "SEAFILE_MYSQL_DB_PASSWORD", "INIT_SEAFILE_MYSQL_ROOT_PASSWORD",
        "INIT_SEAFILE_ADMIN_PASSWORD", "JWT_PRIVATE_KEY",
        "N8N_ENCRYPTION_KEY", "ELEVENLABS_API_KEY", "SARVAM_API_KEY",
        "SEAFILE_TOKEN", "AWS_SECRET_ACCESS_KEY", "CREDENTIALS_FILE",
        "passphrase", "db_password",
    ]
    VISIBLE = [
        "IMMICH_VERSION", "LOCAL_PORT", "UPLOAD_LOCATION", "TZ", "TIME_ZONE",
        "DB_USERNAME", "DB_DATABASE_NAME", "IMMICH_ADMIN_EMAIL",
        "COMPOSE_PROFILES", "ML_MEM_LIMIT", "REPO_URL", "BRANCH",
        "POLL_SECONDS", "NODE_BIN", "PUBLIC_URL", "NTFY_TOPIC",
        "KUMA_ADMIN_USER", "OLLAMA_BASE_URL", "SEAFILE_IMAGE",
        "NARRATION_BACKEND", "SEAFILE_USER", "CONTROL_TOPIC",
    ]

    def test_secret_names(self):
        for name in self.SECRET:
            self.assertTrue(server.is_secret(name), "%s must be secret" % name)

    def test_visible_names(self):
        for name in self.VISIBLE:
            self.assertFalse(server.is_secret(name),
                             "%s must stay visible" % name)

    def test_case_insensitive(self):
        for name in ("api_key", "Api_Key", "myToken", "Private"):
            self.assertTrue(server.is_secret(name))

    def test_over_masking_is_the_accepted_failure_mode(self):
        # KEY as a substring catches KEYCLOAK_URL and MONKEY_NAME too. That is
        # deliberate: a nuisance, not a leak.
        self.assertTrue(server.is_secret("MONKEY_NAME"))

    def test_empty_and_none(self):
        self.assertFalse(server.is_secret(""))
        self.assertFalse(server.is_secret(None))


# ---------------------------------------------------------------- detail

SECRET_VALUE = "hunter2-Sup3r-S3cret#value"
VISIBLE_VALUE = "v1.140.0"


class DetailTest(SandboxTest):

    def setUp(self):
        super().setUp()
        self.make_script("alpha/setup.sh")
        self.make_env("alpha/.env", "\n".join([
            "# generated by setup.sh",
            "IMMICH_VERSION=%s" % VISIBLE_VALUE,
            "LOCAL_PORT=2283",
            "DB_PASSWORD=%s" % SECRET_VALUE,
            "export JWT_PRIVATE_KEY=\"abc==\"",
            "",
        ]))
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "Photos",
             "icon": "camera", "url": "https://HOST:2283/",
             "health": "http://127.0.0.1:2283/api/server/ping",
             "marker": None, "setup": "alpha/setup.sh", "env": "alpha/.env",
             "description": "Shipped description."},
            {"key": "bare", "name": "Bare", "tagline": "t", "icon": "cpu",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "No env at all."},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {u: False for u in urls}

    def test_unknown_key_is_none(self):
        self.assertIsNone(server.service_detail("ghost"))

    def test_shape(self):
        detail = server.service_detail("alpha")
        self.assertEqual(sorted(detail), [
            "active", "control", "deployed_at", "description", "env", "group",
            "icon", "installed", "job", "key", "meta", "name", "receipt",
            "removable", "resources", "state", "tagline", "url", "usage"])
        self.assertEqual(detail["key"], "alpha")
        self.assertEqual(detail["name"], "Alpha")
        self.assertEqual(detail["description"], "Shipped description.")
        self.assertEqual(detail["url"], "https://box.ts.net:2283/")
        self.assertEqual(detail["state"], "available")

    def test_includes_the_nine_list_fields_verbatim(self):
        detail = server.service_detail("alpha")
        tile = {s["key"]: s for s in server.services_payload()["services"]}["alpha"]
        for field in ("key", "name", "tagline", "group", "icon", "url",
                      "state", "installed", "active", "job", "control",
                      "usage", "deployed_at", "resources"):
            self.assertEqual(detail[field], tile[field], field)

    def test_meta(self):
        meta = server.service_detail("alpha")["meta"]
        self.assertEqual(sorted(meta), ["edited", "env", "health", "local_port",
                                        "marker", "setup"])
        self.assertEqual(meta["setup"], "alpha/setup.sh")
        self.assertEqual(meta["env"], "alpha/.env")
        self.assertEqual(meta["health"], "http://127.0.0.1:2283/api/server/ping")
        self.assertEqual(meta["local_port"], 2283)
        self.assertEqual(meta["edited"], [])

    def test_meta_local_port_is_null_without_a_health_probe(self):
        self.assertIsNone(server.service_detail("bare")["meta"]["local_port"])

    def test_env_lists_names_and_flags_in_file_order(self):
        env = server.service_detail("alpha")["env"]
        self.assertEqual(env["path"], "alpha/.env")
        self.assertTrue(env["exists"])
        self.assertEqual(env["vars"], [
            {"name": "IMMICH_VERSION", "secret": False},
            {"name": "LOCAL_PORT", "secret": False},
            {"name": "DB_PASSWORD", "secret": True},
            {"name": "JWT_PRIVATE_KEY", "secret": True},
        ])

    def test_no_env_value_appears_anywhere_in_the_payload(self):
        """The rule the whole design rests on: names and flags, no values."""
        blob = json.dumps(server.service_detail("alpha"))
        self.assertNotIn(SECRET_VALUE, blob)
        self.assertNotIn("hunter2", blob)
        self.assertNotIn("abc==", blob)          # the JWT key's value
        self.assertNotIn(VISIBLE_VALUE, blob)    # not even non-secret values
        self.assertNotIn("2283\"", blob)         # nor LOCAL_PORT's value
        self.assertNotIn("value", blob)          # no masked-value field at all
        self.assertIn("DB_PASSWORD", blob)       # the name is there

    def test_no_env_value_appears_in_the_list_payload(self):
        blob = json.dumps(server.services_payload())
        self.assertNotIn(SECRET_VALUE, blob)
        self.assertNotIn(VISIBLE_VALUE, blob)

    def test_service_without_env_reports_an_empty_env_block(self):
        self.assertEqual(server.service_detail("bare")["env"],
                         {"path": None, "exists": False, "vars": []})

    def test_missing_env_file_degrades_to_exists_false(self):
        os.unlink(os.path.join(self.repo, "alpha", ".env"))
        env = server.service_detail("alpha")["env"]
        self.assertEqual(env, {"path": "alpha/.env", "exists": False,
                               "vars": []})

    def test_env_path_outside_the_allowed_roots_leaks_nothing(self):
        outside = os.path.join(self.tmp, "outside", ".env")
        os.makedirs(os.path.dirname(outside))
        with open(outside, "w") as fh:
            fh.write("DB_PASSWORD=%s\n" % SECRET_VALUE)
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": outside, "description": ""},
        ]})
        detail = server.service_detail("alpha")
        self.assertFalse(detail["env"]["exists"])
        self.assertEqual(detail["env"]["vars"], [])
        self.assertNotIn(SECRET_VALUE, json.dumps(detail))


# ---------------------------------------------------------------- overrides

class OverridesTest(SandboxTest):

    def setUp(self):
        super().setUp()
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Shipped description."},
            {"key": "bravo", "name": "Bravo", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Bravo default."},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {}

    # ---- persistence and layering

    def test_patch_persists_and_is_layered_over_the_registry(self):
        detail = server.patch_service("alpha", {"name": "Photos",
                                                "description": "Mine now."})
        self.assertEqual(detail["name"], "Photos")
        self.assertEqual(detail["description"], "Mine now.")
        self.assertEqual(self.read_overrides_file()["services"]["alpha"],
                         {"name": "Photos", "description": "Mine now."})
        # ...and a fresh read still sees it
        self.assertEqual(server.service_detail("alpha")["name"], "Photos")
        self.assertEqual(server.service_detail("alpha")["meta"]["edited"],
                         ["description", "name"])

    def test_override_shows_on_the_grid_too(self):
        server.patch_service("alpha", {"name": "Photos"})
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertEqual(tiles["alpha"]["name"], "Photos")
        self.assertEqual(tiles["bravo"]["name"], "Bravo")

    def test_one_field_at_a_time_leaves_the_other_alone(self):
        server.patch_service("alpha", {"name": "Photos"})
        detail = server.patch_service("alpha", {"description": "Just this."})
        self.assertEqual(detail["name"], "Photos")
        self.assertEqual(detail["description"], "Just this.")

    def test_other_services_are_untouched(self):
        server.patch_service("alpha", {"name": "Photos"})
        self.assertEqual(server.service_detail("bravo")["name"], "Bravo")
        self.assertNotIn("bravo", self.read_overrides_file()["services"])

    def test_unknown_key_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.patch_service("ghost", {"name": "x"})
        self.assertEqual(ctx.exception.status, 404)
        self.assertFalse(os.path.exists(server.OVERRIDES_PATH))

    def test_empty_body_is_a_no_op_that_writes_nothing(self):
        for body in ({}, None):
            detail = server.patch_service("alpha", body)
            self.assertEqual(detail["name"], "Alpha")
            self.assertEqual(detail["meta"]["edited"], [])
            self.assertFalse(os.path.exists(server.OVERRIDES_PATH))

    def test_unknown_fields_are_ignored(self):
        server.patch_service("alpha", {"key": "evil", "url": "http://evil",
                                       "setup": "/bin/sh"})
        self.assertFalse(os.path.exists(server.OVERRIDES_PATH))
        self.assertEqual(server.service_detail("alpha")["key"], "alpha")

    # ---- clearing

    def test_empty_string_clears_the_override(self):
        server.patch_service("alpha", {"name": "Photos"})
        detail = server.patch_service("alpha", {"name": ""})
        self.assertEqual(detail["name"], "Alpha")
        self.assertEqual(self.read_overrides_file()["services"], {})

    def test_whitespace_only_clears_the_override(self):
        server.patch_service("alpha", {"description": "Mine."})
        detail = server.patch_service("alpha", {"description": "   \n\t "})
        self.assertEqual(detail["description"], "Shipped description.")
        self.assertEqual(self.read_overrides_file()["services"], {})

    def test_setting_the_shipped_default_stores_nothing(self):
        server.patch_service("alpha", {"name": "Alpha",
                                       "description": "Shipped description."})
        self.assertEqual(self.read_overrides_file()["services"], {})
        self.assertEqual(server.service_detail("alpha")["meta"]["edited"], [])

    def test_deleting_the_file_restores_defaults(self):
        server.patch_service("alpha", {"name": "Photos"})
        os.unlink(server.OVERRIDES_PATH)
        self.assertEqual(server.service_detail("alpha")["name"], "Alpha")

    # ---- validation

    def test_non_string_is_400(self):
        for bad in (5, None, True, ["x"], {"a": 1}):
            with self.assertRaises(server.DeployError) as ctx:
                server.patch_service("alpha", {"name": bad})
            self.assertEqual(ctx.exception.status, 400)
        with self.assertRaises(server.DeployError) as ctx:
            server.patch_service("alpha", {"description": 5})
        self.assertEqual(ctx.exception.status, 400)
        self.assertFalse(os.path.exists(server.OVERRIDES_PATH))

    def test_non_object_body_is_400(self):
        for bad in ("string", 5, ["name"]):
            with self.assertRaises(server.DeployError) as ctx:
                server.patch_service("alpha", bad)
            self.assertEqual(ctx.exception.status, 400)

    def test_name_length_limit(self):
        ok = "n" * server.MAX_NAME
        self.assertEqual(server.patch_service("alpha", {"name": ok})["name"], ok)
        with self.assertRaises(server.DeployError) as ctx:
            server.patch_service("alpha", {"name": "n" * (server.MAX_NAME + 1)})
        self.assertEqual(ctx.exception.status, 400)
        # the too-long value did not land
        self.assertEqual(server.service_detail("alpha")["name"], ok)

    def test_description_length_limit(self):
        ok = "d" * server.MAX_DESCRIPTION
        self.assertEqual(
            server.patch_service("alpha", {"description": ok})["description"], ok)
        with self.assertRaises(server.DeployError) as ctx:
            server.patch_service(
                "alpha", {"description": "d" * (server.MAX_DESCRIPTION + 1)})
        self.assertEqual(ctx.exception.status, 400)

    def test_control_characters_are_stripped(self):
        detail = server.patch_service("alpha", {"name": "Ph\x00ot\x07os\x1b"})
        self.assertEqual(detail["name"], "Photos")

    def test_name_is_single_line(self):
        detail = server.patch_service("alpha", {"name": " Photos\nand\tvideo "})
        self.assertEqual(detail["name"], "Photos and video")

    def test_description_keeps_newlines_but_not_carriage_returns(self):
        detail = server.patch_service("alpha",
                                      {"description": "one\r\ntwo\rthree\n"})
        self.assertEqual(detail["description"], "one\ntwo\nthree")

    # ---- durability

    def test_services_json_is_never_modified(self):
        before = open(server.REGISTRY_PATH, "rb").read()
        server.patch_service("alpha", {"name": "Photos",
                                       "description": "Mine now."})
        server.patch_service("alpha", {"name": ""})
        self.assertEqual(open(server.REGISTRY_PATH, "rb").read(), before)

    def test_the_shipped_registry_file_is_never_modified(self):
        """The real, git-tracked services.json — belt and braces."""
        real = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "services.json")
        before = open(real, "rb").read()
        server.patch_service("alpha", {"name": "Photos"})
        self.assertEqual(open(real, "rb").read(), before)

    def test_write_is_atomic_and_leaves_no_temp_files(self):
        server.patch_service("alpha", {"name": "Photos"})
        state = os.path.dirname(server.OVERRIDES_PATH)
        self.assertEqual(os.listdir(state), ["overrides.json"])

    def test_a_failed_replace_leaves_the_previous_file_intact(self):
        server.patch_service("alpha", {"name": "Photos"})
        before = open(server.OVERRIDES_PATH, "rb").read()
        real = os.replace
        os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("disk full"))
        try:
            with self.assertRaises(OSError):
                server.patch_service("alpha", {"name": "Something Else"})
        finally:
            os.replace = real
        self.assertEqual(open(server.OVERRIDES_PATH, "rb").read(), before)
        self.assertEqual(os.listdir(os.path.dirname(server.OVERRIDES_PATH)),
                         ["overrides.json"])
        self.assertEqual(server.service_detail("alpha")["name"], "Photos")

    def test_concurrent_patches_do_not_lose_each_other(self):
        import threading
        keys = ["svc%d" % i for i in range(12)]
        self.write_registry({"services": [
            {"key": k, "name": k, "tagline": "t", "icon": "code", "url": None,
             "health": None, "marker": None, "setup": None, "env": None,
             "description": "d"} for k in keys
        ]})
        start = threading.Barrier(len(keys))
        errors = []

        def patch(key):
            try:
                start.wait(timeout=5)
                server.patch_service(key, {"name": "renamed-%s" % key})
            except Exception as exc:      # noqa: BLE001 - surfaced below
                errors.append(exc)

        threads = [threading.Thread(target=patch, args=(k,)) for k in keys]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        self.assertEqual(errors, [])
        stored = self.read_overrides_file()["services"]
        self.assertEqual(sorted(stored), sorted(keys))
        for key in keys:
            self.assertEqual(stored[key]["name"], "renamed-%s" % key)

    # ---- degrading

    def test_missing_overrides_file_is_not_an_error(self):
        self.assertEqual(server.load_overrides(), {})
        self.assertEqual(server.service_detail("alpha")["name"], "Alpha")

    def test_corrupt_overrides_file_degrades_to_defaults(self):
        os.makedirs(os.path.dirname(server.OVERRIDES_PATH), exist_ok=True)
        for junk in ("{ not json", "[]", "null", '{"services": 5}',
                     '{"services": {"alpha": "Photos"}}',
                     '{"services": {"alpha": {"name": 5}}}'):
            with open(server.OVERRIDES_PATH, "w") as fh:
                fh.write(junk)
            self.assertEqual(server.service_detail("alpha")["name"], "Alpha",
                             "junk: %s" % junk)
            self.assertEqual(server.service_detail("alpha")["description"],
                             "Shipped description.")

    def test_partially_valid_overrides_keep_the_valid_half(self):
        os.makedirs(os.path.dirname(server.OVERRIDES_PATH), exist_ok=True)
        with open(server.OVERRIDES_PATH, "w") as fh:
            json.dump({"services": {"alpha": {"name": "Photos",
                                              "description": 5},
                                    "bravo": "junk"}}, fh)
        detail = server.service_detail("alpha")
        self.assertEqual(detail["name"], "Photos")
        self.assertEqual(detail["description"], "Shipped description.")
        self.assertEqual(server.service_detail("bravo")["name"], "Bravo")

    @unittest.skipIf(os.geteuid() == 0, "root can read anything")
    def test_unreadable_overrides_file_degrades_to_defaults(self):
        os.makedirs(os.path.dirname(server.OVERRIDES_PATH), exist_ok=True)
        with open(server.OVERRIDES_PATH, "w") as fh:
            json.dump({"services": {"alpha": {"name": "Photos"}}}, fh)
        os.chmod(server.OVERRIDES_PATH, 0o000)
        try:
            self.assertEqual(server.load_overrides(), {})
            self.assertEqual(server.service_detail("alpha")["name"], "Alpha")
        finally:
            os.chmod(server.OVERRIDES_PATH, 0o600)

    def test_a_patch_after_a_corrupt_file_starts_clean(self):
        os.makedirs(os.path.dirname(server.OVERRIDES_PATH), exist_ok=True)
        with open(server.OVERRIDES_PATH, "w") as fh:
            fh.write("{ not json")
        server.patch_service("alpha", {"name": "Photos"})
        self.assertEqual(self.read_overrides_file()["services"],
                         {"alpha": {"name": "Photos"}})


# ---------------------------------------------------------------- reveal

class RevealTest(SandboxTest):

    def setUp(self):
        super().setUp()
        self.make_env("alpha/.env", "\n".join([
            "IMMICH_VERSION=%s" % VISIBLE_VALUE,
            "DB_PASSWORD=%s" % SECRET_VALUE,
            "QUOTED=\"quoted value\"",
            "",
        ]))
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": "alpha/.env", "description": ""},
            {"key": "bare", "name": "Bare", "tagline": "t", "icon": "cpu",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": ""},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {}

    def test_reveals_the_real_value(self):
        self.assertEqual(server.reveal_env_var("alpha", "DB_PASSWORD"),
                         {"name": "DB_PASSWORD", "value": SECRET_VALUE})

    def test_reveals_non_secrets_too(self):
        self.assertEqual(
            server.reveal_env_var("alpha", "IMMICH_VERSION")["value"],
            VISIBLE_VALUE)

    def test_quotes_are_stripped_from_the_revealed_value(self):
        self.assertEqual(server.reveal_env_var("alpha", "QUOTED")["value"],
                         "quoted value")

    def test_double_quoted_escapes_are_unescaped(self):
        # Exactly the two escapes a shell, Compose and this parser agree on.
        self.make_env("alpha/.env",
                      'A="say \\"hi\\" and \\\\ back"\n'
                      'B="kept \\$ and \\` and \\n as-is"\n'
                      "C='no \\\\ unescape \\\" in single'\n")
        self.assertEqual(server.reveal_env_var("alpha", "A")["value"],
                         'say "hi" and \\ back')
        self.assertEqual(server.reveal_env_var("alpha", "B")["value"],
                         "kept \\$ and \\` and \\n as-is")
        self.assertEqual(server.reveal_env_var("alpha", "C")["value"],
                         'no \\\\ unescape \\" in single')

    def test_unknown_variable_is_404_and_is_not_echoed_back(self):
        # Near-misses included: the lookup is exact, and the refusal never
        # repeats what was asked for.
        for var in ("NOPE", "db_password", "", "../../etc/passwd",
                    "DB_PASSWORD "):
            with self.assertRaises(server.DeployError) as ctx:
                server.reveal_env_var("alpha", var)
            self.assertEqual(ctx.exception.status, 404, var)
            self.assertEqual(ctx.exception.message, "unknown variable")

    def test_unknown_service_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("ghost", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 404)

    def test_service_without_an_env_file_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("bare", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 404)

    def test_missing_env_file_is_404(self):
        os.unlink(os.path.join(self.repo, "alpha", ".env"))
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("alpha", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 404)

    # ---- the allowed-roots gate, same one the deploy endpoint uses

    def _registry_with_env(self, env_path):
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": env_path, "description": ""},
        ]})

    def test_env_path_outside_the_allowed_roots_is_refused(self):
        outside = os.path.join(self.tmp, "outside", ".env")
        os.makedirs(os.path.dirname(outside))
        with open(outside, "w") as fh:
            fh.write("DB_PASSWORD=%s\n" % SECRET_VALUE)
        self._registry_with_env(outside)
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("alpha", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 403)

    def test_traversal_in_the_registry_env_path_is_refused(self):
        outside = os.path.join(self.tmp, "outside", ".env")
        os.makedirs(os.path.dirname(outside))
        with open(outside, "w") as fh:
            fh.write("DB_PASSWORD=%s\n" % SECRET_VALUE)
        self._registry_with_env("../outside/.env")
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("alpha", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 403)

    def test_absolute_system_path_is_refused(self):
        self._registry_with_env("/etc/passwd")
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("alpha", "root")
        self.assertEqual(ctx.exception.status, 403)

    def test_a_symlink_out_of_the_repo_is_refused(self):
        outside = os.path.join(self.tmp, "outside", ".env")
        os.makedirs(os.path.dirname(outside))
        with open(outside, "w") as fh:
            fh.write("DB_PASSWORD=%s\n" % SECRET_VALUE)
        link = os.path.join(self.repo, "linked.env")
        os.symlink(outside, link)
        self._registry_with_env("linked.env")
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("alpha", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 403)

    def test_sibling_prefix_root_is_refused(self):
        sibling = self.repo + "-evil"
        os.makedirs(sibling)
        target = os.path.join(sibling, ".env")
        with open(target, "w") as fh:
            fh.write("DB_PASSWORD=%s\n" % SECRET_VALUE)
        self._registry_with_env(target)
        with self.assertRaises(server.DeployError) as ctx:
            server.reveal_env_var("alpha", "DB_PASSWORD")
        self.assertEqual(ctx.exception.status, 403)

    def test_an_extra_allowed_root_is_honoured(self):
        # manimkc's .env lives at ~/dev/manimkc/.env, outside the repo but
        # inside an explicitly allowed root.
        other = os.path.join(self.tmp, "dev")
        path = os.path.join(other, "manimkc", ".env")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as fh:
            fh.write("ELEVENLABS_API_KEY=%s\n" % SECRET_VALUE)
        server.ALLOWED_ROOTS = [server.REPO_ROOT, os.path.realpath(other)]
        self._registry_with_env(path)
        self.assertEqual(
            server.reveal_env_var("alpha", "ELEVENLABS_API_KEY")["value"],
            SECRET_VALUE)

    def test_no_value_is_logged(self):
        logged = []
        real = server.log
        server.log = lambda msg: logged.append(msg)
        try:
            server.reveal_env_var("alpha", "DB_PASSWORD")
        finally:
            server.log = real
        for line in logged:
            self.assertNotIn(SECRET_VALUE, line)


# ---------------------------------------------------------------- env edit

ORIGINAL_ENV = "\n".join([
    "# Generated by setup.sh. Gitignored; mode 600.",
    "IMMICH_VERSION=%s" % VISIBLE_VALUE,
    "",
    "  export DB_PASSWORD=%s" % SECRET_VALUE,
    "QUOTED=\"quoted value\"",
    "EMPTY=",
    "DUP=first",
    "DUP=second",
    "not an assignment",
    "# DB_PASSWORD=commented-out",
    "",
])


class EnvEditTest(SandboxTest):
    """PATCH api/services/{key}/env/{var}: rewrite one line, nothing else."""

    def setUp(self):
        super().setUp()
        self.path = self.make_env("alpha/.env", ORIGINAL_ENV)
        os.chmod(self.path, 0o600)
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": "alpha/.env", "description": ""},
            {"key": "bare", "name": "Bare", "tagline": "t", "icon": "cpu",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": ""},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {}

    def env_text(self):
        with open(self.path, encoding="utf-8") as fh:
            return fh.read()

    def set(self, var, value, key="alpha"):
        return server.update_env_var(key, var, {"value": value})

    # ---- happy path

    def test_sets_the_value_and_reveal_reads_it_back(self):
        res = self.set("DB_PASSWORD", "new-secret-123")
        self.assertEqual(res, {"name": "DB_PASSWORD", "secret": True,
                               "value": "new-secret-123"})
        self.assertEqual(server.reveal_env_var("alpha", "DB_PASSWORD")["value"],
                         "new-secret-123")

    def test_every_other_byte_survives(self):
        self.set("DB_PASSWORD", "new-secret-123")
        expected = ORIGINAL_ENV.replace(
            "  export DB_PASSWORD=%s" % SECRET_VALUE,
            "  export DB_PASSWORD=new-secret-123")
        self.assertEqual(self.env_text(), expected)

    def test_indent_and_export_prefix_are_kept(self):
        self.set("DB_PASSWORD", "x")
        self.assertIn("\n  export DB_PASSWORD=x\n", self.env_text())

    def test_missing_final_newline_and_crlf_are_kept(self):
        with open(self.path, "w", encoding="utf-8", newline="") as fh:
            fh.write("A=1\r\nB=2\r\nC=3")
        self.set("B", "two")
        with open(self.path, encoding="utf-8", newline="") as fh:
            self.assertEqual(fh.read(), "A=1\r\nB=two\r\nC=3")
        self.set("C", "three")
        with open(self.path, encoding="utf-8", newline="") as fh:
            self.assertEqual(fh.read(), "A=1\r\nB=two\r\nC=three")

    def test_every_duplicate_assignment_is_rewritten(self):
        # A stale duplicate would otherwise read one way to the shell (last
        # wins) and could be edited into reading another way here.
        self.set("DUP", "both")
        self.assertEqual(self.env_text().count("DUP=both\n"), 2)
        self.assertNotIn("first", self.env_text())
        self.assertNotIn("second", self.env_text())

    def test_the_commented_out_copy_is_not_touched(self):
        self.set("DB_PASSWORD", "x")
        self.assertIn("# DB_PASSWORD=commented-out\n", self.env_text())

    def test_mode_is_preserved(self):
        os.chmod(self.path, 0o640)
        self.set("DB_PASSWORD", "x")
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o640)
        os.chmod(self.path, 0o600)
        self.set("DB_PASSWORD", "y")
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_no_temp_file_is_left_behind(self):
        self.set("DB_PASSWORD", "x")
        self.assertEqual(sorted(os.listdir(os.path.dirname(self.path))), [".env"])

    def test_empty_value_is_allowed_and_bare(self):
        self.set("DB_PASSWORD", "")
        self.assertIn("\n  export DB_PASSWORD=\n", self.env_text())
        self.assertEqual(server.reveal_env_var("alpha", "DB_PASSWORD")["value"], "")

    def test_non_secret_and_unknown_flags(self):
        self.assertFalse(self.set("IMMICH_VERSION", "v2")["secret"])

    # ---- quoting: what lands in the file, and that it reads back

    def test_bare_when_safe(self):
        self.set("DB_PASSWORD", "Ab9+/=._:@%,-")
        self.assertIn("DB_PASSWORD=Ab9+/=._:@%,-\n", self.env_text())

    def test_single_quoted_for_anything_the_shell_or_compose_would_touch(self):
        for value in ("has space", "a#b", "a$b", "~/x", "a;b|c&d", "`t`",
                      "back\\slash", "\"dq\"", "a*b?[c]", "  pad  ", "\t"):
            self.set("DB_PASSWORD", value)
            self.assertIn("DB_PASSWORD='%s'\n" % value, self.env_text(), value)
            self.assertEqual(
                server.reveal_env_var("alpha", "DB_PASSWORD")["value"], value)

    def test_double_quoted_only_for_apostrophes(self):
        self.set("DB_PASSWORD", "it's \"q\" \\s")
        self.assertIn('DB_PASSWORD="it\'s \\"q\\" \\\\s"\n', self.env_text())
        self.assertEqual(server.reveal_env_var("alpha", "DB_PASSWORD")["value"],
                         "it's \"q\" \\s")

    def test_apostrophe_with_dollar_or_backtick_is_refused_unwritten(self):
        for value in ("it's $1", "it's `x`"):
            with self.assertRaises(server.DeployError) as ctx:
                self.set("DB_PASSWORD", value)
            self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(self.env_text(), ORIGINAL_ENV)

    def test_quoting_round_trips_through_the_shell(self):
        # The contract that matters: what a setup.sh `set -a; . .env` sees is
        # what was saved. This deliberately runs a real /bin/sh — via
        # os.system, which the subprocess.Popen guard does not (and should
        # not) cover: the guard exists to catch SERVER code reaching the box,
        # and this is the test itself sourcing a file inside its own sandbox.
        import shlex
        import shutil
        if not shutil.which("sh"):
            self.skipTest("no sh on this machine")
        values = ["plain", "with space", "a#b$c`d\\e", "it's \"q\" \\s", "",
                  "~/tilde;|&<>*?[]!", "  padded  "]
        out_path = os.path.join(self.tmp, "seen")
        for value in values:
            self.set("DB_PASSWORD", value)
            rc = os.system(
                "sh -c 'set -a; . \"$1\"; set +a; printf %%s \"$DB_PASSWORD\" > \"$2\"' "
                "sh %s %s" % (shlex.quote(self.path), shlex.quote(out_path)))
            self.assertEqual(rc, 0, value)
            with open(out_path, encoding="utf-8") as fh:
                self.assertEqual(fh.read(), value)

    # ---- validation

    VALID = {"value": "x"}

    def assert_refused(self, status, var="DB_PASSWORD", body=VALID, key="alpha"):
        with self.assertRaises(server.DeployError) as ctx:
            server.update_env_var(key, var, body)
        self.assertEqual(ctx.exception.status, status)
        self.assertEqual(self.env_text(), ORIGINAL_ENV)   # nothing written
        return ctx.exception

    def test_unknown_variable_is_404_and_is_not_echoed_back(self):
        for var in ("NOPE", "db_password", "", "../../etc/passwd",
                    "DB_PASSWORD ", "not"):
            exc = self.assert_refused(404, var=var)
            self.assertEqual(exc.message, "unknown variable")

    def test_editing_cannot_add_a_variable(self):
        self.assert_refused(404, var="BRAND_NEW")
        self.assertNotIn("BRAND_NEW", self.env_text())

    def test_unknown_service_is_404(self):
        self.assert_refused(404, key="ghost")

    def test_service_without_an_env_file_is_404(self):
        self.assert_refused(404, key="bare")

    def test_missing_env_file_is_404(self):
        os.unlink(self.path)
        with self.assertRaises(server.DeployError) as ctx:
            self.set("DB_PASSWORD", "x")
        self.assertEqual(ctx.exception.status, 404)
        self.assertFalse(os.path.exists(self.path))   # not created either

    def test_bad_bodies_are_400(self):
        for body in (None, [], "x", {}, {"value": None}, {"value": 1},
                     {"value": ["x"]}, {"val": "x"}):
            self.assert_refused(400, body=body)

    def test_multi_line_values_are_400(self):
        for value in ("a\nb", "a\rb", "a\r\nb", "a\0b", "\n"):
            self.assert_refused(400, body={"value": value})

    def test_too_long_is_400_and_the_limit_is_400_exact(self):
        self.assert_refused(400, body={"value": "x" * (server.MAX_ENV_VALUE + 1)})
        self.set("DB_PASSWORD", "x" * server.MAX_ENV_VALUE)

    def test_env_path_outside_the_allowed_roots_is_refused(self):
        outside = os.path.join(self.tmp, "outside", ".env")
        os.makedirs(os.path.dirname(outside))
        with open(outside, "w") as fh:
            fh.write("DB_PASSWORD=%s\n" % SECRET_VALUE)
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": outside, "description": ""},
        ]})
        with self.assertRaises(server.DeployError) as ctx:
            self.set("DB_PASSWORD", "x")
        self.assertEqual(ctx.exception.status, 403)
        with open(outside) as fh:
            self.assertIn(SECRET_VALUE, fh.read())

    def test_no_value_is_logged(self):
        logged = []
        real = server.log
        server.log = lambda msg: logged.append(msg)
        try:
            self.set("DB_PASSWORD", "brand-new-secret-value")
        finally:
            server.log = real
        self.assertTrue(logged)
        for line in logged:
            self.assertNotIn("brand-new-secret-value", line)
            self.assertNotIn(SECRET_VALUE, line)


class EnvEditHttpTest(SandboxTest):

    def setUp(self):
        super().setUp()
        import threading
        self.path = self.make_env("alpha/.env", ORIGINAL_ENV)
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": "alpha/.env", "description": ""},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {}
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def call(self, method, path, body=None):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body,
                     headers={"Content-Type": "application/json"} if body else {})
        resp = conn.getresponse()
        data = resp.read().decode()
        conn.close()
        return resp.status, data

    def test_patch_writes_and_the_detail_still_carries_no_value(self):
        status, body = self.call("PATCH", "/api/services/alpha/env/DB_PASSWORD",
                                 json.dumps({"value": "over-http"}))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["name"], "DB_PASSWORD")
        with open(self.path) as fh:
            self.assertIn("DB_PASSWORD=over-http\n", fh.read())
        status, body = self.call("GET", "/api/services/alpha")
        self.assertNotIn("over-http", body)
        status, body = self.call("POST", "/api/services/alpha/env/DB_PASSWORD/reveal")
        self.assertEqual(json.loads(body)["value"], "over-http")

    def test_works_under_the_path_mount_too(self):
        # `tailscale serve --set-path=/home` strips the prefix; both spellings
        # must route the same way.
        status, _ = self.call("PATCH", "api/services/alpha/env/QUOTED",
                              json.dumps({"value": "v"}))
        self.assertEqual(status, 200)

    def test_errors_map_to_statuses(self):
        cases = [
            ("/api/services/alpha/env/NOPE", {"value": "x"}, 404),
            ("/api/services/ghost/env/DB_PASSWORD", {"value": "x"}, 404),
            ("/api/services/alpha/env/DB_PASSWORD", {"value": 5}, 400),
            ("/api/services/alpha/env/DB_PASSWORD", {"value": "a\nb"}, 400),
            ("/api/services/alpha/env/DB_PASSWORD", {"value": "it's $"}, 400),
        ]
        for path, body, expected in cases:
            status, _ = self.call("PATCH", path, json.dumps(body))
            self.assertEqual(status, expected, path)
        status, _ = self.call("PATCH", "/api/services/alpha/env/DB_PASSWORD",
                              "{not json")
        self.assertEqual(status, 400)

    def test_post_and_get_on_the_edit_path_are_not_edits(self):
        # POST .../env/{var} is not reveal (that has /reveal) and not an edit.
        status, _ = self.call("POST", "/api/services/alpha/env/DB_PASSWORD",
                              json.dumps({"value": "x"}))
        self.assertEqual(status, 404)
        status, _ = self.call("GET", "/api/services/alpha/env/DB_PASSWORD")
        self.assertEqual(status, 404)
        with open(self.path) as fh:
            self.assertEqual(fh.read(), ORIGINAL_ENV)


# ---------------------------------------------------------------- notes

ISO_RE = r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"


class NotesTestBase(SandboxTest):
    """Two services, so cross-service isolation is testable everywhere."""

    def setUp(self):
        super().setUp()
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Shipped description."},
            {"key": "bravo", "name": "Bravo", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Bravo default."},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {}

    def freeze_clock(self, start=0):
        """Deterministic, strictly increasing timestamps.

        Two notes written in the same millisecond are otherwise possible, and
        a test that asserts on ordering or on updated_at moving must not be
        able to lose that race on a fast machine.
        """
        tick = [start]

        def fake():
            tick[0] += 1
            return "2026-09-10T00:00:%02d.%03dZ" % (tick[0] // 1000,
                                                    tick[0] % 1000)

        server._now_iso = fake
        return tick

    def seed(self, key, count, prefix="n"):
        """Write `count` well-formed notes straight to disk, newest first."""
        notes = [{"id": "%s%03d" % (prefix, i),
                  "title": "seeded %d" % i,
                  "body": "seeded body %d" % i,
                  "created_at": "2026-01-01T00:00:%02d.000Z" % (59 - i),
                  "updated_at": "2026-01-01T00:00:%02d.000Z" % (59 - i)}
                 for i in range(count)]
        self.write_notes_file({"services": {key: notes}})
        return notes


class NotesCrudTest(NotesTestBase):

    def test_no_notes_to_begin_with(self):
        self.assertEqual(server.notes_payload("alpha"), {"notes": []})
        self.assertFalse(os.path.exists(server.NOTES_PATH))

    def test_full_round_trip(self):
        note = server.create_note("alpha", {"title": "ML is off",
                                            "body": "Because RAM."})
        self.assertEqual(sorted(note), ["body", "created_at", "id", "title",
                                        "updated_at"])
        self.assertEqual(note["title"], "ML is off")
        self.assertEqual(note["body"], "Because RAM.")
        self.assertEqual(server.notes_payload("alpha")["notes"], [note])

        updated = server.update_note("alpha", note["id"], {"body": "New body."})
        self.assertEqual(updated["id"], note["id"])
        self.assertEqual(updated["body"], "New body.")
        self.assertEqual(updated["title"], "ML is off")
        self.assertEqual(server.notes_payload("alpha")["notes"], [updated])

        self.assertIsNone(server.delete_note("alpha", note["id"]))
        self.assertEqual(server.notes_payload("alpha"), {"notes": []})

    def test_the_note_survives_a_fresh_read_from_disk(self):
        note = server.create_note("alpha", {"body": "Written down."})
        self.assertEqual(server.load_notes()["alpha"], [note])
        stored = self.read_notes_file()["services"]["alpha"]
        self.assertEqual(stored, [note])

    def test_ids_are_opaque_unguessable_and_unique(self):
        ids = {server.create_note("alpha", {"body": "n%d" % i})["id"]
               for i in range(20)}
        self.assertEqual(len(ids), 20)
        for note_id in ids:
            self.assertEqual(len(note_id), 32)
            self.assertRegex(note_id, r"^[0-9a-f]{32}$")

    def test_id_is_stable_across_an_update(self):
        note = server.create_note("alpha", {"body": "one"})
        self.assertEqual(
            server.update_note("alpha", note["id"], {"body": "two"})["id"],
            note["id"])

    # ---- ordering

    def test_notes_are_newest_first(self):
        self.freeze_clock()
        first = server.create_note("alpha", {"body": "first"})
        second = server.create_note("alpha", {"body": "second"})
        third = server.create_note("alpha", {"body": "third"})
        self.assertEqual([n["id"] for n in server.notes_payload("alpha")["notes"]],
                         [third["id"], second["id"], first["id"]])

    def test_ordering_is_by_creation_not_by_edit(self):
        self.freeze_clock()
        first = server.create_note("alpha", {"body": "first"})
        second = server.create_note("alpha", {"body": "second"})
        server.update_note("alpha", first["id"], {"body": "edited"})
        self.assertEqual([n["id"] for n in server.notes_payload("alpha")["notes"]],
                         [second["id"], first["id"]])

    def test_ordering_survives_a_reread_and_ignores_file_order(self):
        self.freeze_clock()
        old = server.create_note("alpha", {"body": "old"})
        new = server.create_note("alpha", {"body": "new"})
        # Hand-edited file, oldest first: the server still serves newest first.
        self.write_notes_file({"services": {"alpha": [old, new]}})
        self.assertEqual([n["id"] for n in server.notes_payload("alpha")["notes"]],
                         [new["id"], old["id"]])

    def test_same_millisecond_notes_keep_insertion_order(self):
        server._now_iso = lambda: "2026-09-10T00:00:00.000Z"
        first = server.create_note("alpha", {"body": "first"})
        second = server.create_note("alpha", {"body": "second"})
        self.assertEqual([n["id"] for n in server.notes_payload("alpha")["notes"]],
                         [second["id"], first["id"]])

    # ---- timestamps

    def test_timestamps_are_iso_utc_with_a_z(self):
        note = server.create_note("alpha", {"body": "x"})
        self.assertRegex(note["created_at"], ISO_RE)
        self.assertRegex(note["updated_at"], ISO_RE)
        self.assertEqual(note["created_at"], note["updated_at"])

    def test_updated_at_moves_on_a_real_change(self):
        self.freeze_clock()
        note = server.create_note("alpha", {"body": "one"})
        updated = server.update_note("alpha", note["id"], {"body": "two"})
        self.assertGreater(updated["updated_at"], note["updated_at"])
        self.assertEqual(updated["created_at"], note["created_at"])

    def test_updated_at_does_not_move_on_a_no_op_save(self):
        self.freeze_clock()
        note = server.create_note("alpha", {"title": "T", "body": "one"})
        for body in ({"body": "one"}, {"title": "T"},
                     {"title": "T", "body": "one"}, {}, None):
            same = server.update_note("alpha", note["id"], body)
            self.assertEqual(same, note, body)

    def test_created_at_is_never_rewritten(self):
        self.freeze_clock()
        note = server.create_note("alpha", {"body": "one"})
        for i in range(3):
            note = server.update_note("alpha", note["id"],
                                      {"body": "edit %d" % i})
        self.assertEqual(server.notes_payload("alpha")["notes"][0]["created_at"],
                         "2026-09-10T00:00:00.001Z")


class NotesTitleTest(NotesTestBase):
    """Every note has a title, because the UI collapses it to exactly that."""

    def test_title_is_derived_from_the_body_when_omitted(self):
        note = server.create_note("alpha", {"body": "Rotate the admin pw"})
        self.assertEqual(note["title"], "Rotate the admin pw")
        self.assertEqual(note["body"], "Rotate the admin pw")

    def test_title_is_derived_from_the_first_line_only(self):
        note = server.create_note(
            "alpha", {"body": "Restart order\n\n1. db\n2. server\n"})
        self.assertEqual(note["title"], "Restart order")
        self.assertEqual(note["body"], "Restart order\n\n1. db\n2. server")

    def test_blank_leading_lines_are_skipped_when_deriving(self):
        note = server.create_note("alpha", {"body": "\n\n   \nReal first line"})
        self.assertEqual(note["title"], "Real first line")

    def test_blank_title_is_treated_as_absent(self):
        for title in ("", "   ", "\t \n "):
            note = server.create_note("alpha", {"title": title,
                                                "body": "Derived from here"})
            self.assertEqual(note["title"], "Derived from here")

    def test_a_derived_title_is_truncated_and_marked(self):
        line = "word " * 60          # 300 chars, well over the limit
        note = server.create_note("alpha", {"body": line})
        self.assertLessEqual(len(note["title"]), server.MAX_NOTE_TITLE)
        self.assertTrue(note["title"].endswith("…"))
        self.assertTrue(note["title"].startswith("word word"))
        self.assertFalse(note["title"].endswith(" …"))
        # Truncating the title never truncates the body.
        self.assertEqual(note["body"], line.strip())

    def test_truncation_prefers_a_word_boundary_when_it_is_cheap(self):
        # The hard cut would land 18 characters into the second word; the
        # boundary is close enough to be worth backing up to.
        note = server.create_note("alpha", {"body": "x" * 100 + " " + "y" * 50})
        self.assertEqual(note["title"], "x" * 100 + "…")

    def test_truncation_does_not_back_up_to_a_far_away_boundary(self):
        # Backing up to the space at offset 10 would throw away most of the
        # line, so the cut stays where it is.
        note = server.create_note("alpha", {"body": "x" * 10 + " " + "y" * 200})
        self.assertEqual(len(note["title"]), server.MAX_NOTE_TITLE)
        self.assertTrue(note["title"].startswith("x" * 10 + " y"))
        self.assertTrue(note["title"].endswith("…"))

    def test_truncation_still_happens_with_no_word_boundary(self):
        note = server.create_note("alpha", {"body": "z" * 400})
        self.assertEqual(len(note["title"]), server.MAX_NOTE_TITLE)
        self.assertEqual(note["title"], "z" * (server.MAX_NOTE_TITLE - 1) + "…")

    def test_a_title_exactly_at_the_limit_is_not_truncated(self):
        line = "y" * server.MAX_NOTE_TITLE
        note = server.create_note("alpha", {"body": line})
        self.assertEqual(note["title"], line)

    def test_a_supplied_title_is_never_derived_over(self):
        note = server.create_note("alpha", {"title": "Mine",
                                            "body": "Something else entirely"})
        self.assertEqual(note["title"], "Mine")

    def test_no_note_ever_has_an_empty_title(self):
        bodies = ["short", "multi\nline\nbody", "   padded   ",
                  "\n\nleading blanks", "x" * 400, "tab\tseparated"]
        for body in bodies:
            note = server.create_note("alpha", {"body": body})
            self.assertTrue(note["title"].strip(), body)
        for note in server.notes_payload("alpha")["notes"]:
            self.assertTrue(note["title"].strip())

    def test_a_note_with_nothing_in_it_is_400(self):
        for body in ({"body": ""}, {"body": "   \n\t "},
                     {"title": "  ", "body": ""}):
            with self.assertRaises(server.DeployError) as ctx:
                server.create_note("alpha", body)
            self.assertEqual(ctx.exception.status, 400, body)
        self.assertFalse(os.path.exists(server.NOTES_PATH))

    def test_a_title_only_note_is_allowed(self):
        note = server.create_note("alpha", {"title": "Just a heading",
                                            "body": ""})
        self.assertEqual(note["title"], "Just a heading")
        self.assertEqual(note["body"], "")

    def test_a_derived_title_follows_the_body_when_the_body_is_edited(self):
        note = server.create_note("alpha", {"body": "First version"})
        updated = server.update_note("alpha", note["id"],
                                     {"body": "Second version"})
        self.assertEqual(updated["title"], "Second version")

    def test_a_typed_title_does_not_follow_the_body(self):
        note = server.create_note("alpha", {"title": "Stays put",
                                            "body": "First version"})
        updated = server.update_note("alpha", note["id"],
                                     {"body": "Second version"})
        self.assertEqual(updated["title"], "Stays put")

    def test_blanking_a_title_falls_back_to_the_derived_one(self):
        note = server.create_note("alpha", {"title": "Typed",
                                            "body": "Body line"})
        updated = server.update_note("alpha", note["id"], {"title": ""})
        self.assertEqual(updated["title"], "Body line")

    def test_an_update_that_empties_a_note_is_400(self):
        note = server.create_note("alpha", {"body": "Something"})
        with self.assertRaises(server.DeployError) as ctx:
            server.update_note("alpha", note["id"], {"body": ""})
        self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(server.notes_payload("alpha")["notes"][0], note)

    def test_title_is_collapsed_to_one_line(self):
        note = server.create_note("alpha", {"title": " Two \n lines\there ",
                                            "body": "b"})
        self.assertEqual(note["title"], "Two lines here")


class NotesValidationTest(NotesTestBase):

    def test_body_is_required_on_create(self):
        for body in ({}, {"title": "only a title"}):
            with self.assertRaises(server.DeployError) as ctx:
                server.create_note("alpha", body)
            self.assertEqual(ctx.exception.status, 400, body)

    def test_non_object_body_is_400(self):
        for bad in (None, "string", 5, ["body"]):
            with self.assertRaises(server.DeployError) as ctx:
                server.create_note("alpha", bad)
            self.assertEqual(ctx.exception.status, 400, repr(bad))
        note = server.create_note("alpha", {"body": "ok"})
        for bad in ("string", 5, ["body"]):
            with self.assertRaises(server.DeployError) as ctx:
                server.update_note("alpha", note["id"], bad)
            self.assertEqual(ctx.exception.status, 400, repr(bad))

    def test_non_string_fields_are_400(self):
        for bad in (5, None, True, ["x"], {"a": 1}):
            with self.assertRaises(server.DeployError) as ctx:
                server.create_note("alpha", {"body": bad})
            self.assertEqual(ctx.exception.status, 400, repr(bad))
            with self.assertRaises(server.DeployError) as ctx:
                server.create_note("alpha", {"title": bad, "body": "x"})
            self.assertEqual(ctx.exception.status, 400, repr(bad))
        self.assertFalse(os.path.exists(server.NOTES_PATH))

    def test_title_length_limit(self):
        ok = "t" * server.MAX_NOTE_TITLE
        self.assertEqual(
            server.create_note("alpha", {"title": ok, "body": "b"})["title"], ok)
        with self.assertRaises(server.DeployError) as ctx:
            server.create_note("alpha", {"title": "t" * (server.MAX_NOTE_TITLE + 1),
                                         "body": "b"})
        self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(len(server.notes_payload("alpha")["notes"]), 1)

    def test_body_length_limit(self):
        ok = "b" * server.MAX_NOTE_BODY
        self.assertEqual(
            server.create_note("alpha", {"body": ok})["body"], ok)
        with self.assertRaises(server.DeployError) as ctx:
            server.create_note("alpha", {"body": "b" * (server.MAX_NOTE_BODY + 1)})
        self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(len(server.notes_payload("alpha")["notes"]), 1)

    def test_limits_apply_to_updates_too(self):
        note = server.create_note("alpha", {"body": "short"})
        for patch in ({"title": "t" * (server.MAX_NOTE_TITLE + 1)},
                      {"body": "b" * (server.MAX_NOTE_BODY + 1)}):
            with self.assertRaises(server.DeployError) as ctx:
                server.update_note("alpha", note["id"], patch)
            self.assertEqual(ctx.exception.status, 400)
        self.assertEqual(server.notes_payload("alpha")["notes"], [note])

    def test_per_service_cap_is_409(self):
        self.seed("alpha", server.MAX_NOTES_PER_SERVICE)
        with self.assertRaises(server.DeployError) as ctx:
            server.create_note("alpha", {"body": "one too many"})
        self.assertEqual(ctx.exception.status, 409)
        self.assertEqual(len(server.notes_payload("alpha")["notes"]),
                         server.MAX_NOTES_PER_SERVICE)

    def test_one_below_the_cap_still_accepts_a_note(self):
        self.seed("alpha", server.MAX_NOTES_PER_SERVICE - 1)
        server.create_note("alpha", {"body": "the last one that fits"})
        self.assertEqual(len(server.notes_payload("alpha")["notes"]),
                         server.MAX_NOTES_PER_SERVICE)

    def test_the_cap_is_per_service_not_global(self):
        self.seed("alpha", server.MAX_NOTES_PER_SERVICE)
        note = server.create_note("bravo", {"body": "bravo has room"})
        self.assertEqual(server.notes_payload("bravo")["notes"], [note])

    def test_deleting_makes_room_again(self):
        seeded = self.seed("alpha", server.MAX_NOTES_PER_SERVICE)
        server.delete_note("alpha", seeded[0]["id"])
        server.create_note("alpha", {"body": "fits now"})
        self.assertEqual(len(server.notes_payload("alpha")["notes"]),
                         server.MAX_NOTES_PER_SERVICE)

    def test_updating_at_the_cap_still_works(self):
        seeded = self.seed("alpha", server.MAX_NOTES_PER_SERVICE)
        updated = server.update_note("alpha", seeded[0]["id"],
                                     {"body": "edited at the cap"})
        self.assertEqual(updated["body"], "edited at the cap")

    # ---- control characters

    def test_control_characters_are_stripped_from_the_body(self):
        note = server.create_note(
            "alpha", {"body": "clean\x00er\x07 text\x1b here\x7f"})
        self.assertEqual(note["body"], "cleaner text here")

    def test_newlines_and_tabs_survive_in_the_body(self):
        note = server.create_note(
            "alpha", {"title": "T", "body": "one\ntwo\n\tindented\n\nend"})
        self.assertEqual(note["body"], "one\ntwo\n\tindented\n\nend")

    def test_carriage_returns_become_newlines(self):
        note = server.create_note("alpha",
                                  {"title": "T", "body": "a\r\nb\rc\n"})
        self.assertEqual(note["body"], "a\nb\nc")

    def test_control_characters_are_stripped_from_the_title(self):
        note = server.create_note("alpha", {"title": "Ti\x00tl\x07e",
                                            "body": "b"})
        self.assertEqual(note["title"], "Title")

    def test_a_control_character_only_body_is_400_not_a_blank_note(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.create_note("alpha", {"body": "\x00\x07\x1b"})
        self.assertEqual(ctx.exception.status, 400)

    def test_stripping_happens_before_the_length_check(self):
        # 8000 real characters plus control junk is still within the limit.
        body = ("b" * server.MAX_NOTE_BODY) + "\x00\x07\x1b\x7f"
        self.assertEqual(len(server.create_note("alpha", {"body": body})["body"]),
                         server.MAX_NOTE_BODY)


class NotesIsolationTest(NotesTestBase):
    """A note id from service A must not be reachable under service B."""

    def setUp(self):
        super().setUp()
        self.a = server.create_note("alpha", {"body": "alpha's note"})
        self.b = server.create_note("bravo", {"body": "bravo's note"})

    def test_each_service_sees_only_its_own(self):
        self.assertEqual(server.notes_payload("alpha")["notes"], [self.a])
        self.assertEqual(server.notes_payload("bravo")["notes"], [self.b])

    def test_reading_across_services_is_impossible(self):
        blob = json.dumps(server.notes_payload("bravo"))
        self.assertNotIn("alpha's note", blob)

    def test_updating_another_services_note_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.update_note("bravo", self.a["id"], {"body": "stolen"})
        self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(server.notes_payload("alpha")["notes"], [self.a])

    def test_deleting_another_services_note_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.delete_note("bravo", self.a["id"])
        self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(server.notes_payload("alpha")["notes"], [self.a])

    def test_editing_one_service_leaves_the_other_alone(self):
        server.update_note("alpha", self.a["id"], {"body": "changed"})
        self.assertEqual(server.notes_payload("bravo")["notes"], [self.b])
        server.delete_note("alpha", self.a["id"])
        self.assertEqual(server.notes_payload("bravo")["notes"], [self.b])

    # ---- unknown keys

    def test_unknown_service_is_404_everywhere(self):
        for call in (lambda: server.notes_payload("ghost"),
                     lambda: server.create_note("ghost", {"body": "x"}),
                     lambda: server.update_note("ghost", self.a["id"],
                                                {"body": "x"}),
                     lambda: server.delete_note("ghost", self.a["id"])):
            with self.assertRaises(server.DeployError) as ctx:
                call()
            self.assertEqual(ctx.exception.status, 404)

    def test_unknown_note_id_is_404(self):
        for note_id in ("nope", "", "../alpha", self.a["id"] + "x"):
            with self.assertRaises(server.DeployError) as ctx:
                server.update_note("alpha", note_id, {"body": "x"})
            self.assertEqual(ctx.exception.status, 404, note_id)
            with self.assertRaises(server.DeployError) as ctx:
                server.delete_note("alpha", note_id)
            self.assertEqual(ctx.exception.status, 404, note_id)

    def test_deleting_twice_is_404_the_second_time(self):
        server.delete_note("alpha", self.a["id"])
        with self.assertRaises(server.DeployError) as ctx:
            server.delete_note("alpha", self.a["id"])
        self.assertEqual(ctx.exception.status, 404)

    # ---- keys that left the registry

    def test_notes_for_a_retired_key_are_not_served(self):
        self.write_registry({"services": [
            {"key": "bravo", "name": "Bravo", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Bravo default."},
        ]})
        with self.assertRaises(server.DeployError) as ctx:
            server.notes_payload("alpha")
        self.assertEqual(ctx.exception.status, 404)

    def test_notes_for_a_retired_key_stay_on_disk_through_other_writes(self):
        self.write_registry({"services": [
            {"key": "bravo", "name": "Bravo", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Bravo default."},
        ]})
        server.create_note("bravo", {"body": "still writing over here"})
        server.delete_note("bravo", self.b["id"])
        self.assertEqual(self.read_notes_file()["services"]["alpha"], [self.a])
        # ...and are there again when the key comes back.
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "description": "Shipped description."},
        ]})
        self.assertEqual(server.notes_payload("alpha")["notes"], [self.a])

    def test_a_registry_with_no_services_at_all_does_not_crash(self):
        self.write_registry({"services": []})
        with self.assertRaises(server.DeployError) as ctx:
            server.notes_payload("alpha")
        self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(sorted(server.load_notes()), ["alpha", "bravo"])


class NotesStorageTest(NotesTestBase):
    """The same discipline overrides.json gets, because this is the only copy."""

    def test_notes_live_beside_overrides_and_not_in_services_json(self):
        self.assertEqual(os.path.dirname(server.NOTES_PATH),
                         os.path.dirname(server.OVERRIDES_PATH))
        self.assertEqual(os.path.basename(server.NOTES_PATH), "notes.json")

    def test_the_real_path_is_under_services_launcher(self):
        real = self._saved["NOTES_PATH"]
        self.assertTrue(real.endswith("/services/launcher/notes.json"), real)
        self.assertEqual(os.path.dirname(real),
                         os.path.dirname(self._saved["OVERRIDES_PATH"]))

    def test_services_json_is_never_modified(self):
        before = open(server.REGISTRY_PATH, "rb").read()
        note = server.create_note("alpha", {"body": "one"})
        server.update_note("alpha", note["id"], {"body": "two"})
        server.delete_note("alpha", note["id"])
        self.assertEqual(open(server.REGISTRY_PATH, "rb").read(), before)

    def test_the_shipped_registry_file_is_never_modified(self):
        """The real, git-tracked services.json — belt and braces."""
        real = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "services.json")
        before = open(real, "rb").read()
        note = server.create_note("alpha", {"body": "one"})
        server.update_note("alpha", note["id"], {"body": "two"})
        server.delete_note("alpha", note["id"])
        self.assertEqual(open(real, "rb").read(), before)

    def test_overrides_and_notes_do_not_clobber_each_other(self):
        note = server.create_note("alpha", {"body": "a note"})
        server.patch_service("alpha", {"name": "Renamed"})
        self.assertEqual(server.notes_payload("alpha")["notes"], [note])
        self.assertEqual(server.service_detail("alpha")["name"], "Renamed")
        self.assertNotIn("a note", json.dumps(self.read_overrides_file()))
        self.assertNotIn("Renamed", json.dumps(self.read_notes_file()))

    def test_write_is_atomic_and_leaves_no_temp_files(self):
        server.create_note("alpha", {"body": "one"})
        state = os.path.dirname(server.NOTES_PATH)
        self.assertEqual(os.listdir(state), ["notes.json"])

    def test_a_failed_replace_leaves_the_previous_file_intact(self):
        note = server.create_note("alpha", {"body": "keep me"})
        before = open(server.NOTES_PATH, "rb").read()
        real = os.replace
        os.replace = lambda *a, **k: (_ for _ in ()).throw(OSError("disk full"))
        try:
            with self.assertRaises(OSError):
                server.create_note("alpha", {"body": "lost"})
            with self.assertRaises(OSError):
                server.update_note("alpha", note["id"], {"body": "also lost"})
            with self.assertRaises(OSError):
                server.delete_note("alpha", note["id"])
        finally:
            os.replace = real
        self.assertEqual(open(server.NOTES_PATH, "rb").read(), before)
        self.assertEqual(os.listdir(os.path.dirname(server.NOTES_PATH)),
                         ["notes.json"])
        self.assertEqual(server.notes_payload("alpha")["notes"], [note])

    def test_a_failed_write_leaves_no_temp_file_behind(self):
        real = json.dump
        json.dump = lambda *a, **k: (_ for _ in ()).throw(OSError("disk full"))
        try:
            with self.assertRaises(OSError):
                server.create_note("alpha", {"body": "never lands"})
        finally:
            json.dump = real
        self.assertEqual(os.listdir(os.path.dirname(server.NOTES_PATH)), [])
        self.assertEqual(server.notes_payload("alpha")["notes"], [])

    def test_the_write_is_fsynced(self):
        synced = []
        real = os.fsync
        os.fsync = lambda fd: (synced.append(fd), real(fd))[1]
        try:
            server.create_note("alpha", {"body": "durable"})
        finally:
            os.fsync = real
        self.assertEqual(len(synced), 1)

    def test_concurrent_creates_on_one_service_do_not_lose_each_other(self):
        import threading
        count = 16
        start = threading.Barrier(count)
        errors = []

        def add(i):
            try:
                start.wait(timeout=5)
                server.create_note("alpha", {"body": "note %d" % i})
            except Exception as exc:      # noqa: BLE001 - surfaced below
                errors.append(exc)

        threads = [threading.Thread(target=add, args=(i,)) for i in range(count)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        self.assertEqual(errors, [])
        bodies = {n["body"] for n in server.notes_payload("alpha")["notes"]}
        self.assertEqual(bodies, {"note %d" % i for i in range(count)})

    def test_concurrent_writes_across_services_do_not_lose_each_other(self):
        import threading
        keys = ["svc%d" % i for i in range(12)]
        self.write_registry({"services": [
            {"key": k, "name": k, "tagline": "t", "icon": "code", "url": None,
             "health": None, "marker": None, "setup": None, "env": None,
             "description": "d"} for k in keys
        ]})
        start = threading.Barrier(len(keys))
        errors = []

        def add(key):
            try:
                start.wait(timeout=5)
                server.create_note(key, {"body": "note for %s" % key})
            except Exception as exc:      # noqa: BLE001 - surfaced below
                errors.append(exc)

        threads = [threading.Thread(target=add, args=(k,)) for k in keys]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        self.assertEqual(errors, [])
        stored = self.read_notes_file()["services"]
        self.assertEqual(sorted(stored), sorted(keys))
        for key in keys:
            self.assertEqual(stored[key][0]["body"], "note for %s" % key)

    def test_concurrent_deletes_and_creates_stay_consistent(self):
        import threading
        seeded = self.seed("alpha", 20)
        start = threading.Barrier(20)
        errors = []

        def work(i):
            try:
                start.wait(timeout=5)
                if i % 2:
                    server.delete_note("alpha", seeded[i]["id"])
                else:
                    server.create_note("alpha", {"body": "added %d" % i})
            except Exception as exc:      # noqa: BLE001 - surfaced below
                errors.append(exc)

        threads = [threading.Thread(target=work, args=(i,)) for i in range(20)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=10)
        self.assertEqual(errors, [])
        notes = server.notes_payload("alpha")["notes"]
        ids = {n["id"] for n in notes}
        self.assertEqual(len(notes), 20)              # 20 - 10 deleted + 10 new
        for i in range(1, 20, 2):
            self.assertNotIn(seeded[i]["id"], ids)
        for i in range(0, 20, 2):
            self.assertIn(seeded[i]["id"], ids)

    # ---- degrading

    def test_missing_notes_file_is_not_an_error(self):
        self.assertEqual(server.load_notes(), {})
        self.assertEqual(server.notes_payload("alpha"), {"notes": []})

    def test_corrupt_notes_file_degrades_to_no_notes(self):
        for junk in ("{ not json", "", "[]", "null", "5", '"a string"',
                     '{"services": 5}', '{"services": []}',
                     '{"services": {"alpha": 5}}',
                     '{"services": {"alpha": "not a list"}}',
                     '{"services": {"alpha": [5, null, "x"]}}',
                     '{"services": {"alpha": [{"id": "a"}]}}',
                     '{"services": {"alpha": [{"id": 5, "title": "t",'
                     ' "body": "b", "created_at": "x", "updated_at": "y"}]}}',
                     '{"nope": {"alpha": []}}'):
            self.write_notes_file(junk)
            self.assertEqual(server.notes_payload("alpha"), {"notes": []},
                             "junk: %s" % junk)
            self.assertEqual(server.load_notes().get("alpha", []), [],
                             "junk: %s" % junk)

    def test_a_corrupt_file_does_not_take_the_rest_of_the_api_down(self):
        self.write_notes_file("{ not json")
        self.assertEqual(server.service_detail("alpha")["name"], "Alpha")
        self.assertEqual(len(server.services_payload()["services"]), 2)

    def test_partially_valid_notes_keep_the_valid_ones(self):
        good = {"id": "keep", "title": "T", "body": "B",
                "created_at": "2026-01-01T00:00:00.000Z",
                "updated_at": "2026-01-01T00:00:00.000Z"}
        self.write_notes_file({"services": {
            "alpha": [good, {"id": "half"}, "junk", None, 5],
            "bravo": "not a list",
        }})
        self.assertEqual(server.notes_payload("alpha")["notes"], [good])
        self.assertEqual(server.notes_payload("bravo")["notes"], [])

    def test_extra_fields_on_a_stored_note_are_dropped_not_served(self):
        self.write_notes_file({"services": {"alpha": [
            {"id": "a", "title": "T", "body": "B",
             "created_at": "2026-01-01T00:00:00.000Z",
             "updated_at": "2026-01-01T00:00:00.000Z",
             "secret": "should not be served", "pinned": True},
        ]}})
        note = server.notes_payload("alpha")["notes"][0]
        self.assertEqual(sorted(note), ["body", "created_at", "id", "title",
                                        "updated_at"])
        self.assertNotIn("should not be served", json.dumps(note))

    @unittest.skipIf(os.geteuid() == 0, "root can read anything")
    def test_unreadable_notes_file_degrades_to_no_notes(self):
        server.create_note("alpha", {"body": "hidden"})
        os.chmod(server.NOTES_PATH, 0o000)
        try:
            self.assertEqual(server.load_notes(), {})
            self.assertEqual(server.notes_payload("alpha"), {"notes": []})
        finally:
            os.chmod(server.NOTES_PATH, 0o600)
        self.assertEqual(server.notes_payload("alpha")["notes"][0]["body"],
                         "hidden")

    def test_a_write_after_a_corrupt_file_starts_clean(self):
        self.write_notes_file("{ not json")
        note = server.create_note("alpha", {"body": "fresh start"})
        self.assertEqual(self.read_notes_file()["services"], {"alpha": [note]})

    def test_deleting_the_file_removes_the_notes_and_nothing_else(self):
        server.create_note("alpha", {"body": "gone soon"})
        server.patch_service("alpha", {"name": "Renamed"})
        os.unlink(server.NOTES_PATH)
        self.assertEqual(server.notes_payload("alpha"), {"notes": []})
        self.assertEqual(server.service_detail("alpha")["name"], "Renamed")

    def test_a_corrupt_file_is_reported_to_stderr(self):
        logged = []
        real = server.log
        server.log = lambda msg: logged.append(msg)
        try:
            self.write_notes_file("{ not json")
            server.load_notes()
        finally:
            server.log = real
        self.assertTrue(any("notes" in line for line in logged), logged)


class NotesHttpTest(NotesTestBase):
    """The four endpoints over a real socket, including the 204."""

    def setUp(self):
        super().setUp()
        import threading
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def call(self, path, method="GET", body=None):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        payload = json.dumps(body).encode() if body is not None else None
        conn.request(method, path, body=payload,
                     headers={"Content-Type": "application/json"}
                     if payload else {})
        resp = conn.getresponse()
        data = resp.read().decode()
        status = resp.status
        conn.close()
        return status, data

    def test_crud_over_http(self):
        status, body = self.call("/api/services/alpha/notes")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), {"notes": []})

        status, body = self.call("/api/services/alpha/notes", "POST",
                                 {"body": "ML is off because RAM."})
        self.assertEqual(status, 201)
        note = json.loads(body)
        self.assertEqual(note["title"], "ML is off because RAM.")

        status, body = self.call("/api/services/alpha/notes")
        self.assertEqual(json.loads(body), {"notes": [note]})

        status, body = self.call("/api/services/alpha/notes/%s" % note["id"],
                                 "PATCH", {"body": "Turned back on."})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["body"], "Turned back on.")

        status, body = self.call("/api/services/alpha/notes/%s" % note["id"],
                                 "DELETE")
        self.assertEqual(status, 204)
        self.assertEqual(body, "")
        self.assertEqual(json.loads(self.call("/api/services/alpha/notes")[1]),
                         {"notes": []})

    def test_notes_work_behind_the_mount_prefix(self):
        self.assertEqual(self.call("/home/api/services/alpha/notes")[0], 200)

    def test_newest_first_over_http(self):
        self.freeze_clock()
        ids = [json.loads(self.call("/api/services/alpha/notes", "POST",
                                    {"body": "n%d" % i})[1])["id"]
               for i in range(3)]
        doc = json.loads(self.call("/api/services/alpha/notes")[1])
        self.assertEqual([n["id"] for n in doc["notes"]], list(reversed(ids)))

    def test_unknown_service_is_404_on_every_verb(self):
        for path, method, body in (
                ("/api/services/ghost/notes", "GET", None),
                ("/api/services/ghost/notes", "POST", {"body": "x"}),
                ("/api/services/ghost/notes/abc", "PATCH", {"body": "x"}),
                ("/api/services/ghost/notes/abc", "DELETE", None)):
            status, data = self.call(path, method, body)
            self.assertEqual(status, 404, path)
            self.assertIn("error", json.loads(data))

    def test_unknown_note_is_404_over_http(self):
        for method in ("PATCH", "DELETE"):
            status, data = self.call("/api/services/alpha/notes/nope", method,
                                     {"body": "x"} if method == "PATCH" else None)
            self.assertEqual(status, 404, method)
            self.assertIn("error", json.loads(data))

    def test_validation_is_400_over_http(self):
        for body in ({}, {"body": ""}, {"body": 5},
                     {"body": "x" * (server.MAX_NOTE_BODY + 1)},
                     {"title": "t" * (server.MAX_NOTE_TITLE + 1), "body": "x"}):
            status, data = self.call("/api/services/alpha/notes", "POST", body)
            self.assertEqual(status, 400, body)
            self.assertIn("error", json.loads(data))

    def test_empty_post_body_is_400_not_a_crash(self):
        status, data = self.call("/api/services/alpha/notes", "POST")
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(data))

    def test_malformed_json_is_400(self):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("POST", "/api/services/alpha/notes", body=b"{not json",
                     headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        self.assertEqual(resp.status, 400)
        resp.read()
        conn.close()

    def test_cap_is_409_over_http(self):
        self.seed("alpha", server.MAX_NOTES_PER_SERVICE)
        status, data = self.call("/api/services/alpha/notes", "POST",
                                 {"body": "one too many"})
        self.assertEqual(status, 409)
        self.assertIn("error", json.loads(data))

    def test_oversized_body_is_413(self):
        status, _ = self.call("/api/services/alpha/notes", "POST",
                              {"body": "x" * (server.MAX_BODY_BYTES + 10)})
        self.assertEqual(status, 413)

    def test_cross_service_id_is_404_over_http(self):
        note = json.loads(self.call("/api/services/alpha/notes", "POST",
                                    {"body": "alpha only"})[1])
        path = "/api/services/bravo/notes/%s" % note["id"]
        self.assertEqual(self.call(path, "PATCH", {"body": "x"})[0], 404)
        self.assertEqual(self.call(path, "DELETE")[0], 404)
        self.assertEqual(
            json.loads(self.call("/api/services/alpha/notes")[1])["notes"],
            [note])

    def test_the_connection_survives_a_204(self):
        """No Content-Length on a 204, so a keep-alive client must not hang."""
        import http.client
        note = json.loads(self.call("/api/services/alpha/notes", "POST",
                                    {"body": "x"})[1])
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("DELETE", "/api/services/alpha/notes/%s" % note["id"])
        resp = conn.getresponse()
        self.assertEqual(resp.status, 204)
        self.assertEqual(resp.read(), b"")
        # Same connection, second request.
        conn.request("GET", "/api/services/alpha/notes")
        resp = conn.getresponse()
        self.assertEqual(resp.status, 200)
        self.assertEqual(json.loads(resp.read().decode()), {"notes": []})
        conn.close()

    def test_notes_are_not_cached(self):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", "/api/services/alpha/notes")
        resp = conn.getresponse()
        self.assertEqual(resp.getheader("Cache-Control"), "no-store")
        resp.read()
        conn.close()

    def test_notes_do_not_leak_into_the_other_payloads(self):
        self.call("/api/services/alpha/notes", "POST",
                  {"body": "a private operational note"})
        for path in ("/api/services", "/api/services/alpha"):
            self.assertNotIn("a private operational note", self.call(path)[1])

    def test_wrong_shaped_note_paths_are_404(self):
        for path, method in (("/api/services/alpha/notes/a/b", "GET"),
                             ("/api/services/alpha/notes/a/b", "DELETE"),
                             ("/api/services/notes", "GET"),
                             ("/api/services/alpha/note", "GET"),
                             ("/api/services/alpha/notes/abc", "GET")):
            status, _ = self.call(path, method)
            self.assertEqual(status, 404, path)

    def test_delete_is_not_available_on_a_service(self):
        note = json.loads(self.call("/api/services/alpha/notes", "POST",
                                    {"body": "x"})[1])
        self.assertEqual(self.call("/api/services/alpha", "DELETE")[0], 404)
        self.assertEqual(
            json.loads(self.call("/api/services/alpha/notes")[1])["notes"],
            [note])


# ------------------------------------------------- shipped descriptions

class ShippedDescriptionTest(unittest.TestCase):
    """services.json says what a service IS. Operational state is a note."""

    def setUp(self):
        real = os.path.join(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            "services.json")
        with open(real, encoding="utf-8") as fh:
            self.services = {s["key"]: s for s in json.load(fh)["services"]}

    def test_immich_no_longer_explains_why_ml_is_off(self):
        description = self.services["immich"]["description"]
        for phrase in ("Machine learning", "machine learning", "RAM",
                       "7.7 GB", "face grouping", "semantic search",
                       "off by default"):
            self.assertNotIn(phrase, description, phrase)

    def test_immich_still_says_what_it_is(self):
        description = self.services["immich"]["description"]
        self.assertIn("Self-hosted Google Photos", description)
        self.assertIn("camera backup", description)
        self.assertIn("127.0.0.1:2283", description)
        self.assertTrue(description.rstrip().endswith("."))

    def test_seafiles_deliberate_camera_upload_sentence_is_untouched(self):
        # Deliberate, and not the same kind of sentence: it says what this
        # deployment is, not what today's RAM budget happens to be.
        self.assertIn("Camera upload stays off here on purpose",
                      self.services["seafile"]["description"])


# ---------------------------------------------------------------- detail HTTP

class DetailHttpTest(SandboxTest):
    """Detail, PATCH and reveal over a real socket."""

    def setUp(self):
        super().setUp()
        import threading
        self.make_env("alpha/.env",
                      "IMMICH_VERSION=%s\nDB_PASSWORD=%s\n"
                      % (VISIBLE_VALUE, SECRET_VALUE))
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": "https://HOST:1/", "health": None, "marker": None,
             "setup": None, "env": "alpha/.env",
             "description": "Shipped description."},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def call(self, path, method="GET", body=None):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        payload = json.dumps(body).encode() if body is not None else None
        conn.request(method, path, body=payload,
                     headers={"Content-Type": "application/json"}
                     if payload else {})
        resp = conn.getresponse()
        data = resp.read().decode()
        status = resp.status
        conn.close()
        return status, data

    def test_detail_over_http(self):
        status, body = self.call("/api/services/alpha")
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertEqual(doc["key"], "alpha")
        self.assertEqual(doc["description"], "Shipped description.")
        self.assertEqual([v["name"] for v in doc["env"]["vars"]],
                         ["IMMICH_VERSION", "DB_PASSWORD"])
        self.assertNotIn(SECRET_VALUE, body)
        self.assertNotIn(VISIBLE_VALUE, body)

    def test_detail_works_behind_the_mount_prefix(self):
        self.assertEqual(self.call("/home/api/services/alpha")[0], 200)

    def test_unknown_service_is_404(self):
        status, body = self.call("/api/services/ghost")
        self.assertEqual(status, 404)
        self.assertIn("error", json.loads(body))

    def test_patch_over_http_returns_the_updated_detail(self):
        status, body = self.call("/api/services/alpha", "PATCH",
                                 {"name": "Photos"})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["name"], "Photos")
        self.assertEqual(json.loads(self.call("/api/services/alpha")[1])["name"],
                         "Photos")

    def test_patch_validation_is_400_over_http(self):
        status, _ = self.call("/api/services/alpha", "PATCH", {"name": 5})
        self.assertEqual(status, 400)
        status, _ = self.call("/api/services/alpha", "PATCH",
                              {"name": "x" * 200})
        self.assertEqual(status, 400)

    def test_patch_unknown_service_is_404_over_http(self):
        self.assertEqual(
            self.call("/api/services/ghost", "PATCH", {"name": "x"})[0], 404)

    def test_oversized_body_is_413(self):
        status, _ = self.call("/api/services/alpha", "PATCH",
                              {"description": "x" * (server.MAX_BODY_BYTES + 10)})
        self.assertEqual(status, 413)

    def test_reveal_over_http(self):
        status, body = self.call(
            "/api/services/alpha/env/DB_PASSWORD/reveal", "POST")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body),
                         {"name": "DB_PASSWORD", "value": SECRET_VALUE})

    def test_reveal_unknown_variable_is_404_over_http(self):
        status, body = self.call(
            "/api/services/alpha/env/NOPE/reveal", "POST")
        self.assertEqual(status, 404)
        self.assertNotIn("NOPE", body)

    def test_reveal_is_not_available_over_get(self):
        status, body = self.call("/api/services/alpha/env/DB_PASSWORD/reveal")
        self.assertEqual(status, 404)
        self.assertNotIn(SECRET_VALUE, body)


# ---------------------------------------------------------------- control
#
# Lifecycle control: start/stop/restart, from the same per-service `control`
# block in services.json that ntfy-control reads. The tests below care about
# three things above all: the exact argv (nothing from the request, no shell),
# the ORDER of container stops, and that nothing about Uptime Kuma can stop
# you turning a service off.


class RecordedProc:
    """A subprocess that has already exited with a canned code."""

    def __init__(self, code):
        self.code = code
        self.pid = 4242

    def wait(self, timeout=None):
        return self.code


class HungProc:
    """A stop guard that never answers: wait(timeout) always times out, and
    only a plain wait() (after the group kill) returns."""

    def __init__(self, argv):
        self.argv = argv
        self.pid = 31337
        self.timeouts = []

    def wait(self, timeout=None):
        if timeout is not None:
            self.timeouts.append(timeout)
            raise subprocess.TimeoutExpired(self.argv, timeout)
        return -9


class ControlTestBase(SandboxTest):
    """Sandbox with a small control registry and a recording Popen."""

    REGISTRY = {"services": []}

    def setUp(self):
        super().setUp()
        # _find_uv is patched by most of these; tearDown restores whatever is
        # registered here, so no patch can leak into another test.
        self._saved["_find_uv"] = server._find_uv
        server._find_uv = lambda: None          # no Kuma unless a test asks
        server._have_docker_group = lambda: True  # plain docker argv by default
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {u: False for u in urls}
        self.spawned = []
        self.write_registry(self.control_registry())

    # ---- helpers

    def control_registry(self):
        def svc(key, control):
            return {"key": key, "name": key, "tagline": "t", "icon": "code",
                    "url": None, "health": None, "marker": None,
                    "setup": None, "env": None, "control": control}
        return {"services": [
            svc("immich", {
                "parts": [{"container": "immich_server"},
                          {"container": "immich_machine_learning",
                           "optional": True},
                          {"container": "immich_redis"},
                          {"container": "immich_postgres"}],
                "kuma": "immich"}),
            svc("beszel", {
                "parts": [{"unit": "beszel-agent.service"},
                          {"container": "beszel"}],
                "primary": "beszel", "kuma": "beszel"}),
            svc("manimkc", {"parts": [{"unit": "manimkc.service"}],
                            "kuma": "manimkc"}),
            svc("n8n", {"parts": [{"container": "n8n"}], "kuma": "n8n"}),
            svc("adguard", {"parts": [{"container": "adguard"}],
                            "kuma": ["adguard", "adguard-dns"]}),
            svc("uptime-kuma", {"parts": [{"container": "uptime-kuma"}],
                                "kuma": None}),
            svc("ntfy", {"locked": "ntfy is how you start things again"}),
            svc("ollama", {"locked": "needs sudo"}),
            # Locked by the registry alone, with no in-code backstop, so the
            # `locked` field can be tested on its own terms.
            svc("offlimits", {"locked": "deliberately off limits"}),
            # Deliberately configured as if someone had tried to make the
            # launcher stoppable from its own UI.
            svc("launcher", {"parts": [{"unit": "launcher.service"}],
                             "kuma": "launcher"}),
            svc("planned", None),
        ]}

    def record_popen(self, failures=None, parked=False):
        """Patch Popen to record argv and hand back canned exit codes.

        `failures` maps a substring of the joined argv to the exit code that
        invocation should report. `parked=True` hands back processes that never
        exit, so the job stays 'running' for the duration of the test — the
        recording equivalent of a bare FakeProc.
        """
        failures = dict(failures or {})

        def fake(argv, **kwargs):
            self.spawned.append((list(argv), kwargs))
            if parked:
                return FakeProc(argv, **kwargs)
            joined = " ".join(argv)
            for needle, code in failures.items():
                if needle in joined:
                    return RecordedProc(code)
            return RecordedProc(0)

        subprocess.Popen = fake

    def wait_for_spawn(self, count, timeout=5.0):
        """Block until `count` steps have actually been spawned.

        A job runs on its own thread, so a test that only checks the job
        registry can finish while that thread has yet to reach Popen. Waiting
        here keeps the stub in place until the step it is meant to catch has
        gone through it.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            if len(self.spawned) >= count:
                return
            time.sleep(0.01)
        self.fail("only %d of %d steps spawned"
                  % (len(self.spawned), count))

    def argvs(self):
        return [argv for argv, _ in self.spawned]

    def run_action(self, key, action, failures=None, timeout=10.0):
        """Start an action, wait for it, return its api/jobs payload."""
        self.record_popen(failures)
        job_id = server.start_action(key, action)
        deadline = time.time() + timeout
        while time.time() < deadline:
            with server._jobs_lock:
                job = server._jobs.get(job_id)
                status = job["status"] if job else None
            if status and status != "running":
                return server.job_payload(job_id)
            time.sleep(0.01)
        self.fail("job %s never finished" % job_id)

    def plan(self, key, action):
        return [step["argv"] for step
                in server.plan_action(server.find_service(key), action)]

    def enable_kuma(self):
        """Give the sandbox a working kuma_toggle.py + services/monitoring/.env."""
        toggle = os.path.join(self.repo, "services", "ntfy-control", "kuma_toggle.py")
        os.makedirs(os.path.dirname(toggle), exist_ok=True)
        with open(toggle, "w", encoding="utf-8") as fh:
            fh.write("# fixture\n")
        env_path = os.path.join(self.repo, "services", "monitoring", ".env")
        os.makedirs(os.path.dirname(env_path), exist_ok=True)
        with open(env_path, "w", encoding="utf-8") as fh:
            fh.write("KUMA_PORT=3002\nKUMA_ADMIN_USER=admin\n"
                     "KUMA_ADMIN_PASSWORD=%s\n" % SECRET_VALUE)
        server._find_uv = lambda: "/opt/bin/uv"
        return toggle


class ControlStatusTest(ControlTestBase):
    """Which services may be controlled at all, and why not."""

    def status(self, key):
        return server.control_status(server.find_service(key))

    def test_configured_service_is_controllable(self):
        self.assertEqual(self.status("n8n"),
                         {"controllable": True, "reason": None})

    def test_locked_service_reports_its_reason(self):
        status = self.status("offlimits")
        self.assertFalse(status["controllable"])
        self.assertEqual(status["reason"], "deliberately off limits")

    def test_hard_locked_reason_wins_over_the_registrys_own(self):
        # ntfy is locked in both places; the in-code reason is the one served,
        # because that is the one that cannot be edited away.
        self.assertEqual(self.status("ntfy")["reason"],
                         server.HARD_LOCKED["ntfy"])

    def test_service_without_a_control_block_is_not_controllable(self):
        status = self.status("planned")
        self.assertFalse(status["controllable"])
        self.assertIn("no start/stop configuration", status["reason"])

    def test_hard_locked_keys_win_over_the_registry(self):
        # The registry entry for `launcher` is fully configured above; the
        # in-code lock must still refuse it, because a bad edit to
        # services.json must not be able to hand the UI a self-destruct.
        status = self.status("launcher")
        self.assertFalse(status["controllable"])
        self.assertIn("no UI left", status["reason"])
        self.assertEqual(sorted(server.HARD_LOCKED),
                         ["launcher", "ntfy", "ollama"])

    def test_status_appears_on_every_tile(self):
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertTrue(tiles["n8n"]["control"]["controllable"])
        self.assertFalse(tiles["ntfy"]["control"]["controllable"])
        self.assertFalse(tiles["launcher"]["control"]["controllable"])
        self.assertFalse(tiles["planned"]["control"]["controllable"])

    def test_status_appears_on_the_detail_payload(self):
        self.assertTrue(server.service_detail("immich")["control"]["controllable"])
        self.assertFalse(server.service_detail("ollama")["control"]["controllable"])

    # ---- a mangled registry degrades, it does not execute

    def test_part_names_with_shell_metacharacters_are_dropped(self):
        self.write_registry({"services": [
            {"key": "evil", "name": "evil", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "control": {"parts": [{"container": "a; rm -rf ~"},
                                   {"container": "$(id)"},
                                   {"unit": "../../etc/passwd"},
                                   {"container": "ok-container"}]}},
        ]})
        parts = server.control_parts(
            server.control_block(server.find_service("evil")))
        self.assertEqual([p["name"] for p in parts], ["ok-container"])

    def test_a_service_whose_parts_are_all_junk_is_not_controllable(self):
        self.write_registry({"services": [
            {"key": "evil", "name": "evil", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "control": {"parts": [{"container": "a b c"}]}},
        ]})
        self.assertFalse(self.status("evil")["controllable"])

    def test_monitor_name_is_gated_too(self):
        self.assertEqual(server.control_monitors({"kuma": "a; curl evil"}), [])
        self.assertEqual(server.control_monitors({"kuma": None}), [])
        self.assertEqual(server.control_monitors({}), [])
        self.assertEqual(server.control_monitors({"kuma": "immich"}), ["immich"])

    def test_monitor_list_keeps_order_and_drops_junk(self):
        self.assertEqual(
            server.control_monitors(
                {"kuma": ["adguard", "a; curl evil", 7, "adguard-dns",
                          "adguard"]}),
            ["adguard", "adguard-dns"])
        self.assertEqual(server.control_monitors({"kuma": []}), [])
        self.assertEqual(server.control_monitors({"kuma": {"a": 1}}), [])


class ControlPlanTest(ControlTestBase):
    """The exact argv, and the order it runs in."""

    def test_single_container_service(self):
        self.assertEqual(self.plan("n8n", "stop"), [["docker", "stop", "n8n"]])
        self.assertEqual(self.plan("n8n", "start"), [["docker", "start", "n8n"]])
        self.assertEqual(self.plan("n8n", "restart"),
                         [["docker", "stop", "n8n"], ["docker", "start", "n8n"]])

    def test_systemd_service_uses_the_user_manager(self):
        self.assertEqual(self.plan("manimkc", "stop"),
                         [["systemctl", "--user", "stop", "manimkc.service"]])
        self.assertEqual(self.plan("manimkc", "start"),
                         [["systemctl", "--user", "start", "manimkc.service"]])

    def test_immich_stops_the_server_before_its_datastores(self):
        self.assertEqual(self.plan("immich", "stop"), [
            ["docker", "stop", "immich_server"],
            ["docker", "stop", "immich_machine_learning"],
            ["docker", "stop", "immich_redis"],
            ["docker", "stop", "immich_postgres"],
        ])

    def test_immich_start_is_the_exact_reverse_of_stop(self):
        stop = self.plan("immich", "stop")
        start = self.plan("immich", "start")
        self.assertEqual([a[2] for a in start],
                         list(reversed([a[2] for a in stop])))
        self.assertEqual(start[0], ["docker", "start", "immich_postgres"])
        self.assertEqual(start[-1], ["docker", "start", "immich_server"])

    def test_immich_restart_is_a_full_stop_pass_then_a_full_start_pass(self):
        plan = self.plan("immich", "restart")
        self.assertEqual(plan, self.plan("immich", "stop")
                         + self.plan("immich", "start"))

    def test_one_command_per_container_not_one_docker_stop_for_all(self):
        """docker stops multiple containers in PARALLEL, which would throw
        away the ordering this service depends on."""
        for argv in self.plan("immich", "stop"):
            self.assertEqual(len(argv), 3)

    def test_immichs_ml_container_is_optional(self):
        steps = server.plan_action(server.find_service("immich"), "stop")
        flags = {step["argv"][2]: step["optional"] for step in steps}
        self.assertTrue(flags["immich_machine_learning"])
        self.assertFalse(flags["immich_server"])
        self.assertFalse(flags["immich_postgres"])

    def test_beszel_moves_hub_and_agent_together(self):
        self.assertEqual(self.plan("beszel", "stop"), [
            ["systemctl", "--user", "stop", "beszel-agent.service"],
            ["docker", "stop", "beszel"],
        ])
        self.assertEqual(self.plan("beszel", "start"), [
            ["docker", "start", "beszel"],
            ["systemctl", "--user", "start", "beszel-agent.service"],
        ])

    def test_beszel_start_brings_the_hub_up_before_the_agent(self):
        start = self.plan("beszel", "start")
        self.assertEqual(start[0][0], "docker")
        self.assertEqual(start[1][0], "systemctl")

    # ---- docker group

    def test_docker_steps_are_wrapped_in_sg_when_the_group_is_missing(self):
        server._have_docker_group = lambda: False
        server._which = lambda n: "/usr/bin/sg" if n == "sg" else None
        argv = self.plan("n8n", "stop")[0]
        self.assertEqual(argv[:3], ["/usr/bin/sg", "docker", "-c"])
        self.assertEqual(argv[3], "docker stop n8n")

    def test_systemd_steps_are_never_wrapped_in_sg(self):
        """systemctl --user needs no docker group, and wrapping it in sg
        would only add a way for it to break."""
        server._have_docker_group = lambda: False
        server._which = lambda n: "/usr/bin/sg" if n == "sg" else None
        self.assertEqual(self.plan("manimkc", "stop")[0],
                         ["systemctl", "--user", "stop", "manimkc.service"])

    def test_no_sg_available_falls_back_to_plain_docker(self):
        server._have_docker_group = lambda: False
        server._which = lambda n: None
        self.assertEqual(self.plan("n8n", "stop")[0], ["docker", "stop", "n8n"])

    # ---- no request data, ever

    def test_every_argv_word_comes_from_the_registry_or_a_constant(self):
        allowed = {"docker", "systemctl", "--user", "start", "stop",
                   "immich_server", "immich_machine_learning", "immich_redis",
                   "immich_postgres"}
        for action in server.CONTROL_ACTIONS:
            for argv in self.plan("immich", action):
                for word in argv:
                    self.assertIn(word, allowed)

    def test_planning_is_a_list_never_a_string(self):
        for argv in self.plan("immich", "restart"):
            self.assertIsInstance(argv, list)
            for word in argv:
                self.assertIsInstance(word, str)


class ControlKumaTest(ControlTestBase):
    """Kuma is paused around deliberate downtime, and never in the way."""

    def steps(self, key, action):
        return server.plan_action(server.find_service(key), action)

    def test_no_kuma_step_when_uv_is_not_installed(self):
        self.enable_kuma()
        server._find_uv = lambda: None
        self.assertEqual(self.plan("n8n", "stop"), [["docker", "stop", "n8n"]])

    def test_no_kuma_step_when_the_toggle_script_is_missing(self):
        self.enable_kuma()
        os.unlink(os.path.join(self.repo, "services", "ntfy-control", "kuma_toggle.py"))
        self.assertEqual(self.plan("n8n", "stop"), [["docker", "stop", "n8n"]])

    def test_no_kuma_step_when_monitoring_env_is_missing(self):
        self.enable_kuma()
        os.unlink(os.path.join(self.repo, "services", "monitoring", ".env"))
        self.assertEqual(self.plan("n8n", "stop"), [["docker", "stop", "n8n"]])

    def test_no_kuma_step_for_a_service_with_no_monitor(self):
        # uptime-kuma has no monitor of itself.
        self.enable_kuma()
        self.assertEqual(self.plan("uptime-kuma", "stop"),
                         [["docker", "stop", "uptime-kuma"]])

    def test_pause_runs_before_anything_stops(self):
        toggle = self.enable_kuma()
        plan = self.plan("immich", "stop")
        self.assertEqual(plan[0],
                         ["/opt/bin/uv", "run", "--with", "uptime-kuma-api",
                          "python3", os.path.realpath(toggle), "pause",
                          "immich"])
        self.assertEqual(plan[1], ["docker", "stop", "immich_server"])

    def test_resume_runs_after_everything_starts(self):
        toggle = self.enable_kuma()
        plan = self.plan("immich", "start")
        self.assertEqual(plan[-1],
                         ["/opt/bin/uv", "run", "--with", "uptime-kuma-api",
                          "python3", os.path.realpath(toggle), "resume",
                          "immich"])
        self.assertEqual(plan[-2], ["docker", "start", "immich_server"])

    def test_restart_pauses_first_and_resumes_last(self):
        self.enable_kuma()
        plan = self.plan("immich", "restart")
        self.assertEqual(plan[0][-2:], ["pause", "immich"])
        self.assertEqual(plan[-1][-2:], ["resume", "immich"])

    def test_every_monitor_is_paused_before_anything_stops(self):
        self.enable_kuma()
        plan = self.plan("adguard", "stop")
        self.assertEqual([a[-2:] for a in plan[:2]],
                         [["pause", "adguard"], ["pause", "adguard-dns"]])
        self.assertEqual(plan[2:], [["docker", "stop", "adguard"]])

    def test_every_monitor_is_resumed_after_everything_starts(self):
        self.enable_kuma()
        plan = self.plan("adguard", "start")
        self.assertEqual(plan[0], ["docker", "start", "adguard"])
        self.assertEqual([a[-2:] for a in plan[1:]],
                         [["resume", "adguard"], ["resume", "adguard-dns"]])

    def test_restart_pauses_and_resumes_every_monitor(self):
        self.enable_kuma()
        plan = self.plan("adguard", "restart")
        self.assertEqual([a[-2:] for a in plan], [
            ["pause", "adguard"], ["pause", "adguard-dns"],
            ["stop", "adguard"], ["start", "adguard"],
            ["resume", "adguard"], ["resume", "adguard-dns"]])

    def test_one_failed_pause_does_not_skip_the_next_monitor(self):
        self.enable_kuma()
        payload = self.run_action("adguard", "stop",
                                  failures={"pause adguard": 1})
        self.assertEqual(payload["status"], "done")
        self.assertIn(["docker", "stop", "adguard"], self.argvs())
        pauses = [a[-1] for a in self.argvs() if a[-2:-1] == ["pause"]]
        self.assertEqual(pauses, ["adguard", "adguard-dns"])
        self.assertIn("pause adguard-dns", payload["log"])

    def test_a_failed_restart_still_resumes_every_monitor(self):
        self.enable_kuma()
        payload = self.run_action("adguard", "restart",
                                  failures={"docker start adguard": 1})
        self.assertEqual(payload["status"], "failed")
        resumes = [a[-1] for a in self.argvs() if a[-2:-1] == ["resume"]]
        self.assertEqual(resumes, ["adguard", "adguard-dns"])

    def test_the_existing_toggle_script_is_called_not_reimplemented(self):
        toggle = self.enable_kuma()
        argv = self.plan("n8n", "stop")[0]
        self.assertEqual(argv[-3], os.path.realpath(toggle))
        self.assertIn("uptime-kuma-api", argv)

    def test_kuma_steps_are_always_optional(self):
        self.enable_kuma()
        for step in self.steps("immich", "restart"):
            if "kuma_toggle.py" in " ".join(step["argv"]):
                self.assertTrue(step["optional"])

    def test_kuma_credentials_go_to_the_child_and_not_the_argv(self):
        self.enable_kuma()
        step = self.steps("n8n", "stop")[0]
        self.assertNotIn(SECRET_VALUE, " ".join(step["argv"]))
        self.assertEqual(step["env"]["KUMA_ADMIN_PASSWORD"], SECRET_VALUE)

    def test_a_kuma_failure_does_not_fail_the_stop(self):
        self.enable_kuma()
        payload = self.run_action("n8n", "stop",
                                  failures={"kuma_toggle.py": 1})
        self.assertEqual(payload["status"], "done")
        self.assertEqual(payload["exit_code"], 0)
        # ...and the container was still stopped, after the failed pause.
        self.assertIn(["docker", "stop", "n8n"], self.argvs())

    def test_a_kuma_that_cannot_even_be_spawned_does_not_fail_the_stop(self):
        self.enable_kuma()

        def fake(argv, **kwargs):
            self.spawned.append((list(argv), kwargs))
            if "kuma_toggle.py" in " ".join(argv):
                raise OSError("uv vanished")
            return RecordedProc(0)

        subprocess.Popen = fake
        job_id = server.start_action("n8n", "stop")
        deadline = time.time() + 10
        while time.time() < deadline:
            payload = server.job_payload(job_id)
            if payload["status"] != "running":
                break
            time.sleep(0.01)
        self.assertEqual(payload["status"], "done")
        self.assertIn(["docker", "stop", "n8n"], self.argvs())

    def test_secrets_never_reach_the_job_log(self):
        self.enable_kuma()
        payload = self.run_action("n8n", "stop")
        self.assertNotIn(SECRET_VALUE, payload["log"])
        self.assertIn("kuma_toggle.py", payload["log"])

    def test_a_failed_restart_still_resumes_the_monitor(self):
        """Otherwise a service that would not come back stays silently
        paused — exactly the downtime you would want to be paged about."""
        self.enable_kuma()
        payload = self.run_action("n8n", "restart",
                                  failures={"docker start n8n": 1})
        self.assertEqual(payload["status"], "failed")
        resumes = [a for a in self.argvs() if a[-2:] == ["resume", "n8n"]]
        self.assertEqual(len(resumes), 1)


class ControlRunnerTest(ControlTestBase):
    """What the job runner does with the plan."""

    def test_action_runs_every_step_in_order(self):
        payload = self.run_action("immich", "stop")
        self.assertEqual(payload["status"], "done")
        self.assertEqual([a[2] for a in self.argvs()],
                         ["immich_server", "immich_machine_learning",
                          "immich_redis", "immich_postgres"])

    def test_absent_optional_container_is_skipped_and_the_rest_still_runs(self):
        """`ml` compose profile off: `docker stop immich_machine_learning`
        exits non-zero with 'No such container' and must not abort the stop."""
        payload = self.run_action(
            "immich", "stop", failures={"immich_machine_learning": 1})
        self.assertEqual(payload["status"], "done")
        self.assertEqual(payload["exit_code"], 0)
        self.assertEqual([a[2] for a in self.argvs()][-2:],
                         ["immich_redis", "immich_postgres"])
        self.assertIn("skipped", payload["log"])

    def test_present_optional_container_is_just_another_step(self):
        payload = self.run_action("immich", "stop")
        self.assertIn(["docker", "stop", "immich_machine_learning"],
                      self.argvs())
        self.assertNotIn("skipped", payload["log"])

    def test_a_required_failure_stops_the_remaining_steps(self):
        payload = self.run_action("immich", "stop",
                                  failures={"immich_server": 3})
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["exit_code"], 3)
        self.assertEqual(self.argvs(), [["docker", "stop", "immich_server"]])
        self.assertIn("failed", payload["log"])

    def test_beszel_stops_both_halves(self):
        self.run_action("beszel", "stop")
        self.assertEqual(self.argvs(), [
            ["systemctl", "--user", "stop", "beszel-agent.service"],
            ["docker", "stop", "beszel"],
        ])

    def test_beszel_starts_both_halves(self):
        self.run_action("beszel", "start")
        self.assertEqual(self.argvs(), [
            ["docker", "start", "beszel"],
            ["systemctl", "--user", "start", "beszel-agent.service"],
        ])

    def test_popen_is_called_with_a_list_and_shell_false(self):
        self.run_action("immich", "restart")
        self.assertTrue(self.spawned)
        for argv, kwargs in self.spawned:
            self.assertIsInstance(argv, list)
            self.assertFalse(kwargs.get("shell", False))
            self.assertIs(kwargs.get("stdin"), subprocess.DEVNULL)

    def test_the_log_records_the_command_line_it_ran(self):
        payload = self.run_action("manimkc", "restart")
        self.assertIn("$ systemctl --user stop manimkc.service", payload["log"])
        self.assertIn("$ systemctl --user start manimkc.service", payload["log"])


class ControlJobTest(ControlTestBase):
    """Actions are ordinary jobs: same registry, same cap, same log endpoint."""

    def test_action_is_recorded_on_the_job(self):
        self.record_popen()
        job_id = server.start_action("n8n", "stop")
        self.assertEqual(server.job_payload(job_id)["action"], "stop")
        self.assertEqual(server.job_payload(job_id)["key"], "n8n")
        # Wait for the step to go through the stub before tearDown restores the
        # real subprocess. Without this the job's thread can reach Popen after
        # the patch is gone and run a REAL `docker stop n8n` against the host —
        # observed once here, and the reason tearDown's "unstubbed subprocess
        # reached the host" guard exists. The race is timing-dependent, so it
        # hides for hundreds of runs and then stops a live service.
        self.wait_for_spawn(1)

    def test_action_shows_on_the_tile_like_a_deploy_does(self):
        self.record_popen(parked=True)
        job_id = server.start_action("n8n", "stop")
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertEqual(tiles["n8n"]["job"],
                         {"id": job_id, "status": "running", "action": "stop"})
        self.wait_for_spawn(1)

    def test_a_deploy_and_an_action_share_the_per_key_slot(self):
        self.make_script("services/n8n/setup.sh")
        registry = self.control_registry()
        for svc in registry["services"]:
            if svc["key"] == "n8n":
                svc["setup"] = "services/n8n/setup.sh"
        self.write_registry(registry)
        self.record_popen(parked=True)
        server.start_deploy("n8n")
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("n8n", "stop")
        self.assertEqual(ctx.exception.status, 409)
        self.wait_for_spawn(1)

    def test_actions_respect_the_global_cap(self):
        self.record_popen(parked=True)
        server.start_action("n8n", "stop")
        server.start_action("manimkc", "stop")
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("immich", "stop")
        self.assertEqual(ctx.exception.status, 429)
        # Both accepted jobs, or the manimkc thread trips the guard after this
        # test has handed the stub back.
        self.wait_for_spawn(2)


class ControlRefusalTest(ControlTestBase):
    """Server-side refusals — not a hidden button."""

    def setUp(self):
        super().setUp()
        self.record_popen()

    def test_unknown_key_is_404(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("ghost", "stop")
        self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(self.spawned, [])

    def test_unknown_action_is_400(self):
        for bogus in ("nuke", "STOP", "", "stop; rm -rf ~", "deploy"):
            with self.assertRaises(server.DeployError) as ctx:
                server.start_action("n8n", bogus)
            self.assertEqual(ctx.exception.status, 400, bogus)
        self.assertEqual(self.spawned, [])

    def test_ntfy_is_refused(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("ntfy", "stop")
        self.assertEqual(ctx.exception.status, 403)
        self.assertEqual(self.spawned, [])

    def test_ollama_is_refused(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("ollama", "stop")
        self.assertEqual(ctx.exception.status, 403)
        self.assertEqual(self.spawned, [])

    def test_launcher_is_refused_even_though_the_registry_configures_it(self):
        for verb in server.CONTROL_ACTIONS:
            with self.assertRaises(server.DeployError) as ctx:
                server.start_action("launcher", verb)
            self.assertEqual(ctx.exception.status, 403)
        self.assertEqual(self.spawned, [])

    def test_a_service_with_no_control_block_is_refused(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("planned", "start")
        self.assertEqual(ctx.exception.status, 403)
        self.assertEqual(self.spawned, [])

    def test_shell_metacharacter_keys_never_reach_popen(self):
        for evil in ("n8n; rm -rf ~", "../../etc/passwd", "$(id)", "n8n|sh"):
            with self.assertRaises(server.DeployError) as ctx:
                server.start_action(evil, "stop")
            self.assertEqual(ctx.exception.status, 404)
        self.assertEqual(self.spawned, [])

    def test_uptime_kuma_stays_controllable(self):
        job_id = server.start_action("uptime-kuma", "stop")
        self.assertTrue(job_id)
        self.wait_for_spawn(1)


class ControlHttpTest(SandboxTest):
    """POST api/services/{key}/action over a real socket."""

    def setUp(self):
        super().setUp()
        import threading
        server._find_uv = lambda: None
        self._saved["_find_uv"] = self._saved.get("_find_uv", server._find_uv)
        server._have_docker_group = lambda: True
        self.write_registry({"services": [
            {"key": "n8n", "name": "n8n", "tagline": "t", "icon": "workflow",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None,
             "control": {"parts": [{"container": "n8n"}], "kuma": None}},
            {"key": "ntfy", "name": "ntfy", "tagline": "t", "icon": "bell",
             "url": None, "health": None, "marker": None, "setup": None,
             "env": None, "control": {"locked": "no"}},
        ]})
        server.magicdns_host = lambda: "box.ts.net"
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def call(self, path, method="POST", body=None):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        payload = json.dumps(body).encode() if body is not None else None
        conn.request(method, path, body=payload,
                     headers={"Content-Type": "application/json"}
                     if payload else {})
        resp = conn.getresponse()
        data = resp.read().decode()
        status = resp.status
        conn.close()
        return status, data

    def test_stop_is_202_with_a_job_id(self):
        status, body = self.call("/api/services/n8n/action",
                                 body={"action": "stop"})
        self.assertEqual(status, 202)
        job_id = json.loads(body)["job_id"]
        # The same job endpoint the deploy sheet already polls.
        status, body = self.call("/api/jobs/%s" % job_id, "GET")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)["action"], "stop")

    def test_every_verb_is_accepted(self):
        for verb in ("start", "stop", "restart"):
            server._jobs.clear()
            status, _ = self.call("/api/services/n8n/action",
                                  body={"action": verb})
            self.assertEqual(status, 202, verb)

    def test_works_behind_the_mount_prefix(self):
        status, _ = self.call("/home/api/services/n8n/action",
                              body={"action": "stop"})
        self.assertEqual(status, 202)

    def test_unknown_key_is_404(self):
        status, _ = self.call("/api/services/ghost/action",
                              body={"action": "stop"})
        self.assertEqual(status, 404)

    def test_locked_service_is_403(self):
        status, body = self.call("/api/services/ntfy/action",
                                 body={"action": "stop"})
        self.assertEqual(status, 403)
        self.assertIn("error", json.loads(body))

    def test_unknown_action_is_400(self):
        status, _ = self.call("/api/services/n8n/action",
                              body={"action": "obliterate"})
        self.assertEqual(status, 400)

    def test_missing_or_wrong_shaped_body_is_400(self):
        self.assertEqual(self.call("/api/services/n8n/action")[0], 400)
        self.assertEqual(self.call("/api/services/n8n/action",
                                   body={"action": 7})[0], 400)
        self.assertEqual(self.call("/api/services/n8n/action",
                                   body=["stop"])[0], 400)

    def test_action_is_not_available_over_get(self):
        self.assertEqual(self.call("/api/services/n8n/action", "GET")[0], 404)

    def test_second_action_for_the_same_key_is_409(self):
        self.assertEqual(self.call("/api/services/n8n/action",
                                   body={"action": "stop"})[0], 202)
        self.assertEqual(self.call("/api/services/n8n/action",
                                   body={"action": "start"})[0], 409)


# ------------------------------------------- the shipped, shared registry

class ControlStopGuardTest(ControlTestBase):
    """control.stop_guard: a read-only check that must pass before a stop."""

    def control_registry(self):
        self.marker = os.path.join(self.tmp, "data", "adguard")
        os.makedirs(self.marker, exist_ok=True)
        for key in ("adguard", "other"):
            self.make_script("%s/setup.sh" % key)
            self.make_script("%s/teardown.sh" % key)
        self.make_script("other/guard.sh")
        self.make_script("outside/guard.sh")

        def svc(key, guard, **extra):
            control = {"parts": [{"container": key}], "kuma": [key, key + "-dns"]}
            control.update(extra)
            if guard is not None:
                control["stop_guard"] = guard
            return {"key": key, "name": key, "tagline": "t", "icon": "code",
                    "url": None, "health": None, "marker": self.marker,
                    "setup": "%s/setup.sh" % key, "env": None,
                    "control": control}
        return {"services": [
            svc("adguard", ["adguard/teardown.sh", "--check-dns"]),
            svc("other", ["other/guard.sh"]),
            svc("plain", None),
        ]}

    def path(self, rel):
        return os.path.realpath(os.path.join(self.repo, rel))

    def set_guard(self, key, guard):
        registry = self.control_registry()
        for svc in registry["services"]:
            if svc["key"] == key:
                svc["control"]["stop_guard"] = guard
        self.write_registry(registry)

    def test_stop_runs_the_guard_first_then_pauses_then_stops(self):
        self.enable_kuma()
        argvs = self.plan("adguard", "stop")
        self.assertEqual(argvs[0], [self.path("adguard/teardown.sh"), "--check-dns"])
        self.assertEqual([a[-1] for a in argvs[1:3]], ["adguard", "adguard-dns"])
        self.assertIn("pause", argvs[1])
        self.assertEqual(argvs[3], ["docker", "stop", "adguard"])
        steps = server.plan_action(server.find_service("adguard"), "stop")
        self.assertTrue(steps[0]["guard"])
        self.assertFalse(steps[0]["optional"])
        self.assertEqual([s for s in steps[1:] if s.get("guard")], [])

    def test_restart_and_start_are_not_guarded(self):
        for action in ("restart", "start"):
            steps = server.plan_action(server.find_service("adguard"), action)
            self.assertEqual([s for s in steps if s.get("guard")], [], action)
            self.assertNotIn("--check-dns", sum((s["argv"] for s in steps), []))

    def test_a_service_without_a_guard_plans_as_before(self):
        self.assertEqual(self.plan("plain", "stop"), [["docker", "stop", "plain"]])

    def test_the_guard_goes_through_the_docker_group_wrapper(self):
        server._have_docker_group = lambda: False
        server._which = lambda name: "/usr/bin/sg" if name == "sg" else None
        argv = self.plan("adguard", "stop")[0]
        self.assertEqual(argv[:3], ["/usr/bin/sg", "docker", "-c"])
        self.assertEqual(argv[3], "%s --check-dns" % self.path("adguard/teardown.sh"))

    def test_remove_does_not_run_teardown_twice(self):
        argvs = self.plan("adguard", "remove")
        self.assertEqual(argvs, [[self.path("adguard/teardown.sh")]])

    def test_remove_runs_a_separate_guard_first(self):
        self.enable_kuma()
        argvs = self.plan("other", "remove")
        self.assertEqual(argvs[0], [self.path("other/guard.sh")])
        self.assertIn("pause", argvs[1])
        self.assertEqual(argvs[3], [self.path("other/teardown.sh")])

    def test_a_refusing_guard_fails_the_stop_before_anything_changes(self):
        self.enable_kuma()
        payload = self.run_action("adguard", "stop",
                                  failures={"--check-dns": 1})
        self.assertEqual(payload["status"], "failed")
        self.assertEqual(payload["exit_code"], 1)
        self.assertTrue(payload["refused"])
        self.assertEqual(self.argvs(),
                         [[self.path("adguard/teardown.sh"), "--check-dns"]])
        self.assertIn("refused by the stop guard", payload["log"])
        self.assertIn("nothing was changed", payload["log"])

    def test_a_passing_guard_lets_the_stop_through(self):
        payload = self.run_action("adguard", "stop")
        self.assertEqual(payload["status"], "done")
        self.assertFalse(payload["refused"])
        self.assertEqual(self.argvs()[-1], ["docker", "stop", "adguard"])

    def test_a_refused_remove_never_pauses_or_resumes_kuma(self):
        self.enable_kuma()
        payload = self.run_action("other", "remove", failures={"guard.sh": 2})
        self.assertTrue(payload["refused"])
        self.assertEqual(self.argvs(), [[self.path("other/guard.sh")]])

    def test_an_ordinary_failure_is_not_a_refusal(self):
        payload = self.run_action("adguard", "stop",
                                  failures={"docker stop": 1})
        self.assertEqual(payload["status"], "failed")
        self.assertFalse(payload["refused"])

    def test_an_unusable_guard_refuses_the_stop_with_no_job(self):
        outside = os.path.join(self.tmp, "elsewhere.sh")
        with open(outside, "w", encoding="utf-8") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        for guard in (["adguard/missing.sh"], [outside], "adguard/teardown.sh",
                      [], [""], ["adguard/teardown.sh", 3],
                      ["adguard/teardown.sh", "--x; rm -rf ~"],
                      ["../%s" % os.path.basename(self.tmp) + "/elsewhere.sh"]):
            self.set_guard("adguard", guard)
            self.record_popen()
            with self.assertRaises(server.DeployError) as ctx:
                server.start_action("adguard", "stop")
            self.assertEqual(ctx.exception.status, 403, guard)
            self.assertIn("stop_guard", ctx.exception.message, guard)
            self.assertEqual(self.spawned, [], guard)
            self.assertEqual(server._jobs, {}, guard)

    def test_a_hung_guard_is_killed_and_the_stop_refused(self):
        self.enable_kuma()
        hung = []
        killed = []

        def fake(argv, **kwargs):
            self.spawned.append((list(argv), kwargs))
            if "--check-dns" in argv:
                hung.append(HungProc(argv))
                return hung[-1]
            return RecordedProc(0)

        real_killpg = os.killpg
        subprocess.Popen = fake
        os.killpg = lambda pid, sig: killed.append((pid, sig))
        try:
            job_id = server.start_action("adguard", "stop")
            deadline = time.time() + 10
            while time.time() < deadline:
                with server._jobs_lock:
                    if server._jobs[job_id]["status"] != "running":
                        break
                time.sleep(0.01)
            payload = server.job_payload(job_id)
        finally:
            os.killpg = real_killpg
        self.assertEqual(payload["status"], "failed")
        self.assertTrue(payload["refused"])
        self.assertEqual(payload["exit_code"], 124)
        self.assertEqual(hung[0].timeouts, [server.GUARD_TIMEOUT])
        self.assertEqual(killed, [(31337, signal.SIGKILL)])
        self.assertTrue(self.spawned[0][1].get("start_new_session"))
        # Nothing after the guard ran: no Kuma pause, no docker stop.
        self.assertEqual(self.argvs(),
                         [[self.path("adguard/teardown.sh"), "--check-dns"]])
        self.assertIn("killed", payload["log"])

    def test_only_the_guard_gets_its_own_session(self):
        self.run_action("adguard", "stop")
        sessions = [bool(kw.get("start_new_session")) for _, kw in self.spawned]
        self.assertEqual(sessions, [True] + [False] * (len(sessions) - 1))

    def test_an_unusable_guard_does_not_block_restart_or_start(self):
        self.set_guard("adguard", ["adguard/missing.sh"])
        self.run_action("adguard", "restart")
        self.assertIn(["docker", "start", "adguard"], self.argvs())


class SharedControlRegistryTest(unittest.TestCase):
    """The real services.json — the file BOTH front ends read.

    These assertions are the anti-drift guarantee: the phone listener and the
    web UI are checked against the same file, in the same test run.
    """

    @classmethod
    def setUpClass(cls):
        cls.launcher_dir = os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))
        cls.repo = os.path.dirname(os.path.dirname(cls.launcher_dir))
        cls.path = os.path.join(cls.launcher_dir, "services.json")
        with open(cls.path, encoding="utf-8") as fh:
            cls.doc = json.load(fh)
        cls.services = {s["key"]: s for s in cls.doc["services"]}

    def control(self, key):
        return self.services[key].get("control") or {}

    def names(self, key):
        return [p.get("container") or p.get("unit")
                for p in self.control(key).get("parts", [])]

    def test_coverage_added_for_immich_beszel_and_manimkc(self):
        for key in ("immich", "beszel", "manimkc"):
            self.assertTrue(self.names(key), key)

    def test_immich_container_order(self):
        self.assertEqual(self.names("immich"),
                         ["immich_server", "immich_machine_learning",
                          "immich_redis", "immich_postgres"])

    def test_immich_ml_is_marked_optional_and_nothing_else_is(self):
        parts = self.control("immich")["parts"]
        optional = [p for p in parts if p.get("optional")]
        self.assertEqual([p["container"] for p in optional],
                         ["immich_machine_learning"])

    def test_beszel_carries_both_the_hub_and_the_agent(self):
        self.assertEqual(self.names("beszel"),
                         ["beszel-agent.service", "beszel"])
        self.assertEqual(self.control("beszel")["primary"], "beszel")

    def test_manimkc_is_a_user_unit(self):
        self.assertEqual(self.control("manimkc")["parts"],
                         [{"unit": "manimkc.service"}])

    def test_self_learn_stops_the_studio_runner_first_and_starts_it_last(self):
        # The runner's unit exists only while STUDIO_ENABLED=1, so it is an
        # optional part; it is listed first so stop takes it down before the
        # app (and the catalog file it talks to), and start (the reverse)
        # brings it back up after both.
        self.assertEqual(self.names("self-learn"),
                         ["self-learn-studio.service", "self-learn.service"])
        optional = [p for p in self.control("self-learn")["parts"]
                    if p.get("optional")]
        self.assertEqual([p["unit"] for p in optional],
                         ["self-learn-studio.service"])

    def test_self_learn_reports_the_web_app_not_the_optional_runner(self):
        # ntfy-control reports the first part's state unless `primary` names
        # another. With Studio off or stopped the runner is never active, so
        # without this a running app would show as stopped on the phone.
        self.assertEqual(self.control("self-learn")["primary"],
                         "self-learn.service")

    def test_every_primary_names_one_of_its_own_parts(self):
        for key in self.services:
            primary = self.control(key).get("primary")
            if primary:
                self.assertIn(primary, self.names(key), key)

    def test_locked_services_carry_a_reason_and_no_parts(self):
        for key in ("ntfy", "ollama"):
            block = self.control(key)
            self.assertTrue(block.get("locked"), key)
            self.assertNotIn("parts", block)

    def test_the_launcher_has_no_registry_entry_and_is_hard_locked(self):
        self.assertNotIn("launcher", self.services)
        self.assertIn("launcher", server.HARD_LOCKED)

    def test_uptime_kuma_is_still_controllable_with_no_monitor_of_its_own(self):
        self.assertEqual(self.names("uptime-kuma"), ["uptime-kuma"])
        self.assertIsNone(self.control("uptime-kuma")["kuma"])

    def test_every_monitor_name_exists_in_the_kuma_seed(self):
        seed = os.path.join(self.repo, "services", "monitoring", "seed_kuma.py")
        with open(seed, encoding="utf-8") as fh:
            text = fh.read()
        for key in self.services:
            for monitor in server.control_monitors(self.control(key)):
                self.assertIn('"%s"' % monitor, text, monitor)

    def test_every_container_part_is_declared_by_a_compose_file(self):
        # `docker stop <name>` takes the CONTAINER name, which is the
        # `container_name:` in the service's compose file — not the compose
        # service key, and not the registry key. Home Assistant shipped with
        # `homeassistant` (its compose service key) while the container is
        # `home-assistant`; both stop buttons then failed with "No such
        # container", after Kuma had already been paused. Read the compose
        # files themselves so a rename on either side fails here, not on the
        # phone.
        import glob
        pattern = re.compile(
            r"^\s*container_name:\s*(?:\$\{[A-Z0-9_]+:-([^}]+)\}|(\S+))",
            re.MULTILINE)
        declared = set()
        for compose in glob.glob(os.path.join(self.repo, "services", "*",
                                              "docker-compose.yml")):
            with open(compose, encoding="utf-8") as fh:
                for default, literal in pattern.findall(fh.read()):
                    declared.add((default or literal).strip("\"'"))
        self.assertTrue(declared)
        for key in self.services:
            for part in self.control(key).get("parts", []):
                name = part.get("container")
                if name:
                    self.assertIn(name, declared, "%s: %s" % (key, name))

    def test_services_with_no_control_block_are_refused_not_half_wired(self):
        # Derived from services.json rather than a hardcoded list of "planned"
        # services: every service deployed since this test was written moved
        # off that list, and a stale list fails for the wrong reason. What
        # matters is not *which* services lack a control block but that the
        # ones that do are cleanly refused by both front ends.
        listener = self._ntfy_control()
        try:
            phone = listener.load_registry()
        finally:
            os.environ.pop("CONTROL_REGISTRY", None)
        refused = [key for key, svc in self.services.items()
                   if not server.control_status(svc)["controllable"]]
        self.assertTrue(refused, "expected at least one uncontrollable service")
        for key in refused:
            svc = self.services[key]
            self.assertTrue(server.control_status(svc)["reason"], key)
            self.assertNotIn(key, phone)
            # Refused for a stated reason (locked) or for the honest absence of
            # a config — never a control block that exists but does nothing,
            # which would draw buttons the server then refuses.
            block = svc.get("control")
            if block is not None:
                self.assertTrue(block.get("locked"), key)

    def test_the_kuma_helper_paths_point_at_real_files(self):
        block = self.doc["control"]
        for field in ("kuma_toggle", "kuma_env"):
            self.assertTrue(block[field])
        self.assertTrue(os.path.isfile(
            os.path.join(self.repo, block["kuma_toggle"])))
        self.assertEqual(block["kuma_toggle"], "services/ntfy-control/kuma_toggle.py")

    # ---- the point of the whole exercise

    def _ntfy_control(self):
        """Import the deployed listener and point it at the shipped file."""
        import importlib.util
        path = os.path.join(self.repo, "services", "ntfy-control", "control_listener.py")
        os.environ["CONTROL_REGISTRY"] = self.path
        spec = importlib.util.spec_from_file_location("control_listener", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_both_front_ends_see_exactly_the_same_service_set(self):
        listener = self._ntfy_control()
        try:
            phone = set(listener.load_registry())
        finally:
            os.environ.pop("CONTROL_REGISTRY", None)
        web = {key for key, svc in self.services.items()
               if server.control_status(svc)["controllable"]}
        self.assertEqual(phone, web)
        # ...and it is the set we meant, not an empty one agreeing with itself.
        # Asserted as properties, not as a literal list: an exact list has to be
        # edited every time a service is deployed, and when someone forgets, the
        # failure points at this test instead of at whatever actually broke.
        self.assertTrue(web)
        for key in ("code-server", "seafile", "immich"):
            self.assertIn(key, web)          # the core, which never leaves
        for key in ("launcher", "ntfy", "ollama"):
            self.assertNotIn(key, web)       # locked, and must stay locked
        for key, svc in self.services.items():
            if key in web:
                self.assertTrue(svc["control"].get("parts"), key)

    def test_both_front_ends_agree_on_parts_order_and_monitors(self):
        listener = self._ntfy_control()
        try:
            phone = listener.load_registry()
        finally:
            os.environ.pop("CONTROL_REGISTRY", None)
        for key, control in phone.items():
            svc = self.services[key]
            web_parts = server.control_parts(server.control_block(svc))
            self.assertEqual([p["name"] for p in control["parts"]],
                             [p["name"] for p in web_parts], key)
            self.assertEqual([p["optional"] for p in control["parts"]],
                             [p["optional"] for p in web_parts], key)
            self.assertEqual(control["kuma"],
                             server.control_monitors(
                                 server.control_block(svc)), key)

    def test_adguard_stop_is_guarded_by_its_own_dns_check(self):
        guard = self.control("adguard")["stop_guard"]
        self.assertEqual(guard, ["services/adguard/teardown.sh", "--check-dns"])
        self.assertTrue(os.path.isfile(os.path.join(self.repo, guard[0])))
        with open(os.path.join(self.repo, guard[0]), encoding="utf-8") as fh:
            self.assertIn("--check-dns)", fh.read())

    def test_both_front_ends_resolve_the_same_stop_guard(self):
        listener = self._ntfy_control()
        try:
            phone = listener.load_registry()
        finally:
            os.environ.pop("CONTROL_REGISTRY", None)
        saved = (server.REPO_ROOT, server.ALLOWED_ROOTS)
        server.REPO_ROOT = os.path.realpath(self.repo)
        server.ALLOWED_ROOTS = [server.REPO_ROOT]
        try:
            for key, control in phone.items():
                web = server.stop_guard(self.services[key])
                guard, guard_error = listener.resolve_guard(control)
                self.assertIsNone(guard_error, key)
                if web is None:
                    self.assertIsNone(guard, key)
                else:
                    # The phone may prefix /bin/bash; the rest must match.
                    want = [web[0]] + list(web[1])
                    self.assertEqual(guard[-len(want):], want, key)
        finally:
            server.REPO_ROOT, server.ALLOWED_ROOTS = saved
        self.assertTrue(listener.resolve_guard(phone["adguard"])[0])

    def test_all_three_agree_on_which_stop_guards_are_well_formed(self):
        """The generator, the launcher and ntfy-control each carry their own
        copy of the guard shape rule; this table keeps the copies identical."""
        import importlib.util
        listener = self._ntfy_control()
        os.environ.pop("CONTROL_REGISTRY", None)
        spec = importlib.util.spec_from_file_location(
            "build_registry", os.path.join(self.repo, "scripts", "build-registry.py"))
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        self.assertEqual(server._GUARD_ARG_RE.pattern, listener.GUARD_ARG_RE.pattern)
        self.assertEqual(server._GUARD_ARG_RE.pattern, generator.GUARD_ARG_RE.pattern)
        table = [
            (["teardown.sh"], True),
            (["teardown.sh", "--check-dns"], True),
            (["teardown.sh", "--reason=DNS_maintenance", "-v", "a/b:c@d+e"], True),
            (["teardown.sh", "x" * 128], True),
            (["teardown.sh", "x" * 129], False),
            (["teardown.sh", "--reason=DNS maintenance"], False),
            (["teardown.sh", "--x;rm"], False),
            (["teardown.sh", "$(id)"], False),
            (["teardown.sh", "a\nb"], False),
            (["teardown.sh", "--x\n"], False),
            (["teardown.sh", "caf\u00e9"], False),
            (["teardown.sh", "'q'"], False),
            (["teardown.sh", ""], False),
            (["teardown.sh", 3], False),
            ([""], False),
            ([], False),
            ("teardown.sh", False),
            (None, False),
            ({"0": "teardown.sh"}, False),
        ]
        for raw, want in table:
            got = (server.guard_shape_ok(raw), listener.guard_shape_ok(raw),
                   generator.guard_shape_ok(raw))
            self.assertEqual(got, (want, want, want), raw)

    def test_neither_front_end_will_touch_the_locked_three(self):
        listener = self._ntfy_control()
        try:
            phone = listener.load_registry()
        finally:
            os.environ.pop("CONTROL_REGISTRY", None)
        for key in ("ntfy", "ollama", "launcher"):
            self.assertNotIn(key, phone, key)
            self.assertIn(key, listener.HARD_LOCKED, key)
            self.assertIn(key, server.HARD_LOCKED, key)


# ---------------------------------------------------------------- v3: usage
#
# usage.json is the sort key the grid defaults to, so it is written on every
# click and read on every poll. These care about three things: that a bad
# file can never take the grid down, that a write is atomic, and that
# last_used really is the later of the two stamps.


class UsageStoreTest(SandboxTest):
    """load_usage / _write_usage, on their own terms."""

    REGISTRY = {"services": [
        {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "code",
         "url": None, "health": None, "marker": None, "setup": None},
    ]}

    def test_missing_file_is_no_history(self):
        self.assertEqual(server.load_usage(), {})

    def test_round_trip(self):
        with server._usage_lock:
            server._write_usage({"alpha": {"last_launched": 12.5,
                                           "last_opened": 3.0}})
        self.assertEqual(server.load_usage(),
                         {"alpha": {"last_launched": 12.5, "last_opened": 3.0}})

    def test_deleting_the_file_resets_every_stamp(self):
        server.record_touch("alpha", {"event": "launched"})
        os.unlink(server.USAGE_PATH)
        self.assertEqual(server.load_usage(), {})
        self.assertEqual(server.usage_entry(server.load_usage(), "alpha"),
                         {"last_launched": None, "last_opened": None,
                          "last_used": None})

    def test_corrupt_file_degrades_to_no_history(self):
        self.write_usage_file("{not json")
        self.assertEqual(server.load_usage(), {})

    def test_non_object_document_degrades(self):
        self.write_usage_file("[1, 2, 3]")
        self.assertEqual(server.load_usage(), {})

    def test_missing_services_key_degrades(self):
        self.write_usage_file({"something": "else"})
        self.assertEqual(server.load_usage(), {})

    def test_only_numeric_stamps_survive(self):
        # A bool is a number in Python and is not a timestamp; a string is
        # not sortable against a float. Both are dropped rather than served.
        self.write_usage_file({"services": {
            "alpha": {"last_launched": "yesterday", "last_opened": 5},
            "bravo": {"last_launched": True},
            "charlie": {"last_launched": 7.5},
            "not-a-dict": 3,
        }})
        self.assertEqual(server.load_usage(),
                         {"alpha": {"last_opened": 5.0},
                          "charlie": {"last_launched": 7.5}})

    def test_write_is_atomic_and_leaves_no_temp_file(self):
        with server._usage_lock:
            server._write_usage({"alpha": {"last_launched": 1.0}})
        directory = os.path.dirname(server.USAGE_PATH)
        self.assertEqual([f for f in os.listdir(directory)
                          if f != "usage.json"], [])
        # and the file on disk is a complete, parseable document
        self.assertEqual(self.read_usage_file(),
                         {"services": {"alpha": {"last_launched": 1.0}}})

    def test_a_failed_write_leaves_the_previous_file_intact(self):
        with server._usage_lock:
            server._write_usage({"alpha": {"last_launched": 1.0}})
        before = self.read_usage_file()
        try:
            with server._usage_lock:
                # sets are not JSON: the dump fails halfway, after the temp
                # file exists but before any os.replace.
                server._write_usage({"alpha": {"last_launched": {1.0}}})
        except TypeError:
            pass
        self.assertEqual(self.read_usage_file(), before)
        directory = os.path.dirname(server.USAGE_PATH)
        self.assertEqual([f for f in os.listdir(directory)
                          if f != "usage.json"], [])

    def test_entry_last_used_is_the_max(self):
        usage = {"a": {"last_launched": 10.0, "last_opened": 4.0},
                 "b": {"last_launched": 4.0, "last_opened": 10.0}}
        self.assertEqual(server.usage_entry(usage, "a")["last_used"], 10.0)
        self.assertEqual(server.usage_entry(usage, "b")["last_used"], 10.0)

    def test_entry_with_one_stamp_uses_it(self):
        usage = {"a": {"last_opened": 8.0}}
        self.assertEqual(server.usage_entry(usage, "a"),
                         {"last_launched": None, "last_opened": 8.0,
                          "last_used": 8.0})

    def test_entry_for_a_never_used_service_is_all_null(self):
        self.assertEqual(server.usage_entry({}, "ghost"),
                         {"last_launched": None, "last_opened": None,
                          "last_used": None})


class TouchTest(SandboxTest):
    """POST api/services/{key}/touch, at the function level."""

    def setUp(self):
        super().setUp()
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {u: False for u in urls}
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "code",
             "url": "https://HOST:1/", "health": None, "marker": None,
             "setup": None},
            {"key": "bravo", "name": "Bravo", "tagline": "t", "icon": "code",
             "url": "https://HOST:2/", "health": None, "marker": None,
             "setup": None},
        ]})

    def test_launched_records_a_timestamp(self):
        before = time.time()
        out = server.record_touch("alpha", {"event": "launched"})
        after = time.time()
        stamp = out["usage"]["last_launched"]
        self.assertTrue(before <= stamp <= after)
        self.assertIsNone(out["usage"]["last_opened"])
        self.assertEqual(out["usage"]["last_used"], stamp)

    def test_opened_records_a_timestamp(self):
        out = server.record_touch("alpha", {"event": "opened"})
        self.assertIsNone(out["usage"]["last_launched"])
        self.assertIsNotNone(out["usage"]["last_opened"])
        self.assertEqual(out["usage"]["last_used"],
                         out["usage"]["last_opened"])

    def test_last_used_is_the_later_of_the_two(self):
        server.record_touch("alpha", {"event": "opened"})
        out = server.record_touch("alpha", {"event": "launched"})
        usage = out["usage"]
        self.assertGreaterEqual(usage["last_launched"], usage["last_opened"])
        self.assertEqual(usage["last_used"], usage["last_launched"])
        # and the older stamp is still the max when it is the later one
        stored = server.load_usage()["alpha"]
        stored["last_opened"] = stored["last_launched"] + 100
        self.assertEqual(server.usage_entry({"alpha": stored}, "alpha")
                         ["last_used"], stored["last_opened"])

    def test_the_stamp_is_taken_inside_the_lock(self):
        # Two near-simultaneous clicks. Whichever request WINS the lock has
        # to be the one whose stamp lands: taken at entry instead, the loser
        # overwrites the winner, last_launched moves backwards, and the 200
        # the first caller already rendered reports a stamp the server threw
        # away. Held here by hand so the race is decided, not raced.
        import threading
        got = {}

        def touch():
            got["usage"] = server.record_touch(
                "alpha", {"event": "launched"})["usage"]

        server._usage_lock.acquire()
        worker = threading.Thread(target=touch)
        worker.start()
        time.sleep(0.05)
        released = time.time()
        server._usage_lock.release()
        worker.join(5)
        self.assertFalse(worker.is_alive())
        self.assertGreaterEqual(got["usage"]["last_launched"], released)

    def test_a_second_touch_overwrites_only_its_own_field(self):
        first = server.record_touch("alpha", {"event": "opened"})["usage"]
        time.sleep(0.01)
        second = server.record_touch("alpha", {"event": "launched"})["usage"]
        self.assertEqual(second["last_opened"], first["last_opened"])
        self.assertNotEqual(second["last_launched"], first["last_opened"])

    def test_touching_one_service_leaves_the_others_alone(self):
        server.record_touch("alpha", {"event": "launched"})
        server.record_touch("bravo", {"event": "opened"})
        stored = server.load_usage()
        self.assertEqual(sorted(stored), ["alpha", "bravo"])
        self.assertEqual(sorted(stored["alpha"]), ["last_launched"])
        self.assertEqual(sorted(stored["bravo"]), ["last_opened"])

    def test_unknown_key_is_404(self):
        with self.assertRaises(server.DeployError) as caught:
            server.record_touch("ghost", {"event": "launched"})
        self.assertEqual(caught.exception.status, 404)
        self.assertFalse(os.path.exists(server.USAGE_PATH))

    def test_unknown_key_is_refused_before_the_event_is_looked_at(self):
        with self.assertRaises(server.DeployError) as caught:
            server.record_touch("ghost", {"event": "nonsense"})
        self.assertEqual(caught.exception.status, 404)

    def test_bad_event_is_400(self):
        for event in ("deployed", "", None, 5, ["launched"]):
            with self.assertRaises(server.DeployError) as caught:
                server.record_touch("alpha", {"event": event})
            self.assertEqual(caught.exception.status, 400, event)
        self.assertFalse(os.path.exists(server.USAGE_PATH))

    def test_non_object_body_is_400(self):
        for body in (None, [], "launched", 5):
            with self.assertRaises(server.DeployError) as caught:
                server.record_touch("alpha", body)
            self.assertEqual(caught.exception.status, 400, body)

    def test_usage_is_on_every_list_entry(self):
        server.record_touch("alpha", {"event": "launched"})
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertEqual(sorted(tiles["alpha"]["usage"]),
                         ["last_launched", "last_opened", "last_used"])
        self.assertIsNotNone(tiles["alpha"]["usage"]["last_used"])
        self.assertEqual(tiles["bravo"]["usage"],
                         {"last_launched": None, "last_opened": None,
                          "last_used": None})

    def test_usage_is_on_the_detail_entry_too(self):
        recorded = server.record_touch("alpha", {"event": "opened"})["usage"]
        self.assertEqual(server.service_detail("alpha")["usage"], recorded)


class TouchHttpTest(SandboxTest):
    """The touch endpoint over a real socket, including the size cap."""

    def setUp(self):
        super().setUp()
        import threading
        server.magicdns_host = lambda: "box.ts.net"
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "code",
             "url": "https://HOST:1/", "health": None, "marker": None,
             "setup": None},
        ]})
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def call(self, path, method="POST", body=None, raw=None):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        payload = raw if raw is not None else (
            json.dumps(body).encode() if body is not None else None)
        conn.request(method, path, body=payload,
                     headers={"Content-Type": "application/json"}
                     if payload else {})
        resp = conn.getresponse()
        data = resp.read().decode()
        status = resp.status
        conn.close()
        return status, data

    def test_touch_over_http(self):
        status, body = self.call("/api/services/alpha/touch",
                                 body={"event": "launched"})
        self.assertEqual(status, 200)
        doc = json.loads(body)
        self.assertEqual(sorted(doc), ["usage"])
        self.assertEqual(sorted(doc["usage"]),
                         ["last_launched", "last_opened", "last_used"])
        self.assertEqual(doc["usage"]["last_used"],
                         doc["usage"]["last_launched"])

    def test_touch_is_visible_on_the_next_list(self):
        self.call("/api/services/alpha/touch", body={"event": "opened"})
        doc = json.loads(self.call("/api/services", "GET")[1])
        self.assertIsNotNone(doc["services"][0]["usage"]["last_opened"])

    def test_unknown_key_is_404_over_http(self):
        status, body = self.call("/api/services/ghost/touch",
                                 body={"event": "launched"})
        self.assertEqual(status, 404)
        self.assertIn("error", json.loads(body))

    def test_bad_event_is_400_over_http(self):
        status, body = self.call("/api/services/alpha/touch",
                                 body={"event": "deployed"})
        self.assertEqual(status, 400)
        self.assertIn("error", json.loads(body))

    def test_oversized_body_is_413_well_below_the_global_cap(self):
        # Far under MAX_BODY_BYTES, so this only passes because touch has a
        # cap of its own.
        big = {"event": "launched", "pad": "x" * (server.MAX_TOUCH_BYTES + 10)}
        self.assertLess(len(json.dumps(big)), server.MAX_BODY_BYTES)
        status, body = self.call("/api/services/alpha/touch", body=big)
        self.assertEqual(status, 413)
        self.assertIn("error", json.loads(body))
        self.assertFalse(os.path.exists(server.USAGE_PATH))

    def test_a_body_just_under_the_cap_is_accepted(self):
        big = {"event": "launched", "pad": "x" * 800}
        self.assertLess(len(json.dumps(big)), server.MAX_TOUCH_BYTES)
        self.assertEqual(self.call("/api/services/alpha/touch", body=big)[0],
                         200)

    def test_malformed_body_is_400_over_http(self):
        status, _ = self.call("/api/services/alpha/touch", raw=b"{nope")
        self.assertEqual(status, 400)

    def test_touch_is_not_available_over_get(self):
        self.assertEqual(self.call("/api/services/alpha/touch", "GET")[0], 404)


# ----------------------------------------------------------- v3: deployed_at

class DeployedAtTest(SandboxTest):
    """mtime of the marker: "when was this deployed", without docker."""

    def setUp(self):
        super().setUp()
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {u: False for u in urls}

    def marker(self, name, mtime=None):
        path = os.path.join(self.tmp, name)
        os.makedirs(path)
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return path

    def test_marker_mtime(self):
        path = self.marker("state", 1757550470.0)
        self.assertEqual(server.deployed_at(path), 1757550470.0)

    def test_missing_marker_is_null(self):
        self.assertIsNone(server.deployed_at(os.path.join(self.tmp, "nope")))

    def test_no_marker_configured_is_null(self):
        self.assertIsNone(server.deployed_at(None))
        self.assertIsNone(server.deployed_at(""))

    def test_a_marker_that_is_not_a_path_is_null_not_a_500(self):
        # services.json is hand-edited, so `marker` is whatever JSON allowed.
        # A number raises TypeError out of expanduser and a NUL inside the
        # string raises ValueError. Either one uncaught is not one bad field:
        # deployed_at runs for every tile on every list request, so it takes
        # the entire grid down.
        self.assertIsNone(server.deployed_at(1757550470))
        self.assertIsNone(server.deployed_at(["~/services"]))
        self.assertIsNone(server.deployed_at("~/serv\x00ices"))

    def test_a_bad_marker_still_renders_the_grid(self):
        # The claim that actually matters, asserted end to end rather than on
        # the helper: `installed` reads the same field through marker_exists.
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": 1757550470,
             "setup": None}]})
        tiles = server.services_payload()["services"]
        self.assertEqual(len(tiles), 1)
        self.assertIsNone(tiles[0]["deployed_at"])
        self.assertFalse(tiles[0]["installed"])

    def test_tilde_is_expanded_like_everywhere_else(self):
        # Registry markers are written "~/services/immich"; this must read
        # the same path `installed` does.
        home = os.environ.get("HOME")
        os.environ["HOME"] = self.tmp
        try:
            self.marker("services", 1700000000.0)
            self.assertEqual(server.deployed_at("~/services"), 1700000000.0)
        finally:
            if home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = home

    def test_on_list_and_detail(self):
        deployed = self.marker("deployed", 1757550470.0)
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": deployed, "setup": None},
            {"key": "bravo", "name": "Bravo", "tagline": "t", "icon": "code",
             "url": None, "health": None,
             "marker": os.path.join(self.tmp, "never"), "setup": None},
        ]})
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertEqual(tiles["alpha"]["deployed_at"], 1757550470.0)
        self.assertIsNone(tiles["bravo"]["deployed_at"])
        self.assertEqual(server.service_detail("alpha")["deployed_at"],
                         1757550470.0)
        self.assertIsNone(server.service_detail("bravo")["deployed_at"])


# ------------------------------------------------------------ v3: resources
#
# Everything here runs against a fake cgroup tree under the sandbox
# (LAUNCHER_CGROUP_ROOT / server.CGROUP_ROOT), never /sys/fs/cgroup, and the
# one docker call is stubbed at subprocess.Popen like every other command in
# this file. The rules being defended: a part that cannot be read is null and
# never an error, docker being unavailable nulls container parts and changes
# nothing else, and cpu_pct is null until there are two samples.

CID = "a" * 64
OTHER_CID = "b" * 64


class ResourceTestBase(SandboxTest):

    def setUp(self):
        super().setUp()
        server.magicdns_host = lambda: "box.ts.net"
        server.probe_all = lambda urls: {u: False for u in urls}
        # Plain `docker ...` argv, so the assertions do not depend on whether
        # the user running the tests happens to be in the docker group.
        server._have_docker_group = lambda: True
        self.uid = os.getuid()

    # ---- fixture tree

    def unit_dir(self, name):
        path = os.path.join(server.CGROUP_ROOT, "user.slice",
                            "user-%d.slice" % self.uid,
                            "user@%d.service" % self.uid, "app.slice", name)
        os.makedirs(path, exist_ok=True)
        return path

    def container_dir(self, cid=CID):
        path = os.path.join(server.CGROUP_ROOT, "system.slice",
                            "docker-%s.scope" % cid)
        os.makedirs(path, exist_ok=True)
        return path

    def write_cgroup(self, path, rss=None, usage_usec=None):
        if rss is not None:
            with open(os.path.join(path, "memory.current"), "w") as fh:
                fh.write("%s\n" % rss)
        if usage_usec is not None:
            with open(os.path.join(path, "cpu.stat"), "w") as fh:
                fh.write("usage_usec %s\nuser_usec 1\nsystem_usec 2\n"
                         % usage_usec)

    def registry_with(self, control, key="svc", **extra):
        entry = {"key": key, "name": key, "tagline": "t", "icon": "code",
                 "url": None, "health": None, "marker": None, "setup": None,
                 "control": control}
        entry.update(extra)
        self.write_registry({"services": [entry]})
        return server.find_service(key)

    def set_cpus(self, count):
        real = os.cpu_count
        os.cpu_count = lambda: count
        self.addCleanup(setattr, os, "cpu_count", real)

    def measure(self, svc, now):
        """One measurement at an explicit clock reading — the mocked clock
        for every CPU assertion, with no patching of time.time itself."""
        return server._measure_resources(svc, now)


class ResourceReadingTest(ResourceTestBase):
    """What comes out of the fake sysfs tree."""

    def test_unit_part_reports_rss(self):
        self.write_cgroup(self.unit_dir("beszel-agent.service"), rss=4096)
        svc = self.registry_with({"parts": [{"unit": "beszel-agent.service"}]})
        out = self.measure(svc, 100.0)
        self.assertEqual(out["rss_bytes"], 4096)
        self.assertEqual(out["parts"], [
            {"name": "beszel-agent.service", "kind": "unit",
             "rss_bytes": 4096, "cpu_pct": None}])

    def test_container_part_reports_rss_through_the_docker_map(self):
        self.write_cgroup(self.container_dir(), rss=512000000)
        server.docker_name_map = lambda: {"n8n": CID}
        svc = self.registry_with({"parts": [{"container": "n8n"}]})
        out = self.measure(svc, 100.0)
        self.assertEqual(out["rss_bytes"], 512000000)
        self.assertEqual(out["parts"][0]["kind"], "container")

    def test_unreadable_part_is_null_and_the_rest_still_sum(self):
        self.write_cgroup(self.unit_dir("one.service"), rss=1000)
        self.write_cgroup(self.container_dir(), rss=2000)
        # three parts, and the middle one has no cgroup at all
        server.docker_name_map = lambda: {"c1": CID}
        svc = self.registry_with({"parts": [{"unit": "one.service"},
                                            {"unit": "gone.service"},
                                            {"container": "c1"}]})
        out = self.measure(svc, 100.0)
        self.assertEqual([p["rss_bytes"] for p in out["parts"]],
                         [1000, None, 2000])
        self.assertEqual(out["rss_bytes"], 3000)

    def test_no_part_readable_is_a_null_total(self):
        svc = self.registry_with({"parts": [{"unit": "gone.service"}]})
        out = self.measure(svc, 100.0)
        self.assertIsNone(out["rss_bytes"])
        self.assertIsNone(out["cpu_pct"])
        self.assertEqual(out["parts"],
                         [{"name": "gone.service", "kind": "unit",
                           "rss_bytes": None, "cpu_pct": None}])

    def test_garbage_in_a_cgroup_file_is_null_not_an_error(self):
        path = self.unit_dir("weird.service")
        self.write_cgroup(path, rss="not-a-number")
        with open(os.path.join(path, "cpu.stat"), "w") as fh:
            fh.write("nonsense\n")
        svc = self.registry_with({"parts": [{"unit": "weird.service"}]})
        out = self.measure(svc, 100.0)
        self.assertIsNone(out["parts"][0]["rss_bytes"])
        self.assertIsNone(out["parts"][0]["cpu_pct"])

    def test_a_service_with_no_control_block_has_no_parts(self):
        svc = self.registry_with(None)
        out = self.measure(svc, 100.0)
        self.assertEqual(out, {"rss_bytes": None, "cpu_pct": None,
                               "sampled_at": 100.0, "parts": []})

    def test_parts_follow_control_parts_in_order_and_kind(self):
        server.docker_name_map = lambda: {}
        svc = self.registry_with({"parts": [{"unit": "u.service"},
                                            {"container": "c1"},
                                            {"container": "c2"}]})
        out = self.measure(svc, 100.0)
        self.assertEqual([(p["name"], p["kind"]) for p in out["parts"]],
                         [("u.service", "unit"), ("c1", "container"),
                          ("c2", "container")])

    def test_every_key_is_always_present(self):
        svc = self.registry_with({"parts": [{"unit": "gone.service"}]})
        out = self.measure(svc, 100.0)
        self.assertEqual(sorted(out),
                         ["cpu_pct", "parts", "rss_bytes", "sampled_at"])
        self.assertEqual(sorted(out["parts"][0]),
                         ["cpu_pct", "kind", "name", "rss_bytes"])

    def test_a_container_id_that_is_not_a_container_id_is_ignored(self):
        # Nothing shaped unlike a docker id may be pasted into a path this
        # then opens.
        self.write_cgroup(self.container_dir("../../etc"), rss=1)
        server.docker_name_map = lambda: {"c1": "../../etc"}
        svc = self.registry_with({"parts": [{"container": "c1"}]})
        self.assertIsNone(self.measure(svc, 100.0)["parts"][0]["rss_bytes"])


class ResourceDockerMapTest(ResourceTestBase):
    """The one docker call, and what happens when it is not there."""

    def setUp(self):
        super().setUp()
        # SandboxTest stubs the map out so that no unrelated test can shell
        # out; these are the tests that put the real one back, over a stubbed
        # Popen.
        server.docker_name_map = self._saved["docker_name_map"]

    def test_map_parses_names_to_ids(self):
        self.stub_docker_ps("n8n\t%s\nbeszel\t%s\n" % (CID, OTHER_CID))
        self.assertEqual(server.docker_name_map(),
                         {"n8n": CID, "beszel": OTHER_CID})

    def test_argv_is_the_documented_command(self):
        self.stub_docker_ps("")
        server.docker_name_map()
        self.assertEqual(self.docker_calls, [[
            "docker", "ps", "-a", "--no-trunc",
            "--format", "{{.Names}}\t{{.ID}}"]])

    def test_argv_goes_through_sg_when_the_group_is_missing(self):
        server._have_docker_group = lambda: False
        server._which = lambda name: "/usr/bin/sg" if name == "sg" else None
        self.stub_docker_ps("")
        server.docker_name_map()
        argv = self.docker_calls[0]
        self.assertEqual(argv[:3], ["/usr/bin/sg", "docker", "-c"])
        self.assertIn("docker ps -a --no-trunc", argv[3])

    def test_one_cached_call_inside_the_ttl(self):
        self.stub_docker_ps("n8n\t%s\n" % CID)
        first = server.docker_name_map()
        second = server.docker_name_map()
        self.assertEqual(first, second)
        self.assertEqual(len(self.docker_calls), 1)

    def test_the_map_is_re_read_once_the_ttl_expires(self):
        server.DOCKER_MAP_TTL = 0.0
        self.stub_docker_ps("n8n\t%s\n" % CID)
        server.docker_name_map()
        server.docker_name_map()
        self.assertEqual(len(self.docker_calls), 2)

    def test_a_failure_is_cached_too(self):
        # With no docker group at all this must cost one failed call per TTL,
        # not one per container per request.
        self.stub_docker_ps("", code=1)
        server.docker_name_map()
        server.docker_name_map()
        self.assertEqual(len(self.docker_calls), 1)

    def test_nonzero_exit_gives_no_map(self):
        self.stub_docker_ps("n8n\t%s\n" % CID, code=1)
        self.assertEqual(server.docker_name_map(), {})

    def test_docker_missing_entirely_gives_no_map(self):
        self.stub_docker_ps(raises=FileNotFoundError("no docker"))
        self.assertEqual(server.docker_name_map(), {})

    def test_a_wedged_docker_is_killed_and_gives_no_map(self):
        self.stub_docker_ps(hangs=subprocess.TimeoutExpired("docker", 5))
        self.assertEqual(server.docker_name_map(), {})
        self.assertTrue(self.docker_procs[0].killed)

    def test_garbage_output_is_dropped_line_by_line(self):
        self.stub_docker_ps(
            "good\t%s\nnoseparator\nbad\tnothex\n\t%s\nalso\t%s\n"
            % (CID, CID, OTHER_CID))
        self.assertEqual(server.docker_name_map(),
                         {"good": CID, "also": OTHER_CID})

    def test_docker_failure_nulls_container_parts_and_nothing_else(self):
        # The rule that matters: no docker group, no daemon, no docker at
        # all — container resources go null and status is untouched.
        self.write_cgroup(self.unit_dir("u.service"), rss=64)
        self.stub_docker_ps(raises=FileNotFoundError("no docker"))
        self.write_registry({"services": [
            {"key": "svc", "name": "Svc", "tagline": "t", "icon": "code",
             "url": None, "health": "http://127.0.0.1:9/h",
             "marker": self.tmp, "setup": None,
             "control": {"parts": [{"container": "c1"},
                                   {"unit": "u.service"}]}},
        ]})
        server.probe_all = lambda urls: {u: True for u in urls}
        tile = server.services_payload()["services"][0]
        self.assertEqual([p["rss_bytes"] for p in tile["resources"]["parts"]],
                         [None, 64])
        self.assertEqual(tile["resources"]["rss_bytes"], 64)
        # status, state and the control block are exactly what they were
        self.assertEqual(tile["state"], "active")
        self.assertTrue(tile["active"])
        self.assertTrue(tile["installed"])
        self.assertEqual(tile["control"], {"controllable": True,
                                           "reason": None})

    def test_a_unit_only_service_never_shells_out(self):
        self.write_cgroup(self.unit_dir("u.service"), rss=64)
        self.stub_docker_ps("")
        svc = self.registry_with({"parts": [{"unit": "u.service"}]})
        self.assertEqual(self.measure(svc, 100.0)["rss_bytes"], 64)
        self.assertEqual(self.docker_calls, [])


class ResourceCpuTest(ResourceTestBase):
    """cpu_pct: percent of the whole machine, across two samples."""

    def setUp(self):
        super().setUp()
        self.set_cpus(4)
        self.path = self.unit_dir("u.service")
        self.svc = self.registry_with({"parts": [{"unit": "u.service"}]})

    def sample(self, usage_usec, now):
        self.write_cgroup(self.path, rss=10, usage_usec=usage_usec)
        return self.measure(self.svc, now)["parts"][0]["cpu_pct"]

    def test_first_sample_is_null(self):
        self.assertIsNone(self.sample(1_000_000, 1000.0))

    def test_second_sample_is_percent_of_the_whole_machine(self):
        self.sample(1_000_000, 1000.0)
        # 2s of CPU over 1s of wall on 4 cores = half the machine
        self.assertAlmostEqual(self.sample(3_000_000, 1001.0), 50.0)

    def test_a_single_busy_core_is_a_quarter_of_four(self):
        self.sample(0, 1000.0)
        self.assertAlmostEqual(self.sample(1_000_000, 1001.0), 25.0)

    def test_it_is_clamped_to_100(self):
        self.sample(0, 1000.0)
        # 100s of CPU in 1s of wall: impossible, and must not render as
        # 10000%.
        self.assertEqual(self.sample(100_000_000, 1001.0), 100.0)

    def test_a_counter_reset_is_zero_not_negative(self):
        self.sample(5_000_000, 1000.0)
        self.assertEqual(self.sample(1_000_000, 1001.0), 0.0)

    def test_no_wall_time_between_samples_is_null(self):
        self.sample(1_000_000, 1000.0)
        self.assertIsNone(self.sample(2_000_000, 1000.0))

    def test_the_sample_is_dropped_when_the_cgroup_goes_away(self):
        self.sample(1_000_000, 1000.0)
        os.unlink(os.path.join(self.path, "cpu.stat"))
        self.assertIsNone(self.measure(self.svc, 1001.0)["parts"][0]["cpu_pct"])
        # coming back must start counting again rather than differencing
        # against a counter from before the restart
        self.assertIsNone(self.sample(9_000_000, 1002.0))
        self.assertAlmostEqual(self.sample(10_000_000, 1003.0), 25.0)

    def test_the_service_total_sums_its_parts_and_is_clamped(self):
        other = self.unit_dir("v.service")
        svc = self.registry_with({"parts": [{"unit": "u.service"},
                                            {"unit": "v.service"}]})
        self.write_cgroup(self.path, rss=1, usage_usec=0)
        self.write_cgroup(other, rss=2, usage_usec=0)
        self.assertIsNone(self.measure(svc, 1000.0)["cpu_pct"])
        self.write_cgroup(self.path, rss=1, usage_usec=1_000_000)
        self.write_cgroup(other, rss=2, usage_usec=1_000_000)
        out = self.measure(svc, 1001.0)
        self.assertAlmostEqual(out["cpu_pct"], 50.0)   # 25 + 25
        self.assertEqual(out["rss_bytes"], 3)

    def test_a_service_total_above_the_machine_is_clamped(self):
        # Three parts at a legal 60% each; the sum is not legal, and must
        # read as "the whole machine", never as 180%.
        names = ["p%d.service" % i for i in range(3)]
        dirs = [self.unit_dir(n) for n in names]
        svc = self.registry_with({"parts": [{"unit": n} for n in names]})
        for path in dirs:
            self.write_cgroup(path, rss=1, usage_usec=0)
        self.assertIsNone(self.measure(svc, 1000.0)["cpu_pct"])
        for path in dirs:
            self.write_cgroup(path, rss=1, usage_usec=2_400_000)
        out = self.measure(svc, 1001.0)
        self.assertEqual([round(p["cpu_pct"]) for p in out["parts"]],
                         [60, 60, 60])
        self.assertEqual(out["cpu_pct"], 100.0)

    def test_cpu_is_null_when_there_is_no_cgroup_at_all(self):
        svc = self.registry_with({"parts": [{"unit": "gone.service"}]})
        self.assertIsNone(self.measure(svc, 1000.0)["parts"][0]["cpu_pct"])
        self.assertIsNone(self.measure(svc, 1001.0)["parts"][0]["cpu_pct"])


class ResourceCacheTest(ResourceTestBase):
    """The TTL that stops a grid full of tiles hammering sysfs."""

    def setUp(self):
        super().setUp()
        self.path = self.unit_dir("u.service")
        self.write_cgroup(self.path, rss=2048, usage_usec=1)
        self.svc = self.registry_with({"parts": [{"unit": "u.service"}]})
        self.reads = []
        real = server._read_rss
        server._read_rss = lambda cgroup: (self.reads.append(cgroup),
                                           real(cgroup))[1]
        self.addCleanup(setattr, server, "_read_rss", real)

    def test_two_calls_inside_the_ttl_read_sysfs_once(self):
        first = server.service_resources(self.svc)
        second = server.service_resources(self.svc)
        self.assertEqual(len(self.reads), 1)
        self.assertIs(first, second)

    def test_the_cached_answer_survives_the_file_disappearing(self):
        # The same claim without counting anything: nothing was re-read.
        first = server.service_resources(self.svc)
        os.unlink(os.path.join(self.path, "memory.current"))
        self.assertEqual(server.service_resources(self.svc)["rss_bytes"],
                         first["rss_bytes"])

    def test_an_expired_entry_is_re_measured(self):
        server.RESOURCE_TTL = 0.0
        server.service_resources(self.svc)
        server.service_resources(self.svc)
        self.assertEqual(len(self.reads), 2)

    def test_the_cache_is_per_service(self):
        other = self.registry_with({"parts": [{"unit": "u.service"}]},
                                   key="other")
        server.service_resources(self.svc)
        server.service_resources(other)
        self.assertEqual(len(self.reads), 2)

    def test_the_sample_clock_is_taken_after_the_docker_call(self):
        # `docker ps` runs OUTSIDE the lock and can block for up to
        # DOCKER_MAP_TIMEOUT against a wedged daemon. Stamping the sample
        # with the time the request ARRIVED shrinks the wall delta that
        # _cpu_percent divides by, so a service at 40% reads 100%, and it
        # stamps the cache entry already-expired once the block outlasts
        # RESOURCE_TTL, making every later request re-measure.
        self.write_cgroup(self.container_dir(), rss=4096, usage_usec=1)
        svc = self.registry_with({"parts": [{"container": "c"}]}, key="cs")

        def slow_map():
            time.sleep(0.05)
            return {"c": CID}

        server.docker_name_map = slow_map
        entered = time.time()
        out = server.service_resources(svc)
        self.assertGreaterEqual(out["sampled_at"], entered + 0.05)

    def test_sampled_at_is_when_the_sample_was_taken(self):
        before = time.time()
        out = server.service_resources(self.svc)
        self.assertTrue(before <= out["sampled_at"] <= time.time())
        time.sleep(0.02)
        self.assertEqual(server.service_resources(self.svc)["sampled_at"],
                         out["sampled_at"])

    def test_a_broken_measurement_is_nulls_not_a_500(self):
        boom = server._measure_resources
        server._measure_resources = lambda svc, now, docker_map: (
            _ for _ in ()).throw(RuntimeError("sysfs on fire"))
        self.addCleanup(setattr, server, "_measure_resources", boom)
        out = server.service_resources(self.svc)
        self.assertEqual(sorted(out),
                         ["cpu_pct", "parts", "rss_bytes", "sampled_at"])
        self.assertEqual(out["parts"], [])
        self.assertIsNone(out["rss_bytes"])


class ResourcePayloadTest(ResourceTestBase):
    """The three v3 keys on the list and the detail object, over a socket."""

    def setUp(self):
        super().setUp()
        import threading
        self.write_cgroup(self.unit_dir("u.service"), rss=4096, usage_usec=1)
        self.write_registry({"services": [
            {"key": "svc", "name": "Svc", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None,
             "control": {"parts": [{"unit": "u.service"}]}},
            {"key": "bare", "name": "Bare", "tagline": "t", "icon": "code",
             "url": None, "health": None, "marker": None, "setup": None},
        ]})
        self.srv = server.Server(("127.0.0.1", 0), server.Handler)
        self.port = self.srv.server_address[1]
        self.thread = threading.Thread(target=self.srv.serve_forever,
                                       daemon=True)
        self.thread.start()

    def tearDown(self):
        self.srv.shutdown()
        self.srv.server_close()
        super().tearDown()

    def get(self, path):
        import http.client
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request("GET", path)
        resp = conn.getresponse()
        data = resp.read().decode()
        status = resp.status
        conn.close()
        return status, json.loads(data)

    def test_list_carries_all_three_keys_for_every_service(self):
        status, doc = self.get("/api/services")
        self.assertEqual(status, 200)
        for tile in doc["services"]:
            self.assertEqual(sorted(tile["usage"]),
                             ["last_launched", "last_opened", "last_used"])
            self.assertIn("deployed_at", tile)
            self.assertEqual(sorted(tile["resources"]),
                             ["cpu_pct", "parts", "rss_bytes", "sampled_at"])
        tiles = {t["key"]: t for t in doc["services"]}
        self.assertEqual(tiles["svc"]["resources"]["rss_bytes"], 4096)
        self.assertEqual(tiles["bare"]["resources"]["parts"], [])
        self.assertIsNone(tiles["bare"]["resources"]["rss_bytes"])

    def test_detail_carries_the_same_block(self):
        status, doc = self.get("/api/services/svc")
        self.assertEqual(status, 200)
        self.assertEqual(doc["resources"]["rss_bytes"], 4096)
        self.assertEqual(doc["resources"]["parts"][0]["kind"], "unit")
        self.assertEqual(sorted(doc["usage"]),
                         ["last_launched", "last_opened", "last_used"])
        self.assertIn("deployed_at", doc)

    def test_a_missing_cgroup_root_entirely_is_still_a_200(self):
        # /sys/fs/cgroup not being there at all (a container, a mac) must
        # look like "no numbers", not like a broken launcher.
        server.CGROUP_ROOT = os.path.join(self.tmp, "no-such-root")
        self.reset_resource_caches()
        status, doc = self.get("/api/services")
        self.assertEqual(status, 200)
        tiles = {t["key"]: t for t in doc["services"]}
        self.assertIsNone(tiles["svc"]["resources"]["rss_bytes"])
        self.assertEqual(tiles["svc"]["state"], "planned")



class ExitedProc:
    """A deploy that has already finished with `code`."""

    def __init__(self, code):
        self.code = code
        self.pid = 4242

    def wait(self, timeout=None):
        return self.code


class HungProc:
    """A stop guard that never answers: wait(timeout) always times out, and
    only a plain wait() (after the group kill) returns."""

    def __init__(self, argv):
        self.argv = argv
        self.pid = 31337
        self.timeouts = []

    def wait(self, timeout=None):
        if timeout is not None:
            self.timeouts.append(timeout)
            raise subprocess.TimeoutExpired(self.argv, timeout)
        return -9


SHA_A = "a" * 40
SHA_B = "b" * 40


class ReceiptTest(SandboxTest):

    def setUp(self):
        super().setUp()
        self.make_script("alpha/setup.sh")
        self.make_env("alpha/.env", "\n".join([
            "LOCAL_PORT=2283",
            "HTTPS_PORT=8443",
            "SECRET_PORT=9999",        # looks secret: never copied
            "ODD_PORT=not-a-number",
            "BIG_PORT=70000",
            "DB_PASSWORD=%s" % SECRET_VALUE,
            "",
        ]))
        self.make_script("bare/setup.sh")
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": "~/services/alpha",
             "setup": "alpha/setup.sh", "env": "alpha/.env"},
            {"key": "bare", "name": "Bare", "tagline": "t", "icon": "cpu",
             "url": None, "health": None, "marker": None,
             "setup": "bare/setup.sh", "env": None},
        ]})
        self.times = iter(["2026-10-25T01:00:00.000Z", "2026-10-26T02:00:00.000Z",
                           "2026-10-27T03:00:00.000Z"])
        server._now_iso = lambda: next(self.times)

    def make_git(self, root, head="ref: refs/heads/main", refs=None, packed=None):
        git = os.path.join(root, ".git")
        os.makedirs(git, exist_ok=True)
        with open(os.path.join(git, "HEAD"), "w") as fh:
            fh.write(head + "\n")
        for ref, sha in (refs or {}).items():
            path = os.path.join(git, ref)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as fh:
                fh.write(sha + "\n")
        if packed:
            with open(os.path.join(git, "packed-refs"), "w") as fh:
                fh.write("# pack-refs with: peeled fully-peeled sorted\n")
                for ref, sha in packed.items():
                    fh.write("%s %s\n" % (sha, ref))
        return git

    def finish(self, key, code=0):
        job = server.register_job(key, "deploy")
        logfile = open(job["log_path"], "wb")
        server._reap(job, ExitedProc(code), logfile)
        return job

    def test_receipt_names_what_ran_not_what_is_there_now(self):
        # start_deploy freezes revision + setup; a pull and a registry edit
        # before the job finishes must not leak into the receipt.
        self.make_git(self.repo, refs={"refs/heads/main": SHA_A})
        # FakeProc never exits, so the only reap is the one below.
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        job_id = server.start_deploy("alpha")
        self.make_git(self.repo, refs={"refs/heads/main": SHA_B})
        self.make_script("moved/setup.sh")
        self.write_registry({"services": [
            {"key": "alpha", "name": "Alpha", "tagline": "t", "icon": "camera",
             "url": None, "health": None, "marker": "~/elsewhere",
             "setup": "moved/setup.sh", "env": "alpha/.env"}]})
        job = server._jobs[job_id]
        server._reap(job, ExitedProc(0), open(os.devnull, "wb"))
        r = server.load_receipt("alpha")
        self.assertEqual(r["revision"], SHA_A)
        self.assertEqual(r["setup"], "alpha/setup.sh")
        self.assertEqual(r["data_dir"], "~/services/alpha")
        self.assertEqual(r["ports"]["LOCAL_PORT"], 2283)
        self.assertEqual(r["deploys"], 1)

    def test_success_writes_a_receipt(self):
        self.make_git(self.repo, refs={"refs/heads/main": SHA_A})
        job = self.finish("alpha")
        r = server.load_receipt("alpha")
        self.assertEqual(r["version"], 1)
        self.assertEqual(r["key"], "alpha")
        self.assertEqual(r["repo"], os.path.realpath(self.repo))
        self.assertEqual(r["revision"], SHA_A)
        self.assertEqual(r["setup"], "alpha/setup.sh")
        self.assertEqual(r["data_dir"], "~/services/alpha")
        self.assertEqual(r["installed_at"], "2026-10-25T01:00:00.000Z")
        self.assertEqual(r["deployed_at"], r["installed_at"])
        self.assertEqual(r["deploys"], 1)
        self.assertEqual(r["last_job"], job["id"])
        self.assertEqual(server._jobs[job["id"]]["status"], "done")

    def test_ports_are_whole_numbers_and_never_secret(self):
        self.finish("alpha")
        self.assertEqual(server.load_receipt("alpha")["ports"],
                         {"LOCAL_PORT": 2283, "HTTPS_PORT": 8443})
        with open(server.receipt_path("alpha"), encoding="utf-8") as fh:
            self.assertNotIn(SECRET_VALUE, fh.read())

    def test_no_env_means_no_ports(self):
        self.finish("bare")
        self.assertEqual(server.load_receipt("bare")["ports"], {})

    def test_failed_deploy_writes_nothing(self):
        job = self.finish("alpha", code=1)
        self.assertIsNone(server.load_receipt("alpha"))
        self.assertEqual(server._jobs[job["id"]]["status"], "failed")

    def test_redeploy_keeps_first_install_and_counts(self):
        self.finish("alpha")
        self.finish("alpha")
        r = server.load_receipt("alpha")
        self.assertEqual(r["installed_at"], "2026-10-25T01:00:00.000Z")
        self.assertEqual(r["deployed_at"], "2026-10-26T02:00:00.000Z")
        self.assertEqual(r["deploys"], 2)

    def test_garbage_deploy_count_restarts_at_one(self):
        os.makedirs(server.INSTANCES_DIR)
        with open(server.receipt_path("alpha"), "w") as fh:
            json.dump({"key": "alpha", "deploys": "lots", "installed_at": "2026-01-01"}, fh)
        self.finish("alpha")
        r = server.load_receipt("alpha")
        self.assertEqual(r["deploys"], 1)
        self.assertEqual(r["installed_at"], "2026-01-01")

    def test_unwritable_receipt_does_not_fail_the_deploy(self):
        os.makedirs(os.path.dirname(server.INSTANCES_DIR), exist_ok=True)
        with open(server.INSTANCES_DIR, "w") as fh:   # a file where the dir goes
            fh.write("x")
        job = self.finish("alpha")
        self.assertEqual(server._jobs[job["id"]]["status"], "done")
        self.assertIsNone(server.load_receipt("alpha"))

    def test_no_git_means_null_repo_and_revision(self):
        self.finish("alpha")
        r = server.load_receipt("alpha")
        # The sandbox may sit inside some other checkout; either way no sha
        # from this sandbox repo can appear.
        self.assertNotEqual(r["revision"], SHA_A)

    def test_unreadable_receipts_are_none(self):
        os.makedirs(server.INSTANCES_DIR)
        with open(server.receipt_path("alpha"), "w") as fh:
            fh.write("{not json")
        self.assertIsNone(server.load_receipt("alpha"))
        with open(server.receipt_path("alpha"), "w") as fh:
            json.dump({"key": "someone-else"}, fh)
        self.assertIsNone(server.load_receipt("alpha"))
        with open(server.receipt_path("alpha"), "w") as fh:
            json.dump(["alpha"], fh)
        self.assertIsNone(server.load_receipt("alpha"))

    def test_path_shaped_keys_have_no_receipt_path(self):
        for evil in ("../alpha", "a/b", "", "Alpha", ".hidden", None, 3):
            self.assertIsNone(server.receipt_path(evil), evil)
            self.assertIsNone(server.load_receipt(evil))

    def test_detail_carries_the_receipt(self):
        server.magicdns_host = lambda: "box.ts.net"
        self.assertIsNone(server.service_detail("alpha")["receipt"])
        self.finish("alpha")
        self.assertEqual(server.service_detail("alpha")["receipt"]["deploys"], 1)

    def test_list_payload_carries_the_receipt(self):
        server.magicdns_host = lambda: "box.ts.net"
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertIsNone(tiles["alpha"]["receipt"])
        self.finish("alpha")
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertEqual(tiles["alpha"]["receipt"]["installed_at"], "2026-10-25T01:00:00.000Z")
        self.assertIsNone(tiles["bare"]["receipt"])

    def test_receipt_does_not_change_tile_state(self):
        server.magicdns_host = lambda: "box.ts.net"
        self.finish("alpha")
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertFalse(tiles["alpha"]["installed"])
        self.assertEqual(tiles["alpha"]["state"], "available")

    # ---- git_revision

    def test_revision_from_a_loose_ref(self):
        self.make_git(self.repo, refs={"refs/heads/main": SHA_A})
        self.assertEqual(server.git_revision(self.repo), SHA_A)

    def test_revision_from_packed_refs(self):
        self.make_git(self.repo, packed={"refs/heads/main": SHA_B})
        self.assertEqual(server.git_revision(self.repo), SHA_B)

    def test_revision_of_a_detached_head(self):
        self.make_git(self.repo, head=SHA_B)
        self.assertEqual(server.git_revision(self.repo), SHA_B)

    def test_revision_of_a_worktree(self):
        main = os.path.join(self.tmp, "main")
        git = self.make_git(main, refs={"refs/heads/feature": SHA_B})
        wt_git = os.path.join(git, "worktrees", "wt")
        os.makedirs(wt_git)
        with open(os.path.join(wt_git, "HEAD"), "w") as fh:
            fh.write("ref: refs/heads/feature\n")
        with open(os.path.join(wt_git, "commondir"), "w") as fh:
            fh.write("../..\n")
        wt = os.path.join(self.tmp, "wt")
        os.makedirs(wt)
        with open(os.path.join(wt, ".git"), "w") as fh:
            fh.write("gitdir: %s\n" % wt_git)
        self.assertEqual(server.git_revision(wt), SHA_B)

    def test_revision_garbage_is_none(self):
        self.make_git(self.repo, head="ref: refs/heads/main", refs={"refs/heads/main": "zzz"})
        self.assertIsNone(server.git_revision(self.repo))
        self.make_git(self.repo, head="nonsense")
        self.assertIsNone(server.git_revision(self.repo))
        self.assertIsNone(server.git_revision(os.path.join(self.tmp, "nowhere")))

    def test_collapse_home(self):
        home = os.path.expanduser("~")
        self.assertEqual(server._collapse_home(os.path.join(home, "dev", "x")), "~/dev/x")
        self.assertEqual(server._collapse_home(home + "-other/x"), home + "-other/x")



class RemoveTest(ControlTestBase):
    """The Remove action: Kuma pause, then the service's teardown.sh."""

    def control_registry(self):
        self.marker = os.path.join(self.tmp, "data", "n8n")
        os.makedirs(self.marker)
        for key in ("n8n", "bare", "launcher", "ntfy", "adguard"):
            self.make_script("%s/setup.sh" % key)
        for key in ("n8n", "launcher", "ntfy", "adguard"):
            self.make_script("%s/teardown.sh" % key)

        def svc(key, control, marker=None, health=None):
            return {"key": key, "name": key, "tagline": "t", "icon": "code",
                    "url": None, "health": health, "marker": marker,
                    "setup": "%s/setup.sh" % key, "env": None, "control": control}
        return {"services": [
            svc("n8n", {"parts": [{"container": "n8n"}], "kuma": "n8n"},
                marker=self.marker),
            svc("bare", {"parts": [{"container": "bare"}], "kuma": None},
                marker=self.marker),
            svc("adguard", {"parts": [{"container": "adguard"}],
                            "kuma": ["adguard", "adguard-dns"]},
                marker=self.marker),
            svc("launcher", {"parts": [{"unit": "launcher.service"}]},
                marker=self.marker),
            svc("ntfy", {"locked": "ntfy is how you start things again"},
                marker=self.marker),
        ]}

    def tiles(self):
        return {s["key"]: s for s in server.services_payload()["services"]}

    def test_removable_needs_a_teardown_and_control(self):
        tiles = self.tiles()
        self.assertTrue(tiles["n8n"]["removable"])
        self.assertFalse(tiles["bare"]["removable"])       # no teardown.sh
        self.assertFalse(tiles["launcher"]["removable"])   # hard-locked
        self.assertFalse(tiles["ntfy"]["removable"])       # registry-locked
        self.assertTrue(server.service_detail("n8n")["removable"])

    def test_plan_pauses_kuma_then_runs_teardown_without_purge(self):
        self.enable_kuma()
        argvs = self.plan("n8n", "remove")
        self.assertEqual(argvs[0][-2:], ["pause", "n8n"])
        teardown = os.path.realpath(os.path.join(self.repo, "n8n", "teardown.sh"))
        self.assertEqual(argvs[1], [teardown])
        self.assertEqual(argvs[2][-2:], ["resume", "n8n"])   # failure-only
        self.assertEqual(len(argvs), 3)
        steps = server.plan_action(server.find_service("n8n"), "remove")
        self.assertTrue(steps[2]["on_failure"])
        self.assertNotIn("--purge", " ".join(" ".join(a) for a in argvs))

    def test_plan_without_kuma_is_just_teardown(self):
        argvs = self.plan("n8n", "remove")
        self.assertEqual(len(argvs), 1)
        self.assertTrue(argvs[0][0].endswith("teardown.sh"))

    def test_no_teardown_is_403(self):
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("bare", "remove")
        self.assertEqual(ctx.exception.status, 403)
        self.assertIn("teardown.sh", ctx.exception.message)

    def test_locked_services_are_403(self):
        for key in ("launcher", "ntfy"):
            with self.assertRaises(server.DeployError) as ctx:
                server.start_action(key, "remove")
            self.assertEqual(ctx.exception.status, 403, key)

    def test_not_installed_is_409(self):
        os.rmdir(self.marker)
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("n8n", "remove")
        self.assertEqual(ctx.exception.status, 409)

    def test_success_marks_removed_and_tile_reads_not_installed(self):
        self.assertEqual(self.tiles()["n8n"]["state"], "stopped")
        job = self.run_action("n8n", "remove")
        self.assertEqual(job["status"], "done")
        self.assertEqual(job["action"], "remove")
        self.assertTrue(server.load_receipt("n8n")["removed_at"])
        tile = self.tiles()["n8n"]
        self.assertFalse(tile["installed"])
        self.assertEqual(tile["state"], "available")
        self.assertTrue(os.path.isdir(self.marker))       # data kept
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("n8n", "remove")          # already removed
        self.assertEqual(ctx.exception.status, 409)

    def test_success_does_not_resume_kuma(self):
        self.enable_kuma()
        job = self.run_action("n8n", "remove")
        self.assertEqual(job["status"], "done")
        self.assertEqual(self.argvs()[0][-2:], ["pause", "n8n"])
        self.assertFalse(any(a[-2:] == ["resume", "n8n"] for a in self.argvs()))

    def test_failed_teardown_resumes_kuma(self):
        self.enable_kuma()
        job = self.run_action("n8n", "remove", failures={"teardown.sh": 3})
        self.assertEqual(job["status"], "failed")
        self.assertEqual(self.argvs()[-1][-2:], ["resume", "n8n"])

    def test_failed_reinstall_resume_is_logged(self):
        self.enable_kuma()
        self.run_action("n8n", "remove")
        self.record_popen(failures={"resume": 2})
        job = server.register_job("n8n", "deploy")
        with open(job["log_path"], "wb") as fh:
            fh.write(b"deploy output\n")
        server._reap(job, ExitedProc(0), open(os.devnull, "wb"))
        with open(job["log_path"], encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("deploy output", text)
        self.assertIn("still paused", text)
        self.assertNotIn(SECRET_VALUE, text)

    def test_remove_pauses_every_monitor_then_tears_down(self):
        self.enable_kuma()
        argvs = self.plan("adguard", "remove")
        self.assertEqual([a[-2:] for a in argvs[:2]],
                         [["pause", "adguard"], ["pause", "adguard-dns"]])
        self.assertTrue(argvs[2][0].endswith("adguard/teardown.sh"))
        self.assertEqual([a[-2:] for a in argvs[3:]],
                         [["resume", "adguard"], ["resume", "adguard-dns"]])
        steps = server.plan_action(server.find_service("adguard"), "remove")
        self.assertEqual([bool(s.get("on_failure")) for s in steps],
                         [False, False, False, True, True])

    def test_successful_remove_leaves_every_monitor_paused(self):
        self.enable_kuma()
        job = self.run_action("adguard", "remove")
        self.assertEqual(job["status"], "done")
        self.assertFalse(any(a[-2:-1] == ["resume"] for a in self.argvs()))

    def test_failed_teardown_resumes_every_monitor(self):
        self.enable_kuma()
        job = self.run_action("adguard", "remove",
                              failures={"teardown.sh": 3})
        self.assertEqual(job["status"], "failed")
        self.assertEqual([a[-2:] for a in self.argvs()[-2:]],
                         [["resume", "adguard"], ["resume", "adguard-dns"]])

    def test_reinstall_resumes_every_monitor_and_logs_each_failure(self):
        self.enable_kuma()
        self.run_action("adguard", "remove")
        self.record_popen(failures={"resume adguard-dns": 2})
        job = server.register_job("adguard", "deploy")
        with open(job["log_path"], "wb") as fh:
            fh.write(b"deploy output\n")
        server._reap(job, ExitedProc(0), open(os.devnull, "wb"))
        resumes = [a[-1] for a in self.argvs() if a[-2:-1] == ["resume"]]
        self.assertEqual(resumes, ["adguard", "adguard-dns"])
        with open(job["log_path"], encoding="utf-8") as fh:
            text = fh.read()
        self.assertIn("monitor adguard-dns is still paused", text)
        self.assertNotIn("monitor adguard is still paused", text)
        self.assertNotIn(SECRET_VALUE, text)

    def test_failed_teardown_records_nothing(self):
        job = self.run_action("n8n", "remove", failures={"teardown.sh": 3})
        self.assertEqual(job["status"], "failed")
        self.assertIsNone(server.load_receipt("n8n"))
        self.assertTrue(self.tiles()["n8n"]["installed"])

    def test_a_running_service_is_never_called_removed(self):
        self.run_action("n8n", "remove")
        self.assertTrue(server.is_removed(server.load_receipt("n8n"), False))
        self.assertFalse(server.is_removed(server.load_receipt("n8n"), True))
        self.assertFalse(server.is_removed(None, False))

    def test_reinstall_clears_removal_and_resumes_kuma(self):
        self.enable_kuma()
        self.run_action("n8n", "remove")
        self.spawned = []
        job = server.register_job("n8n", "deploy")
        server._reap(job, ExitedProc(0), open(os.devnull, "wb"))
        r = server.load_receipt("n8n")
        self.assertNotIn("removed_at", r)
        self.assertEqual(r["deploys"], 1)
        self.assertEqual(self.argvs()[-1][-2:], ["resume", "n8n"])
        self.assertTrue(self.tiles()["n8n"]["installed"])

    def test_plain_redeploy_does_not_touch_kuma(self):
        self.enable_kuma()
        self.record_popen()
        job = server.register_job("n8n", "deploy")
        server._reap(job, ExitedProc(0), open(os.devnull, "wb"))
        self.assertEqual(self.argvs(), [])


if __name__ == "__main__":
    unittest.main()
