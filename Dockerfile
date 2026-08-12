# Ubuntu 24.04 の Asterisk 20 を使う。
# （Debian bookworm(12) は asterisk を収録していないため Ubuntu を使用）
FROM ubuntu:24.04

# asterisk 本体 + 標準モジュール + 既定の設定一式が入る（universe は既定で有効）
# python3 は hookflash 用の短いAGIスクリプトを動かすためだけに追加
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y asterisk python3 \
 && rm -rf /var/lib/apt/lists/*

# hookflash.py をAGIディレクトリへ配置（Debian/Ubuntu系パッケージの既定AGIパスはここ）
COPY asterisk/agi-bin/hookflash.py /usr/share/asterisk/agi-bin/hookflash.py
RUN chmod +x /usr/share/asterisk/agi-bin/hookflash.py

# コンテナではフォアグラウンド実行し、ログを docker の標準出力へ流す
#   -f : デーモン化しない（fork しない）
#   -vvv : 適度に詳しいログ
CMD ["asterisk", "-f", "-vvv"]
