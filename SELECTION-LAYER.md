# SELECTION-LAYER — 「今の状態アンカー + MCP検索ツール」具体設計

> DIRECTION.md §5/§7 の優先順位 #1 を、既存コードの上に乗る形で具体化する。
> 目的：生ログ垂れ流しでも lossy 要約でもなく、**エージェントが「今の必要」に絞って
> 文脈を組み立てられる検索プリミティブ**を MCP で提供する。知能はエージェント、
> 素材の質は mull。
>
> ---
>
> **2026-08-08 の位置づけ更新**
>
> 本書が設計した層は、もはや「機能の一つ」ではなく **mull の製品そのもの**になった
> （STRATEGY-2026-08.md（非公開の内部文書） / CLAUDE.md §5）。
> GUI は従、MCP サーフェスが主。**§7 の実装スライス 1・2・3・4 は完了している**（各項参照）。
>
> そして §6 の評価ハーネスは、公開時の**主張の全体重が乗る場所**になった——
> ETH arXiv 2602.11988（"context files don't improve success rates, +20% cost"）に対して、
> **「詰め込めば効かない。選べば効く。測った」**と言うための唯一の道具。

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

捨てる前提：`get_behavior_patterns` / `get_week_comparison` / `get_patterns` /
`get_briefing` の「事前消化を吐くだけ」ツールは段階的に廃止（DIRECTION §4）。

---

## 1. 軽い索引（要約ではない・捕捉/派生時に付与）

既存 `RecordingEvent { timestamp, eventType(keystroke/clipboard/screenText/appSwitch),
appName, windowTitle, textContent }` に、検索の"取っ手"を足す。**内容は消さない。**

| フィールド | 由来（安く計算） | 用途 |
|-----------|----------------|------|
| `entity`   | window title の先頭セグメント（`Project — File — App` の Project）、git リポ名、clipboard内のパス | entityで引く（最強の軸） |
| `type`     | note(自分宛メモ) / error / **decision** / code / web / file … を語彙ルールで判定 | typeで絞る |
| `salience` | 0–1。自分宛メモ・コピーしたエラー・git commit = 高、ランダム打鍵片 = 低 | 並べ替え・予算配分 |
| `session`  | 直前イベントとの間隔 < N分 で同セッションID | 「この作業の塊」で引く |

実装メモ：まずは**派生時計算**（検索クエリ内で entity/type を都度判定）で十分。
効いてきたら events に列追加 + FTS に載せる。

---

## 2. 現在状態アンカー：`whats_active_now()`

「今に錨を打つ」の本体。個人・先回りでは relevance の支配的シグナル。

```swift
struct CurrentState {
    var activeApp: String?       // 直近の appSwitch
    var activeTitle: String?     // 直近の screenText（window title）
    var activeEntity: String?    // activeTitle から抽出した project/entity
    var recentActions: [String]  // 直近 ~20分の salience 高イベント（N件）
    var sessionStart: Date?      // 現在セッションの開始
}
```

- **純DBで組み立てる**（Accessibility 依存を避ける）：recorder が5秒毎に window title を
  記録しているので、最新 screenText/appSwitch を「今」とみなせる。テスト可能。
- MCP `whats_active_now` はこれを短いテキスト/JSON で返す。エージェントはまずこれを読み、
  続く検索を現在 entity/session で条件付ける。

---

## 3. スコープ付き検索ツール群（MCP）

粒度を細かく、**ファセットで絞れる**こと。各ツールは**小さく・出典付き**で返す。

| ツール | 引数 | 返す |
|--------|------|------|
| `whats_active_now()` | — | 現在状態アンカー（§2） |
| `search(query, entity?, type?, since?, k=8)` | 汎用ハイブリッド検索 | top-k の {time, entity, type, text, source} |
| `recent_work(entity?, since="24h")` | entity の作業時系列 | 行動の連なり |
| `notes(about?, since?)` | 自分宛メモ/clipboard（salience高） | メモ列 |
| `errors(since="24h")` | 捕捉したエラー | エラー列 |
| `decisions(entity?)` | memory由来の決定/learnings | 決定列 |

> 既存ツールの扱い：`search_history`→`search` に統合・強化／`get_relevant`→`search`+
> アンカーで置換／`get_projects`は当面残置（entity一覧として）／`get_user_context`は
> me.md（Curated）読み出しとして残す。`get_behavior_patterns`/`get_week_comparison`/
> `get_patterns`/`get_briefing` は廃止予定。

---

## 4. 選択パイプライン（1回の `search` がどう解決するか）

1. **アンカー**：呼び出しに entity/since が無ければ `whats_active_now()` で補完
   （= 現在状態で条件付け）。
2. **候補検索（高再現率）**：ハイブリッド融合
   `score = w1·recency + w2·(entity一致) + w3·FTS(BM25) + w4·salience [+ w5·embedding]`
   で top-K（例 K=40）。まずは embedding 無しの recency+entity+FTS+salience で開始。

   > **実装（2026-08-09 時点、正本は `Selection.rank`）**:
   > `0.40·lexical + 0.22·recency + 0.18·salience + 0.20·entityMatch`（4項で和が1）
   > `+ 0.03·attributable + 0.06·mode + 0.10·correction`（順序付けの加算項。和の外）
   >
   > **`mode` は 2026-08-09 に接続した。** それまで `Mode` は捕捉時に計算・保存されながら
   > 選択層から一切読まれておらず、MAP-ARCHITECTURE の「重み付け・選別に使う」が
   > 実装されていなかった（ROADMAP §1 B1）。
   > **0.06 は暫定値**——eval 28ケースはほぼ全てが `appName: "Code"` を共有するため
   > mode がコーパス内でほぼ定数になり、**この重みを測れない**。
   > 引き上げるには、先に mode が分散する eval ケースが要る（契約3: 測れない状態で作らない）。
   >
   > **`correction` は 2026-08-09 に接続した。唯一、人間の判定に裏打ちされた項**——
   > だから mode より重い（0.10）。そして**唯一 eval が実測できる項**でもある:
   >
   > ```
   > convergence — precision@1 on 4 ties the ranker cannot break
   >   curve: 0.00 → 0.25 → 0.50 → 0.75 → 1.00
   > ```
   >
   > 並べ替えるだけで、単独では落とせない（法則5）。既定は `.empty` なので
   > コールドスタートの挙動は接続前と完全に同一。
3. **絞り込み（高精度）**：安いLLM/ヒューリスティックで「今の必要」に並べ替え、
   **token予算内**に圧縮。include / summarize / drop を per-item 判定。
4. **組み立て**：上位を**出典付き**で返す（time・entity・source）。可視性＝信頼。
5. **使用ログ**：何を返し、エージェント/人間が使った/直したかを記録 → salience に還流。

---

## 5. 学習ループ（後段）

- 返したスライスのうち**実際に使われた**もの = 正ラベル。
- **人間が Curator で直した/消した** = 最高品質の relevance ラベル（無料）。
- これを salience / 重み w に還流。mull の不当な強み（現在状態 × 人間の修正）。

> **✅ 2026-08-09 に実装した。**
> `Curator.detectCorrections`（16の呼び出し元が通る chokepoint）→ `CorrectionCard`（9セクション、
> **1–3 自動 / 4・5・8 は空欄**）→ `CorrectionIndex` → `Selection.rank` の `+0.10·correction`。
> ledger は `06_knowledge/corrections/ledger.md`——**編集可能な md**（契約2）。
> **残っている配線は2本**: `Curator.contextSnapshotProvider` への `CurrentState` 注入（カード §1）と、
> 起動時の ledger ロード。詳細は [HARNESS.md](HARNESS.md) 第II部。

> **実装仕様は [HARNESS.md](HARNESS.md) 第II部が正本**（2026-08-09）。
> 要点だけ引くと:
> - **編集距離（量）だけでは足りない。** 条件を捨てた訂正は次に誤用される（PRC-003 文脈転写の不可能性）
> - 訂正は **Correction Card（9セクション）** として構造で持つ
> - **1–3（Context snapshot / Failed move / Signals）は自動化する。4・5・8（Hidden axis /
>   Reasoning chain / Contrast）は自動化しない**——そこを自動化すると「もっともらしい嘘」になる
> - 足りない機構は3つ: Card スキーマ / **Retrieval cues**（見つかる設計）/ **Check question**（次回に効く設計）
> - セクション1を自動で埋められるのは mull だけ（`whats_active_now()` のスナップショット）。
>   ここが STRATEGY §2-2 の非対称性の具体化

---

## 6. 評価ハーネス（先に作る）— **✅ 作った。ただし今ビルドが壊れている**

`(need, 理想スライス)` を 20〜50 本。`search`/アンカーの **precision/recall** を測る。
変更が効いたか判定できる状態を**最初に**作る。これが「選択を良くする」の出発点。

### 現況（2026-08-08）

**実装**: [`eval/selection_eval.swift`](eval/selection_eval.swift)。
`Selection.rank` に対して **precision / recall / MRR** を **20ケース**で測る。
GRDB-free の `RecordingEvent` shim を持ち、Xcode ターゲット外に置いてある
（＝ホストアプリのビルドを待たずに数秒で回る設計）。

**🔴 ただし現在コンパイルできない。**

```
Mull/Core/Selection.swift:125: cannot find 'DatabaseService' in scope
```

2026-07-18 の god object 分割で `Selection.rank` が `DatabaseService.containsCJK` を
呼ぶようになり、`DatabaseService` は `import GRDB`。**本書 §6 の「GRDB-free で回る」という
前提が、リファクタで静かに壊れた。**

**直し方**: `containsCJK` を GRDB 非依存の置き場へ抽出する（シンボル1つ）。
**そして CI かプリコミットに載せる**——測れない状態に戻さないため。
ROADMAP §1-A が公開ゲートとして持っている。

### まだやっていないこと

- **ベースラインとの比較**。数字を単体で出しても意味がない。
  最低限、次の3つと並べる: ①素の全文投入（＝ETH論文が否定した条件） ②recency のみ ③entity のみ。
  **mull の融合スコアがこれらに勝てなければ、選択層は堀ではない**（STRATEGY §6 撤回基準）。
- ケース数を50本まで増やす（20は DIRECTION §5.6 の下限）。

---

## 7. 実装スライス（小さく・効く順）

| # | スライス | 状態 |
|---|---|---|
| 1 | **`CurrentState`（純DB・テスト付き）** ＋ MCP `whats_active_now` ← アンカーの土台 | ✅ `Mull/Core/CurrentState.swift` ＋ `CurrentStateTests` |
| 2 | **`search(query, entity?, type?, since?)`** ＝ FTS + recency + entity + salience の融合 | ✅ `Mull/Core/Selection.swift` ＋ `SelectionTests`。MCP `search` として公開済み |
| 3 | **評価ハーネス 20 本** | ⚠️ 実装済み・**ビルド破損中**（§6） |
| 4 | type/salience の語彙ルール → 派生計算で | ✅ `Signal.swift` / `Mode.swift`。capture-time の列にも保存 |
| 5 | rerank（安いLLM・予算配分） | ❌ 未着手 — **eval が回ってから**。効果を測らずに入れない |
| 6 | 使用/編集の学習ループ | ❌ 未着手 — ROADMAP §3-A。**star が付いてからの第2弾** |
| 7 | 旧「事前消化」ツールの廃止 | 🔄 進行中（CLAUDE.md §5.2） |

> **1・2・4 が終わっているのに事業の像が結ばなかった。** 空白は技術ではなく、
> **数字（3）と公開**だった（STRATEGY §1）。次の一手は 5 でも 6 でもなく、**3 を直して回すこと**。

> 不変条件：要約は捨て構造化は残す／知能はエージェント／出典付きで可視・編集可能／
> 現在状態に錨を打つ。
