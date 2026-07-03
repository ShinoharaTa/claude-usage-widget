# ClaudeUsageWidget

Claude Code のレートリミット（5h / 7d）を macOS メニューバー + オーバーレイウィジェットに表示する常駐アプリ。
リポジトリ: https://github.com/ShinoharaTa/claude-usage-widget (private)

## ビルド・実行

```sh
./build.sh                                # swiftc でビルド → ~/Applications/ClaudeUsageWidget.app へ配置（旧プロセスは pkill される）
open ~/Applications/ClaudeUsageWidget.app # 起動
```

- 依存は Xcode CLT の swiftc のみ。Xcode プロジェクトはない。ソースは `Sources/main.swift` 単一ファイル（top-level code なので main.swift のままにすること）
- アプリは Keychain にアクセスしない。再ビルドしても Keychain 許可ダイアログは出ない設計。

## アーキテクチャ

- `UsageFetcher` enum: `~/.cache/claude-usage-cache.json` を読み取るだけ。Keychain/API/OAuth 更新処理は持たない。
  statusline スクリプト（`~/.claude/statusline-command.sh`）も同じく読み取り専用。形式（`cached_at` エポック秒を付与した API レスポンス）を変えると表示側が壊れる
- `UsageView`: オーバーレイの 2 段バー描画（240x60、flipped 座標）
- `AppDelegate`: NSStatusItem（左クリック=ウィジェットトグル / 右クリック=詳細メニュー）、NSPanel（.floating、全 Space、ドラッグ可・位置は UserDefaults に永続化）、
  60 秒タイマー（キャッシュ再読込）、リセット時刻ごとの Timer 通知（リセット時刻のエポックをキーに重複排除）、SMAppService でログイン時起動

## 動作確認のポイント

- 起動確認: `pgrep -x ClaudeUsageWidget`
- キャッシュ確認: `jq -r '.cached_at' ~/.cache/claude-usage-cache.json`
- **cached_at は必ず整数で書くこと**: statusline スクリプトが bash の整数演算に使っており、
  小数を書くと statusline がシェルごと死んで何も表示されなくなる（2026-07-03 に実際に起きた。
  statusline 側にも `| floor` の防御を入れてあるが、フォーマットは整数を維持する）
- スクリーンショットでの UI 確認はターミナルの画面収録権限がないと `screencapture` が失敗する
