#!/usr/bin/env bash
# share_types.sh - the share email/circle/talk/remote subcommands, incoming
# listing, leave, copy-internal, and open --web (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The stub logs only the last request body option; wrap it so every
# --data-urlencode field is visible and assert request shapes precisely.
# Values passed as NAME@FILE (share passwords) are decoded into the field
# log the way curl does.
STUB_REAL="${STUB_BIN}/curl.real"
cp "${STUB_BIN}/curl" "$STUB_REAL"
cat >"${STUB_BIN}/curl" <<STUB
#!/bin/bash
log_dir="${TMP}"
printf '%s\n' "\$@" >>"\${log_dir}/share-types-curl-args.log"
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "--data-urlencode" ]; then
    case "\$arg" in
      *@/*)
        name="\${arg%%@*}"
        file="\${arg#*@}"
        if [ -f "\$file" ]; then
          printf '%s=%s\n' "\$name" "\$(cat "\$file")" >>"\${log_dir}/share-types-curl-fields.log"
        else
          printf '%s\n' "\$arg" >>"\${log_dir}/share-types-curl-fields.log"
        fi
        ;;
      *) printf '%s\n' "\$arg" >>"\${log_dir}/share-types-curl-fields.log" ;;
    esac
  fi
  prev="\$arg"
done
exec "${STUB_REAL}" "\$@"
STUB
chmod +x "${STUB_BIN}/curl"

curl_args_clear() {
  : >"${TMP}/share-types-curl-args.log"
  : >"${TMP}/share-types-curl-fields.log"
}
# share_fields - the values passed to --data-urlencode, one per line.
share_fields() {
  cat "${TMP}/share-types-curl-fields.log" 2>/dev/null || true
}

# A stub pbcopy so copy-internal never touches the actual clipboard.
PBC="${STUB_BIN}/pbcopy"
cat >"$PBC" <<'STUB'
#!/bin/bash
dir="$(cd "$(dirname "$0")" && pwd)"
cat >"${dir}/pbcopy.log"
exit 0
STUB
chmod +x "$PBC"
rm -f "${STUB_BIN}/pbcopy.log"
pbcopy_data() { cat "${STUB_BIN}/pbcopy.log" 2>/dev/null || true; }

# run_cli_ni - non-interactive CLI run. leave only prompts when stdin is a
# terminal, so this keeps the delete-without---yes case deterministic even
# when the suite runs from a terminal.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_ni() { SCIEBO_NON_INTERACTIVE=1 run_cli_nc "$@"; }

CREATE_XML="${TMP}/share-types-create.xml"
cat >"$CREATE_XML" <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <id>21</id>
  <share_type>4</share_type>
  <share_with>bob@example.org</share_with>
  <permissions>1</permissions>
 </data>
</ocs>
XML

# --- email shares: shareType 4, address, and sendPasswordByTalk --------------
stub_clear_calls
stub_reset_routes
curl_args_clear
stub_route_file POST '*apps/files_sharing/api/v1/shares' "$CREATE_XML" 200
expect_cli "share email rc 0" 0 run_cli_nc share email notes/plan.txt bob@example.org \
  --permissions r --note "for bob" --password s3cret --expire 2030-01-31 --send-password-by-talk
fields="$(share_fields)"
expect_contains "share email shareType=4" "$fields" "shareType=4"
expect_contains "share email shareWith" "$fields" "shareWith=bob@example.org"
expect_contains "share email sendPasswordByTalk" "$fields" "sendPasswordByTalk=true"
expect_contains "share email password" "$fields" "password=s3cret"
expect_not_contains "share email password stays out of argv" \
  "$(cat "${TMP}/share-types-curl-args.log" 2>/dev/null)" "s3cret"
expect_contains "share email expiry" "$fields" "expireDate=2030-01-31"
expect_contains "share email note" "$fields" "note=for bob"
expect_contains "share email permissions" "$fields" "permissions=1"
expect_contains "share email id printed" "$CLI_OUT" "created share 21"

expect_cli "share email talk without password rc 2" 2 \
  run_cli_nc share email notes/plan.txt bob@example.org --send-password-by-talk
expect_contains "share email names --password" "$CLI_OUT" "requires --password"

# --- circle, talk, and remote shares: shareType 7/10/6 -----------------------
stub_clear_calls
curl_args_clear
expect_cli "share circle rc 0" 0 run_cli_nc share circle notes/plan.txt 42 --permissions r
fields="$(share_fields)"
expect_contains "share circle shareType=7" "$fields" "shareType=7"
expect_contains "share circle shareWith" "$fields" "shareWith=42"

stub_clear_calls
curl_args_clear
expect_cli "share talk rc 0" 0 run_cli_nc share talk notes/plan.txt room-token --permissions r
fields="$(share_fields)"
expect_contains "share talk shareType=10" "$fields" "shareType=10"
expect_contains "share talk shareWith" "$fields" "shareWith=room-token"

stub_clear_calls
curl_args_clear
expect_cli "share remote rc 0" 0 run_cli_nc share remote notes/plan.txt bob@cloud.example.org --permissions r
fields="$(share_fields)"
expect_contains "share remote shareType=6" "$fields" "shareType=6"
expect_contains "share remote shareWith" "$fields" "shareWith=bob@cloud.example.org"

stub_clear_calls
curl_args_clear
expect_cli "share remote --json rc 0" 0 run_cli_nc share remote notes/plan.txt bob@cloud.example.org --permissions r --json
expect_contains "share remote json type" "$CLI_OUT" '"type": "remote"'
expect_contains "share remote json permissions" "$CLI_OUT" '"permissions": "1"'
expect_not_contains "share remote json hides text" "$CLI_OUT" "created share"

stub_clear_calls
curl_args_clear
expect_cli "share deck rc 0" 0 run_cli_nc share deck notes/plan.txt board-7 --permissions r
fields="$(share_fields)"
expect_contains "share deck shareType=12" "$fields" "shareType=12"
expect_contains "share deck shareWith" "$fields" "shareWith=board-7"
expect_contains "share deck id printed" "$CLI_OUT" "created share 21"

stub_clear_calls
curl_args_clear
expect_cli "share deck --json rc 0" 0 run_cli_nc share deck notes/plan.txt board-7 --permissions r --json
expect_contains "share deck json type" "$CLI_OUT" '"type": "deck"'
expect_contains "share deck json permissions" "$CLI_OUT" '"permissions": "1"'

# --- guest shares: shareType 8 ----------------------------------------------
stub_clear_calls
curl_args_clear
expect_cli "share guest rc 0" 0 run_cli_nc share guest notes/plan.txt guest@example.org --permissions r
fields="$(share_fields)"
expect_contains "share guest shareType=8" "$fields" "shareType=8"
expect_contains "share guest shareWith" "$fields" "shareWith=guest@example.org"
expect_contains "share guest permissions" "$fields" "permissions=1"

stub_clear_calls
curl_args_clear
expect_cli "share guest --json rc 0" 0 run_cli_nc share guest notes/plan.txt guest@example.org --permissions r --json
expect_contains "share guest json type" "$CLI_OUT" '"type": "guest"'
expect_contains "share guest json permissions" "$CLI_OUT" '"permissions": "1"'

expect_cli "share circle rejects --password rc 2" 2 run_cli_nc share circle notes/plan.txt 42 --password x
expect_contains "share circle option named" "$CLI_OUT" "does not accept --password"

# --- share_type_label learns deck (type 12) ----------------------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*apps/files_sharing/api/v1/shares*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>5</id>
   <share_type>12</share_type>
   <share_with>deck-board</share_with>
   <permissions>31</permissions>
   <path>/backup/notes/plan.txt</path>
  </element>
  <element>
   <id>6</id>
   <share_type>8</share_type>
   <share_with>guest@example.org</share_with>
   <permissions>1</permissions>
   <path>/backup/notes/plan.txt</path>
  </element>
 </data>
</ocs>
XML
expect_cli "share list deck rc 0" 0 run_cli_nc share list
expect_contains "share list deck label" "$CLI_OUT" "deck"
expect_contains "share list guest label" "$CLI_OUT" "guest"

# --- incoming: shared_with_me=true, Shared-by column -------------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*shared_with_me=true*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>31</id>
   <share_type>0</share_type>
   <share_with>alice</share_with>
   <permissions>31</permissions>
   <expiration></expiration>
   <note></note>
   <token></token>
   <path>/backup/notes/shared.txt</path>
   <share_owner>bob</share_owner>
   <uid_owner>bob</uid_owner>
  </element>
 </data>
</ocs>
XML
expect_cli "share incoming rc 0" 0 run_cli_nc share incoming
expect_contains "share incoming Shared-by header" "$CLI_OUT" "Shared-by"
expect_contains "share incoming owner" "$CLI_OUT" "bob"
expect_contains "share incoming path" "$CLI_OUT" "/backup/notes/shared.txt"
expect_contains "share incoming query" "$(stub_calls)" "shared_with_me=true"

expect_cli "share incoming --json rc 0" 0 run_cli_nc share incoming --json
expect_contains "share incoming json id" "$CLI_OUT" '"id": "31"'
expect_contains "share incoming json shared_by" "$CLI_OUT" '"shared_by": "bob"'

# --- remote-list: accepted federated shares ---------------------------------
stub_clear_calls
stub_reset_routes
stub_route GET '*apps/files_sharing/api/v1/remote_shares' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>77</id>
   <share_type>6</share_type>
   <remote>https://remote.example.org</remote>
   <remote_id>12</remote_id>
   <share_token>fed-77</share_token>
   <name>/fed-report.txt</name>
   <owner>carol</owner>
   <user>alice</user>
   <mountpoint>/fed-report.txt</mountpoint>
  </element>
 </data>
</ocs>
XML
expect_cli "share remote-list rc 0" 0 run_cli_nc share remote-list
expect_contains "share remote-list header" "$CLI_OUT" "Owner"
expect_contains "share remote-list id" "$CLI_OUT" "77"
expect_contains "share remote-list type" "$CLI_OUT" "remote"
expect_contains "share remote-list owner" "$CLI_OUT" "carol"
expect_contains "share remote-list target" "$CLI_OUT" "/fed-report.txt"
expect_contains "share remote-list GET" "$(stub_calls)" $'GET\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/remote_shares'

expect_cli "share remote-list --json rc 0" 0 run_cli_nc share remote-list --json
expect_contains "share remote-list json array" "$CLI_OUT" '"remote_shares": ['
expect_contains "share remote-list json owner" "$CLI_OUT" '"owner": "carol"'
expect_contains "share remote-list json target" "$CLI_OUT" '"target": "/fed-report.txt"'
expect_not_contains "share remote-list json hides table" "$CLI_OUT" "Owner"

# --- leave: DELETE the share and confirm -------------------------------------
stub_clear_calls
stub_reset_routes
stub_route DELETE '*apps/files_sharing/api/v1/shares/41' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
expect_cli "share leave rc 0" 0 run_cli_ni share leave 41
expect_contains "share leave confirms" "$CLI_OUT" "left share 41"
expect_eq "share leave DELETEs once" "1" "$(stub_count '^DELETE')"
expect_cli "share leave invalid id rc 2" 2 run_cli_nc share leave abc
expect_contains "share leave invalid id named" "$CLI_OUT" "invalid share id"

# --- copy-internal: direct /f/<fileid> link through the clipboard ------------
stub_clear_calls
stub_reset_routes
rm -f "${STUB_BIN}/pbcopy.log"
stub_route PROPFIND '*/remote.php/dav/files/alice/notes/plan.txt' 200 <<'XML'
<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
 <d:response>
  <d:href>/remote.php/dav/files/alice/notes/plan.txt</d:href>
  <d:propstat><d:prop><oc:fileid>42</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
 </d:response>
</d:multistatus>
XML
expect_cli "share copy-internal rc 0" 0 run_cli_nc share copy-internal notes/plan.txt
expect_eq "share copy-internal clipboard" "http://127.0.0.1:9/index.php/f/42" "$(pbcopy_data)"
expect_contains "share copy-internal confirms" "$CLI_OUT" "copied to clipboard"

# --- open --web: the Files app URL, printed instead of launched --------------
expect_cli "open --web --print rc 0" 0 run_cli_nc open --web --print notes
expect_eq "open --web url" "http://127.0.0.1:9/index.php/apps/files/?dir=/backup/notes" "$CLI_OUT"

expect_cli "open --web root rc 0" 0 run_cli_nc open --web --print
expect_eq "open --web root url" "http://127.0.0.1:9/index.php/apps/files/?dir=/backup" "$CLI_OUT"

# --- usage failures ----------------------------------------------------------
expect_cli "share incoming extra arg rc 2" 2 run_cli_nc share incoming extra
expect_contains "share incoming extra named" "$CLI_OUT" "unexpected argument"
expect_cli "share copy-internal without SUB rc 2" 2 run_cli_nc share copy-internal
expect_contains "share copy-internal needs SUB" "$CLI_OUT" "requires a remote path"

finish
