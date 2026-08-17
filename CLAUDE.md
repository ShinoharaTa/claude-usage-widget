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
- `Limit` は 1 行分のリミット。`5h` / `7d` は `five_hour` / `seven_day` から、
  モデル別の週次上限は `limits` 配列の `kind == "weekly_scoped"` から作る（`scope.model.display_name` → `scope.surface` → `"model"` の順にラベルを決めて小文字化）。
  **statusline スクリプトが同じ行を同じ方法で選んでいるので、片方を変えるならもう片方も変える**
- 色は `severity`（`normal` / `warning` / `critical`）優先、無ければ使用率（70/90%）で判定。
  閾値は statusline の `color_for_limit` / `color_for_pct` と合わせてある。
  メニューバーだけは `normal` のとき通常の文字色（常時緑は飾りとして無視されるため）
- `UsageView`: オーバーレイのバー描画（幅 240 固定、flipped 座標）。段数はリミット数で変わり、
  高さは `UsageView.height(rowCount:stale:)` が返す（1 段 24pt + 上 10pt + 下 2pt、2 段で従来と同じ 60pt）。
  ラベル幅は一番長いラベルに合わせて可変（上限 62pt、超えたら truncate）なので、`fable` でもバーは潰れない
- `AppDelegate`: NSStatusItem（左クリック=ウィジェットトグル / 右クリック=詳細メニュー）、NSPanel（.floating、全 Space、ドラッグ可）、
  60 秒タイマー（キャッシュ再読込 → `layoutPanel` でリサイズ）、リセット通知、SMAppService でログイン時起動
- **パネル位置は上端（`widgetTopY`）で永続化する**。段数が増減しても上端を固定してリサイズするため。
  旧 `widgetY`（高さ 60 固定時代の左下原点）しか無い場合は `+60` して上端に読み替える
- 通知はリセット時刻（エポック秒）でグルーピングして 1 通にまとめる。モデル別上限は 7d と同時リセットが普通で、
  分けると同じ内容が 2 通届く。重複排除は各 `Limit.notifyKey` に通知済みエポックを書く方式（キーが増え続けない）。
  **すでに過ぎたリセットは通知しない**（キャッシュが遅れていただけなので、起動直後に過去の通知が飛ぶのを防ぐ）

## 動作確認のポイント

- 起動確認: `pgrep -x ClaudeUsageWidget`
- キャッシュ確認: `jq -r '.cached_at' ~/.cache/claude-usage-cache.json`
- **パース部分は GUI を立てずに検証できる**。`// MARK: - App delegate` より前を切り出して
  ダンプコードを足せば、そのままコンパイルして実行できる（`AppKit` を import したままでも CLI として動く）。
  `XDG_CACHE_HOME` を差し替えれば合成キャッシュを食わせられるので、
  旧形式（`limits` 配列なし）・`severity` 各値・段数の増減・`cached_at` 過去・壊れた JSON を一通り通しておく

  ```sh
  awk '/^\/\/ MARK: - App delegate/{exit} {print}' Sources/main.swift > /tmp/check.swift
  # /tmp/check.swift の末尾に UsageFetcher.get(force:) を呼ぶ print を足す
  swiftc /tmp/check.swift -o /tmp/check && XDG_CACHE_HOME=/tmp/case1 /tmp/check
  ```

- **cached_at は必ず整数で書くこと**: statusline スクリプトが bash の整数演算に使っており、
  小数を書くと statusline がシェルごと死んで何も表示されなくなる（2026-07-03 に実際に起きた。
  statusline 側にも `| floor` の防御を入れてあるが、フォーマットは整数を維持する）
- スクリーンショットでの UI 確認はターミナルの画面収録権限がないと `screencapture` が失敗する
