# HDZap TTS Quality Test

実機ベンチマーク：HDZap のラップ実況フレーズで主要クラウド TTS の **日本語＋英語**音質をブラインド試聴する。

ぼくが作った。

## 何ができる？

- `phrases.json` の HDZap 実フレーズ（"ラップ3、12.34、ベストラップ" 等）を
- ElevenLabs / Gemini / Google Cloud / Polly / OpenAI / fish.audio / Cartesia / Inworld / Murf / xAI Grok の **10プロバイダ** で同時生成
- `outputs/{provider}/{voice}/{phrase_id}.mp3` に並べて保存
- `compare.html` で側by-side試聴＋1-5スコアリング→CSVエクスポート

## セットアップ

```bash
cd tts-quality-test

# 1. uv で Python 環境（推奨）
uv sync

# 2. API キー
cp .env.example .env
# .env を編集。持ってる鍵だけ入れればOK、無いものは自動スキップされる
```

### ⚠️ シェル環境変数の落とし穴

`~/.zshrc` / fish config / direnv 等で `OPENAI_API_KEY` 等を export してると **`.env` 作らなくてもツールが拾って実 API を呼ぶ**。意図せず課金されるリスクあり。

**対策**:
- ツール起動時に `⚠ provider: using shell-exported X (not in .env)` という警告が出る → そのproviderが本当に走らせたいか確認
- 特定 provider を強制的に止めたい時は `.env` でキーを空文字に設定:
  ```
  OPENAI_API_KEY=
  ```
  `load_dotenv(override=True)` で shell 値が空文字で上書きされ、provider は skip される

### 必要な鍵（最低限）

すべてオプション。持ってる分だけ走る。**ElevenLabs と Gemini と Polly があれば充分**な比較になる。

| 鍵 | 取得先 | 必須? |
|---|---|---|
| `ELEVENLABS_API_KEY` | https://elevenlabs.io/app/settings/api-keys | 推奨 |
| `GEMINI_API_KEY` | https://aistudio.google.com/apikey | 推奨（無料枠あり）|
| `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` | IAM ユーザーに `polly:SynthesizeSpeech` 権限 | 推奨 |
| `OPENAI_API_KEY` | https://platform.openai.com/api-keys | 推奨 |
| `GOOGLE_APPLICATION_CREDENTIALS` | service-account JSON のパス | 任意 |
| `FISH_AUDIO_API_KEY` | https://fish.audio/go-api/ | 任意 |
| `CARTESIA_API_KEY` | https://play.cartesia.ai/ | 任意 |
| `INWORLD_API_KEY` | https://platform.inworld.ai/ | 任意 |
| `MURF_API_KEY` | https://murf.ai/api | 任意 |
| `XAI_API_KEY` | https://console.x.ai/ | 任意 |

## 実行

```bash
# 全プロバイダ全フレーズ
uv run python tts_test.py

# 特定プロバイダだけ
uv run python tts_test.py --provider gemini --provider polly

# 日本語だけ
uv run python tts_test.py --lang ja

# 短いフレーズだけ（音声トークン節約）
uv run python tts_test.py --category lap_best --category fixed_cues

# 1プロバイダ・1ボイスに絞る（コスト確認用）
uv run python tts_test.py --provider elevenlabs_flash --voice-limit 1
```

### コスト感

デフォルト設定（全プロバイダ・全フレーズ・各プロバイダ2ボイス）で全体 **約 $0.30-$0.50** 程度。Inworld/Murf/Polly はほぼタダ、ElevenLabs と OpenAI で大半。

## 試聴

```bash
# 簡易 HTTP サーバー（CORS のため file:// では音声が読めない）
python -m http.server 8000
open http://localhost:8000/compare.html
```

ブラウザで:
1. フレーズごとに全プロバイダの音声を縦並びで聞き比べ
2. 各セルの **1-5 ボタン**で評価（自然さ・聴きやすさ・抑揚）
3. **⤓ Export ratings** で CSV ダウンロード
4. 後で集計してプロバイダ別平均スコアを出す

評価は `localStorage` に保存されるのでブラウザ再起動しても残る。

## 評価軸（推奨）

| スコア | 基準 |
|---|---|
| 5 | プロのアナウンサー、違和感ゼロ |
| 4 | 自然、たまに微妙だがレース実況として完璧 |
| 3 | わかる、AIだとわかるが許容範囲 |
| 2 | 機械的、長時間聞きたくない |
| 1 | 読み間違い・棒読み・致命的 |

**HDZap 用途の優先ポイント**:
- 「12.34」の数字読みが自然か（「じゅうにてんさんよん」を流暢に）
- 「ラップ」「ベストラップ」のカタカナがネイティブイントネーションか
- 短文（5-15文字）でも棒読みにならないか

## トラブルシュート

- **Gemini が 403**: API キーが TTS preview にアクセスできていない。AI Studio で `gemini-2.5-flash-preview-tts` モデルを有効化。
- **Polly が voice not found**: リージョンが `ap-northeast-1` 以外。`.env` で `AWS_REGION=ap-northeast-1`。
- **fish.audio が 404 voice**: reference ID が無効。Public Library で別ボイスを選んで `providers/fish_audio.py` の `id` を差し替える。
- **Inworld auth failed**: API キーは Base64 ペア（`Basic` 認証）形式が必要。Inworld dashboard の API キーをそのまま貼る。
- **xAI Grok が 404**: TTS API は 2026-03 以降のアカウント限定の可能性。プロビジョニング要確認。

## 結果の使い方

HDZap Premium のデフォルト provider を決めるエビデンスにする。スコア平均で上位 2-3 を選定 → 本番 Worker proxy の `provider-agnostic abstraction` に組み込み → ユーザー側で voice picker から選択可能に。
