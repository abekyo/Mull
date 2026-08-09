# DIRECTION — アーキテクチャの帰結と方針

> 2026-06-02 の設計議論の結論。CLAUDE.md（製品仕様）が「何を作るか」なら、これは
> 「**どう作り直すか**」。判断の根拠と、残す/消すの線引きを残す。
>
> **これが技術の北極星。** 旧 `PRODUCT.md`（削除済み・付録B）の "Direction v2 / v3" を上書きする。
> v2/v3 から生き残るもの：mull＝エージェントの記憶+良心 / Curator(provenance) / recompilable
> context（ただし派生は use-time 組み立て）/ epistemics / 行動ゲートは「1本の先回りループ」に縮小。
> 保留：v3 の `00_〜09_` ontology・外部 ingestion・capture-time synthesis（§4・§6 参照）。
>
> ---
>
> **2026-08-08 改訂**
>
> - **§7（ソロ・1年の勝ち筋）は STRATEGY-2026-08.md（非公開の内部文書） で全面置換された。**
>   外部市場データ（MARKET-2026-08.md／非公開の内部文書）により、§7 が名指ししていた
>   買い手 Cursor (Anysphere) が消滅している（2026-06-16 SpaceX が $60B で買収）ことが判明したため。
>   本書 §7 は**履歴として残すが、事業判断には使わない**。
> - **§1〜§6・§8・§9 の技術方針は全て生きている。** むしろ §5（選択層）が製品の実体になり、
>   §6（Curator）が唯一の堀として位置づけを上げた。
> - **§5.6 の評価ハーネスは完成済み**（`eval/selection_eval.swift`、20ケース）。§5.6 の但し書き参照。

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

## 2. 率直な現状評価（なぜ作り直すか）

- 直近の作業はほぼ全部**バグ潰し**だった（プライバシー漏洩・データ消失・並行性・
  レンダリング崩壊・誤推論）。新コードベースのバグ密度＝「鋭く信頼できる」ではなく
  「広く脆い」状態のシグナル。
- 製品の中核成果物 me.md が実際に**壊れて表示された**（英語と誤判定／矛盾する事実／
  ゴミProject）。
- 真因は**収集の広さではない**。**浅い事前消化（Analytics/FactExtractor/TimeBlock が
  生データを薄く要約して me.md に固める）と、生ログの垂れ流し**。
  → 「今いらない情報まで一緒に投げる」から微妙になる。

> 収集すること と それをどう使うか は**別物**。失敗は「使う層」にある。

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

---

## 7. ソロ・1年の勝ち筋（楔）— **2026-08-08 置換済み**

> **⚠️ 本節は履歴。事業判断には STRATEGY-2026-08.md（非公開の内部文書） を使うこと。**
>
> **何が間違っていたか**（外部データによる検証結果、MARKET-2026-08.md）:
>
> | 本節の想定 | 実際 |
> |---|---|
> | 売り先＝Cursor / Claude Code系 | **Cursor (Anysphere) は 2026-06-16 に SpaceX へ $60B で売却され消滅。** Anthropic が2025年以降に買ったのは Humanloop / Bun / Vercept / Runhouse / Stainless ＝**全て開発者インフラで、personal memory はゼロ** |
> | 「ゾッとする精度のデモ」で見せる | **デモは通貨ではない。** ソロ acqui-hire の全例（OpenClaw 196k★ / Alex Codes YC / Sky = Shortcuts創業者）が OSS採用数・YC・著名創業歴のどれかを先行させている。クローズドな macOS アプリはこの指標を持てない |
> | 「acqui-hire はその副産物」 | 方向は正しいが、**副産物が出る土壌（public な採用実績）が無い**ままだった |
>
> **生き残った部分**: 「差別化は集める量では取れない。**選択の質 + 個人データの修正ループ**」——
> これは完全に正しく、STRATEGY でも中核のまま。**間違っていたのは流通の想定だけ。**

### 当時の記述（履歴）

- 売り先：AIコーディング系（Cursor/Claude Code系）。1年・ソロ・acqui-hire。
- これは大きいビジョン（memory/retrieval/proactive は全AI企業が殺到中の最前線）。
  **差別化は「集める量」では取れない。選択の質 + 先回りループ + 個人データの修正ループ。**
- **たった1つの先回りループを end-to-end で完成させ、ゾッとする精度で見せる**：
  「広く収集 → エージェントが"あるタスク"に必要な文脈だけを的確に組み立て → 先回り実行/提案」。
  残りは全部その足場。

### 優先順位（**この4行は今も有効**）
1. **MCPで鋭い検索ツール ＋ "今の状態"アンカー**（エージェント駆動・現在条件付き） → ✅ 実装済み
2. **軽い構造化**（entity＋type＋salience）を捕捉時に → ✅ 実装済み
3. **評価ハーネス20本**（効果を測れる状態に） → ✅ 実装済み（§5.6）
4. あとから rerank・学習ループ → 未着手

> **1〜3 が終わっているのに事業が像を結ばなかったのは、技術ではなく流通が空白だったから。**
> STRATEGY §1 参照。

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

上の④は「正解が存在しないから不可逆な実行は禁止」と結論している。一方 CLAUDE.md §2 の
Final Goal は **B（実行する分身）**を採り、§3.6 の憲法で「下書きまで・発火は常に主」と
している。**この2つは同じ結論に別の理由で到達しているだけで、矛盾はしていない**:

- Epistemics ④: 不可逆な実行を禁じる（根拠＝ground truth の不在）
- 分身の憲法 1: 送信・実行・公開の最後の一押しは常に人間（根拠＝dignity）

つまり分身が広げてよいのは**下書きの範囲**であって、実行の自動化ではない。
「分身に進んだから ④ は失効した」という読み方をしないこと。失効していない。

---

## 付録B. 削除したドキュメント（2026-07）

| 文書 | 理由 |
|------|------|
| `PRODUCT.md` | v2/v3 は本文書が明示的に上書き済み。UI/ターゲット/学びの章は CLAUDE.md と重複。唯一固有だった Epistemics は付録A に回収 |
| `ONBOARDING.md` | 「Fortune Teller Strategy」— cold reading / **Barnum効果** / framing の実装指示書。コード側は既に正しい判断で撤退済み（`InsightPhrases.swift:9`「他人のデータについても意味が通る文は、観測ではなく星占いだ」）だが、仕様書だけが残り、次の書き手に再導入を指示する状態だった。DESIGN-NORTHSTAR の「尊厳」と同居できない |

北極星は **DIRECTION.md（どう作るか）** と **DESIGN-NORTHSTAR.md（どう見せるか）**、
製品仕様は **CLAUDE.md** の3本。衝突したら DESIGN-NORTHSTAR > DIRECTION > CLAUDE.md。

> **2026-08-08 改訂**: これに **STRATEGY-2026-08.md（誰に何を出すか）** が加わった。
> 序列は **STRATEGY（事業） > DIRECTION（技術） > CLAUDE.md（仕様）**。
> DESIGN-NORTHSTAR / DESIGN.md は UI/意匠に限って最上位のまま——ただし**当面凍結**
> （CLAUDE.md §9）。中身は温存してあり、UI 作業を再開する日にそのまま有効。
