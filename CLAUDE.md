# Dream - Product CLAUDE.md

## 1. Identity

- **App Name**: Dream
- **Subtitle**: Your life, AI-ready.
- **Tagline**: Remember everything. Explain nothing.
- **Category**: Productivity / Utilities
- **Platform**: macOS (Apple Silicon)

---

## 2. Concept

「説明する手間を消す」アプリ。

AIに仕事を頼むたびに、自分の状況・文脈・過去の判断を一から説明し直すのは、本来不要な作業。Dreamはその手間を丸ごと消し、「AIがあなたを既に知っている状態」を自動で作る。

ユーザーにとっての価値は「記録」ではなく「説明しなくていい」こと。

### Core Values

1. **Invisible（存在を忘れる）** - インストールした瞬間から記録が始まる。設定不要。操作不要。アプリを開く必要すらない。
2. **Accumulative（勝手に育つ）** - 毎晩LLMが1日を要約し、知識が構造化されて蓄積される。使えば使うほど「あなた理解」が深まる。
3. **AI-ready（すぐ渡せる）** - 蓄積されたコンテキストを1タップでAIに渡せる。AIがあなたの同僚になる瞬間。

### Positioning

Rewind/Screenpipeは「全てを記録するインフラ」。パワーユーザー向けで、設定・管理・活用は自分でやる必要がある。

Dreamは記録+要約+AI連携を「インストールして放置」に圧縮する。機能が少ないことが価値。Rewindが「監視カメラ」なら、Dreamは「日記を代筆してくれる秘書」。

### Core Value（核）

> **「あなた」をAIに渡せるファイルにする**

- Layer 1（表層）: 「今日何したか」を毎晩自動で記録してくれる
- Layer 2（中層）: 蓄積データがNotion/Obsidianに構造化されて入る
- Layer 3（核）: 蓄積データがAIの「あなた理解」になる

Layer 3が核。AIに「先週のレビューで指摘されたパターン、今回も同じだけど大丈夫？」と言われる体験。あなたが説明しなくても、AIが文脈を持っている状態。

---

## 3. Design Language

### Color Scheme

- **Base Light**: `#FFFFFF`
- **Base Dark**: `#1C1C1E`（ダークモード時）
- **Surface**: `#F2F2F7`（ライト）/ `#2C2C2E`（ダーク）
- **Accent（Primary）**: Indigo `#5856D6`（Appleの「睡眠」と同系色。夢のメタファー）
- **Accent Light**: `rgba(88, 86, 214, 0.12)`
- **Success**: `#34C759`（Apple標準グリーン）
- **Text Primary**: `#000000`（ライト）/ `#FFFFFF`（ダーク）
- **Text Secondary**: `#8E8E93`
- **Text Tertiary**: `#C7C7CC`
- **Separator**: `#E5E5EA`（ライト）/ `#38383A`（ダーク）

### Visual Identity

- **World View**: 「静かな夜に記憶が整理される」 - 眠りの中で脳が記憶を定着させるプロセスのメタファー
- **Key Visual**: なし。Apple純正に溶け込むことが最優先。ブランド主張は最小限
- **Icon**: 月のモチーフ `moon.fill`。Indigo背景に白い三日月。macOSのメニューバーアイコンは `moon` のSF Symbol

### Typography

- **System font**: SF Pro（Apple標準）
- **サマリー本文**: SF Pro Text, 14pt, Regular
- **日付ヘッダー**: SF Pro Text, 13pt, Semibold, ALL CAPS, letter-spacing: 0.5px, Text Secondary
- **セクション見出し**: SF Pro Text, 15pt, Semibold
- **検索バー**: SF Pro Text, 16pt, Regular
- **数値・統計**: SF Pro Rounded, Semibold

### Design Philosophy

このアプリの存在理由は「AIにあなたを渡す」こと。UIの全ての判断はこの一点から逆算する。

1. **核の価値に1タップで到達する**
   - メニューバーをクリック → パネルが開く → 「AIに渡す」ボタンが常に視界にある。この3ステップが最短経路であり、これ以上短くできない限界まで削る
   - 「AIに渡す」はアクションバーの中央、Indigoアクセントカラーで唯一の強調ボタン。他のボタン（Copy, Export）はセカンダリカラー
   - 検索もサマリー閲覧もエクスポートも全て「あって便利」な機能。「AIに渡す」だけが「なければ製品でない」機能

2. **UIは存在を消すためにある**
   - このアプリは使わないことが正しい使い方。95%の時間はバックグラウンドで動き、ユーザーは存在を忘れている
   - UIが必要になるのは「AIに渡したい瞬間」と「振り返りたい瞬間」だけ。それ以外の時間にアプリが主張してはならない
   - macOSネイティブに溶け込むのは美学ではなく機能的要請。「別のアプリを開いている」感覚すら与えたくない

3. **Surface階層で複雑さを隔離する**
   - Surface 1（メニューバーアイコン）: 存在の確認だけ。情報ゼロ
   - Surface 2（パネル）: **95%のユーザーが100%の時間ここだけで完結する**。今日のサマリー + AIに渡す + 検索
   - Surface 3（AI選択シート）: 核の価値を届ける瞬間。選択→コピー→AIで開く。3タップで完了
   - Surface 4（フルウィンドウ）: 週次/月次の振り返り。パワーユーザーのみ、たまにしか開かない
   - Surface 5（設定）: 一度設定したら二度と開かない
   - 複雑さが奥に行くほど増える。手前は常にシンプル

4. **サマリーが主役。UIは額縁**
   - パネルの面積の80%以上はサマリーテキストで占める。UIクロムは最小限
   - Paparazziが「コンテンツが主役、UIは画面の下20%」なら、Dreamは「サマリーが主役、UIは額縁」
   - ボタン、ラベル、区切り線を1つ減らせるなら減らす。追加するなら「それがないと核の価値に到達できない」場合のみ

### UI Implementation

- **macOSの一部に見える**ことが最優先。独自のデザインシステムは作らない
- SwiftUIの標準コンポーネントをそのまま使う。カスタムUIは最小限
- `.ultraThinMaterial` でメニューバーパネルの背景をぼかし、OSネイティブ感を出す
- ライトモードがデフォルト。「記録されている」安心感。ダークは監視感が出る
- ダークモードにも完全対応（macOSの設定に自動追従）
- 情報密度はApple Journal程度。余白を十分に取る
- アニメーションはmacOS標準の`spring`。派手な演出はしない

### Interaction Design

- **メニューバークリック**: パネル表示/非表示
- **スクロール**: タイムラインを過去方向に遡る
- **検索**: `Cmd+F` or 検索バーをクリック。インクリメンタルサーチ
- **コピー**: サマリーカードのアクションボタンからワンクリック
- **キーボードショートカット**: `Cmd+Shift+D` でグローバルにパネルをトグル

---

## 4. App Structure

### Surface 1: メニューバーアイコン

- macOS メニューバーに常駐する月アイコン `moon.fill`
- クリックでパネル（Surface 2）をドロップダウン表示
- Dreamの夜間処理中（23:00頃）はアイコンが `moon.stars.fill` に変わり、処理完了後に戻る
- 基本的にこれ以外の「存在主張」はしない。空気のように常駐する

### Surface 2: メニューバーパネル（メイン画面）

日常操作の95%はここで完結する。Raycast風のドロップダウンパネル。

- **幅**: 420px
- **最大高さ**: 600px（画面の60%を超えない）
- **背景**: `.ultraThinMaterial`

#### パネル構成（上から）:

1. **検索バー**
   - プレースホルダー: "Search your memory..."
   - SF Symbol `magnifyingglass` アイコン
   - インクリメンタルサーチ。過去のサマリー全文を検索
   - 結果はタイムライン上でハイライト

2. **今日のサマリーカード**
   - ヘッダー: "TODAY - Mon, March 31"（日付、曜日）
   - 本文: 時間帯ごとの活動サマリー（午前/午後/夜）
   - 各項目は1行の箇条書き。動詞で始める（「〜を実装」「〜を調査」「〜について議論」）
   - セクション: 「学んだこと」「進行中」（該当がある日のみ表示）
   - Dreamが未実行の場合（当日分）: リアルタイムの記録状況をプレビュー表示
     - "Recording... Dream runs at 23:00" のサブテキスト

3. **アクションバー**（サマリーカード下部）
   - `📋 Copy` — サマリーをMarkdownとしてクリップボードにコピー。**セカンダリスタイル（グレー、控えめ）**
   - `🤖 AI に渡す` — コンテキスト選択シート（Surface 3）を表示。**プライマリスタイル（Indigo、唯一の強調ボタン）**。これが製品の存在理由であり、視覚的に最も目立つ要素
   - `📓 Export` — Obsidian/Notion/ファイルに出力。**セカンダリスタイル（グレー、控えめ）**

4. **過去のサマリー**（スクロール）
   - 昨日、一昨日...と時系列で並ぶ
   - 各カードは折りたたまれた状態（1行プレビュー）。クリックで展開
   - 無限スクロールで過去に遡れる

### Surface 3: AIコンテキスト選択シート

「AI に渡す」ボタンから表示されるシート。

- チェックボックスリスト:
  - `[x] 今日のサマリー`
  - `[x] 今週の学び`
  - `[ ] 今月の傾向`
  - `[x] 進行中のプロジェクト`
  - `[ ] 全メモリ（MEMORY.md）`
- コピー先ボタン:
  - `Claude` — クリップボードにコピー + claude.ai を開く
  - `ChatGPT` — クリップボードにコピー + chatgpt.com を開く
  - `Clipboard` — コピーのみ
- 将来的にMCP連携で「Claude側からDreamを読む」を実装予定

### Surface 4: フルウィンドウ（振り返りビュー）

メニューバーパネルから「Open Dream」またはグローバルショートカットで開く独立ウィンドウ。
週次/月次の振り返り時に使用。

- **左サイドバー**:
  - カレンダーピッカー（月表示、日付をクリックでジャンプ）
  - 「今日」ボタン
  - タグフィルター（自動生成されたプロジェクトタグ）

- **メインエリア**:
  - Apple Journal風のタイムライン
  - 各日のサマリーカードが縦に並ぶ
  - 日付間に「この週のハイライト」等の集計カードが挿入される

- **集計カード**（週次/月次の区切りに表示）:
  - よく使ったアプリ Top 5
  - 主なプロジェクト/テーマ
  - 作業パターン（何曜日の何時に集中しているか）
  - 学びのハイライト

### Surface 5: 設定画面

最小限。macOS標準のSettings window。

- **General**
  - Dream実行時刻（デフォルト23:00、スライダーで変更）
  - ログイン時に自動起動（デフォルトON）
  - グローバルショートカット設定

- **Recording**
  - 記録対象アプリの除外リスト（デフォルト: パスワードマネージャー、銀行アプリ等を除外）
  - 記録タイプの選択: 画面テキスト / キーストローク / 音声（各トグル）
  - 一時停止ボタン（「次の1時間記録しない」等）

- **AI**
  - LLMプロバイダー選択:
    - ローカル（MLX / Ollama）— デフォルト。データが外に出ない
    - Claude API（APIキー入力）
    - OpenAI API（APIキー入力）
  - モデル選択（プロバイダーに応じたドロップダウン）

- **Export**
  - 出力先設定:
    - ローカルフォルダ（デフォルト: `~/Dream/`）
    - Obsidian vault パス
    - Notion連携（OAuth）
  - 自動エクスポート（Dream実行後に自動でエクスポートするか）

- **Privacy**
  - データ保存期間（デフォルト: 無制限。30日/90日/1年/無制限から選択）
  - 全データ削除ボタン
  - データの保存場所表示（`~/Library/Application Support/Dream/`）

---

## 5. Core Features

### 5.1 Silent Recording（常時記録）

バックグラウンドで常時動作し、以下を記録する。

| データタイプ | 取得方法 | 用途 |
|------------|---------|------|
| 画面テキスト | Accessibility API（`AXUIElement`） | 何のアプリで何を見ていたか |
| アクティブウィンドウ | `NSWorkspace` + `CGWindowList` | アプリ切り替え、作業時間 |
| キーストローク | `CGEvent` tap | 入力内容のキャプチャ |
| クリップボード | `NSPasteboard` 監視 | コピーした内容の記録 |
| 音声（オプション） | `AVAudioEngine` | 会議の書き起こし |

#### 記録ポリシー:

- **イベント駆動**: 常時スクリーンショットは撮らない。アプリ切替、タイピング停止（1秒以上）、クリップボード変更時にスナップショット
- **除外リスト**: パスワードマネージャー（1Password, Bitwarden等）、銀行アプリ、キーチェーンアクセスはデフォルト除外
- **パスワードフィールド検出**: `AXUIElement` の `isSecureTextField` 属性でパスワード入力を自動検出・除外
- **省電力**: CPU使用率5%以下を目標。Accessibility APIはOCRの1/3の負荷
- **完全ローカル**: 記録データは一切外部に送信しない

#### Storage:

- **DB**: SQLite（GRDB.swift）with WAL mode
- **場所**: `~/Library/Application Support/Dream/dream.sqlite`
- **テーブル構成**:
  - `events` — タイムスタンプ, イベントタイプ, アプリ名, ウィンドウタイトル, テキスト内容
  - `keystrokes` — タイムスタンプ, アプリコンテキスト, 入力テキスト（パスワードフィールド除外済み）
  - `clipboard` — タイムスタンプ, 内容, ソースアプリ
  - `audio_chunks` — タイムスタンプ, 書き起こしテキスト, 話者ID
- **FTS5**: 全文検索用の仮想テーブル（`events_fts`, `keystrokes_fts`）
- **データ量目安**: 1日あたり約10-50MB（テキストのみ。音声を含む場合は+100MB/時間）

### 5.2 Dream Engine（夜間要約エンジン）

Claude Codeの autoDream アーキテクチャを移植・応用した要約システム。

#### 3ゲートトリガー:

毎晩、設定時刻（デフォルト23:00）に以下を順にチェック:

| ゲート | 条件 | コスト | 目的 |
|-------|------|------|------|
| **Time Gate** | 前回Dream実行から24時間以上経過 | `.dream-lock` のmtime確認（1 stat） | 重複実行防止 |
| **Data Gate** | 前回以降に一定量の新規記録が存在 | SQLite COUNT クエリ（1 query） | 空振り防止 |
| **Lock Gate** | 他のDreamプロセスが実行中でない | PIDファイル確認 + プロセス存在チェック | 競合防止 |

3つ全てパスした場合のみDreamを実行。

#### 4フェーズ処理:

```
Phase 1: Orient（現状把握）
  → 既存のMEMORY.mdとメモリファイルを読み込み
  → 現在の知識ベースの全体像を把握

Phase 2: Gather（情報収集）
  → SQLiteから過去24時間の記録を取得
  → アプリごと・時間帯ごとにグルーピング
  → 重要なイベント（長時間の集中作業、新しいツールの使用、繰り返しパターン）を抽出

Phase 3: Consolidate（統合・要約）
  → LLMが1日のサマリーをMarkdownで生成
  → 既存メモリとの矛盾を検出・更新
  → 新しい学びや判断をメモリファイルとして保存
  → 相対日付（「今日」「昨日」）を絶対日付（2026-03-31）に変換

Phase 4: Prune & Index（整理）
  → MEMORY.mdを200行以内に維持
  → 古い/陳腐化した情報を削除
  → インデックスを更新
```

#### 出力ファイル構造:

```
~/Dream/
  MEMORY.md                         # 知識インデックス（200行以内）
  daily/
    2026/
      03/
        2026-03-31.md               # 日次サマリー
        2026-03-30.md
  memory/
    user_profile.md                 # ユーザー情報（役割、スキル、好み）
    project_paparazzi.md            # プロジェクト文脈
    project_dream.md
    feedback_coding_style.md        # 作業スタイルの傾向
    reference_tools.md              # よく使うツール・サービス
  .dream-lock                       # ロックファイル（mtime = 最終実行時刻）
```

#### メモリファイル形式:

```markdown
---
name: User Profile
description: Backend engineer, building iOS apps, prefers minimal design
type: user
---

- iOS/Swift開発者。PaparazziとDreamを並行開発中
- デザインはApple純正に寄せる方針
- 「機能が少ないことが価値」という設計哲学
- LLMのアーキテクチャ設計に関心が高い
```

#### 日次サマリー形式:

```markdown
# 2026-03-31 (Mon)

## 午前
- Claude Codeの漏洩ソースコードを分析
- autoDreamシステムの4フェーズ設計を詳細に調査

## 午後
- Screenpipeのアーキテクチャを調査
- Dream製品のコンセプトとUI設計を決定
- 「あなたをAIに渡せるファイルにする」を核の価値として定義

## 学んだこと
- autoDreamの3ゲートトリガー（Time/Session/Lock）が効率的な実行制御の鍵
- Screenpipeのパイプシステムはcron + markdown promptで拡張可能
- Apple Journal x Raycast のハイブリッドがDreamのUI方針

## 進行中
- Dream: CLAUDE.md（製品仕様書）を作成開始
- Paparazzi: モザイク処理のSwift実装
```

### 5.3 AI Context Export（AIコンテキスト出力）

核の価値を直接体現する機能。蓄積データをAIに渡せる形に整形して出力する。

#### 出力形式:

選択したコンテキストを以下の形式でMarkdownにまとめる:

```markdown
# About Me (auto-generated by Dream)
Last updated: 2026-03-31

## Current Focus
- DreamアプリのmacOS版を設計・開発中
- Paparazziアプリの並行開発

## Recent Activity (This Week)
- Mon: Claude Codeソース分析、Dream製品設計
- Sun: React Nativeビルドエラー修正
- Sat: Paparazziのメタル処理最適化

## Working Style
- 火曜午前にDeep Workが集中する傾向
- Apple純正UIを好む
- 「機能を絞って磨く」設計哲学

## Key Decisions & Context
- DreamのUIはApple Journal x Raycast方針で決定
- LLMはローカル優先（プライバシー重視）
- Notion/Obsidian連携は初期から対応
```

#### Export先:

| 出力先 | 方法 |
|-------|------|
| Clipboard | Markdownをそのままコピー |
| Claude | クリップボード + claude.ai を開く |
| ChatGPT | クリップボード + chatgpt.com を開く |
| Obsidian | 指定vault内にmdファイルを直接書き出し |
| Notion | Notion API経由でページ作成/更新 |
| ローカルファイル | `~/Dream/exports/` に保存 |

### 5.4 Search（記憶検索）

メニューバーパネルの検索バーから、蓄積された全データを横断検索。

- FTS5全文検索（SQLite）で高速
- 日次サマリー + メモリファイル + 生データを横断
- インクリメンタルサーチ（タイプするたびに結果更新）
- 結果はタイムライン上で該当日がハイライト
- 「あの日あれについて何してたっけ」が1秒で出る

### 5.5 Notion / Obsidian Sync（外部連携）

Dream実行後に自動で外部ツールに同期。

#### Obsidian:
- 指定したvaultの `Dream/` フォルダにmdファイルを直接書き出し
- Obsidianのリンク記法（`[[]]`）に対応
- Daily Noteプラグインと連携可能な日付ベースのファイル名

#### Notion:
- OAuth認証でNotion APIに接続
- 指定データベースに日次サマリーをページとして作成
- プロパティ: Date, Tags (自動生成), Summary (本文)

---

## 6. Experience Touchpoints

### 6.1 First Launch（初回起動）

1. アプリを開く
2. macOS Accessibility権限のリクエスト（1画面で説明、ワンクリックで設定画面へ）
3. 「Dream is now recording. Your first summary will be ready tomorrow at 23:00.」
4. メニューバーにアイコンが表示される
5. 完了。チュートリアルなし。設定画面なし。すぐ閉じていい

目標: **起動から記録開始まで30秒以内**

### 6.2 First Dream（初回要約 - 翌日）

- 23:00にメニューバーアイコンが `moon.stars.fill` に変わる
- 処理完了後（通常1-3分）:
  - macOS通知: "Your first Dream is ready. ☽"
  - メニューバーアイコンに青いドット（未読インジケーター）
- パネルを開くと初めてのサマリーカードが表示されている
- この瞬間が「あ、これ勝手にやってくれるんだ」という価値体験のファーストタッチ

### 6.3 Dream処理中の表示

- メニューバーアイコン: `moon.stars.fill`（星が追加される）
- パネル内: 今日のカードに "Dreaming..." のサブテキスト + Indigo のプログレスインジケーター（細いライン）
- 派手な演出はしない。静かに処理されている感

### 6.4 通知

最小限。デフォルトで以下のみ:

- Dream完了時: "Today's Dream is ready."（1日1回まで）
- 初回セットアップ完了時

通知頻度が高いとユーザーに嫌われる。Dreamの思想は「空気のように存在する」こと。

---

## 7. Monetization

### Model

- **無料版**: 全記録機能 + 直近7日分のDream要約 + ローカルLLMのみ
- **Pro版**: 無制限の履歴 + クラウドLLM対応 + Notion/Obsidian同期 + AIコンテキストエクスポート

### 無料版の設計意図:

- 7日分のサマリーで「勝手にまとめてくれる」価値を十分に体験できる
- 8日目に最初のサマリーが消える瞬間が最も強い課金動機（損失回避バイアス）
- 記録自体は無制限に継続。データは消えない。Dream要約のアクセスのみ制限
- ローカルLLMは無料で使えるため、技術的に詳しいユーザーは無料のまま使い続けられる（これは許容する）

### Paywall

#### タイミング: 8日目のパネル表示時

```
┌────────────────────────────────────────┐
│                                        │
│  Your memories are growing.            │
│                                        │
│  7 days of Dreams are stored.          │
│  Tomorrow, your oldest Dream fades.    │
│                                        │
│  Keep all your Dreams.                 │
│  ┌──────────────────────────────────┐  │
│  │       Unlock Dream Pro           │  │
│  └──────────────────────────────────┘  │
│                                        │
│  or continue with 7-day window         │
│                                        │
└────────────────────────────────────────┘
```

- 押し付けがましくない。静かなトーン
- 「fades」という言葉で損失を想起させるが、攻撃的ではない
- 「continue with 7-day window」で無料継続の選択肢を明示

### Pricing

| Plan | Price | Note |
|------|-------|------|
| Monthly | $9.99/月 | 一般ユーザー向け |
| Annual | $79.99/年 ($6.67/月) | 33% OFF表示 |
| Lifetime | $199.99 | 早期購入者向け（将来値上げの可能性を示唆） |

**価格設定の根拠:**

- Rewind.aiは$19.95/月。Dreamはそれより安いが無料ではない
- $9.99/月はmacOSの生産性アプリとして標準的な価格帯（Raycast Pro, CleanShot X等）
- ライフタイムプランは初期のアーリーアダプター獲得とレビュー数確保のため
- LLM API費用はユーザー持ち（自分のAPIキー）またはローカルLLM。運営側のLLMコストは発生しない

---

## 8. Technical Architecture

### Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Swift |
| UI Framework | SwiftUI |
| App Type | macOS Menu Bar App (MenuBarExtra) |
| Database | SQLite via GRDB.swift (WAL mode + FTS5) |
| Screen Capture | Accessibility API (AXUIElement) |
| Keystroke Capture | CGEvent tap (Quartz Event Services) |
| Clipboard | NSPasteboard observation |
| Audio (optional) | AVAudioEngine + Speech framework / Whisper.cpp |
| Local LLM | MLX Swift / llama.cpp |
| Cloud LLM | Anthropic SDK / OpenAI SDK (直接HTTP) |
| Notion Sync | Notion API (REST) |
| Obsidian Sync | 直接ファイル書き出し |
| Scheduling | macOS `Timer` + `DistributedNotificationCenter` |
| Keychain | macOS Keychain Services（APIキー保存） |

### Why Swift Native (not Electron/Tauri)

| Aspect | Swift | Electron/Tauri |
|--------|-------|----------------|
| CPU使用率 | ~3-5% | ~10-15% |
| メモリ | ~30-50MB | ~150-300MB |
| Accessibility API | ネイティブアクセス | ブリッジ経由（遅延・制限あり） |
| App Store | 直接配信 | 制限あり |
| macOS統合 | 完全（メニューバー、通知、Keychain） | 部分的 |
| バイナリサイズ | ~20MB | ~100MB+ |

常駐アプリはリソース消費が命。Swiftネイティブ一択。

### Dream Engine アーキテクチャ

```
┌─────────────────────────────────────────────────────┐
│ Recording Layer (常時稼働)                            │
│  AXUIElement ──┐                                     │
│  CGEvent tap ──┼──→ SQLite (GRDB.swift)              │
│  NSPasteboard ─┘        │                            │
│                         │                            │
├─────────────────────────┼───────────────────────────┤
│ Dream Engine (1日1回)    │                            │
│                         ↓                            │
│  ┌─────────┐    ┌──────────────┐    ┌────────────┐  │
│  │ 3-Gate  │───→│ 4-Phase LLM  │───→│ md Output  │  │
│  │ Trigger │    │ Consolidation│    │ + Index    │  │
│  └─────────┘    └──────────────┘    └────────────┘  │
│                                           │          │
├───────────────────────────────────────────┼─────────┤
│ Export Layer                              ↓          │
│  ┌──────────┐  ┌──────────┐  ┌────────────────────┐ │
│  │ Obsidian │  │  Notion  │  │  AI Context Export │ │
│  │  (file)  │  │  (API)   │  │  (clipboard/MCP)  │ │
│  └──────────┘  └──────────┘  └────────────────────┘ │
└─────────────────────────────────────────────────────┘
```

### Privacy Architecture

プライバシーはDreamの機能ではない。Dreamの前提条件である。全キーストローク・全画面テキスト・全クリップボードを記録するアプリが信頼を失ったら、プロダクトは即死する。

#### 大原則: ローカル完結

- **完全オンデバイス処理がデフォルト**: ローカルLLM（MLX）使用時はデータが一切外部に出ない
- **クラウドLLM使用時**: 要約生成のためにその日の記録テキストのみをAPIに送信。APIキーはユーザー自身のもの。Dream社のサーバーは経由しない
- **記録データの暗号化**: SQLiteデータベースはmacOS FileVaultに依存（追加暗号化は不要）
- **パスワード自動除外**: `isSecureTextField` によるパスワードフィールドの自動検出
- **アプリ除外リスト**: ユーザーが任意のアプリを記録対象から除外可能
- **データ主権**: 全データはユーザーのMac内に保存。Dream社（開発者）はアクセスしない、できない、する仕組みが存在しない

#### Analytics方針: コンテンツは絶対に送らない。形だけ送る

プロダクト改善のためにユーザーの利用傾向は知る必要がある。ただし「何をしたか」は知る必要がない。「どう使っているか」だけを知ればいい。

**送信するもの（匿名メタデータのみ）:**

| データ | 例 | 目的 |
|-------|-----|------|
| Dream実行回数 | 1回/日 | 機能の利用率 |
| Dream処理時間 | 47秒 | パフォーマンス改善 |
| 検索利用回数 | 3回/日 | 検索機能の価値検証 |
| 「AIに渡す」利用回数 | 1回/日 | 核の価値への到達率（最重要KPI） |
| Export先 | "claude" | 連携先の優先順位判断 |
| LLMプロバイダー | "local_mlx" | ローカル/クラウドの比率把握 |
| 記録イベント数 | 1,247件/日 | ストレージ・パフォーマンス設計 |
| アプリ起動日数 | 連続14日 | リテンション計測 |
| OS/ハードウェア | "macOS 15.3, M4" | 互換性・最適化 |
| アプリバージョン | "1.2.0" | アップデート普及率 |
| 無料/Pro | "free" | 転換率計測 |

**絶対に送信しないもの（コンテンツ）:**

- サマリーのテキスト
- キーストロークの内容
- 画面テキスト・ウィンドウタイトル
- アプリ名（どのアプリを使っているかすら送らない）
- クリップボード内容
- メモリファイルの中身
- 検索クエリの文字列
- ファイルパス
- ユーザー名・メールアドレス（アカウント制度を設けない）

**境界線の原則**: 「この情報から、ユーザーが何をしていたか推測できるか？」— Yesなら送らない。

#### オプトイン設計

- **デフォルト: OFF**（匿名メタデータも送らない）
- 初回起動から7日後、初めてのPaywall表示と同じタイミングで1回だけ聞く:

```
┌──────────────────────────────────────────┐
│                                          │
│  Help improve Dream?                     │
│                                          │
│  Share anonymous usage statistics.       │
│  Never your content — only how often     │
│  you use features like search or export. │
│                                          │
│  ┌──────────┐  ┌─────────────────────┐   │
│  │ Not now  │  │ Share anonymously   │   │
│  └──────────┘  └─────────────────────┘   │
│                                          │
│  You can change this anytime in          │
│  Settings → Privacy.                     │
│                                          │
└──────────────────────────────────────────┘
```

- 「Not now」を選んでもアプリは完全に機能する。制限なし
- 二度と聞かない（設定画面からいつでも変更可能）
- 7日後に聞く理由: アプリの価値を体験した後の方がオプトイン率が高い。初日に聞くのは信頼構築前で逆効果

#### プライバシー可視化UI

ユーザーに「安全だ」と言うだけでは不十分。**安全であることを見せる**。

**1. メニューバーパネル下部の常設ステータス:**

```
┌──────────────────────────────────────────┐
│  ...（サマリーカード等）...                 │
│                                          │
│  ─────────────────────────────────────── │
│  🟢 All data stays on your Mac           │
│     Local LLM · No cloud · 14.2 MB today │
└──────────────────────────────────────────┘
```

- 常にパネル最下部に1行で表示
- `🟢` 緑ドット = ローカル完結中
- `🟡` 黄ドット = クラウドLLM使用中（「Your API key · Data sent to Anthropic API」）
- 当日の記録データ量をリアルタイム表示（「14.2 MB today」）
- この1行が「監視されている不安」を「守られている安心」に変換する

**2. 設定画面 → Privacy タブ:**

```
┌──────────────────────────────────────────────┐
│  Privacy                                     │
│                                              │
│  Data Location                               │
│  ~/Library/Application Support/Dream/        │
│  [Open in Finder]                            │
│                                              │
│  Storage Used                                │
│  ████████░░░░░░░░  847 MB (42 days)          │
│                                              │
│  What's Being Recorded        [Pause 1 hour] │
│  ☑ Screen text (Accessibility)               │
│  ☑ Keystrokes                                │
│  ☑ Clipboard                                 │
│  ☐ Audio                                     │
│                                              │
│  Excluded Apps                               │
│  1Password, Keychain Access, +2 more [Edit]  │
│                                              │
│  Anonymous Usage Statistics                  │
│  ○ OFF — No data sent to Dream              │
│  ● ON  — Feature usage only, never content   │
│  [View exactly what's shared]                │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │  🗑 Delete All Data                    │  │
│  └────────────────────────────────────────┘  │
│                                              │
└──────────────────────────────────────────────┘
```

- 「Open in Finder」でデータの保存場所を直接確認できる。隠さない
- 「View exactly what's shared」で送信されるメタデータの実際のJSONサンプルを表示。曖昧さゼロ
- 「Delete All Data」は赤いデストラクティブボタン。確認ダイアログ付きで即座に全削除可能
- 「Pause 1 hour」でワンクリック一時停止。プライベートな作業時に

**3. 「View exactly what's shared」の表示内容:**

```json
{
  "app_version": "1.2.0",
  "os": "macOS 15.3",
  "hardware": "Apple M4",
  "events": {
    "dream_completed": 1,
    "dream_duration_seconds": 47,
    "search_used": 3,
    "ai_export_used": 1,
    "ai_export_destination": "claude",
    "llm_provider": "local_mlx",
    "recording_events_count": 1247
  },
  "plan": "free",
  "streak_days": 14
}
```

- 実際に送信される直近のペイロードをそのまま表示
- 「これ以外は何も送られない」ことが一目でわかる
- 技術者でなくても「テキストの中身がない」ことは理解できる

---

## 9. Non-Features（意図的に実装しないもの）

| Feature | Reason |
|---------|--------|
| スクリーンショット/画面録画 | Rewind/Screenpipeとの差別化。テキストベースで十分。ストレージ爆発を防ぐ |
| iOS版 | macOSのAccessibility APIに依存。iOSでは同等の記録ができない |
| Webダッシュボード | データをクラウドに上げる必要が生じる。プライバシーと矛盾 |
| チーム/共有機能 | 個人の「第二の脳」に特化。共有は外部ツール（Notion等）に委ねる |
| リアルタイム通知・アラート | 「今〜してますよ」は監視感が出る。Dreamは「振り返り」のツール |
| タスク管理 | Things, Todoist等に委ねる。記録と管理は別の関心事 |
| カスタムプロンプト編集 | ユーザーにプロンプトを触らせない。「何も考えなくていい」の原則 |
| ブラウザ拡張 | Accessibility APIで十分取得可能。拡張のインストールは摩擦 |

---

## 10. Future Expansion（v2以降）

ユーザーの反応を見て検討。v1では実装しない。

- **MCP Server**: Dream自体がMCPサーバーとして動作し、Claude Desktop/Cursor等から直接クエリ可能に
- **Weekly/Monthly Digest**: 週次・月次の自動レポート生成
- **Pattern Detection**: 「最近この作業に時間がかかりすぎている」等の傾向アラート
- **Multi-device Sync**: iCloud経由でのメモリファイル同期
- **Voice Query**: 「今週何してた？」と音声で聞ける
- **API**: 外部アプリからDreamのデータを参照するREST API

---

## 11. Copywriting Guidelines

### Tone of Voice

- **静か**: 主張しない。空気のように存在する
- **温かい**: 機械的ではなく、親しい友人の語り口
- **知的**: 簡潔で無駄がない。技術用語は避けるが、ユーザーを子供扱いしない
- English base（グローバル展開前提）

### Word Choice

| Avoid | Use Instead |
|-------|-------------|
| Record everything | Remember for you |
| AI-powered | Automatic |
| Data collection | Memory |
| Productivity tool | Your second brain |
| Daily summary | Dream |
| Configure | Just works |

### App Store Description

**First 3 lines (preview):**

> Dream remembers your day so you don't have to.
> Every night, AI quietly reviews what you did and creates a structured summary — no input needed, no journaling habit required.

**Feature list:**

> - Runs silently in your menu bar
> - Auto-generates daily summaries while you sleep
> - Search months of work history in seconds
> - Export context to Claude, ChatGPT, or any AI
> - Sync to Obsidian or Notion automatically
> - 100% local by default. Your data never leaves your Mac.

**Closing tagline:**

> Remember everything. Explain nothing.

---

## 12. Metrics to Track

- Daily Active Users (メニューバーパネルを1回以上開いた)
- Dream完了率（トリガーされたDreamのうち正常完了した割合）
- 検索利用率（検索バーの使用頻度）
- 「AIに渡す」利用率（核の価値への到達率）
- Export先の分布（Claude / ChatGPT / Clipboard / Obsidian / Notion）
- 無料→Pro転換率（特に8日目の転換率）
- サマリーの平均閲覧時間（長すぎると情報過多、短すぎると価値不足）
- 記録データの平均日次容量（パフォーマンス最適化の指標）
- LLMプロバイダーの分布（ローカル vs クラウド）
