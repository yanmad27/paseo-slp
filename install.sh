#!/usr/bin/env bash
# Installs — and, run again, updates — the Supervisor → Lead → Peer room:
#   0. removes v1 (the orchestrate@my-orchestrate-skill plugin, its marketplace, watchdogs)
#   1. the /supervisor skill            → ~/.claude/skills/supervisor
#   2. a Claude runtime per seat — Supervisor, Lead, Peer (its role as an output style,
#      sharing your settings, skills, and one token) and the Codex launcher
#                                        → ~/.config/slp-room
#   3. the room's profiles and providers → ~/.paseo/config.json (backup kept alongside)
#   4. paseo daemon reload
#   5. slp-gc, the Paseo GC / memory diagnostic → ~/.config/slp-room/bin/slp-gc, run every 60 s
#      by a launchd agent (a fresh install reclaims the safe tier; kill-memory is opt-in), config ~/.config/slp-room/slp-gc.conf.
#      The default mode and --paseo-only include this step unless --no-gc is given (--skill-only
#      does not); --gc-only is this step alone.
# From a checkout: ./install.sh   Piped: curl -fsSL <raw>/install.sh | bash
# (Commands that could read stdin get </dev/null, so they never eat a piped script.)
# Options: --skill-only, --paseo-only, --no-reload, --token (ask for a new Claude token),
# --endpoint (ask for a custom Anthropic-compatible base URL + key instead of a token).
# Non-interactive endpoint: SLP_CLAUDE_BASE_URL, SLP_CLAUDE_AUTH_TOKEN, and SLP_CLAUDE_AUTH_HEADER
# (SLP_CLAUDE_API_KEY is still accepted as an older alias for SLP_CLAUDE_AUTH_TOKEN) (bearer, the default → ANTHROPIC_AUTH_TOKEN; or x-api-key → ANTHROPIC_API_KEY).
# SLP_REF picks a branch or tag.
# slp-gc options: --gc-only (just slp-gc: touches no seats, Paseo config, or daemon), --no-gc,
# --no-gc-launchd (skip the launchd agent), --gc-apply / --gc-kill-stale / --gc-kill-memory (--gc-kill
# is both) / --gc-report-only (edit the opt-in keys of slp-gc.conf; the kill flags need --gc-apply).
# SLP_LAUNCHCTL (an absolute path to an executable) overrides launchctl, for tests.
# Jev switch: --jev / --no-jev set SLP_JEV=1|0 in ~/.config/slp-room/room.conf (default 0, off) and the
# choice persists. Off renders the prompts, room copies, the installed skill, and the seats' CLAUDE.md
# without Jev, and disables the ask-jev plugin and its hooks in the Claude seats only. Re-run install.sh
# to apply a change; the flag alone changes nothing until then.
set -euo pipefail

REPO="yanmad27/paseo-slp"
TARBALL_URL="${SLP_TARBALL_URL:-https://codeload.github.com/$REPO/tar.gz/${SLP_REF:-main}}"
ROOM_HOME="${SLP_ROOM_HOME:-$HOME/.config/slp-room}"

DO_SKILL=1
DO_PASEO=1
RELOAD=1
ASK_TOKEN=0
ASK_ENDPOINT=0
JEV_FLAG=""
GC_ONLY=0; NO_GC=0; GC_LAUNCHD=1; GC_APPLY=0; GC_KILL_STALE=0; GC_KILL_MEM=0; GC_REPORT_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --skill-only) DO_PASEO=0 ;;
    --paseo-only) DO_SKILL=0 ;;
    --gc-only) GC_ONLY=1 ;;
    --no-gc) NO_GC=1 ;;
    --no-gc-launchd) GC_LAUNCHD=0 ;;
    --gc-apply) GC_APPLY=1 ;;
    --gc-kill) GC_KILL_STALE=1; GC_KILL_MEM=1 ;;
    --gc-kill-stale) GC_KILL_STALE=1 ;;
    --gc-kill-memory) GC_KILL_MEM=1 ;;
    --gc-report-only) GC_REPORT_ONLY=1 ;;
    --jev|--no-jev)
      new_flag=1; [ "$arg" = "--jev" ] || new_flag=0
      if [ -n "$JEV_FLAG" ] && [ "$JEV_FLAG" != "$new_flag" ]; then
        echo "--jev and --no-jev are mutually exclusive; pass at most one." >&2; exit 1
      fi
      JEV_FLAG="$new_flag" ;;
    --no-reload) RELOAD=0 ;;
    --token) ASK_TOKEN=1 ;;
    --endpoint) ASK_ENDPOINT=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
if [ "$DO_SKILL" = 0 ] && [ "$DO_PASEO" = 0 ]; then
  echo "--skill-only and --paseo-only are mutually exclusive; pass at most one." >&2
  exit 1
fi
# slp-gc: installed with the Paseo half by default (not with --skill-only); --gc-only is just slp-gc.
DO_GC=$DO_PASEO
if [ "$GC_ONLY" = 1 ]; then
  if [ "$DO_SKILL" = 0 ] || [ "$DO_PASEO" = 0 ] || [ "$NO_GC" = 1 ]; then
    echo "--gc-only cannot be combined with --skill-only, --paseo-only or --no-gc." >&2; exit 1
  fi
  DO_SKILL=0; DO_PASEO=0; DO_GC=1
fi
[ "$NO_GC" = 0 ] || DO_GC=0
if [ "$((GC_KILL_STALE + GC_KILL_MEM))" -gt 0 ] && [ "$GC_APPLY" = 0 ]; then
  echo "--gc-kill, --gc-kill-stale and --gc-kill-memory need --gc-apply: the kill flags only act together with apply." >&2; exit 1
fi
if [ "$GC_REPORT_ONLY" = 1 ] && [ "$((GC_APPLY + GC_KILL_STALE + GC_KILL_MEM))" -gt 0 ]; then
  echo "--gc-report-only cannot be combined with --gc-apply or the --gc-kill flags." >&2; exit 1
fi
if [ "$DO_GC" = 0 ] && [ "$((GC_APPLY + GC_KILL_STALE + GC_KILL_MEM + GC_REPORT_ONLY))" -gt 0 ]; then
  echo "--gc-apply, the --gc-kill flags and --gc-report-only need slp-gc to be installed (drop --no-gc / --skill-only)." >&2; exit 1
fi
# --- slp-gc preflight: every refusal happens here, before any install step ---------------------
GC_LABEL="com.paseo-slp.slp-gc"
GC_BIN="$ROOM_HOME/bin/slp-gc"
GC_CONF="$ROOM_HOME/slp-gc.conf"
GC_STATE="${SLP_GC_STATE_DIR:-$HOME/Library/Logs/slp-gc}"
GC_LOG="$GC_STATE/launchd.log"
GC_PLIST="$HOME/Library/LaunchAgents/$GC_LABEL.plist"
# The plist's PATH: system dirs first. jq (and paseo) found elsewhere are appended after them.
GC_BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
if [ -n "${SLP_LAUNCHCTL:-}" ] && [ -n "${SLP_GC_PLIST_BASE_PATH:-}" ]; then GC_BASE_PATH="$SLP_GC_PLIST_BASE_PATH"; fi  # tests only
GC_PATH="$GC_BASE_PATH"; GC_PATH_ADDED=""
gc_links() { stat -c %h -- "$1" 2>/dev/null || stat -f %l "$1" 2>/dev/null || echo 0; }
gc_refuse() { echo "$1" >&2; exit 1; }
if [ "$DO_GC" = 1 ]; then
  # The config is read by tick and edited below: only a regular file, never a link or special file.
  if [ -L "$GC_CONF" ]; then
    gc_refuse "$GC_CONF is a symlink; refusing to read or edit it. Replace it with a regular file and re-run."
  elif [ -e "$GC_CONF" ] && [ ! -f "$GC_CONF" ]; then
    gc_refuse "$GC_CONF exists but is not a regular file (FIFO, directory or device); refusing to read or edit it. Remove it and re-run."
  fi
  # The state dir holds process and memory reports and launchd's log: an owned, real directory.
  if [ -L "$GC_STATE" ]; then
    gc_refuse "slp-gc state dir $GC_STATE is a symlink; refusing to write through it. Remove the link and re-run."
  elif [ -e "$GC_STATE" ] && [ ! -d "$GC_STATE" ]; then
    gc_refuse "slp-gc state dir $GC_STATE exists but is not a directory; remove it and re-run."
  elif [ -d "$GC_STATE" ] && [ ! -O "$GC_STATE" ]; then
    gc_refuse "slp-gc state dir $GC_STATE is not owned by you; refusing to install into it."
  fi
  if [ -L "$GC_LOG" ]; then
    gc_refuse "$GC_LOG is a symlink; refusing to write through it. Remove the link and re-run."
  elif [ -e "$GC_LOG" ] && [ ! -f "$GC_LOG" ]; then
    gc_refuse "$GC_LOG exists but is not a regular file; remove it and re-run."
  elif [ -d "$GC_LOG.1" ]; then
    gc_refuse "$GC_LOG.1 is a directory; remove it and re-run."
  fi
  # tick needs jq (and calls paseo when applying) under launchd's minimal PATH: check them against
  # exactly the plist PATH, and add the canonical dir of one found elsewhere after the system dirs.
  gc_need_tool() {  # gc_need_tool <name> <required 1|0>
    local name="$1" required="$2" found dir
    if [ -n "$(PATH="$GC_BASE_PATH" command -v "$name" 2>/dev/null || true)" ]; then return 0; fi
    found="$(command -v "$name" 2>/dev/null || true)"
    case "$found" in /*) ;; *) found="" ;; esac
    if [ -z "$found" ]; then
      [ "$required" = 0 ] || gc_refuse "$name is required by slp-gc but was not found on PATH or on the launchd PATH ($GC_BASE_PATH). Install it (brew install $name) and re-run."
      return 0
    fi
    dir="$(cd -P "$(dirname "$found")" 2>/dev/null && pwd -P)" || dir=""
    case "$dir" in
      ""|*[:[:space:]\<\>\&]*) [ "$required" = 0 ] || gc_refuse "$name is at $found, a directory that cannot go on the launchd PATH; install it under /usr/local/bin or /opt/homebrew/bin." ;;
      *) case ":$GC_PATH:" in *":$dir:"*) ;; *) GC_PATH="$GC_PATH:$dir"; GC_PATH_ADDED="${GC_PATH_ADDED:+$GC_PATH_ADDED }$dir ($name)" ;; esac ;;
    esac
  }
  gc_need_tool jq 1
  gc_need_tool paseo 0
fi

WORK="$(mktemp -d)"
AUTH_TMP=""
trap 'rm -rf "$WORK"; [ -z "$AUTH_TMP" ] || rm -f "$AUTH_TMP"' EXIT

# Source: this checkout, or the repository tarball when piped.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ] \
  && [ -d "$(dirname "${BASH_SOURCE[0]}")/skills/supervisor" ]; then
  SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  command -v curl >/dev/null 2>&1 || { echo "curl is required to download $REPO." >&2; exit 1; }
  curl -fsSL "$TARBALL_URL" | tar -xz -C "$WORK" || { echo "Failed to download $TARBALL_URL" >&2; exit 1; }
  SRC="$(find "$WORK" -mindepth 1 -maxdepth 1 -type d | head -1)"
fi
VERSION="$(tr -d '[:space:]' < "$SRC/version.txt")"

# --- room.conf: the Jev switch, decided before anything is installed -------------------------------
# KEY=VALUE, parsed (never sourced); the last SLP_JEV wins. Only a regular file, never a link or special file.
ROOM_CONF="$ROOM_HOME/room.conf"
JEV=0
if [ "$GC_ONLY" = 0 ]; then
  if [ -L "$ROOM_CONF" ]; then
    echo "$ROOM_CONF is a symlink; refusing to read or edit it. Replace it with a regular file and re-run." >&2; exit 1
  elif [ -e "$ROOM_CONF" ] && [ ! -f "$ROOM_CONF" ]; then
    echo "$ROOM_CONF exists but is not a regular file; refusing to read or edit it. Remove it and re-run." >&2; exit 1
  fi
  if [ -f "$ROOM_CONF" ] && grep -q '^SLP_JEV=' "$ROOM_CONF"; then
    JEV="$(sed -n 's/^SLP_JEV=//p' "$ROOM_CONF" | tail -n 1)"
    case "$JEV" in
      0|1) ;;
      *) echo "$ROOM_CONF: SLP_JEV must be 0 or 1 (got '$JEV'). Fix it, or pass --jev / --no-jev." >&2; exit 1 ;;
    esac
  fi
  if [ -n "$JEV_FLAG" ] || [ ! -e "$ROOM_CONF" ]; then
    [ -z "$JEV_FLAG" ] || JEV="$JEV_FLAG"
    mkdir -p "$ROOM_HOME"
    CONF_TMP="$(mktemp "$ROOM_HOME/.room.conf.XXXXXX")"
    {
      if [ -f "$ROOM_CONF" ]; then
        grep -v '^SLP_JEV=' "$ROOM_CONF" || true
      else
        printf '%s\n' '# paseo-slp room configuration (KEY=VALUE, parsed not sourced; the last value wins).' \
          '# SLP_JEV=1 keeps the Jev (ask-jev) parts of the prompts and seats; 0 removes them.' \
          '# Change it with install.sh --jev / --no-jev, then re-run install.sh to apply.'
      fi
      printf 'SLP_JEV=%s\n' "$JEV"
    } > "$CONF_TMP"
    chmod 644 "$CONF_TMP"
    mv -f "$CONF_TMP" "$ROOM_CONF"
  fi
fi
if [ "$JEV" = 1 ]; then JEV_MODE=on; else JEV_MODE=off; fi
jevf() { awk -v keep="$1" '/^<!-- jev:(on|off) -->$/{cur=($0~/jev:on/)?"on":"off";next} /^<!-- jev:end -->$/{cur="";next} cur==""||cur==keep{print}' "$2"; }
# Rewrites a file in place (keeping its mode) with only the current mode's Jev variant.
jevf_inplace() { local tmp="$WORK/jevf.$$"; jevf "$JEV_MODE" "$1" > "$tmp" && cat "$tmp" > "$1"; rm -f "$tmp"; }

# Seat CLAUDE.md without Jev: ~/.claude/CLAUDE.md filtered by block. A block with no /jev/i is kept byte for byte;
# a matching prose paragraph loses its matching sentences, list item/table row/heading section/fence is dropped.
jev_filter_claude_md() {
  LC_ALL=C awk '
    function m(s) { return tolower(s) ~ /jev/ }
    function isfence(s) { return s ~ /^[ \t]*(```|~~~)/ }
    function isblank(s) { return s ~ /^[ \t]*$/ }
    function hlevel(s,   r) {
      if (s !~ /^#+/) return 0
      match(s, /^#+/); r = RLENGTH
      if (r > 6) return 0
      if (length(s) == r || substr(s, r + 1, 1) ~ /[ \t]/) return r
      return 0
    }
    function ismarker(s) { return s ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]/ }
    function indent(s,   t, n) { t = s; n = 0; while (t ~ /^[ \t]/) { n += (substr(t, 1, 1) == "\t") ? 4 : 1; t = substr(t, 2) } return n }
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function emit(s) { out[++o] = s; dropped = 0 }
    function abbrev(w) { w = tolower(w); sub(/^[("\[]+/, "", w); return (w == "e.g" || w == "i.e" || w == "etc" || w == "vs" || w == "cf") }
    function prose(k,   p, q, s, c, ch, st, ws, kept, sent, quote, res, any) {
      quote = 1
      for (p = 1; p <= k; p++) if (b[p] !~ /^[ \t]*>/) quote = 0
      s = ""
      for (p = 1; p <= k; p++) {
        t = trim(b[p]); if (quote) t = trim(substr(t, 2))
        s = (p == 1) ? t : s " " t
      }
      st = 1; ws = 0; res = ""; any = 0
      for (c = 1; c <= length(s); c++) {
        ch = substr(s, c, 1)
        if (ch == " ") ws = c
        if (ch ~ /[.!?]/ && (c == length(s) || substr(s, c + 1, 1) == " ")) {
          if (ch == "." && abbrev(substr(s, ws + 1, c - ws - 1))) continue
          sent = substr(s, st, c - st + 1)
          if (!m(sent)) { res = any ? res " " sent : sent; any = 1 }
          st = c + 1; while (substr(s, st, 1) == " ") st++
          c = st - 1
        }
      }
      if (st <= length(s)) { sent = substr(s, st); if (!m(sent)) { res = any ? res " " sent : sent; any = 1 } }
      if (any) emit(quote ? "> " res : res)
    }
    function block(k,   p, q, r, any, own, ind) {
      any = 0
      for (p = 1; p <= k; p++) if (m(b[p])) any = 1
      if (!any) { for (p = 1; p <= k; p++) emit(b[p]); return }
      dropped = 1
      if (ismarker(b[1])) {
        p = 1
        while (p <= k) {
          if (!ismarker(b[p])) { emit(b[p]); p++; continue }
          ind = indent(b[p]); own = b[p]; q = p + 1
          while (q <= k && !ismarker(b[q])) { own = own "\n" b[q]; q++ }
          if (m(own)) {
            r = q
            while (r <= k && !(ismarker(b[r]) && indent(b[r]) <= ind)) r++
            p = r
          } else { for (r = p; r < q; r++) emit(b[r]); p = q }
        }
      } else if (b[1] ~ /^[ \t]*\|/) {
        for (p = 1; p <= k; p++) if (!m(b[p])) emit(b[p])
      } else prose(k)
    }
    { L[++n] = $0 }
    END {
      i = 1; skiph = 0; o = 0; dropped = 1
      while (i <= n) {
        line = L[i]
        if (isfence(line)) {
          mk = substr(trim(line), 1, 3); j = i + 1
          while (j <= n && !(isfence(L[j]) && substr(trim(L[j]), 1, 3) == mk)) j++
          if (j > n) j = n
          hit = 0; for (p = i; p <= j; p++) if (m(L[p])) hit = 1
          if (skiph || hit) dropped = 1
          else for (p = i; p <= j; p++) emit(L[p])
          i = j + 1; continue
        }
        lv = hlevel(line)
        if (lv) {
          if (skiph && lv <= skiph) skiph = 0
          if (skiph) dropped = 1
          else if (m(line)) { skiph = lv; dropped = 1 }
          else emit(line)
          i++; continue
        }
        if (skiph) { dropped = 1; i++; continue }
        if (isblank(line)) {
          if (!(dropped && (o == 0 || isblank(out[o])))) { out[++o] = line }
          i++; continue
        }
        k = 0; j = i
        while (j <= n && !isblank(L[j]) && !isfence(L[j]) && !hlevel(L[j])) { b[++k] = L[j]; j++ }
        block(k)
        i = j
      }
      if (dropped) while (o > 0 && isblank(out[o])) o--
      for (p = 1; p <= o; p++) print out[p]
    }' "$1"
}

# --- auth: decided, validated and saved before anything else changes ---------------------
# Every Claude seat shares one auth, in one of two modes, all kept in ONE private file,
# $ROOM_HOME/auth (mode 600, written atomically, read as data and never sourced), one
# `name=value` line per field (split on the first `=`; the key's value keeps interior spaces):
#   mode      token | endpoint
#   token     one `claude setup-token` token (token mode)
#   url, key, header   any Anthropic-compatible proxy or gateway: base URL, key, bearer|x-api-key
# Migration: older installs kept these in five mode-600 files (auth-mode, oauth-token,
# anthropic-base-url, anthropic-api-key, anthropic-auth-header). On any run that gets here, each
# old file is read with its old rules (all whitespace stripped, except the key: first line only),
# and its value is carried into $ROOM_HOME/auth only if auth has no such field yet; then the old
# file is deleted, but only when its value is now in auth (or it was empty). So a partial old
# layout migrates what exists, as is. If auth already exists it wins: an old file whose value
# differs is left untouched with a warning, never deleted, so no credential is lost silently.
# An old key file with more than its first line is also kept; so is an old file that cannot be
# read (permissions, other owner), a symbolic link, or anything but a regular file: each is
# reported by path with a warning, never deleted, never migrated as if empty. A second run
# changes nothing. Migration runs after the arguments and SLP_CLAUDE_* values below are
# validated, so an invalid-input run changes nothing; later exits (no complete endpoint, missing
# jq) may come after a lossless migration. An old auth-mode file is carried over as is, so
# mode=token can migrate without a token, as the old layout allowed. auth is rewritten whole from
# the fields above: any other line in it is not kept, and a symlinked auth is replaced by a
# regular file.
# Rules: SLP_CLAUDE_* and --token / --endpoint pick the mode, else the saved one (default
# token). --token with no token, or --endpoint with no complete endpoint, keeps what is
# saved. mode=token is saved in auth only with a saved token; SLP_CLAUDE_OAUTH_TOKEN is used
# for one run and never persisted. Asking for both kinds at once is an error. Prompts read
# /dev/tty, which still works when piped. The key is never taken from an argument.
OAUTH_TOKEN=""; BASE_URL=""; API_KEY=""; ENDPOINT_KEY_VAR=""
if [ "$DO_PASEO" = 1 ]; then
  AUTH_FILE="$ROOM_HOME/auth"
  # The key is opaque: its value is kept whole, interior whitespace intact. Surrounding
  # whitespace (a trailing newline included) is trimmed; only an empty key or a line break
  # inside it is rejected. The other fields are stored without any whitespace.
  A_MODE=""; A_TOKEN=""; A_URL=""; A_KEY=""; A_HDR=""
  auth_load() {
    local line k v
    A_MODE=""; A_TOKEN=""; A_URL=""; A_KEY=""; A_HDR=""
    [ -f "$AUTH_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in *=*) ;; *) continue ;; esac
      k="${line%%=*}"; v="${line#*=}"
      case "$k" in
        mode) A_MODE="${v//[[:space:]]/}" ;;
        token) A_TOKEN="${v//[[:space:]]/}" ;;
        url) A_URL="${v//[[:space:]]/}" ;;
        key) A_KEY="$v" ;;
        header) A_HDR="${v//[[:space:]]/}" ;;
      esac
    done < "$AUTH_FILE"
  }
  # Write the A_* fields to $AUTH_FILE: private temp file, then rename; untouched when unchanged.
  auth_write() {
    local tmp content=""
    [ ! -d "$AUTH_FILE" ] || { echo "$AUTH_FILE is a directory; move it away and re-run." >&2; exit 1; }
    [ -z "$A_MODE" ] || content+="mode=$A_MODE"$'\n'
    [ -z "$A_TOKEN" ] || content+="token=$A_TOKEN"$'\n'
    [ -z "$A_URL" ] || content+="url=$A_URL"$'\n'
    [ -z "$A_KEY" ] || content+="key=$A_KEY"$'\n'
    [ -z "$A_HDR" ] || content+="header=$A_HDR"$'\n'
    mkdir -p "$ROOM_HOME"
    tmp="$(umask 077 && mktemp "$ROOM_HOME/.auth.XXXXXX")"
    AUTH_TMP="$tmp"  # removed by the EXIT trap if anything below fails or is interrupted
    # One checked write of the whole content: a failed write never replaces a good auth.
    { printf '%s' "$content" > "$tmp" && chmod 600 "$tmp" \
        && if [ -f "$AUTH_FILE" ] && cmp -s "$tmp" "$AUTH_FILE"; then rm -f "$tmp"; chmod 600 "$AUTH_FILE"
           else mv -f "$tmp" "$AUTH_FILE"; fi
    } || { rm -f "$tmp"; AUTH_TMP=""; echo "Could not write $AUTH_FILE; it is unchanged." >&2; exit 1; }
    AUTH_TMP=""
  }
  # Fold the five old files into $AUTH_FILE (rules in the comment above).
  auth_migrate() {
    local f new warn_path n_old=0
    for f in auth-mode oauth-token anthropic-base-url anthropic-api-key anthropic-auth-header; do
      [ -e "$ROOM_HOME/$f" ] || [ -L "$ROOM_HOME/$f" ] && n_old=$((n_old + 1))
    done
    [ "$n_old" -gt 0 ] || return 0
    auth_load
    local had_auth=0; [ -f "$AUTH_FILE" ] && had_auth=1
    # old_read <file>: read it once with the old rules. Fails (touching nothing) unless it is a
    # readable regular file (or a link to one). Sets OLD_V (the value) and OLD_ALL (all its
    # non-whitespace text), so the empty test and the equality test use the same read.
    old_read() {
      local p="$ROOM_HOME/$1"
      OLD_V=""; OLD_ALL=""
      [ -f "$p" ] && [ -r "$p" ] && { : < "$p"; } 2>/dev/null || return 1
      OLD_ALL="$(tr -d '[:space:]' < "$p" 2>/dev/null)" || return 1
      case "$1" in
        anthropic-api-key) { IFS= read -r OLD_V || true; } < "$p" 2>/dev/null ;;
        *) OLD_V="$OLD_ALL" ;;
      esac
    }
    old_field() { case "$1" in
      auth-mode) new="$A_MODE" ;; oauth-token) new="$A_TOKEN" ;; anthropic-base-url) new="$A_URL" ;;
      anthropic-api-key) new="$A_KEY" ;; *) new="$A_HDR" ;; esac; }
    for f in auth-mode oauth-token anthropic-base-url anthropic-api-key anthropic-auth-header; do
      old_read "$f" || continue
      old_field "$f"
      [ -z "$new" ] || continue
      case "$f" in
        auth-mode) A_MODE="$OLD_V" ;; oauth-token) A_TOKEN="$OLD_V" ;; anthropic-base-url) A_URL="$OLD_V" ;;
        anthropic-api-key) A_KEY="$OLD_V" ;; *) A_HDR="$OLD_V" ;;
      esac
    done
    if [ -n "$A_MODE$A_TOKEN$A_URL$A_KEY$A_HDR" ]; then
      auth_write
      auth_load  # what is on disk now is what is compared below
    fi
    for f in auth-mode oauth-token anthropic-base-url anthropic-api-key anthropic-auth-header; do
      warn_path="$ROOM_HOME/$f"
      [ -e "$warn_path" ] || [ -L "$warn_path" ] || continue
      if ! old_read "$f"; then
        echo "WARNING: $warn_path is not a readable regular file; left in place and not migrated. Fix it or move its value into $AUTH_FILE." >&2
        continue
      fi
      old_field "$f"
      if [ -L "$warn_path" ]; then
        if [ "$OLD_V" = "$new" ]; then echo "WARNING: $warn_path is a symbolic link; its value is already in $AUTH_FILE, link left in place. Remove it yourself." >&2
        else echo "WARNING: $warn_path is a symbolic link whose value is not in $AUTH_FILE; left in place, not deleted." >&2; fi
      elif [ -z "$OLD_ALL" ] || { [ "$OLD_V" = "$new" ] && [ "$OLD_ALL" = "$(printf '%s' "$OLD_V" | tr -d '[:space:]')" ]; }; then
        rm -f "$warn_path"
      else
        echo "WARNING: $warn_path differs from or goes beyond $AUTH_FILE; left in place, $AUTH_FILE wins. Delete it once you no longer need it." >&2
      fi
    done
    [ "$had_auth" = 1 ] || [ ! -f "$AUTH_FILE" ] || echo "Moved the saved auth into $AUTH_FILE"
  }
  trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
  norm_url() {
    local u
    u="$(trim "$1")"
    while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
    case "$u" in *[[:space:]]*) return 1 ;; http://?*|https://?*) printf '%s' "$u" ;; *) return 1 ;; esac
  }
  redact_url() { sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*://)[^/]*@#\1***@#'; }
  key_ok() { case "$1" in ""|*$'\n'*|*$'\r'*) return 1 ;; esac; }

  ENV_TOKEN="${SLP_CLAUDE_OAUTH_TOKEN:-}"
  EP_URL="${SLP_CLAUDE_BASE_URL:-}"
  # The key: SLP_CLAUDE_AUTH_TOKEN, else the older alias SLP_CLAUDE_API_KEY (both set must agree).
  EP_KEY_VAR=SLP_CLAUDE_AUTH_TOKEN; EP_KEY_RAW="${SLP_CLAUDE_AUTH_TOKEN:-}"
  if [ -n "${SLP_CLAUDE_AUTH_TOKEN:-}" ] && [ -n "${SLP_CLAUDE_API_KEY:-}" ] \
    && [ "$(trim "$SLP_CLAUDE_AUTH_TOKEN")" != "$(trim "$SLP_CLAUDE_API_KEY")" ]; then
    echo "SLP_CLAUDE_AUTH_TOKEN and SLP_CLAUDE_API_KEY are both set and differ; set only SLP_CLAUDE_AUTH_TOKEN." >&2; exit 1
  fi
  if [ -z "$EP_KEY_RAW" ]; then EP_KEY_VAR=SLP_CLAUDE_API_KEY; EP_KEY_RAW="${SLP_CLAUDE_API_KEY:-}"; fi
  EP_KEY="$(trim "$EP_KEY_RAW")"
  EP_HDR="${SLP_CLAUDE_AUTH_HEADER:-}"
  if [ -n "$EP_URL" ]; then
    EP_URL="$(norm_url "$EP_URL")" || { echo "SLP_CLAUDE_BASE_URL must be an http:// or https:// URL without whitespace." >&2; exit 1; }
  fi
  if [ -n "$EP_KEY_RAW" ] && ! key_ok "$EP_KEY"; then
    echo "$EP_KEY_VAR must not be blank or contain a line break." >&2; exit 1
  fi
  case "$EP_HDR" in ""|bearer|x-api-key) ;; *) echo "SLP_CLAUDE_AUTH_HEADER must be bearer or x-api-key." >&2; exit 1 ;; esac
  TOKEN_REQ=0; EP_REQ=0
  { [ -n "$ENV_TOKEN" ] || [ "$ASK_TOKEN" = 1 ]; } && TOKEN_REQ=1
  { [ -n "$EP_URL$EP_KEY$EP_HDR" ] || [ "$ASK_ENDPOINT" = 1 ]; } && EP_REQ=1
  if [ "$TOKEN_REQ" = 1 ] && [ "$EP_REQ" = 1 ]; then
    echo "Choose one auth mode: a setup-token (--token, SLP_CLAUDE_OAUTH_TOKEN) or a custom endpoint" >&2
    echo "  (--endpoint, SLP_CLAUDE_BASE_URL / SLP_CLAUDE_AUTH_TOKEN / SLP_CLAUDE_AUTH_HEADER), not both." >&2
    exit 1
  fi
  auth_migrate  # only now: everything above can still exit 1 without changing anything
  auth_load
  HAS_TTY=0
  if [ -t 2 ] && { : < /dev/tty; } 2>/dev/null; then HAS_TTY=1; fi
  TOKEN_FLAG="$ASK_TOKEN"
  if [ "$ASK_TOKEN" = 1 ] && [ "$HAS_TTY" = 0 ]; then
    echo "WARNING: --token needs a terminal to ask on; keeping the saved token." >&2
    ASK_TOKEN=0
  fi
  if [ "$ASK_ENDPOINT" = 1 ] && [ "$HAS_TTY" = 0 ]; then
    echo "WARNING: --endpoint needs a terminal to ask on; using the saved endpoint." >&2
    ASK_ENDPOINT=0
  fi
  SAVED_MODE="$A_MODE"
  if [ "$EP_REQ" = 1 ]; then MODE=endpoint
  elif [ "$TOKEN_REQ" = 1 ]; then MODE=token
  elif [ "$SAVED_MODE" = endpoint ]; then MODE=endpoint
  else MODE=token
  fi

  CHOSE_TOKEN=0
  if [ "$MODE" = token ]; then
    OAUTH_TOKEN="$ENV_TOKEN"
    TOKEN_FROM_FILE=0; PASTED_OK=0
    if [ -z "$OAUTH_TOKEN" ] && [ "$ASK_TOKEN" = 0 ]; then
      OAUTH_TOKEN="$A_TOKEN"
      [ -z "$OAUTH_TOKEN" ] || TOKEN_FROM_FILE=1
    fi
    if [ -z "$OAUTH_TOKEN" ] && [ "$TOKEN_REQ" = 0 ] && [ "$HAS_TTY" = 1 ]; then
      {
        echo
        echo "How should the room's Claude seats sign in?"
        echo "  1) a 'claude setup-token' token (default)"
        echo "  2) a custom Anthropic-compatible endpoint (base URL + key)"
        printf 'Choose 1 or 2: '
      } > /dev/tty
      IFS= read -r CHOICE < /dev/tty || CHOICE=""
      case "$(printf '%s' "$CHOICE" | tr -d '[:space:]')" in
        2) MODE=endpoint; ASK_ENDPOINT=1 ;;
        *) CHOSE_TOKEN=1 ;;
      esac
    fi
  fi
  if [ "$MODE" = token ]; then
    if [ -z "$OAUTH_TOKEN" ] && [ "$HAS_TTY" = 1 ]; then
      {
        echo
        echo "The room's Claude seats share one token. In another terminal run 'claude setup-token',"
        echo "then paste the sk-ant-oat01-… line it prints (input hidden; Enter skips)."
        printf 'Token: '
      } > /dev/tty
      IFS= read -rs PASTED < /dev/tty || PASTED=""
      echo > /dev/tty
      PASTED="$(printf '%s' "$PASTED" | tr -d '[:space:]')"
      case "$PASTED" in
        "") ;;
        sk-ant-oat*)
          A_TOKEN="$PASTED"; auth_write
          OAUTH_TOKEN="$PASTED"; PASTED_OK=1
          echo "Saved the token to $AUTH_FILE"
          ;;
        *) echo "WARNING: that is not a 'claude setup-token' token (sk-ant-oat…); not saved." >&2 ;;
      esac
      PASTED=""
      # Skipping the prompt (or a bad paste) keeps the token that was already saved.
      if [ -z "$OAUTH_TOKEN" ]; then
        OAUTH_TOKEN="$A_TOKEN"
        [ -z "$OAUTH_TOKEN" ] || { TOKEN_FROM_FILE=1; echo "Kept the saved token in $AUTH_FILE"; }
      fi
    fi
    if [ -z "$OAUTH_TOKEN" ] && { [ "$TOKEN_FLAG" = 1 ] || [ "$CHOSE_TOKEN" = 1 ]; } \
      && [ "$SAVED_MODE" = endpoint ] && [ -n "$A_URL" ] && [ -n "$A_KEY" ]; then
      MODE=endpoint  # no token came out of it: keep the saved endpoint rather than drop auth
      echo "Kept the saved endpoint $(printf '%s' "$A_URL" | redact_url) (no token was given)."
    fi
  fi
  if [ "$MODE" = token ]; then
    if [ -z "$OAUTH_TOKEN" ]; then
      echo "WARNING: no Claude token for the room runtimes. Run 'claude setup-token', then re-run" >&2
      echo "  install.sh with --token and paste it — or log in once per runtime:" >&2
      echo "  CLAUDE_CONFIG_DIR=$ROOM_HOME/claude-<supervisor|lead|peer> claude" >&2
    elif [ -z "$ENV_TOKEN" ] && { [ "$PASTED_OK" = 1 ] || { [ "$TOKEN_FLAG" = 1 ] && [ "$TOKEN_FROM_FILE" = 1 ]; }; }; then
      A_MODE=token; auth_write
    fi
  fi

  # Endpoint mode. Explicit values (SLP_CLAUDE_*) beat prompts, which beat what is saved.
  # The header form picks the variable: bearer → ANTHROPIC_AUTH_TOKEN, x-api-key → ANTHROPIC_API_KEY.
  # Its order: SLP_CLAUDE_AUTH_HEADER (skips the prompt); else the prompt's choice, when it runs;
  # else bearer if SLP_CLAUDE_BASE_URL is set; else the saved one; else bearer.
  if [ "$MODE" = endpoint ]; then
    CUR_URL="$EP_URL"; CUR_KEY="$EP_KEY"
    [ -n "$CUR_URL" ] || CUR_URL="$A_URL"
    [ -n "$CUR_KEY" ] || CUR_KEY="$A_KEY"
    if [ -n "$EP_HDR" ]; then CUR_HDR="$EP_HDR"       # explicit header
    elif [ -n "$EP_URL" ]; then CUR_HDR=bearer         # a new endpoint starts at the default
    else CUR_HDR="$A_HDR"; fi            # a rotated key keeps the saved header
    ASK_URL=0; ASK_KEY=0
    if [ "$HAS_TTY" = 1 ]; then
      if [ -z "$EP_URL" ] && { [ "$ASK_ENDPOINT" = 1 ] || [ -z "$CUR_URL" ]; }; then ASK_URL=1; fi
      if [ -z "$EP_KEY" ] && { [ "$ASK_ENDPOINT" = 1 ] || [ -z "$CUR_KEY" ]; }; then ASK_KEY=1; fi
    fi
    if [ "$ASK_URL" = 1 ] || [ "$ASK_KEY" = 1 ]; then
      {
        echo
        echo "Custom endpoint: any Anthropic-compatible proxy or gateway (e.g. 9router, LiteLLM)."
        echo "Enter keeps what is saved (or skips)."
      } > /dev/tty
    fi
    if [ "$ASK_URL" = 1 ]; then
      printf 'Base URL%s: ' "${CUR_URL:+ [$(printf '%s' "$CUR_URL" | redact_url)]}" > /dev/tty
      IFS= read -r PASTED < /dev/tty || PASTED=""
      if [ -n "$(trim "$PASTED")" ]; then
        if PASTED="$(norm_url "$PASTED")"; then CUR_URL="$PASTED"
        else echo "WARNING: the base URL must be an http:// or https:// URL without whitespace; not saved." >&2; fi
      fi
    fi
    if [ "$ASK_KEY" = 1 ]; then
      printf 'Key (input hidden): ' > /dev/tty
      IFS= read -rs PASTED < /dev/tty || PASTED=""
      echo > /dev/tty
      PASTED="$(trim "$PASTED")"
      if [ -z "$PASTED" ]; then :
      elif key_ok "$PASTED"; then CUR_KEY="$PASTED"
      else echo "WARNING: the key must not contain a line break; not saved." >&2; fi
      PASTED=""
    fi
    if { [ "$ASK_URL" = 1 ] || [ "$ASK_KEY" = 1 ]; } && [ -z "$EP_HDR" ]; then
      {
        echo "Send the key as:"
        echo "  1) 'Authorization: Bearer' (default; most proxies)"
        echo "  2) 'x-api-key'"
        printf 'Choose 1 or 2%s: ' "${CUR_HDR:+ [current: $CUR_HDR]}"
      } > /dev/tty
      IFS= read -r CHOICE < /dev/tty || CHOICE=""
      case "$(printf '%s' "$CHOICE" | tr -d '[:space:]')" in
        1) CUR_HDR=bearer ;;
        2) CUR_HDR=x-api-key ;;
      esac
    fi
    case "$CUR_HDR" in bearer|x-api-key) ;; *) CUR_HDR=bearer ;; esac
    if [ -n "$CUR_URL" ] && [ -n "$CUR_KEY" ]; then
      if [ "$CUR_URL" != "$A_URL" ] || [ "$CUR_KEY" != "$A_KEY" ] || [ "$CUR_HDR" != "$A_HDR" ]; then
        A_URL="$CUR_URL"; A_KEY="$CUR_KEY"; A_HDR="$CUR_HDR"
        echo "Saved the endpoint to $AUTH_FILE"
      fi
      A_MODE=endpoint; auth_write
      BASE_URL="$CUR_URL"; API_KEY="$CUR_KEY"
      if [ "$CUR_HDR" = bearer ]; then ENDPOINT_KEY_VAR=ANTHROPIC_AUTH_TOKEN; else ENDPOINT_KEY_VAR=ANTHROPIC_API_KEY; fi
    elif [ "$EP_REQ" = 1 ] && { [ -n "$EP_URL$EP_KEY$EP_HDR" ] || [ "$HAS_TTY" = 0 ]; }; then
      echo "No complete endpoint: set SLP_CLAUDE_BASE_URL and SLP_CLAUDE_AUTH_TOKEN (or save one first with --endpoint)." >&2
      exit 1
    else
      echo "WARNING: no complete custom endpoint (base URL + key) for the room runtimes. Re-run" >&2
      echo "  install.sh with --endpoint, or with --token to use a 'claude setup-token' token instead." >&2
    fi
  fi
fi

# --- 0. v1 cleanup ------------------------------------------------------------------
# v1 shipped as orchestrate@my-orchestrate-skill; its /orchestrate skill would compete with
# the Supervisor. Remove the user-scope plugin and its marketplace, and stop any v1 watchdog.
# Project-scope installs live in other repositories' settings, so they are only reported.

LEGACY_PLUGIN="orchestrate@my-orchestrate-skill"
LEGACY_MARKETPLACE="my-orchestrate-skill"
if [ "$GC_ONLY" = 1 ]; then
  :  # --gc-only touches nothing but slp-gc
elif command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  LEGACY_SCOPES="$(claude plugin list --json </dev/null 2>/dev/null \
    | jq -r --arg id "$LEGACY_PLUGIN" '.[]? | select(.id == $id) | .scope // "user"' 2>/dev/null || true)"
  for scope in $LEGACY_SCOPES; do
    if [ "$scope" != user ]; then
      echo "NOTE: $LEGACY_PLUGIN is also installed at $scope scope; remove it from that project with: claude plugin uninstall $LEGACY_PLUGIN --scope $scope" >&2
    elif claude plugin uninstall "$LEGACY_PLUGIN" --scope user </dev/null >/dev/null 2>&1; then
      echo "Removed v1 plugin: $LEGACY_PLUGIN"
    else
      echo "WARNING: could not uninstall $LEGACY_PLUGIN; run: claude plugin uninstall $LEGACY_PLUGIN" >&2
    fi
  done
  if claude plugin marketplace list --json </dev/null 2>/dev/null \
    | jq -e --arg name "$LEGACY_MARKETPLACE" '.[]? | select(.name == $name)' >/dev/null 2>&1; then
    if claude plugin marketplace remove "$LEGACY_MARKETPLACE" </dev/null >/dev/null 2>&1; then
      echo "Removed v1 marketplace: $LEGACY_MARKETPLACE"
    else
      echo "WARNING: could not remove marketplace $LEGACY_MARKETPLACE; run: claude plugin marketplace remove $LEGACY_MARKETPLACE" >&2
    fi
  fi
fi
if [ "$GC_ONLY" = 0 ]; then
  if command -v pkill >/dev/null 2>&1 && pkill -f 'skills/orchestrate/watchdog.mjs run' 2>/dev/null; then
    echo "Stopped v1 watchdog pollers"
  fi
  rm -f "${TMPDIR:-/tmp}"/orchestrate-watchdog-* 2>/dev/null || true
fi

# --- 1. skill -------------------------------------------------------------------

if [ "$DO_SKILL" = 1 ]; then
  SKILLS="$HOME/.claude/skills"
  mkdir -p "$SKILLS"
  rm -rf "$SKILLS/supervisor"
  cp -R "$SRC/skills/supervisor" "$SKILLS/supervisor"
  jevf_inplace "$SKILLS/supervisor/SKILL.md"
  jevf_inplace "$SKILLS/supervisor/roles/lead.md"
  echo "Installed skill: $SKILLS/supervisor"
  # v1 installed the same role as "orchestrate"; leaving it would compete with /supervisor.
  if [ -f "$SKILLS/orchestrate/SKILL.md" ] && grep -q '^name: orchestrate$' "$SKILLS/orchestrate/SKILL.md"; then
    rm -rf "$SKILLS/orchestrate"
    echo "Removed legacy skill: $SKILLS/orchestrate"
  fi
fi

if [ "$DO_PASEO" = 1 ]; then
  command -v jq >/dev/null 2>&1 || { echo "jq is required but not installed. Install jq and re-run." >&2; exit 1; }

  # --- 2. role prompts, Claude runtimes, Codex launcher ---------------------------
  # Paseo has no per-agent system prompt. Each Claude seat (Supervisor, Lead, Peer) gets
  # its own Claude Code runtime (CLAUDE_CONFIG_DIR) whose output style carries protocol +
  # role, sharing the user's settings, skills, plugins, and CLAUDE.md, and one auth token.
  # Codex gets the Peer prompt as developer instructions through a launcher.

  CLAUDE_HOME="$HOME/.claude"
  ROOM_FILES="$ROOM_HOME/room"
  mkdir -p "$ROOM_HOME/bin" "$ROOM_FILES/roles"
  # A stable copy of the room files: every seat's ROOM_DIR, however the skill was installed.
  jevf "$JEV_MODE" "$SRC/skills/supervisor/PROTOCOL.md" > "$ROOM_FILES/PROTOCOL.md"
  # The Lead and Peer roles name slp-journal by absolute path: their @@SLP_JOURNAL@@ token is replaced.
  SLP_JOURNAL_SED="$(printf '%s' "$ROOM_HOME/bin/slp-journal" | sed 's/[\\&|]/\\&/g')"
  jevf "$JEV_MODE" "$SRC/skills/supervisor/roles/lead.md" | sed "s|@@SLP_JOURNAL@@|$SLP_JOURNAL_SED|g" > "$ROOM_FILES/roles/lead.md"
  jevf "$JEV_MODE" "$SRC/skills/supervisor/roles/peer.md" | sed "s|@@SLP_JOURNAL@@|$SLP_JOURNAL_SED|g" > "$ROOM_FILES/roles/peer.md"
  # The room's one blocking wait, at an absolute path the Supervisor prompt names: its
  # @@SLP_WAIT@@ token is replaced with it. Only the Supervisor waits; Leads and Peers are denied.
  cp "$SRC/paseo/bin/slp-wait" "$ROOM_HOME/bin/slp-wait"
  chmod 755 "$ROOM_HOME/bin/slp-wait"
  # slp-reviewer-check: the reviewer sandbox self-check. Installed only; neither this script nor CI runs it.
  cp "$SRC/paseo/bin/slp-reviewer-check" "$ROOM_HOME/bin/slp-reviewer-check"
  chmod 755 "$ROOM_HOME/bin/slp-reviewer-check"
  # slp-journal: stdlib-Python message-envelope + journal helper. Needs python3 >= 3.9; without it
  # the helper is skipped with a warning (the install does not fail). Journals are never created here.
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
    mkdir -p "$ROOM_HOME/schemas"
    cp "$SRC/paseo/bin/slp-journal" "$ROOM_HOME/bin/slp-journal"
    chmod 755 "$ROOM_HOME/bin/slp-journal"
    cp "$SRC/paseo/schemas/room-message.v1.schema.json" "$ROOM_HOME/schemas/room-message.v1.schema.json"
    chmod 644 "$ROOM_HOME/schemas/room-message.v1.schema.json"
  else
    echo "WARNING: python3 >= 3.9 not found; skipping slp-journal (the room works without it)." >&2
  fi
  # The room's one journal lives in state/ (0700); SLP_JOURNAL points the Lead and Peer seats at it.
  # Only the directory is created here: never the journal itself, and an existing one is left alone.
  mkdir -p "$ROOM_HOME/state" && chmod 700 "$ROOM_HOME/state"
  SLP_WAIT_SED="$(printf '%s' "$ROOM_HOME/bin/slp-wait" | sed 's/[\\&|]/\\&/g')"

  HEADER="<!-- Generated by install.sh (paseo-slp $VERSION). Re-run it to update; do not edit. -->"
  for role in lead peer; do
    {
      printf '%s\n\n' "$HEADER"
      cat "$ROOM_FILES/PROTOCOL.md"
      printf '\n---\n\n'
      cat "$ROOM_FILES/roles/$role.md"
    } > "$ROOM_HOME/$role.md"
  done
  {
    printf '%s\n\n' "$HEADER"
    printf '# Room role: Supervisor\n\n'
    printf 'This session is the Supervisor of a Paseo Supervisor → Lead → Peer room, and every user\n'
    printf 'message comes from Human. ROOM_DIR=%s. The room protocol follows, then the\n' "$ROOM_FILES"
    printf 'Supervisor role; where the role mentions /supervisor, $ARGUMENTS, or reading PROTOCOL.md,\n'
    printf 'this system prompt already covers it.\n\n'
    cat "$ROOM_FILES/PROTOCOL.md"
    printf '\n---\n\n'
    jevf "$JEV_MODE" "$SRC/skills/supervisor/SKILL.md" | awk 'n >= 2 { print; next } /^---$/ { n++ }' \
      | sed "s|@@SLP_WAIT@@|$SLP_WAIT_SED|g"  # drop the frontmatter
  } > "$ROOM_HOME/supervisor.md"

  for role in supervisor lead peer reviewer; do
    RUNTIME="$ROOM_HOME/claude-$role"
    PROMPT_ROLE="$role"; [ "$role" != reviewer ] || PROMPT_ROLE=peer  # the reviewer seat runs the Peer prompt
    mkdir -p "$RUNTIME/output-styles" "$RUNTIME/skills"
    {
      printf -- '---\nname: slp-%s\ndescription: Supervisor → Lead → Peer room, %s seat\nkeep-coding-instructions: true\n---\n\n' "$role" "$role"
      cat "$ROOM_HOME/$PROMPT_ROLE.md"
    } > "$RUNTIME/output-styles/slp-$role.md"

    # The user's settings, with the seat's output style, and without this plugin: no seat
    # loads the /supervisor skill on top of its own role.
    USER_SETTINGS='{}'
    if [ -f "$CLAUDE_HOME/settings.json" ]; then
      if jq -e 'type == "object"' "$CLAUDE_HOME/settings.json" >/dev/null 2>&1; then
        USER_SETTINGS="$(cat "$CLAUDE_HOME/settings.json")"
      else
        echo "WARNING: $CLAUDE_HOME/settings.json is not a JSON object; the $role runtime starts from empty settings." >&2
      fi
    fi
    # Endpoint mode: the user's settings env must not override or conflict with the provider env.
    STRIP_ENV=0
    if [ -n "$ENDPOINT_KEY_VAR" ]; then
      STRIP_ENV=1
      DROPPED="$(printf '%s' "$USER_SETTINGS" | jq -r '[(.env // {}) | if type == "object" then keys[] else empty end
        | select(. == "CLAUDE_CODE_OAUTH_TOKEN" or . == "ANTHROPIC_BASE_URL" or . == "ANTHROPIC_AUTH_TOKEN" or . == "ANTHROPIC_API_KEY")] | join(", ")')"
      if [ -n "$DROPPED" ] && [ -z "${WARNED_ENV:-}" ]; then
        WARNED_ENV=1
        echo "WARNING: removed $DROPPED from the runtimes' settings env (the custom endpoint sets them); $CLAUDE_HOME/settings.json is untouched." >&2
      fi
    fi
    printf '%s' "$USER_SETTINGS" | jq --arg style "slp-$role" --argjson strip "$STRIP_ENV" '
      .outputStyle = $style
      | if $strip == 1 and (.env | type) == "object" then
          (.env) as $before
          | .env |= del(.CLAUDE_CODE_OAUTH_TOKEN, .ANTHROPIC_BASE_URL, .ANTHROPIC_AUTH_TOKEN, .ANTHROPIC_API_KEY)
          | if .env == {} and $before != {} then del(.env) else . end
        else . end
      | .enabledPlugins = ((.enabledPlugins // {})
          | with_entries(if (.key | test("^(paseo-slp|orchestrate)@")) then .value = false else . end))
    ' > "$RUNTIME/settings.json"
    if [ "$JEV" = 0 ]; then
      # Jev off, seats only: ask-jev disabled, its hooks removed, and the unfiltered ~/.claude/CLAUDE.md excluded from the ancestor walk; the user's own settings.json is only read.
      jq --arg md "$CLAUDE_HOME/CLAUDE.md" '
        .enabledPlugins = ((.enabledPlugins // {}) | .["ask-jev@ask-jev"] = false)
        | .claudeMdExcludes = (((.claudeMdExcludes | if type == "array" then . else [] end) + [$md]) | unique)
        | if (.env | type) == "object" then .env |= with_entries(select(.key | test("jev"; "i") | not)) else . end
        | if (.extraKnownMarketplaces | type) == "object" then .extraKnownMarketplaces |= with_entries(select(.key | test("jev"; "i") | not)) else . end
        | if (.permissions | type) == "object" and (.permissions.allow | type) == "array" then
            .permissions.allow |= map(select((type == "string" and test("jev"; "i")) | not))
          else . end
      ' "$RUNTIME/settings.json" > "$RUNTIME/settings.json.tmp"
      jq '
        if (.hooks | type) == "object" then
          .hooks |= (
            with_entries(
              .value |= (if type == "array" then
                map(if type == "object" and (.hooks | type) == "array" then
                      .hooks |= map(select(((type == "object") and (.command | type) == "string" and (.command | test("ask-jev\\.mjs|jev-ask\\.mjs"))) | not))
                    else . end)
                | map(select((type == "object" and (.hooks | type) == "array" and (.hooks | length) == 0) | not))
              else . end))
            | with_entries(select((.value | type) != "array" or (.value | length) > 0)))
        else . end
      ' "$RUNTIME/settings.json.tmp" > "$RUNTIME/settings.json"
      rm -f "$RUNTIME/settings.json.tmp"
    fi

    if [ "$role" = reviewer ]; then
      # Restriction keys, merged last so they win over the user's settings: deny rules beat allow rules, the
      # sandbox block is replaced (no excludedCommands, no allowWrite, no unsandboxed retry), the user's
      # Bash/Edit/Write and non-paseo mcp__ allow rules, hooks, statusLine, credential helpers, MCP server lists
      # and most env are dropped. Writes under $HOME (the launch cwd is writable by default and the docs have no
      # cwd-relative form in user settings) and under SLP_REVIEWER_DENY_WRITE are denied; the temp dir is outside
      # $HOME on macOS and is the only place the Edit/Write tools may write. Doc-claimed: slp-reviewer-check probes it.
      REVIEWER_DENY=("$HOME")
      if [ -n "${SLP_REVIEWER_DENY_WRITE:-}" ]; then
        IFS=: read -r -a REVIEWER_EXTRA <<< "$SLP_REVIEWER_DENY_WRITE"
        for extra in "${REVIEWER_EXTRA[@]}"; do
          case "$extra" in
            /*) REVIEWER_DENY+=("$extra") ;;
            "") ;;
            *) echo "ERROR: SLP_REVIEWER_DENY_WRITE entries must be absolute paths (got '$extra')." >&2; exit 1 ;;
          esac
        done
      fi
      REVIEWER_DENY_JSON="$(jq -cn '$ARGS.positional | unique' --args "${REVIEWER_DENY[@]}")"
      REVIEWER_TMP_JSON="$(jq -cn --arg t "$(cd -P "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P || echo /tmp)" '[$t, "/tmp", "/private/tmp"] | unique')"
      jq --argjson dw "$REVIEWER_DENY_JSON" --argjson tmpd "$REVIEWER_TMP_JSON" --arg home "$HOME" --arg room "$ROOM_HOME" '
        (["/.config/gh", "/.ssh", "/.aws", "/.netrc", "/.npmrc", "/.codex", "/.claude", "/.claude.json", "/.paseo/config.json"] | map($home + .)) as $homeCreds
        | (["/auth", "/claude-supervisor", "/claude-lead", "/claude-peer", "/codex-peer", "/codex-reviewer"] | map($room + .)) as $roomCreds
        | ($homeCreds + $roomCreds) as $credPaths
        | (.permissions | if type == "object" then . else {} end) as $perm
        | .permissions = ($perm
            | del(.additionalDirectories)
            | .defaultMode = "default"
            | .disableBypassPermissionsMode = "disable"
            | .allow = (((.allow // []) | map(select(type == "string" and (test("^(Bash|Edit|Write|NotebookEdit|MultiEdit|mcp__)") | not))))
                + ["Read(//**)", "Grep", "Glob", "Skill", "TaskStop", "mcp__paseo__send_agent_prompt", "mcp__paseo__get_agent_status"]
                + ($tmpd | map("Edit(/" + . + "/**)", "Write(/" + . + "/**)")) | unique)
            | .deny = (((.deny // [])
                + ["WebFetch", "WebSearch", "Bash(git push:*)", "Bash(gh:*)"]
                + ($dw | map("Edit(/" + . + "/**)", "Write(/" + . + "/**)"))
                + ($credPaths | map("Read(/" + . + ")", "Read(/" + . + "/**)"))) | unique))
        | .sandbox = {
            enabled: true, allowUnsandboxedCommands: false, failIfUnavailable: true, autoAllowBashIfSandboxed: true,
            filesystem: {denyWrite: $dw},
            network: {allowedDomains: []},
            credentials: {
              files: ($credPaths | map({path: ., mode: "deny"})),
              envVars: (["GH_TOKEN", "GITHUB_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] | map({name: ., mode: "deny"}))}}
        | del(.hooks, .statusLine, .apiKeyHelper, .awsAuthRefresh, .awsCredentialExport, .mcpServers, .enabledMcpjsonServers, .enableAllProjectMcpServers)
        | .enabledPlugins = {}
        | .env = ((.env // {}) | if type == "object" then with_entries(select(.key | test("^(LANG|LC_[A-Z]+|TZ|NO_COLOR|ANTHROPIC_(DEFAULT_[A-Z_]+_MODEL|MODEL|SMALL_FAST_MODEL))$"))) else {} end)
        | if .env == {} then del(.env) else . end
      ' "$RUNTIME/settings.json" > "$RUNTIME/settings.json.tmp" \
        && chmod 600 "$RUNTIME/settings.json.tmp" \
        && mv "$RUNTIME/settings.json.tmp" "$RUNTIME/settings.json" \
        || { rm -f "$RUNTIME/settings.json.tmp"; echo "ERROR: could not render the reviewer sandbox settings; the reviewer would run unrestricted. Aborting." >&2; exit 1; }
    fi

    for shared in plugins agents commands; do
      [ "$role" != reviewer ] || { rm -f "$RUNTIME/$shared" 2>/dev/null; continue; }  # plugins can carry hooks that run outside the sandbox
      if [ -e "$CLAUDE_HOME/$shared" ] && { [ -L "$RUNTIME/$shared" ] || [ ! -e "$RUNTIME/$shared" ]; }; then
        ln -sfn "$CLAUDE_HOME/$shared" "$RUNTIME/$shared"
      fi
    done
    # Seat CLAUDE.md: the link to the user's file with Jev on; with Jev off a regular, filtered copy that
    # starts with GEN_HEADER. Never written through the link, and a file of the user's own is left alone.
    GEN_HEADER="<!-- generated by paseo-slp install.sh from ~/.claude/CLAUDE.md (room switch off); re-run install.sh after editing it -->"
    SEAT_MD="$RUNTIME/CLAUDE.md"
    if [ -e "$CLAUDE_HOME/CLAUDE.md" ]; then
      GENERATED=0
      if [ -f "$SEAT_MD" ] && [ ! -L "$SEAT_MD" ] && [ "$(head -n 1 "$SEAT_MD")" = "$GEN_HEADER" ]; then GENERATED=1; fi
      if [ "$JEV" = 1 ]; then
        if [ "$GENERATED" = 1 ]; then rm -f "$SEAT_MD"; fi
        if [ -L "$SEAT_MD" ] || [ ! -e "$SEAT_MD" ]; then
          ln -sfn "$CLAUDE_HOME/CLAUDE.md" "$SEAT_MD"
        else
          echo "WARNING: $SEAT_MD is not a link and was not generated by install.sh; left alone." >&2
        fi
      elif [ -L "$SEAT_MD" ] || [ ! -e "$SEAT_MD" ] || [ "$GENERATED" = 1 ]; then
        MD_TMP="$(mktemp "$RUNTIME/.CLAUDE.md.XXXXXX")"
        if ! { printf '%s\n' "$GEN_HEADER"; jev_filter_claude_md "$CLAUDE_HOME/CLAUDE.md"; } > "$MD_TMP" \
          || { [ -s "$CLAUDE_HOME/CLAUDE.md" ] && [ "$(wc -l < "$MD_TMP")" -le 1 ]; }; then
          rm -f "$MD_TMP"
          echo "ERROR: could not filter $CLAUDE_HOME/CLAUDE.md for the $role seat (Jev off); $SEAT_MD left as it was. Fix the cause or pass --jev." >&2
          exit 1
        fi
        chmod 600 "$MD_TMP"
        mv -f "$MD_TMP" "$SEAT_MD"
      else
        echo "WARNING: $SEAT_MD is not a link and was not generated by install.sh; left alone." >&2
      fi
    elif [ -f "$SEAT_MD" ] && [ ! -L "$SEAT_MD" ] && [ "$(head -n 1 "$SEAT_MD")" = "$GEN_HEADER" ]; then
      rm -f "$SEAT_MD"
      echo "Removed $SEAT_MD: it was generated from $CLAUDE_HOME/CLAUDE.md, which no longer exists."
    fi
    find "$RUNTIME/skills" -mindepth 1 -maxdepth 1 -type l -exec rm -f {} +
    if [ -d "$CLAUDE_HOME/skills" ]; then
      for skill in "$CLAUDE_HOME/skills"/*; do
        case "$(basename "$skill")" in supervisor|orchestrate) continue ;; esac
        [ -e "$skill" ] && ln -sfn "$skill" "$RUNTIME/skills/$(basename "$skill")"
      done
    fi
  done
  rm -f "$ROOM_HOME/bin/claude-lead" "$ROOM_HOME/bin/claude-peer"  # launchers of an earlier version

  # Every copy of the agent-spawning CLIs on PATH (and their symlink targets): Claude seats
  # deny them by name and path (step 3); the Codex runtime forbids them in its rules.
  SPAWNERS=()
  for cli in paseo claude codex; do
    while IFS= read -r found; do
      [ -n "$found" ] || continue
      SPAWNERS+=("$found")
      target="$(readlink -f "$found" 2>/dev/null || true)"
      [ -z "$target" ] || SPAWNERS+=("$target")
    done < <(type -ap "$cli" 2>/dev/null || true)
  done
  rm -rf "$ROOM_HOME/guard"  # PATH stubs of an earlier version: login shells reorder PATH past them

  # The Codex Peer runtime (CODEX_HOME), as codex-room-setup does it: shared auth, a copy of
  # the user's config, their AGENTS.md/skills/plugins, and rules that forbid spawning agents.
  CODEX_USER_HOME="${CODEX_HOME:-$HOME/.codex}"
  CODEX_RT="$ROOM_HOME/codex-peer"
  mkdir -p "$CODEX_RT/rules"
  if [ -f "$CODEX_USER_HOME/config.toml" ]; then
    cp "$CODEX_USER_HOME/config.toml" "$CODEX_RT/config.toml"
  fi
  for shared in auth.json AGENTS.md skills plugins; do
    if [ -e "$CODEX_USER_HOME/$shared" ] && { [ -L "$CODEX_RT/$shared" ] || [ ! -e "$CODEX_RT/$shared" ]; }; then
      ln -sfn "$CODEX_USER_HOME/$shared" "$CODEX_RT/$shared"
    fi
  done
  [ -e "$CODEX_RT/auth.json" ] || echo "WARNING: no $CODEX_USER_HOME/auth.json to share; run 'codex login' (file credentials) and re-run install.sh." >&2
  CODEX_FORBIDDEN="$(jq -rn '["paseo", "claude", "codex", "slp-wait"] + $ARGS.positional | unique | map(@json) | join(", ")' \
    --args ${SPAWNERS[@]+"${SPAWNERS[@]}"} "$ROOM_HOME/bin/slp-wait")"
  cat > "$CODEX_RT/rules/room.rules" <<RULES
# Generated by install.sh: a room seat never starts agents outside create_agent.
prefix_rule(
    pattern = [[$CODEX_FORBIDDEN]],
    decision = "forbidden",
    justification = "not allowed in a room seat: only the Supervisor and Leads create agents, via create_agent",
)
RULES

  CODEX_BIN="$(command -v codex || true)"
  if [ -z "$CODEX_BIN" ]; then
    echo "WARNING: codex is not on PATH; the codex-peer launcher will look it up each time it runs." >&2
    CODEX_BIN=codex
  fi
  # Codex takes the prompt as a TOML literal string, which cannot contain '''.
  if grep -qF "'''" "$ROOM_HOME/peer.md"; then
    echo "roles/peer.md or PROTOCOL.md contains ''' and cannot be passed to Codex; remove it and re-run." >&2
    exit 1
  fi
  # No native Codex sub-agents either (multi_agent_v2 is a table in some configs, a flag in others).
  V2_OFF="features.multi_agent_v2=false"
  if grep -q '^\[features\.multi_agent_v2\]' "$CODEX_RT/config.toml" 2>/dev/null; then
    V2_OFF="features.multi_agent_v2.enabled=false"
  fi
  cat > "$ROOM_HOME/bin/codex-peer" <<LAUNCHER
#!/bin/sh
# Generated by install.sh: Codex in the room's Peer runtime — the Peer role as developer
# instructions, native sub-agents off, and rules that forbid paseo/claude/codex.
SLP_JOURNAL="$ROOM_HOME/state/journal.jsonl" CODEX_HOME="$CODEX_RT" exec "$CODEX_BIN" -c agents.enabled=false -c features.multi_agent=false -c $V2_OFF \\
  -c "developer_instructions='''\$(cat "$ROOM_HOME/peer.md")'''" "\$@"
LAUNCHER
  chmod +x "$ROOM_HOME/bin/codex-peer"
  # The Codex reviewer: the Peer runtime and prompt, a read-only sandbox, approvals off (a blocked action fails
  # instead of prompting), a core-only subprocess environment. Its CODEX_HOME copies the config and rules. A
  # separate login is not something install.sh can create, so auth.json is linked like codex-peer's: the model
  # can read the shared login (a limit, docs/REVIEWER_SANDBOX.md). Read-only means no temp-dir checks on Codex.
  CODEX_RV="$ROOM_HOME/codex-reviewer"
  mkdir -p "$CODEX_RV/rules"
  [ ! -f "$CODEX_RT/config.toml" ] || cp "$CODEX_RT/config.toml" "$CODEX_RV/config.toml"
  cp "$CODEX_RT/rules/room.rules" "$CODEX_RV/rules/room.rules"
  for shared in auth.json AGENTS.md skills plugins; do
    if [ -e "$CODEX_USER_HOME/$shared" ] && { [ -L "$CODEX_RV/$shared" ] || [ ! -e "$CODEX_RV/$shared" ]; }; then
      ln -sfn "$CODEX_USER_HOME/$shared" "$CODEX_RV/$shared"
    fi
  done
  cat > "$ROOM_HOME/bin/codex-reviewer" <<LAUNCHER
#!/bin/sh
# Generated by install.sh: Codex in the room's reviewer runtime — the Peer role as developer instructions,
# sandbox_mode=read-only, approval_policy=never, a core-only subprocess environment, native sub-agents off.
# Doc-claimed only: run slp-reviewer-check to probe it.
SLP_JOURNAL="$ROOM_HOME/state/journal.jsonl" CODEX_HOME="$CODEX_RV" exec "$CODEX_BIN" -c 'sandbox_mode="read-only"' -c 'approval_policy="never"' -c 'shell_environment_policy.inherit="core"' -c agents.enabled=false -c features.multi_agent=false -c $V2_OFF \\
  -c "developer_instructions='''\$(cat "$ROOM_HOME/peer.md")'''" "\$@"
LAUNCHER
  chmod +x "$ROOM_HOME/bin/codex-reviewer"
  echo "Rendered room runtimes and prompts: $ROOM_HOME"
  echo "Reviewer seats are configured to restrict writes, network and credentials, but nothing is verified yet: run $ROOM_HOME/bin/slp-reviewer-check"

  # --- 3. Paseo config ------------------------------------------------------------

  # Deny every copy of the spawners by absolute path too, so calling
  # /opt/homebrew/bin/claude is no way around the by-name rules.
  LEAD_ABS=()
  SUP_ABS=()
  for path in ${SPAWNERS[@]+"${SPAWNERS[@]}"}; do
    LEAD_ABS+=("Bash($path:*)")
    case "$(basename "$path")" in
      paseo) SUP_ABS+=("Bash($path run:*)" "Bash($path send:*)" "Bash($path import:*)") ;;
      *) SUP_ABS+=("Bash($path:*)") ;;
    esac
  done
  LEAD_ABS_JSON="$(jq -cn '$ARGS.positional | unique' --args ${LEAD_ABS[@]+"${LEAD_ABS[@]}"})"
  SUP_ABS_JSON="$(jq -cn '$ARGS.positional | unique' --args ${SUP_ABS[@]+"${SUP_ABS[@]}"})"
  # Only the Supervisor waits with slp-wait; Leads and Peers never do.
  NOWAIT_JSON="$(jq -cn --arg p "Bash($ROOM_HOME/bin/slp-wait:*)" '[$p]')"

  # With no token the env key is dropped, so a per-runtime login keeps working. In endpoint
  # mode the token key is replaced by the endpoint's base URL and key (the header form picks
  # which variable), so a provider never carries both modes' variables.
  jq --arg dir "$ROOM_HOME" --arg token "$OAUTH_TOKEN" \
    --arg baseUrl "${BASE_URL:-}" --arg apiKey "${API_KEY:-}" --arg keyVar "$ENDPOINT_KEY_VAR" \
    --argjson leadAbs "$LEAD_ABS_JSON" --argjson supAbs "$SUP_ABS_JSON" \
    --argjson noWait "$NOWAIT_JSON" '
    walk(if type == "string" then gsub("@@ROOM_HOME@@"; $dir) else . end)
    | .agents.providers |= map_values(
        if .env.CLAUDE_CODE_OAUTH_TOKEN == "@@CLAUDE_OAUTH_TOKEN@@" then
          (if $keyVar != "" then
             del(.env.CLAUDE_CODE_OAUTH_TOKEN) | .env.ANTHROPIC_BASE_URL = $baseUrl | .env[$keyVar] = $apiKey
           elif $token == "" then del(.env.CLAUDE_CODE_OAUTH_TOKEN) else .env.CLAUDE_CODE_OAUTH_TOKEN = $token end)
        else . end)
    | .agents.providers["claude-lead"].disallowedTools += $leadAbs + $noWait
    | .agents.providers["claude-peer"].disallowedTools += $leadAbs + $noWait
    | .agents.providers["claude-reviewer"].disallowedTools += $leadAbs + $noWait
    | .agents.providers["claude-supervisor"].disallowedTools += $supAbs
  ' "$SRC/paseo/config.snippet.json" > "$WORK/snippet.json"

  PASEO_DIR="$HOME/.paseo"
  CONFIG="$PASEO_DIR/config.json"
  mkdir -p "$PASEO_DIR"
  # The config and its backups may hold the Claude token: keep them private.
  umask 077
  [ -f "$CONFIG" ] || echo '{"version":1}' > "$CONFIG"
  chmod 600 "$CONFIG"
  cp "$CONFIG" "$CONFIG.bak-$(date +%Y%m%d%H%M%S)"

  # The snippet's profiles (matched by id, or by name when an old install left no id) and
  # providers are owned by this script: each run replaces them with the snippet's version.
  # v1 profiles and the v1 claude-worker provider are removed. Everything else is kept.
  MERGE='
    ($snip[0].daemon.agentProfiles) as $new
    | ["agent_profile_orchestrate_cheap_worker", "agent_profile_orchestrate_worker",
       "agent_profile_orchestrate_expensive_worker", "agent_profile_orchestrate_reviewer",
       "agent_profile_orchestrate_codex_advisor"] as $legacyIds
    | ["Cheap worker", "Worker", "Expensive worker", "Reviewer", "Codex advisor"] as $legacyNames
    | (($new | map(.id)) + $legacyIds) as $ownedIds
    | (($new | map(.name)) + $legacyNames) as $ownedNames
    | def owned: if .id == null then (.name as $n | $ownedNames | index($n)) != null
                 else (.id as $i | $ownedIds | index($i)) != null end;
    .daemon.agentProfiles = (((.daemon.agentProfiles // []) | map(select(owned | not))) + $new)
    | (.daemon.agentProfiles | map(.provider)) as $used
    | .agents.providers = ((.agents.providers // {}) + $snip[0].agents.providers)
    | if (.agents.providers["claude-worker"].description // "") == "Delegated worker — cannot spawn or control other agents"
         and ($used | index("claude-worker")) == null
      then del(.agents.providers["claude-worker"]) else . end
  '
  TMP="$(mktemp "$CONFIG.XXXXXX")"
  jq --slurpfile snip "$WORK/snippet.json" "$MERGE" "$CONFIG" > "$TMP"
  REMOVED="$(jq -r --slurpfile after "$TMP" '
    [.daemon.agentProfiles[]?.name] - [$after[0].daemon.agentProfiles[].name] | join(", ")' "$CONFIG")"
  mv "$TMP" "$CONFIG"
  echo "Updated Paseo config: $CONFIG (backup saved alongside it)"
  echo "  Room profiles: $(jq -r '[.daemon.agentProfiles[].name] | join(", ")' "$WORK/snippet.json")"
  echo "  Room providers: $(jq -r '.agents.providers | keys | join(", ")' "$WORK/snippet.json")"
  [ -z "$OAUTH_TOKEN" ] || echo "  Claude runtimes share the token from $ROOM_HOME/auth"
  [ -z "$ENDPOINT_KEY_VAR" ] || echo "  Claude runtimes use the endpoint $(printf '%s' "$BASE_URL" | redact_url) (key in $ROOM_HOME/auth, sent via $ENDPOINT_KEY_VAR)"
  [ -z "$REMOVED" ] || echo "  Removed v1 profiles: $REMOVED"
  DUPES="$(jq -r '[.daemon.agentProfiles[].name] | group_by(.) | map(select(length > 1)[0]) | join(", ")' "$CONFIG")"
  [ -z "$DUPES" ] || echo "WARNING: you also have your own profile(s) named $DUPES; rename yours so the room picks the right one." >&2

  if [ "$(jq -r '.daemon.mcp.injectIntoAgents // false' "$CONFIG")" != "true" ]; then
    echo "WARNING: daemon.mcp.injectIntoAgents is not enabled in $CONFIG" >&2
    echo "The Supervisor and Lead agents will not have the create_agent tool without it." >&2
    echo "Enable it by setting daemon.mcp.enabled: true and daemon.mcp.injectIntoAgents: true" >&2
  fi

  # --- 4. reload --------------------------------------------------------------------

  if [ "$RELOAD" = 0 ]; then
    echo "Run 'paseo daemon reload' to load the updated profiles and providers."
  elif command -v paseo >/dev/null 2>&1 && paseo daemon reload </dev/null; then
    :
  else
    echo "WARNING: could not run 'paseo daemon reload'; run it (or restart Paseo) yourself." >&2
  fi
fi

# Whether launchd may be touched, and through what. Fail closed. SLP_LAUNCHCTL (tests) must be an
# absolute path to an executable and is the only launchctl then used. A HOME that is not the login
# user's own home (a test sandbox) never reaches launchd, even so: loading would replace the real
# agent with one pointing at that HOME. An unresolvable login home loads only with SLP_LAUNCHCTL set.
# Production resolves the user and their home with fixed system tools; PATH lookups (the fixtures'
# stubs) are honoured only when SLP_LAUNCHCTL is set. Sets LAUNCHCTL, GC_ID, GC_DOMAIN and GC_SKIP.
gc_resolve_launchctl() {
  LAUNCHCTL=launchctl; GC_SKIP=""
  if [ -n "${SLP_LAUNCHCTL:-}" ]; then GC_ID=id; GC_DSCL=dscl; GC_GETENT=getent
  else GC_ID=/usr/bin/id; GC_DSCL=/usr/bin/dscl; GC_GETENT=/usr/bin/getent; fi
  if [ -n "${SLP_LAUNCHCTL:-}" ]; then
    case "$SLP_LAUNCHCTL" in
      /*) if [ -f "$SLP_LAUNCHCTL" ] && [ -x "$SLP_LAUNCHCTL" ]; then LAUNCHCTL="$SLP_LAUNCHCTL"
          else GC_SKIP="SLP_LAUNCHCTL ($SLP_LAUNCHCTL) is not an existing executable"; fi ;;
      *) GC_SKIP="SLP_LAUNCHCTL ($SLP_LAUNCHCTL) is not an absolute path" ;;
    esac
  fi
  if [ -z "$GC_SKIP" ]; then
    local user login_home=""
    user="$("$GC_ID" -un 2>/dev/null || true)"
    if [ -n "$user" ]; then
      login_home="$("$GC_DSCL" . -read "/Users/$user" NFSHomeDirectory 2>/dev/null </dev/null | sed -n 's/^NFSHomeDirectory: //p' | head -1 || true)"
      [ -n "$login_home" ] || login_home="$("$GC_GETENT" passwd "$user" 2>/dev/null </dev/null | cut -d: -f6 || true)"
    fi
    if [ -n "$login_home" ] && [ -d "$login_home" ]; then
      if [ "$(cd -P "$login_home" && pwd -P)" != "$(cd -P "$HOME" && pwd -P)" ]; then
        GC_SKIP="HOME ($HOME) is not the login home ($login_home)"
      fi
    elif [ -z "${SLP_LAUNCHCTL:-}" ]; then
      GC_SKIP="the login home could not be resolved (dscl/getent)"
    fi
    if [ -z "$GC_SKIP" ] && ! command -v "$LAUNCHCTL" >/dev/null 2>&1; then
      GC_SKIP="launchctl not found (not macOS?)"
    fi
  fi
  GC_DOMAIN="gui/$("$GC_ID" -u 2>/dev/null || id -u)"
}
# With --no-gc / --no-gc-launchd an agent from an earlier install is left alone: say what is true of
# it. "Active" only after a successful launchctl print through the override; a plist alone is just
# an installed definition, and "unknown" is said when launchd cannot be queried safely.
gc_existing_agent_note() {
  local plist=0 state=unknown rm_cmd
  if [ -e "$GC_PLIST" ] || [ -L "$GC_PLIST" ]; then plist=1; fi
  gc_resolve_launchctl
  if [ -z "$GC_SKIP" ]; then
    if "$LAUNCHCTL" print "$GC_DOMAIN/$GC_LABEL" </dev/null >/dev/null 2>&1; then state=loaded; else state=notloaded; fi
  fi
  rm_cmd="launchctl bootout gui/\$(id -u)/$GC_LABEL; rm $GC_PLIST"
  if [ "$state" = loaded ]; then
    echo "slp-gc: existing agent remains active: $GC_LABEL (not touched); to remove: $rm_cmd"
  elif [ "$plist" = 1 ] && [ "$state" = notloaded ]; then
    echo "slp-gc: existing definition remains installed (not loaded): $GC_PLIST (not touched); to remove: rm $GC_PLIST"
  elif [ "$plist" = 1 ]; then
    echo "slp-gc: an existing definition is installed at $GC_PLIST; whether it is loaded is unknown (launchd cannot be queried safely here: $GC_SKIP); not touched; to remove: $rm_cmd"
  fi
}

# --- 5. slp-gc: Paseo GC + memory diagnostic, run every 60 s by a launchd agent -----------------
# Independent of the Paseo daemon. A fresh install defaults to the safe tier (apply + kill-stale on,
# kill-memory off); the opt-ins live in slp-gc.conf (never in the plist's arguments), which a re-run
# keeps and only --gc-* edits.

if [ "$DO_GC" = 1 ]; then
  mkdir -p "$ROOM_HOME/bin"
  # A state dir this run creates is private (0700); an existing one (owned: checked up front) keeps
  # its mode, with a warning when it is not 0700.
  if [ -e "$GC_STATE" ]; then
    GC_STATE_MODE="$(stat -c %a "$GC_STATE" 2>/dev/null || stat -f %Lp "$GC_STATE" 2>/dev/null || true)"
    if [ "$GC_STATE_MODE" != 700 ]; then
      echo "WARNING: slp-gc state dir $GC_STATE is mode ${GC_STATE_MODE:-unknown}, not 0700; it holds process and memory reports. Left as is." >&2
    fi
  else
    (umask 077 && mkdir -p "$GC_STATE") && chmod 700 "$GC_STATE"
  fi
  # Atomic: a running tick never sees a half-written slp-gc.
  GC_TMP="$(mktemp "$ROOM_HOME/bin/.slp-gc.XXXXXX")"
  cp "$SRC/paseo/bin/slp-gc" "$GC_TMP"
  chmod 755 "$GC_TMP"
  mv -f "$GC_TMP" "$GC_BIN"
  echo "Installed slp-gc: $GC_BIN"

  # --- config: written once, never reset (a re-run never migrates it: an old untouched default and a
  # deliberate opt-out are the same file). KEY=VALUE, parsed (not sourced) by `slp-gc tick`.
  GC_CONF_EXISTED=1
  if [ ! -e "$GC_CONF" ] && [ ! -L "$GC_CONF" ]; then
    GC_CONF_EXISTED=0
    (umask 077 && cat > "$GC_CONF" <<'CONF'
# slp-gc configuration (KEY=VALUE, parsed not sourced; the last value wins). Read by `slp-gc tick`
# only. A flag is on only when its value is exactly 1. install.sh never resets this file: change
# it here, or with install.sh --gc-apply / --gc-kill / --gc-report-only.
#
# Default (fresh install): the safe tier. Every tick records memory, writes hourly reports and alerts,
# deletes completed schedules and long-archived agents, and SIGTERMs proven orphaned processes.
# kill-memory stays off. Set all three flags to 0 (install.sh --gc-report-only) for report-only.

# 1 = delete completed schedules and long-archived agents through the paseo CLI.
SLP_GC_APPLY=1
# 1 = also SIGTERM proven orphaned agent processes (needs SLP_GC_APPLY=1 to act).
SLP_GC_KILL_STALE=1
# 1 = also SIGTERM agent descendants above SLP_GC_MEM_KILL_MB (needs SLP_GC_APPLY=1 to act).
SLP_GC_KILL_MEMORY=0

# Tunables (uncomment to change; defaults shown):
# SLP_GC_MEM_WARN_MB=3072
# SLP_GC_MEM_KILL_MB=4096
# SLP_GC_TREE_WARN_MB=            (default: 50% of RAM)
# SLP_GC_KILL_COMMS=              (process names the kill rules may target; alias SLP_GC_ORPHAN_COMMS)
# SLP_GC_ORPHAN_MIN_AGE_MIN=10
# SLP_GC_TEST_CONCURRENCY_WARN=3
# SLP_GC_MAX_KILLS=20             (per tick)
# SLP_GC_TICK_BUDGET_S=45
# SLP_GC_REPORT_INTERVAL_MIN=60
# SLP_GC_ALERT_SUPERVISOR=1         (0 = never deliver a real alert to the most recently used open Supervisor)
CONF
    )
    echo "Wrote default config (safe tier: apply + kill-stale; kill-memory off): $GC_CONF"
  fi
  # Sets KEY=VALUE in place, replacing every existing KEY= line (or appending); the rest is kept.
  gc_conf_set() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp "$GC_CONF.XXXXXX")"
    awk -v k="$key" -v v="$val" 'BEGIN { p = k "=" }
      index($0, p) == 1 { if (!done) print p v; done = 1; next }
      { print } END { if (!done) print p v }' "$GC_CONF" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$GC_CONF"
  }
  if [ "$GC_REPORT_ONLY" = 1 ]; then
    gc_conf_set SLP_GC_APPLY 0; gc_conf_set SLP_GC_KILL_STALE 0; gc_conf_set SLP_GC_KILL_MEMORY 0
    echo "slp-gc opt-ins cleared (report-only): $GC_CONF"
  fi
  if [ "$GC_APPLY" = 1 ]; then gc_conf_set SLP_GC_APPLY 1; echo "slp-gc apply enabled: $GC_CONF"; fi
  if [ "$GC_KILL_STALE" = 1 ]; then gc_conf_set SLP_GC_KILL_STALE 1; echo "slp-gc kill-stale enabled: $GC_CONF"; fi
  if [ "$GC_KILL_MEM" = 1 ]; then gc_conf_set SLP_GC_KILL_MEMORY 1; echo "slp-gc kill-memory enabled: $GC_CONF"; fi
  # The effective value of a flag, read as slp-gc's read_config does: the last KEY=VALUE line wins,
  # \r and one pair of quotes are stripped, and the flag is on only when the value is exactly 1.
  gc_flag() {
    local line k v on=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in ''|'#'*) continue ;; esac
      k="${line%%=*}"; v="${line#*=}"
      [ "$k" != "$line" ] && [ "$k" = "$1" ] || continue
      v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
      if [ "$v" = 1 ]; then on=1; else on=0; fi
    done < "$GC_CONF"
    [ "$on" = 1 ]
  }
  GC_OPTINS=()
  gc_flag SLP_GC_APPLY && GC_OPTINS+=("apply (delete completed schedules and long-archived agents)")
  gc_flag SLP_GC_KILL_STALE && GC_OPTINS+=("kill-stale (SIGTERM proven orphaned processes)")
  gc_flag SLP_GC_KILL_MEMORY && GC_OPTINS+=("kill-memory (SIGTERM agent descendants over the memory limit)")

  # --- launchd agent
  GC_LOADED=0
  GC_LAUNCHD_NOTE="not installed (--no-gc-launchd)"
  if [ "$GC_LAUNCHD" = 1 ]; then
    xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
    GC_EXTRA=""
    if [ -n "${SLP_GC_STATE_DIR:-}" ]; then
      GC_EXTRA="
    <key>SLP_GC_STATE_DIR</key>
    <string>$(xml "$GC_STATE")</string>"
    fi
    # Values go in through the environment, so no character in a path is special to the renderer.
    GC_TPL="$(P_LABEL="$GC_LABEL" P_SLP_GC="$(xml "$GC_BIN")" P_HOME="$(xml "$HOME")" P_PATH="$(xml "$GC_PATH")" \
      P_CONFIG="$(xml "$GC_CONF")" P_LOG="$(xml "$GC_LOG")" P_EXTRA_ENV="$GC_EXTRA" \
      awk 'function sub_all(line, tok, val,   out, i) {
             out = ""
             while ((i = index(line, tok)) > 0) { out = out substr(line, 1, i - 1) val; line = substr(line, i + length(tok)) }
             return out line
           }
           { l = $0
             l = sub_all(l, "@@LABEL@@", ENVIRON["P_LABEL"]);   l = sub_all(l, "@@SLP_GC@@", ENVIRON["P_SLP_GC"])
             l = sub_all(l, "@@HOME@@", ENVIRON["P_HOME"]);     l = sub_all(l, "@@CONFIG@@", ENVIRON["P_CONFIG"])
             l = sub_all(l, "@@LOG@@", ENVIRON["P_LOG"]);       l = sub_all(l, "@@EXTRA_ENV@@", ENVIRON["P_EXTRA_ENV"])
             l = sub_all(l, "@@PATH@@", ENVIRON["P_PATH"])
             print l }' "$SRC/paseo/launchd/slp-gc.plist.in")"
    mkdir -p "$HOME/Library/LaunchAgents"
    GC_TMP="$(mktemp "$HOME/Library/LaunchAgents/.$GC_LABEL.XXXXXX")"
    printf '%s\n' "$GC_TPL" > "$GC_TMP"
    chmod 644 "$GC_TMP"
    mv -f "$GC_TMP" "$GC_PLIST"
    # launchd appends to the agent's log through this path, so it must be a regular file of ours:
    # never truncate or write through the existing name. A hard-linked one (its other name may lie
    # outside) is unlinked, an oversized one renamed aside; a fresh 0600 file is created if absent
    # (the preflight refused symlinks and special files).
    if [ -f "$GC_LOG" ]; then
      if [ "$(gc_links "$GC_LOG")" != 1 ]; then
        rm -f "$GC_LOG"
        echo "NOTE: $GC_LOG had several hard links; removed this name and started a fresh log." >&2
      elif [ "$(wc -c < "$GC_LOG")" -gt 1048576 ]; then
        rm -f "$GC_LOG.1"; mv "$GC_LOG" "$GC_LOG.1"
      fi
    fi
    if [ ! -e "$GC_LOG" ] && [ ! -L "$GC_LOG" ]; then (umask 077 && set -C && : > "$GC_LOG"); fi
    echo "Wrote launchd agent: $GC_PLIST"
    [ -z "$GC_PATH_ADDED" ] || echo "  launchd PATH extended after the system dirs with: $GC_PATH_ADDED"

    gc_resolve_launchctl
    if [ -n "$GC_SKIP" ]; then
      echo "WARNING: the launchd agent was written but NOT loaded: $GC_SKIP." >&2
      echo "  slp-gc is not running every 60 s. Load it from your own login: launchctl bootstrap gui/\$(id -u) $GC_PLIST" >&2
      GC_LAUNCHD_NOTE="NOT loaded ($GC_SKIP)"
    else
      gc_loaded() { "$LAUNCHCTL" print "$GC_DOMAIN/$GC_LABEL" </dev/null >/dev/null 2>&1; }
      BO_RC=0; BO_OUT="$("$LAUNCHCTL" bootout "$GC_DOMAIN/$GC_LABEL" </dev/null 2>&1)" || BO_RC=$?
      BO_FAILED=0
      if [ "$BO_RC" != 0 ] && [ "$BO_RC" != 3 ] && ! printf '%s' "$BO_OUT" | grep -qiE 'no such process|could not find|not found'; then
        BO_FAILED=1   # a real failure, not just "nothing was loaded"
      fi
      if [ "$BO_FAILED" = 1 ] && gc_loaded; then
        echo "WARNING: 'launchctl bootout' failed ($BO_OUT); the agent is still loaded with the PRIOR definition." >&2
        GC_LAUNCHD_NOTE="still loaded with the PRIOR definition (bootout failed: ${BO_OUT:-exit $BO_RC}); NOT reloaded"
      else
        [ "$BO_FAILED" = 0 ] || echo "WARNING: 'launchctl bootout' failed ($BO_OUT), but the agent is not loaded; continuing." >&2
        BS_RC=0; BS_OUT="$("$LAUNCHCTL" bootstrap "$GC_DOMAIN" "$GC_PLIST" </dev/null 2>&1)" || BS_RC=$?
        if [ "$BS_RC" != 0 ]; then
          if gc_loaded; then
            echo "WARNING: 'launchctl bootstrap' failed ($BS_OUT); the agent is still loaded with the PRIOR definition." >&2
            GC_LAUNCHD_NOTE="still loaded with the PRIOR definition (bootstrap failed: ${BS_OUT:-exit $BS_RC})"
          else
            echo "WARNING: could not load the agent ($BS_OUT); run: launchctl bootstrap $GC_DOMAIN $GC_PLIST" >&2
            GC_LAUNCHD_NOTE="NOT loaded (launchctl bootstrap failed: ${BS_OUT:-exit $BS_RC})"
          fi
        elif gc_loaded; then
          GC_LOADED=1; GC_LAUNCHD_NOTE="loaded ($GC_LABEL, 'slp-gc tick' every 60 s; verified with launchctl print)"
          echo "Loaded launchd agent $GC_LABEL (runs 'slp-gc tick' every 60 s)"
        else
          echo "WARNING: 'launchctl bootstrap' succeeded but 'launchctl print' cannot see $GC_LABEL." >&2
          GC_LAUNCHD_NOTE="NOT loaded (bootstrap reported success but launchctl print cannot see the agent)"
        fi
      fi
    fi
  else
    gc_existing_agent_note
  fi

  if [ "${#GC_OPTINS[@]}" -gt 0 ]; then
    if [ "$GC_LOADED" = 1 ]; then
      echo "!! slp-gc reclaims every 60 s (the safe tier is the install default); per its config it will:"
    else
      echo "!! slp-gc is configured to reclaim (it acts only while a tick runs); per its config it will:"
    fi
    for o in "${GC_OPTINS[@]}"; do echo "!!   - $o"; done
    echo "!! Back to report-only: install.sh --gc-report-only"
  else
    echo "slp-gc: report-only (nothing is deleted or killed)"
  fi
  if [ "$GC_CONF_EXISTED" = 1 ] && [ "$((GC_APPLY + GC_KILL_STALE + GC_KILL_MEM + GC_REPORT_ONLY))" = 0 ] && ! gc_flag SLP_GC_APPLY; then
    echo "slp-gc: your existing config is report-only; fresh installs now default to the safe tier. To opt in: install.sh --gc-apply --gc-kill-stale (or add --gc-only); ignore this to stay report-only"
  fi
  if [ "$GC_LOADED" = 1 ]; then echo "  launchd agent: $GC_LAUNCHD_NOTE"
  else echo "  launchd agent $GC_LAUNCHD_NOTE"; fi
  echo "  config: $GC_CONF   output: $GC_STATE"
  echo "  by hand: $GC_BIN report    (also: record, tick)"
elif [ "$NO_GC" = 1 ]; then
  gc_existing_agent_note
fi

echo "paseo-slp $VERSION installed."
