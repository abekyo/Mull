# DIRECTION — アーキテクチャの帰結と方針

> 2026-06-02 の設計議論の結論。CLAUDE.md（製品仕様）が「何を作るか」なら、これは
> 「**どう作り直すか**」。判断の根拠と、残す/消すの線引きを残す。
>
> **これが技術の北極星。** 旧 `PRODUCT.md`（削除済み）の "Direction v2 / v3" を上書きする。
> v2/v3 から生き残るもの：mull＝エージェントの記憶+良心 / Curator(provenance) / recompilable
> context（ただし派生は use-time 組み立て）/ epistemics / 行動ゲートは「1本の先回りループ」に縮小。
> 保留：v3 の `00_〜09_` ontology・外部 ingestion・capture-time synthesis（§4・§6 参照）。
> **うち `00_〜09_` ontology は 2026-08-09 に保留 → 廃止決定。正本は §6.1。**
>
> ---
>
> **§1〜§6・§8・§9 の技術方針は全て生きている。** §5（選択層）が製品の実体であり、
> §6（Curator）が唯一の堀。§5.6 の評価ハーネスは完成しており、仕様と現在値の正本は
> [SELECTION-LAYER.md](SELECTION-LAYER.md) §6。
>
> **節番号に欠番がある（§2 / §7 / 付録B）。** §2 は 2026-06 時点の自製品評価、§7 は外部データで
> 置換された事業計画、付録B は削除した文書の記録で、いずれも作者の内部文書に置いてある。
> 番号は振り直していない——他文書とコードから節番号で参照されているため。

---

## 0. 一行で

**収集は広く・最大に。浅い事前消化(rule-based)は捨てる。知能を capture-time から
use-time のエージェントに移す。エージェントが「今の必要」に絞って統合・先回り実行し、
その判断を人間が編集できる md で書き戻す。**

---

## 1. 目的（再確認）

- 「説明ゼロでAIがあなたを知っている」「**なんで知ってるの?** の瞬間」。
- 究極：広く集めた情報をエージェントが統合判断し、**今重要なことを先回りして実行**する
  ＝ Fragment の ACE（Autonomous Context Engine）の**個人版**。
- 前提：**マルチエージェント社会 + コンテキスト拡大**。エージェントが整理・添削・大量処理
  してくれることが所与。だから収集は広くてよい。

---

## 3. 中核の分離：収集 ≠ 使用

| | 方針 |
|--|------|
| **収集 (capture)** | 広く・最大に取る。これからも増やす。AI社会では資産。**ここは絞らない** |
| **使用 (use)**     | ここが製品。生ログ垂れ流しでも、lossyな事前要約でもない。**エージェントが今の必要に絞って組み立てる** |

---

## 4. アーキテクチャの帰結（残す / 消す）

| 層 | 判断 | 中身 |
|----|------|------|
| **収集（firehose）** | 残す・拡張 | 作業文脈の信号を広く。**1イベント=1ファイルは禁止**。追記ログ/小DBに |
| **浅い事前消化** | **消す** | Analytics統計・TimeBlock・FactExtractor が me.md に固めるrule-base。"微妙"の発生源 |
| **rule-baseの先回り** | 置換 | ProactiveEngine/PredictionEngine もrule-base → エージェント駆動に置き換え |
| **選択層（核）** | **作る** | use-timeのエージェント：今の必要 → 関連スライス選択 → 統合・判断 → 先回り提案/実行 |
| **書き戻し層** | 残す・堅牢化 | エージェントの判断を**編集可能なmd**で出す。**Curator**(provenance)が核 |
| **露出** | 残す | MCPで「フォルダ/索引を露出」。鋭い検索ツールを出す |

→ **me.md/now.md は「手書きrule-baseの成果物」ではなく「エージェントが必要に応じて
組み立てるキャッシュ/出力」になる。知能が capture-time から use-time に移る。**

---

## 5. 中核IP：選択の質（need-scoped context assembly）

> 「今いらない情報を渡すのは無意味」を裏返すと、製品の核心は1つ：
> **その時・その問いに対し、広い貯蔵から"ちょうど正しい最小スライス"だけを取り出す層。**
> ＝ ACE の "semantic context layer" の本質。「集める」ではなく「**今に対して正しく選ぶ**」。

### 選択品質の関数
```
選択品質 = (今の"必要"の鋭い言語化)
         × (貯蔵が"選べる形"に索引されているか)
         × (順位付け・絞り込みの質)
         × (使われた結果から学べるか)
```
embedding改善は4要素の一部にすぎない。効く順は以下。

### 設計原則（効く順）
1. **事前に当てにいかない。エージェントに取らせる。**
   一発RAGで詰め込む ❌ → MCPで粒度の細かい検索ツールを出し、エージェントに反復的に
   引かせる ✅。例：`recent_work(project)` / `notes_about(topic)` / `errors_today()` /
   `decisions(project)` / `whats_active_now()`。
   **選択の知能はエージェント、素材の質はmull。**（"mullは記憶であって頭脳ではない"と一致）
2. **"今"に錨を打つ。** 個人・先回りでは「今何をしているか」(アクティブな project/file/app、
   直近N行動、カレンダー)が relevance の支配的シグナル。検索を現在状態で条件付ける
   → 無関係な過去スライスが自然に落ちる。
3. **貯蔵を"選べる形"に（軽い構造化、要約ではない）。**
   - entity解決：「PantryApp」を keystroke/window-title/git/clipboard 横断で1実体に束ねる
   - 軸：time / entity / type(決定・エラー・自分宛メモ・コード) / session
   - salience を捕捉時に安く採点（自分宛メモ・コピーしたエラー >> ランダム打鍵片）
   - **要約は捨てる(損失)、構造化は残す(検索の取っ手)**
4. **二段構え：広く取って予算に絞る。** ①ハイブリッド候補検索(recency＋entity＋BM25＋
   embedding)で高再現率 → ②安いLLM/rerankerで「今の必要」に並べ替え、token予算内に圧縮。
   含める/要約して含める/落とす を per-item で**予算配分**。
5. **学習ループ：** エージェントが使ったスライス＝正ラベル、**人間がCuratorで直した/消した
   ＝最高品質のrelevanceラベル(無料)**。salience に還流。
6. **評価ハーネス：** (need, 理想の文脈) を20〜50本用意し precision/recall を測る。
   **これがないと"選択を良くする"はvibesになる。出発点。**

   > **✅ 完了（2026-07-19）**: [`eval/selection_eval.swift`](eval/selection_eval.swift)。
   > `Selection.rank` の **precision / recall / MRR** を **20ケース**で測る。
   > GRDB-free shim で Xcode ターゲット外・数秒で走る。
   > **残りは「作る」ではなく「回して、数字を出して、公開する」**（STRATEGY §4）。
   > ベースラインは**素の全文投入**との比較に取ること——それが ETH arXiv 2602.11988
   > （"context files don't improve success rates, +20% cost"）への直接の回答になる。

### mullの不当な強み（差別化）
1. **現在状態のライブ信号**（今の project/file/作業）→ 検索アンカー
2. **session/時間構造**（個人作業は塊で起きる）
3. **人間の編集＝無料の正解ラベル**

→ 差別化は「たくさん集める」では取れない（皆集める）。
**「個人のライブ文脈 × 人間の修正ループ」で選択を磨く**こと。

---

## 6. 人間所有・編集可能・provenance（Curatorが核）

- 対象ユーザー（Claude Code巧者）は**既に自分のドキュメントを持って回している**
  (CLAUDE.md/設計doc)。mullはそれを**置き換えず、自動で最新に保つ＋作業文脈で補強**する。
- ドキュメントは刻々変わる → **人間がいつでも直接編集・上書き・差し替えできる**こと
  (= プレーンmd、所有権は人間) と、**自動層が人間の編集を絶対に壊さない**こと
  (= provenance: agent/human/pinned) が**メンテ性の本体**。
- DBに閉じた自動生成物＝触れない＝メンテ不能。**folder-of-MD は必然。**
- ただし **v3 の `00_〜09_` ontology + synthesis + ingestion は"folder形式の最大主義版"**で違う。
  作るべきは**小さく・平らで・自明**なフォルダ。
- 外部pull(MCP ingestion)は**従**。信頼できる内部・自筆の世界を汚さない。対象ユーザーは
  管理外の自動流入を欲しがらない。

> **Curator こそが mull の本当の核**。周りの Analytics/TimeBlock/synthesis/ingestion は飾り。
> Curator のバグ（消したブロックの蘇生＝人間の編集破壊）は**メンテ性を直接損なう**。
> 投資すべきは「Curatorの堅牢化」であって新機能ではない。

### 6.1 `00_〜09_` ontology — 保留 → **廃止決定**（2026-08-09）

**本節が正本。** 上の「保留」は2026-06-02に書かれ、2ヶ月ぶん実装に反映されないままだった。
今回それを確定に変える。

**なぜ保留のままだったか（記録として残す）**: 実装 `b3f4e14 15:01:43` の**1時間後**に
本節 §6 の保留が書かれている（`131d313 16:05:01`、同日）。つまり ontology は
「保留を上書きした後発の決定」ではなく、**否定される前に出荷された残骸**だった。
残骸であることが2ヶ月見えなかったのは、体系が README の図と実装にはあり、
DIRECTION にだけ「保留」と書かれていたためである。

**実装照合で確定した事実**（2026-08-09、コマンドと出力は判断ログに残す）:

| 事実 | 根拠 |
|---|---|
| 番号フォルダを読むコードは `03_projects/*.md` と `06_knowledge/corrections/ledger.md` の2つだけ | 検索5経路（直接名 / `indexPath`・`folders`・`folder.path` / `MullDirectory.read(` 全件 / `markdownFiles(in:` 全件 / `index\.md`） |
| 唯一の読み手すら `index.md` を読まない | `MullDirectory.markdownFiles(in:)` が `index.md` を明示除外 |
| 選択層は vault の md を読まない | `ContextComposer.swift` / `Selection.swift` に `MullDirectory` 参照ゼロ |
| `02_work` / `04_career` には書き手が存在しない | `primaryDestination(forConnector:)` に 02/04 への分岐が無く、`SynthesisEngine.gatherItems` が常に空を返す |
| `00_identity/index.md` は `canonical: ../me.md` を名乗るが me.md と食い違う | me.md は事実ゼロ、00 は2件。`801ed60`（2026-07-19）が me.md からは推測を落とし、`FolderFiller.fillIdentity` は落とさなかった |

**決定**: 番号体系は browsable なカテゴリ体系としては廃止する。
残すのは **mull 自身の出力先**だけで、それは**ユーザーのカテゴリではない**。

> **カテゴリはユーザーのもの（`notes/` に自分で切る）。出力先は mull のもの（固定・平ら・自明）。**
> 番号体系の誤りは、この2つを1つの棚に混ぜ、**mull が埋められない棚をユーザーに向けて8つ並べた**ことにある。

目標形（実装は未反映。反映時に README のツリー図と、
SELECTION-LAYER §5 と HARNESS 第II部 §3 の corrections パス表記を同時に直す）:

```
~/mull/
  me.md  me.pinned.md  now.md  full.md  MEMORY.md  mull.md
  projects/       ← 03_projects から改名（DeliberationEngine の briefing）
  corrections/    ← 06_knowledge/corrections から昇格（訂正ループの台帳＝堀）
  inbox.md        ← 09_inbox/captures.md（QuickCapture）
  notes/          ← ユーザーが自分でカテゴリを切る場所
  daily/  memory/  _raw/
```

連動して止めたもの: `SynthesisEngine`（Phase C）/ `FolderFiller` の index 埋め /
`primaryDestination` の routing / `IngestionService` の inbox digest。いずれも本節冒頭が
保留にしていた「synthesis・ingestion」そのものなので、方針としては整合する。
`FolderOntology` は `VaultLayout` になり、残ったのは raw zone の定数と一方向移行だけ。

**移行で見つかった実バグ**: `VaultOwnership.of` が root ファイル名を**深さを問わず**
照合していたため、`projects/mull.md` が root の `mull.md`（mull が丸ごと書き直す orientation
ファイル）と誤認されていた。MCP の `write_note` は、自分の説明文が例として挙げているパスを
エージェントに拒否し、Files タブは briefing を読み取り専用で出していた。root ファイル名は
root でだけ意味を持つように直した。

**撤回基準**（契約3。これを書かずに変えると往復する——LICENSE の実例）:

| | |
|---|---|
| 期限 | フラット化から60日（2026-10-08） |
| 観測点A | `notes/` 配下にユーザーが切ったフォルダ数が **0 のまま** → 「自分でカテゴリを作る」が機能していない |
| 観測点B | `notes/` 直下の md が10件超、かつサブフォルダ0 → 置き場所が決まらず溜まっている |
| 原因の分離 | A/B が起きたとき「固定分類が要る」のか「New Folder の導線が弱い」のかを分ける。`+` → New Folder の実行回数が0なら後者（計測が無いのでフラット化と同時に足す） |
| 戻し方 | `FolderOntology` / `FolderFiller` / `SynthesisEngine` は git 履歴に残る（削除コミットから復元できる）。vault 側は `VaultLayout.migrate` と同型の一方向移行を1本書く |

**移行コストについて**: この判断の時点で `gh repo view` → `isPrivate: true, stargazerCount: 0`。
他ユーザーはゼロで、**public にする前が移行コスト最小の最後の瞬間**である。

---

## 8. 決定事項（要約）

1. 収集は広く・最大。**絞らない**。
2. 浅い事前消化(rule-base統計→md固め)は**捨てる**。
3. 知能を **use-timeのエージェント**に移す。mullは鋭い検索プリミティブを提供する側。
4. 製品の核は **need-scoped context assembly（選択層）**。現在状態アンカー＋エージェント反復取得。
5. 要約は捨て、**軽い構造化(entity/type/salience/session)** に投資。
6. **Curator（provenance付き編集可能md）が核**。堅牢化が最優先投資。folder-of-MD、最小・平ら。
7. 外部ingestionは従、内部・自筆・編集可能が主。
8. 評価ハーネスを先に作る。選択の質は測って初めて上がる。
9. ~~ソロ1年は**1本の先回りループをend-to-end**で。残りは足場。~~
   → **2026-08-08 改訂**: 技術の中身はそのまま。ただし**それを閉じたアプリの中に置かない**。
   MCPサーバーとして開き、選択の質を数字で示す（STRATEGY §2）。

---

## 9. 但し書き（統合時の補正）

§4 の「捨てる」を鵜呑みにしないための4点。これを含めて初めて自己無矛盾。

1. **「事前消化を全部捨てる」は行き過ぎ。lossyな要約だけ捨てる。**
   mull の公言価値「LLM無しで初日から動く」(CLAUDE.md) を壊さないため、capture-time の
   **安い構造化(entity/type/salience/session)は残す**。§4「消す」と §5.3「構造化は残す」の
   表現を揃える：殺すのは**rule-baseの要約をme.mdに固める**こと、構造化ではない。

2. **「知能は全部 use-time」だと誰も呼ばない限り mull は無動作。**
   先回り(proactive)には**何かが自走**しないと成立しない。選択層は受動(MCP検索)だけでなく、
   **定期 or 状態変化で自分を叩く能動トリガ**を持つ（= §7 の「1本の先回りループ」の駆動部）。

3. **評価ハーネス(§5.6)は"作られないのが常"。最優先で本当に20本作る。**
   無いと「選択を良くする」は vibes。着手順の先頭に固定。

4. **前提：収集が capture で死んでいる場合がある（権限）。**
   2026-06-02 時点で screenText/打鍵がゼロ（Accessibility/Input Monitoring 未許可）だった。
   選択層・先回りの前に、**権限を通して収集を実際に動かす**のが最初。材料が無ければ選択も空回り。

### 着手順（補正反映）
1. ✅ 収集を生かす（権限）→ 材料を確保
2. ✅ 軽い構造化(entity/type/salience) を capture-time に
3. ✅ MCP 鋭い検索ツール ＋ "今"アンカー（受動）＋ 能動トリガ
4. 1本の先回りループ end-to-end（駆動部＋選択＋成果物手渡し＋Curator書き戻し）
5. ✅ 評価20本（並行で早く）
6. Curator 堅牢化は通底の最優先 ← **継続**

> **2026-08-08 追記**: 1・2・3・5 は完了している。にもかかわらず事業の像が結ばなかった。
> **次の着手は 4 の続きではなく、STRATEGY §4 の「回して・整えて・開けて・言う」。**
> 4（先回りループ）は public 化の後、star が付いてから第2弾として出す方が効く——
> 先に出しても見る人がいない。


---

## 付録A. Epistemics — 正解の無い領域で提案する根拠

> PRODUCT.md から回収。PRODUCT.md 自体は削除した（v2/v3 は本文書が上書き済み、
> UI/学び の章は CLAUDE.md と重複）が、この章だけは**コード内の11箇所が参照しており、
> かつ他のどこにも書かれていない**。ここが正本。

### Epistemics — proposing without ground truth
The hardest question: Fragment/ACE works in procurement because there's a **verifiable** correct answer (invoice matches or it doesn't). Personal personality/behavior has **no ground truth**. So on what basis does mull "execute" and "propose"? Answer: **don't chase a correct answer — it doesn't exist. Use four substitutes.**

**1. The user is the oracle — proposals are A/B tests.**
mull doesn't assert truth; it floats a hypothesis and lets the user's reaction become the answer, after the fact.
- accepted → it was right; reinforce.
- ignored → it was wrong; suppress.
The "correct answer" emerges per-user, empirically, over time. (This is ACE's Reflector/Curator, but the reward signal is *user acceptance*, not task success.)

**2. Observation, not interpretation (most important).**
The safe form of "proposal" in a no-truth domain is to stick to facts in the log and avoid judgment.
- ❌ interpretation (no ground truth, painful when wrong): "You're avoiding this project." (§3.6 already proved judgment fails — users don't want to be judged.)
- ✅ observation (a verifiable fact in the record): "You've reopened this file 5 times this week." / "You got stuck here last week — still unresolved?"
Observations are checkable against the log, so the "correctness problem" disappears, and **the user's own brain supplies the meaning.** A proposal is not "say the right thing" — it's "place past-you in front of present-you at the right moment." That IS the "how do you know that?" mechanism.

**3. Predict behavior, not preference — manufacture ground truth.**
"What's right for this person" (preference/norm) is unverifiable. But "what this person will do next" (behavior) shows up in tomorrow's log — **verifiable.**
- unverifiable: "You should do this task."
- verifiable: "After lunch you'll return to the PantryApp work." → check the log tomorrow.
By predicting *behavior* instead of *preference*, mull can self-grade its proactivity against the log. It's the only way to create ground truth in a domain that has none — you fabricate it by predicting observable future behavior.

**4. Match execution to confidence × reversibility.**
With no ground truth, the safety mechanism is **reversibility**, not correctness. Only auto-execute actions whose error cost is ~zero.

| Confidence | Kind | Form of execution |
|-----------|------|-------------------|
| High | fact in log | **assert it** — "you did X" |
| Medium | pattern | **place as observation** — "you tend to… on Thursdays" |
| Low | interpretation / prediction | **make it a question** — "still on your mind?" |
| — | irreversible action | **don't** |

This is the *logical* basis for mull stopping at "organize" and never reaching "execute." Fragment can execute because its answers are verifiable; mull's domain is unverifiable, so irreversible execution is forbidden. **§3.6's "no execution" stance isn't philosophy — it's forced by the absence of ground truth.**

**Net:** mull is not a machine that outputs "the right answer." It's a machine that **places the right question and the right fact at the right moment.** The user produces the answer.

### 但し書き（2026-07 追記）— B との衝突を明示しておく

上の④は「正解が存在しないから不可逆な実行は禁止」と結論している。一方で mull は
**実行まで踏み込む方向**（提案するだけでなく、下書きを仕上げて差し出す）を採っている。
**この2つは同じ結論に別の理由で到達しているだけで、矛盾はしていない**:

- Epistemics ④: 不可逆な実行を禁じる（根拠＝ground truth の不在）
- 人間主権の線: 送信・実行・公開の最後の一押しは常に人間（根拠＝dignity）

つまり広げてよいのは**下書きの範囲**であって、実行の自動化ではない。
「実行方向に進んだから ④ は失効した」という読み方をしないこと。失効していない。

---

