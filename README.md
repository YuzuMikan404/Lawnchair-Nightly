# Lawnchair Nightly Mirror

Lawnchairの `nightly` リリース(同じタグ上で毎回上書きされるリリース)を定期監視し、
APKの中身(SHA256)が変わったタイミングだけ、このリポジトリに
**タイムスタンプ付きの新しいタグ・リリース**として保存するボットです。

Obtainium / ObtainX 側は「タグが変わらないと更新と認識しない」ため、
このリポジトリを Obtainium の監視先にすることで、正しく新バージョンを検知できます。

## セットアップ手順

1. GitHubで新しい空のリポジトリを作成する(例: `lawnchair-nightly-mirror`)
2. このリポジトリの中身(`.github/workflows/mirror-nightly.yml` を含む)をそのままpushする
3. リポジトリの **Settings → Actions → General → Workflow permissions** で
   「Read and write permissions」を選択して保存する
   (これをしないと `gh release create` や `git push` が失敗します)
4. 何もしなくても1時間おきに自動実行されますが、
   すぐ試したい場合は **Actions タブ → Mirror Lawnchair Nightly → Run workflow** で手動実行できる
5. 初回実行時は必ず「変更あり」と判定されるので、最初の1回だけリリースが作られます
   (以降は本当にAPKが変わったときだけ新リリースが作られます)

## Obtainium側の設定

Obtainiumの追加時に、アプリソースとして **GitHub** を選び、
このミラーリポジトリのURL(例: `https://github.com/yourname/lawnchair-nightly-mirror`)を指定してください。
タグごとに新しいリリースが作られるので、正しく更新を検知できるようになります。

## チェック頻度の変更

`.github/workflows/mirror-nightly.yml` の一番上、
```yaml
- cron: '0 * * * *'
```
の部分を変えることで頻度を調整できます(例: 15分おきなら `*/15 * * * *`)。
あまり短くしすぎるとGitHub APIのレート制限に引っかかりやすくなるので、
15分〜1時間程度がおすすめです。

## 仕組みの補足

- 元の `nightly` リリースのAPKアセットの `digest`(SHA256)を毎回取得
- 前回保存した値(`state/last_digest.txt`)と比較
- 変わっていれば、そのAPKをダウンロードして
  `nightly-YYYYMMDD-HHMMSS` というタグで新規リリースを作成
- 変わっていなければ何もしない(APIを叩くだけなので軽い)
