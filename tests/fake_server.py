#!/usr/bin/env python3
"""fake_server.py - configurable Nextcloud stand-in for feature tests.

Run it directly or through tests/fake_env.sh:

    python3 tests/fake_server.py --port 0 --user alice --password secret \
        --state /tmp/fake-state

--port 0 asks the OS for a free port; the chosen port is printed as
``PORT=<n>`` on stdout (the only thing written to stdout) so a harness can
parse it. Every endpoint except GET /status.php and the Login Flow v2
endpoints requires HTTP basic auth; wrong credentials get a 401 with a DAV
error body. The --state directory backs the WebDAV file tree (GET/PUT/DELETE/
MKCOL, PROPFIND, LOCK/UNLOCK, chunked uploads, and functional trashbin and
versions), so rclone can list, upload, lock, and download a small tree; the
OCS responses (capabilities, user, shares incl. pending, sharees,
notifications with actions, activity with limit/since, user_status, search)
are in-memory and reset when the process exits. Login Flow v2, the avatar,
and the ``/__test__/`` hooks round out the surface the feature tests use.

Test hooks (authenticated; every endpoint except Login Flow v2 is):
``POST /__test__/seed`` with ``what=trash`` seeds one deterministic trashbin
item; ``what=versions&path=REL`` seeds one version for REL, creating the file
when it is missing; ``what=props&path=REL`` overrides the DAV properties of
REL (``encrypted=1`` for nc:is-encrypted, ``external=1`` to add M to
oc:permissions, ``checksums=SHA256:...``, ``owner=NAME``); ``what=e2ee``,
``what=external``, ``what=checksums``, and ``what=owner`` are shortcuts for
the single-field forms; ``what=fail&path=REL&status=429`` queues an injected
error (optionally ``method=GET`` and ``count=N``). ``POST /__test__/login``
with ``polls=N`` makes the next Login Flow v2 poll answer HTTP 404 N times
before it succeeds (default 0, i.e. the first poll succeeds). Trashbin,
versions, and the property/fault overrides stay empty until seeded, matching
the tree of a fresh account.

Any request may append ``?__fail=STATUS`` to inject one error response for
that request (``429`` adds ``Retry-After: 1``). ``GET /__test__/redirect?to=
TARGET`` and ``GET /redirect/TARGET`` answer HTTP 302 with a Location header.
GET of a file honors a single ``Range: bytes=`` request with HTTP 206.

Only the standard library is used. One access line ``METHOD PATH STATUS`` is
written to stderr per request.
"""

import argparse
import base64
import hmac
import json
import mimetypes
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.parse
from email.utils import formatdate, parsedate_to_datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape

XML_DECL = '<?xml version="1.0" encoding="utf-8"?>\n'
DAV_NS = (
    'xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" '
    'xmlns:nc="http://nextcloud.org/ns" xmlns:s="http://sabredav.org/ns"'
)
FILES_PREFIX = "/remote.php/dav/files/"
TRASHBIN_PREFIX = "/remote.php/dav/trashbin/"
VERSIONS_PREFIX = "/remote.php/dav/versions/"
UPLOADS_PREFIX = "/remote.php/dav/uploads/"

# Login Flow v2 hands out this app password; basic auth accepts it once a
# flow has been started, like a real Nextcloud app password.
LOGIN_APP_PASSWORD = "app-pass"

# 1x1 transparent PNG served by the avatar endpoint.
PNG_1X1 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)

# Sharee autocomplete seeds: (shareWith, label) per share type.
SHAREE_USERS = (("alice", "Alice Anderson"), ("bob", "Bob Brown"))
SHAREE_GROUPS = (("team-blue", "Team Blue"),)

CAPABILITIES_XML = (
    XML_DECL + "<ocs><meta><status>ok</status><statuscode>200</statuscode>"
    "<message>OK</message></meta><data>"
    "<version><major>34</major><minor>0</minor><micro>0</micro>"
    "<string>34.0.0</string></version>"
    "<capabilities><files>"
    "<bigfilechunking>true</bigfilechunking>"
    "<chunked_upload><max_size>10485760</max_size>"
    "<max_parallel_count>5</max_parallel_count></chunked_upload>"
    "<checksums><supportedTypes><element>SHA256</element></supportedTypes>"
    "<preferredUploadType>SHA256</preferredUploadType></checksums>"
    "<versioning>true</versioning>"
    "</files>"
    "<files_trashbin><undelete>true</undelete><versioning>true</versioning></files_trashbin>"
    "<files_versions><versioning>true</versioning></files_versions>"
    "<files_sharing>"
    "<api_enabled>true</api_enabled>"
    "<public><enabled>true</enabled>"
    "<password><enforced>true</enforced></password>"
    "<expire_date><enforced>false</enforced></expire_date>"
    "<default_permissions>1</default_permissions>"
    "<default_internal_expire_date><enforced>false</enforced></default_internal_expire_date>"
    "<default_remote_expire_date><enforced>false</enforced></default_remote_expire_date></public>"
    "<user><default_permissions>31</default_permissions></user>"
    "<resharing>true</resharing><group_sharing>true</group_sharing>"
    "<federation><outgoing>true</outgoing><incoming>true</incoming></federation>"
    "<sharebymail><enabled>true</enabled></sharebymail>"
    "</files_sharing>"
    "<comments><maxCharacters>1000</maxCharacters><maxUserMentions>10</maxUserMentions></comments>"
    "<systemtags><enabled>true</enabled></systemtags>"
    "<notifications><ocs-endpoints><element>list</element><element>get</element>"
    "<element>delete</element></ocs-endpoints></notifications>"
    "<user_status><enabled>true</enabled><supports_emoji>true</supports_emoji></user_status>"
    "<activity><apiv2><element>filters</element><element>filter</element></apiv2></activity>"
    "<dav><chunking>1.0</chunking></dav>"
    "</capabilities></data></ocs>"
)

CAPABILITIES_JSON = {
    "ocs": {
        "meta": {"status": "ok", "statuscode": 200, "message": "OK"},
        "data": {
            "version": {
                "major": 34,
                "minor": 0,
                "micro": 0,
                "string": "34.0.0",
                "edition": "",
                "extendedSupport": False,
            },
            "capabilities": {
                "files": {
                    "bigfilechunking": True,
                    "undelete": True,
                    "versioning": True,
                    "chunked_upload": {"max_size": 10485760, "max_parallel_count": 5},
                    "checksums": {
                        "supportedTypes": ["SHA256"],
                        "preferredUploadType": "SHA256",
                    },
                },
                "files_trashbin": {"undelete": True, "versioning": True},
                "files_versions": {"versioning": True},
                "files_sharing": {
                    "api_enabled": True,
                    "public": {
                        "enabled": True,
                        "password": {"enforced": True},
                        "expire_date": {"enforced": False},
                        "default_permissions": 1,
                        "default_internal_expire_date": {"enforced": False},
                        "default_remote_expire_date": {"enforced": False},
                    },
                    "user": {"default_permissions": 31},
                    "resharing": True,
                    "group_sharing": True,
                    "federation": {"outgoing": True, "incoming": True},
                    "sharebymail": {"enabled": True},
                },
                "comments": {"maxCharacters": 1000, "maxUserMentions": 10},
                "systemtags": {"enabled": True},
                "notifications": {"ocs-endpoints": ["list", "get", "delete"]},
                "user_status": {"enabled": True, "supports_emoji": True},
                "activity": {"apiv2": ["filters", "filter"]},
                "dav": {"chunking": "1.0"},
            },
        },
    }
}

# Files-root quota reported by PROPFIND, so `rclone about` (and therefore
# `sciebo quota` and `account info`) has numbers to show.
QUOTA_AVAILABLE_BYTES = 10 * 1024 ** 3
QUOTA_USED_BYTES = 1 * 1024 ** 3


def dav_error(message):
    """A DAV error body (used for 401/404/... responses)."""
    return (
        XML_DECL + '<d:error %s><s:message>%s</s:message></d:error>' % (DAV_NS, escape(message))
    )


def ocs_envelope(data):
    """Wrap DATA in the OCS v2 envelope used by the real Nextcloud API."""
    return (
        XML_DECL + "<ocs><meta><status>ok</status><statuscode>200</statuscode>"
        "<message>OK</message></meta><data>%s</data></ocs>" % data
    )


def ocs_empty():
    return (
        XML_DECL + "<ocs><meta><status>ok</status><statuscode>200</statuscode>"
        "<message>OK</message></meta><data/></ocs>"
    )


def ocs_error(message, statuscode=404):
    return (
        XML_DECL + "<ocs><meta><status>failure</status><statuscode>%d</statuscode>"
        "<message>%s</message></meta></ocs>" % (statuscode, escape(message))
    )


def ocs_json(data, statuscode=200):
    """The same OCS v2 envelope as ocs_envelope, as JSON (format=json)."""
    return json.dumps(
        {
            "ocs": {
                "meta": {"status": "ok", "statuscode": statuscode, "message": "OK"},
                "data": data,
            }
        },
        separators=(",", ":"),
    )


def ocs_json_error(message, statuscode=404):
    return json.dumps(
        {
            "ocs": {
                "meta": {"status": "failure", "statuscode": statuscode, "message": message},
                "data": [],
            }
        },
        separators=(",", ":"),
    )


def iso_now(offset=0):
    return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() + offset))


class State:
    """In-memory OCS state plus the on-disk WebDAV tree."""

    def __init__(self, root):
        self.root = root
        self._next_id = 1
        self._ids = {}
        self.favorites = set()
        self.tags = {}
        self.comments = {}
        self.next_comment = 1
        self.systemtags = []
        self.next_tag = 1
        self.shares = []
        self.next_share = 1
        self.status = {"status": "online", "message": "Working from home", "icon": "\U0001f642", "clearAt": ""}
        # Pending shares are seeded with stable ids so tests can drive
        # accept/decline deterministically: 501 is a local user share, 601 a
        # pending federated share. Accepting moves a share to self.shares /
        # self.remote_shares; declining drops it.
        self.pending_shares = [
            {
                "id": 501,
                "share_type": 0,
                "permissions": 31,
                "path": "/backup/report.txt",
                "token": "",
                "share_with": "alice",
                "share_with_displayname": "Alice",
                "uid_owner": "bob",
                "displayname_owner": "Bob",
                "expiration": "",
                "note": "",
                "label": "",
                "state": 1,
            }
        ]
        self.remote_shares = []
        self.remote_pending = [
            {
                "id": 601,
                "remote": "https://remote.example.org",
                "remote_id": 42,
                "share_token": "fed-token-601",
                "name": "fed-report.txt",
                "owner": "carol",
                "user": "alice",
                "mountpoint": "/fed-report.txt",
                "share_type": 6,
            }
        ]
        self.notifications = [
            {
                "notification_id": 11,
                "app": "files_sharing",
                "datetime": iso_now(-120),
                "subject": "Alice shared report.txt with you",
                "message": "Open the file to accept the share",
                "link": "https://cloud.example.org/s/42",
                # Real Nextcloud spells the HTTP method of an action <type>;
                # the link is root-absolute OCS.
                "actions": [
                    {
                        "id": "accept",
                        "label": "Accept",
                        "link": "/ocs/v2.php/apps/files_sharing/api/v1/shares/pending/501",
                        "type": "POST",
                        "primary": "true",
                    },
                    {
                        "id": "decline",
                        "label": "Decline",
                        "link": "/ocs/v2.php/apps/files_sharing/api/v1/shares/pending/501",
                        "type": "DELETE",
                        "primary": "false",
                    },
                ],
            },
            {
                "notification_id": 12,
                "app": "dav",
                "datetime": iso_now(-60),
                "subject": "Sync finished",
                "message": "3 files uploaded",
                "link": "",
                "actions": [
                    {
                        "id": "dismiss",
                        "label": "Dismiss",
                        "link": "#",
                        "type": "POST",
                        "primary": "true",
                    }
                ],
            },
        ]
        self.activity = [
            {
                "activity_id": 101,
                "app": "files",
                "type": "file_created",
                "datetime": iso_now(-90),
                "subject": "You created report.txt",
                "message": "",
                "link": "https://cloud.example.org/f/101",
                "actor": "alice",
            },
            {
                "activity_id": 102,
                "app": "files_sharing",
                "type": "shared_user_self",
                "datetime": iso_now(-30),
                "subject": "You shared notes.txt with bob",
                "message": "",
                "link": "https://cloud.example.org/f/102",
                "actor": "alice",
            },
        ]
        # Enough entries for limit/since pagination (ids 103..125).
        for activity_id in range(103, 126):
            self.activity.append(
                {
                    "activity_id": activity_id,
                    "app": "files",
                    "type": "file_changed",
                    "datetime": iso_now(-30 - (activity_id - 102) * 60),
                    "subject": "Changed file note-%d.txt" % activity_id,
                    "message": "",
                    "link": "https://cloud.example.org/f/%d" % activity_id,
                    "actor": "alice",
                }
            )
        self.locks = {}
        self.next_lock = 1
        self.trash = []
        self.versions = {}
        self.uploads = {}
        # DAV property overrides seeded per REL path (see _test_seed): keys are
        # "encrypted", "external", "checksums", and "owner".
        self.file_props = {}
        # Queued error injections: {"path", "method", "status", "count"}.
        self.faults = []
        self.login_flows = {}
        self.login_pending_polls = 0
        self.app_passwords = set()

    def fileid(self, rel):
        if rel not in self._ids:
            self._ids[rel] = self._next_id
            self._next_id += 1
        return self._ids[rel]

    def rel_for_fileid(self, fileid):
        """The DAV-relative path of FILEID, or None (used by versions)."""
        for rel, ident in self._ids.items():
            if str(ident) == str(fileid):
                return rel
        return None

    def local(self, rel):
        """Map a DAV-relative path to --state; None for escaping paths."""
        parts = [part for part in rel.split("/") if part not in ("", ".")]
        if any(part == ".." for part in parts):
            return None
        return os.path.join(self.root, *parts)

    def flat_fields(self, body):
        parsed = urllib.parse.parse_qs(body.decode("utf-8", "replace"), keep_blank_values=True)
        return {key: values[-1] for key, values in parsed.items()}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "FakeNextcloud/34.0.0"
    state = None
    user = "alice"
    password = "secret"

    # --- plumbing ---------------------------------------------------------

    def log_message(self, fmt, *args):
        pass  # access lines are written by _dispatch

    def _read_body(self):
        """Read the request body once per request and cache it.

        Every method must drain the body even when it ignores it; otherwise
        the unread bytes are parsed as the next request on a keep-alive
        connection and rclone sees spurious 400s.
        """
        if self._body is not None:
            return self._body
        length = self.headers.get("Content-Length")
        self._body = b""
        if length:
            try:
                self._body = self.rfile.read(int(length))
            except (ValueError, OSError):
                self._body = b""
        return self._body

    def _send(self, status, body="", ctype="application/xml; charset=utf-8", headers=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        if status == 204:
            self.end_headers()
            return status
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD" and body:
            self.wfile.write(body)
        return status

    def _dispatch(self):
        self._body = None  # handler instances live across keep-alive requests
        self._read_body()
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        try:
            status = self._route(path, query)
        except Exception as exc:  # keep one bad request from killing the server
            status = self._send(500, dav_error("fake server error: %s" % exc))
        sys.stderr.write("%s %s %s\n" % (self.command, self.path, status))
        sys.stderr.flush()

    def _authenticated(self, path):
        # Login Flow v2 runs before any credentials exist, so its endpoints
        # are public like on a real Nextcloud.
        if (
            path == "/status.php"
            or path.startswith("/index.php/login/v2")
            or path.startswith("/login/v2/")
        ):
            return True
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic "):
            return False
        try:
            decoded = base64.b64decode(header[6:]).decode("utf-8", "replace")
        except ValueError:
            return False
        user, _, password = decoded.partition(":")
        if not hmac.compare_digest(user, self.user):
            return False
        if hmac.compare_digest(password, self.password):
            return True
        # App passwords issued by Login Flow v2 authenticate too.
        return any(
            hmac.compare_digest(password, issued) for issued in self.state.app_passwords
        )

    # --- fault injection --------------------------------------------------

    def _query_fault(self, query):
        """A ?__fail=STATUS query parameter, or None."""
        raw = (query.get("__fail", [""])[0] or "").strip()
        if not raw.isdigit():
            return None
        return self._fault_response(int(raw))

    def _seeded_fault(self, path):
        """Consume one queued error injection matching PATH, or return None."""
        for rule in self.state.faults:
            if rule["count"] <= 0:
                continue
            if rule["method"] and rule["method"] != self.command:
                continue
            if rule["path"] and rule["path"] not in path:
                continue
            rule["count"] -= 1
            return self._fault_response(rule["status"])
        return None

    def _fault_response(self, status):
        """Render an injected error; 429 carries a short Retry-After."""
        if status == 429:
            return self._send(429, dav_error("too many requests"), headers={"Retry-After": "1"})
        if status == 503:
            return self._send(503, dav_error("service unavailable"))
        if status == 507:
            return self._send(507, dav_error("insufficient storage"))
        if status == 412:
            return self._send(412, dav_error("precondition failed"))
        if 400 <= status <= 599:
            return self._send(status, dav_error("injected fault %d" % status))
        return self._send(500, dav_error("bad injected fault %d" % status))

    def _route(self, path, query):
        if not self._authenticated(path):
            return self._send(
                401,
                dav_error("Unauthorized"),
                headers={"WWW-Authenticate": 'Basic realm="fake"'},
            )
        # Error injection is opt-in and runs before any endpoint logic: a
        # ?__fail=STATUS query wins over a queued /__test__/seed what=fail rule.
        fault = self._query_fault(query)
        if fault is None:
            fault = self._seeded_fault(path)
        if fault is not None:
            return fault
        if path == "/status.php":
            body = json.dumps(
                {"installed": True, "version": "34.0.0", "versionstring": "34.0.0"},
                separators=(",", ":"),
            )
            return self._send(200, body, "application/json")
        if path == "/__test__/redirect":
            target = query.get("to", [""])[0] or "/status.php"
            return self._send(302, "", headers={"Location": target})
        if path.startswith("/redirect/"):
            target = "/" + path[len("/redirect/") :]
            return self._send(302, "", headers={"Location": target})
        if path.startswith("/__test__/"):
            return self._test_hook(path)
        if path == "/index.php/login/v2":
            if self.command == "POST":
                return self._login_flow_start()
            return self._send(405, dav_error("method not allowed"))
        if path == "/login/v2/poll":
            if self.command == "POST":
                return self._login_flow_poll()
            return self._send(405, dav_error("method not allowed"))
        if path.startswith("/login/v2/flow/"):
            return self._login_flow_page(path)
        if path.startswith("/avatar/"):
            return self._avatar(path)
        if path.startswith("/ocs/v2.php/"):
            return self._ocs(path[len("/ocs/v2.php") :], query)
        if path.startswith("/remote.php/dav/"):
            return self._dav(path, query)
        return self._send(404, dav_error("no such endpoint: %s" % path))

    # --- OCS --------------------------------------------------------------

    def _ocs(self, path, query):
        method = self.command
        if path == "/cloud/capabilities" and method in ("GET", "HEAD"):
            if query.get("format", [""])[0] == "json":
                return self._send(
                    200, json.dumps(CAPABILITIES_JSON, separators=(",", ":")), "application/json"
                )
            return self._send(200, CAPABILITIES_XML)
        if path == "/cloud/user" and method in ("GET", "HEAD"):
            return self._send(
                200,
                ocs_envelope(
                    "<id>%s</id><displayname>User</displayname>"
                    "<email>user@example.org</email>" % escape(self.user)
                ),
            )
        if path.startswith("/apps/files_sharing/api/v1/shares/pending"):
            return self._pending_shares(path, method, query)
        if path.startswith("/apps/files_sharing/api/v1/shares"):
            return self._shares(path, method, query)
        if path.startswith("/apps/files_sharing/api/v1/remote_shares/pending"):
            return self._remote_pending(path, method, query)
        if path.startswith("/apps/files_sharing/api/v1/remote_shares"):
            return self._remote_shares(path, method, query)
        if path.startswith("/apps/files_sharing/api/v1/sharees"):
            return self._sharees(path, method, query)
        if path.startswith("/apps/notifications/api/v2/notifications"):
            return self._notifications(path, method)
        if path.startswith("/apps/activity/api/v2/activity"):
            return self._activity(path, query)
        if path.startswith("/apps/user_status/api/v1/user_status"):
            return self._user_status(path, method)
        if path == "/search/providers/files/search" and method in ("GET", "HEAD"):
            return self._search()
        return self._send(404, dav_error("no OCS endpoint: %s" % path))

    def _shares(self, path, method, query):
        rest = path[len("/apps/files_sharing/api/v1/shares") :].strip("/")
        share_id = None
        # POST /shares/<id>/send-email asks the server to mail the share to
        # its recipient; the fake accepts it for any existing share.
        if rest.endswith("/send-email"):
            sid = rest[: -len("/send-email")]
            if method != "POST" or not sid.isdigit():
                return self._send(405, dav_error("method not allowed"))
            share = next((s for s in self.state.shares if s["id"] == int(sid)), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            return self._send(200, ocs_empty())
        if rest:
            if not rest.isdigit():
                return self._send(404, dav_error("bad share id"))
            share_id = int(rest)
        if method in ("GET", "HEAD"):
            if share_id is None:
                # Older servers have no /shares/pending endpoint; clients ask
                # the regular collection instead.
                if (
                    query.get("shared_with_me", [""])[0] == "true"
                    and query.get("state", [""])[0] == "pending"
                ):
                    return self._shares_response(self.state.pending_shares, query)
                return self._shares_response(self.state.shares, query)
            share = next((s for s in self.state.shares if s["id"] == share_id), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            return self._send(200, ocs_envelope(self._share_xml(share)))
        if method == "POST":
            fields = self.state.flat_fields(self._read_body())
            try:
                share_type = int(fields.get("shareType", "3") or "3")
                permissions = int(fields.get("permissions", "1") or "1")
            except ValueError:
                return self._send(400, ocs_error("bad numeric field", 400))
            share = {
                "id": self.state.next_share,
                "share_type": share_type,
                "permissions": permissions,
                "path": "/" + fields.get("path", "").lstrip("/"),
                "token": self._token() if share_type == 3 else "",
                "share_with": fields.get("shareWith", ""),
                "expiration": fields.get("expireDate", ""),
                "note": fields.get("note", ""),
                "label": fields.get("label", ""),
            }
            self.state.next_share += 1
            self.state.shares.append(share)
            return self._send(200, ocs_envelope(self._share_xml(share)))
        if method == "PUT":
            share = next((s for s in self.state.shares if s["id"] == share_id), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            fields = self.state.flat_fields(self._read_body())
            for key, field in (
                ("permissions", "permissions"),
                ("expireDate", "expiration"),
                ("note", "note"),
                ("label", "label"),
            ):
                if key in fields:
                    share[field] = fields[key]
            return self._send(200, ocs_envelope(self._share_xml(share)))
        if method == "DELETE":
            if share_id is None:
                return self._send(400, ocs_error("share id required", 400))
            remaining = [s for s in self.state.shares if s["id"] != share_id]
            if len(remaining) == len(self.state.shares):
                return self._send(404, ocs_error("share not found"))
            self.state.shares = remaining
            return self._send(200, ocs_empty())
        return self._send(405, dav_error("method not allowed"))

    def _shares_response(self, shares, query):
        """Render a share collection as OCS XML (or JSON with format=json)."""
        if query.get("format", [""])[0] == "json":
            return self._send(
                200, ocs_json([self._share_json(share) for share in shares]), "application/json"
            )
        items = "".join("<element>%s</element>" % self._share_xml(share) for share in shares)
        return self._send(200, ocs_envelope(items))

    def _pending_shares(self, path, method, query):
        """Pending local shares: accept with POST, decline with DELETE."""
        rest = path[len("/apps/files_sharing/api/v1/shares/pending") :].strip("/")
        share_id = None
        if rest:
            if not rest.isdigit():
                return self._send(404, ocs_error("bad share id"))
            share_id = int(rest)
        if method in ("GET", "HEAD"):
            if share_id is None:
                return self._shares_response(self.state.pending_shares, query)
            share = next((s for s in self.state.pending_shares if s["id"] == share_id), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            return self._send(200, ocs_envelope(self._share_xml(share)))
        if method in ("POST", "DELETE"):
            if share_id is None:
                return self._send(400, ocs_error("share id required", 400))
            share = next((s for s in self.state.pending_shares if s["id"] == share_id), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            self.state.pending_shares = [
                s for s in self.state.pending_shares if s["id"] != share_id
            ]
            if method == "DELETE":
                return self._send(200, ocs_empty())
            share["state"] = 0
            self.state.shares.append(share)
            return self._send(200, ocs_envelope(self._share_xml(share)))
        return self._send(405, dav_error("method not allowed"))

    def _remote_pending(self, path, method, query):
        """Pending federated shares: accept with POST, decline with DELETE."""
        rest = path[len("/apps/files_sharing/api/v1/remote_shares/pending") :].strip("/")
        share_id = None
        if rest:
            if not rest.isdigit():
                return self._send(404, ocs_error("bad share id"))
            share_id = int(rest)
        if method in ("GET", "HEAD"):
            if share_id is None:
                return self._remote_response(self.state.remote_pending, query)
            share = next((s for s in self.state.remote_pending if s["id"] == share_id), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            return self._send(200, ocs_envelope("<element>%s</element>" % self._remote_share_xml(share)))
        if method in ("POST", "DELETE"):
            if share_id is None:
                return self._send(400, ocs_error("share id required", 400))
            share = next((s for s in self.state.remote_pending if s["id"] == share_id), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            self.state.remote_pending = [
                s for s in self.state.remote_pending if s["id"] != share_id
            ]
            if method == "DELETE":
                return self._send(200, ocs_empty())
            accepted = dict(share, accepted=1)
            self.state.remote_shares.append(accepted)
            return self._send(200, ocs_envelope("<element>%s</element>" % self._remote_share_xml(accepted)))
        return self._send(405, dav_error("method not allowed"))

    def _remote_shares(self, path, method, query):
        """Accepted federated shares: GET /remote_shares (read-only)."""
        rest = path[len("/apps/files_sharing/api/v1/remote_shares") :].strip("/")
        if method not in ("GET", "HEAD"):
            return self._send(405, dav_error("method not allowed"))
        if rest:
            if not rest.isdigit():
                return self._send(404, ocs_error("bad share id"))
            share = next((s for s in self.state.remote_shares if s["id"] == int(rest)), None)
            if share is None:
                return self._send(404, ocs_error("share not found"))
            return self._send(
                200, ocs_envelope("<element>%s</element>" % self._remote_share_xml(share))
            )
        return self._remote_response(self.state.remote_shares, query)

    def _remote_response(self, shares, query):
        if query.get("format", [""])[0] == "json":
            return self._send(
                200,
                ocs_json([self._remote_share_json(share) for share in shares]),
                "application/json",
            )
        items = "".join(
            "<element>%s</element>" % self._remote_share_xml(share) for share in shares
        )
        return self._send(200, ocs_envelope(items))

    def _remote_share_xml(self, share):
        return (
            "<id>%s</id><share_type>6</share_type><remote>%s</remote>"
            "<remote_id>%s</remote_id><share_token>%s</share_token><name>%s</name>"
            "<owner>%s</owner><user>%s</user><mountpoint>%s</mountpoint>"
            % (
                share["id"],
                escape(share["remote"]),
                escape(str(share["remote_id"])),
                escape(share["share_token"]),
                escape(share["name"]),
                escape(share["owner"]),
                escape(share["user"]),
                escape(share["mountpoint"]),
            )
        )

    def _remote_share_json(self, share):
        return {
            "id": str(share["id"]),
            "share_type": 6,
            "remote": share["remote"],
            "remote_id": str(share["remote_id"]),
            "share_token": share["share_token"],
            "name": share["name"],
            "owner": share["owner"],
            "user": share["user"],
            "mountpoint": share["mountpoint"],
            "accepted": int(share.get("accepted", 0)),
        }

    def _sharees(self, path, method, query):
        """Sharee autocomplete (users and groups) for share user/group."""
        if method not in ("GET", "HEAD"):
            return self._send(405, dav_error("method not allowed"))
        search = query.get("search", [""])[0].lower()
        exact_users, exact_groups, users, groups = [], [], [], []
        for share_with, label in SHAREE_USERS:
            if search and search not in share_with.lower() and search not in label.lower():
                continue
            entry = {"shareType": 0, "shareWith": share_with, "label": label}
            (exact_users if share_with.lower() == search else users).append(entry)
        for share_with, label in SHAREE_GROUPS:
            if search and search not in share_with.lower() and search not in label.lower():
                continue
            entry = {"shareType": 1, "shareWith": share_with, "label": label}
            (exact_groups if share_with.lower() == search else groups).append(entry)
        if query.get("format", [""])[0] == "json":
            data = {
                "exact": {
                    "users": [self._sharee_json(entry) for entry in exact_users],
                    "groups": [self._sharee_json(entry) for entry in exact_groups],
                    "remote": [],
                },
                "users": [self._sharee_json(entry) for entry in users],
                "groups": [self._sharee_json(entry) for entry in groups],
                "remote": [],
            }
            return self._send(200, ocs_json(data), "application/json")
        data = (
            self._sharee_section("exact", exact_users + exact_groups)
            + self._sharee_section("users", users)
            + self._sharee_section("groups", groups)
        )
        return self._send(200, ocs_envelope(data))

    def _sharee_xml(self, entry):
        return (
            "<element><label>%s</label><value><shareType>%s</shareType>"
            "<shareWith>%s</shareWith></value></element>"
            % (escape(entry["label"]), entry["shareType"], escape(entry["shareWith"]))
        )

    def _sharee_section(self, name, entries):
        if not entries:
            return ""
        return "<%s>%s</%s>" % (name, "".join(self._sharee_xml(e) for e in entries), name)

    def _sharee_json(self, entry):
        return {
            "label": entry["label"],
            "value": {"shareType": entry["shareType"], "shareWith": entry["shareWith"]},
        }

    def _token(self):
        alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return "".join(alphabet[(os.getpid() + i * 31 + len(self.state.shares)) % len(alphabet)] for i in range(8))

    def _share_xml(self, share):
        token = share.get("token", "")
        url = "%s/s/%s" % (self.headers.get("Host", "127.0.0.1"), token) if token else ""
        state = share.get("state")
        state_xml = "" if state is None else "<state>%s</state>" % state
        return (
            "<id>%s</id><share_type>%s</share_type><uid_owner>%s</uid_owner>"
            "<displayname_owner>%s</displayname_owner><permissions>%s</permissions>"
            "<path>%s</path><token>%s</token><share_with>%s</share_with>"
            "<share_with_displayname>%s</share_with_displayname><expiration>%s</expiration>"
            "<note>%s</note><label>%s</label><url>%s</url>%s"
            % (
                share["id"],
                share["share_type"],
                escape(share.get("uid_owner", self.user)),
                escape(share.get("displayname_owner", "User")),
                share["permissions"],
                escape(share["path"]),
                escape(token),
                escape(share["share_with"]),
                escape(share.get("share_with_displayname", share["share_with"])),
                escape(share["expiration"]),
                escape(share["note"]),
                escape(share["label"]),
                escape(url),
                state_xml,
            )
        )

    def _share_json(self, share):
        token = share.get("token", "")
        url = "%s/s/%s" % (self.headers.get("Host", "127.0.0.1"), token) if token else ""
        return {
            "id": str(share["id"]),
            "share_type": share["share_type"],
            "uid_owner": share.get("uid_owner", self.user),
            "permissions": share["permissions"],
            "path": share["path"],
            "token": token,
            "share_with": share["share_with"],
            "expiration": share["expiration"],
            "note": share["note"],
            "label": share["label"],
            "url": url,
            "state": share.get("state", 0),
        }

    def _notifications(self, path, method):
        rest = path[len("/apps/notifications/api/v2/notifications") :].strip("/")

        def render_actions(actions):
            if not actions:
                return ""
            return "<actions>%s</actions>" % "".join(
                "<element><id>%s</id><label>%s</label><link>%s</link>"
                "<type>%s</type><primary>%s</primary></element>"
                % (
                    escape(action.get("id", "")),
                    escape(action["label"]),
                    escape(action["link"]),
                    escape(action.get("type", "GET")),
                    action.get("primary", "false"),
                )
                for action in actions
            )

        def render(item):
            return (
                "<notification_id>%s</notification_id><app>%s</app><datetime>%s</datetime>"
                "<subject>%s</subject><message>%s</message><link>%s</link>%s"
                % (
                    item["notification_id"],
                    escape(item["app"]),
                    escape(item["datetime"]),
                    escape(item["subject"]),
                    escape(item["message"]),
                    escape(item["link"]),
                    render_actions(item.get("actions", [])),
                )
            )

        if method in ("GET", "HEAD"):
            if rest and rest.isdigit():
                item = next(
                    (n for n in self.state.notifications if n["notification_id"] == int(rest)),
                    None,
                )
                if item is None:
                    return self._send(404, ocs_error("notification not found"))
                return self._send(200, ocs_envelope("<element>%s</element>" % render(item)))
            items = "".join("<element>%s</element>" % render(n) for n in self.state.notifications)
            return self._send(200, ocs_envelope(items))
        if method == "DELETE":
            if rest and rest.isdigit():
                before = len(self.state.notifications)
                self.state.notifications = [
                    n for n in self.state.notifications if n["notification_id"] != int(rest)
                ]
                if len(self.state.notifications) == before:
                    return self._send(404, ocs_error("notification not found"))
            else:
                self.state.notifications = []
            return self._send(200, ocs_empty())
        return self._send(405, dav_error("method not allowed"))

    def _activity(self, path, query):
        rest = path[len("/apps/activity/api/v2/activity") :].strip("/")
        if rest not in ("", "filter") or self.command not in ("GET", "HEAD"):
            return self._send(404, dav_error("no activity endpoint: %s" % path))
        entries = sorted(
            self.state.activity, key=lambda item: item["activity_id"], reverse=True
        )
        since = query.get("since", [""])[0]
        if since.isdigit():
            entries = [item for item in entries if item["activity_id"] > int(since)]
        limit = query.get("limit", [""])[0]
        if limit.isdigit():
            entries = entries[: int(limit)]
        items = "".join(
            "<element><activity_id>%s</activity_id><app>%s</app><type>%s</type>"
            "<datetime>%s</datetime><timestamp>%s</timestamp><subject>%s</subject>"
            "<message>%s</message><link>%s</link><actor>%s</actor></element>"
            % (
                item["activity_id"],
                escape(item["app"]),
                escape(item["type"]),
                escape(item["datetime"]),
                escape(item["datetime"]),
                escape(item["subject"]),
                escape(item["message"]),
                escape(item["link"]),
                escape(item["actor"]),
            )
            for item in entries
        )
        return self._send(200, ocs_envelope(items))

    def _user_status(self, path, method):
        rest = path[len("/apps/user_status/api/v1/user_status") :].strip("/")
        status = self.state.status
        if method in ("GET", "HEAD") and rest == "":
            return self._send(
                200,
                ocs_envelope(
                    "<userId>%s</userId><status>%s</status><message>%s</message>"
                    "<statusIcon>%s</statusIcon><clearAt>%s</clearAt>"
                    % (
                        escape(self.user),
                        escape(status["status"]),
                        escape(status["message"]),
                        escape(status["icon"]),
                        escape(status["clearAt"]),
                    )
                ),
            )
        if method == "PUT":
            fields = self.state.flat_fields(self._read_body())
            if rest == "status":
                status["status"] = fields.get("statusType", status["status"])
            elif rest == "message":
                status["message"] = ""
                status["icon"] = ""
                status["clearAt"] = ""
            elif rest == "message/custom":
                status["message"] = fields.get("message", status["message"])
                status["icon"] = fields.get("statusIcon", status["icon"])
                status["clearAt"] = fields.get("clearAt", status["clearAt"])
            else:
                status["status"] = fields.get("statusType", fields.get("status", status["status"]))
                status["message"] = fields.get("message", status["message"])
                status["icon"] = fields.get("statusIcon", fields.get("icon", status["icon"]))
                status["clearAt"] = fields.get("clearAt", status["clearAt"])
            return self._send(200, ocs_empty())
        if method == "DELETE":
            status["message"] = ""
            status["icon"] = ""
            status["clearAt"] = ""
            return self._send(200, ocs_empty())
        return self._send(405, dav_error("method not allowed"))

    def _search(self):
        entries = (
            "<element><title>report.txt</title><subline>/backup/report.txt</subline>"
            "<resourceUrl>%s/report.txt</resourceUrl></element>"
            % (FILES_PREFIX + urllib.parse.quote(self.user))
        )
        return self._send(200, ocs_envelope("<name>files</name><entries>%s</entries>" % entries))

    # --- WebDAV -----------------------------------------------------------

    def _dav(self, path, query):
        method = self.command
        if path.startswith(FILES_PREFIX):
            rest = path[len(FILES_PREFIX) :]
            user, _, rel = rest.partition("/")
            if user != self.user:
                return self._send(404, dav_error("unknown user"))
            rel = urllib.parse.unquote(rel).strip("/")
            return self._dav_files(rel, method)
        if path.startswith(TRASHBIN_PREFIX):
            return self._dav_trash(path, method)
        if path.startswith(VERSIONS_PREFIX):
            return self._dav_versions(path, method)
        if path.startswith(UPLOADS_PREFIX):
            return self._dav_uploads(path, method)
        if path.startswith("/remote.php/dav/comments/files/"):
            return self._dav_comments(path[len("/remote.php/dav/comments/files/") :], method)
        if path.startswith("/remote.php/dav/systemtags"):
            return self._dav_systemtags(path[len("/remote.php/dav/systemtags") :], method)
        return self._send(404, dav_error("no DAV endpoint: %s" % path))

    def _dav_files(self, rel, method):
        local = self.state.local(rel)
        if local is None:
            return self._send(404, dav_error("invalid path"))
        # Conditional writes honor If-Match like a real DAV server; a stale or
        # bogus tag answers 412 (the fake's own ETag format is "%x-%x").
        if method in ("GET", "HEAD", "PUT", "DELETE", "PROPFIND") and self._if_match_conflict(local):
            return self._send(412, dav_error("If-Match precondition failed"))
        if method in ("PROPFIND", "HEAD"):
            return self._propfind(rel, local)
        if method == "GET":
            if not os.path.isfile(local):
                return self._send(404, dav_error("not a file: /%s" % rel))
            with open(local, "rb") as handle:
                data = handle.read()
            ctype = mimetypes.guess_type(local)[0] or "application/octet-stream"
            status, body, extra = self._range_slice(data)
            headers = {"Accept-Ranges": "bytes", "ETag": self._etag(local)}
            headers.update(extra)
            return self._send(status, body, ctype, headers=headers)
        if method == "PUT":
            if os.path.isdir(local):
                return self._send(405, dav_error("path is a collection"))
            parent = os.path.dirname(local)
            if parent:
                os.makedirs(parent, exist_ok=True)
            existed = os.path.exists(local)
            with open(local, "wb") as handle:
                handle.write(self._read_body())
            self._apply_mtime(local)
            return self._send(
                204 if existed else 201, headers={"ETag": self._etag(local)}
            )
        if method == "DELETE":
            if not os.path.exists(local):
                return self._send(404, dav_error("not found: /%s" % rel))
            if os.path.isdir(local):
                shutil.rmtree(local)
            else:
                os.remove(local)
            return self._send(204)
        if method == "MKCOL":
            if os.path.exists(local):
                return self._send(405, dav_error("already exists"))
            os.makedirs(local)
            return self._send(201)
        if method == "PROPPATCH":
            return self._proppatch(rel, local)
        if method == "PATCH":
            if not os.path.exists(local):
                return self._send(404, dav_error("not found: /%s" % rel))
            self._apply_mtime(local)
            return self._send(204)
        if method == "REPORT":
            return self._report()
        if method == "MOVE":
            return self._move(local)
        if method == "LOCK":
            return self._lock(rel)
        if method == "UNLOCK":
            return self._unlock(rel)
        if method == "OPTIONS":
            return self._send(
                200,
                "",
                headers={
                    "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, PROPFIND, PROPPATCH, REPORT, MOVE, LOCK, UNLOCK"
                },
            )
        return self._send(405, dav_error("method not allowed"))

    def _href(self, rel, is_dir):
        href = FILES_PREFIX + urllib.parse.quote(self.user) + "/"
        if rel:
            href += urllib.parse.quote(rel, safe="/")
        if is_dir and not href.endswith("/"):
            href += "/"
        return href

    def _etag(self, local):
        """The ETag of a file on disk (the format used in d:getetag)."""
        stat = os.stat(local)
        return '"%x-%x"' % (int(stat.st_mtime), stat.st_size)

    def _if_match_conflict(self, local):
        """True when an If-Match header names an ETag that does not match."""
        value = (self.headers.get("If-Match") or "").strip()
        if not value or value == "*":
            return False
        if not os.path.exists(local):
            return True
        return value != self._etag(local)

    def _range_slice(self, data):
        """Split DATA for one `Range: bytes=N-M` request.

        Returns (status, body, extra_headers): a single satisfiable range gets
        206 plus Content-Range, an unsatisfiable one 416, and anything
        unparseable the full body with 200 so clients always make progress.
        """
        header = self.headers.get("Range", "")
        if not header.startswith("bytes="):
            return 200, data, {}
        size = len(data)
        spec = header[len("bytes=") :].split(",")[0].strip()
        start_text, _, end_text = spec.partition("-")
        if start_text:
            if not start_text.isdigit():
                return 200, data, {}
            start = int(start_text)
            end = int(end_text) if end_text.isdigit() else size - 1
        else:
            if not end_text.isdigit():
                return 200, data, {}
            start = max(0, size - int(end_text))
            end = size - 1
        if start >= size or start > end:
            return 416, b"", {"Content-Range": "bytes */%d" % size}
        end = min(end, size - 1)
        return 206, data[start : end + 1], {
            "Content-Range": "bytes %d-%d/%d" % (start, end, size)
        }

    def _dav_response(self, rel, local):
        is_dir = os.path.isdir(local)
        stat = os.stat(local)
        etag = self._etag(local)
        info = self.state.file_props.get(rel, {})
        lock = self.state.locks.get(rel)
        lock_props = ""
        if lock:
            lock_props = (
                "<d:lockdiscovery>%s</d:lockdiscovery>"
                "<d:locktoken>%s</d:locktoken>"
                "<nc:lock-token>%s</nc:lock-token>"
                % (
                    self._activelock_xml(lock["token"], lock.get("owner", "")),
                    escape(lock["token"]),
                    escape(lock["token"]),
                )
            )
        # External storages are marked by an M in oc:permissions, on top of
        # the usual letters shared by files and directories.
        permissions = "RGDNVCK" if is_dir else "RGDNVW"
        if info.get("external"):
            permissions += "M"
        # nc:is-encrypted is only advertised for paths seeded as encrypted:
        # a real Nextcloud answers it everywhere, but clients only probe for
        # it, and an always-present "0" would trigger their bounded recursive
        # E2EE scan on every folder (changing request counts for other tests).
        e2ee_prop = "<nc:is-encrypted>1</nc:is-encrypted>" if info.get("encrypted") else ""
        # The quota belongs to the files root only, like on a real Nextcloud.
        quota_props = ""
        if not rel:
            quota_props = (
                "<d:quota-available-bytes>%d</d:quota-available-bytes>"
                "<d:quota-used-bytes>%d</d:quota-used-bytes>"
                % (QUOTA_AVAILABLE_BYTES, QUOTA_USED_BYTES)
            )
        props = (
            "<d:resourcetype>%s</d:resourcetype>"
            "<d:getcontentlength>%d</d:getcontentlength>"
            "<d:getlastmodified>%s</d:getlastmodified>"
            "<d:getetag>%s</d:getetag>"
            "<d:owner-id>%s</d:owner-id>"
            "<oc:fileid>%d</oc:fileid>"
            "<oc:permissions>%s</oc:permissions>"
            "<oc:favorite>%s</oc:favorite>"
            "<oc:checksums>%s</oc:checksums>"
            "<oc:size>%d</oc:size>%s%s%s"
            % (
                "<d:collection/>" if is_dir else "",
                0 if is_dir else stat.st_size,
                formatdate(stat.st_mtime, usegmt=True),
                etag,
                escape(info.get("owner", self.user)),
                self.state.fileid(rel),
                permissions,
                "1" if rel in self.state.favorites else "0",
                escape(info.get("checksums", "")),
                0 if is_dir else stat.st_size,
                e2ee_prop,
                quota_props,
                lock_props,
            )
        )
        return self._response(self._href(rel, is_dir), props)

    def _response(self, href, props, status="HTTP/1.1 200 OK"):
        return (
            "<d:response><d:href>%s</d:href><d:propstat><d:prop>%s</d:prop>"
            "<d:status>%s</d:status></d:propstat></d:response>"
            % (escape(href), props, status)
        )

    def _multistatus(self, responses):
        return XML_DECL + "<d:multistatus %s>%s</d:multistatus>" % (DAV_NS, "".join(responses))

    def _propfind(self, rel, local):
        if not os.path.exists(local):
            return self._send(404, dav_error("not found: /%s" % rel))
        entries = [(rel, local)]
        depth = (self.headers.get("Depth") or "1").lower()
        if os.path.isdir(local) and depth != "0":
            for name in sorted(os.listdir(local)):
                child_rel = (rel + "/" + name) if rel else name
                entries.append((child_rel, os.path.join(local, name)))
        return self._send(
            207, self._multistatus([self._dav_response(r, l) for r, l in entries])
        )

    def _proppatch(self, rel, local):
        if not os.path.exists(local):
            return self._send(404, dav_error("not found: /%s" % rel))
        body = self._read_body().decode("utf-8", "replace")
        props = []
        match = re.search(r"<oc:favorite>\s*([^<]*?)\s*</oc:favorite>", body)
        if match:
            if match.group(1) in ("1", "true", "on"):
                self.state.favorites.add(rel)
            elif match.group(1) in ("0", "false", "off"):
                self.state.favorites.discard(rel)
            props.append("<oc:favorite/>")
        match = re.search(r"<oc:tags>\s*([^<]*?)\s*</oc:tags>", body)
        if match:
            self.state.tags[rel] = match.group(1)
            props.append("<oc:tags/>")
        match = re.search(r"<d:getlastmodified>\s*([^<]*?)\s*</d:getlastmodified>", body)
        if match:
            try:
                stamp = parsedate_to_datetime(match.group(1)).timestamp()
                os.utime(local, (stamp, stamp))
            except (TypeError, ValueError, OSError):
                pass
            props.append("<d:getlastmodified/>")
        if not props:
            props.append("<d:resourcetype/>")
        return self._send(
            207,
            self._multistatus(
                [self._response(self._href(rel, os.path.isdir(local)), "".join(props))]
            ),
        )

    def _report(self):
        body = self._read_body().decode("utf-8", "replace")
        responses = []
        if "filter-rules" in body and "<oc:favorite>1</oc:favorite>" in body:
            for rel in sorted(self.state.favorites):
                local = self.state.local(rel)
                if local and os.path.exists(local):
                    responses.append(self._dav_response(rel, local))
        return self._send(207, self._multistatus(responses))

    def _apply_mtime(self, local):
        """Honor rclone's X-OC-Mtime upload header (epoch seconds)."""
        value = self.headers.get("X-OC-Mtime") or self.headers.get("X-OC-MTime")
        if not value:
            return
        try:
            os.utime(local, (int(value), int(value)))
        except (ValueError, OSError):
            pass

    def _move(self, local):
        if not os.path.exists(local):
            return self._send(404, dav_error("not found"))
        parsed = urllib.parse.urlsplit(self.headers.get("Destination", ""))
        prefix = FILES_PREFIX + self.user + "/"
        if not parsed.path.startswith(prefix):
            return self._send(400, dav_error("bad destination"))
        dest_rel = urllib.parse.unquote(parsed.path[len(prefix) :]).strip("/")
        dest_local = self.state.local(dest_rel)
        if dest_local is None:
            return self._send(400, dav_error("bad destination"))
        parent = os.path.dirname(dest_local)
        if parent:
            os.makedirs(parent, exist_ok=True)
        shutil.move(local, dest_local)
        return self._send(201)

    # --- locks ------------------------------------------------------------

    def _activelock_xml(self, token, owner=""):
        owner_xml = "<d:owner>%s</d:owner>" % escape(owner) if owner else ""
        return (
            "<d:activelock><d:locktype><d:write/></d:locktype>"
            "<d:lockscope><d:exclusive/></d:lockscope><d:depth>0</d:depth>%s"
            "<d:timeout>Second-3600</d:timeout>"
            "<d:locktoken><d:href>%s</d:href></d:locktoken></d:activelock>"
            % (owner_xml, escape(token))
        )

    def _lock_owner(self):
        """Best-effort owner from a JSON or DAV lock body; the user otherwise."""
        body = self._read_body()
        if not body:
            return self.user
        text = body.decode("utf-8", "replace")
        try:
            parsed = json.loads(text)
        except ValueError:
            parsed = None
        if isinstance(parsed, dict) and parsed.get("owner"):
            return str(parsed["owner"])
        match = re.search(r"<d:owner>\s*([^<]*?)\s*</d:owner>", text)
        if match:
            return match.group(1)
        return self.user

    def _lock(self, rel):
        if rel in self.state.locks:
            return self._send(423, dav_error("locked: /%s" % rel))
        token = "opaquelocktoken:fake-%d" % self.state.next_lock
        self.state.next_lock += 1
        self.state.locks[rel] = {"token": token, "owner": self._lock_owner()}
        body = (
            XML_DECL + "<d:prop %s><d:lockdiscovery>%s</d:lockdiscovery></d:prop>"
            % (DAV_NS, self._activelock_xml(token, self.state.locks[rel]["owner"]))
        )
        return self._send(200, body, headers={"Lock-Token": token})

    def _unlock(self, rel):
        lock = self.state.locks.get(rel)
        token = (self.headers.get("Lock-Token") or "").strip().strip("<>")
        if lock is None:
            return self._send(404, dav_error("not locked: /%s" % rel))
        if token != lock["token"]:
            return self._send(409, dav_error("lock token mismatch"))
        del self.state.locks[rel]
        return self._send(204)

    # --- trashbin ---------------------------------------------------------

    def _dav_trash(self, path, method):
        rest = path[len(TRASHBIN_PREFIX) :]
        user, _, rel = rest.partition("/")
        if user != self.user:
            return self._send(404, dav_error("unknown user"))
        rel = urllib.parse.unquote(rel).strip("/")
        if rel == "trash":
            item_name = None
        elif rel.startswith("trash/"):
            item_name = rel[len("trash/") :]
        else:
            return self._send(404, dav_error("bad trash path"))
        if item_name is None:
            if method in ("PROPFIND", "HEAD"):
                return self._trash_propfind(None)
            if method == "DELETE":
                self.state.trash = []
                return self._send(204)
            return self._send(405, dav_error("method not allowed"))
        item = self._trash_item(item_name)
        if item is None:
            return self._send(404, dav_error("no such trash item"))
        if method in ("PROPFIND", "HEAD"):
            return self._trash_propfind(item_name)
        if method == "MOVE":
            return self._trash_restore(item)
        if method == "DELETE":
            self.state.trash.remove(item)
            return self._send(204)
        return self._send(405, dav_error("method not allowed"))

    def _trash_item(self, name):
        return next((item for item in self.state.trash if item["name"] == name), None)

    def _trash_propfind(self, item_name):
        # An empty trashbin keeps answering the historical empty multistatus.
        if not self.state.trash:
            return self._send(207, self._multistatus([]))
        base = TRASHBIN_PREFIX + urllib.parse.quote(self.user) + "/trash"
        responses = []
        if item_name is None:
            responses.append(
                self._response(base + "/", "<d:resourcetype><d:collection/></d:resourcetype>")
            )
            items = self.state.trash
        else:
            items = [item for item in self.state.trash if item["name"] == item_name]
        for item in items:
            props = (
                "<d:resourcetype/>"
                "<oc:trashbin-original-filename>%s</oc:trashbin-original-filename>"
                "<oc:trashbin-original-location>%s</oc:trashbin-original-location>"
                "<oc:trashbin-delete-timestamp>%d</oc:trashbin-delete-timestamp>"
                "<d:getcontentlength>%d</d:getcontentlength>"
                % (
                    escape(item["original_filename"]),
                    escape(item["original_location"]),
                    item["timestamp"],
                    item["size"],
                )
            )
            responses.append(
                self._response(base + "/" + urllib.parse.quote(item["name"]), props)
            )
        return self._send(207, self._multistatus(responses))

    def _trash_restore(self, item):
        parsed = urllib.parse.urlsplit(self.headers.get("Destination", ""))
        dest = urllib.parse.unquote(parsed.path)
        restore_prefix = TRASHBIN_PREFIX + self.user + "/restore/"
        files_prefix = FILES_PREFIX + self.user + "/"
        if dest.startswith(restore_prefix):
            rel = item["original_location"]
        elif dest.startswith(files_prefix):
            rel = dest[len(files_prefix) :].strip("/")
        else:
            return self._send(400, dav_error("bad destination"))
        local = self.state.local(rel)
        if local is None:
            return self._send(400, dav_error("bad destination"))
        parent = os.path.dirname(local)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(local, "wb") as handle:
            handle.write(item["content"])
        self.state.trash.remove(item)
        return self._send(201)

    # --- file versions ----------------------------------------------------

    def _dav_versions(self, path, method):
        rest = path[len(VERSIONS_PREFIX) :]
        user, _, rel = rest.partition("/")
        if user != self.user:
            return self._send(404, dav_error("unknown user"))
        parts = [part for part in urllib.parse.unquote(rel).strip("/").split("/") if part]
        if len(parts) < 2 or parts[0] != "versions" or not parts[1].isdigit():
            return self._send(404, dav_error("bad versions path"))
        fileid = parts[1]
        version_id = parts[2] if len(parts) > 2 else None
        versions = self.state.versions.get(fileid, [])
        if method in ("PROPFIND", "HEAD"):
            return self._versions_propfind(fileid, versions)
        version = next((v for v in versions if v["id"] == version_id), None)
        if version is None:
            return self._send(404, dav_error("no such version"))
        if method == "GET":
            return self._send(200, version["content"], "application/octet-stream")
        if method == "DELETE":
            versions.remove(version)
            return self._send(204)
        if method == "MOVE":
            return self._versions_restore(fileid, version)
        return self._send(405, dav_error("method not allowed"))

    def _versions_propfind(self, fileid, versions):
        if not versions:
            return self._send(207, self._multistatus([]))
        base = (
            VERSIONS_PREFIX + urllib.parse.quote(self.user) + "/versions/" + fileid
        )
        responses = [
            self._response(base + "/", "<d:resourcetype><d:collection/></d:resourcetype>")
        ]
        for version in sorted(versions, key=lambda v: v["id"]):
            props = (
                "<d:resourcetype/>"
                "<d:getcontentlength>%d</d:getcontentlength>"
                "<d:getlastmodified>%s</d:getlastmodified>"
                % (len(version["content"]), formatdate(version["timestamp"], usegmt=True))
            )
            responses.append(self._response(base + "/" + version["id"], props))
        return self._send(207, self._multistatus(responses))

    def _versions_restore(self, fileid, version):
        parsed = urllib.parse.urlsplit(self.headers.get("Destination", ""))
        dest = urllib.parse.unquote(parsed.path)
        restore_prefix = VERSIONS_PREFIX + self.user + "/restore/"
        if not dest.startswith(restore_prefix):
            return self._send(400, dav_error("bad destination"))
        rel = self.state.rel_for_fileid(fileid)
        if rel is None:
            return self._send(404, dav_error("no such file"))
        local = self.state.local(rel)
        if local is None:
            return self._send(400, dav_error("bad destination"))
        parent = os.path.dirname(local)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(local, "wb") as handle:
            handle.write(version["content"])
        return self._send(201)

    # --- chunked uploads --------------------------------------------------

    def _dav_uploads(self, path, method):
        rest = path[len(UPLOADS_PREFIX) :]
        user, _, rel = rest.partition("/")
        if user != self.user:
            return self._send(404, dav_error("unknown user"))
        parts = [part for part in urllib.parse.unquote(rel).strip("/").split("/") if part]
        if not parts:
            return self._send(404, dav_error("bad upload path"))
        upload_id = parts[0]
        if len(parts) == 1:
            if method == "MKCOL":
                if upload_id in self.state.uploads:
                    return self._send(405, dav_error("upload exists"))
                self.state.uploads[upload_id] = {}
                return self._send(201)
            if method == "DELETE":
                if upload_id not in self.state.uploads:
                    return self._send(404, dav_error("no such upload"))
                del self.state.uploads[upload_id]
                return self._send(204)
            return self._send(405, dav_error("method not allowed"))
        chunk = "/".join(parts[1:])
        chunks = self.state.uploads.get(upload_id)
        if chunks is None:
            return self._send(404, dav_error("no such upload"))
        if method == "PUT":
            chunks[chunk] = self._read_body()
            return self._send(201)
        if method == "MOVE" and chunk == ".file":
            return self._upload_assemble(upload_id, chunks)
        return self._send(404, dav_error("bad upload path"))

    def _upload_assemble(self, upload_id, chunks):
        parsed = urllib.parse.urlsplit(self.headers.get("Destination", ""))
        prefix = FILES_PREFIX + self.user + "/"
        if not parsed.path.startswith(prefix):
            return self._send(400, dav_error("bad destination"))
        rel = urllib.parse.unquote(parsed.path[len(prefix) :]).strip("/")
        local = self.state.local(rel)
        if local is None:
            return self._send(400, dav_error("bad destination"))
        parent = os.path.dirname(local)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(local, "wb") as handle:
            for name in self._chunk_order(chunks):
                handle.write(chunks[name])
        self._apply_mtime(local)
        del self.state.uploads[upload_id]
        return self._send(201)

    @staticmethod
    def _chunk_order(chunks):
        """Upload chunk names as integers where possible (1 before 10)."""

        def key(name):
            return (0, int(name), "") if name.isdigit() else (1, 0, name)

        return sorted(chunks, key=key)

    def _dav_comments(self, rest, method):
        parts = [part for part in rest.strip("/").split("/") if part]
        if not parts or not parts[0].isdigit():
            return self._send(404, dav_error("bad comment path"))
        fileid = parts[0]
        comment_id = parts[1] if len(parts) > 1 else None
        comments = self.state.comments.setdefault(fileid, [])
        if method in ("PROPFIND", "HEAD"):
            responses = []
            for comment in comments:
                props = (
                    "<oc:id>%s</oc:id><oc:actorId>%s</oc:actorId>"
                    "<oc:actorDisplayName>User</oc:actorDisplayName>"
                    "<oc:message>%s</oc:message>"
                    "<oc:creationDateTime>%s</oc:creationDateTime><oc:verb>comment</oc:verb>"
                    % (
                        comment["id"],
                        escape(self.user),
                        escape(comment["message"]),
                        escape(comment["datetime"]),
                    )
                )
                href = "/remote.php/dav/comments/files/%s/%s" % (fileid, comment["id"])
                responses.append(self._response(href, props))
            return self._send(207, self._multistatus(responses))
        if method == "POST":
            body = self._read_body().decode("utf-8", "replace")
            match = re.search(r"<oc:message>\s*([^<]*?)\s*</oc:message>", body)
            comment = {
                "id": self.state.next_comment,
                "message": match.group(1) if match else "",
                "datetime": iso_now(),
            }
            self.state.next_comment += 1
            comments.append(comment)
            href = "/remote.php/dav/comments/files/%s/%s" % (fileid, comment["id"])
            props = (
                "<oc:id>%s</oc:id><oc:message>%s</oc:message>"
                "<oc:creationDateTime>%s</oc:creationDateTime>"
                % (comment["id"], escape(comment["message"]), escape(comment["datetime"]))
            )
            return self._send(201, XML_DECL + "<d:prop %s>%s</d:prop>" % (DAV_NS, props))
        if method == "DELETE":
            if comment_id is None or not comment_id.isdigit():
                return self._send(400, dav_error("comment id required"))
            before = len(comments)
            self.state.comments[fileid] = [c for c in comments if c["id"] != int(comment_id)]
            if len(self.state.comments[fileid]) == before:
                return self._send(404, dav_error("comment not found"))
            return self._send(204)
        return self._send(405, dav_error("method not allowed"))

    def _dav_systemtags(self, rest, method):
        tag_id = rest.strip("/")
        if method in ("PROPFIND", "HEAD"):
            responses = []
            for tag in self.state.systemtags:
                if tag_id and tag_id.isdigit() and tag["id"] != int(tag_id):
                    continue
                props = (
                    "<oc:id>%s</oc:id><oc:display-name>%s</oc:display-name>"
                    "<oc:user-visible>%s</oc:user-visible>"
                    "<oc:user-assignable>%s</oc:user-assignable>"
                    % (tag["id"], escape(tag["name"]), tag["visible"], tag["assignable"])
                )
                responses.append(
                    self._response("/remote.php/dav/systemtags/%s" % tag["id"], props)
                )
            return self._send(207, self._multistatus(responses))
        if method == "POST":
            body = self._read_body().decode("utf-8", "replace")
            match = re.search(r"<oc:display-name>\s*([^<]*?)\s*</oc:display-name>", body)
            tag = {
                "id": self.state.next_tag,
                "name": match.group(1) if match else "tag",
                "visible": "true",
                "assignable": "true",
            }
            self.state.next_tag += 1
            self.state.systemtags.append(tag)
            props = (
                "<oc:id>%s</oc:id><oc:display-name>%s</oc:display-name>"
                "<oc:user-visible>true</oc:user-visible>"
                "<oc:user-assignable>true</oc:user-assignable>"
                % (tag["id"], escape(tag["name"]))
            )
            return self._send(201, XML_DECL + "<oc:systemtag %s>%s</oc:systemtag>" % (DAV_NS, props))
        return self._send(405, dav_error("method not allowed"))

    # --- test hooks -------------------------------------------------------

    def _test_hook(self, path):
        if self.command != "POST":
            return self._send(405, dav_error("method not allowed"))
        if path == "/__test__/seed":
            return self._test_seed()
        if path == "/__test__/login":
            return self._test_login()
        return self._send(404, dav_error("no test hook: %s" % path))

    def _test_seed(self):
        """Seed trashbin/versions fixtures on demand (see the module docstring)."""
        fields = self.state.flat_fields(self._read_body())
        what = fields.get("what", "")
        if what == "trash":
            content = fields.get("content", "restored from trash\n").encode("utf-8")
            item = {
                "name": "plan.txt.d1700000000",
                "original_filename": "plan.txt",
                "original_location": "notes/plan.txt",
                "timestamp": 1700000000,
                "content": content,
                "size": len(content),
            }
            self.state.trash = [i for i in self.state.trash if i["name"] != item["name"]]
            self.state.trash.append(item)
            return self._send(
                200,
                json.dumps(
                    {"seeded": "trash", "name": item["name"]}, separators=(",", ":")
                ),
                "application/json",
            )
        if what == "versions":
            rel = fields.get("path", "report.txt").lstrip("/")
            local = self.state.local(rel)
            if local is None:
                return self._send(400, dav_error("bad path"))
            parent = os.path.dirname(local)
            if parent:
                os.makedirs(parent, exist_ok=True)
            if not os.path.isfile(local):
                with open(local, "wb") as handle:
                    handle.write(b"current content\n")
            fileid = self.state.fileid(rel)
            version = {
                "id": "1700000000",
                "timestamp": 1700000000,
                "content": fields.get("content", "version-one-payload\n").encode("utf-8"),
            }
            self.state.versions[str(fileid)] = [version]
            return self._send(
                200,
                json.dumps(
                    {
                        "seeded": "versions",
                        "fileid": fileid,
                        "version": version["id"],
                        "path": rel,
                    },
                    separators=(",", ":"),
                ),
                "application/json",
            )
        if what in ("props", "e2ee", "external", "checksums", "owner"):
            return self._test_seed_props(what, fields)
        if what == "fail":
            return self._test_seed_fail(fields)
        return self._send(400, dav_error("unknown seed: %s" % what))

    def _test_seed_props(self, what, fields):
        """Override DAV properties for one REL path (E2EE, mount, checksums)."""
        rel = fields.get("path", "").lstrip("/")
        if not rel:
            return self._send(400, dav_error("props seed requires a path"))
        info = self.state.file_props.setdefault(rel, {})
        if what == "e2ee":
            info["encrypted"] = True
        elif what == "external":
            info["external"] = True
        elif what == "checksums":
            info["checksums"] = fields.get("checksums", "SHA256:0")
        elif what == "owner":
            info["owner"] = fields.get("owner", self.user)
        else:
            if "encrypted" in fields:
                info["encrypted"] = fields["encrypted"].lower() in ("1", "true", "yes", "on")
            if "external" in fields:
                info["external"] = fields["external"].lower() in ("1", "true", "yes", "on")
            if "checksums" in fields:
                info["checksums"] = fields["checksums"]
            if "owner" in fields:
                info["owner"] = fields["owner"]
        return self._send(
            200,
            json.dumps(
                {"seeded": "props", "path": rel, "props": info}, separators=(",", ":")
            ),
            "application/json",
        )

    def _test_seed_fail(self, fields):
        """Queue an injected error for a path (and optionally a method)."""
        status = fields.get("status", "500")
        count = fields.get("count", "1")
        rule = {
            "path": fields.get("path", ""),
            "method": fields.get("method", ""),
            "status": int(status) if status.isdigit() else 500,
            "count": int(count) if count.isdigit() else 1,
        }
        self.state.faults.append(rule)
        return self._send(
            200,
            json.dumps({"seeded": "fail", "rule": rule}, separators=(",", ":")),
            "application/json",
        )

    def _test_login(self):
        pending = self.state.flat_fields(self._read_body()).get("polls", "0")
        self.state.login_pending_polls = int(pending) if pending.isdigit() else 0
        return self._send(
            200,
            json.dumps(
                {"pending_polls": self.state.login_pending_polls}, separators=(",", ":")
            ),
            "application/json",
        )

    # --- login flow v2 ----------------------------------------------------

    def _base_url(self):
        return "http://" + self.headers.get("Host", "127.0.0.1")

    def _login_flow_start(self):
        token = "flow-%d" % (len(self.state.login_flows) + 1)
        base = self._base_url()
        self.state.login_flows[token] = {"polls": 0}
        # The issued app password becomes a valid basic-auth credential, like
        # a real Nextcloud app password.
        self.state.app_passwords.add(LOGIN_APP_PASSWORD)
        body = json.dumps(
            {
                "poll": {"token": token, "endpoint": base + "/login/v2/poll"},
                "login": base + "/login/v2/flow/" + token,
            },
            separators=(",", ":"),
        )
        return self._send(200, body, "application/json")

    def _login_flow_poll(self):
        token = self.state.flat_fields(self._read_body()).get("token", "")
        flow = self.state.login_flows.get(token)
        if flow is None:
            return self._send(404, "", "application/json")
        if flow["polls"] < self.state.login_pending_polls:
            flow["polls"] += 1
            return self._send(404, "", "application/json")
        body = json.dumps(
            {
                "server": self._base_url(),
                "loginName": self.user,
                "appPassword": LOGIN_APP_PASSWORD,
            },
            separators=(",", ":"),
        )
        return self._send(200, body, "application/json")

    def _login_flow_page(self, path):
        token = path[len("/login/v2/flow/") :].strip("/")
        if token not in self.state.login_flows:
            return self._send(404, dav_error("unknown login flow"))
        return self._send(
            200,
            "<html><body>Login flow %s</body></html>" % escape(token),
            "text/html; charset=utf-8",
        )

    # --- avatar -----------------------------------------------------------

    def _avatar(self, path):
        parts = [part for part in path.strip("/").split("/") if part]
        if len(parts) < 2 or urllib.parse.unquote(parts[1]) != self.user:
            return self._send(404, dav_error("no such avatar"))
        size = parts[2] if len(parts) > 2 else "128"
        if not size.isdigit():
            return self._send(400, dav_error("bad avatar size"))
        return self._send(200, PNG_1X1, "image/png")

    # HTTP method entry points; every one shares the router above.
    do_GET = _dispatch
    do_HEAD = _dispatch
    do_POST = _dispatch
    do_PUT = _dispatch
    do_DELETE = _dispatch
    do_PROPFIND = _dispatch
    do_PROPPATCH = _dispatch
    do_PATCH = _dispatch
    do_REPORT = _dispatch
    do_MKCOL = _dispatch
    do_MOVE = _dispatch
    do_OPTIONS = _dispatch
    do_LOCK = _dispatch
    do_UNLOCK = _dispatch


def main(argv=None):
    parser = argparse.ArgumentParser(description="Fake Nextcloud server for feature tests")
    parser.add_argument("--port", type=int, default=0, help="port to bind (0 picks a free one)")
    parser.add_argument("--user", default="alice", help="basic-auth user")
    parser.add_argument("--password", default="secret", help="basic-auth password")
    parser.add_argument("--state", default=None, help="directory backing the WebDAV tree")
    args = parser.parse_args(argv)

    root = args.state if args.state else tempfile.mkdtemp(prefix="fake-nextcloud.")
    os.makedirs(root, exist_ok=True)
    Handler.state = State(root)
    Handler.user = args.user
    Handler.password = args.password

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    if args.port == 0:
        print("PORT=%d" % server.server_address[1])
        sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
