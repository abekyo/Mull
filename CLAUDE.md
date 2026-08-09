# mull: Product Specification

> **文書の序列**
>
> | 文書 | 何を決めるか | 序列 |
> |---|---|---|
> | 本書 §0（これは何に効くか） | 解く問題と、今解けているか | **全文書に優先** |
> | [DIRECTION.md](DIRECTION.md) | 作り方と判断の根拠 | 技術については最上位 |
> | [SELECTION-LAYER.md](SELECTION-LAYER.md) | 中核IP（選択層）の具体設計 | DIRECTION の従属 |
> | [MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md) | データ層の構造（領土/地図/モード） | DIRECTION の従属 |
> | [HARNESS.md](HARNESS.md) | 訂正ループの実装仕様（§7.3 の実装） | DIRECTION の従属 |
> | CLAUDE.md（本書） | 製品仕様 | 上記に従属 |
> | [WRITING.md](WRITING.md) | UI文言と vault 文言の書き方 | 本書の従属 |
>
> 衝突したら **§0 > DIRECTION > CLAUDE.md の残り**。
> §0 が上にあるのは、他の文書が「どう作るか」を決めているのに対し、
> §0 だけが「そもそも作っていいか」を決めるからです。
>
> 節番号に欠番があります（§2 / §3 / §9 / §11 / §12）。事業の線、非ゴールの選定、UI凍結の判断、
> 競合比較、公開までの順序は作者の内部文書に置いてあり、このリポジトリには入れていません。
> 番号は振り直していません。コードコメントと他文書から27箇所が節番号で本書を指しており、
> 動かすと参照が全部ずれるためです。欠番は削除の痕跡であって、隠した跡ではありません。
>
> ただし読者に関わる約束は公開側に残してあります。カレンダーへの書き込みで越えない4本の線と、
> 「餌と呼ばない・人間を product にしない」の3不変項は [SECURITY.md](SECURITY.md) にあります。

---

## 0. これは何に効くか（全文書に優先する）

> **この表に紐づかない作業はしない。** バグ修正も、リファクタも、公開準備も。
> どれにも当たらない変更を思いついたら、場面を足すか、やらないかを先に決めます。

| # | 場面 | 今どうなるか | mull で何をするか | 今動くか |
|---|---|---|---|---|
| **C** | 月曜に戻って、金曜の続きが思い出せない | git log と開いたままのタブから再構成する | `whats_active_now` と `search` が金曜の作業をそのまま出す | ✅ |
| **D** | エージェントに毎回同じ前提を説明し直す | 「Swift」「GRDB」「macOS 14」を毎回打つ | `get_user_context` と Copy context が観測から自動で渡す | ⚠ |
| **B** | エージェントが同じ直され方を繰り返す | 同じ指摘を何度もする。直した事実はどこにも残らない | あなたの訂正が `rules.md` の規則になり、次のセッションでエージェントが読む | ✅ |
| **A** | 作っているものが頭の中で分散し、次に何をすべきか分からなくなる | 決めたはずの方針とずれ、本質でない所を触り続ける | 決定とその理由を引く（`get_knowledge` / `search`） | ⚠ |

**場面の出所**（契約1。人物についての推測を場面として書かない）:
A と B は 2026-08-09 のセッションでの実観測、C と D は作者による確認です。

**B が ✅ になった経路**（2026-08-09 に開通）:

```
Curator が訂正を検知 → Card に §1–3 を書く（§1 は whats_active_now のスナップショット）
  → get_corrections がエージェントに渡す → エージェントが curate で §7 の規則を書き戻す
  → RuleBook が rules.md に集める → get_user_context と mull://rules が毎回渡す
```

ただし依存が1つあります。解釈するのはエージェントで、mull ではありません（§0.1）。
エージェントが `get_corrections` を呼ばなければ規則は増えない。`serverInstructions` で
仕事の区切りに呼ぶよう指示していますが、これは強制ではありません。撤回基準の観測点はここを見ます。

**D が ⚠ に落ちた理由**（2026-08-09）: 渡してはいますが、質を測っていませんでした。
実際の Copy context 出力を読むと、約25行のうち使えるのは2〜3行で、残りは無関係な視聴履歴、
文の断片がプロジェクト名になったもの、1分や2分の滞在でした。しかも `ContextComposer` は
`Selection` を一度も呼ばないので、README の F1 0.919 はこの経路を1文字も説明していません。
3つのフィルタ（consume はアンカー一致時のみ、節を含む句は entity にしない、5分未満は出さない）を
入れて `ContextComposerTests` で固定しましたが、**測っているのはラベル付きの1ケースだけ**です。
✅ に戻す条件は、`eval/real/` と同じ形で実ログの窓を採点できるようにすること。

**A が ⚠ の理由**: mull が解けるのは「過去に何を決めたか」までです。「次に何をすべきか」は
方針の問題で、それを持つのは道具ではなくこの文書のほうです。半分は mull では解きません。

> C と D は他社もやっています（ActivityWatch / Screenpipe / Mem0）。B だけが mull にしかありません。
> 2026-08-09 まで、動いているものは競争にならず、競争になるものが動いていませんでした。
> 今は動きます。使われるかどうかはこれから測ります。

### 0.1 mull の仕事

1. **広く正確に捕える**。今しか取れないものを、ロスなく
2. **今の必要に対して正しく選ぶ**。need-scoped context assembly（DIRECTION §5）
3. **訂正から規則を草案する**。1と2はここに仕える（§7.3 / [HARNESS.md](HARNESS.md)）

**3が中核です。規則は観測からは出てきません。**

「Xcode を使う」は記録から出ます。「選択肢を並べず推奨を1つ出せ」は、どれだけ記録しても
出てきません。それが現れるのは人が mull の出力を直した瞬間だけで、訂正が規則の唯一の源泉です。

ただし解釈は mull の仕事ではありません。mull が出せるのは材料と草案までで、判断軸を引くのは
人とエージェントです（HARNESS.md 第II部 §2 の自動化境界）。「賢さで勝負しない」という線は
動いていません。動いたのは、mull が黙って材料を置く場所から、草案を差し出して直される場所に
なったことです。

**撤回基準**（契約3。これを書かずに路線を変えると往復する）:

| | |
|---|---|
| 期限 | 開通（2026-08-09）から90日、つまり 2026-11-07 |
| 観測点 | `~/mull/rules.md` の規則が3件未満のまま |
| 原因の分離 | `corrections/` のカード数を見る。0件なら訂正自体が起きていない（出力が直すに値しないか、直す導線が無い）。カードはあるのに rules.md が空ならエージェントが解釈していない（`get_corrections` が呼ばれていない）。前者は製品の問題、後者は `serverInstructions` の問題で、打ち手が違う |
| 戻し方 | 仕事を1と2の2つに戻し、訂正ループは選択順を良くする内部機構に限定する。§0 から場面 B を落とす |

---

## 1. Identity

- **App Name**: mull
- **Subtitle**: Behavioral memory for coding agents.
- **Tagline**: Your agent knows what you told it. mull knows what you did.
- **Category**: Developer tool / Agent memory（旧: Productivity / Second Brain）
- **Platform**: macOS (Apple Silicon)
- **License**: MIT（2026-08-09 決定。FSL-1.1-MIT を一度採ったが公開前に撤回。理由は §8.3）
- **配布**: OSS。MCP サーバー単体バイナリ（`MullMCP`）が主、GUI は従（新規の UI 投資はしない）

---

## 4. Core Values

1. **Local-first（外に出ない）**。全データはユーザーの Mac 内。mull のサーバーは存在しない。LLM は既定 Off
2. **Portable（持ち出せる）**。出力はプレーン md。DB/API ロックインなし。git/Obsidian 互換
3. **Correctable（人間が上書きできる）**。自動層は人間の編集を壊さない（Curator / provenance）
4. **Measurable（測れる）**。選択の質は eval で測る。vibes で「良くなった」と言わない
5. **Open（読める）**。キーストロークを扱う製品が信頼を得る唯一の手段はコードが読めること（§8.3）

---

## 5. 製品の実体（MCP サーフェス）

**mull の製品は GUI ではなく、エージェントが叩く13のツールです。**

```bash
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

| ツール | 役割 |
|---|---|
| `whats_active_now` | 現在状態アンカー。今のアプリ、entity、セッション、直近の高salience行動 |
| `search` | now-anchored ranked retrieval（recency + entity + FTS + salience の融合） |
| `get_user_context` | 3層コンテキスト（profile / standard / full） |
| `get_relevant` | ファセット絞り込みの選択 |
| `get_projects` | entity 一覧と状態 |
| `get_knowledge` | 抽出された決定とその理由 |
| `search_history` | 生イベント検索 |
| `calendar` | 予定（EventKit）と実績（観測活動）の並置 |
| `list_files` / `read_file` | vault の閲覧 |
| `write_note` | エージェントが vault にメモを書く |
| `curate` | 既存ファイルにブロック単位でマージ。人間の編集は保護される |
| `get_corrections` | まだ規則が引き出されていない訂正を渡す。§0.1 の3つ目の仕事の受け渡し口。mull は §1–3（観測）を埋め、§4–9（解釈）はエージェントが `curate` で書き戻す |

### 5.1 選択パイプライン（`search` 1回の中身）

1. **アンカー**。entity/since が無ければ `whats_active_now()` で補完
2. **候補検索（高再現率）**。`w1·recency + w2·entity一致 + w3·FTS(BM25) + w4·salience` で top-K
3. **絞り込み（高精度）**。token 予算内に圧縮。include / summarize / drop を per-item 判定
4. **組み立て**。出典付きで返す（time / entity / source）。可視性が信頼になる
5. **使用ログ**。何が使われ、何が人間に直されたかを salience に還流

詳細は [SELECTION-LAYER.md](SELECTION-LAYER.md)。

### 5.2 廃止したツール（2026-08 完了）

`get_behavior_patterns` / `get_week_comparison` / `get_patterns` / `get_briefing` は
もう存在しません。どれも事前消化した結論を吐くだけで、素材ではなく mull の解釈を
返していました（DIRECTION §4）。選択の知能はエージェント側にあり、mull が返すのは
出典付きの素材である。この線に合わないものを落とした結果が、現在の13ツールです。

---

## 6. Data Capture

**収集は広く、最大に。ここは絞りません**（DIRECTION §3）。捕捉の忠実度だけが「今しか取れない」資産です。

| ソース | 方法 | 取得内容 |
|--------|------|---------|
| キーストローク | CGEvent tap | 全入力（ローマ字含む）、3秒フラッシュ |
| クリップボード | NSPasteboard 0.5秒ポーリング | コピーした全テキスト（40,000字まで） |
| ウィンドウタイトル | Accessibility API 5秒ポーリング | ファイル名やページ名 |
| ウィンドウ本文 | Accessibility API 30秒ポーリング | 作業の中身（タイトルではなく） |
| ブラウザURL | AppleScript | Safari/Chrome/Arc/Brave/Edge |
| アプリ切り替え | NSWorkspace 通知 | アプリ名と滞在時間 |
| カレンダー | EventKit | 今日のスケジュール |
| メール | AppleScript（オプトイン） | この経路は件名と送信者のみ（下記） |

> **メールの行について。** 「本文は読まない」はこの経路については正しく、製品については誤りです。
> Mail.app は除外リストに載っていないので、メールを読んでいる間の画面の文字は
> 「ウィンドウ本文」の行が拾います。この表の行は互いに独立ではありません。
> 正確な約束と、止め方は [SECURITY.md](SECURITY.md) にあります（そちらが正本）。

### 6.1 捕捉時の軽い索引（要約ではない）

各イベントに検索の取っ手を付けます。内容は消しません。

| フィールド | 由来 | 用途 |
|---|---|---|
| `entity` | window title の先頭セグメント、git リポ名、clipboard 内のパス | entity で引く（最強の軸） |
| `contentType` | note / error / decision / code / web / file など | type で絞る |
| `salience` | 0〜1。自分宛メモ、コピーしたエラー、commit が高く、ランダム打鍵片が低い | 並べ替え、予算配分 |
| `session` | 直前イベントとの間隔が N 分未満なら同セッション | 「この作業の塊」で引く |
| `mode` | produce / consume / decide / think / research / communicate | 意味づけ（MAP-ARCHITECTURE） |

> 要約すると原文が失われます。索引を足しても失われません。だから索引だけを足します。

---

## 7. 出力（3-Layer Context と Curator）

**出力の契約**: 成果物は「何であるか」ではなく「誰が読み、何が変わるか」で持ちます。
3列が埋まらないものは作りません。埋まらなくなったものは消します。

| ファイル | 誰が読むか | 何が変わるか | 場面 | 今 |
|---|---|---|---|---|
| `me.md`（~200 tok） | エージェント（`get_user_context` / `mull://me`） | 前提の再説明が要らなくなる | D | ✅ |
| `now.md`（~500 tok） | 同上 | 中断した作業に接続できる | C | ✅ |
| `me.pinned.md` | エージェントと人間 | 人が自分で書いた前提が最上段に載る（§7.4） | D | ✅ |
| `rules.md` | エージェント（`get_user_context` 全レベル / `mull://rules`） | エージェントの振る舞いが、あなたが直した通りに変わる | B | ✅ |
| `corrections/`（Card と ledger） | `get_corrections`（カード）と `Selection`（ledger） | 規則の材料になる。選択の並び順が変わる | B | ✅ |
| `full.md`（~1,500+ tok） | エージェント（`level: "full"`） | **答えられない** | — | ⚠ |

> **`full.md` の ⚠ について。** これは全部入りで、mull 自身が否定している「詰め込み」そのものです
> （選択せずに渡すと成功率は上がらずコストだけ増える、という反証への態度は README 参照）。
> 選択層を通した `search` があるのに全部を1枚で渡す経路が残っているのは、契約に照らして
> 正当化できていません。消すか、選択層が使えない相手への退避路として用途を明記するか、
> どちらかを決める必要があります。
>
> **`rules.md` について。** 表の中で唯一、mull がユーザーを観測して作ったのではなく、
> ユーザーが mull を直して作ったファイルです。だから `.shared` 所有（`VaultOwnership`）で、
> 書き換えた規則は `human` として永久に保護されます。規則はユーザーのもので、
> mull はその索引を組むだけです（§7.2 と同じ線）。

### 7.1 出力していいものの境界

> ここが出力していいのは、ユーザーに「この行はこの記録から来た」と示せるものだけです。
> アプリ一覧から職業を、クリップボードの部分一致から技術スタックを名乗るのは
> 観測ではなく主張であり、me.md の先頭に置いてよいものではありません。

2026-07 に、人物についての推測（役割、技術スタック、ドメイン）は削除しました。
残っているのは言語比率、実測ツール、プロジェクト名などの観測だけです。

### 7.2 Curator こそが核

自動層が人間の編集を壊さないこと（provenance: agent / human / pinned）が、メンテ性の本体です。
DB に閉じた自動生成物は触れず、メンテできません。だから folder-of-MD が必然になります（DIRECTION §6）。

そして Curator は同時に、mull の唯一の学習信号でもあります（§7.3）。

### 7.3 訂正ループ（規則の唯一の源泉）

```
mull が選んで出す / 草案する  →  人間が Curator で直す / 消す
                                          ↓
                        「これは要らなかった」「これが正しい」
                                          ↓
                    ①  ledger → Selection の重み      （選択が良くなる）
                    ②  Card → 規則 → rules.md         （場面 B）
```

**①と②は別物です。**①は選択の精度で、他社も原理的にはやれます。②は「選択肢を並べるな」の
ような、観測からは決して出てこない規則が立ち上がる経路で、これが §0.1 の3つ目の仕事です。

2026-08-09 に両方とも開通しました。①は `MCPServer.toolSearch` が ledger を `Selection` に
渡すようになり、②は `get_corrections` → `curate` → `RuleBook` → `rules.md` が繋がりました。

エージェントが使ったスライスは弱い正ラベルです。人間が直した、あるいは消したという事実は、
最高品質の relevance ラベルで、しかも無料で手に入ります。

Screenpipe も ManicTime も Timing も、この信号を持っていません。捕捉の広さでは差がつきません
（皆やっています）。mull の強みは「個人のライブ文脈と人間の修正ループ」の一点だけです。

> **旧「分身 / fidelity ループ」の再定義。** 「あなたの文体で日報を書く」という枠組みは、
> 日報自動生成がコモディティ化したため主商品から降ろしました。しかし機構は死んでいません。
> 編集距離の計測（`EditDistance.swift` / `ReportWriter.fidelitySeries`）は、人間の訂正を
> 定量化する装置として生き残ります。文体の忠実さではなく、選択の正しさを測るラベル生成器
> としてです。無編集承認がサンプルに入らない設計（provenance による遮断）も、そのまま正しい。

### 7.4 me.pinned.md への書き込み（約束の正確な形。この節が正本）

2026-08-09 の実装照合で、本書と README と UI とテンプレートが揃って
「mull は me.pinned.md を絶対に上書きしない」と書いていることが分かりました。
**これは literal には誤りです。** 実装では mull がこのファイルに書く経路が2つあります。

| 経路 | 実装 | いつ |
|---|---|---|
| 雛形を置く | `Curator.readPinned()` | ファイルが無いとき、または中身が雛形の行だけのとき（守るべきユーザーの記述が無いとき） |
| オンボーディング回答の投影 | `OnboardingProfile.writeSection()` | ユーザーが Settings やオンボーディングで自分で保存したとき。マーカーで囲んだ管理セクションだけを差し替える（`removeSection` は冪等） |
| 同セクションの貼り直し | `OnboardingProfile.reprojectSection()` から同じ `writeSection()` | ユーザーが Settings で言語を切り替えたとき。回答は変えず、区画を囲むマーカーだけが読み手の言語に追従する（2026-08-09 追加）|

書き込みの種類は2つのまま（雛形と管理セクション）で、増えたのは契機のほうです。
雛形の文面が言う「mull がこのファイルに書くのは2つだけ」は、この意味で正しい。

どちらも、ユーザーが自分で書いた行には触れません。正確な約束はこうなります。

> **あなたが書いた行を mull が上書きすることはありません。**
> mull がこのファイルに書くのは、雛形を置くときと、あなたが Settings で保存した回答を
> マーカーで囲んだ区画に入れるときだけです。

**エージェントは、このファイルに一切書けません**（2026-08-09 追加）。
`write_note` は以前から拒否していましたが、`curate` はパス解決を共有しながら拒否リストを
通っておらず、エージェントがブロックを追記できました。追記は上書きではないので約束の literal
には触れませんが、`Curator.filterPinned` は見出しと引用以外の全行をユーザーが主張した事実として
扱い、pinned は me.md の最上段（mull 自身の記述より上）に載ります。つまりエージェントの一文が、
以後すべての AI に本人の自己申告として配られていました。書けないのはファイルの権利であって、
書き込みの種類の話ではありません。両ツールとも `MCPServer.pinnedRefusal` を通ります
（`MCPServerTests` が両方を固定しています）。

**なぜ「絶対に上書きしない」ではだめか。** Input Monitoring を渡す判断の材料になる文（§8.3）は、
実装で確かめられる形で書かれていなければなりません。実装を見た人が反例を1つ見つけた瞬間、
他のすべての約束も同じ精度で疑われます。約束は弱くなっていません。精度が上がっただけです。

他の文書、UI、テンプレートはこの節へのポインタで、完全一覧を二重に持ちません（契約2）。

---

## 8. Privacy

### 8.1 大原則: ローカル完結

- 全データはユーザーの Mac 内。mull 社のサーバーは存在しない
- LLM は既定で Off。クラウドを明示的に選んだ時だけ外部送信し、送信前に機密は除外する
- Ollama か OpenAI互換ローカルサーバーを選べば、LLM 機能を含めてネットワークを切ったまま動く。
  MCP の13ツールはどの設定でも LLM を呼ばない（境界の全件と、ソースのどこで確かめるかは [SECURITY.md](SECURITY.md)）
- クラウド利用時はユーザー自身の API キーで直接通信する。中間サーバーは無い
- 使用統計の収集も送信も一切しない（トグルも持たない）

### 8.2 データ保護

- パスワードフィールドは自動でスキップ（`IsSecureEventInputEnabled`）
- アプリ除外リスト（1Password, Keychain などはデフォルト除外）。除外中は5経路すべてと、
  切り替えの記録そのものが止まる（`RecordingService.isExcludedApp` と `recordAppSession`）
- mull 自身のイベントは記録しない
- メール取り込みの経路は件名と送信者のみ。パスワードリセットや銀行通知は自動除外。
  ただし画面に出ているメール本文は別経路が拾う（§6 の注記と [SECURITY.md](SECURITY.md)）
- API キーは macOS Keychain に置く

### 8.3 なぜ「読めること」が privacy の要件なのか

市場調査で見つかった、動かせない事実があります。

> **内容を保持したまま受け入れられた製品は1件もありません。**
> 信頼されている打鍵近傍アプリ（TextExpander / Espanso / ActivityWatch）は、
> 全て「保持しない」ことで信頼を得ています。内容保持を宣言した2製品、
> Rewind（$33M調達）と Microsoft Recall（Windows の流通力）は、両方とも跳ね返されました
> （Recall は GA 後も明示オプトインで、有効化率は10%未満）。

mull は内容を保持します。ならばコードが読めることが唯一の説得手段です。
Bartender の事例（所有者交代、解析を無断追加、HN 252pt 炎上、無料OSS の Ice に市場を奪われる）は、
権限を持つクローズドアプリの信頼がいつでも崩れうることを示しています。

**OSS は流通戦略であると同時に、privacy 要件でもあります。**

> **なぜ FSL ではなく MIT か（2026-08-09）。**
> privacy 要件そのものは「読めること、自分でビルドできること」なので、FSL でも満たされます。
> 分かれたのは寄与の敷居のほうです。MIT なら、コードを読んだ人がそのまま直して送り返せます。
> 内容を保持する製品にとって、読めることと直せることは続きの1本です。privacy 要件は同点で、
> その続きの分だけ MIT が勝ちます。
>
> **初出の理由は誤りでした。** ここには「homebrew-core が DFSG 適合ライセンスを明文で要求するので、
> FSL では `brew install` の経路が塞がる」と書いてありました。mull の出荷物は `.app` を包んだ DMG で
> （`scripts/release.sh`）、homebrew-core は主産物が native `.app` の formula をライセンス以前に
> 受け付けません。行き先は cask のほうで、cask はライセンスを問いません。FSL でも
> `brew install --cask` は塞がりませんでした。結論は変わりませんが、支えていた根拠は
> 成り立っていませんでした。§7.4 と同じ理由で、消さずに残します。実装で確かめられない一文を
> 1つ置くと、他の約束も同じ精度で疑われます。
>
> 往復の経緯そのものは作者の内部文書にありますが、判断の根拠は上に閉じています。
> 公開側だけを読んで筋が通ることが、この分割の条件です。

---

## 10. Technical Architecture

| レイヤー | 技術 |
|---------|------|
| Language | Swift |
| UI | SwiftUI（凍結中） |
| Database | SQLite via GRDB.swift (WAL + FTS5 + DatabasePool) |
| Keystrokes | CGEvent tap (Quartz Event Services) |
| Calendar | EventKit |
| Browser / Email | AppleScript |
| API Keys | macOS Keychain Services |
| LLM | Off（既定） / Ollama / OpenAI互換ローカルサーバー / Gemini / Anthropic / OpenAI |
| AI Protocol | MCP (Model Context Protocol) via stdio。`MullMCP` 単体バイナリ |
| Project generation | XcodeGen (`project.yml`) |

コード配置は [README.md](README.md)、データ層の構造は [MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md)。

---

*Your agent knows what you told it. mull knows what you did.*
