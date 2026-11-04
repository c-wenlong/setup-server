"""Mocked tests for app/web/ghapp.py, the GitHub-app runner.

No docker, git, tailscale or network: every subprocess goes through
ghapp.run / ghapp.quiet, which these tests replace, and the state dirs point
at a temp dir. Run from app/web/:

    python3 -m unittest discover -s tests -p 'test_*.py'
"""

import json
import os
import shutil
import sys
import tempfile
import unittest

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
        self.quiet_out = {}
        self.run_codes = {}

        def fake_run(argv, check=True, capture=False, cwd=None):
            self.calls.append(list(argv))
            self.cwds.append(cwd)
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
            json.dump({"sha": self.OLD_SHA}, fh)
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        # Re-checkout of the old sha, then up -d again.
        back = self.argv_with("checkout", "--detach", self.OLD_SHA)
        self.assertTrue(back)
        ups = self.argv_with("compose", "up", "--detach")
        self.assertEqual(len(ups), 2)
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

    def test_static_builds_then_serves_output_read_only(self):
        self.write_method("static")
        src = self.make_src("hello-app")
        os.makedirs(os.path.join(src, "public"))
        ghapp.deploy("hello-app")
        idx = self.calls.index(self.argv_with("sh", "-c", "make site")[0])
        self.assertEqual(self.cwds[idx], src)
        self.assertTrue(self.argv_with("docker", "pull", ghapp.STATIC_IMAGE))
        run = self.argv_with("docker", "run")[-1]
        self.assertIn("127.0.0.1:8301:80", run)
        mount = run[run.index("--volume") + 1]
        self.assertTrue(mount.endswith(":/usr/share/nginx/html:ro"), mount)
        self.assertTrue(mount.startswith(os.path.join(src, "public")), mount)
        self.assertEqual(self.deployed()["image"], ghapp.STATIC_IMAGE)

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
