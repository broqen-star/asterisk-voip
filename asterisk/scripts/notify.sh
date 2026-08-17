#!/bin/bash
#==============================================================
# notify.sh — 留守番録音の通知を振り分ける（Discord / メール）
#--------------------------------------------------------------
# 呼び出し元: extensions.conf の h エクステンション
#   引数 $1 = 録音ファイルのフルパス(.wav)
#   引数 $2 = 発信者番号(CID)
#
# どこへ通知するかは .env の以下で切り替える（1=送る / 0=送らない）:
#   NOTIFY_DISCORD=1
#   NOTIFY_EMAIL=1
# 両方 1 なら両方に飛ぶ。両方 0 なら何もしない。
#
# 「送るかどうか」の共通判定（ファイル有無・短すぎる録音の除外・
# CIDの無害化・長さ計算）はここで一度だけ行い、結果を環境変数で
# 各通知スクリプトへ渡す。個別スクリプトは送信だけに専念する。
#==============================================================
set -u

FILE="${1:-}"
CID="${2:-unknown}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { logger -t notify "$*"; }

# 1/yes/true/on を「有効」とみなす（大文字小文字は問わない）
enabled() {
  case "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')" in
    1|yes|true|on) return 0 ;;
    *)             return 1 ;;
  esac
}

[ -f "$FILE" ] || { log "ファイルが見つかりません: $FILE"; exit 0; }

# 8KB未満(=約0.5秒未満)は、無言のまま切られたものとみなして通知しない
MIN_BYTES="${NOTIFY_MIN_BYTES:-8192}"
SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)
if [ "$SIZE" -lt "$MIN_BYTES" ]; then
  log "録音が短すぎるため通知しません(${SIZE}bytes): $FILE"
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

ANY=0

if enabled "${NOTIFY_DISCORD:-1}"; then
  ANY=1
  bash "$SCRIPT_DIR/notify-discord.sh" "$FILE" "$CID_SAFE"
fi

if enabled "${NOTIFY_EMAIL:-0}"; then
  ANY=1
  bash "$SCRIPT_DIR/notify-email.sh" "$FILE" "$CID_SAFE"
fi

[ "$ANY" = "1" ] || log "通知先がすべてオフのため送信しません: $NOTIFY_NAME"
