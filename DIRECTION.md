# DIRECTION: アーキテクチャの帰結と方針

> 2026-06-02 の設計議論の結論です。CLAUDE.md（製品仕様）が「何を作るか」なら、これは
> 「どう作り直すか」。判断の根拠と、残す/消すの線引きを残します。
>
> **これが技術の北極星です。** 旧 `PRODUCT.md`（削除済み）の "Direction v2 / v3" を上書きします。
> v2/v3 から生き残るもの: mull はエージェントの記憶と良心、Curator（provenance）、
> recompilable context（ただし派生は use-time 組み立て）、epistemics、
> 行動ゲートは「1本の先回りループ」に縮小。
> 保留: v3 の `00_〜09_` ontology、外部 ingestion、capture-time synthesis（§4 と §6 参照）。
> このうち `00_〜09_` ontology は 2026-08-09 に保留から廃止へ変えました。正本は §6.1 です。
>
> ---
>
> §1〜§6・§8・§9 の技術方針は全て生きています。§5（選択層）がエージェントに渡す形を決め、
> §6（Curator）が唯一の堀です。§5.6 の評価ハーネスは完成しており、仕様と現在値の正本は
> [SELECTION-LAYER.md](SELECTION-LAYER.md) §6 にあります。
>
> **ただし本書は「どう作るか」を決めるもので、「そもそも作っていいか」は決めません。**
> それは [CLAUDE.md](CLAUDE.md) §0（解く場面と、今解けているか）にあり、§0 が本書に優先します。
> 選択層は §0 の場面 C と D に効く手段であって、それ自体が目的ではありません。
> ここは 2026-08-09 に「選択層が製品の実体」から書き換えました（CLAUDE.md §0.1）。
>
> 節番号に欠番があります（§2 / §7 / 付録B）。§2 は 2026-06 時点の自製品評価、§7 は外部データで
> 置換された事業計画、付録B は削除した文書の記録で、いずれも作者の内部文書にあります。
> 番号は振り直していません。他文書とコードから節番号で参照されているためです。

---

## 0. 一行で

**収集は広く、最大に。浅い事前消化（rule-based）は捨てる。知能を capture-time から
use-time のエージェントに移す。エージェントが「今の必要」に絞って統合し先回りして実行し、
その判断を人間が編集できる md で書き戻す。**

---

## 1. 目的（再確認）

- 「説明ゼロで AI があなたを知っている」「なんで知ってるの? の瞬間」。
- 究極的には、広く集めた情報をエージェントが統合判断し、今重要なことを先回りして実行すること。
  Fragment の ACE（Autonomous Context Engine）の個人版です。
- 前提はマルチエージェント社会とコンテキスト拡大。エージェントが整理も添削も大量処理も
  してくれることが所与なので、収集は広くて構いません。

---

## 3. 中核の分離: 収集 ≠ 使用

| | 方針 |
|--|------|
| **収集 (capture)** | 広く、最大に取る。これからも増やす。AI社会では資産。ここは絞らない |
| **使用 (use)**     | ここが製品。生ログ垂れ流しでも、lossy な事前要約でもない。エージェントが今の必要に絞って組み立てる |

### 3.1 「絞らない」の適用範囲（2026-08-15）

**打鍵の捕捉を既定オフのオプトインにしました。** 上の行と衝突して見えるので、どこが動いて
どこが動いていないかを書きます。

動いていないのは方針です。**入れた経路は一つも細くしていません。** 打鍵をオンにした mull は
前と一字も変わらず全入力を取ります。動いたのは、その経路を**インストールの判断に含めるのを
やめた**ことだけです。「広く取る」は許可を求める強さの話ではなく、許可された後に何を捨てるか
の話で、mull は今も何も捨てていません。

判断の材料は実測です（2026-06-01 から 75日、29,115イベント）。

| 経路 | イベント | 文字数 | 文字シェア |
|---|---|---|---|
| keystroke（Input Monitoring） | 13,782 (47%) | 115,405 | **3.0%** |
| windowBody（Accessibility） | 1,053 (4%) | 3,073,147 | **80.6%** |

打鍵は3秒フラッシュなので、64%が10字未満、75日で100字を超えたものが一つもありません。
そして78%が Code、つまり既にディスクと git にあり windowBody からも読めるテキストの重複です。
**この経路だけが見ているのは残りで、残りは私信とメモに偏ります。**

つまり Input Monitoring は、製品で最も信頼を失う許可を払って、大半の重複と、最も機微な一部を
集めていました。[CLAUDE.md](CLAUDE.md) §8.3 が訂正後に示した通り、受容を分けるのは保持量では
なく「用途・選択・局所性」の3点で、この変更は2つ目に効きます。**保持を減らす変更ではありません。**

| | |
|---|---|
| 撤回基準の期限 | 2026-10-14（オプトイン化から60日） |
| 観測点 | 打鍵オフのまま §0 の場面 C / D / B が劣化したか。`whats_active_now` の直近行動が空になる日が週2日以上 |
| 原因の分離 | 劣化したなら windowBody の取りこぼしを疑う（打鍵が埋めていた穴が見える）。劣化しないなら3%は最初から要らなかった |
| 戻し方 | 既定オンに戻す。本節を消す。上の表は動かさない |

実装は `Preferences.keystrokeCaptureEnabled` と `RecordingService.start()`、約束を固定して
いるのは `Tests/KeystrokeOptInTests.swift` です。

---

## 4. アーキテクチャの帰結（残す / 消す）

| 層 | 判断 | 中身 |
|----|------|------|
| 収集（firehose） | 残す・拡張 | 作業文脈の信号を広く。1イベント1ファイルは禁止。追記ログか小DBに |
| 浅い事前消化 | **消す** | Analytics統計、TimeBlock、FactExtractor が me.md に固める rule-base。「微妙」の発生源 |
| rule-base の先回り | 置換 | ProactiveEngine と PredictionEngine も rule-base なのでエージェント駆動に置き換える |
| 選択層（核） | **作る** | use-time のエージェント。今の必要から関連スライスを選び、統合し、先回り提案や実行に繋ぐ |
| 書き戻し層 | 残す・堅牢化 | エージェントの判断を編集可能な md で出す。Curator（provenance）が核 |
| 露出 | 残す | MCP でフォルダと索引を露出する。鋭い検索ツールを出す |

つまり me.md と now.md は「手書き rule-base の成果物」ではなく「エージェントが必要に応じて
組み立てるキャッシュや出力」になります。知能が capture-time から use-time に移ります。

---

## 5. 中核IP: 選択の質（need-scoped context assembly）

> 「今いらない情報を渡すのは無意味」を裏返すと、製品の核心は1つになります。
> その時、その問いに対して、広い貯蔵から「ちょうど正しい最小スライス」だけを取り出す層です。
> ACE の semantic context layer の本質でもあります。「集める」ではなく「今に対して正しく選ぶ」。

### 選択品質の関数

```
選択品質 = (今の"必要"の鋭い言語化)
         × (貯蔵が"選べる形"に索引されているか)
         × (順位付け・絞り込みの質)
         × (使われた結果から学べるか)
```

embedding の改善は4要素の一部にすぎません。効く順は以下です。

### 設計原則（効く順）

1. **事前に当てにいかない。エージェントに取らせる。**
   一発 RAG で詰め込むのではなく、MCP で粒度の細かい検索ツールを出し、エージェントに
   反復的に引かせます。例: `recent_work(project)` / `notes_about(topic)` / `errors_today()` /
   `decisions(project)` / `whats_active_now()`。
   選択の知能はエージェント、素材の質は mull です（「mull は記憶であって頭脳ではない」と一致）。
2. **「今」に錨を打つ。** 個人向けと先回りでは「今何をしているか」（アクティブな project、file、app、
   直近N行動、カレンダー）が relevance の支配的シグナルです。検索を現在状態で条件付けると、
   無関係な過去スライスが自然に落ちます。
3. **貯蔵を「選べる形」にする（軽い構造化。要約ではない）。**
   - entity 解決: 「PantryApp」を keystroke / window-title / git / clipboard 横断で1実体に束ねる
   - 軸: time / entity / type（決定・エラー・自分宛メモ・コード）/ session
   - salience を捕捉時に安く採点する（自分宛メモやコピーしたエラーは、ランダム打鍵片より遥かに高い）
   - 要約すると原文が失われます。索引を足しても失われません
4. **二段構え。広く取って予算に絞る。** まずハイブリッド候補検索（recency、entity、BM25、
   embedding）で高再現率を取り、次に安い LLM か reranker で「今の必要」に並べ替えて
   token 予算内に圧縮します。含める、要約して含める、落とすを per-item で予算配分します。
5. **学習ループ。** エージェントが使ったスライスが正ラベルです。人間が Curator で直した、
   あるいは消したという事実が最高品質の relevance ラベルで、しかも無料です。salience に還流します。
6. **評価ハーネス。** (need, 理想の文脈) を20〜50本用意して precision/recall を測ります。
   これがないと「選択を良くする」は vibes になります。ここが出発点です。

   > **✅ 完了（2026-07-19、その後拡張）**: [`eval/selection_eval.swift`](eval/selection_eval.swift)。
   > `Selection.rank` の precision / recall / MRR を32ケースで測ります。
   > GRDB-free shim で Xcode ターゲット外に置いてあり、数秒で走ります。
   > 残りは「作る」ではなく「回して、数字を出して、公開する」です。
   > ベースラインは素の全文投入との比較に取ります。それが ETH arXiv 2602.11988
   > （"context files don't improve success rates, +20% cost"）への直接の回答になります。

### mull の強み（差別化）

1. 現在状態のライブ信号（今の project、file、作業）が検索アンカーになる
2. session と時間構造（個人作業は塊で起きる）
3. 人間の編集が無料の正解ラベルになる

差別化は「たくさん集める」では取れません（皆集めています）。
「個人のライブ文脈と人間の修正ループ」で選択を磨くことが差になります。

---

## 6. 人間所有・編集可能・provenance（Curator が核）

- 対象ユーザー（Claude Code 巧者）は既に自分のドキュメントを持って回っています
  （CLAUDE.md や設計 doc）。mull はそれを置き換えず、自動で最新に保ち、作業文脈で補強します。
- ドキュメントは刻々変わります。だから人間がいつでも直接編集し、上書きし、差し替えられること
  （プレーン md、所有権は人間）と、自動層が人間の編集を壊さないこと
  （provenance: agent / human / pinned）が、メンテ性の本体になります。
- DB に閉じた自動生成物は触れず、メンテできません。だから folder-of-MD が必然になります。
- ただし v3 の `00_〜09_` ontology、synthesis、ingestion は「folder 形式の最大主義版」で、
  これとは違います。作るべきは小さく、平らで、自明なフォルダです。
- 外部 pull（MCP ingestion）は従です。信頼できる内部と自筆の世界を汚しません。
  対象ユーザーは管理外の自動流入を欲しがりません。

> **Curator こそが mull の本当の核です。** 周りの Analytics、TimeBlock、synthesis、ingestion は飾りです。
> Curator のバグ（消したブロックの蘇生、つまり人間の編集破壊）はメンテ性を直接損ないます。
> 投資すべきは Curator の堅牢化であって、新機能ではありません。

### 6.1 `00_〜09_` ontology を廃止した（2026-08-09）

**本節が正本です。** 上の「保留」は 2026-06-02 に書かれ、2ヶ月ぶん実装に反映されないままでした。
今回それを確定に変えました。

**なぜ保留のままだったか**（記録として残します）。実装 `b3f4e14 15:01:43` の1時間後に
§6 の保留が書かれています（`131d313 16:05:01`、同日）。つまり ontology は
「保留を上書きした後発の決定」ではなく、否定される前に出荷された残骸でした。
残骸であることが2ヶ月見えなかったのは、体系が README の図と実装にはあり、
DIRECTION にだけ「保留」と書かれていたためです。

**実装照合で確定した事実**（2026-08-09。コマンドと出力は判断ログに残しました）:

| 事実 | 根拠 |
|---|---|
| 番号フォルダを読むコードは `03_projects/*.md` と `06_knowledge/corrections/ledger.md` の2つだけ | 検索5経路（直接名 / `indexPath`・`folders`・`folder.path` / `MullDirectory.read(` 全件 / `markdownFiles(in:` 全件 / `index\.md`） |
| 唯一の読み手すら `index.md` を読まない | `MullDirectory.markdownFiles(in:)` が `index.md` を明示除外 |
| 選択層は vault の md を読まない | `ContextComposer.swift` と `Selection.swift` に `MullDirectory` 参照がゼロ |
| `02_work` と `04_career` には書き手が存在しない | `primaryDestination(forConnector:)` に 02/04 への分岐が無く、`SynthesisEngine.gatherItems` が常に空を返す |
| `00_identity/index.md` は `canonical: ../me.md` を名乗るが me.md と食い違う | me.md は事実ゼロ、00 は2件。`801ed60`（2026-07-19）が me.md からは推測を落とし、`FolderFiller.fillIdentity` は落とさなかった |

**決定**: 番号体系は browsable なカテゴリ体系としては廃止します。
残すのは mull 自身の出力先だけで、それはユーザーのカテゴリではありません。

> カテゴリはユーザーのものです（`notes/` に自分で切る）。出力先は mull のもので、固定で、平らで、自明です。
> 番号体系の誤りは、この2つを1つの棚に混ぜ、mull が埋められない棚をユーザーに向けて8つ並べたことにあります。

現在の形（`VaultLayout` が一方向移行を持ちます）:

```
~/mull/
  me.md  me.pinned.md  now.md  full.md  rules.md  MEMORY.md  mull.md
  projects/       ← 03_projects から改名（DeliberationEngine の briefing）
  corrections/    ← 06_knowledge/corrections から昇格（訂正ループの台帳）
  inbox.md        ← 09_inbox/captures.md（QuickCapture）
  notes/          ← ユーザーが自分でカテゴリを切る場所
  daily/  memory/  _raw/
```

連動して止めたもの: `SynthesisEngine`（Phase C）、`FolderFiller` の index 埋め、
`primaryDestination` の routing、`IngestionService` の inbox digest。いずれも本節冒頭が
保留にしていた synthesis と ingestion そのものなので、方針としては整合します。
`FolderOntology` は `VaultLayout` になり、残ったのは raw zone の定数と一方向移行だけです。

**移行で見つかった実バグ**: `VaultOwnership.of` が root ファイル名を深さを問わず照合していたため、
`projects/mull.md` が root の `mull.md`（mull が丸ごと書き直す orientation ファイル）と
誤認されていました。MCP の `write_note` は、自分の説明文が例として挙げているパスを
エージェントに拒否し、Files タブは briefing を読み取り専用で出していました。
root ファイル名は root でだけ意味を持つように直しました。

**撤回基準**（契約3。これを書かずに変えると往復します。LICENSE が実例です）:

| | |
|---|---|
| 期限 | フラット化から60日、つまり 2026-10-08 |
| 観測点A | `notes/` 配下にユーザーが切ったフォルダ数が0のまま。「自分でカテゴリを作る」が機能していない |
| 観測点B | `notes/` 直下の md が10件超で、かつサブフォルダ0。置き場所が決まらず溜まっている |
| 原因の分離 | A か B が起きたとき、「固定分類が要る」のか「New Folder の導線が弱い」のかを分ける。`+` から New Folder の実行回数が0なら後者（計測が無いのでフラット化と同時に足す） |
| 戻し方 | `FolderOntology` / `FolderFiller` / `SynthesisEngine` は git 履歴に残っている（削除コミットから復元できる）。vault 側は `VaultLayout.migrate` と同型の一方向移行を1本書く |

**移行コストについて**: この判断の時点で `gh repo view` は `isPrivate: true, stargazerCount: 0`。
他ユーザーはゼロで、public にする前が移行コスト最小の最後の瞬間でした。

---

### 6.2 GUI は vault を編集する場所をやめる（2026-08-14）

**本節が正本です。** CLAUDE.md §1 と README「The GUI」節は、この節を指すポインタに変えました。

作者の実 vault の `memory/` に、`Obsidian food log` と `MD Editor Plus (VS Code extension)` の
2件が入っています。md を書く場所は既に2つあり、どちらも1日中開いています。
mull の Files タブがそれに勝つ見込みはありません。

**実装照合で確定した事実**（2026-08-14。コマンドと出力は判断ログに残しました）:

| 事実 | 根拠 |
|---|---|
| Files タブは `FullWindowView.swift` 2,823行のうち約1,840行 | `// MARK:` の 476行（Watching the vault）から 2320行（Helpers 末尾）まで。999–1044 のタブ振り分けだけが他と共有 |
| 精度の劣化はファイル固有ではない | `now.md` の壊れた行 `A. カルテが濃くなる（本命）` は clipboard イベント由来（`where textContent like '%カルテが濃くなる%'` → `Code / clipboard / Pet / note`）。生成しているのは `CurrentState.recentActions` で、これは MCP `whats_active_now` の本体でもある |
| 日次要約は事実として正しい | 2026-08-11 の要約の6項目すべてが同日の windowTitle に一致（ローカライズ不足／オフライン誤表示／ペイウォールUI／パネル文字サイズ／iOS-web 差分／M&A 価値評価）。捏造は見つからなかった |
| 日記のファイルは存在しない | `MullEngine.writeDailyFile` は no-op。`daily/YYYY/MM/DD.md` は `LiveContextGenerator.snapshotDaily` が `full.md` を60秒ごとに上書きしたもの |
| 日記は3日止まっている | `daily_summaries` の実体ある行は通算3件（08-09 / 08-11 / 06-10）。`mull_lock.lastSummaryAt` は 2026-08-11 15:39 UTC。08-12（3,742イベント）と 08-14（2,633イベント）は要約が無く、`ConsolidationScheduler` の3ゲートは現在すべて開いている |

**決定**:

> GUI が持つのは、人が毎日見る2つだけです。予定と実績を並べるカレンダーと、その日の記録が入る md。
> vault を編集する場所は mull ではありません。Finder と Obsidian と VS Code がそこにあります。

出力としての md は残ります。畳むのは編集 UI だけで、`~/mull` は今日と同じプレーンな md のままです。
MCP の13ツールと `me.md` / `now.md` も残し、場面 B の撤回基準（2026-11-07）は動かしません。
「精度が悪いからファイルをやめる」ではないのは、精度の発生源が `CurrentState` にあって
ファイル側に無いからです。上の表の2行目がその根拠で、ファイルを消しても
`whats_active_now` に同じものが残ります。

**未検証の外部事実が1つ隣にあります**（契約1。根拠に使っていないことを明記します）。
CLAUDE.md §7.3 は「日報自動生成がコモディティ化したため主商品から降ろした」と書いており、
本節はその降ろした先に人間向けの主 surface を置く判断です。この一文の現在値は
2026-08-14 時点で確認していません。本節の根拠は市場ではなく実測（作者の使用と配線の状態）に
閉じており、外部事実が動いても上の5行は変わりません。動くのは Subtitle / Tagline / Category を
「AIカレンダー」に寄せるかどうかのほうで、そちらは 2026-08-14 に決着しました。**寄せません。**
理由と根拠へのポインタは CLAUDE.md §1 が正本です。同日、製品の重心をカレンダーに置く決定も
取りましたが、Identity は動いていません。重心の側の撤回基準は CLAUDE.md §0 場面 E にあります。

**実装状態**（2026-08-15 に完了。順序には意味がありました。壊れた状態のまま削除を決めないため）:

1. ✅ **日記が止まる原因を特定して直した。** 原因は2つで、どちらも外から見えませんでした。
   時間ゲートが「前回の完了から24時間」を測っていて、唯一の呼び出し元は毎日同じ時刻に鳴る
   タイマーだったこと。つまり次の発火時点の経過は常に24時間から前回の所要時間を引いた値で、
   08-09 の実行が67.8秒かかった結果 08-10 が拒否されました。**書かれた記録は原理的に
   1日おきにしか出ません。** もう1つは、その時刻にアプリが動いていなかった日には
   二度目の機会が無かったことです（08-12 がこれ）。ゲートは「この日の記録がまだ無いか」を
   聞くようになり、起動時の取りこぼし補償が付きました（`ConsolidationSchedulerTests` 9件）
2. ✅ `writeDailyFile` の no-op を解消。`daily/YYYY/MM/DD.md` は日記本体になり、
   DB にしか無かった日はディスクに出ました。`full.md` の60秒スナップショットは廃止
   （`DailyFileTests` 8件）
3. ✅ `CurrentState.recentActions` を修正。コピーは「コピーした」と書かれ、ラベルではなく
   文書の断片（切り詰めが必要な長さ）は落ち、アプリ名を繰り返すだけのタイトルも落ちます
4. ✅ Files タブを撤去。`FullWindowView` は 2,823行から 979行に、未使用になった
   `MarkdownTextEditor`（1,408行）も削除。サイドバーは Home / Calendar / Live / Chat の4行です。

   `me.pinned.md` の編集のために `AboutYouView` を一度残しましたが、**同日中に取り下げました。**
   Settings › General「Your answers」が既にそのファイルを持っていた（編集・リセット・
   保留行の表示）ためで、固有機能は重複でした。残っていたのはエージェント向けに書かれた
   me.md を、それについて書かれている本人に見せる画面です。1つのファイルに編集口を2つ置くのは、
   この窓が繰り返してきた誤りでした

5. ✅ **その過程で me.md の中身が実際に悪いことが分かり、直しました。** §7.1 の線がここでは
   守られていませんでした。詳細は下の §6.3

### 6.3 「Who I am」は観測を人格にしない（2026-08-15）

**本節が正本です。** §7.1（観測できないことを主張しない）の、me.md における具体形です。

§6.2 の作業中に画面を開いて分かりました。me.md は4行あり、そのうち3行が**1日の観測を
恒常的な性質に昇格させたもの**で、しかも日付が落ちていました。証拠は同じ DB 行の中に
最初からありました。`content` が「today」と言い、`description` が「regularly」と言い、
me.md が描くのは `description` のほうです。

| me.md の行 | 元の `content` | createdAt → updatedAt |
|---|---|---|
| Regularly uses LINE for messaging. | LINE was used extensively **today** (high activity on **10 June 2026**) | 06-10 → 06-10 |
| Often does heavy video editing and coding in afternoons. | **Today** (10 June 2026) shows a pattern: … | 06-10 → 06-10 |
| Prefers Claude for AI assistance; used frequently (updated 11 Aug 2026) | Used Claude repeatedly today for coding help | 06-10 → **08-11** |
| 通知が多すぎて操作の邪魔になると感じた（2026-08-09） | 日中に通知が頻繁に発生して作業の邪魔になった | 08-09 → 08-09 |

上2行は 66日間一度も再観測されないまま、「この人はこういう人だ」として全エージェントに
配られ続けていました。

**決定**: 判定は `createdAt == updatedAt`（一度書かれ、二度と確認されていない）です。
言語解析もモデルも要りません。再観測された記憶は残り、一度きりの観測は30日で識別を失います。
そして**残る行はすべて、最後に観測された日を持ちます**。読み手が判断できる形にするのが
§7.1 の要求だからです（説明文が既に年を含むときは足しません。1行に日付が2つあるのは
0個より悪い）。

実装は `MemoryEntry.isIdentity` / `identityLine` で、me.md を書く2つの経路
（`LiveContextGenerator.generateMe` と `MullEngine.generateLayerA`）が同じ規則を通ります。
固定しているのは `Tests/IdentityLineTests.swift` で、フィクスチャは上の表の実データそのものです。

実データでの結果: KEEP 2件（Claude / 通知）、DROP 2件（LINE / 午後の編集）。

**生成側も直しました（同日）。** 上の規則は「確認されないものは人格にしない」だけで、
モデルが最初に一般化を書くこと自体は止めていませんでした。原因はプロンプトにあり、
**mull が明示的に「working patterns の記憶を作れ」と指示していました。** 1日しか見せていない
モデルにパターンを書けと言えば、証拠のない一般化が返ってきます。「Often does heavy video
editing…」はその指示の産物です。

書き換えた点は2つです。

1. **観測を書かせる。** 「あなたが見ているのは1日で、他の日は見えていない。
   *usually / often / regularly / prefers / tends to* は、見せられていない日についての主張です」
2. **繰り返しは Confirm させる。** 今日が既存の記憶と同じことを示したら、
   新しい情報が無くても `update` を出す。これが**上の規則と対になっています**。
   日数を数えるのは mull の仕事で、「今日は先週の火曜と同じことだ」と気付けるのはモデルだけです。
   既存記憶の一覧には最終確認日を添えるようにしました（`seen once, on 2026-06-10` /
   `first seen …, last confirmed …`）。それが無ければ「また」の意味が決まりません。

固定は `Tests/ConsolidationPromptTests.swift`。旧文言（`working patterns`）が復活しないことも
含めて見ています。

**残っている限界**（プロンプトは保証ではありません）: モデルが Confirm を一度も出さなければ、
すべての記憶が単発観測のまま30日で識別を失い、me.md の mull 側は空になります。これは
故障ではなく、この設計での正しい振る舞いです。**何も確認されていないなら、mull は
その人について何も主張しない。**空の me.md は、間違った me.md より §7.1 に忠実です。

---

**撤回基準**（契約3。§6.2 の決定について）:

| | |
|---|---|
| 期限 | 2026-09-13（30日） |
| 観測点 | `daily/` が日記本体になった後、`select count(*) from daily_summaries where length(content)>300 and date>'2026-08-14'` が20件未満（30日の3分の2を下回る） |
| 原因の分離 | ファイルは生成されているのに読まれていないなら製品の問題で、特化しても意味がない。生成自体が止まるなら配線の問題で、打ち手が違う。`daily/` のファイル数と、そのファイルを開いた記録（`recording_events` の windowTitle）で分ける |
| 戻し方 | Files タブの削除は戻しません（畳んでもカレンダーと日記は失われないため、戻す理由にならない）。戻すのは主画面をカレンダーに寄せた文書側だけです |

---

## 8. 決定事項（要約）

1. 収集は広く、最大に。絞りません。
2. 浅い事前消化（rule-base 統計を md に固めるもの）は捨てます。
3. 知能を use-time のエージェントに移します。mull は鋭い検索プリミティブを提供する側です。
4. 製品の核は need-scoped context assembly（選択層）。現在状態アンカーとエージェント反復取得。
5. 要約は捨て、軽い構造化（entity / type / salience / session）に投資します。
6. Curator（provenance 付き編集可能 md）が核。堅牢化が最優先投資。folder-of-MD で、最小、平ら。
7. 外部 ingestion は従、内部と自筆と編集可能が主。
8. 評価ハーネスを先に作ります。選択の質は測って初めて上がります。
9. ~~ソロ1年は1本の先回りループを end-to-end で。残りは足場。~~
   2026-08-08 改訂: 技術の中身はそのままですが、それを閉じたアプリの中に置きません。
   MCP サーバーとして開き、選択の質を数字で示します。

---

## 9. 但し書き（統合時の補正）

§4 の「捨てる」を鵜呑みにしないための4点です。これを含めて初めて自己無矛盾になります。

1. **「事前消化を全部捨てる」は行き過ぎです。lossy な要約だけ捨てます。**
   mull の公言価値「LLM 無しで初日から動く」を壊さないため、capture-time の安い構造化
   （entity / type / salience / session）は残します。§4 の「消す」と §5-3 の「構造化は残す」の
   表現を揃えます。殺すのは rule-base の要約を me.md に固めることであって、構造化ではありません。

2. **「知能は全部 use-time」だと、誰も呼ばない限り mull は無動作です。**
   先回り（proactive）には何かが自走しないと成立しません。選択層は受動（MCP 検索）だけでなく、
   定期または状態変化で自分を叩く能動トリガを持ちます。

3. **評価ハーネス（§5-6）は「作られないのが常」です。最優先で本当に作ります。**
   無いと「選択を良くする」は vibes になります。着手順の先頭に固定します。

4. **前提として、収集が capture で死んでいる場合があります（権限）。**
   2026-06-02 時点で screenText と打鍵がゼロでした（Accessibility と Input Monitoring が未許可）。
   選択層や先回りの前に、権限を通して収集を実際に動かすのが最初です。
   材料が無ければ選択も空回りします。

### 着手順（補正反映）

1. ✅ 収集を生かす（権限）。材料を確保する
2. ✅ 軽い構造化（entity / type / salience）を capture-time に
3. ✅ MCP の鋭い検索ツールと「今」アンカー（受動）、そして能動トリガ
4. 1本の先回りループを end-to-end（駆動部、選択、成果物手渡し、Curator 書き戻し）
5. ✅ 評価ハーネス（並行で早く）
6. Curator 堅牢化は通底の最優先。継続

> **2026-08-08 追記**: 1・2・3・5 は完了しています。にもかかわらず事業の像が結びませんでした。
> 次の着手は 4 の続きではなく、「回して、整えて、開けて、言う」です。
> 4（先回りループ）は public 化の後、star が付いてから第2弾として出すほうが効きます。
> 先に出しても見る人がいません。

---

## 付録A. Epistemics: 正解の無い領域で提案する根拠

> PRODUCT.md から回収しました。PRODUCT.md 自体は削除しています（v2/v3 は本文書が上書き済み、
> UI と学びの章は CLAUDE.md と重複）が、この章だけはコード内の11箇所が参照しており、
> かつ他のどこにも書かれていません。ここが正本です。

### Epistemics: proposing without ground truth

The hardest question. Fragment and ACE work in procurement because there is a verifiable correct
answer: the invoice matches or it does not. Personal behavior has no ground truth. So on what
basis does mull propose anything? The answer is that you do not chase a correct answer, because
it does not exist. You use four substitutes.

**1. The user is the oracle. Proposals are A/B tests.**
mull does not assert truth. It floats a hypothesis and lets the user's reaction become the answer,
after the fact. Accepted means it was right, so reinforce it. Ignored means it was wrong, so
suppress it. The correct answer emerges per user, empirically, over time. This is ACE's
Reflector and Curator, except the reward signal is user acceptance rather than task success.

**2. Observation, not interpretation.** This is the most important one.
In a domain with no truth, the safe form of a proposal is to stick to facts in the log and avoid
judgment.

- Interpretation has no ground truth and is painful when wrong: "You're avoiding this project."
  Judgment fails because users do not want to be judged.
- Observation is a verifiable fact in the record: "You've reopened this file 5 times this week."
  Or: "You got stuck here last week. Still unresolved?"

Observations are checkable against the log, so the correctness problem disappears, and the user's
own brain supplies the meaning. A proposal is not "say the right thing". It is "place past-you in
front of present-you at the right moment". That is the "how do you know that?" mechanism.

**3. Predict behavior, not preference. Manufacture ground truth.**
"What is right for this person" (preference, norm) is unverifiable. But "what this person will do
next" (behavior) shows up in tomorrow's log, and is verifiable.

- Unverifiable: "You should do this task."
- Verifiable: "After lunch you'll return to the PantryApp work." Check the log tomorrow.

By predicting behavior instead of preference, mull can grade its own proactivity against the log.
It is the only way to create ground truth in a domain that has none. You fabricate it by
predicting observable future behavior.

**4. Match execution to confidence times reversibility.**
With no ground truth, the safety mechanism is reversibility, not correctness. Only auto-execute
actions whose error cost is close to zero.

| Confidence | Kind | Form of execution |
|-----------|------|-------------------|
| High | fact in log | assert it: "you did X" |
| Medium | pattern | place as observation: "you tend to… on Thursdays" |
| Low | interpretation / prediction | make it a question: "still on your mind?" |
| Any | irreversible action | do not |

This is the logical basis for mull stopping at "organize" and never reaching "execute". Fragment
can execute because its answers are verifiable. mull's domain is unverifiable, so irreversible
execution is forbidden. The "no execution" stance is not philosophy. It is forced by the absence
of ground truth.

**Net:** mull is not a machine that outputs the right answer. It is a machine that places the
right question and the right fact at the right moment. The user produces the answer.

### 但し書き（2026-07 追記）: B との衝突を明示しておく

上の④は「正解が存在しないから不可逆な実行は禁止」と結論しています。一方で mull は
実行まで踏み込む方向（提案するだけでなく、下書きを仕上げて差し出す）を採っています。
この2つは同じ結論に別の理由で到達しているだけで、矛盾はしていません。

- Epistemics ④: 不可逆な実行を禁じる（根拠は ground truth の不在）
- 人間主権の線: 送信、実行、公開の最後の一押しは常に人間（根拠は dignity）

つまり広げてよいのは下書きの範囲であって、実行の自動化ではありません。
「実行方向に進んだから ④ は失効した」という読み方はしないでください。失効していません。
