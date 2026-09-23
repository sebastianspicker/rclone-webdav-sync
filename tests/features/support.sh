#!/usr/bin/env bash
# support.sh - redacted debug archive: archive contents, credential
# redaction, and --json output.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# A settings layer with a literal secret; support must redact it and must
# never write .env into the archive.
cat >"${TMP}/support-secret.env" <<'EOF'
PASSWORD=feature-test-secret
API_KEY=feature-test-secret
NORMAL_SETTING=keep-me
EOF

# run_cli_support - run `support` against the webdav remote (its config has
# a pass line to redact) with the secret settings layer active.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_support() {
  (cd "$TMP" && env RCLONE_REMOTE=webtest SETTINGS_LOCAL_FILE="${TMP}/support-secret.env" \
    bash "${PROJ}/bin/sciebo" "$@")
}

ARCHIVE="${TMP}/support.tar.gz"
expect_cli "support: builds archive rc 0" 0 run_cli_support support --output "$ARCHIVE"
expect_file "support: archive written" "$ARCHIVE"
expect_contains "support: wrote path" "$CLI_OUT" "support: wrote ${ARCHIVE}"

listing="$(tar -tzf "$ARCHIVE" 2>/dev/null)"
expect_contains "support: version.txt in archive" "$listing" "version.txt"
expect_contains "support: doctor.txt in archive" "$listing" "doctor.txt"
expect_contains "support: rclone-config.txt in archive" "$listing" "rclone-config.txt"
expect_contains "support: settings.txt in archive" "$listing" "settings.txt"

version_txt="$(tar -xzOf "$ARCHIVE" version.txt 2>/dev/null)"
expect_contains "support: version banner" "$version_txt" "sciebo"
expect_contains "support: uname line" "$version_txt" "$(uname -s)"

rclone_txt="$(tar -xzOf "$ARCHIVE" rclone-config.txt 2>/dev/null)"
expect_contains "support: rclone pass redacted" "$rclone_txt" "pass = REDACTED"

settings_txt="$(tar -xzOf "$ARCHIVE" settings.txt 2>/dev/null)"
expect_contains "support: settings password redacted" "$settings_txt" "PASSWORD=REDACTED"
expect_contains "support: settings api key redacted" "$settings_txt" "API_KEY=REDACTED"
expect_contains "support: settings normal value kept" "$settings_txt" "NORMAL_SETTING=keep-me"

secret_hits="$(tar -xzOf "$ARCHIVE" 2>/dev/null | grep -c 'feature-test-secret' || true)"
expect_eq "support: literal secret absent from archive" "0" "$secret_hits"

expect_cli "support: json rc 0" 0 run_cli_support support --json --output "${TMP}/support-json.tar.gz"
expect_contains "support: json archive field" "$CLI_OUT" '"archive"'
expect_contains "support: json files field" "$CLI_OUT" '"files"'
expect_contains "support: json bytes field" "$CLI_OUT" '"bytes"'

# The staging tree is registered for exit/signal cleanup, so the registry
# cleanup must remove directories (rm -rf), not only files.
stage_dir="${TMP}/support-stage-probe"
mkdir -p "${stage_dir}/logs"
printf 'x\n' >"${stage_dir}/logs/file.txt"
sciebo_temp_register "$stage_dir"
expect_file "support: staging probe registered" "${stage_dir}/logs/file.txt"
sciebo_temp_cleanup
expect_no_file "support: cleanup removes a registered staging directory" "$stage_dir"
expect_eq "support: cleanup drains the registry" "0" "${#SCIEBO_TEMP_FILES[@]}"

finish
