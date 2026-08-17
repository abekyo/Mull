# WRITING: UI文言の書き方

> mull の画面と、mull が `~/mull` に書き出す markdown の文言についての規則です。
> 対象は英語と日本語の両方。判断が割れたときは [CLAUDE.md](CLAUDE.md) §0 に従属します。
>
> この文書は 2026-08-09 の指摘から起こしました。指摘はひとことで
> 「ポエムチックで何を言っているか分からない箇所が多々ある」でした。
> 原因は3つあり、どれも文才の問題ではなく規則の不在でした。

---

## 0. 判定基準

**読み手が実体を当てられない語は、詩情ではなく欠陥です。**

UI文言の読み手は、その画面で何かを決めようとしている人です。決めるのに要る情報が
比喩の下に隠れていたら、それは装飾ではなく障害物になります。文書の推敲では
「もっと良い言い方はないか」を探しますが、UI文言では「これで判断できるか」だけを見ます。

この基準は privacy 要件にも効きます（[SECURITY.md](SECURITY.md)）。Input Monitoring を
渡すかどうかを決める文が情緒的だと、書いてある保証まで情緒的に見えます。

---

## 1. 比喩を置かない

2026-08-09 に UI から削除した語と、その置き換えです。**同じ語を戻さないでください。**

| 使っていた語 | 実体 | いま使う語 |
|---|---|---|
| understudy / 代役 | LLM | AI |
| custodian / 保管者 | 何でもない（削除） | — |
| moments / 件（英語側） | DB のレコード | records |
| voice sample / 文体の見本 | 明日の下書きが参照する文章 | 文体を引き継ぐ |
| portrait / 人物像 | プロフィール画面 | このページ |
| listening / 聞いています | 記録中 | 記録中 |
| quiet page / 静かなページ | 記録が無い | まだ記録がありません |
| taken shape / 形になっていません | 表示するものが無い | まだ表示するものがありません |
| observed / 観測 | 記録から取った | 記録から |
| 窓 | ウィンドウ | ウィンドウ |
| 見立て | 要約 | 要約 |
| 材料がありません | データが足りない | データがありません |

判定のしかた: **その語を初見の人に見せて、指しているUI要素かデータを当てられるか。**
当てられないなら比喩です。`custodian` は当てられる対象がそもそも無く、削除しました。

コード内のコメントと LLM へのプロンプトは対象外です。`ReportWriter.swift` の
`You are the user's understudy` は残っています。読み手が人間ではないからです。

---

## 2. 日本語UIで二倍ダッシュ `——` を使わない

英語原文の em-dash をそのまま持ち込むと `——` が量産されます。2026-08-09 の実測で
日本語647件のうち63件。日本語UIとしては異常な密度で、「ポエムチック」の体感の大半は
これでした。

置き換えは4通りです。

| 型 | 例 |
|---|---|
| ステータス + 説明 | `記録中——mull が…` → `記録中: mull が…` |
| エラーコード + 理由 | `アクセス拒否（403）——このキーには…` → `アクセス拒否（403）: このキーには…` |
| 文末の補足 | `接続できません——サーバーは起動していますか？` → `接続できません。サーバーは起動していますか？` |
| 挟み込み `——X——` | `ほかの何か——MCP サーバー・Obsidian——が` → `ほかの何か（MCP サーバー・Obsidian など）が` |

単純置換で済まないものがあります。理由が後置されていると日本語では宙に浮くので、
語順ごと組み直します。

- `コピーしても移動しても、何で開いても構いません——ただのマークダウンです。`
  → `ただのマークダウンなので、コピーしても移動しても、何で開いても構いません。`
- `…件名と送信者だけを読み——本文は読みません——この Mac に保管します。`
  → `…件名と送信者だけを読み、この Mac に保管します。本文は読みません。`

**英語側の `—` は触りません。** 英文としては自然な句読点で、直すと Swift のリテラルと
xcstrings のキーの両方が動きます（§5）。この規則は日本語だけの話です。

---

## 3. ラベルを文にしない

ボタン・タブ・セクション見出し・ツールチップの見出し・Picker のラベルは、文ではなく
名詞句です。英語が2〜3語なら日本語も同じ長さで収まるはずで、収まらないときは
訳ではなく解釈が入っています。

| 場所 | 文になっていた | いま |
|---|---|---|
| provenance マーカー | あなたが編集できます | 編集可 |
| provenance マーカー | mull が書いたもの · 訂正できます | mull が書いた · 訂正可 |
| ダイアログのボタン | それでも接続 | このまま接続 |
| Picker のラベル | この時間内に戻ったら同じ作業とみなす | 同じ作業とみなす間隔 |
| セクション見出し | 今日を、あなたの言葉で | 今日のレポート |
| 傾向ラベル | 手つかずの期間 | 放置期間 |
| エラー | それを保存できませんでした | 保存できませんでした |
| カウント表示 | 今日は1件の記録を保存しました。 | 今日の記録: 1件 |

Picker のラベルに文を入れると、コントロールの左側が文の長さぶん押し出されて
レイアウトが崩れます。文になっているかどうかは見た目にも出ます。

---

## 3.5 要らない行は消す

言い換えでは直らないものがあります。**その行を読んで決められることが1つも無いなら、
消すのが正解です。** 2026-08-09 に消したもの:

| 消したもの | なぜ |
|---|---|
| `コピーしても移動しても、何で開いても構いません。ただのマークダウンです。` | markdown ビューアで開いている本人に、markdown だと伝えていた |
| dossier 末尾の `この記録はあなたのものです。mull は…どこにも送りません。` | すぐ上の行が同じことを言っていた |
| now.md / full.md の front matter `layer` `refresh` | `mull://start` が同じことを AI に伝えている |
| me.md の front matter `sources` | 本文の各ブロックが provenance を持っている |
| proactive.md の front matter `scope` `refresh` | `scope` はタイトルの言い換えだった |
| 中断設定の `離れていた長さはブロックに出ます。` | 設定を決めるのに要らない |

vault の front matter で `generator` だけは消せません。`MarkdownDoc.isGeneratedByMull` が
これで mull 自身の書いたものを見分け、クリップボード経由の再取り込みを止めています。
ファイルには残し、`MarkdownView` の表示側で伏せています。

同じ理由で、front matter に説明文を足すときは止まってください。あそこは
`updated` のような機械可読の値の場所で、散文の場所ではありません。

---

## 4. 情緒に寄せない

事実を述べ、次にできることを言う。それ以上は書きません。

| 書かない | 書く |
|---|---|
| あなたの編集は %@ に無事です。 | 編集内容は %@ に保存してあります。 |
| 今日のレポートの未保存の編集を預かってあります。 | 今日のレポートに未保存の編集が残っています。 |
| ただのファイルのまま、あなたのものです。 | ただのファイルのまま、あなたのものです。（可。所有の明示は事実） |
| この Mac の中だけにあります。送信しません。あなたのものです。 | この Mac の中だけにあり、外部へは送信されません。 |
| 保管者は預かるだけで、所有はしません。 | （削除） |

体言止めの三連（「Held on this Mac. Never sent. Yours alone.」型）は、英語では
リズムになりますが日本語では途切れた断片に読めます。1文にします。

---

## 5. 直すときに踏む地雷

### 5.1 英語リテラルが xcstrings のキーです

SwiftUI の `Text("…")` と `String(localized: "…")` は、英語のリテラルがそのまま
`Localizable.xcstrings` のキーになります。

- **日本語だけ直す**: キーは動かない。Swift も無変更。差分が小さい
- **英語も直す**: Swift のリテラルと xcstrings のキーを同時に改名する必要がある

英語が比喩や誤りを含むとき（§1）だけ後者を選びます。日本語の読みやすさのためだけに
英語を動かさないでください。

### 5.2 `~/mull` に書き出す文言は xcstrings にありません

`VaultText.t(en, ja)` と `isJapanese ? ja : en` で書かれた文字列は Swift 側にあり、
翻訳ファイルを直しても変わりません。ここにあります。

`Curator.swift` / `ContextComposer.swift` / `RuleBook.swift` / `ReportWriter.swift` /
`LiveContextGenerator.swift` / `ProactiveLoop.swift` / `CorrectionCard.swift`

me.md・now.md・full.md のヘッダー、proactive.md、訂正カードの文面がこれです。
UI文言を直したのに直っていない、という報告が来たらまずここを見ます。

### 5.3 未翻訳が「ポエム」に混ざります

「何を言っているか分からない」の一部は比喩ではなく、日本語UIに英語がそのまま
出ていたものでした。2026-08-09 に8箇所見つかっています。原因は2つです。

- `Text("…")` のリテラルが xcstrings に未登録（6件）
- `String(localized:)` を通していない生の `String`（2件）

うち1件は、翻訳済み断片と英語の尻尾を連結していました。

```swift
let threads = mainActivities == 1 ? String(localized: "One main thread") : …
return "\(threads) today, \(span) of activity."   // ← ここが英語のまま
```

日本語では「主な流れ 1本 today, 2h 30m of activity.」と表示されていました。
**断片を訳して連結しないでください。** 1文まるごとを `String(localized:)` に入れ、
複数形は文ごとに分けます。

### 5.4 `+` で繋いだ瞬間、翻訳されなくなります

`Text` には2つのイニシャライザがあります。リテラルを渡すと `LocalizedStringKey` を取る
ほうが選ばれ、`String` 式を渡すと素通しのほうが選ばれます。**`+` を1つ書くだけで後者に
落ちます。** 型は通り、警告も出ず、xcstrings にキーが現れないだけです。

```swift
Text("No AI provider. Questions like \"what did I do today?\" are answered "
     + "from your records anyway.")            // ← 英語のまま出る
Text("Runs as: " + parts.joined(separator: " "))   // ← 同じ
```

行を折りたたみたいだけなら、1つのリテラルにします。値を差し込みたいなら文字列補間
（`Text("Runs as: \(joined)")`）にします。補間ならキーは `Runs as: %@` になり、翻訳が効きます。

`String` を引数に取る自前のヘルパー（`moreButton(_ title: String)` など）も同じです。
呼び出し側で `String(localized:)` を通してください。

### 5.5 キーに `%1$@` を書かない（2026-08-18 追記）

Swift が引く**キー**は常に非位置指定です。`"\(a) · \(b) recorded"` が探すのは
`%@ · %@ recorded` であって `%1$@ · %2$@ recorded` ではありません。引数が何個でも同じで、
`Text` の `LocalizedStringKey` と `String(localized:)` の両方で確認しました。

xcstrings に位置指定でキーを書くと、翻訳は載っているのに永久に引かれません。**画面は英語のまま、
カタログは完成して見える**という、いちばん気づけない壊れ方をします。2026-08-18 に10件見つかりました
（カレンダーの日別ツールチップ、中断の表示、検索の絞り込み件数、全削除の確認文など）。

**値のほうは位置指定で構いません。** 日本語で語順を入れ替えるときは値に `%2$lld件中 %1$lld件` と
書けば効きます。キーと値は別物です。

### 5.5.1 コードが読んでいる文字列を訳さない（2026-08-18 追記）

`LLMFailure.explain` は、`LLMClient` が投げたメッセージの英単語を `contains` で見て
「キー切れ」「レート制限」「オフライン」を仕分けていました。この英語を訳した瞬間、
日本語では10個の判定を全部すり抜けて、いちばん役に立たない最後の1文（「答えられませんでした」）
だけが出るようになります。**警告もテスト失敗も出ません。**

読み手が人間ではない文字列（front matter のキー、`MarkdownDoc.generatorStamp`、provenance
マーカー、MCP のツール説明）は元から対象外です。問題は、人間も読むが**コードも読んでいる**
文字列のほうで、これは訳す前に分類を型に移します。`LLMFailure.Kind` がその形です。

### 5.6 引数が無い文字列の `%` は `%%` にしない（2026-08-18 追記）

補間が1つでもある文字列は書式文字列になるので、リテラルの `%` はキーの中で `%%` になります
（`"\(n)% named"` → `%lld%% named`）。補間が1つも無ければ書式文字列ではないので、`%` は `%` のままです
（`"about 3% of what mull captured"` → そのまま）。

スクリプトでカタログを編集するときにここを取り違えると、キーが1文字ずれて引かれなくなります。

---

## 6. 検査

`Mull/Resources/Localizable.xcstrings` は Xcode の JSON で、
`json.dumps(doc, ensure_ascii=False, indent=2, sort_keys=True) + "\n"` で
バイト同一に往復します。スクリプトで安全に編集できます。

書き換えは **English キーで指定してください。** 日本語の値を検索キーにすると、
あとから再翻訳が入ったときに当たらなくなります。

コミット前の3つの確認:

```bash
# 1. 日本語値にダッシュが残っていないか
python3 -c "
import json
d=json.load(open('Mull/Resources/Localizable.xcstrings'))['strings']
for k,v in d.items():
    u=v.get('localizations',{}).get('ja',{}).get('stringUnit')
    if u and any(c in u['value'] for c in '—–―‒−'): print(k[:70])
"

# 2. Swift 側の日本語リテラルにダッシュが残っていないか
grep -rn --include="*.swift" -P '"[^"]*[\x{3040}-\x{30ff}\x{4e00}-\x{9fff}][^"]*[—–―][^"]*"' Mull/

# 3. xcstrings に登録されていない画面文字列が無いか
python3 -c "
import json,re,glob
keys=set(json.load(open('Mull/Resources/Localizable.xcstrings'))['strings'])
lit=r'\"((?:[^\"\\\\]|\\\\.)*)\"'
apis=r'(?:Text|Toggle|Button|Label|Picker|Section|Stepper|TextField|SecureField|Menu|Link|LabeledContent|confirmationDialog|alert|navigationTitle)'
pats=[re.compile(apis+r'\(\s*'+lit),
      re.compile(r'String\(localized:\s*'+lit),
      re.compile(r'\.(?:help|accessibilityLabel|accessibilityValue|accessibilityHint)\(\s*'+lit),
      re.compile(r'(?:one|other):\s*'+lit)]
for f in sorted(glob.glob('Mull/Views/**/*.swift',recursive=True)):
    for i,line in enumerate(open(f),1):
        if line.strip().startswith('//'): continue
        for p in pats:
            for m in p.finditer(line):
                s=m.group(1)
                if '\\\\(' in s or len(s)<=2: continue
                k=s.replace('\\\\n','\n').replace('\\\\\"','\"')
                if k not in keys: print(f'{f}:{i} {k[:60]!r}')
"

# 4. Text() の中で文字列を + で繋いでいないか（§5.4）
grep -rn --include="*.swift" -E 'Text\("[^"]*"\s*\+' Mull/Views/

# 5. キーに位置指定子が混ざっていないか（§5.5）。テストが同じことを見ています
python3 -c "
import json
d=json.load(open('Mull/Resources/Localizable.xcstrings'))['strings']
import re
for k in d:
    if re.search(r'%\d+\\\$', k): print(repr(k[:70]))
"
```

3 は `Text(` だけを見ていた時期があり、`Toggle` / `Picker` / `.help` に入った11件を
取りこぼしました。2026-08-18 に `String(localized:)` と `counted(one:other:)` も足しています。
API を1つ足したら、この正規表現にも足してください。補間を含む行（`\(…)`）は飛ばすので、
そこは目で見るしかありません。
4 はコメントと `"+"` を含むリテラルを拾います。目視で外してください。

**3 と 5 はテストにもなっています。** `VaultLocalizationTests` の
`testEveryEnglishStringHasAJapaneseOne`（訳の抜け）と
`testNoKeyUsesAPositionalSpecifier`（§5.5 の死んだキー）が、ビルドされた `.lproj` の側から
同じことを見ます。上のスクリプトが見るのはソース側で、テストが見るのは成果物側です。
xcstrings に登録し忘れた文字列はテストでは落ちないので、両方要ります。

2 の grep は doc comment も拾います。実際のウィンドウタイトルを例示している
コメント（`「Mdファイル編集時のサイドバー位置ずれ問題」 — Mull`）は正しい姿なので、
そのままにしてください。

---

## 7. この文書に無いこと

散文（README・DIRECTION・本書自身）の書き方は別です。em-dash を使わない点だけ
共通しますが、太字の頻度、冒頭の作り方、専門語の導入順といった規則は文書側の話で、
UI文言には効きません。

*2026-08-09 起草。*
