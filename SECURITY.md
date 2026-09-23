# Security model

rclone-sciebo keeps exactly one credential: the Nextcloud app password for
the configured remote. This document describes where that credential lives
and what protects it. It is a threat model for the tool itself, not a formal
audit, and it names the residual exposures that are accepted by design.

## Credentials at rest

- `sciebo setup` stores the app password either in the platform Keychain
  (`KEYCHAIN=1`, the default; service `KEYCHAIN_SERVICE`, account
  `<RCLONE_REMOTE>#plain`) or, as a fallback, in the rclone config using
  `rclone obscure`. Obscuring is a reversible encoding, not encryption:
  anyone who can read the config can recover the password.
- The Keychain backend is `security` on macOS and `secret-tool` (libsecret)
  or `pass` on Linux, whichever is available. The item holds the **plaintext**
  app password under account `<RCLONE_REMOTE>#plain`, so the HTTP layer can
  send it without running `rclone reveal` (which would put the reversible
  obscured value in an argv). A legacy install that still holds the obscured
  value under account `RCLONE_REMOTE` is migrated once on first use: the item
  is revealed in memory and rewritten to the `#plain` slot; the legacy item is
  left in place and is removed by `logout` (which deletes both items). On
  Linux the secret reaches the backend on stdin, not in
  its argv; the macOS `security` argv caveat is below. `KEYCHAIN=0` keeps the
  classic rclone-config behavior.
- `.env` (`ENV_FILE`) is a manual/legacy place for `SCIEBO_APP_PASSWORD`; the
  tool never requires it. `sciebo doctor` warns when `.env` is group/other
  readable or writable and when the rclone config is group/other readable;
  it never fails on them and recommends `chmod 600`.

## Credentials in transit

- rclone talks to the remote URL from the rclone config (HTTPS in normal
  setups) and sends the app password as HTTP basic auth over that TLS
  connection.
- Certificate verification is on by default. `TLS_INSECURE=1` or the global
  `--trust` flag passes `--insecure` to curl and `--no-check-certificate` to
  rclone; use it only on trusted networks against self-signed servers.

## Credentials in child processes

- rclone runs with the obscured password in the child environment
  (`RCLONE_CONFIG_<REMOTE>_PASS`); the parent environment is not modified.
  A process environment is readable by the same user (and by root), so it is
  only as private as the account.
- Direct HTTP calls (`lib/http.sh`) write the plain password to a mode-600
  netrc temp file and pass `--netrc-file`; the password never appears in the
  curl argv (`ps`, process listings). In the top-level process the file is
  created once and reused: it is emptied (truncated) after every request, on
  success and failure alike, and the path stays registered so it is removed at
  exit or on a signal. A command-substitution subshell, which cannot register
  cleanup with the parent, uses a per-call netrc that is removed as soon as
  curl returns.
- Share link/update passwords (`share --password`) are written to a mode-600
  temp file and passed as `--data-urlencode password@file`; they never appear
  in the curl argv either, and the file is removed right after the request.
- Residual exposure: a fatal signal (`SIGKILL`, a crash) that bypasses the
  EXIT/signal cleanup can leave a secret temp file in `${TMPDIR:-/tmp}`. The
  netrc (`sciebo-http-netrc.*`) is mode 600 and empty between requests (the
  password is written only for the duration of a call), so a leftover normally
  holds no secret, but a crash during a request can capture it. The client-key
  `--config` file (`sciebo-http-key.*`) is mode 600 and is emptied after every
  request the same way, so it carries the same exposure. The Login Flow
  response temp (`sciebo-login.*`, `lib/commands/setup.sh`) is registered for
  exit cleanup and removed on a signal; it is mode 600 under `umask 077` and
  holds the plaintext app password for the duration of the poll loop, so a
  `SIGKILL` during that loop can leave it behind. Delete leftovers if you
  suspect one.
- Passwords containing control bytes (newline, CR, TAB) cannot be represented
  in netrc safely; `lib/http.sh` refuses such a password instead of falling
  back to `-u user:password` in the argv.
- The OCS capabilities probe in `lib/capabilities.sh` uses the same netrc
  treatment when `lib/http.sh` is loaded (it always is in `bin/sciebo`). The
  standalone path used when the library is sourced alone (the unit-test
  harness) also writes a mode-600 netrc and refuses a control-byte secret;
  there is no `-u user:password` fallback in `lib/`.
- `SCIEBO_DEBUG`/`--debug` adds `-v` to curl, whose verbose trace can print
  the `Authorization: Basic ...` request header (base64, trivially
  reversible). Use debug output for support, not for sharing.
- `keychain_security_store` passes the secret in the macOS `security` argv;
  only the same user can read it during the brief call. With the current
  plaintext slot the value is the app password itself, so on macOS the process
  table is exposed to the same user for the duration of the `security` call.
  The Linux `secret-tool`/`pass` paths use stdin and do not have this exposure.
- `CLIENT_KEY_PASSWORD` (mutual-TLS client-key passphrase) is written to a
  mode-600 curl `--config` file as `pass = "..."` and passed as
  `--config FILE`, so it never reaches the curl or Login Flow argv the way
  `--pass` would. In the top-level process the file is created once and
  reused: it is emptied (truncated) after every request, on success and
  failure alike, and rewritten for the next request while the passphrase is
  set; the path stays registered so it is removed at exit or on a signal. A
  passphrase containing a control byte is refused because curl's config parser
  cannot represent it safely.
- rclone's config write has no stdin or environment path, so
  `remote_write_nextcloud`, `setup --crypt`, and `nextcloudcmd` first write a
  non-secret placeholder, then patch the real obscured value directly into the
  plaintext rclone config file (mode 600, atomic) — the reversible secret
  never reaches an argv. `setup --rotate` does the same through
  `remote_write_pass`. When the rclone config is itself encrypted, the secret
  cannot be patched in without exposing it in the process list, so the command
  refuses with a clear message instead of falling back to `rclone config`
  argv (disable rclone config encryption and re-run).
- `remote_secret_plain` prefers the keychain plaintext slot, so HTTP commands
  no longer run `rclone reveal` during normal operation. A legacy obscured
  keychain item is revealed once for the migration. When the secret lives
  obscured in the rclone config (`KEYCHAIN=0`, no backend, or `--no-keychain`),
  it is still revealed with `rclone reveal -- <obscured>`, whose reversible
  value appears in that argv (same same-user caveat); prefer `KEYCHAIN=1`,
  where the config stores only the obscured empty value and the real secret
  lives in the platform keychain. `doctor` reports this residual.
- Proxy credentials: an explicit `http://` or `https://` `PROXY` with embedded
  userinfo (`http://user:pass@host`) is exported to the curl/rclone child as
  `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY`, so it stays out of the child argv
  (the environment is readable only by the same user, same as the other
  password paths). A `socks5://` `PROXY` still travels as `-x` for curl and
  `--http-proxy` for rclone, so its credentials remain visible in the child
  argv. `doctor` and `network` mask the userinfo in their reports, but for
  proxy authentication prefer exporting `HTTPS_PROXY`/`HTTP_PROXY` instead of
  setting `PROXY`.
- `nextcloudcmd --password VALUE` and `provision --apppassword PASS` carry the
  secret in the process argv, so it is visible to the same user in a process
  listing; both offer a file-descriptor form (`--password-fd FD`,
  `--apppassword-fd FD`) that reads the secret from an already-open descriptor
  and keeps it out of the argv.
- Files that are `source`d (settings, profile settings, `.env`, and the
  capabilities cache) are checked for regular-file type, symlink, ownership by
  the current user, and group/other-write permission; an unsafe file is
  refused rather than executed. `safe_source` opens the file, validates that
  open descriptor itself (and, where `stat /dev/fd/N` masks the file bits,
  that the descriptor and the path name the same inode), and sources through
  it, so a file replaced or swapped between the check and the read is still
  refused rather than executed (TOCTOU-safe). `safe_source` returns the
  sourced file's status, so a syntax or runtime error in a settings, profile,
  or `.env` file aborts the command instead of being silently swallowed.

## State and logs

- `bin/sciebo` sets `umask 077`, so state directories, logs, run records,
  caches, and temporary files are created private to the user.
- Records (run state, pause markers, failure blacklist, remote lock tokens,
  capabilities caches, ...) are written atomically with mode 600.
- Logs and diagnostic output can contain file names and remote paths; treat
  them as private data and let `cleanup --logs` age them out.

## Lock semantics

- A sync/cleanup run holds a lock directory (`${LOCK_DIR}/sync.lock`),
  created atomically with `mkdir`; the pid and process start time are
  recorded inside.
- A lock is broken only when the recorded pid is gone or no longer matches
  the recorded start time (recycled pid). The stale directory is moved aside
  before removal so a concurrent takeover cannot delete a freshly created
  lock, and release removes the lock only when it is owned by the current
  process.
- The lock serializes sync and cleanup runs; it is not an access control
  against other local users.

## Reporting a vulnerability

Report suspected vulnerabilities through a private
[GitHub Security Advisory](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on the repository (Security -> Advisories -> Report a vulnerability) rather
than in a public issue. If the repository is mirrored elsewhere, use the
advisory form on the canonical host.

Please include the version (`sciebo --version`), the platform, the exact
commands or configuration needed to reproduce, and the impact you believe the
issue has. Do not include real app passwords, share tokens, or other secrets:
redact them or use a throwaway account. There is no bug bounty; reports are
acknowledged best-effort.
