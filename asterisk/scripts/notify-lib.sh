#!/bin/bash
#==============================================================
# notify-lib.sh — 通知スクリプト共通のログ処理
#--------------------------------------------------------------
# 各 notify*.sh から source して使う。
#
# ログの出力先は3か所（可能なものすべてに書く）:
#   1) ログファイル  … 既定 /var/spool/asterisk/recordings/notify.log
#                      ホストからは ./recordings/notify.log で読める。
#                      ※これが確実に残る。まずここを見ること。
#   2) 標準出力      … Asterisk のstdoutを継承するので docker compose logs に出る
#   3) syslog        … /dev/log がある環境のときだけ（コンテナには通常無い）
#
# 以前は logger(syslog) だけに書いていたが、コンテナ内には syslog が
# 存在しないため出力が消えていた。その対策としてファイル出力を追加。
#
# 環境変数:
#   NOTIFY_LOG      ログファイルのパス（既定は上記）
#   NOTIFY_LOG_MAX  このバイト数を超えたら .1 に退避（既定 1MB）
#   NOTIFY_TAG      ログ行に付く種別名（各スクリプトで設定）
#==============================================================

NOTIFY_LOG="${NOTIFY_LOG:-/var/spool/asterisk/recordings/notify.log}"
NOTIFY_LOG_MAX="${NOTIFY_LOG_MAX:-1048576}"
NOTIFY_TAG="${NOTIFY_TAG:-notify}"

_LOG_READY=""

_init_log() {
  [ -n "$_LOG_READY" ] && return 0
  if ( : >> "$NOTIFY_LOG" ) 2>/dev/null; then
    _LOG_READY=1
    # 肥大化防止。世代は1つだけ残す
    SZ=$(stat -c%s "$NOTIFY_LOG" 2>/dev/null || echo 0)
    if [ "$SZ" -gt "$NOTIFY_LOG_MAX" ]; then
      mv -f "$NOTIFY_LOG" "${NOTIFY_LOG}.1" 2>/dev/null && : > "$NOTIFY_LOG"
    fi
  else
    _LOG_READY=0
  fi
  return 0
}

log() {
  _init_log
  LINE="$(date '+%Y-%m-%d %H:%M:%S') [${NOTIFY_TAG}] $*"
  echo "$LINE"
  [ "$_LOG_READY" = "1" ] && echo "$LINE" >> "$NOTIFY_LOG"
  if [ -S /dev/log ] && command -v logger >/dev/null 2>&1; then
    logger -t "$NOTIFY_TAG" "$*" 2>/dev/null
  fi
  return 0
}
