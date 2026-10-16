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
  - ログイン時に自動起動（トグル。下記「自動起動」）
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
~/Applications/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget --enable-login-item   # 初回: 自動起動を有効にして起動
```

依存は Xcode Command Line Tools の swiftc のみ。
自動起動を有効にしてあれば、2 回目以降の `./build.sh` は新しいビルドを launchd 経由で起動し直す。

## 自動起動

ログイン時の起動と、落ちたときの再起動は launchd の LaunchAgent
`~/Library/LaunchAgents/com.shino3.claude-usage-widget.plist` が受け持つ（SMAppService は使わない。
ad-hoc 署名のバンドルを build.sh が丸ごと置き換えるため、登録が残らなかった）。
メニューの「ログイン時に自動起動」はこの plist の有無を切り替える。ターミナルからは:

```sh
BIN=~/Applications/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget
$BIN --enable-login-item    # plist を書き、launchd 管理で今すぐ起動（手動起動中のものは置き換える）
$BIN --disable-login-item   # plist を消す。動作中のものは次回ログアウトまでそのまま
$BIN --login-item-status    # enabled / loaded / pid
```

- クラッシュや `pkill` で死んだときは launchd が起動し直す。メニューの「終了」（正常終了）では起動し直さない
- アプリの stderr は `/tmp/claude-usage-widget.err`
