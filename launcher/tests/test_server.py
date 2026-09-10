"""Mocked unit tests for the launcher backend.

No network, no subprocesses, no writes outside a temp dir: every probe and
every Popen is stubbed, and REPO_ROOT / JOBS_DIR / the registry are pointed
at a sandbox. Run from launcher/:

    python3 -m unittest discover -s tests -p 'test_*.py'
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import server  # noqa: E402


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
        # Never the real ~/services/launcher/overrides.json or notes.json.
        server.OVERRIDES_PATH = os.path.join(self.tmp, "state", "overrides.json")
        server.NOTES_PATH = os.path.join(self.tmp, "state", "notes.json")

        self.write_registry(self.REGISTRY)
        server._registry_cache["mtime"] = None
        server._registry_cache["data"] = None
        server._probe_cache.clear()
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
        shutil.rmtree(self.tmp, ignore_errors=True)

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
        path = self.make_script("beszel/setup.sh")
        got = server.resolve_script({"setup": "beszel/setup.sh"})
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
                         ["action", "exit_code", "key", "log", "status"])
        self.assertEqual(payload["action"], "deploy")
        self.assertEqual(payload["key"], "alpha")
        self.assertEqual(payload["status"], "running")
        self.assertIsNone(server.job_payload("does-not-exist"))


# ---------------------------------------------------------------- job field

class ServiceJobFieldTest(SandboxTest):
    """`job` on each service: what lets a reopened tile reattach to a deploy."""

    # The identity fields, in payload order. `description` joined them so the
    # grid's hover tooltip does not have to fetch each service individually.
    EIGHT = ["key", "name", "tagline", "description", "icon", "url", "state",
             "installed", "active"]

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

    def test_no_field_beyond_job_and_control_was_added(self):
        server.start_deploy("alpha")
        for tile in self.tiles().values():
            self.assertEqual(list(tile), self.EIGHT + ["job", "control"])

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
        self.assertEqual(sorted(svc), ["active", "control", "description",
                                       "icon", "installed", "job", "key",
                                       "name", "state", "tagline", "url"])
        self.assertEqual(svc["url"], "https://box.ts.net:1/")
        self.assertIsNone(svc["job"])

    def test_services_field_order_is_stable(self):
        # The frontend reads these positionally in places. `description` sits
        # next to the other identity fields (the grid tooltip needs it here,
        # not only on the detail page); `job` and `control` stay appended last.
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(list(doc["services"][0]),
                         ["key", "name", "tagline", "description", "icon",
                          "url", "state", "installed", "active", "job",
                          "control"])

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
        self.assertIn("web/", body)
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
            "active", "control", "description", "env", "icon", "installed",
            "job", "key", "meta", "name", "state", "tagline", "url"])
        self.assertEqual(detail["key"], "alpha")
        self.assertEqual(detail["name"], "Alpha")
        self.assertEqual(detail["description"], "Shipped description.")
        self.assertEqual(detail["url"], "https://box.ts.net:2283/")
        self.assertEqual(detail["state"], "available")

    def test_includes_the_nine_list_fields_verbatim(self):
        detail = server.service_detail("alpha")
        tile = {s["key"]: s for s in server.services_payload()["services"]}["alpha"]
        for field in ("key", "name", "tagline", "icon", "url", "state",
                      "installed", "active", "job", "control"):
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

    def wait(self):
        return self.code


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

    def record_popen(self, failures=None):
        """Patch Popen to record argv and hand back canned exit codes.

        `failures` maps a substring of the joined argv to the exit code that
        invocation should report.
        """
        failures = dict(failures or {})

        def fake(argv, **kwargs):
            self.spawned.append((list(argv), kwargs))
            joined = " ".join(argv)
            for needle, code in failures.items():
                if needle in joined:
                    return RecordedProc(code)
            return RecordedProc(0)

        subprocess.Popen = fake

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
        """Give the sandbox a working kuma_toggle.py + monitoring/.env."""
        toggle = os.path.join(self.repo, "ntfy-control", "kuma_toggle.py")
        os.makedirs(os.path.dirname(toggle), exist_ok=True)
        with open(toggle, "w", encoding="utf-8") as fh:
            fh.write("# fixture\n")
        env_path = os.path.join(self.repo, "monitoring", ".env")
        os.makedirs(os.path.dirname(env_path), exist_ok=True)
        with open(env_path, "w", encoding="utf-8") as fh:
            fh.write("KUMA_PORT=3002\nKUMA_ADMIN_USER=kai\n"
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
        self.assertIsNone(server.control_monitor({"kuma": "a; curl evil"}))
        self.assertIsNone(server.control_monitor({"kuma": None}))
        self.assertEqual(server.control_monitor({"kuma": "immich"}), "immich")


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
        os.unlink(os.path.join(self.repo, "ntfy-control", "kuma_toggle.py"))
        self.assertEqual(self.plan("n8n", "stop"), [["docker", "stop", "n8n"]])

    def test_no_kuma_step_when_monitoring_env_is_missing(self):
        self.enable_kuma()
        os.unlink(os.path.join(self.repo, "monitoring", ".env"))
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

    def test_action_shows_on_the_tile_like_a_deploy_does(self):
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        job_id = server.start_action("n8n", "stop")
        tiles = {s["key"]: s for s in server.services_payload()["services"]}
        self.assertEqual(tiles["n8n"]["job"],
                         {"id": job_id, "status": "running", "action": "stop"})

    def test_a_deploy_and_an_action_share_the_per_key_slot(self):
        self.make_script("n8n/setup.sh")
        registry = self.control_registry()
        for svc in registry["services"]:
            if svc["key"] == "n8n":
                svc["setup"] = "n8n/setup.sh"
        self.write_registry(registry)
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        server.start_deploy("n8n")
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("n8n", "stop")
        self.assertEqual(ctx.exception.status, 409)

    def test_actions_respect_the_global_cap(self):
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        server.start_action("n8n", "stop")
        server.start_action("manimkc", "stop")
        with self.assertRaises(server.DeployError) as ctx:
            server.start_action("immich", "stop")
        self.assertEqual(ctx.exception.status, 429)


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

class SharedControlRegistryTest(unittest.TestCase):
    """The real services.json — the file BOTH front ends read.

    These assertions are the anti-drift guarantee: the phone listener and the
    web UI are checked against the same file, in the same test run.
    """

    @classmethod
    def setUpClass(cls):
        cls.launcher_dir = os.path.dirname(
            os.path.dirname(os.path.abspath(__file__)))
        cls.repo = os.path.dirname(cls.launcher_dir)
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
        seed = os.path.join(self.repo, "monitoring", "seed_kuma.py")
        with open(seed, encoding="utf-8") as fh:
            text = fh.read()
        for key in self.services:
            monitor = self.control(key).get("kuma")
            if monitor:
                self.assertIn('"%s"' % monitor, text, monitor)

    def test_planned_services_have_no_control_block(self):
        for key in ("adguard", "jellyfin", "paperless-ngx", "karakeep",
                    "forgejo"):
            self.assertIsNone(self.services[key].get("control"), key)

    def test_the_kuma_helper_paths_point_at_real_files(self):
        block = self.doc["control"]
        for field in ("kuma_toggle", "kuma_env"):
            self.assertTrue(block[field])
        self.assertTrue(os.path.isfile(
            os.path.join(self.repo, block["kuma_toggle"])))
        self.assertEqual(block["kuma_toggle"], "ntfy-control/kuma_toggle.py")

    # ---- the point of the whole exercise

    def _ntfy_control(self):
        """Import the deployed listener and point it at the shipped file."""
        import importlib.util
        path = os.path.join(self.repo, "ntfy-control", "control_listener.py")
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
        self.assertEqual(sorted(web), [
            "beszel", "code-server", "immich", "kaichenpedia", "manimkc",
            "n8n", "open-webui", "seafile", "uptime-kuma"])

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
                             server.control_monitor(
                                 server.control_block(svc)), key)

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


if __name__ == "__main__":
    unittest.main()
