# Filters

rclone filter files in `--filter-from` syntax: `- pattern` excludes,
`+ pattern` includes, `#` starts a comment. See
https://rclone.org/filtering/ for the pattern language. `sciebo doctor`
validates every `*.txt` file in this directory by asking rclone to parse
it with `--filter-from`.

- `clutter.txt` - global excludes applied to every source. Extend it,
  or reference per-source files from `config/sources.conf`.
- `pair-<name>.txt` - per-pair excludes written by `sciebo folders`;
  referenced from `config/folders.conf`.

Debug the effective rules of a run with:

    rclone --config ~/.config/rclone/rclone.conf \
      sync /tmp/example sciebo:backup/example \
      --filter-from config/filters/clutter.txt \
      --exclude-if-present .nosync \
      -vv --dump filters
