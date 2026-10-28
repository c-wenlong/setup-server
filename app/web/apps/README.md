# Exported GitHub apps

One `<key>.json` per app built from a GitHub repo by the launcher
(`app/web/ghapp.py`). Each is a copy of the box's
`~/services/launcher/apps/<key>.json`, added here by the launcher's
**Export to repo** button as a pull request, never by hand.

The files carry no secrets: an app's `.env` stays on the box, and the export
PR lists only its variable names. CI checks every file here is a definition
the runner accepts, named for its key, on its own port in 8300–8399, and
not clashing with a service in `services.json`
(`ExportedAppsInRepoTest` in `app/web/tests/test_server.py`).

The launcher compares each file with the box copy to show "Saved in this
repo" on the app's detail page. A file here with no box copy shows as a
not-installed app under From GitHub; Install copies it onto the box (a new
port if its own is taken), starts its `.env` from `env_names` with empty
values, and deploys it.
