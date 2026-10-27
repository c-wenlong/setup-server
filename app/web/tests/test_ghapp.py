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


class Sandbox(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ghapp-test-")
        self._saved = (ghapp.DEFS_DIR, ghapp.APPS_HOME, ghapp.run, ghapp.quiet,
                       ghapp.healthy, ghapp.tailscale_bin, os.environ.get("DEPLOY_SHA"))
        ghapp.DEFS_DIR = os.path.join(self.tmp, "defs")
        ghapp.APPS_HOME = os.path.join(self.tmp, "apps")
        os.makedirs(ghapp.DEFS_DIR)
        self.calls = []
        self.quiet_out = {}

        def fake_run(argv, check=True, capture=False, cwd=None):
            self.calls.append(list(argv))

            class R(object):
                returncode = 0
                stdout = ""
            return R()

        def fake_quiet(argv, cwd=None):
            self.calls.append(list(argv))
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
         ghapp.healthy, ghapp.tailscale_bin, sha) = self._saved
        if sha is None:
            os.environ.pop("DEPLOY_SHA", None)
        else:
            os.environ["DEPLOY_SHA"] = sha
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write_def(self, d):
        with open(ghapp.def_path(d["key"]), "w") as fh:
            json.dump(d, fh)

    def make_src(self, key, dockerfile="Dockerfile"):
        src = os.path.join(ghapp.app_dir(key), "src")
        os.makedirs(os.path.join(src, ".git"), exist_ok=True)
        path = os.path.join(src, dockerfile)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, "w").close()
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
        self.quiet_out["docker inspect"] = (0, "launcher-app/hello-app:oldoldoldold\n")
        ghapp.healthy = lambda d, t: False
        with self.assertRaises(ghapp.AppError):
            ghapp.deploy("hello-app")
        runs = self.argv_with("docker", "run")
        self.assertEqual(runs[-1][-1], "launcher-app/hello-app:oldoldoldold")
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


class RemoveTest(Sandbox):

    def setUp(self):
        super().setUp()
        self.write_def(good())
        os.makedirs(ghapp.app_dir("hello-app"))
        with open(os.path.join(ghapp.app_dir("hello-app"), "deployed.json"), "w") as fh:
            fh.write("{}")
        ghapp.tailscale_bin = lambda: "/bin/tailscale"

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
