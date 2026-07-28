# Need / Bank ラップ実況 実装計画

> **実装時の変更点（この計画からの逸脱）**
>
> 以下は実装・実機確認の結果、計画から意図的に変えた点。本文の該当箇所（仕様上の判断 3 / 5、文言表、タスク 3、受け入れ条件）は計画当時の記述のまま残してあるので、**仕様として読むならこの節が優先**。
>
> 1. **`.onTarget` では「ペースちょうど」/ `on pace` を読む**（計画では「何も追加しない」）。`splitState` は合計差（±0.005 秒）で判定するのに読み上げる数字は残り1周あたりの取り分なので、Need のまま「0.0秒」を読む状態が実機で発生した。無音にすると「機能が効いていない」と区別できないため、明示的に読む方に倒した。
> 2. **日本語は読点入りの「0.2秒、不足」/「0.2秒、余裕」**（計画では読点なし）。読点がないと合成音声が「秒不足」を連濁して「びょうぶそく」と読む。半角スペースでは分割されなかった。
> 3. **日本語のトグル名は「目標ペースとの差を読み上げる」**（計画では「Need / Bank を読み上げる」）。日本語として読めないため。英語ラベルは OSD の `NEED` / `BANK` 表記と揃えて据え置き。
> 4. **目標ラップ数に到達した後は接尾句を出さない。** `RaceMetrics.remainingLaps` は `max(1, …)` で下限1に張り付くため、到達後は `perLapSec` が累積差そのものになり「15.1秒、余裕」のような無意味な読み上げになる。
> 5. **`AudioSettingsView` の Reset には追加しない**（計画のタスク2は不採用）。Reset は Voice セクション限定というコード内の明示スコープがあり、`announceBest` / `countdownEnabled` も対象外。

**目的:** ラップ完了時の音声に現在の `Need` または `Bank` を追加できる設定を用意し、オペレーターやパイロットが iPhone や Goggle の OSD を見なくても、目標ペースとの差を把握できるようにする。

**アーキテクチャ:** Need / Bank の判定と残りラップあたりの差分計算は、引き続き `RaceMetrics` を唯一の正とする。`TimerView` はラップ実況の前にすでに `metricsSnapshot` を更新しているため、そのスナップショットを `LapAnnouncer` に渡し、音声専用のローカライズ済み接尾句を生成する。新しい設定は `LapAnnouncerDefaults` と `AudioSettingsView` で既存の「ベストラップ」設定の近くに配置する。BLE やファームウェアの変更は不要。

**技術要素:** Swift 5.9、SwiftUI、`@AppStorage`、AVSpeechSynthesizer、Premium クラウド TTS、String Catalog、iOS 18、xcodegen。

**要望:** OSD に表示される `Need` / `Bank` の内容を、ラップ実況でも読み上げられる設定を追加する。

**テスト方針:** 現在のアプリには Unit Test ターゲットがないため、新しい文章生成処理は小さな決定的ヘルパーに分離し、境界値を DEBUG assertion で検証する。その後、Xcode プロジェクトの再生成と Simulator ビルドを確認する。最後に、両言語・両音声エンジンで実機または Simulator の確認を行う。Premium では、完成した全文がキャッシュキーと Worker リクエストに使われることも確認する。

---

## 仕様上の判断

1. **任意機能とし、初期値は OFF にする。** 既存ユーザーは明示的に有効化するまで、従来の短い「ラップ N、タイム」という実況のまま利用できる。
2. **「ラップタイムを読み上げる」の配下に置く。** `Need / Bank を読み上げる` はラップ実況が有効な場合だけ表示し、既存のベストラップおよびカウントダウン設定の近くに配置する。
3. **OSD の符号ではなく、短い日本語で方向を伝える。** `RaceMetrics.perLapSec` は Need の場合に負、Bank の場合に正になるが、日本語音声では絶対値の後に「不足」または「余裕」を付ける。「1ラップあたり」や「ニード／バンク」は読まず、「0.2秒不足」「0.2秒余裕」と短く伝える。
4. **OSD と同じ小数第1位まで読む。** 実況を短く保ちつつ、OSD の `NEED` / `BANK` と同じ丸め結果を伝える。
5. **`.onTarget` では何も追加しない。** 要望の対象は Need / Bank であり、修正すべきペース差がないときに実況を長くしない。
6. **実況内の優先順位を維持する。** 「ラップ番号 → ラップタイム → 任意のベストラップ → 任意の Need / Bank」の順にする。これにより、ベスト更新は引き続きすぐ認識できる。
7. **1周目の Need / Bank は読み上げる。** 既存どおり1周目の「ベストラップ」は省略するが、Need / Bank は1周目からレース戦略に使えるため実況対象とする。
8. **レース終了時のサマリーは変更しない。** 終了後には調整対象となる残りラップがないため、最終実況は従来どおりラップ数・合計・ベストのみとする。

想定する読み上げ文言：

| 言語 | 状態 | 追加する文言の例 |
|---|---|---|
| 英語 | Need | `need 0.2 seconds per lap` |
| 英語 | Bank | `bank 0.2 seconds per lap` |
| 日本語 | Need | `0.2秒不足` |
| 日本語 | Bank | `0.2秒余裕` |
| 共通 | On target | 追加なし |

日本語は短さを優先し、「1ラップあたり」を音声には含めない。ただし、値の意味は従来どおり「残り目標ラップ1周あたりの不足／余裕」である。System 音声、Polly の Takumi または Kazuha、Azure の日本語音声を最低1つずつ試聴し、「0.2秒不足」「0.2秒余裕」が自然に聞こえることを確認する。

---

## タスク1: 設定値の追加と初期値登録

**対象ファイル:**
- 変更: `app/HDZap/Models/LapAnnouncer.swift`
- 変更: `app/HDZap/HDZapApp.swift`

- [ ] `LapAnnouncerDefaults` に `announceSplitKey`（例: `lapTTSAnnounceSplit`）と `defaultAnnounceSplit = false` を追加する。
- [ ] `HDZapApp` の起動時 `UserDefaults.register(defaults:)` に同じ初期値を登録する。
- [ ] `LapAnnouncerDefaults` の登録・リセット箇所をすべて検索し、必要な箇所に新しいキーを追加する。Defaults enum の外に同じ文字列を直接記述しない。
- [ ] 旧バージョンから更新し保存値が存在しない場合は `false` になり、ユーザーが明示的に変更した値は再起動後も保持されることを確認する。

## タスク2: ラップ実況設定画面への追加

**対象ファイル:**
- 変更: `app/HDZap/Views/Settings/AudioSettingsView.swift`
- 変更: `app/HDZap/Localizable.xcstrings`
- 必要な場合のみ変更: `app/HDZap/Utils/ScreenshotMode.swift`

- [ ] `@AppStorage(LapAnnouncerDefaults.announceSplitKey)` で新しい設定値をバインドする。
- [ ] Announcement セクションの `lapTTSEnabled` 条件内で、ベストラップ設定の直後に `Need / Bank を読み上げる` トグルを追加する。
- [ ] String Catalog に英語・日本語の翻訳と、Need / Bank が OSD に表示されるレースペース用語であることを説明する翻訳者向けコメントを追加する。
- [ ] 画面の「リセット」操作にこの設定を含め、仕様どおり初期値へ戻す。
- [ ] 「ラップタイムを読み上げる」を OFF にするとトグルは非表示になるが、保存済みの選択は破棄されないことを確認する。
- [ ] 見た目が変わるため、実装時に英語・日本語のラップ実況画面を撮影する。マニュアルの既存画像に変更箇所が含まれる場合は画像も差し替える。

## タスク3: 音声専用の Need / Bank フォーマッター

**対象ファイル:**
- 変更: `app/HDZap/Models/LapAnnouncer.swift`

- [ ] `RaceMetrics`、または必要最小限の `SplitState` と `perLapSec`、および `LapAnnouncerLanguage` を受け取り、任意の接尾句を返す決定的ヘルパーを追加する。
- [ ] `.need` / `.bank` では `abs(perLapSec)` を `RaceMetrics.seconds(..., decimals: 1)` または同等の POSIX 固定フォーマッターで整形する。`splitValue` は符号と画面用の `/L` 略記を含むため、そのまま音声に流用しない。
- [ ] `.onTarget`、非有限値、その他の不正値では `nil` を返し、`nan` や `infinity` が読まれないようにする。
- [ ] 言語ごとのヘルパー内で完成文を組み立て、System と Premium に同じ文を渡す。日本語は `0.2秒不足` / `0.2秒余裕` とし、「1ラップあたり」を追加しない。
- [ ] Need、Bank、On target、小数第1位への丸め、負のゼロ防止、両言語を DEBUG assertion で検証する。

## タスク4: 実際のラップ実況と音声テストへの組み込み

**対象ファイル:**
- 変更: `app/HDZap/Models/LapAnnouncer.swift`
- 変更: `app/HDZap/Views/TimerView.swift`

- [ ] `announceLap` が更新直後の `RaceMetrics?` スナップショットを受け取れるようにする。`LapAnnouncer` 内でレース計算をやり直したりタイマー状態を参照したりせず、引数として明示的に渡す。
- [ ] `announceLap` で既存のベストラップ設定と同様に新しい設定値を1回読み、任意の Need / Bank 接尾句を文章生成処理へ渡す。
- [ ] `TimerView.recordLap` では、`refreshMetricsSnapshot()` の後、別の状態遷移で置き換わる前に `metricsSnapshot` を渡す。現在の処理順で、スナップショットには記録直後のラップが含まれる。
- [ ] ベストラップと Need / Bank が互いに独立して、仕様どおりの順序で文章へ追加されるようにする。
- [ ] `announceTest()` は設定が ON のときだけ Need / Bank も試せるようにする。決定的なサンプル値を使い、「音声テスト」で実戦と同じ構成を確認できるようにする。
- [ ] `announceFinal`、カウントダウン、Start、Last lap、warm-keeper、キャンセル、音声重畳の挙動は変更しない。

## タスク5: Premium TTS とキャッシュの確認

**対象ファイル:**
- 確認: `app/HDZap/Models/Speech/PremiumSpeechSynthesizer.swift`
- 不具合が見つかった場合のみ変更: `app/HDZap/Models/Speech/PremiumSpeechSynthesizer.swift`

- [ ] 組み立てた全文が `speakAsync(text:...)` にそのまま渡ることを確認する。
- [ ] `TTSCache` のキーに全文が含まれ、Need / Bank あり・なしの音声が衝突しないことを確認する。
- [ ] 動的なラップタイムや Need / Bank は `fixedPrewarmPhrases` に追加しない。値の組み合わせが多く、事前取得すると通信量とストレージを浪費するため。
- [ ] 購読済みテストアカウントで、各言語について Polly と Azure の音声を最低1つずつ試聴する。プロバイダー固有の句読点調整が必要ならコードコメントに理由を残す。
- [ ] セッション途中で設定を切り替えた場合、再起動やキャッシュ削除なしで次のラップから反映されることを確認する。

## タスク6: エンドユーザーマニュアルの更新

**対象ファイル:**
- 変更: `docs/manual/en.md`
- 変更: `docs/manual/ja.md`
- 必要に応じて差し替え: `docs/manual/images/` 内の該当画像

- [ ] 両言語のラップ実況設定リファレンスに新しいトグルを追加する。
- [ ] 値の意味は「目標達成に必要な短縮量」または「貯金できている時間」の**残り目標ラップ1周あたり**である一方、実際の日本語音声は短さを優先して「0.2秒不足」「0.2秒余裕」と読むことを説明する。小数第1位まで読み、On target では省略する。
- [ ] 有効にすると該当する各ラップ実況が長くなることを明記し、最短の実況を優先する場合は OFF を推奨する。
- [ ] Premium のプライバシー説明を正確に保つ。Need / Bank の文言は現在の読み上げ文の一部としてクラウド TTS へ送られるが、レース履歴など追加のデータは送信されない。

## タスク7: ビルドと受け入れ確認

- [ ] Xcode プロジェクトを再生成し、意図しないプロジェクトファイル差分がないことを確認する。

  ```sh
  cd app && xcodegen generate
  git diff --exit-code -- HDZap.xcodeproj/project.pbxproj
  ```

- [ ] 利用可能な iOS Simulator 向けにビルドする。

  ```sh
  cd app && xcodebuild -scheme HDZap -destination 'generic/platform=iOS Simulator' build
  ```

- [ ] String Catalog の構造を検証する。

  ```sh
  # `plutil -lint` は拡張子から plist 形式と推測して必ず失敗する。JSON として検証する
  python3 -c "import json; json.load(open('app/HDZap/Localizable.xcstrings')); print('OK')"
  ```

- [ ] リポジトリの空白エラーを確認する。

  ```sh
  git diff --check
  ```

- [ ] ラップ実況を有効にし、以下の組み合わせを手動確認する。

  | 言語 | エンジン | Need | Bank | On target | Best + Need/Bank |
  |---|---|---:|---:|---:|---:|
  | 英語 | System | ✓ | ✓ | 省略 | 順序が正しい |
  | 日本語 | System | ✓ | ✓ | 省略 | 順序が正しい |
  | 英語 | Premium（Polly + Azure） | ✓ | ✓ | 省略 | 順序が正しい |
  | 日本語 | Premium（Polly + Azure） | ✓ | ✓ | 省略 | 順序が正しい |

- [ ] OFF では既存のラップ文章がバイト単位で変わらないこと、ON でも Start・カウントダウン・Last lap・最終サマリーに影響しないこと、1周目は Need / Bank を読み得るが「ベストラップ」は読まないことを確認する。
- [ ] OSD の差分行を非表示にしても音声はレイアウトではなくメトリクスから生成されるため、Need / Bank が読まれることを確認する。
- [ ] OSD / BLE 接続をすべて無効にしても読み上げられることを確認する。この機能は iOS 側で完結し、アプリ単体モードでも動作しなければならない。

---

## 対象外

- ファームウェア、BLE UUID、Characteristic、OSD レイアウトの変更。
- `Pace`、合計 `Diff`、平均ラップ、予測ラップ数の読み上げ。
- Need のみ、Bank のみを個別に選ぶ設定。
- あらゆるラップタイム / Need / Bank の組み合わせの動的な事前取得。
- `RaceMetrics` の計算方法や画面表示形式の変更。

## 受け入れ条件

- ラップ実況設定に、保存可能かつローカライズされた `Need / Bank を読み上げる` トグルがあり、初期値は OFF である。
- ON の場合、`.need` または `.bank` となる各ラップで、通常の実況に小数第1位までの差が追加され、日本語ではそれぞれ「0.2秒不足」「0.2秒余裕」の形式になる。「1ラップあたり」は読み上げない。
- `.onTarget` では追加文言がなく、不正な数値が読み上げられない。
- System と Premium が意味として同じ文章を使用し、英語・日本語とも自然に発音される。
- ベストラップ、カウントダウン、warm-keeper、レース終了処理、アプリ単体モード、BLE、OSD の既存挙動が変わらない。
- 英語・日本語マニュアルと該当スクリーンショットが、実装された設定を正確に説明している。
