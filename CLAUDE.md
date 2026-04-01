# Dream — Product Specification

## 1. Identity

- **App Name**: Dream
- **Subtitle**: Your life, AI-ready.
- **Tagline**: Remember everything. Explain nothing.
- **Category**: Productivity / Second Brain
- **Platform**: macOS (Apple Silicon)

---

## 2. Vision

### First Goal: AIがあなたを知っている状態を自動で作る

AIに仕事を頼むたびに、自分の状況・文脈・過去の判断を一から説明し直すのは本来不要な作業。Dreamはその手間を丸ごと消す。

ユーザーにとっての価値は「記録」ではなく**「説明しなくていい」**こと。

> **「あなた」をAIに渡せるファイルにする。**

- インストールして放置するだけで、AIがあなたを知っている状態が勝手に作られる
- キーストローク、クリップボード、ウィンドウタイトル、カレンダー、メール — 全て自動取得
- me.md / now.md / full.md が60秒ごとに自動更新される
- MCPサーバー経由でAIが自分からDreamにアクセスする
- ユーザーは何もしない。AIが勝手に知っている。**「なんでこんなこと知ってるの？」**の瞬間が起きる

### Ultimate Goal: 第二の脳を作る

散らばった情報を一つの場所に集約する。境界を設けない。

- **自動で入ってくるもの** — キーストローク、クリップボード、ウィンドウ、メール、カレンダー、ブラウザ履歴、Git、ファイル変更
- **手動で入れるもの** — メモ、PDF、画像、ファイル、ブックマーク、何でも
- **AIが書き込むもの** — 会話で学んだこと、判断の記録、生成したドキュメント

この3つが全て **`~/Dream/`** フォルダに入る。

```
~/Dream/ = あなたのデジタル人格

  ├── me.md          ← AIがあなたを理解するためのプロフィール
  ├── now.md         ← 今何をしているか
  ├── full.md        ← 全コンテキスト
  ├── daily/         ← 日次サマリー（自動生成）
  ├── memory/        ← AIが学んだトピック別メモリ
  ├── notes/         ← ユーザーが自分で書くメモ
  ├── files/         ← ドラッグ&ドロップしたPDF、画像、ドキュメント
  └── clips/         ← Webクリップ、ブックマーク

誰でもアクセスできる:
  - Dream アプリ（閲覧・編集）
  - AI（MCPサーバー経由で読み書き）
  - 他のツール（ただのフォルダ。git, iCloud, Obsidian互換）
```

NotionとObsidianとRewindとClaude Codeのメモリを全部足して、それをフォルダ1つに圧縮したもの。それがDream。

---

## 3. Core Values

1. **Invisible（存在を忘れる）** — インストールした瞬間から記録が始まる。設定不要。操作不要。
2. **Accumulative（勝手に育つ）** — 使えば使うほど第二の脳が豊かになる。自動取得 + 手動投入 + AI書き込み。
3. **Boundaryless（境界がない）** — どんな情報でも入る。テキスト、画像、PDF、URL。拒まない。
4. **AI-native（AIのために存在する）** — 全データはAIが読める形で構造化される。MCPで直接アクセス。コピペ不要。

---

## 4. Design Language

### Color Scheme

- **Base**: macOS標準に従う（ライト/ダーク自動対応）
- **Accent**: Indigo `#5856D6`（Appleの「睡眠」と同系色。夢のメタファー）
- **Cards**: `.ultraThinMaterial` + 微細シャドウ + 0.5px ボーダー
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

### Main Window (4 Tabs)

**Live** — リアルタイムイベントストリーム
- 録音状態 + イベント数 + ストレージ
- 色分けされたイベント（🔵keyboard 🟠clipboard 🟢window 🟣app）
- ホバーで展開、テキスト選択可能

**Insights** — 「あなた」の可視化
- ヒーローカード: プロフィール + ファクトタグ + イベントカウンター
- カレンダースケジュール（← NOW / ← in 15min）
- Dreamサマリー（実行済みの場合）
- 2列分析グリッド: Activity / Week / Language / Apps
- キーワードタグクラウド
- What Dream Knows（メモリ一覧）

**Files** — Bear風mdファイルエディタ
- サイドバー: コアファイル（me/now/full/MEMORY）+ フォルダ
- エディタ: 22ptタイトル、14ptテキスト、行間4pt、ホバーツールバー
- ファイル管理: 新規作成、フォルダ作成、名前変更、削除、右クリックメニュー
- auto-generated バッジ（Dream生成ファイル）

**Timeline** — カレンダー風タイムライン
- サイドバー: カレンダーピッカー + 日別リスト + Generate Summaryボタン
- 「WHAT YOU MAINLY DID」ヒーローカード（ルールベース推論）
- 時間ブロック（アプリ色分け、ラベル、イベント数）
- Dreamサマリー + 直近イベント

### Settings (3 Tabs)

- **General**: Dream時刻、起動設定、出力サイズ、エクスポート先
- **AI**: LLMプロバイダー（Ollama / Claude / OpenAI）+ 接続テスト
- **Data**: 権限状態、データソース（メール等）、ストレージ、保持期間、クリーンアップ

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
- `get_user_context`: AIがDreamを読む
- `search_history`: AIが過去のイベントを検索
- `list_files`: AIがファイル構造を確認

---

## 7. Data Processing

### ルールベース（LLM不要、常時稼働）

| エンジン | 機能 |
|---------|------|
| AnalyticsEngine | キーワード頻度、アプリ使用比率、時間帯パターン、曜日パターン、言語比率 |
| FactExtractor | 役割推定、技術スタック検出、プロジェクト推定、ツール嗜好 |
| TimeBlockEngine | イベント→時間ブロック集約、「メインでやったこと」推論 |
| LiveContextGenerator | me.md / now.md / full.md を60秒ごと自動生成 |

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

- 全データはユーザーのMac内に保存。Dream社のサーバーは存在しない
- クラウドLLM使用時: ユーザー自身のAPIキーで直接通信。中間サーバーなし
- 匿名使用統計: デフォルトOFF。オプトインで形だけ送る（コンテンツは絶対に送らない）

### データ保護

- パスワードフィールド自動スキップ（`IsSecureEventInputEnabled`）
- アプリ除外リスト（1Password, Keychain等はデフォルト除外）
- Dream自身のイベントは記録しない
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

| | Screenpipe | Pieces | Mem0 | **Dream** |
|--|-----------|--------|------|----------|
| データ取得 | 画面OCR + 音声 | 画面OCR | 会話からのみ | **キーストローク + クリップボード + ウィンドウ + カレンダー + メール** |
| 出力形式 | SQLite | API | API | **mdファイル（ポータブル、人間もAIも読める）** |
| MCP | あり | あり | あり | **あり（読み書き両方）** |
| LLM依存 | なし | あり | あり | **なし（ルールベースで基本動作）** |
| ファイル管理 | なし | なし | なし | **あり（Bear風エディタ）** |
| 設計思想 | 記録インフラ | 開発者ツール | AIメモリ層 | **第二の脳** |

Dreamだけがやっていること:
1. キーストローク+クリップボードの直接取得（OCRではない）
2. ポータブルなmdファイル出力（DB/APIではない）
3. ファイル管理UI（Bear風エディタ）
4. LLM不要で基本動作（ルールベース分析 + ファクト抽出）

---

## 12. Roadmap

### Now (v1)
- キーストローク、クリップボード、ウィンドウ、カレンダー、メール件名、ブラウザURL
- me.md / now.md / full.md 自動生成
- MCPサーバー
- 「メインでやったこと」推論
- Bear風ファイルエディタ

### Next (v1.x)
- ブラウザ履歴全取得（SQLite直読み）
- Git活動自動取得
- ファイルのドラッグ&ドロップ
- 全文横断検索
- メール本文（オプトイン）

### Future (v2)
- プラグインアーキテクチャ
- Slack / Discord連携
- ファイルシステム監視（FSEvents）
- Webクリッパー
- Apple Intelligence統合（macOS 26）

### Ultimate (v3)
- 完全な第二の脳
- あらゆる情報源の統合
- AIが自律的に知識を整理
- Dream = あなたのデジタル人格

---

*Remember everything. Explain nothing.*
