# ClaudeUsageWidget

Claude Code のレートリミット（5h / 7d）を macOS メニューバー + オーバーレイウィジェットに表示する常駐アプリ。
リポジトリ: https://github.com/ShinoharaTa/claude-usage-widget (private)

## ビルド・実行

```sh
./build.sh                                # swiftc でビルド → ~/Applications/ClaudeUsageWidget.app へ配置。自動起動が有効なら launchd 経由で起動し直す
~/Applications/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget --enable-login-item  # 自動起動を有効化して起動（初回のみ）
```

- 依存は Xcode CLT の swiftc のみ。Xcode プロジェクトはない。ソースは `Sources/main.swift` 単一ファイル（top-level code なので main.swift のままにすること）
- アプリは Keychain にアクセスしない。再ビルドしても Keychain 許可ダイアログは出ない設計。

## アーキテクチャ

- `UsageFetcher` enum: `~/.cache/claude-usage-cache*.json` を読み取るだけ。Keychain/API/OAuth 更新処理は持たない。
  statusline スクリプト（`~/.claude/statusline-command.sh`）も同じく読み取り専用。形式（`cached_at` エポック秒と `account` を付与した API レスポンス）を変えると表示側が壊れる
- **アカウントごとに 1 キャッシュ**。命名は Claude Code が Keychain アイテムを名前空間化する方式に合わせてある。
  デフォルト設定ディレクトリ（`CLAUDE_CONFIG_DIR` 未設定）は無印、それ以外は `-<sha256(パス)先頭8桁>`:
  `~/.claude` → `claude-usage-cache.json` / `~/.claude-work` → `claude-usage-cache-6b15588f.json`。
  同じ導出規則なので statusline は `$CLAUDE_CONFIG_DIR` だけから読むべきキャッシュを決められる（対応表を持たない）
- `fetch-usage.sh` が `account: {config_dir, email, label}` をキャッシュに書く。`label` は
  team seat なら組織名、そうでなければメールのローカル部（`asteno` / `takuma1201`）。
  表示側が毎回 ~110KB の `.claude.json` を読まずに済ませるため
- `UsageView`: オーバーレイのバー描画（幅 240、flipped 座標）。1 アカウントなら従来どおり
  ヘッダなしの 2 段・高さ 60。複数なら 1 アカウントにつきヘッダ + 2 段のブロックで、高さは
  `UsageView.height(for:)` が返す（`6 + N*68`）。増減時は `resizePanel()` が上辺を固定したまま伸縮させる
- `AppDelegate`: NSStatusItem（左クリック=ウィジェットトグル / 右クリック=詳細メニュー）、NSPanel（.floating、全 Space、ドラッグ可・位置は UserDefaults に永続化）、
  60 秒タイマー（キャッシュ再読込）、リセット時刻ごとの Timer 通知（リセット時刻のエポックをキーに重複排除）
- `LaunchAgent` enum: ログイン時起動と死活監視。`~/Library/LaunchAgents/com.shino3.claude-usage-widget.plist`
  （RunAtLoad + KeepAlive.SuccessfulExit=false）を書く/消すだけで、有効=plist がある。
  **SMAppService は使わない**: ad-hoc 署名のバンドルを build.sh が置き換えるため登録が残らず、
  2026-10-12 の再起動後にアプリが上がってこなかった。`--enable-login-item` / `--disable-login-item` /
  `--login-item-status` で CLI からも操作できる（`LoginItemCLI`。`--` 付き引数があれば UI を出さずに終了する）
- build.sh は旧プロセスを `launchctl bootout` → `pkill` で止めてから置き換える。KeepAlive のまま pkill だけすると、
  コピー中の古いバイナリを launchd が起動し直してしまう

## 動作確認のポイント

- 起動確認: `pgrep -x ClaudeUsageWidget`、launchd 側は `ClaudeUsageWidget --login-item-status`（enabled/loaded/pid）。
  起動しないときは `/tmp/claude-usage-widget.err`
- キャッシュ確認: `for f in ~/.cache/claude-usage-cache*.json; do jq -c '{account:.account.label, cached_at}' "$f"; done`
- ウィンドウ寸法の確認（画面収録権限が無くても使える）:
  `CGWindowListCopyWindowInfo` を叩く小さな swift スクリプトで `ClaudeUsageWidget` の bounds を見る
- **cached_at は必ず整数で書くこと**: statusline スクリプトが bash の整数演算に使っており、
  小数を書くと statusline がシェルごと死んで何も表示されなくなる（2026-07-03 に実際に起きた。
  statusline 側にも `| floor` の防御を入れてあるが、フォーマットは整数を維持する）
- スクリーンショットでの UI 確認はターミナルの画面収録権限がないと `screencapture` が失敗する
