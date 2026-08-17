# 既存PBX内線 ↔ IP子機 連携構成（Docker + Asterisk + HT813）

既存PBXのアナログ内線1本を、HT813(FXO)経由でAsteriskに取り込み、
スマホ(Linphone)やPC・ラズパイから **着信を受け、発信もできる**ようにする一式です。
既存のPBX・ナースコール・非常用電話には一切触れず、IP子機を「足す」構成。

構成: `PBX内線 ↔ HT813(FXO) ↔ Asterisk(このDocker) ↔ Linphone/PC/ラズパイ`

できること（実機で動作確認済み）:
- 既存内線番号あての着信を Linphone/PC で受ける
- Linphone から既存内線（例 5xxx / 8xxx）へ発信
- Linphone から外線へ発信（PBXの 0発信 仕様に対応）
- 通話終了の検出（PBXの話中音検出で切断）

> この一式は **Ubuntu 24.04 の Asterisk 20.6** で検証済みです（endpoint 2つ・
> 着信ルーティング・UDP5060 の展開、および HT813 からの登録受付が通ることを確認済み）。
> ※ Debian bookworm は asterisk を収録していないため、ベースは Ubuntu を使用しています。

---

## 0. 前提

- サーバ機に **Docker** と **docker compose** が入っていること
  （`docker --version` と `docker compose version` が通ればOK）
- サーバ・HT813・スマホが **同じLAN**（同じルータ配下）にいること
- サーバのLAN内IPアドレスを控えておく（例では `192.168.1.50` とする）
  - 確認: `ip a`（Linux）/ ルータの端末一覧 など
  - できれば **DHCP固定** にしておくと後がラク

## ファイル構成

```
asterisk-voip/
├── docker-compose.yml
├── Dockerfile
├── README.md
└── asterisk/
    ├── pjsip.conf        ← 内線の定義（★パスワードを変更）
    ├── extensions.conf   ← 着信の流れ
    └── rtp.conf          ← 音声ポート範囲
```

---

## 1. パスワードを変更する（必須）

`asterisk/pjsip.conf` を開き、2か所の `password=` を自分の値に変えます。

- `phone-auth` の `password` … スマホ/ラズパイ側で使う
- `ht813-auth` の `password` … **HT813本体にも同じ値**を設定する

推し。適当な強いパスワードを作るなら:

```bash
openssl rand -base64 18
```

## 2. ビルドして起動

```bash
cd asterisk-voip
docker compose up -d --build
```

## 3. 起動確認

```bash
# ログを見る（Ctrl+Cで抜ける。コンテナは動き続けます）
docker compose logs -f

# Asterisk のコンソールに入る
docker exec -it asterisk asterisk -rvvv
```

コンソールで内線が見えればOK:

```
pjsip show endpoints        ; ht813 と phone が出る（まだ Unavailable でよい）
pjsip show aors
dialplan show from-pstn     ; 着信ルートの確認
```

抜けるときはコンソールで `quit`（コンテナは止まりません）。

---

## 4. HT813 の設定（FXO側）

HT813のLAN側IPをbrowserで開いて管理画面へ（初期は本体のIPをルータで確認）。
**要点だけ**。項目名はファーム版で多少違います。

### アカウント（Asteriskへ登録）
- Primary SIP Server: `192.168.1.50`（サーバのIP）
- SIP Transport: UDP / Port 5060
- SIP User ID / Authenticate ID: `ht813`
- Authenticate Password: pjsip.conf の `ht813-auth` に設定した値
- Register: **Yes**

### 配線
- **HT813 の「LINE」(FXO)** に、PBXの内線モジュラージャックを挿す
- 「PHONE」(FXS)は今回未使用

### 外線着信をSIPへ流す（ここが肝）
- **Number of Rings**: 1〜2（PSTNが何回鳴ったらHT813が応答するか）※FXO PORTタブ
- **Stage Method (1/2)**: `1`（FXO PORT → Channel Dialing。既定が2の版あり）
- **Wait for Dial Tone**: No（同上）
- **PSTN Ring Thru FXS**: No（FXO PORTタブ）
- 優先コーデック: PCMU / PCMA（= ulaw / alaw）（FXO PORTタブ Preferred Vocoder）
- **Unconditional Call Forward to VOIP**: `200`
  - ★注意: この項目は **FXO PORTタブではなく「BASIC SETTINGS」タブの最下部** にあります
    （User ID=`200` / Sip Server=サーバのIP / Port=`5060`）
  - なお extensions.conf 側で「どんな番号でも内線200を鳴らす」ようにしてあるため、
    ここが空でも着信は成立します（入れておくと意図が明確）

### 切断検出（FXO最大の難所。最初はデフォルトで着信を成立させ、後で詰める）
症状: 相手が切っても通話が切れ残る（無音のまま繋がりっぱなし）。
FXO PORTタブの **FXO Termination** で、効きやすい順に **1つずつ試す**:

1. **PSTN Disconnect Tone Detection = Yes**（話中音検出）★本環境で有効だった方法
   - PSTN Disconnect Tone を **日本の話中音**に: `f1=400@-32,c=500/500;`
     （既定 `f1=480@-32,f2=620@-32,c=500/500;` は米国向け）
   - PBX側の設定変更が不要なのが利点。この構成のNEC PBXではこれで解決。
2. **Enable Polarity Reversal = Yes**（極性反転）
   - PBXが切断時に極性反転を出す場合に劇的に効く。出さない設定だと無効。
     保守業者に「アナログ内線で極性反転を出せるか」を確認できると確実。
3. **Enable Current Disconnect** + **Threshold(ms)**（電流断/CPC）
   - 既定Yes。PBXがCPCを出していれば有効。しきい値を100→数百msで調整。

安全網: どの検出も完璧にならない場合に備え、Asterisk側の Dial に通話上限
`L(3600000)`（60分）を付けておくと、切れ残りの被害を必ず有限化できる
（extensions.conf の外線発信のコメント参照）。

---

## 5. スマホ（Linphone）の設定

無料の **Linphone** をインストールして、SIPアカウントを手動追加:

- Username: `phone`
- Password: pjsip.conf の `phone-auth` に設定した値
- Domain / SIP Proxy: `192.168.1.50`（サーバのIP。必要なら `:5060`）
- Transport: UDP

登録に成功すると、Asteriskコンソールの `pjsip show contacts` に出てきます。

> ラズパイでも受けたい場合は、baresip 等で同じ `phone` /
> 同じパスワードで登録すれば、同じ内線が両方で一斉に鳴ります
> （`phone-aor` は max_contacts=3）。

---

## 6. テスト（着信）

1. **内線テスト**: Linphoneから `200` に発信 → 自分が鳴ればSIP経路OK
2. **外線着信テスト**: その内線番号あてに携帯などから電話 → Linphoneが鳴れば成功
3. 通話を切ってみて、**ちゃんと切れるか**を確認（切れ残るなら 4-切断検出 へ）

---

## 7. Linphoneから発信する（既存内線・外線）

着信が動いたら、発信も同じ経路の逆向き（Linphone→Asterisk→HT813→PBX）で可能。
発信は `context=from-internal` に入るので、extensions.conf の `[from-internal]` に
番号パターンを書く。**自分のPBXの内線番号体系に合わせる**のが必須。

本構成の例（内線は 5xxx / 8xxx の4桁、外線は 0発信）:
```ini
[from-internal]
exten => _5XXX,1,Dial(PJSIP/${EXTEN}@ht813,30)   ; 5000-5999 の内線
 same => n,Hangup()
exten => _8XXX,1,Dial(PJSIP/${EXTEN}@ht813,30)   ; 8000-8999 の内線
 same => n,Hangup()
exten => _0X.,1,Dial(PJSIP/${EXTEN}@ht813,60)    ; 0発信の外線
 same => n,Hangup()
```
反映: `docker exec asterisk asterisk -rx "dialplan reload"`

使い方: Linphoneから **相手番号をそのままダイヤル**（例 `5105`）。プレフィックス不要。
ログで `Executing [5105@from-internal]` → `Dial(PJSIP/5105@ht813)` が出て相手が鳴ればOK。

発信でつまずく典型と対処:
- **番号がダイヤルプランに入らない**（`No matching extension`）→ パターンが桁/先頭数字に
  合っていない。`dialplan show from-internal` で確認し `_5XXX` 等を実態に合わせる。
- **番号の頭が欠ける/違う番号にかかる** → FXO PORTの
  `Min Delay Before Dial PSTN Number` を伸ばす、`Wait for Dial-Tone`/`Stage Method` 調整。
- **外線で0の後が続かない** → `Dial(PJSIP/0w${EXTEN:1}@ht813,60)` の様に `w`（ポーズ）挿入。
- **繋がるが無音/片通話** → RTP（ufwの 10000:20000）と `network_mode: host` を確認。

---

## 8. 不応答時の伝言通知（Discord / メール）

内線200が `RING_TIMEOUT` 秒以内に出ないと、案内を流して伝言を録音し、
録音があれば通知が飛ぶ。通知先は **Discord とメールを個別にオン/オフ**できる。

設定は `.env`（`.env.sample` をコピーして作る）で行う:

```
cp .env.sample .env
```

### オン/オフの切り替え

```
NOTIFY_DISCORD=1     # 1=Discordへ送る / 0=送らない
NOTIFY_EMAIL=1       # 1=メールで送る / 0=送らない
```

両方 `1` なら両方に届く。両方 `0` なら録音だけ残り通知はしない。
変更後は `docker compose up -d`（`.env` は起動時に読まれるため再起動が必要）。

### Discord の設定

```
DISCORD_WEBHOOK_URL=https://discord.com/api/webhooks/【ID】/【トークン】
```

Discordのチャンネル設定 → 連携サービス → ウェブフック で発行する。
**URLを知っている人は誰でも投稿できる**ので、`.env` ごと外部に出さないこと。

### メールの設定

```
MAIL_SMTP_URL=smtps://smtp.gmail.com:465   # 587番なら smtp://... + MAIL_STARTTLS=1
MAIL_STARTTLS=0
MAIL_FROM=voip-notify@example.com
MAIL_TO=you@example.com                    # カンマ区切りで複数可
MAIL_USER=voip-notify@example.com          # 認証不要なサーバなら空でよい
MAIL_PASS=【パスワード】
MAIL_ATTACH=1                              # 0 にすると本文だけ（音声を添付しない）
```

ポートと URL スキームの対応:

| ポート | MAIL_SMTP_URL | MAIL_STARTTLS |
| --- | --- | --- |
| 465（SMTPS） | `smtps://ホスト:465` | `0` |
| 587（STARTTLS） | `smtp://ホスト:587` | `1` |

> **Gmail を使う場合**: 2段階認証を有効にしたうえで「アプリ パスワード」を発行し、
> `MAIL_PASS` にはそれを入れる。通常のログインパスワードでは弾かれる。

送信は curl の SMTP 機能を使うので、追加インストールは不要。

### 送信ログの確認

通知の実行結果は **`./recordings/notify.log`** に残る。

```
tail -f recordings/notify.log
```

出力例（成功時）:

```
2026-08-17 09:12:03 [notify] 通知処理を開始: file=/var/spool/asterisk/recordings/20260817-091150_5105.wav cid=5105 discord=1 email=1
2026-08-17 09:12:03 [discord] 送信: 音声付き file=20260817-091150_5105.wav size=182008bytes
2026-08-17 09:12:04 [discord] 成功: HTTP 204 (音声付き): 20260817-091150_5105.wav
2026-08-17 09:12:04 [mail] 送信: server=smtps://smtp.gmail.com:465 from=... to=... 添付=あり size=182008bytes
2026-08-17 09:12:07 [mail] 成功: 添付あり: 20260817-091150_5105.wav → you@example.com
2026-08-17 09:12:07 [notify] 通知処理を正常終了: 20260817-091150_5105.wav
```

失敗時は理由がそのまま出る:

```
[discord] 失敗: HTTP 401 curl終了コード=22 応答={"message":"Invalid Webhook Token"...}
[mail] 失敗: curl終了コード=67 内容=... Authentication failed ...
```

同じ内容はコンテナの標準出力にも流れるので、こちらでも追える:

```
docker compose logs -f asterisk | grep -E '\[notify\]|\[discord\]|\[mail\]'
```

> **補足**: 以前は `logger`（syslog）にだけ書いていたが、コンテナ内に syslog が
> 存在しないためログが消えていた。現在はファイルと標準出力の両方に出す。
> 出力先は `NOTIFY_LOG` で変更でき、1MBを超えると `notify.log.1` に退避される。

### 動作確認

電話をかけずに通知経路だけを試せる。`.env` の設定がそのまま使われる。

```
# 最新の録音（無ければ案内音声）を使ってテスト送信する
docker exec asterisk bash /etc/asterisk/scripts/notify.sh --test

# 結果を確認
tail -20 recordings/notify.log
```

Linphone からダイヤルしてもテストできる:

| 内線 | 内容 |
| --- | --- |
| `203` | 録音そのもののテスト（録って聞き返す） |
| `204` | 通知のテスト（Discord/メールを送るだけ） |

メールが失敗するときは `.env` に `MAIL_DEBUG=1` を足すと、
curl のSMTP通信内容までログに出る（パスワードは出力されない）。

### 通知されないときは

- **ログに何も出ない** → そもそも通知が呼ばれていない。`docker exec -it asterisk asterisk -rvvv`
  で着信させ、`=== 通知スクリプトを起動:` の行が出るか確認する。
  `録音なしのため通知しません` なら、録音自体が作られていない。
- **何も飛ばない** → `NOTIFY_DISCORD` / `NOTIFY_EMAIL` が `0` のまま。
  ログに「Discordはオフのためスキップ」「通知先がすべてオフ」が出る。
- **短い伝言だけ届かない** → 8KB（約0.5秒）未満は無言切断とみなして送らない仕様。
  しきい値は `NOTIFY_MIN_BYTES` で変えられる。
- **メールだけ失敗する** → ログの `mail` タグに curl のエラーが出る。
  認証エラーならアプリパスワード、接続エラーならポート/スキームの対応表を確認。
- **`.env` を書き換えたのに反映されない** → `docker compose restart` ではなく
  `docker compose up -d` で作り直す。

---

---

## トラブルシューティング

- **【最頻出】REGISTERは届いているのに Asterisk が無反応（ファイアウォール ufw）**
  症状: `sudo tcpdump -n -i any udp port 5060` で HT813→サーバの REGISTER は
  見える（`In` 方向）のに、逆向きの応答（`Out` 方向）が一切出ず、Asterisk の
  ログにも REGISTER が現れない。HT813 は Not Registered のまま。
  → 原因は **ufw（ホストのファイアウォール）が 5060/RTP を破棄**していること。
  tcpdump は NIC 直後で拾うので「届いて見える」が、ufw が Asterisk に渡す前に
  捨てている。確認と対処:
  ```bash
  sudo ufw status                       # active で 5060 が無ければこれが原因
  sudo ufw allow from 192.168.0.0/24 to any port 5060 proto udp
  sudo ufw allow from 192.168.0.0/24 to any port 10000:20000 proto udp
  ```
  （`192.168.0.0/24` は自分のLAN帯に合わせる。rtp.conf の範囲と 10000:20000 を一致させる）
  解決すると tcpdump に `サーバ → HT813` の `Out` 応答（OPTIONS/200 OK 等）が現れる。

- **HT813の登録が `404 Not Found` で弾かれる / `pjsip show endpoints` が Unavailable のまま**
  ログに `AOR '' not found for endpoint 'ht813'` が出る場合、pjsip.conf の
  `aors=` とAORのセクション名が一致していないのが原因。本ファイルは
  endpoint / auth / aor をすべて同じ名前（`ht813` / `phone`）に揃えて解決済み。
  自分で書き換える際もこの一致を崩さないこと。修正後は
  `docker exec asterisk asterisk -rx "pjsip reload"` で反映。

- **登録状況をログで追う**
  `docker exec -it asterisk asterisk -rvvv` に入って `pjsip set logger on`。
  HT813側で Apply/Reboot すると、REGISTER と `200 OK`（成功）/ `401`・`403`
  （パスワード不一致）/ `404`（AOR不一致）が流れるので原因を切り分けられる。

- **着信が anonymous 扱いで鳴らない**
  `docker exec -it asterisk asterisk -rvvv` でログを見ながら着信させ、
  どのendpointで受けたか確認。HT813のUser IDが `ht813` になっているか点検。

- **片方向しか音声が聞こえない / 無音**
  ほぼ `network_mode: host` になっていないのが原因。compose を確認。
  NASのDockerだとhostネットワークが制限されることがある（下記）。

- **同じWi-Fiなのにスマホからサーバに繋がらない**
  会社Wi-Fiの **APアイソレーション/ゲスト分離** の可能性。
  サーバと同じ有線/業務用SSIDにスマホを載せる。

- **NAS(Synology/QNAP)で動かす**
  host ネットワークやポート競合(5060)に注意。権限エラー時は
  docker-compose.yml の各volumeの `:ro` を `:Z` に変更。

---

## セキュリティ（重要）

- この構成は **LAN内専用**。**SIPポート(5060)を絶対にインターネットへ開放しない**こと
  （即座に総当たり攻撃の標的になります）。
- 外出先から使いたくなったら、ポート開放ではなく **Tailscale等のVPN** を足す方式で。
- これは会社PBXにつながる機器です。設置前に管理者/保守業者へ一声を。

### ファイアウォール（ufw）の推奨設定
サーバで ufw が有効な場合、SIP/RTP のポートを開けないと登録も通話も通りません。
動作確認のために `sudo ufw disable` で全体を止めるのは手軽ですが、常用時は
**ufw を有効に保ったまま、必要なポートだけ LAN 内に開ける**のが安全です。

```bash
sudo ufw enable
sudo ufw allow from 192.168.0.0/24 to any port 5060 proto udp        # SIP
sudo ufw allow from 192.168.0.0/24 to any port 10000:20000 proto udp # RTP(音声)
sudo ufw status                                                      # 反映確認
```

ポイント:
- `192.168.0.0/24` は**自分のLAN帯**に置き換える。`Anywhere` からの全開放にしない。
- RTP の範囲は `rtp.conf` の `rtpstart`〜`rtpend` と一致させる。
- ufw を有効に戻して不通になったら、上のポート許可の記述漏れ／帯違いを疑う。

---

## よく使うコマンド

```bash
docker compose up -d --build     # 起動 / 設定変更後の再ビルド
docker compose restart           # 再起動
docker compose logs -f           # ログ追尾
docker compose down              # 停止・削除

# 設定だけ変えたとき（再ビルド不要、リロードで反映）
docker exec asterisk asterisk -rx "pjsip reload"
docker exec asterisk asterisk -rx "dialplan reload"

# 状態確認
docker exec asterisk asterisk -rx "pjsip show endpoints"
docker exec asterisk asterisk -rx "pjsip show contacts"
```
