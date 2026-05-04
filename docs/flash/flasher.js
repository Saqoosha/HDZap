// esptool-js is vendored under vendor/ rather than loaded from a CDN so the
// flasher cannot be silently substituted by a CDN compromise — Web Serial
// gives this script direct write access to the user's USB device.
// Pinned to 0.5.7: esp-web-tools v10.x ships the same major; 0.6.x has a
// known regression where compressed writeFlash to ESP32-S3 returns status
// 201 (ESP_TOO_MUCH_DATA). Bump only after re-verifying on real hardware.
import { ESPLoader, Transport } from "./vendor/esptool-js@0.5.7.js";

const PARTS = [
  { url: "firmware/bootloader.bin", offset: 0x0000, label: "ブートローダー" },
  { url: "firmware/partitions.bin", offset: 0x8000, label: "パーティションテーブル" },
  { url: "firmware/boot_app0.bin", offset: 0xe000, label: "ブートアプリ" },
  { url: "firmware/hdzap.bin", offset: 0x10000, label: "HDZap 本体" },
];

const SUPPORTED_CHIP = "ESP32-S3";

const $ = (id) => document.getElementById(id);
const states = ["idle", "working", "done", "error"];

function showState(name) {
  for (const s of states) {
    const el = $(`state-${s}`);
    if (el) el.hidden = s !== name;
  }
}

function setStatus(msg) {
  $("status-msg").textContent = msg;
}

function setProgress(pct, detail) {
  if (!Number.isFinite(pct)) {
    console.warn("[flasher] non-finite progress value:", pct);
    return;
  }
  const clamped = Math.max(0, Math.min(100, pct));
  $("progress-bar").style.width = `${clamped}%`;
  $("progress-pct").textContent = `${clamped}%`;
  $("progress-detail").textContent = detail || "";
}

function showError(msg, hint) {
  $("error-msg").textContent = msg;
  $("error-hint").textContent = hint || "";
  showState("error");
}

function uint8ToBinaryString(u8) {
  const CHUNK = 0x8000;
  let out = "";
  for (let i = 0; i < u8.length; i += CHUNK) {
    out += String.fromCharCode.apply(null, u8.subarray(i, i + CHUNK));
  }
  return out;
}

class NetworkError extends Error {
  constructor(message) {
    super(message);
    this.name = "FlasherNetworkError";
  }
}

class ChipMismatchError extends Error {
  constructor(message) {
    super(message);
    this.name = "ChipMismatchError";
  }
}

async function fetchBinary(url) {
  let r;
  try {
    r = await fetch(url, { cache: "no-store" });
  } catch (err) {
    throw new NetworkError(`${url} のダウンロードに失敗しました（ネットワークエラー）。`);
  }
  if (!r.ok) throw new Error(`${url} の取得に失敗しました（HTTP ${r.status}）`);
  const buf = await r.arrayBuffer();
  return uint8ToBinaryString(new Uint8Array(buf));
}

function humanizeError(err) {
  // Programmer errors — surface them honestly so they don't get reported as hardware faults.
  if (
    err instanceof TypeError ||
    err instanceof ReferenceError ||
    err instanceof RangeError ||
    err instanceof SyntaxError
  ) {
    return {
      msg: "内部エラーが発生しました（HDZap 側のバグの可能性）。",
      hint: `${err.name}: ${err.message}\nブラウザの開発者ツール（コンソール）に詳細が出力されています。`,
    };
  }

  if (err instanceof ChipMismatchError) {
    return {
      msg: err.message,
      hint: "HDZap は M5StickS3（ESP32-S3）専用です。別の ESP32 系ボードでは動きません。",
    };
  }

  if (err instanceof NetworkError) {
    return {
      msg: err.message,
      hint: "ネットワーク接続を確認してから「再試行」してください。",
    };
  }

  const msg = (err && err.message) || String(err);
  const lc = msg.toLowerCase();

  if (lc.includes("failed to connect") || lc.includes("timed out") || lc.includes("no serial data")) {
    return {
      msg: "M5StickS3 のブートローダーに接続できませんでした。",
      hint: "本体左側の電源ボタンを 2 秒長押しして、緑色 LED が点滅している状態（書き込みモード）にしてから再試行してください。USB-C ケーブルがデータ通信対応であることも確認してください。",
    };
  }
  if (lc.includes("access denied") || lc.includes("failed to open")) {
    return {
      msg: "シリアルポートを開けませんでした。",
      hint: "他のアプリ（PlatformIO のシリアルモニタなど）が同じポートを使っていないか確認してください。",
    };
  }
  if (
    lc.includes("chip not supported") ||
    lc.includes("unsupported chip") ||
    lc.includes("chip is esp")
  ) {
    return {
      msg: "このチップは HDZap に対応していません。",
      hint: "HDZap は M5StickS3（ESP32-S3）専用です。",
    };
  }
  if (lc.includes("status 201") || lc.includes("too much data")) {
    return {
      msg: "書き込み中に通信が不安定になりました。",
      hint: "ケーブルを差し直してから「再試行」してください。USB ハブを経由している場合は本体に直接挿すと安定します。",
    };
  }
  return {
    msg: "書き込み中にエラーが発生しました。",
    hint: `${msg}\nブラウザの開発者ツール（コンソール）に詳細が出力されています。`,
  };
}

async function disconnectQuiet(transport) {
  if (!transport) return;
  try {
    await transport.disconnect();
  } catch (err) {
    console.warn("[flasher] transport disconnect failed:", err);
  }
}

async function runInstall() {
  $("install-btn").disabled = true;

  const eraseAll = $("erase-all").checked;
  let transport = null;
  let esploader = null;
  let resetFailed = false;

  showState("working");
  setStatus("ポートを選択してください…");
  setProgress(0, "");

  try {
    let port;
    try {
      port = await navigator.serial.requestPort();
    } catch (err) {
      if (err && err.name === "NotFoundError") {
        // Browser-side cancel from the port-picker dialog. This is the only
        // expected NotFoundError source — re-throw any other for visibility.
        showState("idle");
        return;
      }
      throw err;
    }

    transport = new Transport(port, true);

    setStatus("ブートローダーに接続中…");
    setProgress(2, "（数秒かかることがあります）");

    esploader = new ESPLoader({
      transport,
      baudrate: 921600,
      romBaudrate: 115200,
      terminal: {
        clean: () => {},
        writeLine: (line) => console.log("[esptool]", line),
        write: (data) => console.log("[esptool]", data),
      },
    });

    const chipDescription = await esploader.main();
    const chipName = esploader.chip && esploader.chip.CHIP_NAME;
    console.log("Detected chip:", chipName, "/", chipDescription);

    if (chipName !== SUPPORTED_CHIP) {
      throw new ChipMismatchError(
        `このファームウェアは ${SUPPORTED_CHIP} 専用です（検出されたチップ: ${chipName || "不明"}）。`
      );
    }

    setStatus(`${chipName} を検出しました。ファームウェアをダウンロード中…`);
    setProgress(5, "");

    const fileArray = [];
    for (let i = 0; i < PARTS.length; i++) {
      const p = PARTS[i];
      setProgress(5 + Math.floor((i / PARTS.length) * 5), `${p.label} を取得中…`);
      const data = await fetchBinary(p.url);
      fileArray.push({ data, address: p.offset });
    }

    if (eraseAll) {
      setStatus("チップを完全消去中… (10〜20 秒かかります)");
      setProgress(10, "保存データもすべて消去します");
    } else {
      setStatus("書き込みを開始します…");
      setProgress(10, "保存データ（UID、設定）は保持されます");
    }

    await esploader.writeFlash({
      fileArray,
      flashSize: "8MB", // M5StickS3 fixed; matches firmware/platformio.ini board_build.flash_size
      flashMode: "keep",
      flashFreq: "keep",
      eraseAll,
      compress: true,
      reportProgress: (fileIndex, written, total) => {
        const filePct = total > 0 ? written / total : 0;
        const overall = 10 + Math.floor(((fileIndex + filePct) / PARTS.length) * 85);
        const part = PARTS[fileIndex];
        setStatus("書き込み中…");
        setProgress(
          overall,
          `${part.label} (${fileIndex + 1}/${PARTS.length}) — ${Math.floor(filePct * 100)}%`
        );
      },
    });

    setStatus("書き込み完了。再起動します…");
    setProgress(98, "");
    try {
      await esploader.after("hard_reset");
    } catch (err) {
      console.warn("[flasher] hard_reset after-hook failed:", err);
      resetFailed = true;
    }

    const resetHint = $("reset-failed-hint");
    if (resetHint) resetHint.hidden = !resetFailed;

    setProgress(100, "");
    showState("done");
  } catch (err) {
    console.error(err);
    const { msg, hint } = humanizeError(err);
    showError(msg, hint);
  } finally {
    await disconnectQuiet(transport);
    $("install-btn").disabled = false;
  }
}

function init() {
  if (!("serial" in navigator)) {
    $("browser-check").classList.add("show");
    $("install-btn").disabled = true;
    return;
  }

  $("install-btn").addEventListener("click", runInstall);
  $("retry-btn").addEventListener("click", () => {
    showState("idle");
  });
  $("restart-btn").addEventListener("click", () => {
    setProgress(0, "");
    showState("idle");
  });

  fetch("manifest.json", { cache: "no-store" })
    .then((r) => {
      if (!r.ok) throw new Error(`manifest HTTP ${r.status}`);
      return r.json();
    })
    .then((m) => {
      $("version").textContent = m.version || "unknown";
    })
    .catch((err) => {
      console.warn("[flasher] manifest load failed:", err);
      $("version").textContent = "unknown";
    });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
