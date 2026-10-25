# Proofdeck — 要件・開発仕様書

別のアプリ（主に Claude）が書き換えるたびに描き直す、macOS 用の `.pptx` ビューア。
資料を AI に作らせ、見て、フィードバックし、作り直させる流れの「見る」部分を受け持つ。

- バンドル ID: `com.mitsuba.proofdeck`（Quick Look 拡張 `com.mitsuba.proofdeck.preview`、MCP サーバー `com.mitsuba.proofdeck.mcp`）
- 対象 OS: macOS 14.0+
- 置き場所: `~/Library/Application Support/Proofdeck/`（メモ・制御ソケット）、`$TMPDIR/Proofdeck/`（版ごとの作業コピー）

---

## 1. 要件

### 1.1 機能要件

| # | 要件 | 実現方法 |
|---|------|----------|
| F1 | 別アプリが保存したら、約 1 秒で描き直す | `stat` を 0.25 秒ごと＋親フォルダの kqueue（`FileWatcher`） |
| F2 | 上書き保存とアトミック置換（一時ファイル → rename）の両方を拾う | パスに対して inode・サイズ・mtime・ctime の組を比べる |
| F3 | 書き込み途中のファイルを読まない | 同じシグネチャが 2 回続き、かつ ZIP 末尾に End of Central Directory があるときだけ通知 |
| F4 | 描き直しても見ていたスライドに留まる。消えていたら最後のスライド | 版を差し替える前に表示中の番号を JS 側に渡す（`ppv.load(url, slideIndex)`） |
| F5 | 描き直しでちらつかない | 新しい版を裏の `ppv-host` で描き終えてから差し替える |
| F6 | 左に番号つきサムネイル、右に 1 枚表示、下に発表者ノート | `SlideListController` / `WebSlideView` / `notesSlide*.xml` を直接読む |
| F7 | 非表示スライドが分かる | `<p:sld show="0">` を読み、サムネイルを薄く・番号に打ち消し線 |
| F8 | 直前の更新で変わったスライドに印を付ける | スライドパーツと rels の CRC による指紋（挿入・削除で番号がずれても拾う） |
| F9 | 見ているスライドの前の版と今の版を切り替える（⌘B） | 前の版の作業コピーを残し、別の `WebSlideView` に描いて重ねる |
| F10 | ノートだけの変更では描き直さない | `Deck.changes(since:)` が `.none` を返したらノートだけ更新 |
| F11 | スライドごとのメモ（フィードバックの下書き）と一括コピー（⌥⌘C） | `MemoStore`（`memos.json`）。「スライド 12「見出し」: …」の形にまとめる |
| F12 | 本文とノートの検索（⌘F / ⌘G / ⇧⌘G） | `Deck.searchableText(at:)` |
| F13 | スライドを画像としてコピー（⇧⌘C） | 裏の表示を 1920pt 幅に広げて撮影し、PNG と TIFF でクリップボードへ |
| F14 | PDF と PNG への書き出し（非表示スライドは除く） | 裏の表示で 1 枚ずつ撮影。PDF は 2560px の JPEG、PNG は 3840px |
| F15 | スライドショー（⇧⌘↩）。ショー中の書き換えにも追従 | `SlideShowController`。元のウインドウはそのまま、別の全画面ウインドウに出す |
| F16 | ウインドウの位置・大きさ・見ていたスライドをファイルごとに覚える | `WindowMemory`（UserDefaults） |
| F17 | 終了時に開いていたファイルを次の起動で開き直す | `WindowMemory.openFiles` |
| F18 | Claude から操作できる（MCP） | 同梱の `proofdeck-mcp` が stdio で MCP を話し、Unix ソケットでアプリに取り次ぐ |
| F19 | Claude の書き込み中は描き直さず、終わってから 1 回だけ描く | `set_generating`。バナーを出し、タイムアウト（最短 10 秒）で自動解除 |
| F20 | アプリのメニューから Claude Code に MCP を登録 | `ClaudeSetup` が `claude mcp add proofdeck --scope user -- …` を実行 |
| F21 | Finder の Quick Look でも同じ描画 | `ProofdeckPreview.appex`（サンドボックス）。アプリ本体と同じ JS ページを同梱 |
| F22 | 描画の不具合を報告しやすくする | 「このスライドだけを pptx で書き出す」（他のスライドの本文・ノート・専用の画像を除く） |
| F23 | 旧名（PowerPointViewer）の設定とメモを引き継ぐ | `LegacyMigration` が初回起動で一度だけ |

### 1.2 非機能要件

- **通信しない**: 描画ページは `ppv://` の専用スキームで配り、http/https は WebKit の段階で止める。ライブラリが取りに行く Google Fonts も `fetch` を差し替えて断る
- **外部ソフト不要**: PowerPoint も LibreOffice も使わない。描画は WKWebView 内の JavaScript で完結
- **裏にいても止まらない**: 監視中は `beginActivity` で App Nap を止める（タイマーが間引かれると検知が止まるため）
- **固まらない**: 守られたフォルダ（デスクトップなど）の初回は macOS が許可を待たせるので、親フォルダを開くのは監視用の列で行う
- **メモリを増やし続けない**: 版を読み込むたびにライブラリの描画キャッシュを捨てる（`releasePptxRenderCaches`）。サムネイル用の表示は暇になったら破棄する
- **制御ソケットは本人だけ**: `control.sock` は 0600。ネットワークでは何も待ち受けない

### 1.3 スコープ外（現状の既知の限界）

- PowerPoint と画素単位では一致しない。折り返しは CoreText の計測どおりなので、ぎりぎりのタイトルは折り返しが変わることがある
- アニメーションと画面切り替えは出ない
- 編集はしない（ビューア）
- Quick Look 拡張は同梱・登録するが、`.pptx` の既定のアプリが PowerPoint の間は macOS が標準の Office プレビューを使い続ける
- 配布ビルドは ad-hoc 署名で公証していない

---

## 2. アーキテクチャ

```
別のアプリが保存
   │
FileWatcher ── stat 0.25s + kqueue ──▶ 変化（シグネチャ 2 回一致 & ZIP 完了）
   │
ViewerWindowController.fileChanged
   │  世代番号を進め、前の処理を取り消す
   ▼
process(generation:)
   1. $TMPDIR/Proofdeck/<世代>/deck.pptx に複製（以後は元のファイルを読まない）
   2. Deck を作り、前の版と比べる（none / slides / structural）
   3. WebSlideView.load → JS が裏で描いて差し替え
   4. 変わったスライドの印、前の版の保存、ステータス表示
   5. サムネイル（見ているスライドの近くから、変わった分だけ）
```

### 2.1 ファイル監視（FileWatcher）

- シグネチャ = inode・サイズ・mtime・ctime。前回通知した値と同じなら何もしない
- 新しい値は一度 `pending` に置き、次の確認でも同じで、かつ ZIP 末尾 66KB 以内に `PK\x05\x06` があれば通知
- 親フォルダの `.write/.rename/.delete` を受けたら即座に確認し、0.15 秒後にもう一度確認する（置換直後の書き込みが落ち着くのを待つ）

### 2.2 版の管理と差分（Deck / ZipArchive）

- `ZipArchive` は中央ディレクトリだけを読む最小実装。エントリの CRC とサイズで比べられるので、展開せずに差分が取れる
- `Deck.changes(since:)`:
  - スライドの並び（`presentation.xml` の `sldId` 順）が違えば `structural`
  - `docProps/`・`[Content_Types].xml`・`ppt/notesSlides/`・新しく足された `ppt/media/` は無視
  - `ppt/slides/slideN.xml` とその rels だけが変わったら `slides([…])`
  - それ以外（レイアウト・マスター・テーマ・既存画像）が変われば `structural`
- 変わったスライドの印は、パーツ名ではなく中身の指紋（スライドと rels の CRC・サイズ）で比べる。挿入・削除で番号がずれても、中身が同じスライドには印を付けない
- 作業コピーは表示中・前の版（⌘B 用）の 2 世代だけを残し、他は捨てる

### 2.3 描画（WebSlideView + web/）

- 描画は [pptx-vanilla-viewer](https://github.com/ChristopherVR/ooxml)（Apache-2.0、ooxml-core / ooxml-ui の上に作られている）。`web/src/main.js` がこれを描画だけに使う薄い層で、esbuild で 1 本にまとめて `Resources/web/` に出す
- Swift → JS は `window.ppv.*`（`load` / `goTo` / `layoutIssues` など）、JS → Swift は `webkit.messageHandlers.ppv`（`ready` / `slide` / `error` / `log`）
- `PPVSchemeHandler` が `ppv://app/…` でページを、`ppv://app/__deck/<token>.pptx` で資料のバイト列を返す（同じオリジンにして CORS を避ける）
- ページ（約 12MB）は初めて使うときに読み込む。撮影用・前の版用の表示が、起動時に主の表示の足を引っ張らないように
- ライブラリへの手直しは `web/patches/patches.mjs` にあり、ビルドのたびに当てる（何度当てても同じ結果）。文字色のアルファ、ぶら下げ句読点（WebKit で読点が消える）、pptxgenjs が書く重複した `a:pPr`、星形 5 の調整値。上流に還す前提

### 2.4 サムネイルと撮影

- 主の表示とは別に、見えない `WebSlideView`（480×270）を持ち、同じ版を描いて 1 枚ずつ撮る
- 撮る順は見ているスライドに近い順。部分的な変更なら変わったスライドだけ
- コピー・書き出し・`render_slide`・`check_layout` も同じ裏の表示を一時的に広げて使う。MCP からの頼みはサムネイルより先に処理する（優先キュー）

### 2.5 MCP（proofdeck-mcp + ControlServer）

- `proofdeck-mcp` は `Contents/MacOS/` に同梱する CLI。Claude Code とは stdio の JSON-RPC 2.0（1 行 1 件）で話す
- アプリとは `~/Library/Application Support/Proofdeck/control.sock`（0600）で 1 行 1 JSON。アプリが起動していなければ `open -g … --args --background` で裏で起動し、最大 10 秒待つ
- `--background` で起動されたアプリは前に出ず、ファイル選択画面も出さない
- 道具: `list_open_decks` / `open_deck` / `get_current_slide` / `get_slides` / `render_slide` / `check_layout` / `get_changes` / `get_memos` / `resolve_memo` / `goto_slide` / `set_generating`
- 資料の指定が無ければ、最後に前に出ていたウインドウを対象にする
- `check_layout` は描画済みの DOM を測る: 枠からはみ出した文字、スライド外の文字、文字同士の重なり（インチ単位、許容 1.5px）

### 2.6 Quick Look 拡張

- `ProofdeckPreview.appex` はサンドボックス必須（Quick Look はサンドボックスでない拡張を読み込まない）。WebKit の部品が動くのに `network.client` が要るが、外部への読み込みはページ側と WebKit の規則で止めている
- `WebSlideView.swift` と `Resources/web` をアプリ本体と共有する

---

## 3. モジュール構成

```
Sources/Proofdeck/
  main.swift                   AppDelegate、メニュー、MCP からの頼みの振り分け、起動時の復元
  ViewerWindowController.swift 1 ファイル 1 ウインドウ。読み込み・差分・サムネイル・書き出し・前の版・検索・メモ・MCP 応答
  WebSlideView.swift           WKWebView のラッパーと ppv:// スキーム
  FileWatcher.swift            ファイル監視
  Deck.swift                   スライド構成・見出し・本文・ノート・差分・1 枚だけの書き出し
  Zip.swift                    ZIP の中央ディレクトリの読み書き、CRC32
  SlideList.swift              左のサムネイル一覧
  SlideShow.swift              スライドショー
  ControlServer.swift          Unix ソケットの窓口
  MemoStore.swift              メモと「済」の印
  WindowMemory.swift           ウインドウ位置・見ていたスライド・開いていたファイル
  ClaudeSetup.swift            Claude Code への MCP 登録
  HelpWindow.swift / AboutCredits.swift / AppIconImage.swift
  LegacyMigration.swift        旧名からの引き継ぎ
Sources/QuickLookPreview/      Quick Look 拡張
Sources/proofdeck-mcp/         MCP サーバー
web/                           描画ページ（src/、patches/、build.mjs）
project.yml                    XcodeGen の定義（.xcodeproj はここから作る。コミットしない）
Package.swift                  `swift build` での手早い動作確認用（アプリ本体と MCP のみ）
```

---

## 4. ビルド・開発

```bash
./build.sh install    # 描画ページ → プロジェクト生成 → Release ビルド → ~/Applications へ
scripts/ci.sh         # CI と同じ確認（Release ビルド、同梱物と署名の確認）
```

- 必要なもの: Xcode、Node.js、XcodeGen（`scripts/bootstrap.sh` が無ければ入れる）
- `Proofdeck.xcodeproj` と `Resources/web/` は生成物でコミットしない。ソースを足したら `scripts/bootstrap.sh`
- `.app` は `.build/xcode/` に置く。見える場所に置くと Spotlight に `~/Applications` のものと二つ並ぶ
- **署名**: `scripts/bootstrap.sh` がキーチェーンの最初の Apple Development 証明書からチーム ID（証明書の OU）を取り、`DEVELOPMENT_TEAM` と `CODE_SIGN_IDENTITY` を埋めて XcodeGen に渡す。`DEVELOPMENT_TEAM=…` で上書きできる。証明書が無ければ ad-hoc（`-`）
  - ローカルで Apple Development 署名にするのは、ad-hoc だとビルドのたびに別のアプリと見なされ、デスクトップなどへのアクセス許可を求め直されるため
  - 名前の括弧内の ID はチーム ID ではない。それで署名すると失敗する
- 動作確認用の環境変数（`PPV_OPEN=about|help` と `PPV_SNAPSHOT`、`PPV_EVAL_FILE`、`PPV_COPY`、`PPV_CLAUDE_PROBE`）は、画面収録の権限なしに描画結果を PNG で確かめるためのもの

## 4.1 CI とリリース

開発は Azure DevOps（`origin`）、公開は GitHub（`github`）のミラー。

| | |
| --- | --- |
| `.github/workflows/ci.yml` | main への push と PR で `scripts/ci.sh`（runner に証明書が無いので ad-hoc） |
| `.github/workflows/release.yml` | `v*` タグで Release ビルド → `Proofdeck-vX.Y.Z.zip` を GitHub Releases に出す |
| `scripts/mirror-to-github.sh [vX.Y.Z]` | origin より遅れていないことを確かめて main とタグを GitHub へ。タグを渡すとリリースが走る |

- リリースは xcodebuild 自身に ad-hoc で署名させる（`CODE_SIGN_IDENTITY=-`）。署名なしで作って後から `codesign --sign -` すると、Quick Look 拡張のサンドボックスのエンタイトルメントが落ちる
- バージョンはタグから（`MARKETING_VERSION="${GITHUB_REF_NAME#v}"`）
- zip は `ditto -c -k --sequesterRsrc --keepParent`（バンドルのシンボリックリンクと拡張属性を保つ）
- 公証していないので、初回起動は「システム設定 → プライバシーとセキュリティ → このまま開く」

---

## 5. 検証手順（主要シナリオ）

| シナリオ | 期待 |
|---|---|
| 開いている資料を別アプリで上書き保存 | 約 1 秒で描き直し、同じスライドのまま。変わったスライドに印 |
| 一時ファイルに書いて rename で置き換え | 同上 |
| 大きな資料を書き込み途中 | 書き終わるまで読まない（「読み込みに失敗」も出ない） |
| スライドを途中に 1 枚挿入 | 挿入した 1 枚だけに印。後ろのスライドには付かない |
| 見ている 12 枚目を含む後半を削除 | 最後のスライドを表示 |
| ノートだけ変更 | 描き直さず、ノート欄だけ更新 |
| ⌘B | 見ているスライドの前の版と今の版が切り替わる |
| `set_generating on` の間に 3 回保存 → `off` | 描き直しは最後に 1 回だけ |
| アプリを終了した状態で MCP から `get_current_slide` | アプリが裏で起動し、前に出ずに応答 |
| デスクトップの資料を初めて開く | 許可のダイアログに答えるまで画面が固まらない |
| `scripts/ci.sh` | `✓ all checks passed` |
| リリースの zip を展開して起動 | 「このまま開く」の後に起動し、MCP 登録・Quick Look 拡張の登録ができる |

---

## 6. 今後の候補

- 単体テスト（`Deck.changes`、`ZipArchive`、`FileWatcher` の完了判定は純粋に試せる）
- `proofdeck-mcp` のバージョン文字列をアプリのバージョンと揃える（今は `main.swift` に直書き）
- 描画ライブラリへの手直しを上流に還し、`patches.mjs` を減らす
- Developer ID での署名と公証
