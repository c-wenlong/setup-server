"""Mocked tests for app/web/ghapp.py, the GitHub-app runner.

No docker, git, tailscale or network: every subprocess goes through
ghapp.run / ghapp.quiet, which these tests replace, and the state dirs point
at a temp dir. Run from app/web/:

    python3 -m unittest discover -s tests -p 'test_*.py'
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import ghapp  # noqa: E402

SHA = "0123456789abcdef0123456789abcdef01234567"


def good(**over):
    d = {"key": "hello-app", "name": "Hello", "repo": "c-wenlong/hello",
         "ref": "main", "dockerfile": "Dockerfile", "context": ".",
         "container_port": 3000, "port": 8301, "health_path": "/",
         "volume": None}
    d.update(over)
    return d


def base(**over):
    """The fields every definition carries, with none of a method's own."""
    d = {"key": "hello-app", "name": "Hello", "repo": "c-wenlong/hello",
         "ref": "main", "port": 8301, "health_path": "/", "volume": None}
    d.update(over)
    return d


def method_def(method, **over):
    """A minimal valid definition for `method` (dockerfile defs use good())."""
    fields = {"image": {"image": "ghcr.io/o/hello:1.2.3", "container_port": 3000},
              "compose": {"compose_file": "docker-compose.yml",
                          "container_port": 3000},
              "static": {"build": "make site", "output": "public"},
              "node": {"version": "22-alpine", "build": "npm ci && npm run build",
                       "start": "npm start", "container_port": 3000},
              "python": {"version": "3.13-slim", "start": "python -m app",
                         "container_port": 3000},
              "script": {"cmd": "./run.sh"}}
    d = base(method=method, **fields[method])
    d.update(over)
    return d


class Sandbox(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ghapp-test-")
        self._saved = (ghapp.DEFS_DIR, ghapp.APPS_HOME, ghapp.run, ghapp.quiet,
                       ghapp.healthy, ghapp.tailscale_bin, os.environ.get("DEPLOY_SHA"),
                       ghapp.DEPLOYD_ENV, ghapp.DEPLOYD_HOME)
        # deployd's state is sandboxed for every test: a real
        # ~/services/deployd/state must never see a test's .sha/.disabled.
        ghapp.DEPLOYD_ENV = os.path.join(self.tmp, "no-deployd.env")
        ghapp.DEPLOYD_HOME = os.path.join(self.tmp, "deployd-home")
        ghapp.DEFS_DIR = os.path.join(self.tmp, "defs")
        ghapp.APPS_HOME = os.path.join(self.tmp, "apps")
        os.makedirs(ghapp.DEFS_DIR)
        self.calls = []
        self.cwds = []            # cwd of each call, index-aligned with calls
        self.envs = []            # env= of each call (None for quiet/default)
        self.quiet_out = {}
        self.run_codes = {}

        def fake_run(argv, check=True, capture=False, cwd=None, env=None):
            self.calls.append(list(argv))
            self.cwds.append(cwd)
            self.envs.append(env)
            code = 0
            for prefix, c in self.run_codes.items():
                if " ".join(argv).startswith(prefix):
                    code = c
            if check and code:
                raise ghapp.AppError("%s exited %d" % (argv[0], code))

            class R(object):
                returncode = code
                stdout = ""
            return R()

        def fake_quiet(argv, cwd=None):
            self.calls.append(list(argv))
            self.cwds.append(cwd)
            self.envs.append(None)
            for prefix, out in self.quiet_out.items():
                if " ".join(argv).startswith(prefix):
                    return out
            return 0, ""

        ghapp.run = fake_run
        ghapp.quiet = fake_quiet
        ghapp.tailscale_bin = lambda: None
        os.environ.pop("DEPLOY_SHA", None)

    def tearDown(self):
        (ghapp.DEFS_DIR, ghapp.APPS_HOME, ghapp.run, ghapp.quiet,
         ghapp.healthy, ghapp.tailscale_bin, sha,
         ghapp.DEPLOYD_ENV, ghapp.DEPLOYD_HOME) = self._saved
        if sha is None:
            os.environ.pop("DEPLOY_SHA", None)
        else:
            os.environ["DEPLOY_SHA"] = sha
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_def(self, d):
        with open(ghapp.def_path(d["key"]), "w") as fh:
            json.dump(d, fh)

    def make_src(self, key, dockerfile="Dockerfile"):
        return self.make_file(key, dockerfile)

    def make_file(self, key, rel, content=""):
        """A checkout that passed `clone`/`checkout`: src/.git plus the one
        repo file `rel` (the method's input — Dockerfile, compose file…)."""
        src = os.path.join(ghapp.app_dir(key), "src")
        os.makedirs(os.path.join(src, ".git"), exist_ok=True)
        path = os.path.join(src, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            fh.write(content)
        return src

    def argv_with(self, *words):
        return [c for c in self.calls if all(w in c for w in words)]


class ValidateTest(unittest.TestCase):

    def test_good_definition_passes(self):
        self.assertEqual(ghapp.validate(good())["key"], "hello-app")
        ghapp.validate(good(volume="/data", context="web", dockerfile="web/Dockerfile"))

    def test_shapes_that_could_reach_an_argv_are_refused(self):
        bad = [
            {"key": "X"}, {"key": "-flag"}, {"key": "ab"},
            {"repo": "no-slash"}, {"repo": "a/b/c"}, {"repo": "../x"},
            {"ref": "-b"}, {"ref": "a b"},
            {"dockerfile": "../Dockerfile"}, {"dockerfile": "/etc/passwd"},
            {"dockerfile": "-f"}, {"context": "a/../../b"},
            {"container_port": 0}, {"port": 70000}, {"port": "8301"}, {"port": True},
            {"health_path": "health"}, {"health_path": "/a b"},
            {"volume": "data"}, {"volume": "/a/../etc"},
        ]
        for over in bad:
            with self.assertRaises(ghapp.AppError, msg=over):
                ghapp.validate(good(**over))


class MethodValidateTest(unittest.TestCase):
    """The `method` field selects which fields validate() requires; an
    absent or unknown word is dockerfile, so old definitions are untouched."""

    def test_every_methods_good_shape_passes(self):
        ghapp.validate(good(method="dockerfile"))
        for m in ("image", "compose", "static", "node", "python", "script"):
            self.assertEqual(ghapp.validate(method_def(m))["method"], m, m)

    def test_absent_or_unknown_method_is_dockerfile(self):
        self.assertEqual(ghapp.method_of(good()), "dockerfile")
        self.assertEqual(ghapp.method_of(good(method=None)), "dockerfile")
        self.assertEqual(ghapp.method_of(good(method="podman")), "dockerfile")
        # An unknown word still needs the dockerfile fields it now means.
        ghapp.validate(good(method="podman"))
        with self.assertRaises(ghapp.AppError):
            ghapp.validate(base(method="podman"))       # no dockerfile/context

    def test_method_itself_is_shape_checked(self):
        for m in ("Image", "DOCKER FILE", "-x", "x" * 40, 3, ["image"]):
            with self.assertRaises(ghapp.AppError, msg=m):
                ghapp.validate(good(method=m))

    def test_per_method_fields_are_shape_checked(self):
        bad = [
            method_def("image", image="nginx"),                 # needs :tag/@digest
            method_def("image", image="-evil:1"),
            method_def("image", image="a b:c"),
            method_def("image", image=None),
            method_def("compose", compose_file="."),
            method_def("compose", compose_file="../x.yml"),
            method_def("compose", service="bad name"),
            method_def("compose", service=["web"]),
            method_def("static", build="a\nb"),
            method_def("static", build=""),
            method_def("static", output="/abs"),
            method_def("static", output=None),
            method_def("node", version=22),                     # tag, not int
            method_def("node", version="-alpine"),
            method_def("node", build="x" * 501),
            method_def("node", start=None),
            method_def("python", start="has\nnewline"),
            method_def("script", cmd="a\rb"),
            method_def("script", cmd="x" * 501),
            method_def("script", cmd=""),
            method_def("image", container_port=0),
            method_def("compose", container_port="3000"),
            method_def("image", port=None),
            method_def("image", health_path=None),
        ]
        for d in bad:
            with self.assertRaises(ghapp.AppError, msg=d):
                ghapp.validate(d)

    def test_image_reference_shapes(self):
        ghapp.validate(method_def("image", image="nginx:1.27-alpine"))
        ghapp.validate(method_def("image", image="registry.local:5000/o/n:v2"))
        ghapp.validate(method_def("image", image="o/n@sha256:" + "a" * 64))

    def test_script_may_omit_port_and_health_path(self):
        d = method_def("script", port=None, health_path=None)
        ghapp.validate(d)
        ghapp.validate(method_def("script", port=None))
        with self.assertRaises(ghapp.AppError):
            ghapp.validate(method_def("script", port="abc"))
        with self.assertRaises(ghapp.AppError):
            ghapp.validate(method_def("script", health_path="no-slash"))

    def test_node_python_build_optional_but_start_required(self):
        ghapp.validate(method_def("node", build=None))
        ghapp.validate(method_def("python", build=None))
        with self.assertRaises(ghapp.AppError):
            ghapp.validate(method_def("node", start=""))

    def test_shared_fields_still_gated_for_other_methods(self):
        with self.assertRaises(ghapp.AppError):
            ghapp.validate(method_def("image", volume="data"))
        with self.assertRaises(ghapp.AppError):
            ghapp.validate(method_def("script", env_names=["1BAD"]))


class ArgvTest(Sandbox):

    def test_run_binds_loopback_only_and_restarts_unless_stopped(self):
        argv = ghapp.run_argv(good(), "img:1")
        self.assertIn("127.0.0.1:8301:3000", argv)
        self.assertNotIn("0.0.0.0", " ".join(argv))
        self.assertEqual(argv[argv.index("--restart") + 1], "unless-stopped")
        self.assertEqual(argv[argv.index("--name") + 1], "app-hello-app")
        self.assertEqual(argv[-1], "img:1")
        self.assertNotIn("--env-file", argv)       # no .env yet
        self.assertNotIn("--volume", argv)

    def test_env_file_and_volume_only_when_present(self):
        os.makedirs(ghapp.app_dir("hello-app"))
        open(os.path.join(ghapp.app_dir("hello-app"), ".env"), "w").close()
        argv = ghapp.run_argv(good(volume="/data"), "img:1")
        self.assertIn("--env-file", argv)
        vol = argv[argv.index("--volume") + 1]
        self.assertTrue(vol.endswith("/apps/hello-app/data:/data"), vol)

    def test_build_tags_by_sha_and_stays_inside_src(self):
        argv = ghapp.build_argv(good(dockerfile="web/Dockerfile", context="web"),
                                SHA, "/x/src")
        self.assertEqual(argv[argv.index("--tag") + 1], "launcher-app/hello-app:0123456789ab")
        self.assertEqual(argv[argv.index("--file") + 1], "/x/src/web/Dockerfile")
        self.assertEqual(argv[-1], "/x/src/web")
        self.assertIn("org.opencontainers.image.revision=%s" % SHA, argv)

    def test_deploy_sha_from_env_skips_ls_remote(self):
        os.environ["DEPLOY_SHA"] = SHA
        self.assertEqual(ghapp.resolve_sha(good()), SHA)
        self.assertFalse(self.argv_with("ls-remote"))

    def test_bad_deploy_sha_falls_back_to_ls_remote(self):
        os.environ["DEPLOY_SHA"] = "not-a-sha"
        self.quiet_out["git ls-remote"] = (0, "%s\trefs/heads/main\n" % SHA)
        self.assertEqual(ghapp.resolve_sha(good()), SHA)
        self.assertEqual(self.argv_with("ls-remote")[0][-2:],
                         ["https://github.com/c-wenlong/hello.git", "main"])

    def test_unresolvable_ref_is_an_error(self):
        self.quiet_out["git ls-remote"] = (2, "")
        with self.assertRaises(ghapp.AppError):
            ghapp.resolve_sha(good())


class DeployTest(Sandbox):

    def setUp(self):
        super().setUp()
        self.write_def(good())
        os.environ["DEPLOY_SHA"] = SHA

    def test_happy_path_builds_swaps_and_records(self):
        self.make_src("hello-app")
        ghapp.healthy = lambda d, t: True
        ghapp.deploy("hello-app")
        self.assertTrue(self.argv_with("docker", "build"))
        self.assertTrue(self.argv_with("docker", "run"))
        rec = json.load(open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json")))
        self.assertEqual(rec["sha"], SHA)
        self.assertEqual(rec["image"], "launcher-app/hello-app:0123456789ab")
        # checkout pins the exact sha, detached
        self.assertTrue(self.argv_with("checkout", "--detach", SHA))

    def test_missing_dockerfile_stops_before_building(self):
        os.makedirs(os.path.join(ghapp.app_dir("hello-app"), "src", ".git"))
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("docker", "build"))

    def test_unhealthy_rolls_back_to_previous_image(self):
        self.make_src("hello-app")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "a" * 64 + "\n")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        runs = self.argv_with("docker", "run")
        self.assertEqual(runs[-1][-1], "sha256:" + "a" * 64)
        self.assertFalse(os.path.exists(os.path.join(ghapp.app_dir("hello-app"),
                                                     "deployed.json")))

    def test_unhealthy_first_deploy_has_nothing_to_roll_back_to(self):
        self.make_src("hello-app")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(len(self.argv_with("docker", "run")), 1)

    def test_publish_uses_serve_on_the_app_port(self):
        self.make_src("hello-app")
        ghapp.healthy = lambda d, t: True
        ghapp.tailscale_bin = lambda: "/bin/tailscale"
        self.quiet_out["/bin/tailscale serve status"] = (0, json.dumps({"Web": {}}))
        ghapp.deploy("hello-app")
        serve = self.argv_with("/bin/tailscale", "--bg")
        self.assertEqual(serve[0], ["/bin/tailscale", "serve", "--bg", "--https=8301",
                                    "http://127.0.0.1:8301"])

    def test_already_published_is_left_alone(self):
        self.make_src("hello-app")
        ghapp.healthy = lambda d, t: True
        ghapp.tailscale_bin = lambda: "/bin/tailscale"
        status = {"Web": {"box.ts.net:8301": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8301"}}}}}
        self.quiet_out["/bin/tailscale serve status"] = (0, json.dumps(status))
        ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("/bin/tailscale", "--bg"))


class MethodDeployTest(Sandbox):
    """deploy() dispatch: each method's argv construction and lifecycle."""

    OLD_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    def setUp(self):
        super().setUp()
        os.environ["DEPLOY_SHA"] = SHA
        ghapp.healthy = lambda d, t: True

    def write_method(self, method, **over):
        d = method_def(method, **over)
        self.write_def(d)
        return d

    def deployed(self):
        return json.load(open(os.path.join(ghapp.app_dir("hello-app"),
                                           "deployed.json")))

    def test_image_pulls_and_runs_without_building(self):
        self.write_method("image")
        self.make_src("hello-app")
        ghapp.deploy("hello-app")
        self.assertTrue(self.argv_with("docker", "pull", "ghcr.io/o/hello:1.2.3"))
        runs = self.argv_with("docker", "run")
        self.assertEqual(runs[-1][-1], "ghcr.io/o/hello:1.2.3")
        self.assertIn("127.0.0.1:8301:3000", runs[-1])
        self.assertFalse(self.argv_with("docker", "build"))
        self.assertEqual(self.deployed()["method"], "image")
        self.assertEqual(self.deployed()["image"], "ghcr.io/o/hello:1.2.3")

    def test_image_unhealthy_rolls_back_to_the_previous_id(self):
        self.write_method("image")
        self.make_src("hello-app")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "b" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(self.argv_with("docker", "run")[-1][-1],
                         "sha256:" + "b" * 64)

    def test_compose_ups_the_repo_file_as_project_app_key(self):
        self.write_method("compose")
        src = self.make_file("hello-app", "docker-compose.yml")
        ghapp.deploy("hello-app")
        ups = self.argv_with("compose", "up", "--detach")
        self.assertEqual(len(ups), 1)
        # --build: a `build:` service rebuilds the new commit;
        # --remove-orphans: a renamed service cannot keep the port.
        self.assertIn("--build", ups[0])
        self.assertIn("--remove-orphans", ups[0])
        self.assertEqual(ups[0][ups[0].index("--project-name") + 1], "app-hello-app")
        self.assertEqual(ups[0][ups[0].index("--file") + 1],
                         os.path.join(src, "docker-compose.yml"))
        self.assertFalse(self.argv_with("docker", "build"))
        self.assertFalse(self.argv_with("docker", "run"))
        self.assertEqual(self.deployed()["method"], "compose")

    def test_compose_passes_the_app_env_file_when_present(self):
        self.write_method("compose", service="web")
        src = self.make_file("hello-app", "docker-compose.yml")
        open(os.path.join(ghapp.app_dir("hello-app"), ".env"), "w").close()
        ghapp.deploy("hello-app")
        up = self.argv_with("compose", "up", "--detach")[0]
        self.assertEqual(up[up.index("--env-file") + 1],
                         os.path.join(ghapp.app_dir("hello-app"), ".env"))
        self.assertEqual(up[up.index("--file") + 1],
                         os.path.join(src, "docker-compose.yml"))

    def test_compose_missing_file_stops_before_up(self):
        self.write_method("compose")
        os.makedirs(os.path.join(ghapp.app_dir("hello-app"), "src", ".git"))
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("compose", "up"))

    def test_compose_unhealthy_restores_the_last_deployed_sha(self):
        self.write_method("compose")
        self.make_file("hello-app", "docker-compose.yml")
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"),
                  "w") as fh:
            json.dump({"sha": self.OLD_SHA, "method": "compose"}, fh)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        # Re-checkout of the old sha, then up -d again.
        back = self.argv_with("checkout", "--detach", self.OLD_SHA)
        self.assertTrue(back)
        ups = self.argv_with("compose", "up", "--detach")
        self.assertEqual(len(ups), 2)
        self.assertIn("--build", ups[1])            # rollback rebuilds old sha
        self.assertIn("--remove-orphans", ups[1])
        self.assertFalse(os.path.exists(
            os.path.join(ghapp.app_dir("hello-app"), "deployed.json.tmp")))

    def test_compose_unhealthy_first_deploy_has_no_restore(self):
        self.write_method("compose")
        self.make_file("hello-app", "docker-compose.yml")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(len(self.argv_with("compose", "up", "--detach")), 1)

    def test_compose_failure_log_scopes_to_the_named_service(self):
        self.write_method("compose", service="web")
        self.make_file("hello-app", "docker-compose.yml")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        logs = self.argv_with("compose", "logs")
        self.assertEqual(logs[0][-1], "web")

    def test_static_builds_then_serves_a_release_outside_src(self):
        self.write_method("static")
        src = self.make_file("hello-app", "public/index.html", "v2")
        ghapp.deploy("hello-app")
        idx = self.calls.index(self.argv_with("sh", "-c", "make site")[0])
        self.assertEqual(self.cwds[idx], src)
        self.assertTrue(self.argv_with("docker", "pull", ghapp.STATIC_IMAGE))
        run = self.argv_with("docker", "run")[-1]
        self.assertIn("127.0.0.1:8301:80", run)
        mount = run[run.index("--volume") + 1]
        name = self.deployed()["release"]
        self.assertRegex(name, r"^site-%s-\d+$" % SHA[:12])
        release = os.path.join(ghapp.app_dir("hello-app"), name)
        # Outside src/: the next deploy's `git clean -ffdxq` cannot touch it.
        self.assertEqual(mount, release + ":/usr/share/nginx/html:ro")
        self.assertFalse(release.startswith(src + os.sep))
        with open(os.path.join(release, "index.html")) as fh:
            self.assertEqual(fh.read(), "v2")
        self.assertEqual(self.deployed()["image"], ghapp.STATIC_IMAGE)

    def live_release(self, sha=None, content="v1"):
        """A release a previous static deploy left serving, recorded in
        deployed.json the way deploy() writes it."""
        sha = sha or self.OLD_SHA
        name = "site-%s-1000" % sha[:12]
        path = os.path.join(ghapp.app_dir("hello-app"), name)
        os.makedirs(path)
        with open(os.path.join(path, "index.html"), "w") as fh:
            fh.write(content)
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            json.dump({"sha": sha, "method": "static", "release": name}, fh)
        return name, path

    def test_static_failed_build_leaves_the_live_release_alone(self):
        self.write_method("static")
        self.make_src("hello-app")
        _, live = self.live_release()
        self.run_codes["sh -c make site"] = 2
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertTrue(os.path.isdir(live))
        self.assertFalse(self.argv_with("docker", "run"))

    def test_static_same_commit_rebuild_never_touches_the_live_release(self):
        self.write_method("static")
        self.make_file("hello-app", "public/index.html", "v2")
        name, live = self.live_release(sha=SHA)       # same commit as DEPLOY_SHA
        self.run_codes["docker pull"] = 1             # fail after the copy
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        with open(os.path.join(live, "index.html")) as fh:
            self.assertEqual(fh.read(), "v1")
        sites = [n for n in os.listdir(ghapp.app_dir("hello-app")) if n.startswith("site-")]
        self.assertEqual(sites, [name])               # the new release was dropped

    def test_static_same_commit_rebuild_gets_its_own_release(self):
        self.write_method("static")
        self.make_file("hello-app", "public/index.html", "v2")
        name, live = self.live_release(sha=SHA)
        ghapp.deploy("hello-app")
        new = self.deployed()["release"]
        self.assertNotEqual(new, name)
        self.assertTrue(os.path.isdir(live))          # kept as the rollback one

    def test_static_unhealthy_rolls_back_to_the_previous_release(self):
        self.write_method("static")
        self.make_file("hello-app", "public/index.html", "v2")
        name, prev = self.live_release()
        self.quiet_out["docker inspect"] = (0, "sha256:" + "d" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        back = self.argv_with("docker", "run")[-1]
        self.assertEqual(back[-1], "sha256:" + "d" * 64)
        self.assertEqual(back[back.index("--volume") + 1],
                         prev + ":/usr/share/nginx/html:ro")
        sites = [n for n in os.listdir(ghapp.app_dir("hello-app")) if n.startswith("site-")]
        self.assertEqual(sites, [name])

    def test_static_without_a_recorded_release_does_not_roll_back(self):
        self.write_method("static")
        self.make_file("hello-app", "public/index.html")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "e" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(len(self.argv_with("docker", "run")), 1)

    def test_static_success_prunes_all_but_current_and_previous(self):
        self.write_method("static")
        self.make_file("hello-app", "public/index.html")
        app = ghapp.app_dir("hello-app")
        prev, _ = self.live_release()
        os.makedirs(os.path.join(app, "site-bbbbbbbbbbbb-5"))
        ghapp.deploy("hello-app")
        sites = sorted(n for n in os.listdir(app) if n.startswith("site-"))
        self.assertEqual(sites, sorted([self.deployed()["release"], prev]))

    def test_static_output_symlink_out_of_the_checkout_is_refused(self):
        self.write_method("static")
        src = self.make_src("hello-app")
        os.symlink(self.tmp, os.path.join(src, "public"))
        with self.assertRaises(ghapp.AppError) as ctx:
            ghapp.deploy("hello-app")
        self.assertIn("escapes the checkout", str(ctx.exception))
        self.assertFalse(self.argv_with("docker", "run"))

    def test_dockerfile_symlink_out_of_the_checkout_is_refused(self):
        self.write_def(good())
        src = self.make_src("hello-app", "real/Dockerfile")
        outside = os.path.join(self.tmp, "host-Dockerfile")
        open(outside, "w").close()
        os.symlink(outside, os.path.join(src, "Dockerfile"))
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("docker", "build"))

    def test_compose_file_symlink_out_of_the_checkout_is_refused(self):
        self.write_method("compose")
        src = self.make_src("hello-app")
        outside = os.path.join(self.tmp, "host.yml")
        open(outside, "w").close()
        os.symlink(outside, os.path.join(src, "docker-compose.yml"))
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("compose", "up"))

    def test_generated_dockerfile_never_writes_through_a_symlink(self):
        self.write_method("node")
        src = self.make_src("hello-app")
        victim = os.path.join(ghapp.app_dir("hello-app"), ".env")
        with open(victim, "w") as fh:
            fh.write("SECRET=keep\n")
        os.symlink(victim, os.path.join(src, ghapp.GENERATED_DOCKERFILE))
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        with open(victim) as fh:
            self.assertEqual(fh.read(), "SECRET=keep\n")
        self.assertFalse(self.argv_with("docker", "build"))

    def test_static_missing_output_dir_stops_before_running(self):
        self.write_method("static")
        self.make_src("hello-app")
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("docker", "run"))

    def test_node_writes_a_dockerfile_then_builds_like_dockerfile(self):
        self.write_method("node")
        src = self.make_src("hello-app")
        ghapp.deploy("hello-app")
        path = os.path.join(src, ghapp.GENERATED_DOCKERFILE)
        text = open(path).read()
        self.assertIn("FROM node:22-alpine", text)
        self.assertIn("RUN npm ci && npm run build", text)
        self.assertIn("EXPOSE 3000", text)
        self.assertIn('CMD ["sh", "-c", "npm start"]', text)
        build = self.argv_with("docker", "build")[0]
        self.assertEqual(build[build.index("--file") + 1], path)
        self.assertEqual(build[-1], src)
        self.assertTrue(self.argv_with("docker", "run"))
        self.assertEqual(self.deployed()["method"], "node")

    def test_python_omits_run_line_without_a_build(self):
        self.write_method("python")
        src = self.make_src("hello-app")
        ghapp.deploy("hello-app")
        text = open(os.path.join(src, ghapp.GENERATED_DOCKERFILE)).read()
        self.assertIn("FROM python:3.13-slim", text)
        self.assertNotIn("RUN ", text)
        self.assertIn('CMD ["sh", "-c", "python -m app"]', text)

    def test_script_runs_cmd_in_the_checkout_no_container_no_publish(self):
        self.write_method("script", port=None, health_path=None)
        src = self.make_src("hello-app")
        ghapp.tailscale_bin = lambda: "/bin/ts"
        ghapp.deploy("hello-app")
        idx = self.calls.index(self.argv_with("sh", "-c", "./run.sh")[0])
        self.assertEqual(self.cwds[idx], src)
        self.assertFalse(self.argv_with("docker", "run"))
        self.assertFalse(self.argv_with("docker", "build"))
        self.assertFalse(self.argv_with("docker", "pull"))
        self.assertFalse(self.argv_with("/bin/ts", "serve"))
        self.assertEqual(self.deployed()["method"], "script")
        self.assertIsNone(self.deployed()["image"])

    def test_script_health_check_runs_when_port_and_path_are_set(self):
        self.write_method("script")         # port 8301 + health_path "/"
        self.make_src("hello-app")
        seen = []
        ghapp.healthy = lambda d, t: seen.append((d["port"], d["health_path"])) or True
        ghapp.deploy("hello-app")
        self.assertEqual(seen, [(8301, "/")])
        self.assertFalse(self.argv_with("docker", "run"))

    def test_script_unhealthy_is_an_error(self):
        self.write_method("script")
        self.make_src("hello-app")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(os.path.exists(
            os.path.join(ghapp.app_dir("hello-app"), "deployed.json")))


class HostEnvTest(Sandbox):
    """Host-run commands (static build, script cmd) get the runner's env
    overlaid with the app's .env, read with `docker --env-file` rules, and
    a PATH with the user tool dirs in front. No value is ever printed."""

    SECRET = "sentinel-value-aaaa"   # low entropy: not a secret scan hit

    def setUp(self):
        super().setUp()
        os.environ["DEPLOY_SHA"] = SHA
        ghapp.healthy = lambda d, t: True
        self._dirs = ghapp.HOST_PATH_DIRS
        self._env = dict(os.environ)

    def tearDown(self):
        ghapp.HOST_PATH_DIRS = self._dirs
        os.environ.clear()
        os.environ.update(self._env)
        super().tearDown()

    def write_env(self, text, key="hello-app"):
        os.makedirs(ghapp.app_dir(key), exist_ok=True)
        path = os.path.join(ghapp.app_dir(key), ".env")
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def env_of(self, *words):
        return self.envs[self.calls.index(self.argv_with(*words)[0])]

    def deploy_quietly(self, key="hello-app"):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            ghapp.deploy(key)
        return out.getvalue()

    def test_env_overlay_reaches_a_static_build(self):
        self.write_def(method_def("static"))
        self.make_file("hello-app", "public/index.html")
        self.write_env("SITE_PASSPHRASE=%s\n" % self.SECRET)
        os.environ["RUNNER_ONLY"] = "kept"
        self.deploy_quietly()
        env = self.env_of("sh", "-c", "make site")
        self.assertEqual(env["SITE_PASSPHRASE"], self.SECRET)
        self.assertEqual(env["RUNNER_ONLY"], "kept")     # runner env underneath

    def test_env_overlay_reaches_a_script_cmd(self):
        self.write_def(method_def("script", port=None, health_path=None))
        self.make_src("hello-app")
        self.write_env("TOKEN=abc\n")
        self.deploy_quietly()
        self.assertEqual(self.env_of("sh", "-c", "./run.sh")["TOKEN"], "abc")

    def test_no_env_file_still_gets_the_runner_env(self):
        os.environ["RUNNER_ONLY"] = "kept"
        env = ghapp.host_env("hello-app")
        self.assertEqual(env["RUNNER_ONLY"], "kept")

    def test_docker_env_file_parsing_edge_cases(self):
        os.environ["FROM_RUNNER"] = "runner-value"
        os.environ.pop("NOT_SET_ANYWHERE", None)
        path = self.write_env(
            "\ufeffFIRST=bom-stripped\n"
            "# a comment\n"
            "   # an indented comment\n"
            "\n"
            "QUOTED=\"kept with quotes\"\n"
            "SINGLE='single'\n"
            "DOLLAR=$HOME/x\n"
            "EQUALS=a=b=c\n"
            "EMPTY=\n"
            "   INDENTED=yes\n"
            "TRAILING=space \n"
            "CRLF=dos\r\n"
            "FROM_RUNNER\n"
            "NOT_SET_ANYWHERE\n"
            "1BAD=%s\n"
            "BAD NAME=%s\n"
            "=%s\n"
            "export E=%s\n" % ((self.SECRET,) * 4))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            got = ghapp.env_file_entries(path, dict(os.environ))
        self.assertEqual(got, [
            ("FIRST", "bom-stripped"),
            ("QUOTED", '"kept with quotes"'),
            ("SINGLE", "'single'"),
            ("DOLLAR", "$HOME/x"),
            ("EQUALS", "a=b=c"),
            ("EMPTY", ""),
            ("INDENTED", "yes"),
            ("TRAILING", "space "),
            ("CRLF", "dos"),
            ("FROM_RUNNER", "runner-value"),
        ])
        log = out.getvalue()
        for line in (15, 16, 17, 18):
            self.assertIn("skipping line %d of" % line, log)
        self.assertNotIn(self.SECRET, log)
        self.assertNotIn("1BAD", log)                    # not even the name

    def test_later_lines_win_and_a_bare_key_overrides_with_the_runner_value(self):
        os.environ["DUP"] = "runner"
        self.write_env("DUP=first\nDUP=second\nOTHER=1\nOTHER=2\nDUP\n")
        env = ghapp.host_env("hello-app")
        self.assertEqual(env["OTHER"], "2")
        self.assertEqual(env["DUP"], "runner")

    def test_non_utf8_and_nul_lines_are_skipped(self):
        os.makedirs(ghapp.app_dir("hello-app"))
        path = os.path.join(ghapp.app_dir("hello-app"), ".env")
        with open(path, "wb") as fh:
            fh.write(b"OK=1\nBAD=\xff\xfe\nNUL=a\x00b\nLAST=2\n")
        with contextlib.redirect_stdout(io.StringIO()):
            got = ghapp.env_file_entries(path, {})
        self.assertEqual(got, [("OK", "1"), ("LAST", "2")])

    def test_path_prepends_only_existing_dirs_without_duplicates(self):
        a = os.path.join(self.tmp, "a-bin")
        b = os.path.join(self.tmp, "b-bin")
        missing = os.path.join(self.tmp, "missing-bin")
        os.makedirs(a)
        os.makedirs(b)
        ghapp.HOST_PATH_DIRS = (a, missing, b, a)
        os.environ["PATH"] = os.pathsep.join(["/usr/bin", b, "", "/bin", "/usr/bin"])
        path = ghapp.host_env("hello-app")["PATH"].split(os.pathsep)
        self.assertEqual(path, [a, b, "/usr/bin", "/bin"])
        self.assertNotIn(missing, path)

    def test_path_expands_home_dirs(self):
        home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(home, ".local", "bin"))
        os.environ["HOME"] = home
        ghapp.HOST_PATH_DIRS = ("~/.local/bin", "~/.nix-profile/bin")
        os.environ["PATH"] = "/usr/bin"
        self.assertEqual(ghapp.host_env("hello-app")["PATH"],
                         os.pathsep.join([os.path.join(home, ".local", "bin"),
                                          "/usr/bin"]))

    def test_a_path_in_env_is_ignored_with_one_log_line(self):
        ghapp.HOST_PATH_DIRS = ()
        os.environ["PATH"] = "/usr/bin:/bin"
        self.write_env("PATH=/evil/%s\nPATH=/again\nKEEP=1\n" % self.SECRET)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            env = ghapp.host_env("hello-app")
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        self.assertEqual(env["KEEP"], "1")
        log = out.getvalue()
        self.assertEqual(log.count("PATH in .env is ignored"), 1)
        self.assertNotIn(self.SECRET, log)
        self.assertNotIn("/again", log)

    def test_static_nginx_gets_no_env_file_but_a_dockerfile_app_does(self):
        self.write_def(method_def("static"))
        self.make_file("hello-app", "public/index.html")
        self.write_env("SITE_PASSPHRASE=%s\n" % self.SECRET)
        self.deploy_quietly()
        run = self.argv_with("docker", "run")[-1]
        self.assertEqual(run[-1], ghapp.STATIC_IMAGE)
        self.assertNotIn("--env-file", run)
        # A dockerfile app with the same .env still gets it.
        argv = ghapp.run_argv(good(), "img:1")
        self.assertEqual(argv[argv.index("--env-file") + 1],
                         os.path.join(ghapp.app_dir("hello-app"), ".env"))

    def test_static_rollback_run_gets_no_env_file_either(self):
        self.write_def(method_def("static"))
        self.make_file("hello-app", "public/index.html")
        self.write_env("SITE_PASSPHRASE=%s\n" % self.SECRET)
        name = "site-%s-1000" % ("a" * 12)
        os.makedirs(os.path.join(ghapp.app_dir("hello-app"), name))
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            json.dump({"sha": "a" * 40, "method": "static", "release": name}, fh)
        self.quiet_out["docker inspect"] = (0, "sha256:" + "d" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        runs = self.argv_with("docker", "run")
        self.assertEqual(len(runs), 2)
        for argv in runs:
            self.assertNotIn("--env-file", argv)

    def test_failed_switch_off_static_restores_nginx_as_static_runs_it(self):
        """static -> image/dockerfile/node/python failing its health check
        puts the old nginx back with static's port and release mount and
        without the .env, not with the new method's run settings."""
        for method in ("image", "dockerfile", "node", "python"):
            self.calls[:], self.cwds[:], self.envs[:] = [], [], []
            app = ghapp.app_dir("hello-app")
            shutil.rmtree(app, ignore_errors=True)
            d = good() if method == "dockerfile" else method_def(method)
            self.write_def(d)
            self.make_src("hello-app")
            self.write_env("SITE_PASSPHRASE=%s\n" % self.SECRET)
            name = "site-%s-1000" % ("a" * 12)
            os.makedirs(os.path.join(app, name))
            with open(os.path.join(app, "deployed.json"), "w") as fh:
                json.dump({"sha": "a" * 40, "method": "static", "release": name}, fh)
            self.quiet_out["docker inspect"] = (0, "sha256:" + "f" * 64)
            ghapp.healthy = lambda d, t: False
            with self.assertRaises(ghapp.AppError, msg=method):
                self.deploy_quietly()
            runs = self.argv_with("docker", "run")
            self.assertEqual(len(runs), 2, method)
            self.assertIn("--env-file", runs[0], method)      # the new app's
            back = runs[1]
            self.assertEqual(back[-1], "sha256:" + "f" * 64, method)
            self.assertNotIn("--env-file", back, method)
            self.assertIn("127.0.0.1:8301:80", back, method)
            self.assertEqual(back[back.index("--volume") + 1],
                             os.path.join(app, name) + ":/usr/share/nginx/html:ro",
                             method)

    def test_failed_switch_off_static_without_a_release_does_not_roll_back(self):
        self.write_def(method_def("image"))
        self.make_src("hello-app")
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            json.dump({"sha": "a" * 40, "method": "static"}, fh)
        self.quiet_out["docker inspect"] = (0, "sha256:" + "f" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        self.assertEqual(len(self.argv_with("docker", "run")), 1)

    def test_container_to_container_rollback_keeps_its_own_run_settings(self):
        self.write_def(method_def("image"))
        self.make_src("hello-app")
        self.write_env("A=1\n")
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            json.dump({"sha": "a" * 40, "method": "dockerfile"}, fh)
        self.quiet_out["docker inspect"] = (0, "sha256:" + "f" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        back = self.argv_with("docker", "run")[-1]
        self.assertEqual(back[-1], "sha256:" + "f" * 64)
        self.assertIn("--env-file", back)
        self.assertIn("127.0.0.1:8301:3000", back)

    def test_the_real_run_logs_the_argv_and_never_a_value(self):
        """Through the real run(), which echoes the argv to the job log:
        subprocess.run is stubbed (no process reaches the host), and the
        stub sees the values in env= while stdout holds none of them."""
        real_run = self._saved[2]
        fake_run = ghapp.run
        spawned = []

        def run(argv, check=True, capture=False, cwd=None, env=None):
            if argv[0] == "sh":
                return real_run(argv, check, capture, cwd, env)
            return fake_run(argv, check, capture, cwd, env)

        def sub_run(argv, **kw):
            spawned.append((list(argv), kw.get("env")))
            return subprocess.CompletedProcess(argv, 0)
        ghapp.run = run
        self.write_def(method_def("static", build="./build.sh"))
        self.make_file("hello-app", "public/index.html")
        self.write_env("SITE_PASSPHRASE=%s\nPATH=/nope\n1X=%s\n"
                       % (self.SECRET, self.SECRET))
        with mock.patch.object(ghapp.subprocess, "run", sub_run):
            log = self.deploy_quietly()
        self.assertEqual(len(spawned), 1)
        argv, env = spawned[0]
        self.assertEqual(argv, ["sh", "-c", "./build.sh"])
        self.assertEqual(env["SITE_PASSPHRASE"], self.SECRET)
        self.assertNotIn("/nope", env["PATH"])
        self.assertIn("$ sh -c ./build.sh", log)
        self.assertIn("PATH in .env is ignored", log)
        self.assertIn("skipping line 3 of", log)
        self.assertNotIn(self.SECRET, log)
        self.assertNotIn("/nope", log)
        for call in self.calls:                  # no value in any argv either
            self.assertNotIn(self.SECRET, " ".join(call))


class RemoveTest(Sandbox):

    def setUp(self):
        super().setUp()
        self.write_def(good())
        os.makedirs(ghapp.app_dir("hello-app"))
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            fh.write("{}")
        ghapp.tailscale_bin = lambda: "/bin/tailscale"
        self.quiet_out["docker ps"] = (0, "app-hello-app\n")

    def marker(self):
        return os.path.join(ghapp.app_dir("hello-app"), "deployed.json")

    def test_unreadable_serve_status_changes_nothing(self):
        self.quiet_out["/bin/tailscale serve status"] = (1, "")
        with self.assertRaises(ghapp.AppError):
            ghapp.remove("hello-app")
        self.assertFalse(self.argv_with("docker", "rm"))
        self.assertTrue(os.path.exists(self.marker()))

    def test_docker_not_answering_changes_nothing(self):
        self.quiet_out["/bin/tailscale serve status"] = (0, "{}")
        self.quiet_out["docker ps"] = (1, "")
        with self.assertRaises(ghapp.AppError):
            ghapp.remove("hello-app")
        self.assertFalse(self.argv_with("docker", "rm"))
        self.assertTrue(os.path.exists(self.marker()))

    def test_a_failed_rm_or_serve_off_keeps_the_marker(self):
        status = {"Web": {"box:8301": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8301"}}}}}
        self.quiet_out["/bin/tailscale serve status"] = (0, json.dumps(status))
        self.run_codes["docker rm"] = 1
        with self.assertRaises(ghapp.AppError):
            ghapp.remove("hello-app")
        self.assertTrue(os.path.exists(self.marker()))
        self.run_codes = {"/bin/tailscale serve": 1}
        with self.assertRaises(ghapp.AppError):
            ghapp.remove("hello-app")
        self.assertTrue(os.path.exists(self.marker()))

    def test_a_container_already_gone_is_fine(self):
        self.quiet_out["/bin/tailscale serve status"] = (0, "{}")
        self.quiet_out["docker ps"] = (0, "")
        ghapp.remove("hello-app")
        self.assertFalse(self.argv_with("docker", "rm"))
        self.assertFalse(os.path.exists(self.marker()))

    def test_drops_container_serve_and_marker_but_keeps_data(self):
        status = {"Web": {"box:8301": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8301"}}}}}
        self.quiet_out["/bin/tailscale serve status"] = (0, json.dumps(status))
        ghapp.remove("hello-app")
        self.assertTrue(self.argv_with("docker", "rm", "app-hello-app"))
        self.assertEqual(self.argv_with("--https=8301", "off")[0][-1], "off")
        self.assertFalse(os.path.exists(os.path.join(ghapp.app_dir("hello-app"), "deployed.json")))
        self.assertTrue(os.path.isdir(ghapp.app_dir("hello-app")))
        self.assertTrue(os.path.isfile(ghapp.def_path("hello-app")))

    def test_a_port_another_target_owns_is_not_turned_off(self):
        status = {"Web": {"box:8301": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}}}}
        self.quiet_out["/bin/tailscale serve status"] = (0, json.dumps(status))
        ghapp.remove("hello-app")
        self.assertFalse(self.argv_with("off"))


class MainTest(Sandbox):

    def test_usage_and_unknown_app(self):
        self.assertEqual(ghapp.main(["ghapp.py"]), 2)
        self.assertEqual(ghapp.main(["ghapp.py", "nuke", "x"]), 2)
        os.environ["GHAPP_SG"] = "1"     # skip the docker-group re-exec
        try:
            self.assertEqual(ghapp.main(["ghapp.py", "deploy", "nope-app"]), 1)
            self.assertEqual(ghapp.main(["ghapp.py", "deploy", "../etc"]), 1)
        finally:
            os.environ.pop("GHAPP_SG", None)


if __name__ == "__main__":
    unittest.main()


class ReviewFixesTest(Sandbox):
    """The rollback, pause and ownership rules added after review."""

    def setUp(self):
        super().setUp()
        self.write_def(good())
        os.environ["DEPLOY_SHA"] = SHA
        self.state = os.path.join(self.tmp, "deployd-state")
        os.makedirs(self.state)
        self._ds = ghapp.deployd_state_dir
        ghapp.deployd_state_dir = lambda: self.state

    def tearDown(self):
        ghapp.deployd_state_dir = self._ds
        super().tearDown()

    def test_a_container_that_cannot_start_is_rolled_back_too(self):
        self.make_src("hello-app")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "b" * 64)
        real = ghapp.run

        def run(argv, check=True, capture=False, cwd=None):
            res = real(argv, check, capture, cwd)
            if argv[:2] == ["docker", "run"] and argv[-1].startswith("launcher-app/"):
                raise ghapp.AppError("docker run exited 125")
            return res
        ghapp.run = run
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(self.argv_with("docker", "run")[-1][-1], "sha256:" + "b" * 64)

    def test_same_commit_rebuild_still_rolls_back_to_the_old_image_id(self):
        self.make_src("hello-app")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "c" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        inspect = self.argv_with("docker", "inspect")[0]
        build = self.argv_with("docker", "build")[0]
        self.assertLess(self.calls.index(inspect), self.calls.index(build))
        self.assertEqual(self.argv_with("docker", "run")[-1][-1], "sha256:" + "c" * 64)

    def test_success_records_sha_for_deployd_and_unpauses(self):
        self.make_src("hello-app")
        open(os.path.join(self.state, "hello-app.disabled"), "w").close()
        ghapp.healthy = lambda d, t: True
        ghapp.deploy("hello-app")
        self.assertEqual(open(os.path.join(self.state, "hello-app.sha")).read().strip(), SHA)
        self.assertFalse(os.path.exists(os.path.join(self.state, "hello-app.disabled")))

    def test_remove_pauses_the_poller(self):
        os.makedirs(ghapp.app_dir("hello-app"), exist_ok=True)
        ghapp.remove("hello-app")
        self.assertTrue(os.path.exists(os.path.join(self.state, "hello-app.disabled")))

    def test_reused_key_repoints_origin_before_fetching(self):
        self.make_src("hello-app")
        ghapp.healthy = lambda d, t: True
        ghapp.deploy("hello-app")
        seturl = self.argv_with("remote", "set-url")[0]
        fetch = self.argv_with("fetch", "origin")[0]
        self.assertEqual(seturl[-1], "https://github.com/c-wenlong/hello.git")
        self.assertLess(self.calls.index(seturl), self.calls.index(fetch))
        self.assertFalse(self.argv_with("clone"))

    def test_first_deploy_clones(self):
        os.makedirs(ghapp.app_dir("hello-app"))
        ghapp.healthy = lambda d, t: True
        src = os.path.join(ghapp.app_dir("hello-app"), "src")
        real = ghapp.run

        def run(argv, check=True, capture=False, cwd=None):
            if "clone" in argv:
                os.makedirs(os.path.join(src, ".git"))
                open(os.path.join(src, "Dockerfile"), "w").close()
            return real(argv, check, capture, cwd)
        ghapp.run = run
        ghapp.deploy("hello-app")
        self.assertEqual(self.argv_with("clone")[0][-2:],
                         ["https://github.com/c-wenlong/hello.git", src])

    def test_deleted_definition_stops_a_deploy_waiting_on_the_lock(self):
        with ghapp.Lock("hello-app"):
            with self.assertRaises(ghapp.AppError):
                ghapp.deploy("hello-app")      # lock busy


class PlumbingTest(Sandbox):

    def test_serve_ports_reserves_every_port_but_owns_only_proxies(self):
        ghapp.tailscale_bin = lambda: "/bin/ts"
        status = {"TCP": {"443": {}, "8305": {}},
                  "Web": {"box:8305": {"Handlers": {"/": {"Text": "hi"}}},
                          "box:8306": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8306"}}}}}
        self.quiet_out["/bin/ts serve status"] = (0, json.dumps(status))
        ports = ghapp.serve_ports()
        self.assertEqual(ports, {"443": None, "8305": None,
                                 "8306": "http://127.0.0.1:8306"})

    def test_serve_ports_unreadable_is_none(self):
        self.assertIsNone(ghapp.serve_ports())             # no tailscale
        ghapp.tailscale_bin = lambda: "/bin/ts"
        self.quiet_out["/bin/ts serve status"] = (1, "")
        self.assertIsNone(ghapp.serve_ports())
        self.quiet_out["/bin/ts serve status"] = (0, "{nope")
        self.assertIsNone(ghapp.serve_ports())

    def test_prune_keeps_current_and_one_older(self):
        self.quiet_out["docker image ls"] = (0, "r:new\nr:a\nr:b\nr:c\n")
        ghapp.prune_images("hello-app", "r:new")
        removed = [c[-1] for c in self.argv_with("docker", "image", "rm")]
        self.assertEqual(removed, ["r:b", "r:c"])

    def test_healthy_counts_any_answer_below_500(self):
        import http.server
        import threading

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(404 if self.path == "/missing" else 503)
                self.end_headers()

            def log_message(self, *a):
                pass
        srv = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            port = srv.server_address[1]
            self.assertTrue(ghapp.healthy(good(port=port, health_path="/missing"), 3))
            self.assertFalse(ghapp.healthy(good(port=port, health_path="/"), 0.1))
        finally:
            srv.shutdown()
            srv.server_close()

    def test_deployd_state_dir_reads_service_home(self):
        if True:
            home = os.path.join(self.tmp, "dh")
            os.makedirs(os.path.join(home, "state"))
            env = os.path.join(self.tmp, "deployd.env")
            with open(env, "w") as fh:
                fh.write('SERVICE_HOME="%s"\n' % home)
            ghapp.DEPLOYD_ENV = env
            self.assertEqual(ghapp.deployd_state_dir(), os.path.join(home, "state"))
            # setup.sh writes %q-escaped paths; deployd shlex-splits them.
            spaced = os.path.join(self.tmp, "deploy state")
            os.makedirs(os.path.join(spaced, "state"))
            with open(env, "w") as fh:
                fh.write("SERVICE_HOME=%s\n" % spaced.replace(" ", "\\ "))
            self.assertEqual(ghapp.deployd_state_dir(), os.path.join(spaced, "state"))
            fail = os.path.join(spaced, "state", "hello-app.fail")
            with open(fail, "w") as fh:
                fh.write('{"sha": "old"}\n')
            ghapp.record_deployd_sha("hello-app", SHA)
            self.assertFalse(os.path.exists(fail))
            with open(os.path.join(spaced, "state", "hello-app.sha")) as fh:
                self.assertEqual(fh.read().strip(), SHA)
            ghapp.DEPLOYD_ENV = os.path.join(self.tmp, "absent.env")
            ghapp.DEPLOYD_HOME = os.path.join(self.tmp, "nothing-here")
            self.assertIsNone(ghapp.deployd_state_dir())
            ghapp.set_paused("hello-app", True)       # no state dir: a no-op
            ghapp.record_deployd_sha("hello-app", SHA)

    def test_tailscale_bin_prefers_path(self):
        saved = ghapp.shutil.which
        try:
            ghapp.shutil.which = lambda n: "/usr/bin/tailscale"
            self.assertEqual(self._saved[5](), "/usr/bin/tailscale")
        finally:
            ghapp.shutil.which = saved

    def test_reexec_is_skipped_when_docker_answers_or_on_the_second_pass(self):
        execs = []
        saved = ghapp.os.execv
        ghapp.os.execv = lambda *a: execs.append(a)
        try:
            os.environ["GHAPP_SG"] = "1"
            ghapp.reexec_with_docker_group(["ghapp.py", "deploy", "x"])
            os.environ.pop("GHAPP_SG")
            self.quiet_out["docker info"] = (0, "id")
            ghapp.reexec_with_docker_group(["ghapp.py", "deploy", "x"])
            self.assertEqual(execs, [])
            self.quiet_out["docker info"] = (1, "")
            ghapp.reexec_with_docker_group(["ghapp.py", "deploy", "hello-app"])
            if ghapp.shutil.which("sg"):
                self.assertEqual(execs[0][1][1:3], ["docker", "-c"])
                self.assertIn("deploy hello-app", execs[0][1][3])
        finally:
            ghapp.os.execv = saved
            os.environ.pop("GHAPP_SG", None)


class MethodRemoveTest(Sandbox):
    """remove() is method-aware: compose downs its stack, a script without a
    port never needs Serve status."""

    def setUp(self):
        super().setUp()
        os.makedirs(ghapp.app_dir("hello-app"))
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            fh.write("{}")
        self.marker = os.path.join(ghapp.app_dir("hello-app"), "deployed.json")

    def test_compose_remove_downs_the_stack(self):
        self.write_def(method_def("compose"))
        self.make_file("hello-app", "docker-compose.yml")
        self.quiet_out["/bin/ts serve status"] = (0, "{}")
        ghapp.tailscale_bin = lambda: "/bin/ts"
        ghapp.remove("hello-app")
        down = self.argv_with("compose", "down")
        self.assertEqual(len(down), 1)
        self.assertIn("app-hello-app", down[0])
        self.assertIn("--remove-orphans", down[0])
        self.assertFalse(os.path.exists(self.marker))

    def test_compose_remove_without_the_file_uses_the_project_label(self):
        self.write_def(method_def("compose"))
        self.make_src("hello-app")          # checkout exists, no compose file
        self.quiet_out["/bin/ts serve status"] = (0, "{}")
        ghapp.tailscale_bin = lambda: "/bin/ts"
        self.quiet_out["docker ps --all --filter label="] = \
            (0, "app-hello-app-web-1\napp-hello-app-db-1\n")
        ghapp.remove("hello-app")
        rm = self.argv_with("docker", "rm", "--force")
        self.assertEqual(rm[0][-2:], ["app-hello-app-db-1", "app-hello-app-web-1"])
        self.assertFalse(os.path.exists(self.marker))

    def test_script_without_a_port_needs_no_serve_status(self):
        self.write_def(method_def("script", port=None, health_path=None))
        self.make_src("hello-app")
        # tailscale_bin is None in the sandbox; any Serve read would fail.
        ghapp.remove("hello-app")
        self.assertFalse(os.path.exists(self.marker))
        self.assertFalse(self.argv_with("serve"))


class MethodSwitchTest(Sandbox):
    """deploy() owns method switches: it reads the method the previous
    deployed.json recorded and stops, clears or restores the old runtime
    around the new method, whatever started the deploy (the gallery, a
    deployd poll, `ghapp.py deploy` by hand)."""

    OLD_SHA = "a" * 40

    def setUp(self):
        super().setUp()
        os.environ["DEPLOY_SHA"] = SHA
        ghapp.healthy = lambda d, t: True
        self.log = []
        self._say = ghapp.say
        ghapp.say = lambda msg: self.log.append(msg)

    def tearDown(self):
        ghapp.say = self._say
        super().tearDown()

    def app(self):
        return ghapp.app_dir("hello-app")

    def src(self):
        return os.path.join(self.app(), "src")

    def previous(self, method, definition=None, sha=None, **extra):
        """A deployed.json the way an earlier deploy left it. `definition`
        False leaves the field out, as a record from before it existed."""
        os.makedirs(self.app(), exist_ok=True)
        rec = {"sha": sha or self.OLD_SHA, "image": None, "method": method,
               "ref": "main", "at": "2026-11-01T00:00:00Z"}
        if definition is not False:
            rec["definition"] = definition or (
                good() if method == "dockerfile" else method_def(method))
        rec.update(extra)
        with open(os.path.join(self.app(), "deployed.json"), "w") as fh:
            json.dump(rec, fh)

    def record(self):
        with open(os.path.join(self.app(), "deployed.json")) as fh:
            return json.load(fh)

    def index(self, *words):
        """Position of the first call holding every word, or -1."""
        for i, c in enumerate(self.calls):
            if all(w in c for w in words):
                return i
        return -1

    def logged(self, text):
        return any(text in line for line in self.log)

    # ---- compose -> anything

    def test_compose_to_image_downs_the_old_stack_first(self):
        # The earlier compose deploy is a real one: its record carries the
        # definition the switch takes the stack down by.
        self.write_def(method_def("compose", compose_file="deploy/compose.yml"))
        self.make_file("hello-app", "deploy/compose.yml")
        ghapp.deploy("hello-app")
        self.assertEqual(self.record()["definition"]["compose_file"],
                         "deploy/compose.yml")
        self.calls[:] = []
        self.write_def(method_def("image"))
        ghapp.deploy("hello-app")
        down = self.index("compose", "down")
        self.assertGreaterEqual(down, 0)
        argv = self.calls[down]
        self.assertEqual(argv[argv.index("--project-name") + 1], "app-hello-app")
        self.assertEqual(argv[argv.index("--file") + 1],
                         os.path.join(self.src(), "deploy", "compose.yml"))
        # Before the checkout moves src/ off the commit the stack ran from.
        self.assertLess(down, self.index("checkout", "--force", SHA))
        self.assertLess(down, self.index("docker", "run"))
        self.assertEqual(self.index("compose", "up"), -1)    # no restore
        self.assertEqual(self.record()["method"], "image")
        self.assertTrue(self.logged("method change compose -> image"))

    def test_compose_to_image_failure_restores_the_old_stack(self):
        self.write_def(method_def("image"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("compose")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        run = self.index("docker", "run")
        rm = max(i for i, c in enumerate(self.calls)
                 if c == ["docker", "rm", "--force", "app-hello-app"])
        back = self.index("checkout", "--detach", self.OLD_SHA)
        up = self.index("compose", "up", "--detach")
        # Clear what the image method started, re-check-out the commit the
        # stack ran from, then bring it up again.
        self.assertTrue(run < rm < back < up, (run, rm, back, up))
        self.assertEqual(self.calls[up][-2:], ["up", "--detach"])
        self.assertEqual(self.record()["method"], "compose")   # untouched
        self.assertTrue(self.logged("bringing the old compose stack back"))

    def test_compose_restore_needs_no_fetch_from_the_old_repo(self):
        # Repo and method changed together: the old remote may be gone, and
        # src/ already holds the commit the stack ran from.
        self.write_def(method_def("image", repo="c-wenlong/elsewhere"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("compose")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        run = self.index("docker", "run")
        tail = self.calls[run:]
        self.assertFalse([c for c in tail if "fetch" in c or "set-url" in c])
        self.assertIn(["git", "-C", self.src(), "checkout", "--quiet", "--force",
                       "--detach", self.OLD_SHA], tail)
        self.assertTrue([c for c in tail if c[-2:] == ["up", "--detach"]])

    def test_compose_restore_fetches_only_when_the_commit_is_missing(self):
        self.write_def(method_def("image"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("compose")
        ghapp.healthy = lambda d, t: False
        real, missing = ghapp.run, [True]

        def run(argv, check=True, capture=False, cwd=None):
            if self.OLD_SHA in argv and "checkout" in argv and missing:
                missing.pop()
                self.calls.append(list(argv))
                raise ghapp.AppError("git exited 128")
            return real(argv, check, capture, cwd)
        ghapp.run = run
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        fetch = self.index("fetch", "origin", self.OLD_SHA)
        self.assertGreater(fetch, self.index("docker", "run"))
        self.assertGreater(self.index("compose", "up", "--detach"), fetch)

    def test_a_failed_compose_down_restores_and_never_deploys(self):
        self.write_def(method_def("image"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("compose")
        self.run_codes["docker compose"] = 1
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(self.index("docker", "pull"), -1)
        self.assertGreaterEqual(self.index("compose", "up", "--detach"), 0)

    def test_compose_record_without_definition_downs_by_project_label(self):
        self.write_def(method_def("image"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("compose", definition=False)
        self.quiet_out["docker ps --all --filter label=com.docker.compose."
                       "project=app-hello-app"] = (0, "app-hello-app-web-1\n")
        ghapp.deploy("hello-app")
        self.assertEqual(self.index("compose", "down"), -1)
        rm = self.calls.index(["docker", "rm", "--force", "app-hello-app-web-1"])
        self.assertLess(rm, self.index("docker", "run"))
        self.assertTrue(self.logged("predates `definition`"))

    def test_compose_record_without_definition_cannot_restore_and_says_so(self):
        self.write_def(method_def("image"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("compose", definition=False)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(self.index("compose", "up"), -1)
        self.assertEqual(self.index("checkout", "--detach", self.OLD_SHA), -1)
        self.assertTrue(self.logged("not restoring the old stack"))

    def test_compose_restore_without_the_old_file_says_so(self):
        self.write_def(method_def("image"))
        self.make_file("hello-app", "Dockerfile")       # no compose file
        self.previous("compose")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertEqual(self.index("compose", "up"), -1)
        self.assertTrue(self.logged("the old compose stack was not restored"))

    # ---- container -> script

    def test_container_to_script_stops_the_container_first(self):
        self.write_def(method_def("script"))
        self.make_src("hello-app")
        self.previous("dockerfile")
        ghapp.deploy("hello-app")
        stop = self.calls.index(["docker", "stop", "app-hello-app"])
        self.assertLess(stop, self.index("sh", "-c", "./run.sh"))
        self.assertNotIn(["docker", "start", "app-hello-app"], self.calls)
        self.assertNotIn(["docker", "rm", "--force", "app-hello-app"], self.calls)
        self.assertEqual(self.record()["method"], "script")

    def test_container_to_script_failure_starts_it_again(self):
        self.write_def(method_def("script"))
        self.make_src("hello-app")
        self.previous("image")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        start = self.calls.index(["docker", "start", "app-hello-app"])
        self.assertGreater(start, self.index("sh", "-c", "./run.sh"))
        self.assertEqual(self.record()["method"], "image")

    def test_a_stop_that_fails_is_noted_not_fatal(self):
        self.write_def(method_def("script"))
        self.make_src("hello-app")
        self.previous("static")
        self.run_codes["docker stop"] = 1        # nothing was running
        ghapp.deploy("hello-app")
        self.assertTrue(self.logged("docker stop app-hello-app exited 1"))
        self.assertEqual(self.record()["method"], "script")

    # ---- container -> compose

    def test_container_to_compose_parks_until_the_stack_is_up(self):
        self.write_def(method_def("compose"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("dockerfile")
        ghapp.deploy("hello-app")
        # Never a name another app could own: KEY_RE has no dot.
        self.assertIsNone(ghapp.KEY_RE.match("hello-app.parked"))
        park = [["docker", "rename", "app-hello-app", "app-hello-app.parked"],
                ["docker", "stop", "app-hello-app.parked"]]
        first = self.calls.index(park[0])
        self.assertEqual(self.calls[first:first + 2], park)
        up = self.index("compose", "up", "--detach")
        self.assertLess(first, up)
        # Success only: the parked container goes once the stack answers.
        drop = self.calls.index(["docker", "rm", "--force", "app-hello-app.parked"])
        self.assertGreater(drop, up)
        self.assertNotIn(["docker", "start", "app-hello-app"], self.calls)
        # An earlier dockerfile sha holds no stack: no compose rollback.
        self.assertEqual(self.index("checkout", "--detach", self.OLD_SHA), -1)
        self.assertEqual(self.record()["method"], "compose")

    def test_container_to_compose_failure_puts_the_container_back(self):
        self.write_def(method_def("compose"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("node")
        self.quiet_out["docker ps --all --filter label=com.docker.compose."
                       "project=app-hello-app"] = (0, "app-hello-app-web-1\n")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        up = self.index("compose", "up", "--detach")
        tail = self.calls[up:]
        clear = tail.index(["docker", "rm", "--force", "app-hello-app-web-1"])
        back = tail.index(["docker", "rename", "app-hello-app.parked",
                           "app-hello-app"])
        start = tail.index(["docker", "start", "app-hello-app"])
        self.assertTrue(clear < back < start)
        self.assertEqual(len(self.argv_with("compose", "up")), 1)
        self.assertEqual(self.index("checkout", "--detach", self.OLD_SHA), -1)
        self.assertEqual(self.record()["method"], "node")

    def test_a_stale_parked_container_beside_a_live_one_is_replaced(self):
        self.write_def(method_def("compose"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("dockerfile")
        self.quiet_out["docker ps --all --filter name=^/app-hello-app"] = (
            0, "app-hello-app\napp-hello-app.parked\n")
        ghapp.deploy("hello-app")
        rm = self.calls.index(["docker", "rm", "--force", "app-hello-app.parked"])
        self.assertLess(rm, self.calls.index(
            ["docker", "rename", "app-hello-app", "app-hello-app.parked"]))

    def test_a_retry_after_an_interrupted_switch_keeps_the_parked_container(self):
        # A deployd timeout killed the last switch after the rename: the
        # parked container is still the working version.
        self.write_def(method_def("compose"))
        self.make_file("hello-app", "docker-compose.yml")
        self.previous("dockerfile")
        self.quiet_out["docker ps --all --filter name=^/app-hello-app"] = (
            0, "app-hello-app.parked\n")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        up = self.index("compose", "up", "--detach")
        before = self.calls[:up]
        self.assertNotIn(["docker", "rm", "--force", "app-hello-app.parked"], before)
        self.assertNotIn(["docker", "rename", "app-hello-app",
                          "app-hello-app.parked"], before)
        self.assertIn(["docker", "stop", "app-hello-app.parked"], before)
        # ...and the failure still puts it back under its own name.
        tail = self.calls[up:]
        self.assertIn(["docker", "rename", "app-hello-app.parked",
                       "app-hello-app"], tail)
        self.assertIn(["docker", "start", "app-hello-app"], tail)
        self.assertTrue(self.logged("still parked from an interrupted switch"))

    # ---- script -> anything, same method, nothing deployed

    def test_leaving_script_stops_nothing_and_says_so(self):
        self.write_def(method_def("image"))
        self.make_src("hello-app")
        self.previous("script")
        ghapp.deploy("hello-app")
        self.assertEqual(self.index("docker", "stop"), -1)
        self.assertEqual(self.index("compose", "down"), -1)
        self.assertEqual(self.index("rename"), -1)
        self.assertTrue(self.logged("a script's own processes are not managed"))
        self.assertEqual(self.record()["method"], "image")

    def test_same_method_or_container_to_container_needs_no_switch(self):
        self.write_def(good())
        self.make_src("hello-app")
        for was in ("dockerfile", "image", None):
            if was:
                self.previous(was)
            self.calls[:], self.cwds[:], self.envs[:] = [], [], []
            self.log[:] = []
            ghapp.deploy("hello-app")
            self.assertEqual(self.index("docker", "stop"), -1, was)
            self.assertEqual(self.index("rename"), -1, was)
            self.assertFalse(self.logged("method change"), was)
            os.remove(os.path.join(self.app(), "deployed.json"))

    def test_a_record_from_before_methods_is_dockerfile(self):
        self.write_def(method_def("compose"))
        self.make_file("hello-app", "docker-compose.yml")
        os.makedirs(self.app(), exist_ok=True)
        with open(os.path.join(self.app(), "deployed.json"), "w") as fh:
            json.dump({"sha": self.OLD_SHA, "image": "launcher-app/x:1"}, fh)
        ghapp.deploy("hello-app")
        self.assertIn(["docker", "rename", "app-hello-app",
                       "app-hello-app.parked"], self.calls)

    # ---- the record

    def test_every_deploy_records_the_definition_it_ran(self):
        d = method_def("node", env_names=["API_TOKEN"])
        self.write_def(d)
        self.make_src("hello-app")
        with open(os.path.join(self.app(), ".env"), "w") as fh:
            fh.write("API_TOKEN=hunter2-very-secret\n")
        ghapp.deploy("hello-app")
        rec = self.record()
        self.assertEqual(rec["definition"], d)
        self.assertEqual((rec["sha"], rec["method"], rec["ref"]),
                         (SHA, "node", "main"))
        # A definition holds names, never values: nothing from .env lands.
        self.assertNotIn("hunter2", json.dumps(rec))


class DeploydShaTest(Sandbox):
    """$DEPLOY_SHA must be on origin/<ref>: deployd records the sha it asked
    for as done, so a commit the fetch could not bring down (or one off the
    branch) must fail the deploy and let deployd retry."""

    OTHER = "f" * 40

    def setUp(self):
        super().setUp()
        self.write_def(good())
        self.src = self.make_src("hello-app")
        ghapp.healthy = lambda d, t: True

    def git(self, *tail):
        return " ".join(["git", "-C", self.src] + list(tail))

    def test_an_ancestor_of_the_ref_is_accepted(self):
        os.environ["DEPLOY_SHA"] = SHA
        ghapp.deploy("hello-app")
        fetch = self.argv_with("fetch", "origin")
        self.assertEqual(fetch[0][-1], "+main:refs/remotes/origin/main")
        self.assertFalse(self.argv_with("fetch", "origin", SHA))
        check = self.argv_with("merge-base", "--is-ancestor")[0]
        self.assertEqual(check[-2:], [SHA, "refs/remotes/origin/main"])
        self.assertLess(self.calls.index(fetch[0]), self.calls.index(check))
        self.assertLess(self.calls.index(check),
                        self.calls.index(self.argv_with("checkout", "--force")[0]))
        self.assertTrue(self.argv_with("docker", "build"))
        self.assertFalse(self.argv_with("ls-remote"))

    def test_a_sha_off_the_ref_fails_before_anything_changes(self):
        os.environ["DEPLOY_SHA"] = SHA
        self.quiet_out[self.git("merge-base")] = (1, "")
        self.quiet_out[self.git("rev-parse")] = (0, self.OTHER + "\n")
        # A compose stack is deployed: a refused sha must not take it down.
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            json.dump({"sha": "a" * 40, "method": "compose",
                       "definition": method_def("compose")}, fh)
        with self.assertRaises(ghapp.AppError) as ctx:
            ghapp.deploy("hello-app")
        self.assertEqual(str(ctx.exception),
                         "deployd asked for %s but origin/main is at %s (fetch "
                         "failed or diverged); failing so it retries"
                         % (SHA, self.OTHER))
        self.assertFalse(self.argv_with("checkout", "--force"))
        self.assertFalse(self.argv_with("docker"))
        # ...and the CLI exits non-zero, which is what deployd backs off on.
        os.environ["GHAPP_SG"] = "1"     # skip the docker-group re-exec
        self.addCleanup(os.environ.pop, "GHAPP_SG", None)
        self.assertEqual(ghapp.main(["ghapp.py", "deploy", "hello-app"]), 1)

    def test_a_fetch_that_fails_fails_the_deploy(self):
        os.environ["DEPLOY_SHA"] = SHA
        self.run_codes[self.git("fetch")] = 128
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        self.assertFalse(self.argv_with("merge-base"))
        self.assertFalse(self.argv_with("docker", "build"))

    def test_without_deploy_sha_the_resolved_sha_is_fetched_directly(self):
        self.quiet_out["git ls-remote"] = (0, "%s\trefs/heads/main\n" % SHA)
        ghapp.deploy("hello-app")
        self.assertTrue(self.argv_with("fetch", "origin", SHA))
        self.assertFalse(self.argv_with("merge-base"))


class StaticProxyTest(Sandbox):
    """static's optional proxies + cache_control: validation, the nginx
    config they generate beside each release, the host-gateway mapping,
    and a rollback serving the previous release with ITS config."""

    API = [{"path": "/api/", "port": 8089}]
    OLD_SHA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    def setUp(self):
        super().setUp()
        os.environ["DEPLOY_SHA"] = SHA
        ghapp.healthy = lambda d, t: True

    def deployed(self):
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json")) as fh:
            return json.load(fh)

    def deploy_quietly(self):
        with contextlib.redirect_stdout(io.StringIO()):
            ghapp.deploy("hello-app")

    # --- validation

    def test_good_proxies_and_cache_control_pass(self):
        ghapp.validate(method_def("static", proxies=self.API,
                                  cache_control="no-cache"))
        ghapp.validate(method_def("static", proxies=[], cache_control=None))
        ghapp.validate(method_def("static", proxies=None))
        ghapp.validate(method_def("static", proxies=[
            {"path": "/api", "port": 1}, {"path": "/a.b/c_d~e-f/", "port": 65535}]))
        ghapp.validate(method_def("static",
                                  cache_control="max-age=60, must-revalidate"))
        ten = [{"path": "/p%d/" % i, "port": 9000 + i} for i in range(10)]
        ghapp.validate(method_def("static", proxies=ten))

    def test_bad_proxies_are_refused(self):
        bad = [
            "/api/",                                       # not a list
            {"path": "/api/", "port": 8089},
            [{"path": "/", "port": 8089}],                 # would shadow the site
            [{"path": "", "port": 8089}],
            [{"path": "api/", "port": 8089}],              # not rooted
            [{"path": "/a b/", "port": 8089}],
            [{"path": "/api/;", "port": 8089}],
            [{"path": "/api/{", "port": 8089}],
            [{"path": '/api/"', "port": 8089}],
            [{"path": "/api//x", "port": 8089}],
            [{"path": "/../x/", "port": 8089}],            # never matches
            [{"path": "/./", "port": 8089}],
            [{"path": "/api/", "port": 0}],
            [{"path": "/api/", "port": 65536}],
            [{"path": "/api/", "port": "8089"}],
            [{"path": "/api/", "port": True}],             # bool is not a port
            [{"path": "/api/", "port": 80.5}],
            [{"path": "/api/"}],
            [{"path": "/api/", "port": 8089, "host": "evil"}],
            [{"path": "/api/", "port": 8089}, {"path": "/api/", "port": 9}],
            [{"path": "/api/\n", "port": 8089}],             # `$` alone allows it
            [{"path": "/api/\n", "port": 8089}, {"path": "/api/", "port": 9}],
            ["/api/"],
            [{"path": "/p%d/" % i, "port": 9000 + i} for i in range(11)],
        ]
        for v in bad:
            with self.assertRaises(ghapp.AppError, msg=v) as ctx:
                ghapp.validate(method_def("static", proxies=v))
            self.assertTrue(str(ctx.exception).startswith("bad proxies"), v)

    def test_bad_cache_control_is_refused(self):
        for v in ("", "   ", 'no-cache"; add_header X "y', "no-cache;", "a\nb", "no-cache\n",
                  "x" * 101, 3, ["no-cache"], "no{cache}"):
            with self.assertRaises(ghapp.AppError, msg=v) as ctx:
                ghapp.validate(method_def("static", cache_control=v))
            self.assertTrue(str(ctx.exception).startswith("bad cache_control"))

    def test_frame_ancestors_none_passes_and_anything_else_is_refused(self):
        ghapp.validate(method_def("static", frame_ancestors="none"))
        ghapp.validate(method_def("static", frame_ancestors=None))
        for v in ("", "self", "'none'", "NONE", "none;", "none\n", True, 0,
                  ["none"], {"none": 1}, "https://evil.example"):
            with self.assertRaises(ghapp.AppError, msg=v) as ctx:
                ghapp.validate(method_def("static", frame_ancestors=v))
            self.assertTrue(str(ctx.exception).startswith("bad frame_ancestors"), v)

    # --- the generated config

    def test_no_extras_means_no_config_and_no_add_host(self):
        self.assertIsNone(ghapp.static_conf(method_def("static")))
        self.assertIsNone(ghapp.static_conf(method_def("static", proxies=[])))
        self.write_def(method_def("static"))
        self.make_file("hello-app", "public/index.html")
        self.deploy_quietly()
        run = self.argv_with("docker", "run")[-1]
        self.assertNotIn("--add-host", run)
        self.assertEqual(run.count("--volume"), 1)     # the docroot only
        app = ghapp.app_dir("hello-app")
        self.assertFalse([n for n in os.listdir(app) if n.endswith(".nginx.conf")])

    def test_config_holds_the_proxy_blocks_and_header(self):
        text = ghapp.static_conf(method_def("static", proxies=[
            {"path": "/api/", "port": 8089}, {"path": "/hooks", "port": 9000}],
            cache_control="no-cache"))
        self.assertIn("    location /api/ {\n"
                      "        proxy_pass http://host.docker.internal:8089;\n"
                      "        proxy_http_version 1.1;\n"
                      "        proxy_buffering off;\n"
                      "        proxy_read_timeout 600s;\n"
                      "        proxy_set_header Host $host;\n"
                      "    }\n", text)
        self.assertIn("location /hooks {\n"
                      "        proxy_pass http://host.docker.internal:9000;\n", text)
        # No URI part: the request path reaches the target unchanged.
        for line in text.splitlines():
            if "proxy_pass" in line:
                self.assertRegex(line, r"proxy_pass http://host\.docker\.internal:\d+;$")
        files = text[text.index("    location / {"):]
        files = files[:files.index("    }") + 5]
        self.assertEqual(files, "    location / {\n"
                                "        root   /usr/share/nginx/html;\n"
                                "        index  index.html index.htm;\n"
                                '        add_header Cache-Control "no-cache";\n'
                                "    }")
        self.assertIn("error_page   500 502 503 504  /50x.html;", text)
        self.assertEqual(text.count("{"), text.count("}"))

    def test_cache_control_alone_adds_only_the_header(self):
        text = ghapp.static_conf(method_def("static", cache_control="no-cache"))
        self.assertNotIn("proxy_pass", text)
        self.assertIn('add_header Cache-Control "no-cache";', text)
        self.write_def(method_def("static", cache_control="no-cache"))
        self.make_file("hello-app", "public/index.html")
        self.deploy_quietly()
        run = self.argv_with("docker", "run")[-1]
        self.assertNotIn("--add-host", run)               # nothing to reach
        name = self.deployed()["release"]
        conf = os.path.join(ghapp.app_dir("hello-app"), name + ".nginx.conf")
        self.assertIn(conf + ":/etc/nginx/conf.d/default.conf:ro", run)

    def test_frame_ancestors_adds_both_anti_framing_headers_on_the_files(self):
        text = ghapp.static_conf(method_def("static", proxies=self.API,
                                            cache_control="no-cache",
                                            frame_ancestors="none"))
        files = text[text.index("    location / {"):]
        files = files[:files.index("    }") + 5]
        self.assertEqual(files, "    location / {\n"
                                "        root   /usr/share/nginx/html;\n"
                                "        index  index.html index.htm;\n"
                                '        add_header Cache-Control "no-cache";\n'
                                "        add_header Content-Security-Policy "
                                "\"frame-ancestors 'none'\" always;\n"
                                "        add_header X-Frame-Options DENY always;\n"
                                "    }")
        err = text[text.index("    location = /50x.html {"):]
        self.assertEqual(err, "    location = /50x.html {\n"
                              "        root   /usr/share/nginx/html;\n"
                              "        add_header Content-Security-Policy "
                              "\"frame-ancestors 'none'\" always;\n"
                              "        add_header X-Frame-Options DENY always;\n"
                              "    }\n}\n")
        self.assertEqual(text.count("Content-Security-Policy"), 2)
        self.assertEqual(text.count("{"), text.count("}"))

    def test_frame_ancestors_alone_writes_a_config_without_other_extras(self):
        text = ghapp.static_conf(method_def("static", frame_ancestors="none"))
        self.assertNotIn("proxy_pass", text)
        self.assertNotIn("Cache-Control", text)
        self.assertIn("add_header X-Frame-Options DENY always;", text)
        self.write_def(method_def("static", frame_ancestors="none"))
        self.make_file("hello-app", "public/index.html")
        self.deploy_quietly()
        run = self.argv_with("docker", "run")[-1]
        self.assertNotIn("--add-host", run)
        conf = os.path.join(ghapp.app_dir("hello-app"),
                            self.deployed()["release"] + ".nginx.conf")
        self.assertIn(conf + ":/etc/nginx/conf.d/default.conf:ro", run)

    def test_without_frame_ancestors_no_anti_framing_header(self):
        text = ghapp.static_conf(method_def("static", cache_control="no-cache"))
        self.assertNotIn("frame-ancestors", text)
        self.assertNotIn("X-Frame-Options", text)

    def test_proxies_mount_the_config_beside_the_release_and_add_the_host(self):
        self.write_def(method_def("static", proxies=self.API,
                                  cache_control="no-cache"))
        self.make_file("hello-app", "public/index.html", "v2")
        self.deploy_quietly()
        run = self.argv_with("docker", "run")[-1]
        name = self.deployed()["release"]
        app = ghapp.app_dir("hello-app")
        release = os.path.join(app, name)
        conf = release + ".nginx.conf"
        vols = [run[i + 1] for i, w in enumerate(run) if w == "--volume"]
        self.assertEqual(vols, [release + ":/usr/share/nginx/html:ro",
                                conf + ":/etc/nginx/conf.d/default.conf:ro"])
        self.assertEqual(run[run.index("--add-host") + 1],
                         "host.docker.internal:host-gateway")
        self.assertEqual(run[-1], ghapp.STATIC_IMAGE)
        self.assertNotIn("--env-file", run)
        # Beside the release, never inside it (nginx would serve it).
        self.assertFalse(os.path.exists(os.path.join(release, "default.conf")))
        self.assertEqual(sorted(os.listdir(release)), ["index.html"])
        with open(conf) as fh:
            self.assertEqual(fh.read(), ghapp.static_conf(
                method_def("static", proxies=self.API, cache_control="no-cache")))
        self.assertEqual(os.stat(conf).st_mode & 0o777, 0o644)

    def test_rollback_serves_the_previous_release_with_its_own_config(self):
        app = ghapp.app_dir("hello-app")
        # The previous release proxied; this deploy's definition does not.
        prev = "site-%s-1000" % self.OLD_SHA[:12]
        os.makedirs(os.path.join(app, prev))
        old_conf = os.path.join(app, prev + ".nginx.conf")
        with open(old_conf, "w") as fh:
            fh.write(ghapp.static_conf(method_def("static", proxies=self.API)))
        with open(os.path.join(app, "deployed.json"), "w") as fh:
            json.dump({"sha": self.OLD_SHA, "method": "static", "release": prev}, fh)
        self.write_def(method_def("static", cache_control="no-cache"))
        self.make_file("hello-app", "public/index.html")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "d" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        new, back = self.argv_with("docker", "run")
        self.assertNotIn("--add-host", new)
        self.assertEqual(back[-1], "sha256:" + "d" * 64)
        vols = [back[i + 1] for i, w in enumerate(back) if w == "--volume"]
        self.assertEqual(vols, [os.path.join(app, prev) + ":/usr/share/nginx/html:ro",
                                old_conf + ":/etc/nginx/conf.d/default.conf:ro"])
        self.assertEqual(back[back.index("--add-host") + 1],
                         "host.docker.internal:host-gateway")
        # The failed release and its config are gone; the old pair stays.
        self.assertEqual(sorted(n for n in os.listdir(app) if n.startswith("site-")),
                         sorted([prev, prev + ".nginx.conf"]))

    def test_rollback_to_a_release_without_config_uses_the_default(self):
        app = ghapp.app_dir("hello-app")
        prev = "site-%s-1000" % self.OLD_SHA[:12]
        os.makedirs(os.path.join(app, prev))
        with open(os.path.join(app, "deployed.json"), "w") as fh:
            json.dump({"sha": self.OLD_SHA, "method": "static", "release": prev}, fh)
        self.write_def(method_def("static", proxies=self.API))
        self.make_file("hello-app", "public/index.html")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "d" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        new, back = self.argv_with("docker", "run")
        self.assertIn("--add-host", new)
        self.assertNotIn("--add-host", back)
        self.assertEqual(back.count("--volume"), 1)

    def test_switch_off_static_rollback_keeps_the_release_config(self):
        app = ghapp.app_dir("hello-app")
        prev = "site-%s-1000" % self.OLD_SHA[:12]
        os.makedirs(os.path.join(app, prev))
        with open(os.path.join(app, prev + ".nginx.conf"), "w") as fh:
            fh.write(ghapp.static_conf(method_def("static", proxies=self.API)))
        with open(os.path.join(app, "deployed.json"), "w") as fh:
            json.dump({"sha": self.OLD_SHA, "method": "static", "release": prev}, fh)
        self.write_def(method_def("image"))
        self.make_src("hello-app")
        self.quiet_out["docker inspect"] = (0, "sha256:" + "f" * 64)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        new, back = self.argv_with("docker", "run")
        self.assertNotIn("--add-host", new)
        self.assertIn("127.0.0.1:8301:80", back)
        self.assertIn("--add-host", back)
        self.assertIn(os.path.join(app, prev + ".nginx.conf")
                      + ":/etc/nginx/conf.d/default.conf:ro", back)

    def test_prune_drops_old_configs_with_their_releases(self):
        app = ghapp.app_dir("hello-app")
        prev = "site-%s-1000" % self.OLD_SHA[:12]
        stale = "site-bbbbbbbbbbbb-5"
        for n in (prev, stale):
            os.makedirs(os.path.join(app, n))
            open(os.path.join(app, n + ".nginx.conf"), "w").close()
        open(os.path.join(app, stale + ".nginx.conf.tmp"), "w").close()
        with open(os.path.join(app, "deployed.json"), "w") as fh:
            json.dump({"sha": self.OLD_SHA, "method": "static", "release": prev}, fh)
        self.write_def(method_def("static", proxies=self.API))
        self.make_file("hello-app", "public/index.html")
        self.deploy_quietly()
        cur = self.deployed()["release"]
        self.assertEqual(sorted(n for n in os.listdir(app) if n.startswith("site-")),
                         sorted([cur, cur + ".nginx.conf", prev, prev + ".nginx.conf"]))

    def test_a_failed_pull_drops_the_new_config_too(self):
        self.write_def(method_def("static", proxies=self.API))
        self.make_file("hello-app", "public/index.html")
        self.run_codes["docker pull"] = 1
        with self.assertRaises(ghapp.AppError):
            self.deploy_quietly()
        app = ghapp.app_dir("hello-app")
        self.assertFalse([n for n in os.listdir(app) if n.startswith("site-")])

    def test_add_host_only_reaches_run_argv_when_asked(self):
        self.assertNotIn("--add-host", ghapp.run_argv(good(), "img:1"))
        argv = ghapp.run_argv(good(), "img:1", add_host=True)
        self.assertEqual(argv[argv.index("--add-host") + 1],
                         "host.docker.internal:host-gateway")
        self.assertEqual(argv[-1], "img:1")


class ForceFlagTest(Sandbox):
    """`ghapp.py deploy <key> --force`: accepted, changes nothing."""

    def setUp(self):
        super().setUp()
        os.environ["GHAPP_SG"] = "1"     # skip the docker-group re-exec
        self.addCleanup(os.environ.pop, "GHAPP_SG", None)
        self.seen = []
        self._deploy, self._remove = ghapp.deploy, ghapp.remove
        ghapp.deploy = lambda key: self.seen.append(("deploy", key))
        ghapp.remove = lambda key: self.seen.append(("remove", key))

    def tearDown(self):
        ghapp.deploy, ghapp.remove = self._deploy, self._remove
        super().tearDown()

    def main(self, *args):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            code = ghapp.main(["ghapp.py"] + list(args))
        return code, err.getvalue()

    def test_force_is_a_no_op_on_deploy(self):
        self.assertEqual(self.main("deploy", "hello-app", "--force")[0], 0)
        self.assertEqual(self.main("deploy", "hello-app")[0], 0)
        self.assertEqual(self.seen, [("deploy", "hello-app")] * 2)

    def test_force_is_not_a_remove_flag_or_any_other_word(self):
        for args in (("remove", "hello-app", "--force"),
                     ("deploy", "hello-app", "--forc"),
                     ("deploy", "hello-app", "--force", "x"),
                     ("deploy", "--force", "hello-app")):
            code, err = self.main(*args)
            self.assertEqual(code, 2, args)
            self.assertIn("deploy <key> [--force]", err)
        self.assertEqual(self.seen, [])
