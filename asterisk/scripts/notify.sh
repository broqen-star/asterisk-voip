#!/bin/bash
#==============================================================
# notify.sh — 留守番録音の通知を振り分ける（Discord / メール）
#--------------------------------------------------------------
# 呼び出し元: extensions.conf の h エクステンション
#   引数 $1 = 録音ファイルのフルパス(.wav)
#   引数 $2 = 発信者番号(CID)
#
# 動作確認用:
#   bash notify.sh --test        … 手元の音声ファイルでテスト送信する
#
# どこへ通知するかは .env の以下で切り替える（1=送る / 0=送らない）:
#   NOTIFY_DISCORD=1
#   NOTIFY_EMAIL=1
# 両方 1 なら両方に飛ぶ。両方 0 なら何もしない。
#
# ログは /var/spool/asterisk/recordings/notify.log に必ず残る
# （ホストからは ./recordings/notify.log）。詳細は notify-lib.sh 参照。
#==============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_TAG="notify"
. "$SCRIPT_DIR/notify-lib.sh"

FILE="${1:-}"
CID="${2:-unknown}"

# 1/yes/true/on を「有効」とみなす（大文字小文字は問わない）
enabled() {
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    1|yes|true|on) return 0 ;;
    *)             return 1 ;;
  esac
}

#--------------------------------------------------------------
# テストモード: 着信を待たずに通知経路だけを試す
#--------------------------------------------------------------
if [ "$FILE" = "--test" ]; then
  CID="${2:-0000}"
  # 最新の録音 → 無ければ案内音声 の順に、通知に使えるファイルを探す
  FILE=$(ls -t /var/spool/asterisk/recordings/*.wav 2>/dev/null | head -1)
  [ -n "$FILE" ] || FILE=/usr/share/asterisk/sounds/en/custom/rec_guidance.wav
  log "=== テストモード: $FILE を使って通知します ==="
fi

log "通知処理を開始: file=${FILE:-（なし）} cid=${CID} discord=${NOTIFY_DISCORD:-1} email=${NOTIFY_EMAIL:-0}"

if [ ! -f "$FILE" ]; then
  log "中止: ファイルが見つかりません: $FILE"
  exit 0
fi

# 短すぎる録音は「ビープ直後に切られた」「ノイズを拾っただけ」とみなして通知しない。
# ※通知を止めるだけで、ファイル自体は残る（./recordings や内線202で確認できる）。
#
# しきい値は秒で指定する。バイト数への換算は 8kHz/16bit モノラル = 16000バイト/秒。
# NOTIFY_MIN_BYTES を明示した場合はそちらを優先する（従来設定との互換用）。
MIN_SEC="${NOTIFY_MIN_SEC:-3}"
case "$MIN_SEC" in
  ''|*[!0-9]*) log "警告: NOTIFY_MIN_SEC が不正です(${MIN_SEC})。3秒として扱います"; MIN_SEC=3 ;;
esac
MIN_BYTES="${NOTIFY_MIN_BYTES:-$(( MIN_SEC * 16000 ))}"

SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
  log "中止: 録音が短すぎます(約$(( SIZE / 16000 ))秒 / ${SIZE}bytes < ${MIN_BYTES}bytes = ${MIN_SEC}秒): $FILE"
  log "      ファイルは残っています: $FILE"
  exit 0
fi

# 通知本文に入れる値なので、番号以外の文字が混ざっても壊れないよう落としておく
CID_SAFE=$(printf '%s' "$CID" | tr -cd '0-9a-zA-Z_-')
[ -n "$CID_SAFE" ] || CID_SAFE="unknown"

# 各通知スクリプトが共通で使う値
export NOTIFY_FILE="$FILE"
export NOTIFY_NAME="$(basename "$FILE")"
export NOTIFY_SIZE="$SIZE"
export NOTIFY_SEC="$(( SIZE / 16000 ))"   # 8kHz/16bit モノラル想定のおおよその秒数
export NOTIFY_WHEN="$(date '+%Y-%m-%d %H:%M:%S')"
export NOTIFY_CID="$CID_SAFE"
export NOTIFY_LOG NOTIFY_LOG_MAX

ANY=0
FAIL=0

if enabled "${NOTIFY_DISCORD:-1}"; then
  ANY=1
  bash "$SCRIPT_DIR/notify-discord.sh" "$FILE" "$CID_SAFE" || FAIL=1
else
  log "Discordはオフのためスキップ (NOTIFY_DISCORD=${NOTIFY_DISCORD:-1})"
fi

if enabled "${NOTIFY_EMAIL:-0}"; then
  ANY=1
  bash "$SCRIPT_DIR/notify-email.sh" "$FILE" "$CID_SAFE" || FAIL=1
else
  log "メールはオフのためスキップ (NOTIFY_EMAIL=${NOTIFY_EMAIL:-0})"
fi

if [ "$ANY" = "0" ]; then
  log "通知先がすべてオフのため送信しません: $NOTIFY_NAME"
elif [ "$FAIL" = "1" ]; then
  log "通知処理を終了（失敗を含む）: $NOTIFY_NAME"
else
  log "通知処理を正常終了: $NOTIFY_NAME"
fi
exit 0
