# ClaudeUsageWidget

Claude Code のレートリミット（5時間 / 7日間）を Mac のメニューバーとオーバーレイウィジェットに表示する常駐アプリ。

## 表示

- **メニューバー**: `5h 13%  7d 4%` を常時表示。50%以上でオレンジ、80%以上で赤。ホバーでリセット時刻のツールチップ。
- **ウィジェット**: 画面上部に 5h / 7d の2段バーをオーバーレイ表示（半透明・全Space表示・ドラッグで移動可、位置は記憶される）。

## 操作

- メニューバー項目を**左クリック** → ウィジェットの表示/非表示をトグル
- **右クリック**（または ⌃クリック）→ 詳細メニュー
  - 使用率・リセット時刻・リセットまでの残り時間
  - ウィジェット表示切り替え / キャッシュ再読込
  - ログイン時に自動起動（トグル）
  - 終了

## 通知

5時間 / 7日間リミットのリセット時刻にタイマーで macOS の通知を送る。
初回起動時に通知の許可ダイアログが出るので許可すること。同じリセットに対して重複通知はしない。

## データソースとトークン管理

このアプリは Keychain にアクセスしない。`~/.cache/claude-usage-cache.json`
に保存済みの使用量キャッシュだけを読む。Claude Code の statusline
(`~/.claude/statusline-command.sh`) も同じキャッシュを読み取るだけで、Keychain/API には触れない。

1. `~/.cache/claude-usage-cache.json` に `cached_at` 付きの使用量 JSON を保存しておく
2. statusline は Claude Code の表示更新時にこの JSON を読み取る
3. アプリは 60 秒ごと、またはメニューの「キャッシュを再読込」でこの JSON を読み直す

API アクセス、OAuth トークン取得、トークン更新はアプリ側でも statusline 側でも行わない。
キャッシュが古い場合でも、最後に保存された値を表示し続ける。

## ビルド & インストール

```sh
./build.sh        # swiftc でビルド → ~/Applications/ClaudeUsageWidget.app に配置
open ~/Applications/ClaudeUsageWidget.app
```

依存は Xcode Command Line Tools の swiftc のみ。
