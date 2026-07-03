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

## データソース

statusline (`~/.claude/statusline-command.sh`) と同じ仕組み:

1. Keychain の `Claude Code-credentials` から OAuth トークンを取得
2. `https://api.anthropic.com/api/oauth/usage` を叩く
3. `~/.cache/claude-usage-cache.json` に 360 秒キャッシュ（statusline とキャッシュを共有するので API 呼び出しは増えない）

60 秒ごとに再描画（キャッシュが新しければネットワークアクセスなし）。スリープ復帰時にも更新。

## ビルド & インストール

```sh
./build.sh        # swiftc でビルド → ~/Applications/ClaudeUsageWidget.app に配置
open ~/Applications/ClaudeUsageWidget.app
```

依存は Xcode Command Line Tools の swiftc のみ。
