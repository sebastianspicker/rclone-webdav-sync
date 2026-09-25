#!/bin/bash
# proxy.sh - the PROXY_TYPE/PROXY/PROXY_DIRECT classification decision
# shared by the curl and rclone proxy resolvers (lib/adapters/http.sh's
# _http_proxy_args and lib/adapters/rclone.sh's _rclone_proxy_resolve).

# _proxy_classify CLASS_VAR URL_VAR ERROR_VAR PROXY_TYPE PROXY PROXY_DIRECT -
# the single source of the PROXY_TYPE/PROXY/PROXY_DIRECT decision, shared by
# the curl and rclone proxy resolvers. Writes three out-params (namerefs):
#   CLASS_VAR  one of:
#                none        no proxy, and the ambient proxy environment must
#                            be ignored (PROXY_TYPE=none, or PROXY_DIRECT=1)
#                none-needed no proxy setting at all: leave the environment
#                            (and any ambient proxy) untouched
#                env         use URL_VAR as an http(s) proxy through the
#                            child's environment, keeping credentials out of
#                            the argv
#                flag        pass URL_VAR as an explicit proxy flag (curl -x /
#                            rclone --http-proxy), for socks and other schemes
#   URL_VAR    the proxy URL for env/flag, empty otherwise
#   ERROR_VAR  "PROXY_TYPE=<type> requires PROXY to be set" when http/socks5
#              was selected without PROXY, empty otherwise
# An explicit http:// or https:// PROXY classifies as env; every other scheme
# as flag, because socks support through the environment is not portable.
# This helper never dies, so the caller decides how to report ERROR_VAR; its
# two current consumers die with it (lib/adapters/http.sh _http_proxy_args
# and lib/adapters/rclone.sh _rclone_proxy_resolve).
_proxy_classify() {
  local -n _pc_class="$1" _pc_url="$2" _pc_err="$3"
  local type="${4:-system}" proxy="${5:-}" direct="${6:-0}"
  _pc_class="none-needed"
  _pc_url=""
  _pc_err=""
  case "$type" in
    none)
      _pc_class="none"
      ;;
    http | socks5)
      if [[ -z "$proxy" ]]; then
        _pc_err="PROXY_TYPE=${type} requires PROXY to be set"
        return 0
      fi
      _proxy_classify_url "$1" "$2" "$proxy"
      ;;
    *)
      if [[ "$direct" == "1" ]]; then
        _pc_class="none"
      elif [[ -n "$proxy" ]]; then
        _proxy_classify_url "$1" "$2" "$proxy"
      fi
      ;;
  esac
  return 0
}

# _proxy_classify_url CLASS_VAR URL_VAR PROXY - write the class/url pair for a
# non-empty PROXY: an explicit http:// or https:// proxy goes through the
# child's environment ("env"), every other scheme is passed as an explicit
# proxy flag ("flag"), because socks support through the environment is not
# portable. Both out-params are namerefs; the two branches of _proxy_classify
# call this so the per-scheme rule lives once.
_proxy_classify_url() {
  local -n _pcu_class="$1" _pcu_url="$2"
  local proxy="$3"
  case "$proxy" in
    http://* | https://*)
      _pcu_class="env"
      _pcu_url="$proxy"
      ;;
    *)
      _pcu_class="flag"
      _pcu_url="$proxy"
      ;;
  esac
  return 0
}
