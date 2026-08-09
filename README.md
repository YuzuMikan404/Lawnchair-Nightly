# Lawnchair Nightly Mirror

Lawnchairの `nightly` リリース(同じタグ上で毎回上書きされるリリース)を定期監視し、
APKの中身(SHA256)が変わったタイミングだけ、このリポジトリに
タイムスタンプ付きの新しいタグ・リリースとして保存するボットです。

Obtainium / ObtainX 側は「タグが変わらないと更新と認識しない」ため、
このリポジトリを Obtainium の監視先にすることで、正しく新バージョンを検知できます。

## Obtainium側の設定

Obtainiumの追加時に、
このミラーリポジトリのURL(例: `https://github.com/yourname/lawnchair-nightly-mirror`)を指定してください。
タグごとに新しいリリースが作られるので、正しく更新を検知できるようになります。

## 仕組み

- 元の `nightly` リリースのAPKアセットの `digest`(SHA256)を毎回取得
- 前回保存した値(`state/last_digest.txt`)と比較
- 変わっていれば、そのAPKをダウンロードして
  `nightly-YYYYMMDD-HHMMSS` というタグで新規リリースを作成
- 変わっていなければ何もしない(APIを叩くだけなので軽い)
