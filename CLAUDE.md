# mull — Product Specification

> **文書の序列**
>
> | 文書 | 何を決めるか | 序列 |
> |---|---|---|
> | **本書 §0（これは何に効くか）** | **解く問題と、今解けているか** | **全文書に優先** |
> | [DIRECTION.md](DIRECTION.md) | **作り方**と判断の根拠 | 技術については最上位 |
> | [SELECTION-LAYER.md](SELECTION-LAYER.md) | 中核IP（選択層）の具体設計 | DIRECTION の従属 |
> | [MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md) | データ層の構造（領土/地図/モード） | DIRECTION の従属 |
> | [HARNESS.md](HARNESS.md) | 訂正ループの実装仕様（§7.3 の実装） | DIRECTION の従属 |
> | **CLAUDE.md（本書）** | 製品仕様 | 上記に従属 |
>
> 衝突したら **§0 > DIRECTION（技術） > CLAUDE.md の残り（仕様）**。
> §0 が上にあるのは、他の全ての文書が「どう作るか」を決めているのに対し、
> §0 だけが**そもそも作っていいか**を決めるため。
>
> **節番号に欠番がある（§2 / §3 / §9 / §11 / §12）。** 事業の線・非ゴールの選定・UI凍結の判断・
> 競合比較・公開までの順序は作者の内部文書に置いてあり、このリポジトリには入れていない。
> 番号は**動かしていない**——コードコメントと他文書から27箇所が節番号で本書を指しており、
> 振り直すと参照が全部ずれるため。欠番は削除の痕跡であって、隠した跡ではない。
>
> ただし読者に関わる約束は公開側に残してある。カレンダーへの書き込みで越えない4本の線と、
> 「餌と呼ばない・人間を product にしない」の3不変項は [SECURITY.md](SECURITY.md) にある。

---

## 0. これは何に効くか — **全文書に優先する**

> **この表に紐づかない作業はしない。** バグ修正も、リファクタも、公開準備も。
> どれにも当たらない変更を思いついたら、**場面を足すか、やらないか**を先に決める。

| # | 場面 | 今どうなるか | mull で何をするか | 今動くか |
|---|---|---|---|---|
| **C** | 月曜に戻って、金曜の続きが思い出せない | git log と開いたままのタブから再構成する | `whats_active_now` / `search` が金曜の作業をそのまま出す | ✅ |
| **D** | エージェントに毎回同じ前提を説明し直す | 「Swift」「GRDB」「macOS 14」を毎回打つ | `get_user_context` が観測から自動で渡す | ✅ |
| **B** | エージェントが同じ直され方を繰り返す | 同じ指摘を何度もする。直した事実はどこにも残らない | あなたの訂正が規則になり、次のセッションでエージェントが読む | ❌ |
| **A** | 作っているものが頭の中で分散し、次に何をすべきか分からなくなる | 決めたはずの方針とずれ、本質でない所を触り続ける | 決定とその理由を引く（`get_knowledge` / `search`） | ⚠ |

**場面の出所**（契約1 — 人物についての推測を場面として書かない）:
**A・B** は 2026-08-09 のセッションでの実観測、**C・D** は作者による確認。

**⚠ と ❌ の中身**:

- **B ❌** — Correction Card は書き出されるが、**読む経路が存在しない。**
  `MCPServer` は `Selection` に ledger を渡しておらず、カードを指す MCP ツールも無い
  （2026-08-09 実装照合）。**差別化はこの1行にしかない。**
- **A ⚠** — mull が解けるのは「過去に何を決めたか」まで。「次に何をすべきか」は方針の問題で、
  それを持つのは道具ではなく**この文書**である。半分は mull では解かない。

> **✅ の2つは、他社もやっている**（ActivityWatch / Screenpipe / Mem0）。
> **❌ の1つだけが mull にしか無い。**
> 動いているものは競争にならず、競争になるものが動いていない——これが現在地である。

### 0.1 mull の仕事

1. **広く正確に捕える** — 今しか取れないものを、ロスなく
2. **今の必要に対して正しく選ぶ** — need-scoped context assembly（DIRECTION §5）
3. **訂正から規則を草案する** — 1・2 はここに仕える（§7.3 / [HARNESS.md](HARNESS.md)）

**3 が中核である。規則は観測からは出てこない。**
「Xcode を使う」は記録から出る。「選択肢を並べず推奨を1つ出せ」は、**どれだけ記録しても出てこない。**
それが現れるのは**人が mull の出力を直した瞬間だけ**であり、**訂正が規則の唯一の源泉**である。

**ただし解釈は mull の仕事ではない。** mull が出せるのは材料と草案までで、
判断軸を引くのは人とエージェント（HARNESS.md 第II部 §2 の自動化境界）。
**賢さで勝負しない**という線は動いていない——動いたのは、mull が黙って材料を置く場所から、
**草案を差し出して直される場所**になったことである。

**撤回基準**（契約3 — これを書かずに路線を変えると往復する）:

| | |
|---|---|
| 期限 | 場面 B が ✅ になってから90日 |
| 観測点 | mull が草案した規則を人間が一度も採用しない（規則の置き場が5行未満のまま） |
| 原因の分離 | 「訂正が起きない」のか「エージェントが規則を書けない」のか。`corrections/` にカードが溜まっていれば後者 |
| 戻し方 | 仕事を 1・2 の2つに戻し、訂正ループは選択順を良くする内部機構に限定する。§0 から場面 B を落とす |

---

## 1. Identity

- **App Name**: mull
- **Subtitle**: Behavioral memory for coding agents.
- **Tagline**: **Your agent knows what you told it. mull knows what you did.**
- **Category**: Developer tool / Agent memory (旧: Productivity / Second Brain)
- **Platform**: macOS (Apple Silicon)
- **License**: **MIT**（2026-08-09 決定。FSL-1.1-MIT を一度採ったが公開前に撤回——STRATEGY §5-4）
- **配布**: OSS。MCP サーバー単体バイナリ（`MullMCP`）が主、GUI は従（新規の UI 投資はしない）

---

## 4. Core Values

1. **Local-first（外に出ない）** — 全データはユーザーの Mac 内。mull のサーバーは存在しない。LLM は既定 Off
2. **Portable（持ち出せる）** — 出力はプレーン md。DB/API ロックインなし。git/Obsidian 互換
3. **Correctable（人間が上書きできる）** — 自動層は人間の編集を絶対に壊さない（Curator / provenance）
4. **Measurable（測れる）** — 選択の質は eval で測る。vibes で「良くなった」と言わない
5. **Open（読める）** — キーストロークを扱う製品が信頼を得る唯一の手段はコードが読めること（§8.3）

---

## 5. 製品の実体 — MCP サーフェス

**mull の製品は GUI ではなく、エージェントが叩く 12 のツールである。**

```bash
claude mcp add --transport stdio --scope user mull -- /path/to/MullMCP
```

| ツール | 役割 |
|---|---|
| `whats_active_now` | **現在状態アンカー**。今のアプリ/entity/セッション/直近の高salience行動 |
| `search` | now-anchored ranked retrieval（recency + entity + FTS + salience の融合） |
| `get_user_context` | 3層コンテキスト（profile / standard / full） |
| `get_relevant` | ファセット絞り込みの選択 |
| `get_projects` | entity 一覧と状態 |
| `get_knowledge` | 抽出された決定とその理由 |
| `search_history` | 生イベント検索 |
| `calendar` | 予定（EventKit）と実績（観測活動）の並置 |
| `list_files` / `read_file` | vault の閲覧 |
| `write_note` | エージェントが vault にメモを書く |
| `curate` | 既存ファイルにブロック単位でマージ（**人間の編集は保護される**） |

### 5.1 選択パイプライン（`search` 1回の中身）

1. **アンカー** — entity/since が無ければ `whats_active_now()` で補完
2. **候補検索（高再現率）** — `w1·recency + w2·entity一致 + w3·FTS(BM25) + w4·salience` で top-K
3. **絞り込み（高精度）** — token 予算内に圧縮。include / summarize / drop を per-item 判定
4. **組み立て** — **出典付き**で返す（time / entity / source）。可視性＝信頼
5. **使用ログ** — 何が使われ、何が人間に直されたかを salience に還流

詳細は [SELECTION-LAYER.md](SELECTION-LAYER.md)。

### 5.2 廃止したツール（2026-08 完了）

`get_behavior_patterns` / `get_week_comparison` / `get_patterns` / `get_briefing` は
**もう存在しない**。どれも「事前消化した結論を吐くだけ」で、素材ではなく mull の解釈を
返していた（DIRECTION §4）。選択の知能はエージェント側にあり、mull が返すのは
出典付きの素材である——という線に合わないものを落とした結果が、現在の12ツール。

---

## 6. Data Capture

**収集は広く・最大に。ここは絞らない**（DIRECTION §3）。捕捉の忠実度だけが「今しか取れない」資産。

| ソース | 方法 | 取得内容 |
|--------|------|---------|
| キーストローク | CGEvent tap | 全入力（ローマ字含む）、3秒フラッシュ |
| クリップボード | NSPasteboard 0.5秒ポーリング | コピーした全テキスト（40,000字まで） |
| ウィンドウタイトル | Accessibility API 5秒ポーリング | ファイル名/ページ名 |
| ウィンドウ本文 | Accessibility API 30秒ポーリング | 作業の中身（タイトルではなく） |
| ブラウザURL | AppleScript | Safari/Chrome/Arc/Brave/Edge |
| アプリ切り替え | NSWorkspace 通知 | アプリ名 + 滞在時間 |
| カレンダー | EventKit | 今日のスケジュール |
| メール | AppleScript（オプトイン） | 件名 + 送信者のみ（本文は読まない） |

### 6.1 捕捉時の軽い索引（要約ではない）

各イベントに検索の"取っ手"を付ける。**内容は消さない。**

| フィールド | 由来 | 用途 |
|---|---|---|
| `entity` | window title の先頭セグメント、git リポ名、clipboard 内のパス | entity で引く（最強の軸） |
| `contentType` | note / error / decision / code / web / file … | type で絞る |
| `salience` | 0–1。自分宛メモ・コピーしたエラー・commit = 高、ランダム打鍵片 = 低 | 並べ替え・予算配分 |
| `session` | 直前イベントとの間隔 < N分 で同セッション | 「この作業の塊」で引く |
| `mode` | produce / consume / decide / think / research / communicate | 意味づけ（MAP-ARCHITECTURE） |

> **要約は捨てる（損失）、構造化は残す（検索の取っ手）。**

---

## 7. 出力 — 3-Layer Context と Curator

| ファイル | サイズ | 内容 |
|---------|-------|------|
| `~/mull/me.md` | ~200 tokens | 「誰か」— **観測できたことだけ**（§7.1） |
| `~/mull/now.md` | ~500 tokens | 「今何をしているか」 |
| `~/mull/full.md` | ~1,500+ tokens | 全て |
| `~/mull/me.pinned.md` | — | **人間のもの。あなたが書いた行を mull が上書きすることはない**（§7.4） |

### 7.1 出力していいものの境界

> ここが出力していいのは、ユーザーに**「この行はこの記録から来た」と示せるもの**だけ。
> アプリ一覧から職業を、クリップボードの部分一致から技術スタックを名乗るのは
> 「観測」ではなく「主張」であり、me.md の先頭に置いてよいものではない。

2026-07 に、人物についての推測（役割・技術スタック・ドメイン）は削除済み。
残っているのは言語比率・実測ツール・プロジェクト名などの**観測**のみ。

### 7.2 Curator こそが核

自動層が人間の編集を壊さないこと（provenance: agent / human / pinned）が**メンテ性の本体**。
DB に閉じた自動生成物は触れず、メンテ不能。**folder-of-MD は必然**（DIRECTION §6）。

**そして Curator は同時に、mull の唯一の学習信号でもある**（§7.3）。

### 7.3 訂正ループ ＝ 無料の relevance ラベル（**堀の本体**）

```
mull が選んで出す  →  人間が Curator で直す / 消す
                              ↓
                    「これは要らなかった」「これが正しい」
                              ↓
                    salience と重み w に還流
```

**エージェントが使ったスライス＝弱い正ラベル。人間が直した/消した＝最高品質の relevance ラベル（無料）。**

Screenpipe も ManicTime も Timing も、この信号を持っていない。捕捉の広さでは差がつかない（皆やっている）。
**mull の不当な強みは「個人のライブ文脈 × 人間の修正ループ」の一点だけ。**

> **旧「分身 / fidelity ループ」の再定義**: 「あなたの文体で日報を書く」という枠組みは、
> 日報自動生成がコモディティ化したため主商品から降ろした。
> **しかし機構は死んでいない。** 編集距離の計測（`EditDistance.swift` / `ReportWriter.fidelitySeries`）は
> **「人間の訂正を定量化する装置」**として生き残る——文体の忠実さではなく、
> **選択の正しさを測るラベル生成器**として。無編集承認がサンプルに入らない設計（provenance による遮断）も
> そのまま正しい。

### 7.4 me.pinned.md への書き込み — 約束の正確な形（**この節が正本**）

2026-08-09 の実装照合で、本書と README と UI とテンプレートが揃って
**「mull は me.pinned.md を絶対に上書きしない」**と書いていることが分かった。
**これは literal には誤りである。** 実装では mull がこのファイルに書く経路が2つある。

| 経路 | 実装 | いつ |
|---|---|---|
| 雛形を置く | `Curator.readPinned()` | ファイルが無いとき／**中身が雛形の行だけのとき**（＝守るべきユーザーの記述が無いとき） |
| オンボーディング回答の投影 | `OnboardingProfile.writeSection()` | ユーザーが Settings / オンボーディングで**自分で保存したとき**。マーカーで囲んだ管理セクションだけを差し替える（`removeSection` は冪等） |
| 同セクションの貼り直し | `OnboardingProfile.reprojectSection()` → 上と同じ `writeSection()` | ユーザーが Settings で**言語を切り替えたとき**。回答は変えず、区画を囲むマーカーだけが読み手の言語に追従する（2026-08-09 追加）|

**書き込みの「種類」は2つのまま**（雛形／管理セクション）で、増えたのは**契機**である。
雛形の文面が言う「mull がこのファイルに書くのは2つだけ」は、この意味で正しい。

**どちらも、ユーザーが自分で書いた行には触れない。** 正確な約束はこう:

> **あなたが書いた行を mull が上書きすることはない。**
> mull がこのファイルに書くのは、雛形を置くときと、あなたが Settings で保存した回答を
> マーカーで囲んだ区画に入れるときだけ。

**エージェントは、このファイルに一切書けない**（2026-08-09 追加）。
`write_note` は以前から拒否していたが、`curate` はパス解決を共有しながら拒否リストを通っておらず、
エージェントがブロックを追記できた。追記は「上書き」ではないので約束の literal には触れないが、
`Curator.filterPinned` は見出し・引用以外の全行を**ユーザーが主張した事実**として扱い、
pinned は me.md の最上段（mull 自身の記述より上）に載る。
つまりエージェントの一文が、以後すべての AI に「本人の自己申告」として配られていた。
**書けないのはファイルの権利であって、書き込みの種類の話ではない。**
両ツールとも `MCPServer.pinnedRefusal` を通る（`MCPServerTests` が両方を固定している）。

**なぜ「絶対に上書きしない」ではだめか** — Input Monitoring を渡す判断の材料になる文（§8.3）は、
実装で確かめられる形で書かれていなければならない。実装を見た人が反例を1つ見つけた瞬間、
他のすべての約束も同じ精度で疑われる。**約束は弱くなっていない。精度が上がっただけである。**

他の文書・UI・テンプレートはこの節へのポインタであり、完全一覧を二重に持たない（契約2）。

---

## 8. Privacy

### 8.1 大原則: ローカル完結

- 全データはユーザーの Mac 内。mull 社のサーバーは存在しない
- **LLM は既定で Off。** クラウドを明示的に選んだ時だけ外部送信。送信前に機密は除外
- クラウド利用時はユーザー自身の API キーで直接通信。中間サーバーなし
- 使用統計の収集・送信は一切なし（トグルも持たない）

### 8.2 データ保護

- パスワードフィールド自動スキップ（`IsSecureEventInputEnabled`）
- アプリ除外リスト（1Password, Keychain 等はデフォルト除外）
- mull 自身のイベントは記録しない
- メール: 件名+送信者のみ。パスワードリセット・銀行通知は自動除外
- API キーは macOS Keychain

### 8.3 なぜ「読めること」が privacy の要件なのか

市場調査で見つかった、動かせない事実:

> **内容を保持したまま受け入れられた製品は1件も無い。**
> 信頼されている打鍵近傍アプリ（TextExpander / Espanso / ActivityWatch）は
> **全て「保持しない」ことで**信頼を得ている。
> 内容保持を宣言した2製品——Rewind（$33M調達）と Microsoft Recall（Windows の流通力）——は
> **両方とも跳ね返された**（Recall は GA 後も明示オプトイン、有効化率10%未満）。

mull は内容を保持する。ならば**コードが読めることが唯一の説得手段**である。
Bartender の事例（所有者交代 → 解析を無断追加 → HN 252pt 炎上 → 無料OSS の Ice に市場を奪われる）は、
**権限を持つクローズドアプリの信頼が、いつでも崩れうる**ことを示している。

**OSS は流通戦略であると同時に、privacy 要件でもある。**

> **なぜ FSL ではなく MIT か（2026-08-09）。**
> privacy 要件そのものは「**読めること・自分でビルドできること**」なので FSL でも満たされる。
> 分かれたのは**流通**のほう——homebrew-core は DFSG 適合ライセンスを明文で要求しており、
> FSL では `brew install` の経路が塞がる。privacy 要件は同点、流通は MIT の勝ち。
> 経緯と判断の全文は STRATEGY §5-4。

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
| LLM | Off（既定） / Ollama / Gemini / Anthropic / OpenAI |
| AI Protocol | **MCP (Model Context Protocol) via stdio** — `MullMCP` 単体バイナリ |
| Project generation | XcodeGen (`project.yml`) |

コード配置は [README.md](README.md)、データ層の構造は [MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md)。

---

*Your agent knows what you told it. mull knows what you did.*
