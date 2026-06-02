# SELECTION-LAYER — 「今の状態アンカー + MCP検索ツール」具体設計

> DIRECTION.md §5/§7 の優先順位 #1 を、既存コードの上に乗る形で具体化する。
> 目的：生ログ垂れ流しでも lossy 要約でもなく、**エージェントが「今の必要」に絞って
> 文脈を組み立てられる検索プリミティブ**を MCP で提供する。知能はエージェント、
> 素材の質は mull。

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
| `type`     | note(自分宛メモ) / error / decision / code / web / file … を語彙ルールで判定 | typeで絞る |
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
3. **絞り込み（高精度）**：安いLLM/ヒューリスティックで「今の必要」に並べ替え、
   **token予算内**に圧縮。include / summarize / drop を per-item 判定。
4. **組み立て**：上位を**出典付き**で返す（time・entity・source）。可視性＝信頼。
5. **使用ログ**：何を返し、エージェント/人間が使った/直したかを記録 → salience に還流。

---

## 5. 学習ループ（後段）

- 返したスライスのうち**実際に使われた**もの = 正ラベル。
- **人間が Curator で直した/消した** = 最高品質の relevance ラベル（無料）。
- これを salience / 重み w に還流。mull の不当な強み（現在状態 × 人間の修正）。

---

## 6. 評価ハーネス（先に作る）

`(need, 理想スライス)` を 20〜50 本。`search`/アンカーの **precision/recall** を測る。
変更が効いたか判定できる状態を**最初に**作る。これが「選択を良くする」の出発点。

---

## 7. 実装スライス（小さく・効く順）

1. **`CurrentState`（純DB・テスト付き）** ＋ MCP `whats_active_now` ← 最初の一歩。アンカーの土台。
2. **`search(query, entity?, type?, since?)`** ＝ 既存FTS + recency + entity + salience の融合。`search_history`/`get_relevant` を置換。
3. **評価ハーネス 20 本**。
4. type/salience の語彙ルール → 派生計算で。
5. rerank（安いLLM・予算配分）。
6. 使用/編集の学習ループ。
7. 旧「事前消化」ツールの廃止。

> 不変条件：要約は捨て構造化は残す／知能はエージェント／出典付きで可視・編集可能／
> 現在状態に錨を打つ。
