# TestFlight 配信セットアップ手順

`HDZap` の TestFlight 配信を team `<TEAM_ID>` (<Your Name> 個人 team) で立ち上げた手順。新しい iOS アプリを同 team で出すときの参照に。

---

## バックアップが必須なもの（消えると復旧不可）

| ファイル | パス | 備考 |
|---|---|---|
| ASC API key | `~/.blitz/AuthKey_<KEY_ID>.p8` | **一度しかダウンロードできない**。失った場合は ASC で revoke → 新規作成。`~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` にもコピー済み（altool 用） |
| Web セッション | `~/.blitz/asc-agent/web-session.json` | Apple ID にログイン済みの Chrome cookie。ASC への管理 API 直叩き用。期限切れる |
| AppIcon-1024.png | `app/HDZap/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` | 1024×1024 の app icon |

`AuthKey_<KEY_ID>.p8` だけは **絶対に消すな**。消したら revoke してまた作るしかない。

## 必要なクレデンシャル

- **Team ID**: `<TEAM_ID>`
- **Key ID**: `<KEY_ID>`（ASC API key, name=`<KEY_NAME>`, role=Admin, allAppsVisible=true）
- **Issuer ID**: `<ISSUER_ID>`
- **Bundle ID**: `sh.saqoo.HDZap`（explicit）
- **SKU**: `HDZAP001`

---

## 全体の流れ

```
1. project.yml の DEVELOPMENT_TEAM を team ID に
2. Info.plist に ITSAppUsesNonExemptEncryption=false
3. PrivacyInfo.xcprivacy 追加（trackingDomains/data 無し宣言）
4. Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png 配置（8-bit RGB, アルファ無し, 1024×1024）
5. xcodegen generate
6. Xcode で Apple Development + Apple Distribution 証明書を作成
7. Apple Developer で explicit Bundle ID 登録（wildcard 不可）
8. App Store Connect で新規アプリ作成
9. xcodebuild archive → exportArchive で .ipa 作成
10. ASC API key 作成 → altool で TestFlight にアップロード
11. ASC で Internal testers 追加（最大100人、レビュー無し）
```

---

## ローカル準備

### project.yml

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: "<TEAM_ID>"
    CODE_SIGN_STYLE: Automatic
targets:
  HDZap:
    info:
      properties:
        ITSAppUsesNonExemptEncryption: false  # BLE のみで暗号化扱いされない宣言
```

### Info.plist

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

### PrivacyInfo.xcprivacy

トラッキング・データ収集無しの最小宣言。[app/HDZap/PrivacyInfo.xcprivacy](../app/HDZap/PrivacyInfo.xcprivacy) を参照。

### AppIcon

```sh
# placeholder 生成（本番では差し替え）
magick -size 1024x1024 \
  -define gradient:angle=135 gradient:'#1e3a8a-#06b6d4' \
  -gravity center \
  -font /Library/Fonts/ACaslonPro-Bold.otf -pointsize 280 -fill white \
  -annotate +0-40 "HD" \
  -font /Library/Fonts/ACaslonPro-Bold.otf -pointsize 160 -fill white \
  -annotate +0+180 "ZAP" \
  -alpha off \
  -depth 8 -define png:color-type=2 \
  app/HDZap/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
```

**重要**: 8-bit, アルファ無し, 1024×1024 必須。`identify` で確認 → `8-bit sRGB` であること。16-bit や RGBA は ASC が拒否する。

---

## Apple Developer ポータル設定

### Bundle ID の explicit 登録

ASC は **wildcard App ID（`sh.saqoo.*`）を受け付けない**。explicit な ID が必要。

1. [Identifiers](https://developer.apple.com/account/resources/identifiers/list) → `+` ボタン
2. Type: App IDs → App
3. Description: `HDZap`、Bundle ID: Explicit + `sh.saqoo.HDZap`
4. Capabilities は何も追加しなくて OK（BLE は capability 不要）
5. Continue → Register

### Xcode 証明書（一度きり）

Xcode → Settings → Accounts → Apple ID 追加 → team 選択 → Manage Certificates → `+`：
- **Apple Development**（ローカル）
- **Apple Distribution**（TestFlight/App Store）

確認：
```sh
security find-identity -v -p codesigning
# "Apple Distribution: <Your Name> (<TEAM_ID>)" が出てれば OK
```

---

## App Store Connect で新規アプリ

[Apps](https://appstoreconnect.apple.com/apps) → `+` → New App：

- Platforms: iOS
- Name: `HDZap`
- Primary Language: English (U.S.)
- Bundle ID: `HDZap - sh.saqoo.HDZap`（前ステップで作成した explicit ID がここで選べる）
- SKU: `HDZAP001`（任意の unique 文字列）
- User Access: Full Access

---

## Archive と .ipa 生成

```sh
cd app

# 初回は -allowProvisioningUpdates が必須（Xcode が provisioning profile を自動生成）
xcodebuild -project HDZap.xcodeproj -scheme HDZap \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath build/archives/HDZap.xcarchive \
  -allowProvisioningUpdates archive

# ExportOptions.plist は build/ExportOptions.plist 参照
xcodebuild -exportArchive \
  -archivePath build/archives/HDZap.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist \
  -allowProvisioningUpdates
```

成果物：`app/build/export/HDZap.ipa`

---

## ASC API Key 作成（一度だけ）

`/asc-team-key-create` skill を使う。手順：

1. Chrome で App Store Connect にログイン済みであること
2. browser-harness で cookie を抜いて `~/.blitz/asc-agent/web-session.json` に保存
3. skill のスクリプトが ASC 管理 API を叩いて key 作成 + .p8 ダウンロード

詳細は `~/.claude/skills/asc-team-key-create/SKILL.md`。

`.p8` のコピーを **必ず** `~/.appstoreconnect/private_keys/` にも置くこと（altool は自分の引数で渡したパスを **無視して** ここを探す）：

```sh
mkdir -p ~/.appstoreconnect/private_keys
cp ~/.blitz/AuthKey_<KEY_ID>.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

---

## TestFlight アップロード

```sh
xcrun altool --upload-app -f build/export/HDZap.ipa --type ios \
  --apiKey <KEY_ID> \
  --apiIssuer <ISSUER_ID>
```

成功すると `UPLOAD SUCCEEDED with no errors` + `Delivery UUID`。

そのあと ASC でビルドが「処理中（5〜30分）」→ 完了で TestFlight タブに表示。

---

## TestFlight Internal Testing（レビュー無し、最大100人）

ASC → アプリ → TestFlight タブ：
1. Internal Testing で `+` → グループ作成
2. Apple ID（team メンバー）追加
3. ビルド選択 → Save → 招待メール飛ぶ

External Testers（最大10000人）は Beta App Review が必要（初回のみ）。

---

## 次のリリース時の最小フロー

`develop` で working tree クリーン、`origin/develop` と同期している状態から：

```sh
# 一発でリリース：bump → archive → upload → develop push → CI 待ち
#   → PR develop → main → merge → tag → GitHub Release → develop fast-forward
MODEL_NAME="Opus 4.7" ./scripts/release.sh 1.0.1
```

スクリプトの中身：
- `scripts/build.sh` — `xcodegen generate` + `xcodebuild archive`
- `scripts/upload-testflight.sh` — `exportArchive` + `altool --upload-app`
- `scripts/release.sh` — pre-flight（`develop` 上、tree clean、`origin/develop` 同期、tag 未使用）→ `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` bump → build → TestFlight upload（**ここから先は不可逆**）→ `jj describe` + `develop` push → develop CI green 待ち → `gh pr create develop → main` → `gh pr merge --merge` → tag → `gh release create` → ローカル develop を main に fast-forward

Claude Code から：`release` skill が "release" / "ship it" / "TestFlight build" 等のキーワードで自動発動して上のフローを走らせる（[`.claude/skills/release/SKILL.md`](../.claude/skills/release/SKILL.md)）。`MODEL_NAME` 環境変数は必須（commit の `Co-Authored-By` 行に走っているモデル名を載せるため）。

`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` は `app/project.yml` の `settings.base` で定義し、Info.plist では `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` placeholder で参照（Canopy と同じパターン）。

---

## 落とし穴

- **`xcodebuild` 初回は `-allowProvisioningUpdates` が必須**。これ無しだと `No profiles for 'sh.saqoo.HDZap' were found` で死ぬ。
- **`altool --apiKey` は引数で渡したパスを参照しない**。`~/.appstoreconnect/private_keys/AuthKey_<KEY>.p8` を探す。skill 通りに `~/.blitz/` に置いただけだと `(-43) The file could not be found` エラー。
- **ASC で wildcard Bundle ID は使えない**。`sh.saqoo.*` のような ID を選ぼうとすると ドロップダウンに出ない。explicit ID が必須。
- **AppIcon は 8-bit, アルファ無し, 1024×1024**。16-bit PNG や PNG with alpha channel は ASC validation で拒否される。
- **`CFBundleVersion` は毎アップロードでユニーク**。同じ番号で再アップロード→ Apple が拒否。
- **`.p8` は一度きり**。downloadした瞬間 `canDownload` が false に flip して二度と取れない。失くしたら revoke + 新規作成。

---

## 関連ファイル

- [app/project.yml](../app/project.yml) — DEVELOPMENT_TEAM, ITSAppUsesNonExemptEncryption, MARKETING_VERSION/CURRENT_PROJECT_VERSION
- [app/HDZap/Info.plist](../app/HDZap/Info.plist) — bundle 設定
- [app/HDZap/PrivacyInfo.xcprivacy](../app/HDZap/PrivacyInfo.xcprivacy) — privacy manifest
- [app/HDZap/Assets.xcassets/AppIcon.appiconset/](../app/HDZap/Assets.xcassets/AppIcon.appiconset/) — AppIcon
- [app/ExportOptions.plist](../app/ExportOptions.plist) — export 設定（tracked、`upload-testflight.sh` が参照）
