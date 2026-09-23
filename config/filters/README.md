# Filters

These are [rclone filter files](https://rclone.org/filtering/), one rule per
line: `- pattern` excludes, `+ pattern` includes, and `#` starts a comment.
`sciebo doctor` runs every `*.txt` file in this directory through rclone's
`--filter-from` parser, so a typo fails preflight instead of a sync.

Three kinds of files live here:

- `clutter.txt` — the global excludes that apply to every source (`.DS_Store`,
  `*.swp`, ...), mirroring the Nextcloud desktop client's exclude list. Add
  your own rules here, or keep per-source files and point to them from
  `config/sources.conf`.
- `fleeting.txt` — file-name globs that `sciebo cleanup --junk` may delete
  locally (partial downloads and similar regenerable debris). It is not a
  sync filter.
- `pair-<name>.txt` — excludes written by `sciebo folders` for one pair, for
  example to skip `node_modules/`. Referenced from `config/folders.conf`.

To see which rules a run would actually apply:

```sh
rclone --config ~/.config/rclone/rclone.conf \
  sync /tmp/example sciebo:backup/example \
  --filter-from config/filters/clutter.txt \
  --exclude-if-present .nosync \
  -vv --dump filters
```
