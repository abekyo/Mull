# mull — Product Specification

> **文書の序列**（2026-08 改訂）
>
> | 文書 | 何を決めるか | 序列 |
> |---|---|---|
> | STRATEGY-2026-08.md（非公開の内部文書） | **事業の線**（誰に何を出すか） | 事業については**最上位** |
> | MARKET-2026-08.md（非公開の内部文書） | STRATEGY が依拠する外部データ（証拠台帳） | 参照 |
> | [DIRECTION.md](DIRECTION.md) | **作り方**と判断の根拠 | 技術については最上位 |
> | [SELECTION-LAYER.md](SELECTION-LAYER.md) | 中核IP（選択層）の具体設計 | DIRECTION の従属 |
> | [MAP-ARCHITECTURE.md](MAP-ARCHITECTURE.md) | データ層の構造（領土/地図/モード） | DIRECTION の従属 |
> | [HARNESS.md](HARNESS.md) | **生成すべきハーネスの仕様と、訂正ループの実装**（§7.3 の実装仕様） | DIRECTION の従属 |
> | **CLAUDE.md（本書）** | 製品仕様 | 上記に従属 |
> | [DESIGN-NORTHSTAR.md](DESIGN-NORTHSTAR.md) / [DESIGN.md](DESIGN.md) | 見え方 | **当面凍結**（§9） |
>
> 衝突したら **STRATEGY（事業） > DIRECTION（技術） > CLAUDE.md（仕様）**。
> UI/意匠の話に限っては DESIGN-NORTHSTAR が最上位のまま（ただし凍結中）。

---

## 1. Identity

- **App Name**: mull
- **Subtitle**: Behavioral memory for coding agents.
- **Tagline**: **Your agent knows what you told it. mull knows what you did.**
- **Category**: Developer tool / Agent memory (旧: Productivity / Second Brain)
- **Platform**: macOS (Apple Silicon)
- **License**: **MIT**（2026-08-09 決定。FSL-1.1-MIT を一度採ったが公開前に撤回——STRATEGY §5-4）
- **配布**: OSS。MCP サーバー単体バイナリ（`MullMCP`）が主、GUI は従（§9）

---

## 2. 立ち位置 — なぜこれが要るか

### 2.1 唯一の非対称性

2026年時点で、AI のメモリはどれも**「言われたこと」**しか持っていない。

| 誰 | 何を覚えているか | 何を見ていないか |
|---|---|---|
| ChatGPT (Dreaming V3) | ChatGPT での**発言** | あなたのマシンの上で起きたこと |
| Claude memory | Claude での**発言** | 同上 |
| GitHub Copilot Memory | リポジトリの**成果物**（コミット文体・PR構造） | 書く前の試行、コピーしたエラー、詰まった時間 |
| Gemini Personal Intelligence | Gmail / Photos＝**Google の面** | あなたの Xcode |
| Mem0 / Zep / Letta | アプリが**渡した**もの（＝多くは会話） | OS レベルの行動 |

> **誰も、あなたのマシンの上で実際に起きたことを持っていない。**
> **mull が持っているのはそれだけであり、それが全てである。**

エージェントが「今日の午後ずっと何をしていたか」「15時にコピーしたエラーは何か」
「先週この判断をした時、何を見ていたか」を知る手段は、現状 mull しかない。

### 2.2 「アクセスできる」と「今の必要に対して正しく選べる」は別

Claude Code も computer-use も PC 全体にアクセスできる。しかし毎回探索する。
10万ファイルの中から今日の文脈を探すのは遅く、高く、ノイジー。

**必要なのはアクセス権ではなく、今の問いに対して"ちょうど正しい最小スライス"を返す層**
（＝ DIRECTION §5 / SELECTION-LAYER）。**そこが製品であり、堀である。**

### 2.3 反証への態度

ETH Zurich, arXiv 2602.11988（2026-02）は
*"providing context files does not generally improve task success rates,
while increasing inference cost by over 20%"* と報告している。

**これは正しい。ただし *詰め込んだ* 場合の話である。**
mull の主張は「文脈を渡せば良くなる」ではなく
**「現在状態にアンカーを打って必要分だけ選ぶと良くなる。測れる」**。
測る道具は [`eval/selection_eval.swift`](eval/selection_eval.swift)（20ケース、precision/recall/MRR）。

**この主張が eval で否定されたら、位置づけごと考え直す**（STRATEGY §6 撤回基準）。

---

## 3. 何を売らないか（Non-goals）

2026-08 の市場調査（MARKET-2026-08.md）を受けて、**明示的に降りたもの**:

| 降りたもの | 理由 |
|---|---|
| **消費者向け「第二の脳」アプリ** | Rewind（$33M調達）は 2025-12-19 に製品ごと停止。"second brain" Show HN 236件の中央値 3pt。個人が買い手の側で公開検証できる年商$3M超の例がゼロ |
| **「AIへの自己説明を年120時間ゼロに」という訴求** | 痛みとして感じられておらず、ETH論文が直接の反証になる。訴求は「時間削減」ではなく**選択の質** |
| **日報/タイムシートの自動生成を主商品にすること** | 10社以上が出荷済み（Timely / ManicTime / Timing / Rize / Dayflow …）。ManicTime は $7/user/月 で mull とほぼ同一の機構を持つ。Dayflow と myloggy は**無料**でやっている |
| **消費者サブスクの価格設計** | Screenpipe の順序（公開 → star → 商用化）に従う。価格は star の後 |
| **日本市場を一次市場にすること** | 個人が買える製品が最低人数の壁で構造的に存在せず、PC活動ログ＝監視として認知が固定。**公開してGitHubに置くことがこの問題を丸ごと迂回する** |
| **雇用主向け監視（ActivTrak / Hubstaff 型）** | 金はそこにある（$33–50M ARR）が、DESIGN-NORTHSTAR の dignity と同居できない。**採らない** |

### 3.1 引き続きやらないこと（技術的な非機能）

| やらない | 理由 |
|---|---|
| 画面OCR / スクリーンショット | Screenpipe の領域。CPU/ストレージが重い。打鍵＋クリップボード＋ウィンドウで十分に軽く、構造化しやすい |
| 音声録音・書き起こし | Omi/Granola/Plaud の領域。第三者の録音同意という社会的摩擦を背負わない |
| タスク管理 / メール送信 | 記録と管理は別の関心事。mull は読み取りのみ |
| カレンダーの高度な編集（繰り返し / 出席者 / 通知 / カレンダー作成） | Calendar.app の領域。ただし**予定の作成・時刻変更・削除は GUI で可能**（2026-08 に「カレンダー編集はやらない」を撤回。§3.3） |
| クラウド同期 | プライバシーの根幹。iCloud/git は自分でやればいい |
| iOS / Android | macOS Accessibility API に依存 |
| 汎用チャットボット | Claude/ChatGPT の領域 |
| プラグインマーケットプレイス | 複雑さが指数関数的に増える |

### 3.3 カレンダーへの書き込みについて（2026-08 撤回）

「カレンダー編集はやらない」は撤回した。理由は、予定の穴を見つけるのは **mull のグリッドを見ている最中**だからで、
そこから別アプリに送り返すのは「あなたの1日が住んでいる場所」であることをやめる瞬間だった。
加えて、Mac ユーザーが最初に試すジェスチャ（空きスロットのダブルクリック）が無反応で、理由も言わなかった。

越えない線は4つ:

1. **mull はコピーを持たない** — EventKit に書いて EventKit から読み直す。DB には一切入れない
2. **行き先はユーザーが既に選んだカレンダーだけ** — 既定カレンダーが初期値。mull はカレンダーを作らない
3. **明示的な操作なしには1バイトも書かない** — ダブルクリック → タイトル入力 → Return
4. **すべて取り消せる** — create / edit / delete はすべて `UndoManager` に逆操作を登録する（⌘Z）

繰り返し予定は `.thisEvent` のみ。購読カレンダーは読み取り専用のまま。

> **注（未解決）**: §1 の位置づけ変更（製品の実体 = MCP サーフェス、GUI は従）と、
> GUI のカレンダー編集に投じた労力は緊張関係にある。§5 の MCP `calendar` ツールは読み取りのみで、
> 書き込みはエージェントには開いていない。この線引きが正しいかは STRATEGY 側で決める。

### 3.2 原則

**mull は記憶であって頭脳ではない。**

mull の仕事は2つ:
1. **広く正確に捕える** — 今しか取れないものを、ロスなく（MAP-ARCHITECTURE 法則①）
2. **今の必要に対して正しく選ぶ** — need-scoped context assembly（DIRECTION §5）

**選択の知能はエージェント、素材の質と索引の質は mull。**
賢さで勝負しない。「何でもできる」は Claude/Cursor の領域。

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

### 5.2 廃止予定のツール

`get_behavior_patterns` / `get_week_comparison` / `get_patterns` / `get_briefing` —
「事前消化を吐くだけ」のもの（DIRECTION §4）。段階的に落とす。

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
| `~/mull/me.pinned.md` | — | **人間のもの。mull は絶対に上書きしない** |

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
> 日報自動生成が10社以上でコモディティ化したため主商品から降ろした（§3）。
> **しかし機構は死んでいない。** 編集距離の計測（`EditDistance.swift` / `ReportWriter.fidelitySeries`）は
> **「人間の訂正を定量化する装置」**として生き残る——文体の忠実さではなく、
> **選択の正しさを測るラベル生成器**として。無編集承認がサンプルに入らない設計（provenance による遮断）も
> そのまま正しい。

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

## 9. アプリ UI — 当面凍結

GUI（メニューバー ☽ / Home / Calendar / Live / Chat / Files / Settings）は**動く状態のまま維持するが、
新規投資はしない**。

理由: Screenpipe は UI 投資ゼロで 20.8k★。Mac App Store は81日で収益$21。
**デーモンには UI が要らず、star は UI では取れない。**

- **凍結するもの**: 4ピンの拡張、Bear風エディタの磨き込み、DESIGN-NORTHSTAR / DESIGN.md の意匠適用
- **凍結しないもの**: Curator / provenance / 編集可能 md（これは UI ではなく**堀**）、
  権限セットアップ（捕捉が死ぬと全部死ぬ）

**DESIGN-NORTHSTAR.md と DESIGN.md は中身を温存する。** UI 作業を再開する日に、そのまま有効。

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

## 11. Competitive Positioning

| | ChatGPT/Claude memory | Mem0 / Zep / Letta | Screenpipe | ManicTime / Timing | **mull** |
|--|---|---|---|---|---|
| データ源 | 会話 | アプリが渡したもの | **画面OCR + 音声** | ウィンドウ/文書/URL | **打鍵 + クリップボード + ウィンドウ本文 + 予定** |
| 出力 | 内部状態 | API | SQLite/API | タイムシート | **md（可搬・人間もAIも読める）** |
| MCP | — | — | あり | あり | **あり（12ツール・読み書き）** |
| **人間の訂正ループ** | — | — | **無し** | **無し** | **あり（Curator / provenance）** |
| **選択品質の eval** | — | — | 未公開 | — | **あり（20ケース、precision/recall/MRR）** |
| LLM依存 | 必須 | 必須 | あり | あり | **なし（ルールベースで基本動作）** |

**mull だけがやっていること**:
1. OS レベルの行動を、OCR ではなく**構造化しやすい信号**で捕える
2. **人間の訂正が選択の質に還流する**ループを持つ
3. **選択の質を測って公開する**

---

## 12. Roadmap

**ロードマップの軸は機能追加ではなく、STRATEGY-2026-08 の初手を通すこと。**
詳細は [ROADMAP.md](ROADMAP.md)。

```
1. eval を回して数字を出す            ← 唯一の主張の裏付け
2. UIなしのデーモン経路を整える        ← brew install できる形
3. リポジトリを public にする          ← 唯一の不可逆な一手
4. 記事を出す                          ← "context files don't help — unless you select"
```

**衛星機能（Calendar / Chat / Files の磨き込み）は、壊れていない限り触らない。**

---

*Your agent knows what you told it. mull knows what you did.*
