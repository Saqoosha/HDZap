# HDZap ユーザーマニュアル

<p align="center">
  <img src="images/app-icon-squircle.png" alt="HDZap" width="120" border="0" style="border:0" />
</p>

<p align="center">
  <a href="https://apps.apple.com/app/id6766197336">
    <img src="https://toolbox.marketingtools.apple.com/api/badges/download-on-the-app-store/black/ja-jp?size=250x83" alt="App Store で HDZap をダウンロード" height="40" />
  </a>
</p>

<p align="center">
  <a href="https://saqoosha.github.io/HDZap/">English</a> ・ <strong>日本語</strong>
</p>

> **サポート.** 質問・バグ報告・要望は [a@saqoo.sh](mailto:a@saqoo.sh) または [GitHub Issues](https://github.com/Saqoosha/HDZap/issues) までお願いします。よくある問題は下の [§12 トラブルシューティング](#12-うまくいかないときトラブルシューティング) を参照してください。

---

## 目次

1. [これは何？](#1-これは何)
2. [必要なもの](#2-必要なもの)
3. [M5StickS3 にファームウェアを焼く](#3-m5sticks3-にファームウェアを焼く)
4. [iPhone アプリをインストール](#4-iphone-アプリをインストール)
5. [M5StickS3 と iPhone をペアリング（Bluetooth）](#5-m5sticks3-と-iphone-をペアリングbluetooth)
6. [Digital FPV Goggle と bind する](#6-digital-fpv-goggle-と-bind-する)
7. [フライトバッテリーテレメトリー](#7-フライトバッテリーテレメトリー)
8. [レースする](#8-レースする)
9. [レースのあとに](#9-レースのあとに)
10. [Premium ボイス（サブスクリプション）](#10-premium-ボイスサブスクリプション)
11. [設定リファレンス](#11-設定リファレンス)
12. [うまくいかないとき（トラブルシューティング）](#12-うまくいかないときトラブルシューティング)
13. [付録](#13-付録)

---

## 1. これは何？

<p align="center">
  <iframe src="https://www.youtube.com/embed/FXDKoBYkyB4"
          title="HDZap demo"
          width="640"
          height="480"
          style="max-width: 100%; aspect-ratio: 4 / 3; height: auto; border: 0;"
          frameborder="0"
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
          allowfullscreen></iframe>
</p>

HDZap は、**iPhone で計測したラップタイムを Digital FPV Goggle の OSD に表示する** ためのシステムです。**パイロットとは別に、計測してくれるスポッターが1人必要** な、二人組での運用を前提としています。

```mermaid
flowchart LR
    A["iPhone<br/>HDZap App<br/><i>スポッター</i>"] -- Bluetooth --> B["M5StickS3<br/><i>中継器</i>"]
    B -- ESP-NOW --> C["Digital FPV Goggle<br/><i>パイロット</i>"]
```

システムは3つの要素でできています。

- **iPhone アプリ**：スポッターが操作するタイマー UI。スタート / LAP / ストップ / 履歴管理。
- **M5StickS3**：手のひらサイズの小型 ESP32 デバイス（中継器）。Bluetooth で iPhone から命令を受け、ESP-NOW という別の電波で Goggle に OSD コマンドを送ります。
- **Digital FPV Goggle**：パイロットが装着する FPV ゴーグル。内蔵の ELRS Backpack を通して OSD（画面オーバーレイ）にラップタイムを表示します。

> 💡 **iPhone アプリだけでも使えます。** タイム計測、ラップ履歴、音声読み上げなどはアプリ単体で完結します。M5StickS3 と Goggle を追加すると、それに加えてラップタイムが Goggle の OSD にも表示されるようになります。

### 用語ミニマップ

このあと頻繁に出てくる用語です。詳しい説明は [付録](#13-付録) にあります。

| 用語 | 1行説明 |
|---|---|
| **Goggle** | パイロットが装着する FPV ゴーグル。Digital FPV Goggle / Digital FPV Goggle 2 |
| **ELRS Backpack** | Goggle 内蔵の ESP32 モジュール。OSD コマンドを受信する |
| **UID** | 6 バイトの識別子。Goggle と M5StickS3 が同じ UID を持つと通信できる |
| **bind phrase** | UID を生成するもとになる文字列。同じ phrase ならどの機材でも同じ UID になる |
| **OSD** | On-Screen Display。映像の上に重ねて表示する文字 |

---

## 2. 必要なもの

### ハードウェア

- **M5StickS3** ×1（中継器）

  <img src="images/m5sticks3.jpg" alt="M5StickS3" width="240" />

- **USB-C データケーブル** ×1
  - **充電専用ケーブルは使えません**。データ通信ができるケーブルが必要です
- **Digital FPV Goggle**（Digital FPV Goggle / Digital FPV Goggle 2）
- **iPhone**（iOS 18 以降）

### ソフトウェア

- **Google Chrome**
  - Web Flasher は Web Serial API を使うため、**Safari / Firefox では動作しません**。Chromium 系（Edge、Brave など）も Web Serial に対応しているので技術的には動くはずですが、未検証です
- 動作確認環境：**macOS 26.4 + Chrome** のみ

### 必須：Goggle 側のファームウェア v1.5.5 以上

> ⚠️ **Digital FPV Goggle の ELRS Backpack ファームウェアが v1.5.5 以上であることが必須です。**
>
> 古いバージョンだと HDZap が送る OSD コマンドの一部が無視されたり、正しく描画されなかったりすることがあります。

#### バージョンの確認方法

Goggle のメニュー → **ELRS** で確認できます。

#### アップデートの方法

ExpressLRS Configurator を使って ELRS Backpack のファームウェアをアップデートします。HDZap からは Goggle 側のアップデートはできません。

- ExpressLRS Configurator: https://github.com/ExpressLRS/ExpressLRS-Configurator/releases

![ExpressLRS Configurator](images/02-elrs-configurator.png)

> 💡 **トラブルの大半はファームウェアの古さが原因です。** Chapter 6 で OSD が出ないときは、まずバージョンを疑ってください。

---

## 3. M5StickS3 にファームウェアを焼く

**Web Flasher** というブラウザだけで完結するツールを使います。

### 手順

1. **Chrome** で次の URL を開きます。
   👉 https://saqoosha.github.io/HDZap/flash/ja/

2. **M5StickS3** を USB-C データケーブルで PC に接続します。

3. 接続する前に **「完全初期化する」** チェックボックスを決めます（初期状態はオフ）：
   - **初回フラッシュ時はチェックを推奨**。M5StickS3 のフラッシュメモリを完全に消去してから書き込みます
   - **2回目以降の更新時はチェックを外したまま**。NVS に保存されている UID（Goggle とのペアリング情報）が保持されます

4. ブラウザで **「接続して書き込む」** をクリック。シリアルポート選択のダイアログが出るので、`USB JTAG/serial debug unit` または `USB Serial` のような名前のポートを選びます。多くの場合、esptool が自動で M5StickS3 をブートローダーモードに入れて書き込みを始めます。

5. **接続できないとき：DFU モードに手動で入れる**
   「ブートローダーに接続中…」のまま止まったり、エラーが出たりする場合は、M5StickS3 の **左側面の小さな電源ボタン** を **2 秒ほど長押し** します。緑色の LED が点滅すれば DFU モードに入っています。この状態でもう一度「接続して書き込む」をクリック。

6. 「書き込む」という別ボタンはありません。ポートを選んだ時点で書き込みが始まり、完了まで 30 秒〜1 分ほどかかります。

7. **書き込みが終わったら**、M5StickS3 の **左側面の小さな電源ボタンを押して再起動** します。LCD に状態が表示されれば成功です。

   ![書き込み完了後の M5StickS3](images/03-flasher-done.jpg)

### うまくいかないとき

- **`ESP_TOO_MUCH_DATA` というエラーが出る**：ブラウザを最新の Chrome に更新してください。
- **ポートが選べない / 表示されない**：ケーブルを変えてみてください（充電専用ではないか確認）。それでも駄目なら DFU モードに手動で入れ直してから（電源ボタン 2 秒長押し）もう一度 **「接続して書き込む」** をクリック。
- **Allow ダイアログが出ない**：一度ブラウザを閉じて、URL を開き直してください。

---

## 4. iPhone アプリをインストール

HDZap は App Store で公開中です。

<p align="center">
  <a href="https://apps.apple.com/app/id6766197336">
    <img src="https://toolbox.marketingtools.apple.com/api/badges/download-on-the-app-store/black/ja-jp?size=250x83" alt="App Store で HDZap をダウンロード" height="60" />
  </a>
</p>

1. iPhone で上の App Store バッジをタップし、**「入手」** をタップしてインストールします。
2. ホーム画面に追加された HDZap アイコンをタップして起動。

3. 初回起動時に **Bluetooth の使用許可** を求められるので **「許可」** をタップします。これを拒否すると M5StickS3 と接続できません。

   <p align="center">
     <img src="images/04-bluetooth-permission.png" alt="Bluetooth 権限ダイアログ" width="320" />
   </p>

---

## 5. M5StickS3 と iPhone をペアリング（Bluetooth）

iPhone と M5StickS3 を Bluetooth で接続します。操作場所は iOS アプリの **設定（⚙️）→ デバイス → M5StickS3**。

### 手順

1. M5StickS3 の電源を入れます（LCD に表示が出ている状態）。
2. iPhone の HDZap アプリを開き、画面右上の **歯車アイコン（⚙️）** をタップして設定シートを開きます。

   <p align="center">
     <img src="images/timer-masthead-ja.png" alt="タイマー画面上部 — 右側に歯車アイコン" width="360" />
     <br />
     <em>タイマー画面の上部 — 右側の歯車アイコンをタップ</em>
   </p>

3. 設定シートの **デバイス** セクションで **ブリッジを使う** が OFF なら ON にします。新規インストール時は OFF で、**M5StickS3** / **ゴーグルペアリング** / **OSD レイアウト** の 3 行は ON にするまで表示されません（初回 ON 時に iOS が Bluetooth の利用許可を求めます）。

   <p align="center">
     <img src="images/settings-device-standalone-ja.png" alt="ブリッジ OFF — ドリルダウンが隠れた状態" width="360" />
     <br />
     <em>新規インストール時：ブリッジ OFF</em>
   </p>

4. ON にすると **M5StickS3** / **ゴーグルペアリング** / **OSD レイアウト** の3行が現れます。**M5StickS3** をタップして接続画面に入ります。

   <p align="center">
     <img src="images/settings-device-bridgeon-ja.png" alt="ブリッジ ON 直後 — M5StickS3 は未接続、ゴーグルペアリングは未設定" width="360" />
     <br />
     <em>ブリッジ ON 直後（初回）— M5StickS3 行は <strong>未接続</strong>、ゴーグルペアリングは <strong>—</strong>。M5StickS3 行をタップして接続画面へ</em>
   </p>

5. **スキャン** ボタンをタップ。近くの M5StickS3 が **その他のデバイス** セクションに表示されます。

   <p align="center">
     <img src="images/connection-other-devices-ja.png" alt="その他のデバイスカード（スキャン前は空）" width="360" />
     <br />
     <img src="images/connection-scan-ja.png" alt="スキャンボタン" width="360" />
   </p>

6. **HDZapBridge**（または下の[M5StickS3 の名前を変更する（任意）](#m5sticks3-の名前を変更する任意)で変えた任意の名前）の横の **接続** ボタンをタップ。

7. 接続成功すると：
   - **接続済み** セクションに緑の丸とデバイス名 + **切断** ボタンが現れる
   - その下にバッテリ % と充電アイコン、**バージョン**（App + FW）が出る
   - M5StickS3 側の LCD にも接続状態が出る

   <p align="center">
     <img src="images/connection-connected-ja.png" alt="接続成功後の Connected カード" width="360" />
   </p>

これで iPhone と M5StickS3 の通信路ができました。次は Goggle との bind です。

### M5StickS3 の名前を変更する（任意）

M5StickS3 を複数台持っている場合、デフォルトの `HDZapBridge` のままだと識別しづらくなります。接続中なら次の手順で名前を変えられます：

1. 設定 → **デバイス** → **M5StickS3**。
2. **Bluetooth 名** をタップ。

   <p align="center">
     <img src="images/rename-ja.png" alt="名前変更画面" width="360" />
   </p>

3. 新しい名前を入力（UTF-8、最大 20 バイト。絵文字 1 文字 ≒ 4 バイト）して **保存** をタップ。
4. M5StickS3 が一度だけ自動再起動します（約 3 秒）。iPhone は自動で再接続し、新しい名前が M5StickS3 の LCD の UID 帯と iOS 側の接続済みセクションに反映されます。

> 💡 新しい名前はフラッシュメモリに保存されるので、電源を切っても残ります。`HDZapBridge` を入れて保存し直せばデフォルトに戻ります。

### うまくいかないとき

- **デバイス一覧に何も出ない**：iPhone の設定アプリ → HDZap → Bluetooth が ON になっているか確認。M5StickS3 の電源を入れ直してください。
- **接続ボタンを押しても繋がらない**：iPhone の設定 → Bluetooth に HDZap が出ている場合は一度「このデバイスの登録を解除」してから、もう一度試してください。

---

## 6. Digital FPV Goggle と bind する

操作場所は iOS アプリの **設定（⚙️）→ デバイス → ゴーグルペアリング**（サブ画面のタイトルは **ペアリング**）。下の手順すべて、まずここを開いてからスタートします。動作確認は **設定 → デバイス → OSD レイアウト** を開くだけで OK — ページを開いた瞬間にプレビューが Goggle に自動表示されます。

<p align="center">
  <img src="images/settings-device-ja.png" alt="設定シートのデバイスセクション — ゴーグルペアリング行" width="360" />
  <br />
  <em>すべての bind 方法はここからスタート — <strong>ゴーグルペアリング</strong> 行をタップ</em>
</p>

### 前提チェック

> ⚠️ Goggle の ELRS Backpack ファームウェアが **v1.5.5 以上** であることを確認してください。詳細は [Chapter 2](#必須goggle-側のファームウェア-v155-以上) を参照。

### なぜ bind が必要？

M5StickS3 が Goggle に OSD コマンドを送るには、**両者が同じ UID（6 バイトの識別子）を持つ必要** があります。これを揃える作業が「bind」です。

### 判定フローチャート：あなたはどれ？

```mermaid
flowchart TD
    A[ELRS Backpack の firmware に<br/>bind phrase を設定済み？] -- Yes --> B[6.4 既知の<br/>bind phrase を使う]
    A -- No --> C[プロポと Goggle を<br/>bind したことがある？]
    C -- Yes --> D[6.2 TX UID キャプチャ]
    C -- No --> E[6.1 新規ペアリング]
```

> 📝 **6.3 手動 UID 入力** という選択肢もありますが、現時点での Goggle 公式ファームウェアにはバグがあり、Goggle メニューから UID を読み取ることが事実上できません。そのため上のフローチャートには含めていません。状況により使える人だけ [6.3](#63-手動-uid-入力上級者向け) を参照してください。

### bind phrase と UID の関係

- **bind phrase**：人間が決める文字列（例：`my-race-2026`）
- **UID**：6 バイトの数値（例：`123,45,67,89,0,12`）

bind phrase を MD5 ハッシュにかけた最初の 6 バイトが UID になります。**同じ bind phrase を入れれば、どの機材でも必ず同じ UID** が出ます。

---

### 6.1 新規ペアリング

**こういう人向け**：Goggle が新品。または、まっさらな状態から M5StickS3 と Goggle だけで bind したい。

> ⚠️ **この操作は Goggle の既存の binding を上書きします。** プロポとのペアリング情報は失われます（プロポを使うときは再度 bind が必要）。

#### 手順

1. **Goggle を bind モードに入れる**：
   1. Goggle メニュー → **ELRS** を開く
   2. **Backpack** を **On** にする
   3. **Bind** → **Click to start** を選択
   4. Goggle が「bind 待ち」状態になります
2. アプリの設定シート → **デバイス** → **ゴーグルペアリング** へ。
3. **モード** ピッカーで **新規ペアリング** を選択。

   <p align="center">
     <img src="images/pairing-configure-new-pairing-ja.png" alt="ペアリング — 新規ペアリングモード" width="360" />
   </p>

4. **新しいゴーグルとペアリング** ボタンをタップ。M5StickS3 が bind パケットをブロードキャスト。
5. Goggle が受理すると binding 完了。
6. アプリ側の状態バナーが検証を経て完了になれば OK。
7. **動作確認**：設定 → **デバイス** → **OSD レイアウト** を開く。Goggle にプレビューが自動表示されれば成功。

---

### 6.2 TX UID キャプチャ（プロポで bind 済みの Goggle）

**こういう人向け**：プロポと Goggle を bind したことがある。bind phrase は指定したことがない（または控えていない）。プロポが手元にある。

> ✅ この方法は **プロポと Goggle の既存の binding を壊しません**。M5StickS3 がプロポのブロードキャストを受動的に「盗み聞き」して UID を抜き出すだけです。

#### 手順

1. Goggle の電源を入れ、プロポに bind 済みであることを確認します。映像が出るだけでは確認になりません（VTX 側の話）。**EdgeTX の ExpressLRS Lua スクリプトから VTX チャンネルを変更し、それが Goggle に伝わるか** で初めて確認できます。
2. アプリの設定シート → **デバイス** → **ゴーグルペアリング** に入り、**TX UID キャプチャ** セクションまでスクロール。
3. **TX UID キャプチャを開始** ボタンをタップ。M5StickS3 が ESP-NOW のブロードキャストを聞き始めます。

   <p align="center">
     <img src="images/pairing-tx-uid-capture-ja.png" alt="ペアリング — TX UID キャプチャカード" width="360" />
   </p>

4. **EdgeTX の ExpressLRS Lua Script を開き、その中の Bind メニューを実行** します。
5. M5StickS3 が bind ブロードキャストを受信して UID を抜き出し、**キャプチャした TX UID** セクションに表示されます。
6. **適用** をタップ → 切り替えと検証を経て完了。
7. **動作確認**：設定 → **デバイス** → **OSD レイアウト** を開く。Goggle にプレビューが自動表示されれば成功。

---

### 6.3 手動 UID 入力（上級者向け）

> ⚠️ **注意**：現時点の Goggle 公式リリースファームウェアにはバグがあり、Goggle メニューから UID を読み取ることが事実上できません。**この方法は今のところ普通のユーザーには使えません。** 将来的にゴーグルファームウェアが修正されたら使える方法として記載しています。

**理屈の上での手順**：

1. Goggle の **メニュー → ELRS** を選択すると、`Bind` の行に `UID: xxx,xxx,xxx,xxx,xxx,xxx` という6つの数字が表示されます。
2. アプリの設定シート → **デバイス** → **ゴーグルペアリング** へ。
3. **モード** ピッカーで **手動 UID** を選択。

   <p align="center">
     <img src="images/pairing-configure-manual-uid-ja.png" alt="ペアリング — 手動 UID モード" width="360" />
   </p>

4. **1 つの入力フィールド** にカンマ区切りで 6 つの数字を入力します。下の `Parsed:` 行に 16 進形式で UID が出るので、Goggle 画面の数字と見比べて確認できます。
5. **UID を適用** をタップ → 切り替えと検証を経て完了。
6. **動作確認**：設定 → **デバイス** → **OSD レイアウト** を開く。Goggle にプレビューが自動表示されれば成功。

---

### 6.4 既知の bind phrase を使う

**こういう人向け**：ExpressLRS Configurator で **プロポの Backpack と Goggle の ELRS Backpack の両方** に、同じ bind phrase を焼き込んだファームウェアを書き込んだことがある人。その bind phrase を控えている（または覚えている）。

#### 手順

1. アプリの設定シート → **デバイス** → **ゴーグルペアリング** へ。
2. **モード** ピッカーで **バインドフレーズ** を選択。

   <p align="center">
     <img src="images/pairing-configure-bind-phrase-ja.png" alt="ペアリング — バインドフレーズモード" width="360" />
   </p>

3. テキストフィールドに、ELRS Backpack に書き込んだのと同じ bind phrase を入力。下の `UID:` 行に MD5 から導出された UID（16 進）が出るので、適用前に確認できます。
4. **UID を適用** ボタンをタップ。
5. 状態バナーが切り替えと検証を経て完了するのを待ちます 🎉

   <p align="center">
     <img src="images/pairing-success-banner-ja.png" alt="ペアリング成功時の緑バナー — Pairing works — lap times will appear on this goggle." width="360" />
     <br />
     <em>成功時はこの緑バナーが出ます（4 つの方法すべて共通）</em>
   </p>

6. **動作確認**：設定シート → **デバイス** → **OSD レイアウト** を開く。ページを開いた瞬間にプレビューが Goggle に自動表示されれば bind 成功です 🎉

---

### 動作確認

bind が成功したら、**設定 → デバイス → OSD レイアウト** ページを開いて確認します。

<p align="center">
  <img src="images/osd-preview-ja.png" alt="OSD レイアウトのプレビュー — 同じ 4 行が自動でゴーグルにプッシュされる" width="360" />
</p>

開いた瞬間に、現在のレイアウト設定に基づいたプレビュー（上の画面上部の 4 行のダミー文字）が **自動的に Goggle にも送られて表示** されます。**iPhone のプレビュー欄と Goggle の OSD に同じ 4 行が見えれば、iPhone → M5StickS3 → Goggle の通信路すべてが正常** です 🎉

Goggle に何も出ないときは [Chapter 6 の判定フロー](#判定フローチャートあなたはどれ) を最初からやり直してください。

> 💡 **テスト OSD を送信** ボタンも同じ画面にあります。タップすると **現在時刻** が Goggle に 1 回送られます（毎回タップする度に更新されるので、パケットが届いているのが目で見て分かります）。プレビューを片付けたいときは横の **OSD をクリア** をタップ。

### 自動ロールバック機能

bind の途中で何か失敗したとき（verify で Goggle から応答が返ってこないなど）、HDZap は **自動的に元の UID に戻します**。「ゴーグルが新しいペアリングを受け入れませんでした。前のペアリングに戻しました。」というバナーが出ます。

また、**ゴーグルペアリング** 画面の **前のゴーグルに戻す** ボタンを使えば、いつでも前の UID に戻せます。

### うまくいかないとき

- **OSD レイアウトを開いても（または テスト OSD を押しても）Goggle に何も出ない**
  1. Goggle ファームウェアが v1.5.5 以上か再確認 → これが最頻原因
  2. Goggle との距離は近いか（数 m 以内推奨）
  3. もう一度 「UID を適用」を押してみる
  4. 別の bind 方法（6.1 / 6.2 / 6.4）を試す
- **`確認中…` のまま進まない**：30 秒待ってもダメなら自動でロールバックします。Goggle の電源確認、ファームウェアバージョン確認をやり直してください。

---

## 7. フライトバッテリーテレメトリー

M5StickS3 がパイロットのプロポから CRSF Battery テレメトリーを受信している間、HDZap は **メイン画面** にリアルタイムでバッテリー情報を表示し、レース後の確認用にデータを記録します。

### ライブ VBAT ストリップ（メイン画面）

<p align="center">
  <img src="images/timer-running-ja.png" alt="プログレスバーの上に緑の VBAT ストリップが表示されたメインタイマー" width="360" />
</p>

セッションバーの上にストリップが表示されます。

- **ステータスドット**：緑 = データ受信中、琥珀色 = 信号が途切れた（電源 OFF・圏外・プロポ側でテレメトリーを無効化）、非表示 = まだデータなし
- **電圧**（V）
- **消費 mAh**
- **残量 %** + プログレスバー（プロポ側が値を「不明」と報告している場合は非表示）

デバイスへの接続後にテレメトリーが1つも届いていない場合、ストリップは完全に非表示になります。

### レース後（履歴詳細画面）

<p align="center">
  <img src="images/history-detail-ja.png" alt="VBAT 電圧推移チャート付きの履歴詳細画面" width="360" />
</p>

レース後、履歴一覧から詳細を開くと **VBAT** セクションが表示されます。

- **Start / Min / End** 電圧ラベルとサンプル数
- レース時間に対する電圧推移チャート（ラップ境界マーカー付き）

共有ボタンで生成するリザルトカード画像にも、VBAT チャートが自動で含まれます。生データ（電圧・電流・消費 mAh・残量 %）を CSV で書き出すには、詳細画面のツールバー右端にある **バッテリーアイコン** をタップします。

### VBAT データの前提条件

以下の3つがすべて揃っている必要があります。

1. **プロポ側で ELRS Backpack テレメトリーを有効** にしていること：EdgeTX の ExpressLRS Lua スクリプトで **Backpack → Telemetry** を **ESPNOW** に設定する。
2. **プロポと Goggle が bind 済み** であること — プロポの bind ブロードキャストがプロポの識別情報として使われます。
3. **TX UID キャプチャを一度以上実行済み** であること（[6.2 TX UID キャプチャ](#62-tx-uid-キャプチャプロポで-bind-済みの-goggle) で実施）。これによりプロポの送信元 MAC が M5StickS3 のフラッシュに保存されます。一度保存すれば再起動後も有効です。ただし Web Flasher で「完全初期化する」を使って書き直すと消えます。

> ⚠️ [新規ペアリング（6.1）](#61-新規ペアリング) や [バインドフレーズ（6.4）](#64-既知の-bind-phrase-を使う) でペアリングした場合、プロポ送信元フィルターは設定されません。VBAT を有効にするには、ゴーグルペアリングはそのままで TX UID キャプチャを一度実行してください。

---

## 8. レースする

bind ができたら、いよいよ走らせます。

### レース設定

1. アプリ画面右上の歯車アイコン → 設定シートを開く。
2. シート上部の **フォーマット** セクションで **レース時間**（既定 90 秒）と **目標ラップ数** を調整（**目標ペース** は自動計算）。

   <p align="center">
     <img src="images/settings-format-ja.png" alt="フォーマットセクション — レース時間 / 目標ラップ数 / 目標ペース" width="360" />
   </p>

3. 設定シートを閉じる。

### 走らせる

<p align="center">
  <img src="images/timer-ready-ja.png" alt="レース開始前の READY 状態 — ラップは空、START ボタンが大きく表示" width="360" />
  <br />
  <em>レース開始前の READY 状態 — START をタップして開始</em>
</p>

1. メイン画面の **START ボタン** をタップ。タイマーが動き出します。
2. パイロットがゴール線を越えるたびに **LAP ボタン** をタップ。

   <p align="center">
     <img src="images/timer-running-ja.png" alt="レース中 — LAP ボタン、埋まっていくラップ表、VBAT ストリップ" width="360" />
     <br />
     <em>レース中 — 4 ラップ記録済み、現ラップが進行中、VBAT ストリップは緑（LIVE）</em>
   </p>

3. レース時間（既定 90 秒）に達すると、ボタンの表示が **`FINAL`** に変わります。**最後のラップを `FINAL` ボタンでタップ** することでレースが終了します（自動では終わりません）。
4. レースを途中で打ち切りたい場合は **STOP** ボタン。

### レース終了後

<p align="center">
  <img src="images/timer-done-ja.png" alt="レース後の DONE 状態 — RESET / DONE / SHARE ボタン" width="360" />
  <br />
  <em>レース後の DONE 状態 — 結果表示、共有ボタン有効</em>
</p>

レースが終わると（FINAL を記録、もしくは1ラップ以上記録された後 STOP）：

- ボタンの表示が **DONE**（無効）になり、左右に **RESET** と **SHARE** が現れます
- レースは自動で履歴に保存されます
- 上部のステートピルが **DONE** に切り替わり、ラップ表でベストラップがハイライトされます
- **SHARE** をタップするとリザルトカード画像が生成されて iOS の共有シートが開きます（[§9 レースのあとに](#9-レースのあとに) 参照）
- **RESET** をタップすると次のレース用に画面をクリア

### Goggle 側の OSD 表示

レース中、Goggle 画面下部に最大 4 行のオーバーレイが出ます（**設定 → デバイス → OSD レイアウト** で各行を表示／非表示にしたり、配置や縦位置を変えたりできます）。各行はデフォルトで 50 列グリッドの中央寄せ。

**レース開始前（READY）**：

<pre style="text-align: center;"><code>READY
RACE 90
5LAPS @ 18.00</code></pre>

**レース中（ラップ記録時）**：

<pre style="text-align: center;"><code>TIME LEFT 67
LAP 3 23.456
AVG 22.123 PACE 5L
D-1.234 BANK +0.5/L</code></pre>

**ペースぴったりのとき**（diff が ±0.005 秒以内）は最後の行が `ON TARGET` 表示になります：

<pre style="text-align: center;"><code>D+0.00 ON TARGET</code></pre>

**レース後（DONE）**：

<pre style="text-align: center;"><code>DONE
3LAPS 247.36
AVG 82.45 BEST 81.78</code></pre>

各フィールドの意味：

- **TIME LEFT**：残り時間（秒）
- **LAP N**：直近のラップ番号と時刻（秒）
- **AVG / PACE**：これまでの平均と、現在のペースで何ラップ走れるか
- **D±x BANK / NEED / ON TARGET**：目標ペースとの差。BANK は貯金、NEED は不足、ON TARGET は目標どおり。`/L` は 1 ラップあたりの差 — 残りの目標ラップに差を割り振った値なので、目標ラップ数に到達すると行から消え、`D±x` の合計だけになります。同じタイミングでアプリ側の Need / Bank 列も `Split —` になり、レースが終わったあとも同様です（もう飛べない周回に割り振った補正は助言になりません）

### フライト中のヒント

- **音声**：設定で **音声読み上げ** を ON にしておくと、ラップ毎に iPhone が読み上げます。タイムのほか、目標ペースとの差も追加できます。
- **ハプティック**：LAP / START 時に iPhone が振動するので、画面を見なくても押せたか確認できます。
- **ベストラップ更新**：自動的にハイライト表示されます（星マーク + アクセントカラー）。

---

## 9. レースのあとに

### 共有する

タイマー画面の **SHARE ボタン**（レース終了後に表示 — [§8 のレース後スクショ](#レース終了後) 参照）をタップすると、レース結果をまとめたリザルトカードが画像として生成され、iOS の標準共有シートが開きます。画像として保存、SNS 投稿、メッセージ送信などができます。

リザルトカードに含まれる情報：

- ラップ数（大きく表示）
- 合計時間
- ペース、平均タイム、ベストラップ
- ラップ表
- **VBAT 電圧チャート**（フライトバッテリーテレメトリーが記録されている場合のみ — [7 章](#7-フライトバッテリーテレメトリー) 参照）

### 履歴を見る

<p align="center">
  <img src="images/history-list-ja.png" alt="過去のレースが新しい順に並ぶ履歴シート" width="360" />
  <br />
  <em>履歴シート — 新しい順、各行は ラップ数・合計・推移スパークライン・ベスト</em>
</p>

1. メイン画面右上の **時計アイコン** をタップ → 履歴シートが開きます。
2. 過去のレースが新しい順に並びます。各行に **ラップ数・合計タイム・ラップ推移スパークライン・ベストラップ** が表示されます。
3. 行をタップすると詳細画面へ遷移。

<p align="center">
  <img src="images/history-detail-ja.png" alt="履歴詳細 — ラップ別の表、推移、VBAT チャート" width="360" />
  <br />
  <em>履歴詳細 — ラップ別の内訳、推移スパークライン、VBAT チャート（記録されている場合）</em>
</p>

詳細画面はリザルトカードと同じレイアウトに加え、フライトバッテリーテレメトリーが取れているレースでは下部に VBAT チャートが表示されます。ツールバー右端の **バッテリーアイコン** をタップすると、VBAT 生サンプルを CSV としてエクスポートできます。

### 削除する

- **個別削除**：履歴一覧で行を左にスワイプ → 削除。
- **全削除**：履歴画面右上のメニュー（…）→ 「全て削除」。確認ダイアログが出ます。

---

## 10. Premium ボイス（サブスクリプション）

無料のラップ実況は iPhone 標準の音声を使います。**HDZap Premium** を契約すると、AWS Polly と Microsoft Azure のクラウド AI 音声（英語・日本語合わせて 30 以上）に切り替えられます。

<p align="center">
  <img src="images/13-paywall-ja.png" alt="HDZap Premium サブスク登録シート" width="320" />
</p>

> 💡 **Premium ボイスは契約しなくてもすべて試聴できます。** 実際のレース中で使うときだけ契約が必要です。

### Premium でできること

- **30 以上の音声**（英語・日本語、プロバイダ別にグループ化）
- **数字の自然な読み上げ**：`12.34` を「ジューニーテンサンヨン」のように一文字ずつではなく、自然な発話で読み上げ
- **放送品質の音声**：iPhone のスピーカーでも Bluetooth ヘッドホンでもクリアに聞き取れる
- **プロバイダ別の調整**：両プロバイダで速度スライダー、Azure ではピッチスライダーも有効
- **自動フォールバック**：オフライン時や電波が弱いときは自動でシステム音声に切り替わるので、レース中に無音になることはありません

### カタログを試聴する（契約不要）

1. 設定（⚙）→ **アプリ → ラップ実況** を開く。

   <p align="center">
     <img src="images/settings-app-ja.png" alt="設定 → アプリセクション — ラップ実況行" width="360" />
   </p>

2. **Premium ボイスを試聴** をタップ。

   <p align="center">
     <img src="images/audio-voice-system-ja.png" alt="Voice カードの「Premium ボイスを試聴」エントリー" width="360" />
     <br />
     <em>Voice カードの上部に <strong>Premium ボイスを試聴</strong> 行があります（非契約者だけ表示）</em>
   </p>
3. **AWS Polly** と **Azure** のセクションに分かれて全音声が並びます。行の **▶** をタップするとサンプルが再生されます。

   <p align="center">
     <img src="images/12-premium-voice-picker-locked-ja.png" alt="Premium ボイスピッカー（非契約状態）" width="320" />
   </p>

   - 音声の **名前** をタップ → サブスク登録シートが開きます（音声選択は有料アクション）
   - **▶** ボタンのタップは試聴だけで、選択は確定しません

### サブスクリプションに加入する

1. ピッカーから音声名をタップする、もしくはリスト上部のピンク帯の **Subscribe ›** をタップ。
2. サブスク登録シートが開きます（上の画像）。
3. **月額** または **年額** を選択し、Face ID / Touch ID で確定。決済は Apple が処理します（アプリはカード情報を一切受け取りません）。
4. 購入が完了するとサブスク登録シートは自動で閉じます。これで音声の選択ができるようになり、ラップ実況画面の **エンジン** ピッカーに **Premium（クラウド）** が選べるようになります。

### レース中に Premium ボイスを使う

契約後は以下の手順で使えます：

1. **設定 → アプリ → ラップ実況**。
2. **エンジン** を **Premium（クラウド）** に切り替え。
3. **Premium ボイス** をタップしてカタログから選択（行に現在の選択が表示されます）。

   <p align="center">
     <img src="images/audio-voice-premium-ja.png" alt="Premium エンジン選択時の Voice セクション" width="360" />
   </p>

4. **速度** スライダー（Azure は **ピッチ** も）で調整。
5. **音声テスト** で現在の設定を試聴。

Premium に切り替えてから初めて設定シートを閉じたタイミングで、固定フレーズ（「ラップ 1」「ベストラップ」「カウントダウン数字」など）がローカルにキャッシュされます。以降はネットワーク往復なしで即時再生。レース中の可変フレーズ（ラップタイム）はライブで合成されます。

### 新しい端末で復元する

すでに契約済みで iPhone を新調した場合は、サブスク登録シートの一番下の **購入を復元** をタップしてください。Apple がアクティブなサブスクリプションをアプリに再配信します。

### サブスクリプション詳細

- 月額または年額の **自動更新**、Apple ID 経由で課金
- 解約は **iOS 設定 → Apple ID → サブスクリプション** からいつでも可能
- 価格は地域別。サブスク登録シートには現在の Apple ID のロケールに合わせた価格が表示されます
- Apple の標準サブスクリプション返金ポリシーに準拠

### うまくいかないとき

- **Premium を選んでいるのにラップコールがシステム音声に聞こえる**：設定 → アプリ → ラップ実況 → **Premium ボイスを試聴** をタップ、または画面下部に赤いエラーがないか確認。よくある原因：オフライン、別の Apple ID で復元、契約期限切れ。
- **最初の 1 ラップだけ遅延、以降は即時**：通常のコールドキャッシュ動作。設定シートを閉じるタイミングで固定フレーズのプリウォームが走るので、レース前に一度設定シートを開閉するとプリウォームが完了します。

---

## 11. 設定リファレンス

### フォーマット

<p align="center">
  <img src="images/settings-format-ja.png" alt="フォーマットセクション" width="360" />
</p>

- **レース時間**：60〜180 秒（5 秒刻み）
- **目標ラップ数**：例 5L
- **目標ペース**：レース時間と目標ラップ数から自動計算（読み取り専用）

### デバイス → ブリッジを使う

<p align="center">
  <img src="images/settings-device-ja.png" alt="デバイスセクション（ブリッジ ON）" width="360" />
  <br />
  <em>ブリッジ ON で接続済み — ドリルダウンが表示される状態</em>
</p>

- **ブリッジを使う**：M5StickS3 ブリッジ連携のマスタースイッチ。**新規インストール時は OFF**。M5StickS3 を持っている場合は ON にすると、下に **M5StickS3** / **ゴーグルペアリング** / **OSD レイアウト** の 3 つの行が表示され、初回 ON 時に iOS の Bluetooth 利用許可ダイアログが出ます。OFF のままにすると 3 行は隠れ、代わりに「ゴーグル OSD にラップタイムを映すにはブリッジが必要」という案内が表示されます。
- すでに以前のバージョンでゴーグルとペアリング履歴がある端末では、アップグレード後も自動で ON のままになります（既存の設定を維持）。

<p align="center">
  <img src="images/settings-device-standalone-ja.png" alt="デバイスセクション（ブリッジ OFF）" width="360" />
  <br />
  <em>ブリッジ OFF — ドリルダウンは隠れ、フッターヒントだけ表示</em>
</p>

### デバイス → M5StickS3（接続）

**ブリッジを使う** が ON のときだけ表示。タップするとドリルダウンします。

<p align="center">
  <img src="images/connection-connected-ja.png" alt="接続 — 接続済みカード" width="360" />
</p>

- **接続済み** カード：デバイス名・ステータスドット・**切断** ボタン・バッテリ %・フライトパックテレメトリーの表示・アプリとファームのバージョンを並べた行
- **Bluetooth 名**（接続中だけ表示、カードの下）：M5StickS3 の名前を変更する画面に入ります。UTF-8 で最大 20 バイト、保存後 1 度だけ自動再起動し、iPhone も自動で繋ぎ直します。詳細は [Chapter 5 → M5StickS3 の名前を変更する（任意）](#m5sticks3-の名前を変更する任意)。

<p align="center">
  <img src="images/connection-other-devices-ja.png" alt="接続 — その他のデバイスカード" width="360" />
</p>

- **その他のデバイス**：周辺の M5StickS3。各行に **接続** ボタン。**スキャン** を押すまでは空欄

<p align="center">
  <img src="images/connection-scan-ja.png" alt="接続 — スキャンボタン" width="360" />
</p>

- **スキャン** ボタン：周辺の M5StickS3 を再スキャン

### デバイス → ゴーグルペアリング

モード切り替えで「バインドフレーズ／手動 UID／新規ペアリング」のフォームを切り替えます。**TX UID キャプチャ** も同じ画面の下にあります。詳しいワークフローは [Chapter 6](#6-digital-fpv-goggle-と-bind-する)。

<p align="center">
  <img src="images/pairing-current-uid-ja.png" alt="ペアリング — 現在の UID カード" width="360" />
</p>

- **現在の UID**：M5StickS3 にいま入っている UID（10 進と 16 進を並列表示）

<p align="center">
  <img src="images/pairing-configure-bind-phrase-ja.png" alt="ペアリング — モード設定カード（バインドフレーズモード）" width="360" />
</p>

- **モード設定**（モードピッカー + フォーム）：**バインドフレーズ** / **手動 UID** / **新規ペアリング** から選択。下のテキストフィールドとボタンは選んだモードに合わせて変化（各モードのスクショは [§6.1](#61-新規ペアリング) / [§6.3](#63-手動-uid-入力上級者向け) / [§6.4](#64-既知の-bind-phrase-を使う) を参照）
- **UID を適用 / 新しいゴーグルとペアリング**：選んだフローを実行。切り替え → 検証 → 完了 / 自動ロールバックと進みます
- **前のゴーグルに戻す**（適用後にのみ表示）：直前の UID に巻き戻すボタン

<p align="center">
  <img src="images/pairing-tx-uid-capture-ja.png" alt="ペアリング — TX UID キャプチャカード" width="360" />
</p>

- **TX UID キャプチャ開始**：パッシブスニフを開始（[Chapter 6.2](#62-tx-uid-キャプチャプロポで-bind-済みの-goggle) で使う）。これがアームされた状態で EdgeTX 側で Bind を押します

### デバイス → OSD レイアウト

ゴーグルの OSD のライブエディタ。画面上部に 4 行プレビューがあり、変更はリアルタイムでゴーグルにプッシュされるので、レースを走らせなくても見た目を確認できます。

<p align="center">
  <img src="images/osd-preview-ja.png" alt="OSD レイアウト — プレビューカード" width="360" />
</p>

- **プレビュー**：実際にゴーグルに送られる 4 行ブロックの内容。現在の配置と表示行の設定が反映され、下のコントロールを変えるとリアルタイムで更新

<p align="center">
  <img src="images/osd-position-ja.png" alt="OSD レイアウト — 上端の行スライダー" width="360" />
</p>

- **上端の行** スライダー：18 行のゴーグル画面のどこに OSD ブロックを置くか（1 = 最上、デフォルト = 下端揃え）。表示行を減らすと自動でスライダーの可動範囲も縮むので、ブロックが画面外に落ちることはありません

<p align="center">
  <img src="images/osd-alignment-ja.png" alt="OSD レイアウト — 配置ピッカー" width="360" />
</p>

- **配置**：左 / 中央 / 右。すべての可視行に適用

<p align="center">
  <img src="images/osd-show-rows-ja.png" alt="OSD レイアウト — 表示する行のトグル" width="360" />
</p>

- **表示する行**：**残り時間 / ラップ / ペース / ペース差** を個別に表示／非表示。隠した行は詰めて表示されるのでブロックは常にコンパクト。右端のハンドルをドラッグして順序の入れ替えも可
- **テスト OSD を送信**（SHOW ROWS カードの下）：iPhone の現在日時をゴーグルに 1 回だけ送る。タップごとに時刻が更新されるのでパケットが届いているか目視で確認できます
- **OSD をクリア**：ゴーグルのオーバーレイバッファを消す
- **レイアウトをリセット**：エディタを既定値（下端揃え・中央配置・全行表示）に戻す

### アプリ → ラップ実況

<p align="center">
  <img src="images/audio-announcement-ja.png" alt="ラップ実況 — Announcement カード" width="360" />
</p>

Announcement セクション（両エンジン共通）：

- **音声読み上げ**：読み上げ全体のマスタースイッチ。スタートの合図・ラップ実況・カウントダウン・セッション残り 0 秒の瞬間に鳴る「ファイナルラップです」（言語が英語の場合は "Last lap!"）・レース終了サマリーまで、すべてここで止まります。
- **ラップタイムを読み上げる**：既定 ON。各ラップのあとにラップ番号とタイムを読み上げます（「ラップ3、12.34」）。OFF にすると、ペース・ベストラップ・カウントダウンの合図はそのままに、タイムだけを外せます — タイムは画面に出ているので、外すと 1 回のコールが大幅に短くなります。
- **ベスト更新時に「ベストラップ」と読み上げる**：新ベスト時に読み上げに「ベストラップ」を付ける。上の設定とは独立しているので、ラップタイムを OFF にしても鳴ります
- **目標ペースとの差を読み上げる**：既定 OFF。ON にすると、目標達成に必要な短縮量または貯金できている時間を、残り目標ラップ1周あたり小数第1位まで追加で読み上げます（OSD の Need / Bank と同じ計算）。実況は短さを優先して「0.2秒、不足」「0.2秒、余裕」となり、目標どおりの場合や1周あたりの差が0.0秒に丸まる場合は「ペースちょうど」と読み上げます。丸まる範囲では OSD が NEED / BANK のままでも音声は「ペースちょうど」になります。目標ラップ数に到達した後は、差を割り振る残り周回がないため何も追加しません
- **残り秒数をカウントダウンする**：既定 OFF。ON にすると、セッション終了直前を選択中のボイスでカウントダウン（日本語は「じゅう、きゅう…」、英語は "ten, nine, ..."）。ラップ実況の途中に来た数字は、待たせずに読み飛ばします（時計とズレないため）。**目標ペースとの差を読み上げる** を ON にすると実況が長くなる分、終盤で飛ぶ数字が少し増えます。Premium 音声も同じです — 数字どうしは重ねて読めますが、ラップ実況が始まると鳴っている数字は打ち切られ、実況が終わるまでの数字は読み飛ばされます
- **開始秒数**：5〜15 秒。既定 10。**残り秒数をカウントダウンする** が ON のときだけ表示

ラップ実況の 3 つのスイッチ — **ラップタイムを読み上げる**、**ベスト更新時に「ベストラップ」と読み上げる**、**目標ペースとの差を読み上げる** — は自由に組み合わせられます。ラップタイムを OFF、目標ペースとの差を ON にすると最小構成になり、各ラップで「0.2秒、不足」が、ベスト更新ラップではその前に「ベストラップ」が聞こえます。ベストラップも OFF にすれば、残るのはペースの数値だけです。

この構成には注意点がひとつあります。ペースの数値は残りの目標ラップに差を割り振った補正なので、目標ラップ数に到達すると読み上げが止まります。ラップタイムが OFF だと他に読むものがないため、そこから先のラップは無音になります。目標ラップ数を超えて飛ぶことが多いなら、**目標ラップ数** を上げるか、ラップタイムを ON のままにしてください。

ラップ実況の 3 つをすべて OFF にすると、ラップ間は静かになります。スタートの合図・カウントダウン・「ファイナルラップです」・終了サマリーはそのまま鳴ります。

<p align="center">
  <img src="images/audio-announcement-countdown-ja.png" alt="残り秒数をカウントダウンする ON 時 — 開始秒数ステッパーが表示" width="360" />
  <br />
  <em>カウントダウン ON 状態 — 下に <strong>開始秒数</strong> ステッパーが現れる</em>
</p>

<p align="center">
  <img src="images/audio-voice-system-ja.png" alt="Voice セクション — システムエンジン" width="360" />
  <br />
  <em>システムエンジン — iPhone 標準の音声を使う</em>
</p>

Voice セクション、両エンジン共通：

- **言語**：日本語、英語など。変更すると両エンジンの選択中ボイスが既定にリセットされます
- **エンジン**：**システム**（iPhone 標準音声、無料）または **Premium（クラウド）**（HDZap Premium サブスクリプション — [Chapter 10](#10-premium-ボイスサブスクリプション) 参照）。非契約者には **Premium — サブスク登録 ›** と表示され、タップするとエンジンを切り替えるのではなく試聴ピッカーへ遷移します

システムエンジンの設定：

- **音声**：システム標準 + インストール済みの追加ボイス
- **速度**：読み上げ速度
- **ピッチ**：声の高さ

<p align="center">
  <img src="images/audio-voice-premium-ja.png" alt="Voice セクション — Premium エンジン" width="360" />
  <br />
  <em>Premium エンジン — クラウド AI 音声</em>
</p>

Premium エンジンの設定（アクティブな契約が必要）：

- **Premium ボイス**：プロバイダ別にグループ化されたカタログにドリルダウン。試聴フローは [Chapter 10](#10-premium-ボイスサブスクリプション) を参照
- **速度**：SSML 経由で Polly と Azure の両方に適用
- **ピッチ**：SSML 経由、Azure 音声のみ有効（Polly Neural はピッチ非対応）

両エンジン共通：

- **音声テスト**：現在の設定で読み上げを試す
- **リセット**：ラップ実況の設定を初期化（エンジン別の音声・速度・ピッチも含む）

### アプリ → 外観

<p align="center">
  <img src="images/settings-app-ja.png" alt="アプリセクション — ラップ実況 + 外観行" width="360" />
</p>

- **ハイライト色** スライダー（外観ドリルダウン内）：UI のテーマ色を 0〜360° で変更

### 情報

<p align="center">
  <img src="images/settings-about-ja.png" alt="情報セクション — アプリ + ファームのバージョン" width="360" />
</p>

- **アプリのバージョン**：HDZap アプリのバージョン。常に表示
- **ファームウェア**：M5StickS3 の現行ファームウェアバージョン。接続後に表示されます。アプリと大きく食い違っている場合は **赤字** で警告が出るので、その場合は Web Flasher で M5StickS3 を再書き込みしてください。同じ情報は **設定 → デバイス → M5StickS3** の **バージョン** 行でも見られます

---

## 12. うまくいかないとき（トラブルシューティング）

### M5StickS3 関連

| 症状 | 対処 |
|---|---|
| LCD に何も出ない / 起動しない | Web Flasher で「完全初期化する」をチェックして再フラッシュ |
| Web Flasher で `ESP_TOO_MUCH_DATA` | Chrome を最新版に更新 |
| ポートが選べない | DFU モード入り直し（電源ボタン 2 秒長押し）、ケーブル交換（充電専用でないか確認） |
| Allow ダイアログが出ない | ブラウザを閉じて URL を開き直す |
| すべてリセットしたい | Web Flasher で「完全初期化する」にチェックして再フラッシュ |

### Bluetooth 関連

| 症状 | 対処 |
|---|---|
| デバイス一覧に M5StickS3 が出ない | iPhone 設定で HDZap の Bluetooth 許可を確認、M5StickS3 再起動 |
| 接続が切れる | iPhone と M5StickS3 の距離を縮める、iPhone の Bluetooth リストから一度 forget して再接続 |

### Goggle / OSD 関連

| 症状 | 対処 |
|---|---|
| Goggle に OSD が出ない | **まず Goggle Backpack のファームウェアが v1.5.5 以上か確認**（最頻原因）。次に [Chapter 6 の判定フロー](#判定フローチャートあなたはどれ) を最初からやり直す |
| OSD の文字が崩れる / 一部しか出ない | Goggle ファームウェアバージョンを再確認。次に周囲の 2.4 GHz 電波干渉（Wi-Fi、ドローン本体など）を疑う |
| bind 直後に OSD が出ない | アプリの「前のゴーグルに戻す」で前の状態に戻し、別の bind 方法を試す |

---

## 13. 付録

### 用語集

- **bind phrase**：UID を生成するもとになる人間可読な文字列。MD5 ハッシュの先頭 6 バイトが UID になる。
- **UID**：6 バイトの識別子。M5StickS3 と Goggle が同じ UID を持つと通信できる。先頭バイトのビット 0 は常に 0（マルチキャスト MAC を避ける制約）。
- **MSP / MSPv2**：MultiWii Serial Protocol。FPV 機材間でよく使われる軽量なバイナリ通信プロトコル。HDZap はこの v2 で OSD コマンドを送る。
- **OSD**：On-Screen Display。映像の上に重ねて表示される文字オーバーレイ。
- **ELRS（ExpressLRS）**：オープンソースのラジオコントロールリンク。受信機 / 送信機 / Backpack を含むエコシステム。
- **Backpack**：Goggle やプロポに付ける ESP32 モジュール（Digital FPV Goggle では内蔵）。映像信号とは別の制御チャネル。
- **ESP-NOW**：ESP32 がペアリング不要で使える独自のピアツーピア無線通信。Wi-Fi の物理層を流用。
- **BLE / GATT**：Bluetooth Low Energy / Generic Attribute Profile。iPhone と M5StickS3 間の通信に使う。

### 互換ハードウェア

公式にサポートしているのは **M5StickS3** のみです。他の ESP32 ボードへの対応はリクエスト次第で検討します。参考情報は [互換ボード一覧](https://github.com/saqoosha/HDZap/blob/main/docs/compatible-devices.md) にあります。

### 開発者向け技術詳細

- [README](https://github.com/saqoosha/HDZap)（リポジトリ全体の開発者向け説明）
- [docs/report.md](https://github.com/saqoosha/HDZap/blob/main/docs/report.md)（MSPv2 / ESP-NOW / ELRS bind プロトコル調査）
- [docs/architecture.md](https://github.com/saqoosha/HDZap/blob/main/docs/architecture.md)（システム構成）

### ライセンス・コントリビューション

- ソースコード：[GitHub リポジトリ](https://github.com/saqoosha/HDZap)
- バグ報告・機能要望：[Issues](https://github.com/saqoosha/HDZap/issues)

---

<p align="center">
  <em>Happy racing!</em> 🏁
</p>
