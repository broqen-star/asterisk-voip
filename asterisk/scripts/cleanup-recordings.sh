#!/bin/sh
#==============================================================
# cleanup-recordings.sh — 古い録音を定期的に削除する
#--------------------------------------------------------------
# docker-compose の cleanup サービスから起動され、常駐して
# CLEAN_INTERVAL 秒ごとに RETENTION_DAYS 日より古い .wav を消す。
#
# 環境変数:
#   REC_DIR        削除対象ディレクトリ      (既定 /recordings)
#   RETENTION_DAYS 保存日数。これより古いと削除 (既定 30)
#   CLEAN_INTERVAL 実行間隔[秒]             (既定 86400 = 24時間)
#   DRY_RUN        1 なら消さずに一覧表示だけ (既定 0)
#   RUN_ONCE       1 なら1回だけ実行して終了  (既定 0)
#
# ※ busybox(sh) でも動くよう -delete は使わず rm で消す
#==============================================================
set -u

DIR="${REC_DIR:-/recordings}"
DAYS="${RETENTION_DAYS:-30}"
INTERVAL="${CLEAN_INTERVAL:-86400}"
DRY_RUN="${DRY_RUN:-0}"
RUN_ONCE="${RUN_ONCE:-0}"

log() { echo "[cleanup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# 数値以外が入っていたら全消ししかねないので、必ず検査してから使う
case "$DAYS" in
  ''|*[!0-9]*) log "RETENTION_DAYS が不正です($DAYS)。処理を中止します"; exit 1 ;;
esac
if [ "$DAYS" -lt 1 ]; then
  log "RETENTION_DAYS は1以上にしてください($DAYS)。処理を中止します"; exit 1
fi

clean_once() {
  if [ ! -d "$DIR" ]; then
    log "ディレクトリがありません: $DIR"
    return 0
  fi

  # 対象を一覧化。マイナス指定 +N は「N日より古い」の意味
  LIST=$(find "$DIR" -maxdepth 1 -type f -name '*.wav' -mtime +"$DAYS" 2>/dev/null)

  if [ -z "$LIST" ]; then
    log "削除対象なし (${DAYS}日より古い録音は見つかりませんでした)"
    return 0
  fi

  COUNT=$(printf '%s\n' "$LIST" | wc -l | tr -d ' ')

  if [ "$DRY_RUN" = "1" ]; then
    log "[DRY_RUN] 以下の ${COUNT} 件が削除対象です(実際には消しません):"
    printf '%s\n' "$LIST" | sed 's/^/  /'
    return 0
  fi

  printf '%s\n' "$LIST" | while IFS= read -r f; do
    [ -n "$f" ] || continue
    if rm -f "$f"; then
      log "削除: $f"
    else
      log "削除失敗: $f"
    fi
  done
  log "${DAYS}日より古い録音 ${COUNT} 件を削除しました"
}

log "起動: dir=$DIR 保存日数=${DAYS}日 実行間隔=${INTERVAL}秒 dry_run=$DRY_RUN"

while :; do
  clean_once
  [ "$RUN_ONCE" = "1" ] && break
  sleep "$INTERVAL"
done