#!/bin/bash
# Fetch Claude Code usage from the OAuth usage API and write the shared cache
# (~/.cache/claude-usage-cache.json) that the statusline and the widget read.
#
# Keychain is READ-ONLY here: no token refresh, no write-back. If the access
# token is expired (or the API returns 401), we skip this run and keep the
# stale cache — Claude Code rotates tokens itself during normal use, so a
# later run picks up a fresh token.
#
# Callers: launchd (com.shino3.claude-usage-fetch, every 5 min) and the
# statusline self-heal kick (every render while the cache is stale). The
# backoff file below is the single choke point that keeps those combined
# callers from hammering the API: minimum 60s between attempts, and a 429
# honors retry-after. Without it a rate limit becomes self-sustaining
# (stale cache -> statusline kicks every render -> 429 forever; 2026-07-17).
#
# Skipped runs log a one-line reason to stderr (-> /tmp/claude-usage-fetch.err
# via the plist) so a stalled cache can be diagnosed without instrumenting.
set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_FILE="$CACHE_DIR/claude-usage-cache.json"
BACKOFF_FILE="$CACHE_DIR/claude-usage-fetch.backoff"  # epoch before which we must not call the API

skip() { echo "[$(date '+%F %T')] skip: $1" >&2; exit 0; }

now=$(date +%s)
next_allowed=$(cat "$BACKOFF_FILE" 2>/dev/null || echo 0)
case "$next_allowed" in (*[!0-9]*|'') next_allowed=0;; esac
if [ "$now" -lt "$next_allowed" ]; then
  skip "backoff until $(date -r "$next_allowed" '+%T')"
fi
mkdir -p "$CACHE_DIR"
# Claim the next 60s immediately so concurrent statusline kicks collapse to one attempt
echo $(( now + 60 )) > "$BACKOFF_FILE"

creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) || skip "keychain read failed"
token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
[ -z "$token" ] && skip "no access token in credentials"

# expiresAt is epoch milliseconds; skip if already expired
expires_ms=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // 0 | floor' 2>/dev/null)
now_ms=$(( $(date +%s) * 1000 ))
if [ "${expires_ms:-0}" -gt 0 ] && [ "$expires_ms" -le "$now_ms" ]; then
  skip "token expired"
fi

http_code=$(curl -s --max-time 20 -o "$CACHE_FILE.resp" -D "$CACHE_FILE.hdr" -w '%{http_code}' \
  -H "Authorization: Bearer $token" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "https://api.anthropic.com/api/oauth/usage")
curl_st=$?
if [ "$curl_st" -ne 0 ] || [ "$http_code" != "200" ]; then
  if [ "$http_code" = "429" ]; then
    retry_after=$(awk 'tolower($1)=="retry-after:" {gsub(/\r/,""); print $2}' "$CACHE_FILE.hdr" 2>/dev/null)
    case "$retry_after" in (*[!0-9]*|'') retry_after=300;; esac
    echo $(( $(date +%s) + retry_after + 30 )) > "$BACKOFF_FILE"
  else
    echo $(( $(date +%s) + 300 )) > "$BACKOFF_FILE"
  fi
  rm -f "$CACHE_FILE.resp" "$CACHE_FILE.hdr"
  skip "curl exit=$curl_st http=$http_code"
fi
rm -f "$CACHE_FILE.hdr"

# Guard against writing garbage over a good cache
jq -e '.five_hour // .seven_day // .limits' "$CACHE_FILE.resp" > /dev/null 2>&1 \
  || { rm -f "$CACHE_FILE.resp"; skip "response shape guard failed"; }

# cached_at MUST be an integer epoch: the statusline does bash integer math
# on it and dies on decimals (happened 2026-07-03)
jq --argjson now "$(date +%s)" '. + {cached_at: $now}' "$CACHE_FILE.resp" \
  > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
rm -f "$CACHE_FILE.resp"
