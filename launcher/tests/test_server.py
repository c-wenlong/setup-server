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
            "probe": server.probe,
            "probe_all": server.probe_all,
            "magicdns_host": server.magicdns_host,
            "services_payload": server.services_payload,
            "_have_docker_group": server._have_docker_group,
            "_which": server._which,
            "Popen": subprocess.Popen,
        }
        server.REPO_ROOT = os.path.realpath(self.repo)
        server.ALLOWED_ROOTS = [server.REPO_ROOT]
        server.REGISTRY_PATH = os.path.join(self.tmp, "services.json")
        server.JOBS_DIR = os.path.join(self.tmp, "jobs")
        server.WEB_DIR = os.path.join(self.tmp, "web")

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
        self.assertEqual(sorted(payload), ["exit_code", "key", "log", "status"])
        self.assertEqual(payload["key"], "alpha")
        self.assertEqual(payload["status"], "running")
        self.assertIsNone(server.job_payload("does-not-exist"))


# ---------------------------------------------------------------- job field

class ServiceJobFieldTest(SandboxTest):
    """`job` on each service: what lets a reopened tile reattach to a deploy."""

    EIGHT = ["key", "name", "tagline", "icon", "url", "state",
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

    def test_running_job_is_reported_with_id_and_status_only(self):
        jid = server.start_deploy("alpha")
        job = self.tiles()["alpha"]["job"]
        self.assertEqual(job, {"id": jid, "status": "running"})
        self.assertEqual(sorted(job), ["id", "status"])

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
                         {"id": second, "status": "running"})

    # ---- finished (policy: linger, then disappear)

    def test_recently_finished_job_is_still_reported(self):
        jid = server.start_deploy("alpha")
        self.finish(jid, "done")
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": jid, "status": "done"})

    def test_recently_failed_job_is_still_reported(self):
        jid = server.start_deploy("alpha")
        self.finish(jid, "failed")
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": jid, "status": "failed"})

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
                         {"id": new, "status": "done"})

    def test_running_job_never_expires_however_old(self):
        jid = server.start_deploy("alpha")
        with server._jobs_lock:
            server._jobs[jid]["started"] = time.time() - 10 * server.JOB_RETENTION
        self.assertEqual(self.tiles()["alpha"]["job"],
                         {"id": jid, "status": "running"})

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

    def test_no_field_beyond_job_was_added(self):
        server.start_deploy("alpha")
        for tile in self.tiles().values():
            self.assertEqual(list(tile), self.EIGHT + ["job"])

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
        self.assertEqual(sorted(svc), ["active", "icon", "installed", "job",
                                       "key", "name", "state", "tagline",
                                       "url"])
        self.assertEqual(svc["url"], "https://box.ts.net:1/")
        self.assertIsNone(svc["job"])

    def test_services_field_order_is_stable(self):
        # The frontend reads these positionally in places; `job` is appended
        # last and the original eight keep their order.
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(list(doc["services"][0]),
                         ["key", "name", "tagline", "icon", "url", "state",
                          "installed", "active", "job"])

    def test_running_job_appears_on_its_tile_over_http(self):
        subprocess.Popen = lambda argv, **kw: FakeProc(argv, **kw)
        jid = server.start_deploy("alpha")
        doc = json.loads(self.get("/api/services")[1])
        self.assertEqual(doc["services"][0]["job"],
                         {"id": jid, "status": "running"})

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
                          "marker", "setup"):
                self.assertIn(field, svc, "%s missing %s" % (svc.get("key"), field))
            self.assertNotIn(svc["key"], keys, "duplicate key")
            keys.add(svc["key"])
            if svc["health"]:
                self.assertTrue(svc["health"].startswith("http://127.0.0.1:"),
                                "health probes must be loopback")


if __name__ == "__main__":
    unittest.main()
