#!/bin/bash
# Fetch Claude Code usage from the OAuth usage API and write the shared caches
# that the statusline and the widget read.
#
# One cache per account. Accounts are identified the same way Claude Code
# identifies them internally: by CLAUDE_CONFIG_DIR. The default config dir
# (~/.claude, CLAUDE_CONFIG_DIR unset) gets the unsuffixed names, every other
# config dir gets "-<sha256(dir)[0:8]>" appended:
#
#   default        Keychain "Claude Code-credentials"           -> claude-usage-cache.json
#   ~/.claude-work Keychain "Claude Code-credentials-6b15588f"  -> claude-usage-cache-6b15588f.json
#
# That suffix is not our invention — it is how Claude Code namespaces its own
# Keychain items, so a config dir and its credentials always line up. Reusing it
# means the statusline can derive its cache path from $CLAUDE_CONFIG_DIR alone,
# with no lookup table to keep in sync.
#
# Keychain is READ-ONLY here: no token refresh, no write-back. If an access
# token is expired (or the API returns 401), we skip that account and keep its
# stale cache — Claude Code rotates tokens itself during normal use, so a
# later run picks up a fresh token.
#
# Callers: launchd (com.shino3.claude-usage-fetch, every 5 min) and the
# statusline self-heal kick (every render while the cache is stale). The
# backoff files below are the single choke point that keeps those combined
# callers from hammering the API: minimum 60s between attempts per account, and
# a 429 honors retry-after. Without it a rate limit becomes self-sustaining
# (stale cache -> statusline kicks every render -> 429 forever; 2026-07-17).
#
# Skipped runs log a one-line reason to stderr (-> /tmp/claude-usage-fetch.err
# via the plist) so a stalled cache can be diagnosed without instrumenting.
set -uo pipefail

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$CACHE_DIR"

log() { echo "[$(date '+%F %T')] $1" >&2; }

# "" for the default config dir, "-<8 hex>" for any other. Mirrors Claude Code.
suffix_for() {
  [ -z "$1" ] && return 0
  printf -- '-%s' "$(printf %s "$1" | shasum -a 256 | cut -c1-8)"
}

# Fetch one account. Never fails the whole run: a broken account is skipped and
# the others still refresh.
fetch_one() {
  local dir="$1" label sfx svc cache backoff
  label="${dir:-default}"
  sfx=$(suffix_for "$dir")
  svc="Claude Code-credentials$sfx"
  cache="$CACHE_DIR/claude-usage-cache$sfx.json"
  backoff="$CACHE_DIR/claude-usage-fetch$sfx.backoff"

  # Who this cache belongs to. Resolved here, once per run, rather than by the
  # statusline: .claude.json is ~110KB and the statusline renders constantly.
  # A team seat is identified by its organisation, everyone else by the address
  # they signed in with.
  local cfg_json acct_email acct_org acct_type acct_label
  cfg_json="${dir:-$HOME}/.claude.json"
  IFS='|' read -r acct_email acct_org acct_type <<<"$(jq -r '
    [ .oauthAccount.emailAddress // "",
      .oauthAccount.organizationName // "",
      .oauthAccount.organizationType // "" ] | join("|")' "$cfg_json" 2>/dev/null)"
  if [ "$acct_type" = "claude_team" ] && [ -n "${acct_org:-}" ]; then
    acct_label="$acct_org"
  else
    acct_label="$acct_email"
  fi
  [ -z "${acct_label:-}" ] && acct_label="$label"

  local now next_allowed
  now=$(date +%s)
  next_allowed=$(cat "$backoff" 2>/dev/null || echo 0)
  case "$next_allowed" in (*[!0-9]*|'') next_allowed=0;; esac
  if [ "$now" -lt "$next_allowed" ]; then
    log "skip [$label]: backoff until $(date -r "$next_allowed" '+%T')"
    return 0
  fi
  # Claim the next 60s immediately so concurrent statusline kicks collapse to one attempt
  echo $(( now + 60 )) > "$backoff"

  local creds token expires_ms now_ms
  creds=$(security find-generic-password -s "$svc" -w 2>/dev/null) || {
    log "skip [$label]: keychain read failed ($svc)"; return 0; }
  token=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$token" ] && { log "skip [$label]: no access token in credentials"; return 0; }

  # expiresAt is epoch milliseconds; skip if already expired
  expires_ms=$(printf '%s' "$creds" | jq -r '.claudeAiOauth.expiresAt // 0 | floor' 2>/dev/null)
  now_ms=$(( $(date +%s) * 1000 ))
  if [ "${expires_ms:-0}" -gt 0 ] && [ "$expires_ms" -le "$now_ms" ]; then
    log "skip [$label]: token expired"
    return 0
  fi

  local http_code curl_st retry_after
  http_code=$(curl -s --max-time 20 -o "$cache.resp" -D "$cache.hdr" -w '%{http_code}' \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage")
  curl_st=$?
  if [ "$curl_st" -ne 0 ] || [ "$http_code" != "200" ]; then
    if [ "$http_code" = "429" ]; then
      retry_after=$(awk 'tolower($1)=="retry-after:" {gsub(/\r/,""); print $2}' "$cache.hdr" 2>/dev/null)
      case "$retry_after" in (*[!0-9]*|'') retry_after=300;; esac
      echo $(( $(date +%s) + retry_after + 30 )) > "$backoff"
    else
      echo $(( $(date +%s) + 300 )) > "$backoff"
    fi
    rm -f "$cache.resp" "$cache.hdr"
    log "skip [$label]: curl exit=$curl_st http=$http_code"
    return 0
  fi
  rm -f "$cache.hdr"

  # Guard against writing garbage over a good cache
  jq -e '.five_hour // .seven_day // .limits' "$cache.resp" > /dev/null 2>&1 \
    || { rm -f "$cache.resp"; log "skip [$label]: response shape guard failed"; return 0; }

  # cached_at MUST be an integer epoch: the statusline does bash integer math
  # on it and dies on decimals (happened 2026-07-03)
  jq --argjson now "$(date +%s)" \
     --arg dir "$dir" --arg email "$acct_email" --arg alabel "$acct_label" \
     '. + {cached_at: $now,
           account: {config_dir: $dir, email: $email, label: $alabel}}' "$cache.resp" \
    > "$cache.tmp" && mv "$cache.tmp" "$cache"
  rm -f "$cache.resp"
}

# The default config dir, plus every ~/.claude-* that actually holds an account.
# Requiring .claude.json keeps stray directories (backups, scratch copies) out.
accounts=("")
for d in "$HOME"/.claude-*; do
  [ -d "$d" ] && [ -f "$d/.claude.json" ] && accounts+=("$d")
done

for d in "${accounts[@]}"; do
  fetch_one "$d"
done
