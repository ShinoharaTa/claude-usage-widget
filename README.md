# ClaudeUsageWidget

Claude Code のレートリミット（5時間 / 7日間）を Mac のメニューバーとオーバーレイウィジェットに表示する常駐アプリ。

## 表示

- **メニューバー**: `5h 13%  7d 4%` を常時表示。50%以上でオレンジ、80%以上で赤。ホバーでリセット時刻のツールチップ。
- **ウィジェット**: 画面上部に 5h / 7d の2段バーをオーバーレイ表示（半透明・全Space表示・ドラッグで移動可、位置は記憶される）。

## 操作

- メニューバー項目を**左クリック** → ウィジェットの表示/非表示をトグル
- **右クリック**（または ⌃クリック）→ 詳細メニュー
  - 使用率・リセット時刻・リセットまでの残り時間
  - ウィジェット表示切り替え / 今すぐ更新
  - ログイン時に自動起動（トグル）
  - 終了

## 通知

5時間 / 7日間リミットのリセット時刻を過ぎたことを検出すると、macOS の通知を送る。
初回起動時に通知の許可ダイアログが出るので許可すること。同じリセットに対して重複通知はしない。

## データソースとトークン管理

statusline (`~/.claude/statusline-command.sh`) と同じ仕組み:

1. Keychain の `Claude Code-credentials` から OAuth トークンを取得（Security framework 経由。初回にキーチェーンの許可ダイアログが出るので「常に許可」を推奨。再ビルドすると署名が変わり再度出る）
2. `https://api.anthropic.com/api/oauth/usage` を叩く
3. `~/.cache/claude-usage-cache.json` に 300 秒キャッシュ（statusline とキャッシュを共有）

**5分ごと**に API アクセス（画面の再描画とリセット検出は60秒ごと）。スリープ復帰時にも更新。

アクセストークンが失効している（または失効間近の）場合は、Keychain の refreshToken で
`https://console.anthropic.com/v1/oauth/token` からトークンを再発行し、**Keychain に書き戻す**
（refresh token はローテーションされるため、書き戻さないと Claude Code 本体のトークンが無効になる）。
API が 401 を返した場合は Keychain を読み直し（Claude Code 側が先に更新したケース）てからリトライする。

## ビルド & インストール

```sh
./build.sh        # swiftc でビルド → ~/Applications/ClaudeUsageWidget.app に配置
open ~/Applications/ClaudeUsageWidget.app
```

依存は Xcode Command Line Tools の swiftc のみ。
