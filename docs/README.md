# docs/

Reference documentation and the project's GitHub Pages site.

| File | What it is |
| --- | --- |
| `commands.md` | every command, subcommand, option, exit code, and example |
| `settings.md` | every setting, its default, precedence, and the state layout |
| `architecture.md` | how it works: runtime, `sync`/`setup` flow, layer and release diagrams; module map, conventions, lock/state/HTTP design |
| `parity.md` | the Nextcloud Desktop client parity matrix and its limits |
| `index.html` | the landing page published at [sebastianspicker.github.io/rclone-webdav-sync](https://sebastianspicker.github.io/rclone-webdav-sync/) |
| `assets/screenshots/` | real CLI output rendered to SVG by `tools/screenshots.py` (`make screenshots`) |

`index.html` is a standalone page: a hero, the screenshot tour, a feature
overview, and quick-start snippets. It has no build step and loads no
external assets, so you can preview it locally with any static server:

```sh
python3 -m http.server -d docs 8000   # http://localhost:8000
```

The prepared `Pages` workflow publishes this tracked directory only after a
manual dispatch on `main`; there is no site build step. Before adopting it,
set *Settings → Pages → Source* to **GitHub Actions**. The existing remote
setting was still branch publishing (`main`, `/docs`) at the 2026-11-01 review;
that setting must be changed before the next push to prevent automatic site
updates. Merely adding the workflow does not disable branch publishing.
