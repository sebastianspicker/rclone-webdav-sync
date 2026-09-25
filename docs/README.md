# docs/

Reference documentation and the project's GitHub Pages site.

| File | What it is |
| --- | --- |
| `commands.md` | every command, subcommand, option, exit code, and example |
| `settings.md` | every setting, its default, precedence, and the state layout |
| `architecture.md` | module map, command conventions, lock/state/HTTP design |
| `parity.md` | the Nextcloud Desktop client parity matrix and its limits |
| `index.html` | the landing page published at [sebastianspicker.github.io/rclone-webdav-sync](https://sebastianspicker.github.io/rclone-webdav-sync/) |
| `assets/screenshots/` | real CLI output rendered to SVG by `tools/screenshots.py` (`make screenshots`) |

`index.html` is a standalone page: a hero, the screenshot tour, a feature
overview, and quick-start snippets. It has no build step and loads no
external assets, so you can preview it locally with any static server:

```sh
python3 -m http.server -d docs 8000   # http://localhost:8000
```

It's served from this repository directly: GitHub Pages is configured under
*Settings → Pages* to deploy from the `main` branch's `/docs` folder, so a
push to `main` that changes this directory updates the live site.
