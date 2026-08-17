#!/bin/bash
#==============================================================
# notify-discord.sh — 留守番録音をDiscordへ通知する
#--------------------------------------------------------------
# 呼び出し元: notify.sh（直接叩いてもテストできる）
#   引数 $1 = 録音ファイルのフルパス(.wav)
#   引数 $2 = 発信者番号(CID)
# Webhook URL は環境変数 DISCORD_WEBHOOK_URL から取る(.env で設定)
#
# 送るかどうかの共通判定（短すぎる録音の除外など）は notify.sh 側で
# 済んでいる。ここは Discord への送信だけを担当する。
#
# 成功/失敗は必ずログに残す。失敗時は curl のエラーとHTTPステータスも
# 出すので、原因（URL間違い・レート制限・サイズ超過）を切り分けられる。
#==============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_TAG="discord"
. "$SCRIPT_DIR/notify-lib.sh"

FILE="${1:-${NOTIFY_FILE:-}}"
CID="${2:-${NOTIFY_CID:-unknown}}"
URL="${DISCORD_WEBHOOK_URL:-}"

[ -n "$URL" ]  || { log "未送信: DISCORD_WEBHOOK_URL が未設定です"; exit 0; }
[ -f "$FILE" ] || { log "未送信: ファイルが見つかりません: $FILE"; exit 0; }

# notify.sh から渡ってこない（単体テスト等）場合はここで求める
NAME="${NOTIFY_NAME:-$(basename "$FILE")}"
SIZE="${NOTIFY_SIZE:-$(stat -c%s "$FILE" 2>/dev/null || echo 0)}"
SEC="${NOTIFY_SEC:-$(( SIZE / 16000 ))}"   # 8kHz/16bit モノラル想定のおおよその秒数
WHEN="${NOTIFY_WHEN:-$(date '+%Y-%m-%d %H:%M:%S')}"

# JSONに入れる値なので、番号以外の文字が混ざっても壊れないよう落としておく
CID_SAFE=$(printf '%s' "$CID" | tr -cd '0-9a-zA-Z_-')
[ -n "$CID_SAFE" ] || CID_SAFE="unknown"

PAYLOAD=$(printf '{"embeds":[{"title":"☎️ 留守番電話に新しい伝言","color":2984943,"fields":[{"name":"＜発信者＞","value":"%s"},{"name":"＜受信時刻＞","value":"%s"},{"name":"＜長さ＞","value":"約%s秒"}],"footer":{"text":"%s"}}]}' \
  "$CID_SAFE" "$WHEN" "$SEC" "$NAME")

# Discordの添付上限に収まる場合だけ音声を付ける。超えたら本文だけ送る。
if [ "$SIZE" -lt 9000000 ]; then
  MODE="音声付き"
  RESP=$(curl -sS -m 30 -w '\n%{http_code}' \
    -F "payload_json=$PAYLOAD" -F "file1=@${FILE}" "$URL" 2>&1)
  RC=$?
else
  MODE="本文のみ・サイズ超過"
  RESP=$(curl -sS -m 30 -w '\n%{http_code}' \
    -H "Content-Type: application/json" -d "$PAYLOAD" "$URL" 2>&1)
  RC=$?
fi

CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d' | tr -d '\n' | cut -c1-300)

log "送信: ${MODE} file=${NAME} size=${SIZE}bytes"

# 2xx なら成功。それ以外は理由をそのまま残す。
case "$CODE" in
  2*) log "成功: HTTP ${CODE} (${MODE}): $NAME"; exit 0 ;;
  *)  log "失敗: HTTP ${CODE:-なし} curl終了コード=${RC} 応答=${BODY:-なし}: $NAME"; exit 1 ;;
esac
