#!/usr/bin/env bash
# share.sh - Nextcloud share management through the OCS sharing API (stub
# curl): link/user/group creation, list filtering, info, update, remove,
# search, and copy-link clipboard handling.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# The stub logs only the last request body option; wrap it so the tests can
# inspect every --data-urlencode field and assert request shapes precisely.
# Values passed as NAME@FILE (share passwords) are decoded into the field
# log the way curl does, so assertions still see password=...
STUB_REAL="${STUB_BIN}/curl.real"
cp "${STUB_BIN}/curl" "$STUB_REAL"
cat >"${STUB_BIN}/curl" <<STUB
#!/bin/bash
log_dir="${TMP}"
printf '%s\n' "\$@" >>"\${log_dir}/share-curl-args.log"
prev=""
for arg in "\$@"; do
  if [ "\$prev" = "--data-urlencode" ]; then
    case "\$arg" in
      *@/*)
        name="\${arg%%@*}"
        file="\${arg#*@}"
        if [ -f "\$file" ]; then
          printf '%s=%s\n' "\$name" "\$(cat "\$file")" >>"\${log_dir}/share-curl-fields.log"
        else
          printf '%s\n' "\$arg" >>"\${log_dir}/share-curl-fields.log"
        fi
        ;;
      *) printf '%s\n' "\$arg" >>"\${log_dir}/share-curl-fields.log" ;;
    esac
  fi
  prev="\$arg"
done
exec "${STUB_REAL}" "\$@"
STUB
chmod +x "${STUB_BIN}/curl"

curl_args_clear() {
  : >"${TMP}/share-curl-args.log"
  : >"${TMP}/share-curl-fields.log"
}
# share_fields - the values passed to --data-urlencode, one per line.
share_fields() {
  cat "${TMP}/share-curl-fields.log" 2>/dev/null || true
}
# share_raw_argv - the raw curl arguments, for secret-leak assertions.
share_raw_argv() {
  cat "${TMP}/share-curl-args.log" 2>/dev/null || true
}

# A stub pbcopy (PATH order wins over the real one) so copy-link never
# touches the actual clipboard.
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

# run_cli_ni - non-interactive CLI run. remove/leave only prompt when stdin
# is a terminal, so this keeps the delete-without---yes case deterministic
# even when the suite runs from a terminal.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_ni() { SCIEBO_NON_INTERACTIVE=1 run_cli_nc "$@"; }

# --- link creation: POST shape, id, and /s/<token> URL -----------------------
stub_clear_calls
stub_reset_routes
curl_args_clear
stub_route POST '*apps/files_sharing/api/v1/shares' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <id>7</id>
  <share_type>3</share_type>
  <share_with></share_with>
  <permissions>1</permissions>
  <token>AbCd1234</token>
  <path>/backup/notes/plan.txt</path>
 </data>
</ocs>
XML

expect_cli "share: link create rc 0" 0 run_cli_nc share link notes/plan.txt
expect_contains "share: link id printed" "$CLI_OUT" "created share 7"
expect_contains "share: link token URL printed" "$CLI_OUT" "http://127.0.0.1:9/s/AbCd1234"
expect_contains "share: link POST url" "$(stub_calls)" $'POST\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares'
expect_contains "share: link shareType=3" "$(stub_data)" "shareType=3"
expect_contains "share: link path field" "$(share_fields)" "path=/backup/notes/plan.txt"
expect_eq "share: one POST" "1" "$(stub_count '^POST')"

stub_clear_calls
curl_args_clear
expect_cli "share: link options rc 0" 0 run_cli_nc share link notes/plan.txt \
  --password s3cret --expire 2030-01-31 --note "for bob" --permissions rws --label "Bob copy"
fields="$(share_fields)"
expect_contains "share: link password field" "$fields" "password=s3cret"
expect_not_contains "share: link password stays out of argv" "$(share_raw_argv)" "s3cret"
expect_contains "share: link expiry field" "$fields" "expireDate=2030-01-31"
expect_contains "share: link note field" "$fields" "note=for bob"
expect_contains "share: link label field" "$fields" "label=Bob copy"
expect_contains "share: link permissions field" "$fields" "permissions=19"

stub_clear_calls
curl_args_clear
expect_cli "share: link download rc 0" 0 run_cli_nc share link notes/plan.txt --download 0 --password s3cret
fields="$(share_fields)"
expect_contains "share: link download attributes" "$fields" 'attributes={"download":0}'
expect_contains "share: link download password" "$fields" "password=s3cret"
expect_not_contains "share: link download password stays out of argv" "$(share_raw_argv)" "s3cret"
expect_contains "share: link download body in stub_data" "$(stub_data)" 'attributes={"download":0}'

expect_cli "share: link download invalid rc 2" 2 run_cli_nc share link notes/plan.txt --download 2
expect_contains "share: link download invalid named" "$CLI_OUT" "takes 0 or 1"

expect_cli "share: link unknown permission rc 2" 2 run_cli_nc share link notes/plan.txt --permissions q
expect_contains "share: unknown permission named" "$CLI_OUT" "unknown permission letter"

# --- hide-download: the attribute shape follows the server major version -----
mkdir -p "$STATE_DIR"
cat >"${STATE_DIR}/capabilities.env" <<'EOF'
CAP_VERSION=30.0.0
CAP_PROBED_AT=1700000000
EOF
stub_clear_calls
curl_args_clear
expect_cli "share: link download array false rc 0" 0 run_cli_nc share link notes/plan.txt --download 0
expect_contains "share: link download array false" "$(share_fields)" \
  'attributes=[{"scope":"permissions","key":"download","value":false}]'

stub_clear_calls
curl_args_clear
expect_cli "share: link download array true rc 0" 0 run_cli_nc share link notes/plan.txt --download 1
expect_contains "share: link download array true" "$(share_fields)" \
  'attributes=[{"scope":"permissions","key":"download","value":true}]'

rm -f "${STATE_DIR}/capabilities.env"
stub_clear_calls
curl_args_clear
expect_cli "share: link download legacy rc 0" 0 run_cli_nc share link notes/plan.txt --download 1
expect_contains "share: link download legacy object" "$(share_fields)" 'attributes={"download":1}'

# --- link file-drop / file-request -------------------------------------------
stub_clear_calls
curl_args_clear
expect_cli "share: link file-drop rc 0" 0 run_cli_nc share link notes/plan.txt --file-drop
expect_contains "share: link file-drop permissions 4" "$(share_fields)" "permissions=4"

stub_clear_calls
curl_args_clear
expect_cli "share: link file-request rc 0" 0 run_cli_nc share link notes/plan.txt --file-request
expect_contains "share: link file-request attribute" "$(share_fields)" \
  'attributes=[{"scope":"fileRequest","key":"enabled","value":true}]'

stub_clear_calls
curl_args_clear
expect_cli "share: link file-request download rc 0" 0 run_cli_nc share link notes/plan.txt --file-request --download 1
expect_contains "share: link combined attributes" "$(share_fields)" \
  'attributes=[{"scope":"permissions","key":"download","value":true},{"scope":"fileRequest","key":"enabled","value":true}]'

expect_cli "share: link rejects --send-mail rc 2" 2 run_cli_nc share link notes/plan.txt --send-mail
expect_contains "share: link send-mail named" "$CLI_OUT" "does not accept --send-mail"

# --- create --json: the result document instead of the text line -------------
stub_clear_calls
expect_cli "share: link --json rc 0" 0 run_cli_nc share link notes/plan.txt --json
expect_contains "share: link json id" "$CLI_OUT" '"id": "7"'
expect_contains "share: link json type" "$CLI_OUT" '"type": "link"'
expect_contains "share: link json url" "$CLI_OUT" '"url": "http://127.0.0.1:9/s/AbCd1234"'
expect_contains "share: link json permissions" "$CLI_OUT" '"permissions": "1"'
expect_not_contains "share: link json hides text" "$CLI_OUT" "created share"

stub_clear_calls
expect_cli "share: user --json rc 0" 0 run_cli_nc share user notes/plan.txt bob --permissions r --json
expect_contains "share: user json type" "$CLI_OUT" '"type": "user"'
expect_contains "share: user json permissions" "$CLI_OUT" '"permissions": "1"'
expect_not_contains "share: user json hides text" "$CLI_OUT" "created share"

# --- user and group shares ---------------------------------------------------
stub_clear_calls
curl_args_clear
expect_cli "share: user share rc 0" 0 run_cli_nc share user notes/plan.txt bob --permissions rws
fields="$(share_fields)"
expect_contains "share: user shareWith" "$fields" "shareWith=bob"
expect_contains "share: user shareType=0" "$fields" "shareType=0"
expect_contains "share: user permissions 19" "$fields" "permissions=19"
expect_contains "share: user id printed" "$CLI_OUT" "created share 7"

stub_clear_calls
curl_args_clear
expect_cli "share: group share rc 0" 0 run_cli_nc share group notes/plan.txt team --permissions r
fields="$(share_fields)"
expect_contains "share: group shareWith" "$fields" "shareWith=team"
expect_contains "share: group shareType=1" "$fields" "shareType=1"
expect_contains "share: group permissions 1" "$fields" "permissions=1"

stub_clear_calls
curl_args_clear
expect_cli "share: user send-mail rc 0" 0 run_cli_nc share user notes/plan.txt bob --send-mail
expect_contains "share: user sendMail field" "$(share_fields)" "sendMail=true"

expect_cli "share: user rejects password rc 2" 2 run_cli_nc share user notes/plan.txt bob --password x
expect_contains "share: user option named" "$CLI_OUT" "does not accept --password"

# --- list: rows, URL preference, token fallback, SUB filtering ---------------
cat >"${TMP}/shares-list.xml" <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>7</id>
   <share_type>3</share_type>
   <share_with></share_with>
   <permissions>1</permissions>
   <expiration></expiration>
   <note></note>
   <token>AbCd1234</token>
   <path>/backup/notes/plan.txt</path>
   <url>https://cloud.example.org/s/AbCd1234</url>
  </element>
  <element>
   <id>8</id>
   <share_type>0</share_type>
   <share_with>bob</share_with>
   <permissions>31</permissions>
   <expiration>2030-01-31</expiration>
   <note>for bob</note>
   <token></token>
   <path>/backup/other.txt</path>
   <url></url>
  </element>
  <element>
   <id>9</id>
   <share_type>3</share_type>
   <share_with></share_with>
   <permissions>1</permissions>
   <expiration></expiration>
   <note></note>
   <token>NoUrl99</token>
   <path>/backup/token-only.txt</path>
   <url></url>
  </element>
 </data>
</ocs>
XML
stub_clear_calls
stub_reset_routes
stub_route_file GET '*apps/files_sharing/api/v1/shares*' "${TMP}/shares-list.xml" 200

expect_cli "share: list rc 0" 0 run_cli_nc share list
expect_contains "share: list header" "$CLI_OUT" "Permissions"
expect_contains "share: list link url" "$CLI_OUT" "https://cloud.example.org/s/AbCd1234"
expect_contains "share: list token fallback" "$CLI_OUT" "http://127.0.0.1:9/s/NoUrl99"
expect_contains "share: list user row" "$CLI_OUT" "bob"
expect_contains "share: list GET url" "$(stub_calls)" $'GET\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares'

stub_clear_calls
expect_cli "share: list SUB rc 0" 0 run_cli_nc share list notes/plan.txt
expect_contains "share: list SUB keeps match" "$CLI_OUT" "AbCd1234"
expect_not_contains "share: list SUB drops others" "$CLI_OUT" "bob"
expect_contains "share: list SUB path query" "$(stub_calls)" "path=/backup/notes/plan.txt"
expect_contains "share: list SUB no subdirs" "$(stub_calls)" "subfiles=false"

stub_clear_calls
expect_cli "share: list --json rc 0" 0 run_cli_nc share list --json
expect_contains "share: list json array" "$CLI_OUT" '"shares": ['
expect_contains "share: list json id" "$CLI_OUT" '"id": "7"'
expect_contains "share: list json type" "$CLI_OUT" '"type": "link"'
expect_contains "share: list json url" "$CLI_OUT" '"url": "https://cloud.example.org/s/AbCd1234"'
expect_contains "share: list json shared_by" "$CLI_OUT" '"shared_by":'
expect_not_contains "share: list json hides table" "$CLI_OUT" "Permissions"

stub_clear_calls
expect_cli "share: list SUB --json rc 0" 0 run_cli_nc share list notes/plan.txt --json
expect_contains "share: list SUB json keeps match" "$CLI_OUT" '"id": "7"'
expect_not_contains "share: list SUB json drops others" "$CLI_OUT" '"with": "bob"'

stub_clear_calls
expect_cli "share: list --reshares rc 0" 0 run_cli_nc share list --reshares
expect_contains "share: list reshares query" "$(stub_calls)" "reshares=true"

stub_reset_routes
stub_route GET '*apps/files_sharing/api/v1/shares*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
expect_cli "share: list empty rc 0" 0 run_cli_nc share list
expect_contains "share: list empty message" "$CLI_OUT" "no shares"

# --- info --------------------------------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*apps/files_sharing/api/v1/shares/8' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>8</id>
   <share_type>0</share_type>
   <share_with>bob</share_with>
   <permissions>31</permissions>
   <expiration>2030-01-31</expiration>
   <note>for bob</note>
   <path>/backup/other.txt</path>
  </element>
 </data>
</ocs>
XML
expect_cli "share: info rc 0" 0 run_cli_nc share info 8
expect_contains "share: info id" "$CLI_OUT" "8"
expect_contains "share: info with" "$CLI_OUT" "bob"
expect_contains "share: info expires" "$CLI_OUT" "2030-01-31"
expect_contains "share: info path" "$CLI_OUT" "/backup/other.txt"
expect_contains "share: info URL" "$(stub_calls)" "shares/8"

# --- update: only the given fields, remove-* clears --------------------------
stub_reset_routes
stub_clear_calls
curl_args_clear
stub_route PUT '*apps/files_sharing/api/v1/shares/7' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
expect_cli "share: update rc 0" 0 run_cli_nc share update 7 --note "new note"
expect_contains "share: update PUT url" "$(stub_calls)" $'PUT\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/7'
expect_eq "share: update only the note" "note=new note" "$(stub_data)"
expect_contains "share: update confirms" "$CLI_OUT" "updated share 7"

stub_clear_calls
curl_args_clear
expect_cli "share: update clear expiry rc 0" 0 run_cli_nc share update 7 --remove-expire
expect_eq "share: update empty expireDate" "expireDate=" "$(stub_data)"

stub_clear_calls
curl_args_clear
expect_cli "share: update password rc 0" 0 run_cli_nc share update 7 --password n3wpass
expect_contains "share: update password field" "$(share_fields)" "password=n3wpass"
expect_not_contains "share: update password stays out of argv" "$(share_raw_argv)" "n3wpass"

stub_clear_calls
expect_cli "share: update password combo rc 2" 2 run_cli_nc share update 7 --password x --remove-password
expect_contains "share: update combo message" "$CLI_OUT" "mutually exclusive"
expect_eq "share: update combo sends nothing" "0" "$(stub_count '^PUT')"

expect_cli "share: update with no options rc 2" 2 run_cli_nc share update 7
expect_contains "share: update needs a change" "$CLI_OUT" "at least one"

expect_cli "share: update invalid id rc 2" 2 run_cli_nc share update abc --note x
expect_contains "share: update invalid id named" "$CLI_OUT" "invalid share id"

stub_clear_calls
curl_args_clear
expect_cli "share: update permissions rc 0" 0 run_cli_nc share update 7 --permissions r
expect_eq "share: update permissions mask" "permissions=1" "$(stub_data)"

stub_clear_calls
curl_args_clear
expect_cli "share: update label rc 0" 0 run_cli_nc share update 7 --label "Bob copy"
expect_contains "share: update label field" "$(share_fields)" "label=Bob copy"

stub_clear_calls
curl_args_clear
expect_cli "share: update download rc 0" 0 run_cli_nc share update 7 --download 1
expect_contains "share: update download field" "$(share_fields)" 'attributes={"download":1}'
expect_eq "share: update download PUT body" 'attributes={"download":1}' "$(stub_data)"

stub_clear_calls
expect_cli "share: update download invalid rc 2" 2 run_cli_nc share update 7 --download yes
expect_contains "share: update download invalid named" "$CLI_OUT" "takes 0 or 1"
expect_eq "share: update download invalid no PUT" "0" "$(stub_count '^PUT')"

stub_clear_calls
curl_args_clear
expect_cli "share: update send-mail rc 0" 0 run_cli_nc share update 7 --send-mail
expect_contains "share: update sendMail field" "$(stub_data)" "sendMail=true"

# --- send-email: POST /shares/<id>/send-email --------------------------------
stub_reset_routes
stub_clear_calls
stub_route POST '*apps/files_sharing/api/v1/shares/7/send-email' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
expect_cli "share: send-email rc 0" 0 run_cli_nc share send-email 7
expect_contains "share: send-email confirms" "$CLI_OUT" "sent share 7 by email"
expect_contains "share: send-email POST url" "$(stub_calls)" $'POST\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/7/send-email'
expect_eq "share: send-email one POST" "1" "$(stub_count '^POST')"
expect_cli "share: send-email invalid id rc 2" 2 run_cli_nc share send-email abc
expect_contains "share: send-email invalid named" "$CLI_OUT" "invalid share id"

# --- remove: fetch-then-delete and --yes ------------------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*apps/files_sharing/api/v1/shares/9' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>9</id>
   <share_type>3</share_type>
   <permissions>1</permissions>
   <token>Tok9</token>
   <path>/backup/notes/gone.txt</path>
  </element>
 </data>
</ocs>
XML
stub_route DELETE '*apps/files_sharing/api/v1/shares/9' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
expect_cli "share: remove rc 0" 0 run_cli_ni share remove 9
expect_contains "share: remove names id" "$CLI_OUT" "removed share 9"
expect_contains "share: remove names path" "$CLI_OUT" "/backup/notes/gone.txt"
expect_eq "share: one DELETE" "1" "$(stub_count '^DELETE')"

stub_clear_calls
expect_cli "share: remove --yes rc 0" 0 run_cli_nc share remove 9 --yes
expect_eq "share: remove --yes deletes" "1" "$(stub_count '^DELETE')"
expect_contains "share: remove --yes still prints" "$CLI_OUT" "removed share 9"

# --- search: type-label/shareWith/label rows and extended types --------------
stub_reset_routes
stub_clear_calls
stub_route GET '*apps/files_sharing/api/v1/sharees*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <exact>
   <element>
    <label>Alice Anderson</label>
    <value><shareType>0</shareType><shareWith>alice</shareWith></value>
   </element>
  </exact>
  <groups>
   <element>
    <label>Team Blue</label>
    <value><shareType>1</shareType><shareWith>team-blue</shareWith></value>
   </element>
  </groups>
  <circles>
   <element>
    <label>Project Circle</label>
    <value><shareType>7</shareType><shareWith>circle-seven</shareWith></value>
   </element>
  </circles>
 </data>
</ocs>
XML
expect_cli "share: search rc 0" 0 run_cli_nc share search alice
expect_contains "share: search user row" "$CLI_OUT" $'user\talice\tAlice Anderson'
expect_contains "share: search group row" "$CLI_OUT" $'group\tteam-blue\tTeam Blue'
expect_contains "share: search circle row" "$CLI_OUT" $'circle\tcircle-seven\tProject Circle'
expect_contains "share: search query sent" "$(stub_calls)" "search=alice"
expect_contains "share: search item type" "$(stub_calls)" "itemType=file"
expect_contains "share: search baseline types" "$(stub_calls)" "shareType[]=0&shareType[]=1"
expect_contains "share: search email type" "$(stub_calls)" "shareType[]=4"
expect_contains "share: search remote type" "$(stub_calls)" "shareType[]=6"
expect_contains "share: search circle type" "$(stub_calls)" "shareType[]=7"
expect_contains "share: search guest type" "$(stub_calls)" "shareType[]=8"
expect_contains "share: search talk type" "$(stub_calls)" "shareType[]=10"

# --- search: a 4xx on the extended set falls back to user/group --------------
stub_reset_routes
stub_clear_calls
stub_route GET '*shareType*10*' 400 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>400</statuscode><message>Invalid share type</message></meta><data/></ocs>
XML
stub_route GET '*apps/files_sharing/api/v1/sharees*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <exact>
   <element>
    <label>Alice Anderson</label>
    <value><shareType>0</shareType><shareWith>alice</shareWith></value>
   </element>
  </exact>
 </data>
</ocs>
XML
expect_cli "share: search fallback rc 0" 0 run_cli_nc share search alice
expect_contains "share: search fallback row" "$CLI_OUT" $'user\talice\tAlice Anderson'
expect_eq "share: search fallback extended once" "1" "$(stub_count 'shareType..=10')"
expect_eq "share: search fallback two sharee GETs" "2" "$(stub_count 'api/v1/sharees')"

# --- copy-link: reuse, then create with a failing clipboard ------------------
stub_reset_routes
stub_clear_calls
rm -f "${STUB_BIN}/pbcopy.log"
stub_route GET '*apps/files_sharing/api/v1/shares*' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>7</id>
   <share_type>3</share_type>
   <permissions>1</permissions>
   <token>AbCd1234</token>
   <path>/backup/notes/plan.txt</path>
   <url>https://cloud.example.org/s/AbCd1234</url>
  </element>
 </data>
</ocs>
XML
expect_cli "share: copy-link reuse rc 0" 0 run_cli_nc share copy-link notes/plan.txt
expect_contains "share: copy-link copies" "$CLI_OUT" "copied to clipboard"
expect_eq "share: clipboard has the url" "https://cloud.example.org/s/AbCd1234" "$(pbcopy_data)"
expect_eq "share: reuse sends no POST" "0" "$(stub_count '^POST')"

stub_clear_calls
rm -f "${STUB_BIN}/pbcopy.log"
expect_cli "share: copy-link --json rc 0" 0 run_cli_nc share copy-link notes/plan.txt --json
expect_contains "share: copy-link json type" "$CLI_OUT" '"type": "link"'
expect_contains "share: copy-link json url" "$CLI_OUT" '"url": "https://cloud.example.org/s/AbCd1234"'
expect_contains "share: copy-link json permissions" "$CLI_OUT" '"permissions": "1"'
expect_no_file "share: copy-link json skips clipboard" "${STUB_BIN}/pbcopy.log"
expect_eq "share: copy-link json no POST" "0" "$(stub_count '^POST')"

cat >"${STUB_BIN}/pbcopy" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "${STUB_BIN}/pbcopy"
stub_reset_routes
stub_clear_calls
stub_route GET '*apps/files_sharing/api/v1/shares*' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML
stub_route POST '*apps/files_sharing/api/v1/shares' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <id>12</id>
  <share_type>3</share_type>
  <permissions>1</permissions>
  <token>NewTok12</token>
  <path>/backup/notes/plan.txt</path>
 </data>
</ocs>
XML
expect_cli "share: copy-link create rc 0" 0 run_cli_nc share copy-link notes/plan.txt
expect_contains "share: copy-link prints url" "$CLI_OUT" "http://127.0.0.1:9/s/NewTok12"
expect_eq "share: copy-link POSTs once" "1" "$(stub_count '^POST')"

# --- OCS errors and usage failures ------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route POST '*apps/files_sharing/api/v1/shares' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>404</statuscode><message>Wrong path</message></meta><data/></ocs>
XML
expect_cli "share: OCS error rc 1" 1 run_cli_nc share link missing.txt
expect_contains "share: OCS message surfaced" "$CLI_OUT" "Wrong path"
expect_contains "share: OCS statuscode surfaced" "$CLI_OUT" "404"

expect_cli "share: unknown subcommand rc 2" 2 run_cli_nc share bogus
expect_contains "share: unknown subcommand named" "$CLI_OUT" "unknown subcommand"
expect_cli "share: unknown option rc 2" 2 run_cli_nc share list --bogus
expect_contains "share: usage printed" "$CLI_OUT" "Usage: sciebo share"
expect_cli "share: missing subcommand rc 2" 2 run_cli_nc share
expect_cli "share: link without SUB rc 2" 2 run_cli_nc share link
expect_contains "share: link needs SUB" "$CLI_OUT" "requires a remote path"
expect_cli "share: user without USER rc 2" 2 run_cli_nc share user notes/plan.txt
expect_cli "share: list extra argument rc 2" 2 run_cli_nc share list a b
expect_contains "share: extra argument named" "$CLI_OUT" "unexpected argument"
expect_cli "share: info invalid id rc 2" 2 run_cli_nc share info abc
expect_contains "share: invalid id named" "$CLI_OUT" "invalid share id"
expect_cli "share: unsafe path rc 1" 1 run_cli_nc share link ../evil
expect_contains "share: unsafe path named" "$CLI_OUT" "unsafe remote path"

finish
