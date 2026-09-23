#!/usr/bin/env bash
# share_pending.sh - pending share lifecycle through the OCS sharing API
# (stub curl): list local and federated pending shares, the older-server
# fallback list, accept/decline kind resolution, and the remove --yes path.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# run_cli_ni - non-interactive CLI run. decline refuses without --yes when
# stdin is not a terminal, so this stays deterministic even when the suite
# runs from a terminal.
# shellcheck disable=SC2329  # invoked indirectly via capture/expect_cli
run_cli_ni() { SCIEBO_NON_INTERACTIVE=1 run_cli_nc "$@"; }

# get_count - HTTP GET calls that carry a URL. The HTTP layer probes
# `curl --help` once per process, which the stub logs as a URL-less GET line.
get_count() { stub_count '^GET.http'; }

PENDING_LOCAL_XML="${TMP}/pending-local.xml"
cat >"$PENDING_LOCAL_XML" <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>11</id>
   <share_type>0</share_type>
   <share_with>alice</share_with>
   <uid_owner>bob</uid_owner>
   <path>/backup/notes/pending.txt</path>
   <stime>1712000000</stime>
  </element>
 </data>
</ocs>
XML

PENDING_REMOTE_XML="${TMP}/pending-remote.xml"
cat >"$PENDING_REMOTE_XML" <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>21</id>
   <share_type>6</share_type>
   <remote>https://cloud.example.org</remote>
   <remote_id>99</remote_id>
   <name>/remote.txt</name>
   <owner>carol</owner>
   <user>alice</user>
   <mountpoint>/remote.txt</mountpoint>
   <accepted>0</accepted>
  </element>
 </data>
</ocs>
XML

PENDING_OK_XML="${TMP}/pending-ok.xml"
cat >"$PENDING_OK_XML" <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta><data/></ocs>
XML

# --- pending list: both kinds, table columns ---------------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
expect_cli "pending: list rc 0" 0 run_cli_nc share pending
expect_contains "pending: header Kind" "$CLI_OUT" "Kind"
expect_contains "pending: header Owner" "$CLI_OUT" "Owner"
expect_contains "pending: header Created" "$CLI_OUT" "Created"
expect_contains "pending: header Target" "$CLI_OUT" "Target"
expect_contains "pending: local row" "$CLI_OUT" "local"
expect_contains "pending: local id" "$CLI_OUT" "11"
expect_contains "pending: local owner" "$CLI_OUT" "bob"
expect_contains "pending: local created" "$CLI_OUT" "1712000000"
expect_contains "pending: local target" "$CLI_OUT" "/backup/notes/pending.txt"
expect_contains "pending: remote row" "$CLI_OUT" "remote"
expect_contains "pending: remote id" "$CLI_OUT" "21"
expect_contains "pending: remote owner" "$CLI_OUT" "carol"
expect_contains "pending: remote target" "$CLI_OUT" "/remote.txt"
expect_contains "pending: local GET" "$(stub_calls)" $'GET\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/pending'
expect_contains "pending: remote GET" "$(stub_calls)" $'GET\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/remote_shares/pending'
expect_eq "pending: two GETs" "2" "$(get_count)"

# --- pending --local / --remote restrict the request -------------------------
stub_clear_calls
expect_cli "pending: --local rc 0" 0 run_cli_nc share pending --local
expect_contains "pending: --local keeps local" "$CLI_OUT" "pending.txt"
expect_not_contains "pending: --local drops remote" "$CLI_OUT" "carol"
expect_eq "pending: --local one GET" "1" "$(get_count)"
expect_eq "pending: --local no federated GET" "0" "$(stub_count 'remote_shares/pending')"

stub_clear_calls
expect_cli "pending: --remote rc 0" 0 run_cli_nc share pending --remote
expect_contains "pending: --remote keeps remote" "$CLI_OUT" "carol"
expect_not_contains "pending: --remote drops local" "$CLI_OUT" "pending.txt"
expect_eq "pending: --remote one GET" "1" "$(get_count)"
expect_eq "pending: --remote no local GET" "0" "$(stub_count 'api/v1/shares/pending')"

# --- pending --json: {"pending": [...]} --------------------------------------
stub_clear_calls
expect_cli "pending: --json rc 0" 0 run_cli_nc share pending --json
expect_contains "pending: json array" "$CLI_OUT" '"pending": ['
expect_contains "pending: json local kind" "$CLI_OUT" '"kind": "local"'
expect_contains "pending: json remote kind" "$CLI_OUT" '"kind": "remote"'
expect_contains "pending: json local id" "$CLI_OUT" '"id": "11"'
expect_contains "pending: json remote owner" "$CLI_OUT" '"owner": "carol"'
expect_contains "pending: json remote target" "$CLI_OUT" '"target": "/remote.txt"'
expect_not_contains "pending: json hides table" "$CLI_OUT" "Kind"

# --- older servers: fall back to shared_with_me + state=pending --------------
stub_reset_routes
stub_clear_calls
stub_route GET '*api/v1/shares/pending' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>999</statuscode><message>Invalid query</message></meta><data/></ocs>
XML
stub_route_file GET '*shared_with_me=true*' "$PENDING_LOCAL_XML" 200
expect_cli "pending: fallback rc 0" 0 run_cli_nc share pending --local
expect_contains "pending: fallback lists local" "$CLI_OUT" "pending.txt"
expect_contains "pending: fallback query" "$(stub_calls)" "shared_with_me=true&state=pending"
expect_eq "pending: fallback sent two GETs" "2" "$(get_count)"

# --- one failing kind warns and keeps the other ------------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*api/v1/shares/pending' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>403</statuscode><message>Forbidden</message></meta><data/></ocs>
XML
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
expect_cli "pending: one failed kind rc 0" 0 run_cli_nc share pending
expect_contains "pending: surviving remote row" "$CLI_OUT" "carol"
expect_contains "pending: local failure warned" "$CLI_OUT" "cannot list local pending shares"
expect_contains "pending: failure detail" "$CLI_OUT" "Forbidden"

# --- both kinds failing is an error ------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*api/v1/shares/pending' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>403</statuscode><message>Forbidden</message></meta><data/></ocs>
XML
stub_route GET '*api/v1/remote_shares/pending' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>403</statuscode><message>Forbidden</message></meta><data/></ocs>
XML
expect_cli "pending: both failed rc 1" 1 run_cli_nc share pending
expect_contains "pending: both failed named" "$CLI_OUT" "could not list pending shares"

# --- empty lists -------------------------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_OK_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_OK_XML" 200
expect_cli "pending: empty rc 0" 0 run_cli_nc share pending
expect_contains "pending: empty message" "$CLI_OUT" "no pending shares"

# --- accept local: POST /shares/pending/<id> ---------------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file POST '*api/v1/shares/pending/11' "$PENDING_OK_XML" 200
expect_cli "pending: accept local rc 0" 0 run_cli_nc share accept 11
expect_contains "pending: accept local confirms" "$CLI_OUT" "accepted local share 11"
expect_contains "pending: accept local POST" "$(stub_calls)" $'POST\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/shares/pending/11'
expect_eq "pending: accept one POST" "1" "$(stub_count '^POST')"

# --- accept remote: the id is only in the federated list ---------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file POST '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: accept remote rc 0" 0 run_cli_nc share accept 21
expect_contains "pending: accept remote confirms" "$CLI_OUT" "accepted remote share 21"
expect_contains "pending: accept remote POST" "$(stub_calls)" $'POST\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/remote_shares/pending/21'
expect_eq "pending: accept remote one POST" "1" "$(stub_count '^POST')"

# --- accept --remote forces federated without reading the local list ---------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file POST '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: accept --remote rc 0" 0 run_cli_nc share accept 21 --remote
expect_contains "pending: accept --remote confirms" "$CLI_OUT" "accepted remote share 21"
expect_eq "pending: --remote skips local list" "0" "$(stub_count 'api/v1/shares/pending')"

# --- accept an id that is not pending in either list -------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
expect_cli "pending: accept unknown rc 1" 1 run_cli_nc share accept 99
expect_contains "pending: accept unknown named" "$CLI_OUT" "no pending share with id 99"
expect_eq "pending: unknown no POST" "0" "$(stub_count '^POST')"

# --- accept via the fallback list still resolves local -----------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*api/v1/shares/pending' 200 <<'XML'
<?xml version="1.0"?>
<ocs><meta><status>failure</status><statuscode>999</statuscode><message>Wrong path</message></meta><data/></ocs>
XML
stub_route_file GET '*shared_with_me=true*' "$PENDING_LOCAL_XML" 200
stub_route_file POST '*api/v1/shares/pending/11' "$PENDING_OK_XML" 200
expect_cli "pending: accept via fallback rc 0" 0 run_cli_nc share accept 11
expect_contains "pending: accept fallback confirms" "$CLI_OUT" "accepted local share 11"

# --- decline --yes deletes ---------------------------------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file DELETE '*api/v1/shares/pending/11' "$PENDING_OK_XML" 200
expect_cli "pending: decline --yes rc 0" 0 run_cli_nc share decline 11 --yes
expect_contains "pending: decline confirms" "$CLI_OUT" "declined local share 11"
expect_eq "pending: decline one DELETE" "1" "$(stub_count '^DELETE')"

# --- decline --yes resolves a federated id through the remote list -----------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file DELETE '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: decline remote rc 0" 0 run_cli_nc share decline 21 --yes
expect_contains "pending: decline remote confirms" "$CLI_OUT" "declined remote share 21"
expect_contains "pending: decline remote DELETE" "$(stub_calls)" $'DELETE\thttp://127.0.0.1:9/ocs/v2.php/apps/files_sharing/api/v1/remote_shares/pending/21'

# --- decline without --yes refuses when not interactive ----------------------
stub_clear_calls
expect_cli "pending: decline needs --yes rc 2" 2 run_cli_ni share decline 11
expect_contains "pending: decline refusal" "$CLI_OUT" "requires --yes"
expect_eq "pending: refusal no DELETE" "0" "$(stub_count '^DELETE')"
expect_eq "pending: refusal no GET" "0" "$(stub_count '^GET')"

# --- decline an id that is not pending in either list ------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
expect_cli "pending: decline unknown rc 1" 1 run_cli_nc share decline 99 --yes
expect_contains "pending: decline unknown named" "$CLI_OUT" "no pending share with id 99"
expect_eq "pending: decline unknown no DELETE" "0" "$(stub_count '^DELETE')"

# --- accept --all: every pending share of both kinds -------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file POST '*api/v1/shares/pending/11' "$PENDING_OK_XML" 200
stub_route_file POST '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: accept --all rc 0" 0 run_cli_nc share accept --all
expect_contains "pending: accept --all local" "$CLI_OUT" "accepted local share 11"
expect_contains "pending: accept --all remote" "$CLI_OUT" "accepted remote share 21"
expect_eq "pending: accept --all two POSTs" "2" "$(stub_count '^POST')"

# --- accept --all --remote: only the federated list --------------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file POST '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: accept --all --remote rc 0" 0 run_cli_nc share accept --all --remote
expect_contains "pending: accept --all --remote confirms" "$CLI_OUT" "accepted remote share 21"
expect_not_contains "pending: accept --all --remote drops local" "$CLI_OUT" "local"
expect_eq "pending: accept --all --remote one POST" "1" "$(stub_count '^POST')"
expect_eq "pending: accept --all --remote skips local list" "0" "$(stub_count 'api/v1/shares/pending')"

# --- accept --all skips a server-supplied traversal id -----------------------
stub_reset_routes
stub_clear_calls
cat >"${TMP}/pending-traversal.xml" <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data>
  <element>
   <id>../evil</id>
   <share_type>0</share_type>
   <share_with>alice</share_with>
   <uid_owner>bob</uid_owner>
   <path>/backup/notes/traversal.txt</path>
   <stime>1712000000</stime>
  </element>
  <element>
   <id>11</id>
   <share_type>0</share_type>
   <share_with>alice</share_with>
   <uid_owner>bob</uid_owner>
   <path>/backup/notes/pending.txt</path>
   <stime>1712000000</stime>
  </element>
 </data>
</ocs>
XML
stub_route_file GET '*api/v1/shares/pending' "${TMP}/pending-traversal.xml" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_OK_XML" 200
stub_route_file POST '*api/v1/shares/pending/11' "$PENDING_OK_XML" 200
expect_cli "pending: accept --all skips bad id rc 0" 0 run_cli_nc share accept --all
expect_contains "pending: accept --all warns bad id" "$CLI_OUT" "invalid id"
expect_contains "pending: accept --all accepts the valid id" "$CLI_OUT" "accepted local share 11"
expect_eq "pending: accept --all one POST" "1" "$(stub_count '^POST')"
expect_not_contains "pending: accept --all no traversal request" "$(stub_calls)" "evil"

# --- decline --all --yes: every pending share of both kinds ------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/shares/pending' "$PENDING_LOCAL_XML" 200
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file DELETE '*api/v1/shares/pending/11' "$PENDING_OK_XML" 200
stub_route_file DELETE '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: decline --all --yes rc 0" 0 run_cli_nc share decline --all --yes
expect_contains "pending: decline --all local" "$CLI_OUT" "declined local share 11"
expect_contains "pending: decline --all remote" "$CLI_OUT" "declined remote share 21"
expect_eq "pending: decline --all two DELETEs" "2" "$(stub_count '^DELETE')"

# --- decline --all --remote --yes: only the federated list -------------------
stub_reset_routes
stub_clear_calls
stub_route_file GET '*api/v1/remote_shares/pending' "$PENDING_REMOTE_XML" 200
stub_route_file DELETE '*api/v1/remote_shares/pending/21' "$PENDING_OK_XML" 200
expect_cli "pending: decline --all --remote rc 0" 0 run_cli_nc share decline --all --remote --yes
expect_contains "pending: decline --all --remote confirms" "$CLI_OUT" "declined remote share 21"
expect_eq "pending: decline --all --remote one DELETE" "1" "$(stub_count '^DELETE')"
expect_eq "pending: decline --all --remote skips local list" "0" "$(stub_count 'api/v1/shares/pending')"

# --- decline --all without --yes refuses non-interactively -------------------
stub_clear_calls
expect_cli "pending: decline --all needs --yes rc 2" 2 run_cli_ni share decline --all
expect_contains "pending: decline --all refusal" "$CLI_OUT" "requires --yes"
expect_eq "pending: decline --all refusal no DELETE" "0" "$(stub_count '^DELETE')"
expect_eq "pending: decline --all refusal no GET" "0" "$(stub_count '^GET')"

# --- --all cannot be combined with an explicit id ----------------------------
stub_clear_calls
expect_cli "pending: --all plus id rc 2" 2 run_cli_nc share accept --all 11
expect_contains "pending: --all conflict named" "$CLI_OUT" "cannot be combined"
expect_eq "pending: --all conflict no POST" "0" "$(stub_count '^POST')"

# --- option validation -------------------------------------------------------
expect_cli "pending: --local --remote rc 2" 2 run_cli_nc share pending --local --remote
expect_contains "pending: exclusive flags named" "$CLI_OUT" "mutually exclusive"

# --- remove --yes and the non-interactive remove path ------------------------
stub_reset_routes
stub_clear_calls
stub_route GET '*api/v1/shares/9' 200 <<'XML'
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
stub_route_file DELETE '*api/v1/shares/9' "$PENDING_OK_XML" 200
expect_cli "pending: remove --yes rc 0" 0 run_cli_nc share remove 9 --yes
expect_contains "pending: remove --yes confirms" "$CLI_OUT" "removed share 9"
expect_eq "pending: remove --yes DELETEs" "1" "$(stub_count '^DELETE')"

stub_clear_calls
expect_cli "pending: remove non-interactive rc 0" 0 run_cli_ni share remove 9
expect_contains "pending: remove non-interactive confirms" "$CLI_OUT" "removed share 9"
expect_eq "pending: remove non-interactive DELETEs" "1" "$(stub_count '^DELETE')"

finish
