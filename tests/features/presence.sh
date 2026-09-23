#!/usr/bin/env bash
# presence.sh - user status through the OCS user_status app (stub curl).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=env.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

CLEAR_EPOCH=1700000000
CLEAR_LABEL="$(date -r "$CLEAR_EPOCH" '+%Y-%m-%d %H:%M' 2>/dev/null || true)"
[[ -n "$CLEAR_LABEL" ]] || CLEAR_LABEL="$(date -d "@${CLEAR_EPOCH}" '+%Y-%m-%d %H:%M')"

stub_clear_calls
stub_reset_routes
stub_route GET '*/ocs/v2.php/apps/user_status/api/v1/user_status' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta>
  <status>ok</status>
  <statuscode>200</statuscode>
  <message>OK</message>
 </meta>
 <data>
  <userId>alice</userId>
  <messageId>1</messageId>
  <statusIcon>🌴</statusIcon>
  <message>Working from home</message>
  <status>dnd</status>
  <clearAt>1700000000</clearAt>
 </data>
</ocs>
XML
stub_route PUT '*/ocs/v2.php/apps/user_status/api/v1/user_status/status' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data/>
</ocs>
XML
stub_route PUT '*/ocs/v2.php/apps/user_status/api/v1/user_status/message/custom' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data/>
</ocs>
XML
stub_route DELETE '*/ocs/v2.php/apps/user_status/api/v1/user_status/message' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta><status>ok</status><statuscode>200</statuscode><message>OK</message></meta>
 <data/>
</ocs>
XML

expect_cli "presence: show rc 0" 0 run_cli_nc presence
expect_contains "presence: status printed" "$CLI_OUT" "Status: dnd"
expect_contains "presence: message printed" "$CLI_OUT" "Message: Working from home"
expect_contains "presence: emoji printed" "$CLI_OUT" "Emoji: 🌴"
expect_contains "presence: clears is a local date" "$CLI_OUT" "Clears: ${CLEAR_LABEL}"
expect_eq "presence: one GET" "1" "$(stub_count 'GET')"

expect_cli "presence: explicit show rc 0" 0 run_cli_nc presence show
expect_contains "presence: show alias" "$CLI_OUT" "Status: dnd"

stub_clear_calls
expect_cli "presence: set status rc 0" 0 run_cli_nc presence set dnd
expect_contains "presence: set prints status" "$CLI_OUT" "status: dnd"
expect_eq "presence: status is a PUT" "1" "$(stub_count 'PUT.*user_status/status')"
expect_eq "presence: statusType sent" "statusType=dnd" "$(stub_data)"

stub_clear_calls
expect_cli "presence: set message rc 0" 0 run_cli_nc presence set online --message "Working from home"
expect_contains "presence: message echoed" "$CLI_OUT" "message: Working from home"
expect_eq "presence: custom message PUT" "1" "$(stub_count 'PUT.*message/custom')"
expect_eq "presence: message sent" "message=Working from home" "$(stub_data)"

stub_clear_calls
now_before="$(date +%s)"
expect_cli "presence: set clear-after rc 0" 0 run_cli_nc presence set away --emoji 🌴 --clear-after 30m
now_after="$(date +%s)"
expect_contains "presence: status away" "$CLI_OUT" "status: away"
clear_at="$(stub_data)"
clear_at="${clear_at#clearAt=}"
if [[ "$clear_at" =~ ^[0-9]+$ && "$clear_at" -ge "$((now_before + 1800))" && "$clear_at" -le "$((now_after + 1800))" ]]; then
  pass "presence: clearAt is now plus 30m"
else
  fail "presence: clearAt is now plus 30m" "got [$(stub_data)]"
fi

stub_clear_calls
expect_cli "presence: clear-after 0 clears" 0 run_cli_nc presence set online --clear-after 0
expect_contains "presence: status online" "$CLI_OUT" "status: online"
expect_contains "presence: clear confirmation" "$CLI_OUT" "message cleared"
expect_eq "presence: delete message" "1" "$(stub_count 'DELETE.*user_status/message')"
expect_eq "presence: no custom message PUT" "0" "$(stub_count 'message/custom')"

stub_clear_calls
expect_cli "presence: clear rc 0" 0 run_cli_nc presence clear
expect_eq "presence: clear output" "message cleared" "$CLI_OUT"
expect_eq "presence: single DELETE" "1" "$(stub_count 'DELETE')"

expect_cli "presence: unknown status is rc 2" 2 run_cli_nc presence set busy
expect_contains "presence: unknown status named" "$CLI_OUT" "unknown status"
expect_cli "presence: unknown option is rc 2" 2 run_cli_nc presence set dnd --bogus
expect_contains "presence: unknown option named" "$CLI_OUT" "unknown option"

stub_reset_routes
stub_route GET '*/ocs/v2.php/apps/user_status/api/v1/user_status' 200 <<'XML'
<?xml version="1.0"?>
<ocs>
 <meta>
  <status>failure</status>
  <statuscode>404</statuscode>
  <message>Status not found</message>
 </meta>
</ocs>
XML
expect_cli "presence: OCS error is rc 1" 1 run_cli_nc presence
expect_contains "presence: OCS error surfaced" "$CLI_OUT" "Nextcloud API error"

finish
