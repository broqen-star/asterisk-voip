# Ubuntu 24.04 の Asterisk 20 を使う。
# （Debian bookworm(12) は asterisk を収録していないため Ubuntu を使用）
FROM ubuntu:24.04

# asterisk 本体 + 標準モジュール + 既定の設定一式が入る（universe は既定で有効）
#   tzdata          : TZ=Asia/Tokyo を効かせ、録音ファイル名の時刻を日本時間にする
#   curl/ca-certs   : Discord Webhook への HTTPS POST に使う
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y \
      asterisk tzdata curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# 不応答時の録音の保存先。compose でホストの ./recordings を rw マウントする。
# マウントし忘れてもコンテナ内に書けるよう、権限だけ用意しておく。
RUN mkdir -p /var/spool/asterisk/recordings \
 && chown asterisk:asterisk /var/spool/asterisk/recordings

# コンテナではフォアグラウンド実行し、ログを docker の標準出力へ流す
#   -f : デーモン化しない（fork しない）
#   -vvv : 適度に詳しいログ
CMD ["asterisk", "-f", "-vvv"]