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
#   MAIL_DEBUG      1 で curl の通信内容(-v)もログに残す（原因調査用）
#
# TLS証明書まわり（curl終了コード60が出るときに使う）:
#   MAIL_CAINFO         社内CA/自己署名の証明書ファイル(PEM)のパス。
#                       これを指定するのが正攻法。compose でマウントして渡す。
#   MAIL_TLS_INSECURE   1 で証明書の検証を省略する。中身は暗号化されるが
#                       「相手が本物か」を確認しないため、LAN内の自社サーバ
#                       限定の応急処置とすること。
#   MAIL_RESOLVE        「証明書の名前ではDNSが引けない」ときの逃げ道。
#                       ホスト:ポート:IP の形式で接続先IPを固定する。
#                       例) MAIL_RESOLVE=ms01.pxbb.jp:587:157.101.128.132
#                       この場合 MAIL_SMTP_URL 側も同じホスト名にすること。
#                       証明書は正しい名前で検証されるので TLS_INSECURE より安全。
#
# 成功/失敗は必ずログに残す。失敗時は curl のエラー文をそのまま出す。
#==============================================================
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_TAG="mail"
. "$SCRIPT_DIR/notify-lib.sh"

FILE="${1:-${NOTIFY_FILE:-}}"
CID="${2:-${NOTIFY_CID:-unknown}}"

[ -f "$FILE" ] || { log "未送信: ファイルが見つかりません: $FILE"; exit 0; }

URL="${MAIL_SMTP_URL:-}"
FROM="${MAIL_FROM:-}"
TO="${MAIL_TO:-}"
[ -n "$URL" ]  || { log "未送信: MAIL_SMTP_URL が未設定です"; exit 0; }
[ -n "$FROM" ] || { log "未送信: MAIL_FROM が未設定です";     exit 0; }
[ -n "$TO" ]   || { log "未送信: MAIL_TO が未設定です";       exit 0; }

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

MAILFILE=$(mktemp /tmp/notify-mail.XXXXXX) || { log "未送信: 一時ファイルを作成できません"; exit 1; }
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
RCPT_LIST=""
OLDIFS="$IFS"; IFS=','
for addr in $TO; do
  addr="$(printf '%s' "$addr" | tr -d '[:space:]')"
  if [ -n "$addr" ]; then
    CURL_ARGS+=(--mail-rcpt "$addr")
    RCPT_LIST="${RCPT_LIST}${RCPT_LIST:+,}${addr}"
  fi
done
IFS="$OLDIFS"

[ -n "${MAIL_USER:-}" ] && CURL_ARGS+=(--user "${MAIL_USER}:${MAIL_PASS:-}")
[ "${MAIL_STARTTLS:-0}" = "1" ] && CURL_ARGS+=(--ssl-reqd)
[ "${MAIL_DEBUG:-0}" = "1" ] && CURL_ARGS+=(-v)

# TLS: 社内CAを指定するのが正攻法。無理な場合だけ検証を外す。
TLS_NOTE=""
if [ -n "${MAIL_CAINFO:-}" ]; then
  if [ -f "$MAIL_CAINFO" ]; then
    CURL_ARGS+=(--cacert "$MAIL_CAINFO")
    TLS_NOTE=" ca=${MAIL_CAINFO}"
  else
    log "警告: MAIL_CAINFO のファイルがありません: ${MAIL_CAINFO}（指定を無視します）"
  fi
fi
if [ "${MAIL_TLS_INSECURE:-0}" = "1" ]; then
  CURL_ARGS+=(--insecure)
  TLS_NOTE="${TLS_NOTE} 証明書検証=なし"
fi

# DNSに載っていないホスト名を、証明書の検証はそのままにIP直結で解決させる
if [ -n "${MAIL_RESOLVE:-}" ]; then
  CURL_ARGS+=(--resolve "$MAIL_RESOLVE")
  TLS_NOTE="${TLS_NOTE} resolve=${MAIL_RESOLVE}"
fi

log "送信: server=${URL} from=${FROM} to=${RCPT_LIST} 添付=${ATTACHED} size=${SIZE}bytes${TLS_NOTE}"

ERR=$(curl "${CURL_ARGS[@]}" 2>&1 >/dev/null)
RC=$?

if [ "$RC" = "0" ]; then
  log "成功: 添付${ATTACHED}: $NAME → ${RCPT_LIST}"
  # -v を付けたときだけ通信内容も残す（パスワードは出力されない）
  [ "${MAIL_DEBUG:-0}" = "1" ] && [ -n "$ERR" ] && log "詳細: $(printf '%s' "$ERR" | tr '\n' '|' | cut -c1-1000)"
else
  # curl の終了コードは原因の切り分けに直結するので日本語を添える
  case "$RC" in
    6)  HINT="SMTPサーバのホスト名を解決できない（MAIL_SMTP_URL のホスト名を確認。証明書に合わせた名前がDNSに無い場合は MAIL_RESOLVE でIPを指定する）" ;;
    7)  HINT="SMTPサーバに接続できない（ポート/ファイアウォールを確認）" ;;
    28) HINT="タイムアウト（サーバ到達不可、または応答が遅い）" ;;
    35) HINT="TLSハンドシェイク失敗（ポートとスキームの対応を確認。587なら smtp:// + MAIL_STARTTLS=1、465なら smtps://）" ;;
    51|60) HINT="サーバ証明書を検証できない。社内CA/自己署名なら MAIL_CAINFO にCA証明書を指定する（応急処置は MAIL_TLS_INSECURE=1）" ;;
    67) HINT="SMTP認証に失敗（MAIL_USER / MAIL_PASS を確認。Gmailはアプリパスワード）" ;;
    55|56) HINT="送受信エラー（接続が途中で切れた。添付サイズ上限の可能性）" ;;
    *)  HINT="" ;;
  esac
  # 肝心のエラー文は出力の「末尾」に出るため、先頭ではなく末尾を残す
  DETAIL=$(printf '%s' "${ERR:-なし}" | tr '\n' '|' | tail -c 600)
  log "失敗: curl終了コード=${RC}${HINT:+ (${HINT})}: $NAME"
  log "失敗の詳細: ${DETAIL}"
  exit 1
fi

exit 0
