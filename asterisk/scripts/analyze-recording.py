#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
analyze-recording.py — 品質調査録音(qa/)を解析して「なぜ聞こえづらいか」を数値で出す

使い方（ホスト側で実行。追加インストール不要 / Python3 標準ライブラリのみ）:

    # 最新の1通話を解析
    python3 asterisk/scripts/analyze-recording.py recordings/qa

    # ファイルを指定（-rx / -tx / 拡張子は付けても付けなくてもよい）
    python3 asterisk/scripts/analyze-recording.py recordings/qa/20260818-101530_out_5105_1755.wav

    # どちらのトラックが「自分(Linphone)の声」かを明示する
    python3 asterisk/scripts/analyze-recording.py recordings/qa --self rx

対象ファイル（extensions.conf の [qa-rec] が出力する）:
    ○○.wav       … 両方向ミックス（耳で聴く用）
    ○○-rx.wav    … 録音したチャネルが「受け取った」音声
    ○○-tx.wav    … 録音したチャネルへ「送った」音声

方向の既定（ファイル名の _in_ / _out_ から自動判定）:
    _out_ (Linphoneから発信) : rx = 自分の声   / tx = 相手の声
    _in_  (外線着信)         : tx = 自分の声   / rx = 相手の声

見るべき出力:
  * 自分側の「発話中の平均レベル」が -30dBFS より小さい
      → そもそも送出音量が小さい。Linphoneのマイク / HT813のゲインを上げる。
  * 「ダブルトーク時のレベル低下」が 6dB 以上
      → 同時発話でこちらの声が削られている＝エコーキャンセラの半二重動作。
        録音は Asterisk 到着時点なので、ここで既に落ちていれば犯人は Linphone 側。
  * 「途切れ率(ドロップアウト)」が高い
      → Wi-Fi / パケットロス、または音声検出(VAD)による送出停止。
  * 「クリップ率」が 1% 以上
      → 音量過大による歪み。上げすぎ。
"""

import sys
import os
import wave
import array
import math
import glob

FRAME_MS = 20          # 解析単位(ms)。RTPの1パケットと同じ
CLIP_LEVEL = 32000     # 16bit のほぼ振り切り
DT_DROP_WARN = 6.0     # ダブルトーク時にこのdB以上落ちたら警告


# ---------------------------------------------------------------- 読み込み

def read_wav(path):
    """WAVを読んで [-1.0,1.0] のサンプル配列とサンプリング周波数を返す"""
    with wave.open(path, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width != 2:
        raise ValueError(f"{path}: 16bit以外({width*8}bit)は非対応です")
    a = array.array("h")
    a.frombytes(raw)
    if sys.byteorder == "big":
        a.byteswap()
    if ch > 1:                      # 念のためモノラル化
        a = array.array("h", a[0::ch])
    return a, rate


def frame_levels(samples, rate):
    """FRAME_MS ごとの (RMS[dBFS], ピーク絶対値, クリップ数) を返す"""
    step = max(1, int(rate * FRAME_MS / 1000))
    out = []
    for i in range(0, len(samples) - step + 1, step):
        seg = samples[i:i + step]
        s = 0
        peak = 0
        clip = 0
        for v in seg:
            s += v * v
            av = -v if v < 0 else v
            if av > peak:
                peak = av
            if av >= CLIP_LEVEL:
                clip += 1
        rms = math.sqrt(s / step)
        db = 20 * math.log10(rms / 32768.0) if rms > 0 else -100.0
        out.append((db, peak, clip))
    return out


# ---------------------------------------------------------------- 判定

def noise_floor(levels):
    """静かなフレームの代表値からノイズフロアを推定する"""
    dbs = sorted(l[0] for l in levels)
    if not dbs:
        return -60.0
    return dbs[int(len(dbs) * 0.15)]        # 下から15%点


def speech_flags(levels, floor):
    """発話しているフレームを True にする。しきい値はノイズフロア+12dB"""
    th = max(floor + 12.0, -55.0)
    return [l[0] > th for l in levels], th


def stats(levels, flags):
    spoke = [levels[i][0] for i, f in enumerate(flags) if f]
    total_clip = sum(l[2] for l in levels)
    total_samp = len(levels) * int(8000 * FRAME_MS / 1000)
    peak = max((l[1] for l in levels), default=0)
    return {
        "frames": len(levels),
        "speech_ratio": (len(spoke) / len(levels) * 100) if levels else 0.0,
        "speech_db": (sum(spoke) / len(spoke)) if spoke else -100.0,
        "peak_db": 20 * math.log10(peak / 32768.0) if peak else -100.0,
        "clip_pct": (total_clip / total_samp * 100) if total_samp else 0.0,
    }


def dropout_ratio(flags):
    """発話区間の中に現れる短い無音（途切れ）の割合[%]"""
    n = len(flags)
    holes = 0
    inside = 0
    i = 0
    # 最初と最後の発話位置の間だけを「通話中」とみなす
    try:
        s = flags.index(True)
        e = n - 1 - flags[::-1].index(True)
    except ValueError:
        return 0.0
    for i in range(s, e + 1):
        inside += 1
        if not flags[i]:
            holes += 1
    return holes / inside * 100 if inside else 0.0


def mean_db(levels, idx):
    vals = [levels[i][0] for i in idx]
    return sum(vals) / len(vals) if vals else None


# ---------------------------------------------------------------- 表示

def bar(db, lo=-50.0, hi=0.0, width=28):
    if db <= lo:
        return " " * width
    n = int((db - lo) / (hi - lo) * width)
    return "#" * max(1, min(width, n))


def timeline(self_lv, far_lv, self_fl, far_fl, seconds_per_row=1.0):
    per = max(1, int(seconds_per_row * 1000 / FRAME_MS))
    rows = []
    n = min(len(self_lv), len(far_lv))
    for i in range(0, n, per):
        sl = [self_lv[j][0] for j in range(i, min(i + per, n))]
        fl = [far_lv[j][0] for j in range(i, min(i + per, n))]
        ss = any(self_fl[j] for j in range(i, min(i + per, n)))
        fs = any(far_fl[j] for j in range(i, min(i + per, n)))
        mark = "◆" if (ss and fs) else (" ")
        rows.append((i * FRAME_MS / 1000.0,
                     max(sl), max(fl), mark))
    return rows


def analyze_pair(rx_path, tx_path, self_side):
    tracks = {}
    for name, p in (("rx", rx_path), ("tx", tx_path)):
        s, rate = read_wav(p)
        lv = frame_levels(s, rate)
        fl, th = speech_flags(lv, noise_floor(lv))
        tracks[name] = {"path": p, "lv": lv, "fl": fl, "th": th,
                        "st": stats(lv, fl), "sec": len(s) / rate}

    far_side = "tx" if self_side == "rx" else "rx"
    me, far = tracks[self_side], tracks[far_side]

    print("=" * 68)
    print(f"  自分(Linphone)側 : {os.path.basename(me['path'])}   [{self_side}]")
    print(f"  相手(PBX)側      : {os.path.basename(far['path'])}   [{far_side}]")
    print(f"  長さ             : {me['sec']:.1f} 秒")
    print("=" * 68)

    for label, t in (("自分の声", me), ("相手の声", far)):
        st = t["st"]
        print(f"\n[{label}]")
        print(f"  発話中の平均レベル : {st['speech_db']:7.1f} dBFS  {bar(st['speech_db'])}")
        print(f"  ピークレベル       : {st['peak_db']:7.1f} dBFS")
        print(f"  発話していた割合   : {st['speech_ratio']:7.1f} %")
        print(f"  途切れ(ドロップ)率 : {dropout_ratio(t['fl']):7.1f} %")
        print(f"  クリップ率         : {st['clip_pct']:7.2f} %")

    # ---- ダブルトーク解析（本題） ----
    n = min(len(me["lv"]), len(far["lv"]))
    solo = [i for i in range(n) if me["fl"][i] and not far["fl"][i]]
    both = [i for i in range(n) if me["fl"][i] and far["fl"][i]]
    both_all = [i for i in range(n) if far["fl"][i]]

    print("\n" + "-" * 68)
    print("[ダブルトーク解析] 自分だけ話しているとき vs 同時に話しているとき")
    print("-" * 68)
    d_solo = mean_db(me["lv"], solo)
    d_both = mean_db(me["lv"], both)
    print(f"  単独発話中の自分のレベル : "
          f"{('%7.1f dBFS' % d_solo) if d_solo is not None else '  データ不足'}"
          f"   ({len(solo)*FRAME_MS/1000:.1f}秒)")
    print(f"  同時発話中の自分のレベル : "
          f"{('%7.1f dBFS' % d_both) if d_both is not None else '  データ不足'}"
          f"   ({len(both)*FRAME_MS/1000:.1f}秒)")

    verdict = []
    if d_solo is not None and d_both is not None:
        drop = d_solo - d_both
        print(f"  → 同時発話時のレベル低下 : {drop:+.1f} dB")
        if drop >= DT_DROP_WARN:
            verdict.append(
                f"★ 同時発話でこちらの声が {drop:.0f}dB 削られています。"
                "半二重動作（エコーキャンセラ/エコーサプレッサ）が原因です。\n"
                "   この録音は Asterisk 到着時点のものなので、\n"
                "   → Linphone(スマホ)側のエコーキャンセラ・AGCが犯人。有線ヘッドセットを試す。")
        else:
            verdict.append(
                "・Asterisk 到着時点では同時発話でも音量は保たれています。\n"
                "   → 犯人はこの先（HT813のFXOハイブリッド or PBX/相手電話機）です。")
    else:
        verdict.append("・同時発話のサンプルが足りません。内線296のダブルトーク試験で録り直してください。")

    # 相手が話している間に自分の声が完全に消える割合
    if both_all:
        muted = sum(1 for i in both_all if not me["fl"][i])
        rate_muted = muted / len(both_all) * 100
        print(f"  相手発話中にこちらが無音になった割合 : {rate_muted:.1f} %")

    st = me["st"]
    if st["speech_db"] < -30:
        verdict.append(f"★ 送出レベルが小さい({st['speech_db']:.0f}dBFS)。"
                       "Linphoneのマイク音量 / HT813のFXO送出ゲインを上げる。")
    if st["clip_pct"] >= 1.0:
        verdict.append(f"★ クリップ({st['clip_pct']:.1f}%)。音量を上げすぎ。歪んで聞き取れなくなる。")
    if dropout_ratio(me["fl"]) > 25:
        verdict.append("★ 途切れが多い。Wi-Fi/パケットロス、または VAD(無音圧縮) を疑う。")

    print("\n" + "-" * 68)
    print("[所見]")
    print("-" * 68)
    for v in verdict:
        print("  " + v)

    # ---- タイムライン ----
    print("\n" + "-" * 68)
    print("[タイムライン] ◆=同時発話  (1行=1秒, 最大レベル)")
    print("-" * 68)
    print("   秒  自分                          相手")
    for sec, sdb, fdb, mark in timeline(me["lv"], far["lv"], me["fl"], far["fl"]):
        print(f"  {sec:4.0f} |{bar(sdb):28s}|{bar(fdb):28s}| {mark}")


# ---------------------------------------------------------------- 入口

def resolve(target):
    """引数からベース名(接尾辞なし)を決める"""
    if os.path.isdir(target):
        cands = [f for f in glob.glob(os.path.join(target, "*-rx.wav"))]
        if not cands:
            sys.exit(f"エラー: {target} に -rx.wav がありません（QA録音がまだ無い？）")
        base = max(cands, key=os.path.getmtime)[:-len("-rx.wav")]
        return base
    for suf in ("-rx.wav", "-tx.wav", ".wav"):
        if target.endswith(suf):
            return target[:-len(suf)]
    return target


def main():
    args = [a for a in sys.argv[1:]]
    self_side = None
    if "--self" in args:
        i = args.index("--self")
        self_side = args[i + 1]
        del args[i:i + 2]
    if not args:
        sys.exit(__doc__)

    base = resolve(args[0])
    rx, tx = base + "-rx.wav", base + "-tx.wav"
    for p in (rx, tx):
        if not os.path.exists(p):
            sys.exit(f"エラー: {p} がありません。-rx/-tx の両方が必要です。")

    if self_side not in ("rx", "tx"):
        name = os.path.basename(base)
        # 発信(out)は Linphone が録音チャネル → 自分の声は rx
        # 着信(in) は HT813 が録音チャネル   → 自分の声は tx
        self_side = "rx" if "_out_" in name else "tx"

    analyze_pair(rx, tx, self_side)


if __name__ == "__main__":
    main()
