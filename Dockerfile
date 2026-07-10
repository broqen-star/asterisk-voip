# Ubuntu 24.04 の Asterisk 20 を使う。
# （Debian bookworm(12) は asterisk を収録していないため Ubuntu を使用）
FROM ubuntu:24.04

# asterisk 本体 + 標準モジュール + 既定の設定一式が入る（universe は既定で有効）
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y asterisk \
 && rm -rf /var/lib/apt/lists/*

# コンテナではフォアグラウンド実行し、ログを docker の標準出力へ流す
#   -f : デーモン化しない（fork しない）
#   -vvv : 適度に詳しいログ
CMD ["asterisk", "-f", "-vvv"]
