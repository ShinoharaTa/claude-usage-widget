# ClaudeUsageWidget

Claude Code のレートリミット（5h / 7d）を macOS メニューバー + オーバーレイウィジェットに表示する常駐アプリ。
リポジトリ: https://github.com/ShinoharaTa/claude-usage-widget (private)

## ビルド・実行

```sh
./build.sh                                # swiftc でビルド → ~/Applications/ClaudeUsageWidget.app へ配置（旧プロセスは pkill される）
open ~/Applications/ClaudeUsageWidget.app # 起動
```

- 依存は Xcode CLT の swiftc のみ。Xcode プロジェクトはない。ソースは `Sources/main.swift` 単一ファイル（top-level code なので main.swift のままにすること）
- ad-hoc 署名のため、**再ビルドするたびにキーチェーンの許可ダイアログが再度出る**（署名の CDHash が変わるため）。「常に許可」を選び直す必要がある

## アーキテクチャ

- `Keychain` enum: Security framework で `Claude Code-credentials`（Claude Code 本体と共有）を読み書き。
  アクセストークン失効時は refreshToken で `https://console.anthropic.com/v1/oauth/token`
  （client_id は Claude Code CLI の公開クライアント ID）から再発行し、**ローテーションされたトークンを必ず Keychain に書き戻す**
  （書き戻さないと Claude Code 本体のログインが壊れる）。401 時は Claude Code 側が先に更新したケースを想定して Keychain 再読込→リトライ
- `UsageFetcher` enum: `https://api.anthropic.com/api/oauth/usage` を叩き、`~/.cache/claude-usage-cache.json` に TTL 300 秒でキャッシュ。
  **このキャッシュは statusline スクリプト（`~/.claude/statusline-command.sh`）と共有**しており、形式（`cached_at` エポック秒を付与した API レスポンス）を変えると statusline 側が壊れる
- `UsageView`: オーバーレイの 2 段バー描画（240x60、flipped 座標）
- `AppDelegate`: NSStatusItem（左クリック=ウィジェットトグル / 右クリック=詳細メニュー）、NSPanel（.floating、全 Space、ドラッグ可・位置は UserDefaults に永続化）、
  60 秒タイマー（描画・リセット検出）、リセット通過時の UNUserNotificationCenter 通知（リセット時刻のエポックをキーに重複排除）、SMAppService でログイン時起動

## 動作確認のポイント

- 起動確認: `pgrep -x ClaudeUsageWidget`
- API アクセス確認: `jq -r '.cached_at' ~/.cache/claude-usage-cache.json` が更新されるか（5 分間隔）。
  小数点付き cached_at = このアプリが書いた、整数 = statusline が書いた
- スクリーンショットでの UI 確認はターミナルの画面収録権限がないと `screencapture` が失敗する
