# mull — Product Specification

> **文書の序列**（2026-07 整理）: 哲学と見え方は `DESIGN-NORTHSTAR.md`、作り方と
> 判断の根拠は `DIRECTION.md`、製品仕様（＝この文書）はその2つに従属する。
> 衝突したら **DESIGN-NORTHSTAR > DIRECTION > CLAUDE.md**。
> `PRODUCT.md` と `ONBOARDING.md` は削除した（理由は DIRECTION.md 付録B）。

## 1. Identity

- **App Name**: mull
- **Subtitle**: Know what you did.
- **Tagline**: Stop explaining yourself to AI.
- **Category**: Productivity / Second Brain
- **Platform**: macOS (Apple Silicon)

---

## 2. Vision

### The Problem

AIに仕事を頼むたびに、自分のことを一から説明している:

```
「私はSwift開発者で、PantryAppというヘルスケアアプリを作っていて、
 今Storyboardのリファクタリングをしていて、Phase 5まで進んでいて、
 あとUIKitベースなんだけど、角丸が12〜20でバラバラで...」
```

1回2-3分。1日10回AIに聞くなら、1日30分。月10時間。**年120時間をAIへの自己説明に使っている。**

### What mull Does

**その120時間をゼロにする。**

mullはバックグラウンドであなたの作業を記録し、AIが読める形に構造化する。AIはmullを読んで、あなたのことを最初から知っている。

```
Before mull:
  あなた: 「私はSwift開発者で...（2分の説明）...このバグ直して」
  AI:    「了解しました。まず確認ですが...」

After mull:
  あなた: 「このバグ直して」
  AI:    「PantryAppのStoryboard改修中ですね。Phase 5の
          RegisterAccountTutorialVCの件ですか？15:00からFXの
          ミーティングがあるので、先に小さい修正から始めましょう。」
  あなた: 「......なんでそこまで知ってるの？」
```

**この「なんで知ってるの？」の瞬間がmullの価値。**

### How mull Changes Your Life

```
AIとの会話:   毎回2-3分の説明 → ゼロ。即座に的確な回答
月曜の朝:     「先週何やった...」→ 30秒で全把握
評価面談:     「成果は...えーと...」→ 3ヶ月分の記録が全部ある
転職:         「経歴書に何書こう」→ me.md + 6ヶ月分のTimeline
```

日記としても機能する。ただし目的は「日記を書く」ことではなく「AIとの意思伝達コストをゼロにして生産性を上げる」こと。日記は手段。自動で書かれる。読み返す必要すらない。AIが読んでくれる。

### mull vs ChatGPT Memory — 根本的に違うもの

ChatGPTにもメモリ機能がある。「この人はSwift開発者」「東京在住」と覚えてくれる。では何が違うのか。

```
ChatGPT Memory = あなたが「言った」ことを覚えている
  → "I'm a Swift developer" と言ったから知っている
  → 言わなかったことは知らない
  → 今日何をしたかは知らない
  → 15:00にミーティングがあることは知らない
  → 静的。月に1回更新されるプロフィール。

mull = あなたが「やった」ことを知っている
  → 言わなくても、Xcodeを毎日使っているから開発者だとわかる
  → 今日2.5時間PantryAppに使ったことを知っている
  → 15:00からFXのCSがあることをカレンダーから知っている
  → さっきコピーしたエラーメッセージを知っている
  → 動的。60秒ごとに更新される今日の全行動記録。
```

ChatGPTのメモリは「プロフィール」。mullは「今日の行動ログ + 蓄積された理解」。

ChatGPTは「あなたは誰か」を知っている。mullは「あなたは今、何をしているか」を知っている。両者は競合しない。共存する。mullのデータをChatGPTやClaudeに渡すことで、「誰か」と「今何してるか」の両方をAIが持つ。

### First Goal: AIがあなたを知っている状態を自動で作る

> **「あなた」をAIに渡せるファイルにする。**

- インストールして放置するだけで、AIがあなたを知っている状態が勝手に作られる
- キーストローク、クリップボード、ウィンドウタイトル、カレンダー、メール — 全て自動取得
- me.md / now.md / full.md が60秒ごとに自動更新される
- MCPサーバー経由でAIが自分からmullにアクセスする
- ユーザーは何もしない。AIが勝手に知っている。**「なんでこんなこと知ってるの？」**の瞬間が起きる

### Ultimate Goal: 第二の脳を作る

散らばった情報を一つの場所に集約する。境界を設けない。

- **自動で入ってくるもの** — キーストローク、クリップボード、ウィンドウ、メール、カレンダー、ブラウザ履歴、Git、ファイル変更
- **手動で入れるもの** — メモ、PDF、画像、ファイル、ブックマーク、何でも
- **AIが書き込むもの** — 会話で学んだこと、判断の記録、生成したドキュメント

この3つが全て **`~/mull/`** フォルダに入る。

```
~/mull/ = あなたのデジタル人格

  ├── me.md          ← AIがあなたを理解するためのプロフィール
  ├── now.md         ← 今何をしているか
  ├── full.md        ← 全コンテキスト
  ├── daily/         ← 日次サマリー（自動生成）
  ├── memory/        ← AIが学んだトピック別メモリ
  ├── notes/         ← ユーザーが自分で書くメモ
  ├── files/         ← ドラッグ&ドロップしたPDF、画像、ドキュメント
  └── clips/         ← Webクリップ、ブックマーク

誰でもアクセスできる:
  - mull アプリ（閲覧・編集）
  - AI（MCPサーバー経由で読み書き）
  - 他のツール（ただのフォルダ。git, iCloud, Obsidian互換）
```

NotionとObsidianとRewindとClaude Codeのメモリを全部足して、それをフォルダ1つに圧縮したもの。それがmull。

### Final Goal: 実行する分身（The Understudy）

第二の脳は到達点ではない。**通過点**である。

mullはあなたの行動を1年間見てきたカバン持ちだ。カバン持ちの最終形は「知っている」ことではなく、**「あなたとして動ける」**こと——あなたが繰り返しやっている仕事を、あなたの流儀で仕上げて差し出す**分身**になることだ。

```
価値の階層:
  1. 記録する      （あなたを捕える）        ← 実装済み
  2. 肖像にする    （あなたを知る = 整形は創造）← 実装済み・mullの現在の堀
  3. 先回りする    （見ていたから、先に用意する）
  4. バーチャル自分（あなたの反復行動のプレイブック集）
  5. 代わりに実行  （あなたとして仕上げ、差し出す）← 最終形
```

分身の差別化軸は **capability（賢さ）ではなく fidelity（忠実さ＝you-shaped）**。汎用エージェントは有能だが、あなたではない。mullの分身は有能である必要はない——**あなたに似ていればいい**。それを可能にするのは、mullだけが持つ「あなたがどうやるかの行動ログ」と「あなたの訂正の履歴」である。

最初の分身の仕事（V1・実装済み）: **「Today, in your words」**——今日の活動を、あなたの文体で日報に仕上げて差し出す。あなたの編集が翌日の文体サンプルになる（fidelityループ）。

> 「これ、私が書いたやつだ」——この瞬間が分身の価値。
> （第一段階の「なんでそこまで知ってるの？」に続く、第二の魔法）

---

## 3. Core Values

1. **Invisible（存在を忘れる）** — インストールした瞬間から記録が始まる。設定不要。操作不要。
2. **Accumulative（勝手に育つ）** — 使えば使うほど第二の脳が豊かになる。自動取得 + 手動投入 + AI書き込み。
3. **Boundaryless（境界がない）** — どんな情報でも入る。テキスト、画像、PDF、URL。拒まない。
4. **AI-native（AIのために存在する）** — 全データはAIが読める形で構造化される。MCPで直接アクセス。コピペ不要。

---

## 3.5 Positioning: Why Not Just Give AI Full PC Access?

Claude Code、openClaw、Computer Use — これらはPCを丸ごと操作・解析できる。しかし「アクセスできる」と「理解している」は全く違う。

```
Claude Code:      PC全体にアクセス可能
                  → でも毎回ファイルを探索する
                  → 100万ファイルの中から関連情報を探す
                  → 遅い。トークンを浪費する。ノイジー。

mull:            事前に構造化済み
                  → me.md を読むだけで「誰か」がわかる
                  → now.md を読むだけで「今何してるか」がわかる
                  → 瞬時。安い。的確。
```

**AIに必要なのは「アクセス権」ではなく「整理された文脈」。**

PCを丸ごと読めても、10万ファイルの中から今日のミーティング情報を探すのは非効率。mullが先に「この人は3つの事業を同時に回していて、15:00からFX事業のCSミーティングがあって、午前中はPantryAppのStoryboard改修をPhase 5まで進めた」と構造化しておけば、AIは即座に的確な応答ができる。

### mullの3つの差別化

**1. 事前構造化（Pre-structured Context）**

生データを即座に構造化する。AIが毎回解析する必要がない。

```
生データ:    4,235 events / day
  ↓ AnalyticsEngine + FactExtractor + TimeBlockEngine
構造化:     me.md (~200 tokens) + now.md (~500 tokens)
  ↓
AIが読む:   0.1秒で「あなた」を理解
```

**2. 可視化（Visible Intelligence）**

mullが何を知っているかをユーザーが確認・修正できる。

- Insights tab: 「あなた」がどう解析されているかが見える
- Files tab: me.md を直接編集して「AIの理解」を修正できる
- Timeline: 「メインでやったこと」の推論結果を確認できる

ブラックボックスではない。ユーザーが信頼できる透明性。

**3. 選択的コンテキスト（Right-sized Context）**

全てを渡すのではなく、必要な分だけ渡す。

```
Profile (~200 tokens):  身元だけ。常に安全。
Standard (~700 tokens): 身元 + 今の作業。通常はこれで十分。
Full (~1,500+ tokens):  全て。新しいタスクの開始時だけ。
```

100万トークンのコンテキストウィンドウがあっても、無駄に埋めるべきではない。必要な文脈を最小トークンで渡すことで、AIの精度を最大化する。

---

## 3.6 Non-Features（意図的にやらないこと）

可能性があるからこそ、やらないことを決める。人間の脳は多機能を使いこなせるようにできていない。

| やらないこと | 理由 |
|------------|------|
| **画面OCR / スクリーンショット** | Screenpipeの領域。CPU/ストレージが重い。キーストローク+クリップボードで十分 |
| **音声録音・書き起こし** | Omi/Granola/Plaudの領域。ハードウェアが必要。mullはテキストに集中 |
| **タスク管理** | Things/Todoist/Linearの領域。記録と管理は別の関心事 |
| **カレンダー編集** | Calendar.appの領域。mullは読み取りのみ |
| **メール送信・返信** | Mail.appの領域。mullは読み取りのみ |
| **WYSIWYG エディタ** | Notionの領域。mullはプレーンマークダウン。シンプルさが価値 |
| **リアルタイム共同編集** | Google Docs/Notionの領域。mullは個人の脳 |
| **汎用チャットボット** | ChatGPT/Claudeの領域。雑談・一般質問はやらない。ただし「自分の記録について聞く」スコープ付きチャットは可（下記注を参照） |
| **プラグインマーケットプレイス** | 複雑さが指数関数的に増える。コア体験がぼやける |
| **クラウド同期** | プライバシーの根幹を揺るがす。iCloud/gitは自分でやればいい |
| **iOS / Android版** | macOS Accessibility APIに依存。モバイルでは同等の記録ができない |
| **ブラウザ拡張** | インストール摩擦。AppleScript + History.dbで十分 |
| **カスタムプロンプト編集** | ユーザーにプロンプトを触らせない。「何も考えなくていい」の原則 |
| **ダッシュボードのカスタマイズ** | ウィジェット配置を考える時間 = 無駄。mullが最適配置を決める |

### 原則

**mullは分身であり、汎用エージェントではない。**（旧「mullはデータ層であり、AIの頭脳ではない」を改訂）

mullの仕事は2つ:
1. **記憶を整形する** — AIに渡す「あなた」を構造化する（custode / カバン持ちの基本職務）
2. **あなたとして下書きする** — 観察した反復行動を、あなたの流儀で仕上げて差し出す（分身の職務）

汎用的な賢さで勝負しない。「何でもできる」はClaude/ChatGPT/Cursorの領域。mullの分身は**あなたがやっているのを観察した行動だけ**をやる。賢いからではなく、あなたを千回見たから書ける——それが堀。

#### 分身の憲法（dignity 3制約 — 破ったらBは監視に堕ちる）

1. **発火は常に主** — 分身は下書きまで。送信・実行・公開はあなたがワンタップで承認する。自動発火はしない
2. **根拠を見せる** — 「先週あなたがこう書いたから」と、何から学んだかを開示する
3. **訂正が分身を育てる** — あなたの編集はいつでも可能で、編集そのものが翌日の文体サンプルになる（fidelityループ）。記録も分身も、所有されず預かられる

> **スコープ付きチャットについて（v2）**: mull内のチャットは「汎用チャットボット」ではない。あなたの記録（me/now/projects）に根拠を置いて「自分について」答え、記録の再整理を指示する窓口。雑談や一般質問が来たら断ってClaude/ChatGPTに誘導する。重い汎用思考はMCP経由でmullを読むClaude/ChatGPTがやる。分身の「実行」はこれと別物で、上の憲法に従う。

**1つの画面で1つのことしかしない。**

- Home = 全体の把握
- Live = 記録の確認
- Calendar = 1日/1週間の振り返り（旧Timeline）
- Chat = 自分の記録に問いかける
- Files = 情報の編集
- （Insights/パターン確認は Settings の Profile タブ）

メインのピンは少数に保つ。新しいピンを足したくなったら、既存のどれかが肥大化している証拠。

---

## 4. Design Language

### Color Scheme

> 詳細は `DESIGN-NORTHSTAR.md`（Cucinelli / custode の哲学）が正。衝突したらそちらが優先。

- **Base**: 温かいニュートラル（アイボリー `#F2EDE1` のキャンバス、紙の質感。冷たいテックグレー禁止）
- **Ink**: エスプレッソ `#393127`（真っ黒を使わない）
- **Accent**: タバコブラウン `#945F32`（DS.moon）。**`Color.accentColor` を直接使わない**——システム設定のアクセントに上書きされ青が混入する。必ず DS トークンを通し、ネイティブコントロールにはルートで `.tint(DS.moon)`
- **Cards**: 温かい紙の面 + ヘアライン。`.ultraThinMaterial`（冷たいガラス）は人間に向く面で禁止
- **App Colors**: 既知アプリはキュレーション色、未知アプリはハッシュベースの自動色生成

### Typography

Design Tokens（`DS`）で統一:
- Hero: 28pt bold
- Title: 15pt semibold
- Body: 13pt regular
- Caption: 11pt regular
- Micro: 10pt monospaced

### Spacing

4px grid: xs(4) / sm(8) / md(12) / lg(16) / xl(24) / xxl(32)

### UI Philosophy

- Bear風ミニマリズム: テキストに集中できる。UIは存在を消す
- Raycastのキーボードファースト: ⌘A, ⌘C, Escで閉じる
- Apple純正に溶け込む: 独自デザインシステムは最小限

---

## 5. App Structure

### Menu Bar (Quick Access)

メニューバーの☽アイコン。クリックでドロップダウンパネル。
- 検索バー（自動フォーカス、Esc=クリア→閉じる）
- 今日のカード（イベント数 + 直近3キャプチャ + ミニインサイト）
- アクションバー（Copy / Copy to AI / Export）
- 過去のサマリー（折りたたみ式）
- プライバシーステータス + キーボードヒント

### Main Window (Apple Notes風サイドバー + コンテンツ)

左サイドバーは「ピン留めビュー + ファイルツリー」。Pinned に **Home / Calendar / Live / Chat**、その下に Context（me/now/full/MEMORY）/ Daily / Memory / Notes / projects のファイル群。

**Home** — AIパスポートのコントロールセンター
- プロフィール + ファクト + 直近の活動 + 検索

**Calendar** — Apple Calendar風の週ビュー（旧「Timeline」相当）
- 横=曜日 / 縦=時間。TimeBlockEngineから自動充填、手入力なし
- カレンダー予定（EventKit）+ 活動ブロックを並列表示

**Live** — リアルタイムイベントストリーム
- 録音状態 + イベント数 + ストレージ
- 色分けされたイベント（🔵keyboard 🟠clipboard 🟢window 🟣app）

**Chat** — 自分の記録についてのスコープ付きチャット（v2、§3.6注参照）
- me/now/projects を根拠に「自分について」答える。汎用ボットではない

**Files**（サイドバーのファイルツリー＝Bear風mdエディタ）
- コアファイル（me/now/full/MEMORY）+ フォルダ + projects/
- 新規作成・名前変更・削除・auto-generatedバッジ
- 自動生成ファイルは読み取り専用、ユーザーノートは編集可

### Settings (4 Tabs)

- **General**: mull時刻、起動設定、出力サイズ、エクスポート先
- **AI**: LLMプロバイダー（**既定=Off／**Gemini / Ollama / Claude / OpenAI）+ 接続テスト。既定オフ=外部送信なし
- **Data**: 権限状態、データソース（メール等）、ストレージ、保持期間、クリーンアップ、プライバシー声明
- **Profile**（=Insights）: 「あなた」の可視化。プロフィール + ファクトタグ + 分析グリッド + キーワード + What mull Knows

> 注: 「Insights」はメインウィンドウのタブではなく Settings の Profile タブに在る。メインの4ピンは Home/Calendar/Live/Chat。

---

## 6. Data Capture

### 自動取得（常時稼働）

| ソース | 方法 | 取得内容 |
|--------|------|---------|
| キーストローク | CGEvent tap | 全入力（ローマ字含む）、1秒バッファ |
| クリップボード | NSPasteboard 0.5秒ポーリング | コピーした全テキスト |
| ウィンドウタイトル | Accessibility API 5秒ポーリング | ファイル名/ページ名 |
| ブラウザURL | AppleScript | Safari/Chrome/Arc/Brave/Edge |
| アプリ切り替え | NSWorkspace通知 | アプリ名 + 滞在時間 |
| カレンダー | EventKit | 今日のスケジュール |
| メール | AppleScript（オプトイン） | 件名 + 送信者のみ（本文は読まない） |

### 手動投入（Files tab）

- mdファイルの作成・編集
- フォルダ整理
- ドラッグ&ドロップ（将来）

### AI書き込み（MCPサーバー）

- `write_note`: AIが会話中にメモを保存
- `get_user_context`: AIがmullを読む
- `search_history`: AIが過去のイベントを検索
- `list_files`: AIがファイル構造を確認

---

## 7. Data Processing

### ルールベース（LLM不要、常時稼働）

| エンジン | 機能 |
|---------|------|
| AnalyticsEngine | キーワード頻度、アプリ使用比率、時間帯パターン、曜日パターン、言語比率 |
| ProjectNames | 「この断片はプロジェクト名か」の**唯一の判定**。形（長さ/ファイル名/URL/文）と証拠（あるブラウザの全タイトルに出る断片＝クローム）で判定する。語彙ブロックリストは持たない |
| FactExtractor | **観測のみ**: 言語比率・実測ツール・プロジェクト名。人物についての推測（役割・技術スタック・ドメイン）は2026-07に削除 |
| TimeBlockEngine | イベント→時間ブロック集約、「メインでやったこと」推論 |
| CurrentState | 「今」のアンカー（active entity/app + 直近の高salience信号）。now.md と MCP `whats_active_now` の両方がこれを出す |
| LiveContextGenerator | me.md / now.md / full.md を60秒ごと自動生成 |

> **原則**: ここが出力していいのは、ユーザーに「この行はこの記録から来た」と示せるものだけ。
> アプリ一覧から職業を、クリップボードの部分一致から技術スタックを名乗るのは
> 「観測」ではなく「主張」であり、me.md の先頭に置いてよいものではない（DIRECTION §4/§9.1）。

### LLM統合（オプション、夜間）

| フェーズ | 処理 |
|---------|------|
| 3-Gate Trigger | Time(24h) → Data(50+イベント) → Lock(PID) |
| Phase 1: Orient | 既存メモリ読み込み |
| Phase 2: Gather | 24時間のイベント収集 + 時間帯グルーピング |
| Phase 3: Consolidate | LLMで要約生成 + メモリ更新（失敗時ルールベースフォールバック） |
| Phase 4: Prune | MEMORY.md を200行/25KB以内に維持 |

---

## 8. 3-Layer Context System

| ファイル | サイズ | 内容 | 用途 |
|---------|-------|------|------|
| `me.md` | ~200 tokens | 「誰か」— 身元、スキル、好み | 常に安全。CLAUDE.mdに入れていい |
| `now.md` | ~500 tokens | 「今何してるか」— プロジェクト、今日の活動、スケジュール、パターン | タスク関連の会話に |
| `full.md` | ~1,500+ tokens | 全て — me + now + 生データ | 新しい大きなタスクの開始時 |

---

## 9. Privacy

### 大原則: ローカル完結

- 全データはユーザーのMac内に保存。mull社のサーバーは存在しない
- LLMは既定で**Off**。クラウドプロバイダ（Gemini/Claude/OpenAI）を明示的に選んだ時だけ外部送信。送信前にクリップボード/打鍵の機密（メール/APIキー/カード番号等）は除外
- クラウドLLM使用時: ユーザー自身のAPIキーで直接通信。中間サーバーなし
- 使用統計の収集・送信は一切なし（トグルも持たない）

### データ保護

- パスワードフィールド自動スキップ（`IsSecureEventInputEnabled`）
- アプリ除外リスト（1Password, Keychain等はデフォルト除外）
- mull自身のイベントは記録しない
- メール: 件名+送信者のみ。パスワードリセット・銀行通知は自動除外
- APIキー: macOS Keychain保存（平文なし）

---

## 10. Technical Architecture

| レイヤー | 技術 |
|---------|------|
| Language | Swift |
| UI | SwiftUI |
| Database | SQLite via GRDB.swift (WAL + FTS5 + DatabasePool) |
| Keystrokes | CGEvent tap (Quartz Event Services) |
| Calendar | EventKit |
| Browser | AppleScript |
| Email | AppleScript (Mail.app) |
| API Keys | macOS Keychain Services |
| LLM | Ollama / Anthropic API / OpenAI API |
| AI Protocol | MCP (Model Context Protocol) via stdio |
| Design System | DS tokens (typography, spacing, radius, colors, gradients) |

---

## 11. Competitive Positioning

| | Screenpipe | Pieces | Mem0 | **mull** |
|--|-----------|--------|------|----------|
| データ取得 | 画面OCR + 音声 | 画面OCR | 会話からのみ | **キーストローク + クリップボード + ウィンドウ + カレンダー + メール** |
| 出力形式 | SQLite | API | API | **mdファイル（ポータブル、人間もAIも読める）** |
| MCP | あり | あり | あり | **あり（読み書き両方）** |
| LLM依存 | なし | あり | あり | **なし（ルールベースで基本動作）** |
| ファイル管理 | なし | なし | なし | **あり（Bear風エディタ）** |
| 設計思想 | 記録インフラ | 開発者ツール | AIメモリ層 | **第二の脳** |

mullだけがやっていること:
1. キーストローク+クリップボードの直接取得（OCRではない）
2. ポータブルなmdファイル出力（DB/APIではない）
3. ファイル管理UI（Bear風エディタ）
4. LLM不要で基本動作（ルールベース分析 + ファクト抽出）

---

## 12. Roadmap

ロードマップの軸は機能の追加ではなく、**価値の階層（§2 Final Goal）を一段ずつ登ること**。衛星機能（Calendar/Search/Chatの磨き込み）は壊れていない限り優先しない。

### Now (v1) — 記録と肖像【実装済み】
- キーストローク、クリップボード、ウィンドウ、カレンダー、メール件名、ブラウザURL
- me.md / now.md / full.md 自動生成（60秒ごと、Curator による編集保護）
- MCPサーバー（12ツール、読み書き、Claude Code / Claude Desktop / Cursor 自動設定）
- 「メインでやったこと」推論（TimeBlockEngine、dominantアプリ判定）
- Bear風ライブ装飾エディタ（conceal/reveal、生mdバイト不変）
- 統合検索（タイプ/コピー/予定の時系列タイムライン + フィルタ + ⌘K）

### Next (v1.x) — 分身の最初の仕事【進行中】
- ✅ 「Today, in your words」: あなたの文体の日報下書き（ReportWriter）
- ✅ fidelityの実測: 草稿と承認稿の編集距離を承認時に計測・日次で保存（EditDistance / ReportWriter.fidelitySeries）。**無編集承認は文体サンプルに入らない**（provenance記録で構造的に遮断）
- 先回り: 夕方に自動で下書きが用意されている（開いたらもうある）
- 根拠の開示: 「この文体は◯◯から学んだ」をカードに表示
- ストリーミング応答（Chat / 日報生成の体感品質）
- Home の肖像化（計器盤からの脱却、NORTHSTAR チェックリスト準拠）

### Future (v2) — 分身のレパートリー拡張
- 「AIへの自己説明の代行」: Copy to AI を分身の所作へ（先に入って文脈を渡し、確認質問まで添える）
- 再開ブリーフ: 中断点から「次の一手」を下書き
- MCP還流の強化: 外のAIとの会話で学んだことが me.md に書き戻る
- データ源の拡充: ブラウザ履歴全取得、Git活動、メール本文（オプトイン）

### Ultimate (v3) — 実行する分身
- あなたの反復行動のプレイブック集（バーチャル自分）が育つ
- 観察した行動を、憲法（§3.6）の範囲で代行する
- mull = 巣立たないカバン持ち。卒業レベルの能力のまま、一生あなたの分身でいる

---

*Remember everything. Explain nothing. ——そして、いつか代わりに書く。*
