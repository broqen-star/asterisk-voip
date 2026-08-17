#!/bin/bash
#==============================================================
# notify-email.sh — 留守番録音をメールで通知する
#--------------------------------------------------------------
# 呼び出し元: notify.sh（直接叩いてもテストできる）
#   引数 $1 = 録音ファイルのフルパス(.wav)
#   引数 $2 = 発信者番号(CID)
#
# 送信は curl の SMTP 機能を使う（Dockerfile に curl が入っているため
# 追加インストール不要）。MIME(multipart/mixed)は自前で組み立てる。
#
# 必要な環境変数（.env で設定）:
#   MAIL_SMTP_URL   例) smtps://smtp.gmail.com:465  /  smtp://smtp.example.com:587
#   MAIL_FROM       差出人アドレス（SMTPのエンベロープにも使う）
#   MAIL_TO         宛先。カンマ区切りで複数可
#   MAIL_USER       SMTP認証ユーザ（省略時は認証なし）
#   MAIL_PASS       SMTP認証パスワード（Gmailは「アプリパスワード」）
#   MAIL_STARTTLS   1 なら STARTTLS を要求（587番ポート用。465なら不要）
#   MAIL_FROM_NAME  差出人の表示名（既定 Asterisk 留守番電話）
#   MAIL_ATTACH     0 にすると音声を添付せず本文だけ送る（既定 1）
#   MAIL_ATTACH_MAX 添付する上限バイト数（既定 20000000 = 約20MB）
#
# ※ここで異常終了してもAsterisk本体には影響しない（TrySystemで呼ぶ）。
#==============================================================
set -u

FILE="${1:-${NOTIFY_FILE:-}}"
CID="${2:-${NOTIFY_CID:-unknown}}"

log() { logger -t mail "$*"; }

[ -f "$FILE" ] || { log "ファイルが見つかりません: $FILE"; exit 0; }

URL="${MAIL_SMTP_URL:-}"
FROM="${MAIL_FROM:-}"
TO="${MAIL_TO:-}"
[ -n "$URL" ]  || { log "MAIL_SMTP_URL が未設定のため通知しません"; exit 0; }
[ -n "$FROM" ] || { log "MAIL_FROM が未設定のため通知しません";     exit 0; }
[ -n "$TO" ]   || { log "MAIL_TO が未設定のため通知しません";       exit 0; }

# notify.sh から渡ってこない（単体テスト等）場合はここで求める
NAME="${NOTIFY_NAME:-$(basename "$FILE")}"
SIZE="${NOTIFY_SIZE:-$(stat -c%s "$FILE" 2>/dev/null || echo 0)}"
SEC="${NOTIFY_SEC:-$(( SIZE / 16000 ))}"
WHEN="${NOTIFY_WHEN:-$(date '+%Y-%m-%d %H:%M:%S')}"

FROM_NAME="${MAIL_FROM_NAME:-Asterisk 留守番電話}"
ATTACH="${MAIL_ATTACH:-1}"
ATTACH_MAX="${MAIL_ATTACH_MAX:-20000000}"

# 件名・表示名に日本語を使うので RFC2047(Bエンコード)で包む
enc_header() { printf '=?UTF-8?B?%s?=' "$(printf '%s' "$1" | base64 -w0)"; }

SUBJECT_RAW="[留守番電話] ${CID} から新しい伝言（約${SEC}秒）"
BOUNDARY="=_asterisk_$(date +%s)_$$"

BODY="留守番電話に新しい伝言が入りました。

  発信者   : ${CID}
  受信時刻 : ${WHEN}
  長さ     : 約${SEC}秒
  ファイル : ${NAME}

-- 
Asterisk (自動送信)
"

MAILFILE=$(mktemp /tmp/notify-mail.XXXXXX) || { log "一時ファイルを作成できません"; exit 0; }
trap 'rm -f "$MAILFILE"' EXIT

{
  printf 'From: %s <%s>\r\n' "$(enc_header "$FROM_NAME")" "$FROM"
  printf 'To: %s\r\n' "$TO"
  printf 'Subject: %s\r\n' "$(enc_header "$SUBJECT_RAW")"
  printf 'Date: %s\r\n' "$(date -R)"
  printf 'MIME-Version: 1.0\r\n'
  printf 'Content-Type: multipart/mixed; boundary="%s"\r\n' "$BOUNDARY"
  printf '\r\n'

  printf -- '--%s\r\n' "$BOUNDARY"
  printf 'Content-Type: text/plain; charset=UTF-8\r\n'
  printf 'Content-Transfer-Encoding: base64\r\n\r\n'
  printf '%s' "$BODY" | base64 | sed 's/$/\r/'
  printf '\r\n'
} > "$MAILFILE"

# 添付するのは「添付ONかつ上限内」のときだけ。超えたら本文のみ送る。
ATTACHED="なし"
if [ "$ATTACH" = "1" ] && [ "$SIZE" -le "$ATTACH_MAX" ]; then
  {
    printf -- '--%s\r\n' "$BOUNDARY"
    printf 'Content-Type: audio/wav; name="%s"\r\n' "$NAME"
    printf 'Content-Transfer-Encoding: base64\r\n'
    printf 'Content-Disposition: attachment; filename="%s"\r\n\r\n' "$NAME"
    base64 "$FILE" | sed 's/$/\r/'
    printf '\r\n'
  } >> "$MAILFILE"
  ATTACHED="あり"
fi

printf -- '--%s--\r\n' "$BOUNDARY" >> "$MAILFILE"

# 宛先はカンマ区切り。エンベロープには1件ずつ --mail-rcpt で渡す
CURL_ARGS=(-sS -m 120 --url "$URL" --mail-from "$FROM" --upload-file "$MAILFILE")
OLDIFS="$IFS"; IFS=','
for addr in $TO; do
  addr="$(printf '%s' "$addr" | tr -d '[:space:]')"
  [ -n "$addr" ] && CURL_ARGS+=(--mail-rcpt "$addr")
done
IFS="$OLDIFS"

[ -n "${MAIL_USER:-}" ] && CURL_ARGS+=(--user "${MAIL_USER}:${MAIL_PASS:-}")
[ "${MAIL_STARTTLS:-0}" = "1" ] && CURL_ARGS+=(--ssl-reqd)

if ERR=$(curl "${CURL_ARGS[@]}" 2>&1 >/dev/null); then
  log "メール通知しました(添付${ATTACHED}): $NAME → $TO"
else
  log "メール通知に失敗しました: $NAME : ${ERR:-unknown error}"
fi
