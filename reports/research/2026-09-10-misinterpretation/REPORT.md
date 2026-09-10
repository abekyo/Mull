# Mull: 観測から誤った断定が生まれる経路の調査

調査日: 2026-09-10。対象: 調査時点のワークツリー（既存の未コミット変更を含む）。以下は修正前の調査記録であり、調査時点では製品コードを変更していない。`classification-output.txt` も修正前の合成入力による出力を保存したもの。

その後、この変更セットで項目2（ブラウザーの誤分類）、3（コピーの引用帰属）、4（コピー後の移動・前後関係の断定）、7（安全策の出力経路への適用）を修正した。全947テストと `./eval/run.sh` が通過。以下の再現結果・行番号は調査時点の記録として残している。

## 判断したいこと

「誤った理解を、もっともらしく表示する」問題について、発生源、利用者への出力、既存データへの残留を特定し、修正順序を決める。対象はプロジェクト分類、引用・時間の帰属、傾向分析、本人属性・知識の抽出、UI/MCP/Markdownへの伝播。市場性や価格、デザイン全般、汎用的なAIの性能は判断しない。

許容できない失敗は、観測していない本人の意図・判断・作業関係を事実として出し、その誤りを後続のAIが再利用すること。未確認を隠す改善や、一部の画面だけの修正を完了とはしない。

## 結論

主因はLLMの文章生成より前にある。現在は、観測されたアプリ・タイトル・コピー文字列から「何の仕事か」「何のために使ったか」「本人が決めたか」へ移る際に、確定できない情報が確定的なフィールドへ入る。さらに出力時に推測の区分が失われる。

次の4層を分けて修正する必要がある。

1. **観測の保持**: アプリ、タイトル、日時、コピーの出典を失わない。
2. **帰属の判断**: project/page/app/unknownを分け、時間的な近さだけでは仕事への帰属を確定しない。
3. **意味の判断**: 閲覧・引用・推定・本人確認済みを区別する。回数、時間、成果を混同しない。
4. **出力と移行**: UI、MCP、コピー文、Markdownに同じ区分を渡し、旧データの誤分類も扱う。

## 証拠の区分と範囲

- **実画面**: この会話の前段で /Applications/Mull.app のホームを確認。「元のプロファイル」への30分提案、検索ページを含むプロジェクト一覧、関連が不明な引用を観測。関連が不明という観察だけで、個々の引用が本人の仕事と無関係だったとは断定しない。
- **実DB集計**: mode=ro接続。UTC `2026-09-09 17:18:47.709` までのrecording_eventsは71,445件、entityが「元のプロファイル」のものは12,955件。knowledge_entriesは調査時100件、そのうちprojectが同名のものは3件。knowledge本文の正誤は検証していない。分類の汚染が永続データにあることを確認した。
- **合成入力による再現**: 現行の分類ソースをcompileして5ケースを再現。傾向検出は実際のBehaviorPatternEngineをcompileし、DB・集計依存をstubにした単体再現。後者は実DB全経路の検証ではない。
- **ソース確認**: 再現未実施の知識抽出や属性推測は、発動条件付きのコード上のリスクとして扱う。
- **版の限界**: インストール版とローカルbuild内の実行ファイルのSHA256は異なる。実画面が現行ソースそのものとは保証しない。再現実験は現行ソースに対して行った。

## 1. 別の仕事が一つのプロジェクトにまとまる

**現行ソースで再現済み・確信度: 高。**

`BlockSegmentation.swift:55-65` はイベント間隔が180秒未満なら、別プロジェクトでも同じblockに吸収する。その後、代表アプリと観測回数最多のタイトルを選ぶ。`TimeBlockEngine.swift:380-405` はblock全体の時間を、その一つのprojectに割り当てる。

合成例: CodeでAlphaを10分、その後Betaを10分、1分間隔で観測する。結果は `Alpha — a.swift / key=alpha / seconds=1200` の1blockになった。Betaの作業が消え、Alpha20分に見える。

長い空白を挟んで別blockになればproject比較が働く。このため、典型的な「休憩せず次の仕事に移る」操作が問題になる。

**修正方向**: プロジェクト変更を観測区間の境界として保持する。画面で一つにまとめて見せる処理と、時間をどの作業へ加算するかを分離する。

根拠: [BlockSegmentation.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/BlockSegmentation.swift:55)、[TimeBlockEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/TimeBlockEngine.swift:380)。

## 2. ブラウザーのページ名・プロファイル名がプロジェクトになる

**ソース・合成再現・実DB集計で確認・確信度: 高。**

ブラウザーをproject候補から除く処理は存在するが、全経路に共通していない。

| 経路 | 現在の挙動 |
|---|---|
| `Entity.from(title, app:)` | ブラウザー等を除外する |
| `CurrentState` | 上記のapp-aware版を使用 |
| `RecordingService:955` | appを渡さない版でentityを保存 |
| `projectName` / `artifact(inTitle:)` | ブラウザー等を除外する |
| `normalizeTaskKey` → `projectSnapshots` | 同じ除外を共有しない |
| `Selection:120` / `ContextComposer:145` | 保存済みentityを優先して再利用 |

合成例の `Googleの検索ページ — Google` は `key=googleの検索ページ` になった。実DBには「元のプロファイル」のentityが12,955件ある。現行コード検索では既存entityの再分類・UPDATE処理を確認できなかった。

影響は表示だけではない。`Selection:122` はentityをプロジェクト指定時の必須条件にし、132は一致をランキングに使う。誤ったentityは、必要な記録を除外したり、別の記録を同じ作業としてまとめたりする原因になる。

**修正方向**: 表示名とは独立した種別・識別子・判断根拠・判定バージョンを保持する。入力、読み出し、既存データ移行を同時に設計する。ブラウザーをすべて捨てると、有用な調査資料まで失うため、ページとして保持し、プロジェクトとの関連は別に管理する。

根拠: [Entity.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/Entity.swift:17)、[RecordingService.swift](/Users/stanford/Documents/Work/Mull/Mull/Services/RecordingService.swift:955)、[Selection.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/Selection.swift:120)、[BlockSegmentation.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/BlockSegmentation.swift:350)。

## 3. コピーの出典が失われ、作業の引用として表示される

**現行ソースで再現済み・確信度: 高。**

block内のclipboardは文字列の配列として保持され、出典app、title、timestampとの結びつきが失われる。最後の文字列がblockのprojectの引用になる。

合成例: Alpha作業中にChromeへ移って別用途の文字列をコピーし、Alphaへ戻る。Alphaのblockの `clip` にその文字列が入った。ホームは引用符で表示し、MCPは `Last copied` として返す。コピーされた事実は正しくても、「この仕事を説明する引用」という関係は未確認である。

さらに、projectSnapshotsは今日から過去へ走査してfile/clipboardをappendし、最後の要素を採用する。そのため複数日の候補があれば、最古日側の情報が「Last file / Last copied」になり得る。この時系列問題はソース確認のみ。最終活動日は最大日時を取るため、新しい活動日と古い引用が並ぶ構造がある。

**修正方向**: 出典ID・日時・app・windowを引用に持たせ、関連未確認の引用はprojectカードから外す。「最新」は配列順ではなく日時で選ぶ。

根拠: [BlockSegmentation.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/BlockSegmentation.swift:588)、[TimeBlockEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/TimeBlockEngine.swift:373)、[HomeTab.swift](/Users/stanford/Documents/Work/Mull/Mull/Views/HomeTab.swift:826)、[MCPServer.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/MCPServer.swift:1063)。

## 4. 時間的な前後関係を「その仕事のため」と確定する

**現行ソースで2ケース再現済み・確信度: 高。**

### コピー後の移動

`clipboardFlow` はコピー文字列があること、次blockがartifactを持つこと、時間gapだけで成立する。貼り付けや内容一致は確認しない。しかしbasisはclaimで、tokenは `copied into it`。日別集計はその帰属を時間加算に使う。

合成例: ブラウザーで私用メモをコピーし、4分後にNotionのRoadmap Draftを開く。貼り付けの観測なしで、ブラウザー11分がRoadmapのための作業とされた。

### 前後が同じ資料

`sandwiched` はartifactのないblock群の内部gapを確認せず、両端だけを確認する。合成例では、同じ資料に挟まれた2つのブラウザーblockの間が8時間空いていても、両方をその資料に帰属させた。

内部gapを直しても、「資料→休憩動画→同じ資料」の場合、前後一致だけでは仕事への関連は分からない。ここは条件式の修正と、claim扱いの仕様の見直しの両方が必要。

**修正方向**: 「コピー後に文書を開いた」「同じ文書の間に閲覧した」という観測可能な表現にする。関連が未確認の時間を確定したプロジェクト時間へ加算しない。

根拠: [BlockAttribution.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/BlockAttribution.swift:115)、[TimeBlockEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/TimeBlockEngine.swift:124)。

## 5. 回数・時間・成果の意味が入れ替わる

**ソース確認、一部単体再現・確信度: 高。**

| 表示上の主張 | 実際の入力・計算 | 問題 |
|---|---|---|
| 7日間に3回開いた、各10分未満 | プロジェクトの日合計3件が各10分未満 | 訪問回数でも連続セッションでもない |
| その時間の○% | アプリ切替イベントの割合 | 滞在時間の割合ではない |
| 最も生産的な時間 | イベント数上位の時刻 | 成果を測っていない |
| 終わらせる量が減っている | アプリ切替数の増加 | 完了件数を測っていない |
| focused work / more output | 全blockの稼働時間の比較 | 集中の質や成果量とは異なる |

30分提案は固定値で、必要時間や未完了を確認していない。ただし問いの形式であり、単発の短時間閲覧だけでは出ない。短い日合計3件以上、長い日合計0件という発火条件がある。

検出器の単体再現では、日合計240秒×3日から `opened ... 3 times` と30分提案が出た。また時間別統計1件とChrome切替1件から、最も生産的な時間、30日分に基づく説明、100%の時間という説明が出た。後者は依存stubによる最小標本の単体反例であり、実DBでの発生頻度は測っていない。

**修正方向**: 真のセッション境界を導入するか、「3日とも合計10分未満」と測ったものをそのまま伝える。生産性・成果の主張を除き、記録件数、切替回数、観測された時間を単位付きで扱う。

根拠: [TimeBlockEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/TimeBlockEngine.swift:411)、[BehaviorPatternEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/BehaviorPatternEngine.swift:96)、[BehaviorPatternEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/BehaviorPatternEngine.swift:195)。

## 6. 引用が本人の決定・属性へ昇格する

**発動条件を含むソース確認・確信度: 高。本文の誤抽出の実発生は未測定。**

LLM抽出が失敗したときのKnowledgeExtractorのルール経路は、clipboard内の `because` / `prefer` / `にした` 等を判断として抽出する。本人の発言か、他人の引用か、未採用案かを確認しない。その日の全window titleの多数決でprojectを決め、候補をそこへ所属させる。

したがって、別の人が技術選定理由を書いた記事をコピーすると、自分の決定として、その日の別案件に所属して保存されるリスクがある。通常のLLM抽出にも、出力契約・KnowledgeEntryに根拠event ID、本人確認状態、抽出方式の保持がない。保存後はMCPで `Decision / Why / Rejected` として出る。

実DBで「元のプロファイル」所属のknowledgeが3件あったことは確認したが、それらのdecisionが誤りだったという検証ではない。

別経路では、clipboardの文字分布が「主な言語」「二言語」「コードを書いている」という本人属性へ変換され、ContextComposerのAI向けコピー文へ入る。コピーした文章は本人が書いたとは限らない。一方、現行me.md生成ではこのrule-based factsの書き込みを既に除去しているため、me.mdまで未修正とするのは不正確。

**修正方向**: 観測された引用、推定した判断、本人確認済みの決定を別状態として保存する。原イベントの参照を必須にし、出典や本人性が不明なものをDecisionへ昇格させない。本人属性をコピー内容から推測する出力は撤去するか、コピー内容の統計として明記する。

根拠: [KnowledgeExtractor.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/KnowledgeExtractor.swift:162)、[KnowledgeExtractor.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/KnowledgeExtractor.swift:216)、[MullEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Services/MullEngine.swift:300)、[FactExtractor.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/FactExtractor.swift:80)、[LiveContextGenerator.swift](/Users/stanford/Documents/Work/Mull/Mull/Services/LiveContextGenerator.swift:183)。

## 7. 推測の区分と訂正が、全出力を守っていない

**ソース確認・確信度: 高。**

BehaviorPatternには `.interpretation` と `autoSurfaceable=false` の仕組みがある。しかしホームは全パターンを取り込み、insight/action/evidenceを区分表示なしで出す。full.md生成も全パターンの上位5件をInsight/Action/Evidenceとして出し、epistemicClassを落とす。evidenceは原イベント参照ではなく、同じルールが生成する説明文字列である。

訂正機構も存在する。Curatorは人の編集を保護し、Selectionは訂正をランキングの補正に使う。ただしそれでentityやKnowledgeEntryが修正されるわけではない。knowledge取得は訂正索引を参照しない。

**修正方向**: UI単独の表示フィルタではなく、確定・推定・不明、出典、訂正状態を共通の出力契約にする。訂正した事実が保存値と派生出力のどこへ適用されるかを定め、再生成で復活しないことを検証する。

根拠: [HomeTab.swift](/Users/stanford/Documents/Work/Mull/Mull/Views/HomeTab.swift:656)、[MullEngine.swift](/Users/stanford/Documents/Work/Mull/Mull/Services/MullEngine.swift:994)、[Selection.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/Selection.swift:149)、[MCPServer.swift](/Users/stanford/Documents/Work/Mull/Mull/Core/MCPServer.swift:1078)。

## 反証・矛盾ログ

| 一見矛盾する情報 | 整理 |
|---|---|
| ブラウザー除外処理は既にある | 経路差。一部の分類経路だけに適用され、保存・projectSnapshots経路には共有されていない |
| 現在の未コミット変更で帰属を直している | 範囲差。5分未満のartifactをanchorにしない対策。今回の5つの分類反例は修正後ソースで再現 |
| interpretationは自動表示不可 | 出力経路差。フラグがあってもホーム/full.mdが参照していない |
| 傾向による誤通知もあるはず | 未確認として除外。朝の生産性通知は現行ProactiveEngineで撤去済み。誤った傾向が通知されたとは報告しない |
| me.mdの属性推測は既に消している | 正しい。残存しているのはContextComposer等の別経路 |
| 訂正は学習する設計 | 適用対象が違う。文書所有権・ランキング補正と、entity/knowledgeの値の修正は別 |
| 既存テストが通れば正しい | 一部テストはsandwiched/clipboardFlowをclaimとする仕様を正解としている。仕様自体の見直しが必要 |
| 前段のREADMEはdaily書き込みがno-opと説明 | 時系列差。現行MullEngineは書き込みを実装済み。今回の問題として数えない |

## 推奨する修正順序と受け入れ条件

### 第一段階: 根拠を超えた断定を止める

- 生産性・成果量の未計測主張を除去する。
- コピー後の移動、前後一致を確定帰属から候補へ下げる。
- 本人性不明の引用をDecisionや属性にしない。
- 全出力に確定/推定/不明を残す。確信度の数値は較正するまで作らない。

受け入れ条件: 貼り付けの観測なしに `copied into it` が出ない。切替回数が時間%にならない。他人の文章をコピーしても本人の決定と断定しない。UIで抑えた内容がMCP/full.mdで復活しない。

### 第二段階: 観測・分類・時系列を直す

- 別projectへ切り替えた区間を失わない。
- app/page/projectの種別と、引用の出典・日時を維持する。
- 日合計とセッションを分離する。
- entity判定を共通化し、最新候補を日時で選ぶ。

受け入れ条件: Alpha10分→Beta10分が各10分で残る。別用途のコピーがAlphaの引用にならない。複数日でも最新file/clipboardが選ばれる。同じ元記録に対する日報とproject一覧の時間帰属が整合する。

### 第三段階: 既存データと訂正を扱う

- 新しい分類器で再判定できるものを候補として作り、原記録を保持する。
- 本人確認済みの訂正を自動推定より優先する。
- 出典不明の古いknowledgeを一律に確定扱いしない。
- source event ID、判定バージョン、訂正状態から派生物を再生成できるようにする。

受け入れ条件: 新規記録だけでなく旧entityも検索・コピー出力で補正される。訂正後、再起動・再集約・MCP取得で誤りが復活しない。移行前後を比較でき、原データを失わない。

代替案として文字列ブラックリスト追加だけなら変更量は小さい。しかし未知のブラウザープロファイル、別言語、別アプリで再発し、引用・時間単位・本人性の問題を解決しない。LLMへの置き換えだけでも、既に失った出典は戻せない。短期の表示抑制と、上記のデータ構造の修正を段階的に行う方針を推奨する。

## 探索ログ・証拠台帳

research-protocol標準モードを、製品内部の調査に適用。ソース担当、伝播担当、反証担当で分担し統合した。外部市場・一般的AI性能の主張は対象外で、Web調査は行っていない。

| 探索系統 | 検索語・入口 | 当たった証拠 |
|---|---|---|
| 帰属 | projectSnapshots, normalizeTaskKey, artifact, servedBy, clipboardFlow, sandwiched | 実装、既存diff、BlockAttributionTests、合成反例 |
| 意味・単位 | shortSessions, avoidance, peakWaste, productivity, evidence | BehaviorPatternEngine、AnalyticsEngine、TimeBlockEngine、stub単体再現 |
| 伝播 | entity, backfill, reindex, epistemicClass, autoSurfaceable, full.md, Decision | RecordingService、Selection、ContextComposer、MullEngine、KnowledgeExtractor、読み取り専用DB集計 |
| 反証 | app-aware, interpretation, correction, Curator, fact/pref, Tests | 既存ガード、未コミット対策、me.md除去、通知撤去、テストの適用範囲 |

| 主張ID | 性質・用途 | 根拠 | 反例・限界 | 確信度 |
|---|---|---|---|---|
| 1 | 検証済み事実・修正根拠 | 現行分類ソース＋合成実行 | 長いgapなら分かれる。全ユーザー頻度未測定 | 高 |
| 2 | 検証済み事実・修正根拠 | 2分類経路＋DB集計 | 現在状態のapp-aware版にはガードあり | 高 |
| 3 | 検証済み事実・修正根拠 | 現行分類ソース＋合成実行 | 実画面の個別引用の無関係性は未確認。逆時系列はソースのみ | 高 |
| 4 | 検証済み事実・仕様見直し根拠 | 現行帰属ソース＋2合成実行 | 前後の作業が本当に関連する場合もあるが、観測だけでは確定不可 | 高 |
| 5 | 検証済み事実・修正根拠 | 検出器ソース＋依存stub単体実行 | E2E・実際の発生頻度は未測定 | 高 |
| 6 | 検証済みコード経路・リスク根拠 | 抽出器、モデル、MCP出力 | decision誤抽出の実データ正解付け未実施。ルール経路にはLLM失敗条件 | 高（経路）、未測定（頻度） |
| 7 | 検証済み事実・契約設計根拠 | UI/full.md出力、訂正参照 | 文書保護やme.mdの改善は既に存在 | 高 |

鮮度は全項目とも調査日・現在ワークツリー。各項目の適用条件は本文の再現条件に限定する。推奨設計は未実装の提案であり、品質改善効果を測定済みとはしない。

## 検証結果と残る不確実性

- 分類: 現行ソースをcompileする合成再現5ケース。再現資材を本ディレクトリに保存。
- 傾向: 現行検出器＋依存stubで2ケース。実DB・実集計器を通すE2Eではない。
- DB: 読み取り専用の集計のみ。生の個人記録は成果物へ保存していない。
- XCTest全体・実機の長時間記録・修正後の品質評価は実施していない。製品の修正自体が今回の対象外。

今回の因果関係を特定する範囲では、実装、既存対策/テスト、実画面/DB、合成再現を照合し、主要な反証を確認した。出力、既存ガード、テストを追加確認しても「断定の抑制→観測・分類→既存データ」の順序は変わらなかった。

未解決なのは、実際の作業との正解比較による発生率、知識本文の本人性、初期移行で自動修復できる割合、訂正UIの操作負担。これらは具体的な閾値や移行範囲を変えるが、今回再現した誤った断定を止める優先度は変えない。次の品質評価では、本人が先に正解を付けた複数案件・複数日の記録を使い、誤帰属率、引用の正しい関連付け、根拠のない断定件数、未分類に残す割合を別々に測る。
