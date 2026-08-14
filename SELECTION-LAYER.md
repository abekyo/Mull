# SELECTION-LAYER: 「今の状態アンカー + MCP検索ツール」具体設計

> DIRECTION.md §5/§7 の優先順位 #1 を、既存コードの上に乗る形で具体化します。
> 目的は、生ログ垂れ流しでも lossy 要約でもなく、エージェントが「今の必要」に絞って
> 文脈を組み立てられる検索プリミティブを MCP で提供することです。
> 知能はエージェント、素材の質は mull。
>
> ---
>
> **2026-08-08 の位置づけ更新**
>
> 本書が設計した層は、もはや機能の一つではなく、mull がエージェントに渡す形そのものに
> なりました（CLAUDE.md §5）。GUI は従、MCP サーフェスが主。
> §7 の実装スライス 1・2・3・4 は完了しています。
>
> **2026-08-09 の訂正**: 一度ここに「製品そのもの」と書きましたが、それは行き過ぎでした。
> 選択層は [CLAUDE.md](CLAUDE.md) §0 の場面 C と D に効く手段で、そこは既に ✅ であり、
> かつ他社（Mem0 / Zep / Letta）も売っています。mull にしか無いのは §0 の場面 B、
> つまり訂正から規則が立ち上がる層のほうで、本書はその下敷きです（§5 / [HARNESS.md](HARNESS.md)）。
>
> **2026-08-14 の訂正**: 上の「GUI は従、MCP サーフェスが主」は取り下げました。
> [CLAUDE.md](CLAUDE.md) §0 に場面 E（カレンダー）が入り、§1 の「新規の UI 投資はしない」も
> 同日に取り下げています。正本は CLAUDE.md §0 と §1 で、本書はポインタだけを持ちます。
> 選択層の設計そのものは変わりません。変わったのは、その出口が MCP だけではないことです。
>
> そして §6 の評価ハーネスは、公開時の主張の全体重が乗る場所になりました。
> ETH arXiv 2602.11988（"context files don't improve success rates, +20% cost"）に対して
> 「詰め込めば効かない。選べば効く。測った」と言うための唯一の道具です。

---

## 0. 設計の骨子

```
[広い収集] → [軽い索引: entity / type / salience / session]
                         │
            ┌────────────┴─────────────┐
   現在状態アンカー              スコープ付き検索ツール群 (MCP)
   whats_active_now()           search / recent_work / notes / errors / decisions
                         │
            エージェントが反復的に引く → 統合・判断 → 先回り提案
                         │
            判断は編集可能 md で書き戻す (Curator, provenance)
```

捨てる前提: `get_behavior_patterns` / `get_week_comparison` / `get_patterns` /
`get_briefing` の「事前消化を吐くだけ」ツールは廃止しました（DIRECTION §4）。

---

## 1. 軽い索引（要約ではない。捕捉時か派生時に付与）

既存の `RecordingEvent { timestamp, eventType(keystroke/clipboard/screenText/appSwitch),
appName, windowTitle, textContent }` に、検索の取っ手を足します。内容は消しません。

| フィールド | 由来（安く計算） | 用途 |
|-----------|----------------|------|
| `entity`   | window title のセグメント。エディタは投影名を末尾に置くので `candidates.last ?? candidates.first`（2026-08-14 訂正。git リポ名と clipboard 内のパスは実装に無い。理由は CLAUDE.md §6.1 が正本） | entity で引く（最強の軸） |
| `type`     | note（自分宛メモ）/ error / decision / code / web / file などを語彙ルールで判定 | type で絞る |
| `salience` | 0〜1。自分宛メモ、コピーしたエラー、git commit が高く、ランダム打鍵片が低い | 並べ替え、予算配分 |
| `session`  | 直前イベントとの間隔が N 分未満なら同セッションID | 「この作業の塊」で引く |

実装メモ: まずは派生時計算（検索クエリ内で entity/type を都度判定）で十分です。
効いてきたら events に列を追加して FTS に載せます。

---

## 2. 現在状態アンカー: `whats_active_now()`

「今に錨を打つ」の本体です。個人向けと先回りでは relevance の支配的シグナルになります。

```swift
struct CurrentState {
    var activeApp: String?       // 直近の appSwitch
    var activeTitle: String?     // 直近の screenText（window title）
    var activeEntity: String?    // activeTitle から抽出した project/entity
    var recentActions: [String]  // 直近 ~20分の salience 高イベント（N件）
    var sessionStart: Date?      // 現在セッションの開始
}
```

- 純DBで組み立てます（Accessibility 依存を避けるため）。recorder が5秒ごとに window title を
  記録しているので、最新の screenText と appSwitch を「今」とみなせます。テスト可能です。
- MCP `whats_active_now` はこれを短いテキストか JSON で返します。エージェントはまずこれを読み、
  続く検索を現在の entity と session で条件付けます。

---

## 3. スコープ付き検索ツール群（MCP）

粒度を細かく、ファセットで絞れることが要点です。各ツールは小さく、出典付きで返します。

| ツール | 引数 | 返す |
|--------|------|------|
| `whats_active_now()` | 無し | 現在状態アンカー（§2） |
| `search(query, entity?, type?, since?, k=8)` | 汎用ハイブリッド検索 | top-k の {time, entity, type, text, source} |
| `recent_work(entity?, since="24h")` | entity の作業時系列 | 行動の連なり |
| `notes(about?, since?)` | 自分宛メモや clipboard（salience 高） | メモ列 |
| `errors(since="24h")` | 捕捉したエラー | エラー列 |
| `decisions(entity?)` | memory 由来の決定や learnings | 決定列 |

> 既存ツールの扱い: `search_history` は `search` に統合して強化、`get_relevant` は
> `search` とアンカーで置換、`get_projects` は当面残置（entity 一覧として）、
> `get_user_context` は me.md（Curated）読み出しとして残します。
> `get_behavior_patterns` / `get_week_comparison` / `get_patterns` / `get_briefing` は廃止しました。

---

## 4. 選択パイプライン（1回の `search` がどう解決するか）

1. **アンカー**: 呼び出しに entity/since が無ければ `whats_active_now()` で補完します
   （現在状態で条件付ける）。
2. **候補検索（高再現率）**: ハイブリッド融合
   `score = w1·recency + w2·(entity一致) + w3·FTS(BM25) + w4·salience [+ w5·embedding]`
   で top-K（例 K=40）。まずは embedding 無しの recency + entity + FTS + salience で開始します。

   > **実装（2026-08-09 時点。正本は `Selection.rank`）**:
   > `0.40·lexical + 0.22·recency + 0.18·salience + 0.20·entityMatch`（4項で和が1）
   > `+ 0.03·attributable + 0.06·mode + 0.10·correction`（順序付けの加算項。和の外）
   >
   > `mode` は 2026-08-09 に接続しました。それまで `Mode` は捕捉時に計算して保存されながら
   > 選択層から一切読まれておらず、MAP-ARCHITECTURE の「重み付け・選別に使う」が
   > 実装されていませんでした。
   >
   > **0.06 は暫定値です。** eval の合成ケースはほぼ全てが `appName: "Code"` を共有するため
   > mode がコーパス内でほぼ定数になり、この重みを測れません。
   > 引き上げるには、先に mode が分散する eval ケースが要ります（契約3: 測れない状態で作らない）。
   >
   > `correction` も 2026-08-09 に接続しました。唯一、人間の判定に裏打ちされた項なので
   > mode より重くしてあります（0.10）。そして唯一 eval が実測できる項でもあります。
   >
   > ```
   > convergence — precision@1 on 4 ties the ranker cannot break
   >   curve: 0.00 → 0.25 → 0.50 → 0.75 → 1.00
   > ```
   >
   > 並べ替えるだけで、単独では落とせません（法則5）。既定は `.empty` なので
   > コールドスタートの挙動は接続前と完全に同一です。
3. **絞り込み（高精度）**: 安い LLM かヒューリスティックで「今の必要」に並べ替え、
   token 予算内に圧縮します。include / summarize / drop を per-item で判定します。
4. **組み立て**: 上位を出典付きで返します（time、entity、source）。可視性が信頼になります。
5. **使用ログ**: 何を返し、エージェントや人間が使ったか直したかを記録して salience に還流します。

---

## 5. 学習ループ（後段）

- 返したスライスのうち実際に使われたものが正ラベルです。
- 人間が Curator で直した、あるいは消したという事実が、最高品質の relevance ラベルです。
  しかも無料で手に入ります。
- これを salience と重み w に還流します。ここが mull の強み（現在状態と人間の修正の掛け算）です。

> **✅ 2026-08-09 に実装しました。**
> `Curator.detectCorrections`（16の呼び出し元が通る chokepoint）から `CorrectionCard`
> （9セクション。1–3 自動、4・5・8 は空欄）、`CorrectionIndex`、`Selection.rank` の
> `+0.10·correction` まで。ledger は `corrections/ledger.md` に置く編集可能な md です（契約2）。
>
> **✅ 同日、配線も繋ぎました。** `MCPServer.toolSearch` が毎回 ledger を読んで
> `Selection.slice(corrections:)` に渡し、`contextSnapshotProvider` は `MCPServer.init` と
> `MullEngine.init`（データベースを持つ2つの層）で `CurrentState.summary()` に接続しました。
> それまでは、この曲線は eval の中だけの現象でした。ledger を渡す呼び出し元が
> `selection_eval.swift` しか無く、カード §1 は常に空だったからです。
> 学習ループのもう半分（訂正から規則、そして `rules.md`）は [HARNESS.md](HARNESS.md) 第II部にあります。

> **実装仕様は [HARNESS.md](HARNESS.md) 第II部が正本です**（2026-08-09）。要点だけ引きます。
>
> - 編集距離（量）だけでは足りません。条件を捨てた訂正は次に誤用されます（PRC-003 文脈転写の不可能性）
> - 訂正は Correction Card（9セクション）として構造で持ちます
> - 1–3（Context snapshot / Failed move / Signals）は自動化し、4・5・8（Hidden axis /
>   Reasoning chain / Contrast）は自動化しません。そこを自動化すると「もっともらしい嘘」になります
> - 足りない機構は3つ: Card スキーマ、Retrieval cues（見つかる設計）、Check question（次回に効く設計）
> - セクション1を自動で埋められるのは mull だけです（`whats_active_now()` のスナップショット）。
>   ここが「訂正が規則の唯一の源泉」（[HARNESS.md](HARNESS.md) 冒頭）の具体化になります

---

## 6. 評価ハーネス（この節が正本）

`(need, 理想スライス)` の組に対して `Selection.rank` の precision / recall / MRR を測ります。
変更が効いたか判定できる状態を最初に作りました。これが「選択を良くする」の出発点です。

ハーネスは2本あります。**合成が門番、実ログが答え合わせ**です。

> **どちらも `Selection.rank` だけを測っています。** ユーザーが Copy context で貼り付ける
> ブロックは `ContextComposer` が作り、`Selection` を一度も呼びません（`grep -c "Selection\."` が 0）。
> あちらは `ContextComposerTests` のラベル付きケースで測っています。この harness は
> GRDB-free かつファイルシステム非依存に保つ設計なので、`FactExtractor` と vault に触る
> 経路をここに入れることはできません。**数字を引用するときはどちらの経路の数字か明示すること。**

### 6.1 合成ケース: [`eval/selection_eval.swift`](eval/selection_eval.swift)

`./eval/run.sh` で回ります。GRDB-free の `RecordingEvent` shim を持ち Xcode ターゲット外に
置いてあるので、ホストアプリのビルドを待たずに数秒で終わります。

32ケースを、素で並べたベースライン3種と比較します。数字を単体で出しても意味がないので、
比較対象なしの値は載せません。

| strategy | precision | recall | MRR | F1 |
|---|---|---|---|---|
| **mull** | 0.964 | 0.964 | 0.969 | **0.964** |
| full-context（ETH論文が否定した条件） | 0.453 | 1.000 | 0.799 | 0.624 |
| recency-only | 0.504 | 0.906 | 0.760 | 0.648 |
| entity-only | 0.541 | 0.844 | 0.766 | 0.659 |

この3本に F1 で勝てなければ、選択層は存在を正当化できません。
ハーネスは負けたら `GATE: fail` で終了します。

> **勝っても堀にはなりません。** ここで測っているのは CLAUDE.md §0 の場面 C と D で、
> 既に ✅ であり、既に他社が売っている領域です。この表が守るのは「詰め込みより選んだ方が良い」
> という参入の条件であって、優位ではありません。優位は場面 B（訂正から規則）にしかなく、
> それは上の収束曲線のほうで測ります。この2つを混同しないでください。
> 2026-08-08 版の本書は混同していました。

> ⚠️ ベースラインは3本とも自作です。Mem0 も素の `grep` も入っていません。
> 「勝った」の射程はそこまでです。

### 6.2 実ログケース: [`eval/real/`](eval/real/)

合成ケースは、ランカーを書いた本人がランカーを書いた後で考えたものです。だからそこに入っている
distractor は、そのランカーが既に勝てる distractor でしかありません。実ログの distractor は
違います。同じ語を含む別の4件、同一タイトルの6連コピー、一日中出続ける IDE のトースト。

`eval/real/harvest.sh` が実際の mull DB から窓を切り出し、`eval/real/run.sh` が同じ
`Selection.rank` を採点します。採点対象のファイル一覧は `eval/run.sh` と一字一句同じに保ってください。
ずれた瞬間に2本のハーネスは別のコードを測ることになり、数字が比較できなくなります。

切り出したケースは gitignore してあり、公開されません。各自が自分のログで回すことが
このハーネスの趣旨です。`gold` はランカーの出力を見る前に手で付けます（見てから付けると
無意識に追認して、また 1.000 が出ます）。

実測（4窓 / 1,493 events）は mull が F1 0.220（precision 0.144 / recall 0.467）。
full-context 0.020、recency-only 0.045、entity-only 0.045 には勝っていますが、
**0.220 が正直な数字**であり、合成との差そのものが発見です。
実ログの数字は 2026-08-09 の重複排除より前の測定なので、上がっているはずですが測り直していません。

### 6.3 開いている4つの穴

実ログでしか出なかった失敗を、合成側のケース29–32として取り込んであります（CI が見張るため）。
ゲートには入れていません。直っていないものを緑にしないためです。

| gap | 何が起きるか |
|---|---|
| `duplicate-flood` | ウィンドウタイトルは5秒ポーリング。8枠のうち6枠が、同一タイトルのバイト単位で同じコピーに埋まる。重複排除が無い |
| `query-echo` | 直前にエージェントへ貼った質問文がクリップボードに残っており、自分自身のクエリに完全一致して1位に来る。エージェントは自分の質問を文脈として受け取る |
| `subsumption` | 同じメモの3回の推敲が全部ランクインし、完成版が3番目に来る |
| `entity-junk-profile` | `Entity.from` が末尾セグメントを取るので、ブラウザのタブがプロジェクトではなくブラウザのプロファイル名に紐づき、アンカーを丸ごと失う |

`query-echo` は合成コーパスからは原理的に到達できません。自分のクエリをイベント列に書く人はいないからです。

### 6.4 壊れないようにしてある理由

このハーネスは2度、黙って壊れました。どちらも、採点対象のファイルが `import GRDB` した
何かに手を伸ばしたことが原因で、誰も回していなかったので誰も気づきませんでした。
今は [`.github/workflows/eval.yml`](.github/workflows/eval.yml) が push ごとに回します。

`Mull/Core/` のコードが新しいシンボルを参照するようにしたら、push 前に `./eval/run.sh` が
まだビルドできるか確かめてください。

---

## 7. 実装スライス（小さく、効く順）

| # | スライス | 状態 |
|---|---|---|
| 1 | `CurrentState`（純DB、テスト付き）と MCP `whats_active_now`。アンカーの土台 | ✅ `Mull/Core/CurrentState.swift` と `CurrentStateTests` |
| 2 | `search(query, entity?, type?, since?)`。FTS + recency + entity + salience の融合 | ✅ `Mull/Core/Selection.swift` と `SelectionTests`。MCP `search` として公開済み |
| 3 | 評価ハーネス | ✅ 32ケース。CI が push ごとに回す（§6） |
| 4 | type/salience の語彙ルールを派生計算で | ✅ `Signal.swift` / `Mode.swift`。capture-time の列にも保存 |
| 5 | rerank（安い LLM、予算配分） | ❌ 未着手。効果を測らずに入れない |
| 6 | 使用と編集の学習ループ | ✅ 2026-08-09（§5） |
| 7 | 旧「事前消化」ツールの廃止 | ✅ 完了（CLAUDE.md §5.2） |

> 1・2・4 が終わっていても、3 が回っていなければ 5 は入れられません。
> 効果を測る手段が先で、機能が後。順序はここで固定します（契約3: 測れない状態で作らない）。

> 不変条件: 要約は捨て構造化は残す。知能はエージェント。出典付きで可視かつ編集可能。
> 現在状態に錨を打つ。
