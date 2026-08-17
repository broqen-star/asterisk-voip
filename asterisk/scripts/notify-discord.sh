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
# ※ここで異常終了してもAsterisk本体には影響しない（TrySystemで呼ぶ）。
#   ログは logger 経由でコンテナの標準出力に出る。
#==============================================================
set -u

FILE="${1:-${NOTIFY_FILE:-}}"
CID="${2:-${NOTIFY_CID:-unknown}}"
URL="${DISCORD_WEBHOOK_URL:-}"

log() { logger -t discord "$*"; }

[ -n "$URL" ]  || { log "DISCORD_WEBHOOK_URL が未設定のため通知しません"; exit 0; }
[ -f "$FILE" ] || { log "ファイルが見つかりません: $FILE"; exit 0; }

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
  if curl -sS -m 30 -F "payload_json=$PAYLOAD" -F "file1=@${FILE}" "$URL" >/dev/null 2>&1; then
    log "通知しました(音声付き): $NAME"
  else
    log "通知に失敗しました: $NAME"
  fi
else
  if curl -sS -m 30 -H "Content-Type: application/json" -d "$PAYLOAD" "$URL" >/dev/null 2>&1; then
    log "通知しました(本文のみ・サイズ超過): $NAME"
  else
    log "通知に失敗しました: $NAME"
  fi
fi