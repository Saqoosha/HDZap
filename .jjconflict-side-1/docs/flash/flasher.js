// esptool-js is vendored under vendor/ rather than loaded from a CDN so the
// flasher cannot be silently substituted by a CDN compromise — Web Serial
// gives this script direct write access to the user's USB device.
// Pinned to 0.5.7: esp-web-tools v10.x ships the same major; 0.6.x has a
// known regression where compressed writeFlash to ESP32-S3 returns status
// 201 (ESP_TOO_MUCH_DATA). Bump only after re-verifying on real hardware.
import { ESPLoader, Transport } from "./vendor/esptool-js@0.5.7.js";

// Resolve every asset relative to *this script* so the same flasher.js works
// from both `/flash/` (English) and `/flash/ja/` (Japanese) without per-page
// path tweaks.
const FLASH_BASE = new URL("./", import.meta.url);
const url = (path) => new URL(path, FLASH_BASE).href;

// All user-facing strings live here so adding a third language is a single
// dictionary entry. Keys use snake_case; values that need runtime placeholders
// are functions returning the formatted string.
const MESSAGES = {
  ja: {
    label_bootloader: "ブートローダー",
    label_partitions: "パーティションテーブル",
    label_bootapp: "ブートアプリ",
    label_hdzap: "HDZap 本体",
    chip_unknown: "不明",
    status_select_port: "ポートを選択してください…",
    status_connecting: "ブートローダーに接続中…",
    detail_few_seconds: "（数秒かかることがあります）",
    status_chip_detected: (chipName) =>
      `${chipName} を検出しました。ファームウェアをダウンロード中…`,
    detail_fetching: (label) => `${label} を取得中…`,
    status_erasing: "チップを完全消去中… (10〜20 秒かかります)",
    detail_erase_warn: "保存データもすべて消去します",
    status_starting_write: "書き込みを開始します…",
    detail_keep_data: "保存データ（UID、設定）は保持されます",
    status_writing: "書き込み中…",
    progress_part: (label, idx, total, pct) =>
      `${label} (${idx}/${total}) — ${pct}%`,
    status_done_restarting: "書き込み完了。再起動します…",
    err_chip_mismatch: (expected, detected) =>
      `このファームウェアは ${expected} 専用です（検出されたチップ: ${detected}）。`,
    err_download_failed: (url) =>
      `${url} のダウンロードに失敗しました（ネットワークエラー）。`,
    err_http: (url, status) => `${url} の取得に失敗しました（HTTP ${status}）`,
    err_internal: "内部エラーが発生しました（HDZap 側のバグの可能性）。",
    hint_console: (errName, errMsg) =>
      `${errName}: ${errMsg}\nブラウザの開発者ツール（コンソール）に詳細が出力されています。`,
    hint_chip_only_m5:
      "HDZap は M5StickS3（ESP32-S3）専用です。別の ESP32 系ボードでは動きません。",
    hint_check_network: "ネットワーク接続を確認してから「再試行」してください。",
    err_bootloader_connect: "M5StickS3 のブートローダーに接続できませんでした。",
    hint_dfu_mode:
      "本体左側の電源ボタンを 2 秒長押しして、緑色 LED が点滅している状態（書き込みモード）にしてから再試行してください。USB-C ケーブルがデータ通信対応であることも確認してください。",
    err_serial_open: "シリアルポートを開けませんでした。",
    hint_serial_in_use:
      "他のアプリ（PlatformIO のシリアルモニタなど）が同じポートを使っていないか確認してください。",
    err_chip_unsupported: "このチップは HDZap に対応していません。",
    hint_only_m5: "HDZap は M5StickS3（ESP32-S3）専用です。",
    err_too_much_data: "書き込み中に通信が不安定になりました。",
    hint_reseat_cable:
      "ケーブルを差し直してから「再試行」してください。USB ハブを経由している場合は本体に直接挿すと安定します。",
    err_generic: "書き込み中にエラーが発生しました。",
    hint_console_msg: (msg) =>
      `${msg}\nブラウザの開発者ツール（コンソール）に詳細が出力されています。`,
    version_unknown: "不明",
  },
  en: {
    label_bootloader: "Bootloader",
    label_partitions: "Partition table",
    label_bootapp: "Boot app",
    label_hdzap: "HDZap firmware",
    chip_unknown: "unknown",
    status_select_port: "Select the serial port…",
    status_connecting: "Connecting to bootloader…",
    detail_few_seconds: "(this can take a few seconds)",
    status_chip_detected: (chipName) =>
      `Detected ${chipName}. Downloading firmware…`,
    detail_fetching: (label) => `Fetching ${label}…`,
    status_erasing: "Erasing entire chip… (takes 10–20 seconds)",
    detail_erase_warn: "All saved data will be erased",
    status_starting_write: "Starting flash…",
    detail_keep_data: "Saved data (UID, settings) preserved",
    status_writing: "Writing…",
    progress_part: (label, idx, total, pct) =>
      `${label} (${idx}/${total}) — ${pct}%`,
    status_done_restarting: "Flash complete. Restarting…",
    err_chip_mismatch: (expected, detected) =>
      `This firmware only supports ${expected} (detected chip: ${detected}).`,
    err_download_failed: (url) =>
      `Failed to download ${url} (network error).`,
    err_http: (url, status) => `Failed to fetch ${url} (HTTP ${status})`,
    err_internal: "An internal error occurred (likely an HDZap bug).",
    hint_console: (errName, errMsg) =>
      `${errName}: ${errMsg}\nDetails are in the browser dev tools console.`,
    hint_chip_only_m5:
      "HDZap only supports the M5StickS3 (ESP32-S3). Other ESP32 boards won't work.",
    hint_check_network: "Check your network connection, then click Retry.",
    err_bootloader_connect: "Couldn't connect to the M5StickS3 bootloader.",
    hint_dfu_mode:
      "Hold the small power button on the left side for about 2 seconds — when the green LED blinks, the device is in flash mode. Then retry. Also make sure the USB-C cable supports data, not just charging.",
    err_serial_open: "Couldn't open the serial port.",
    hint_serial_in_use:
      "Make sure no other application (PlatformIO serial monitor, Arduino IDE, etc.) is using the same port.",
    err_chip_unsupported: "This chip is not supported by HDZap.",
    hint_only_m5: "HDZap only supports the M5StickS3 (ESP32-S3).",
    err_too_much_data: "The flash communication became unstable.",
    hint_reseat_cable:
      "Reseat the USB cable and retry. Plugging directly into the computer (not through a hub) is more reliable.",
    err_generic: "An error occurred during flashing.",
    hint_console_msg: (msg) =>
      `${msg}\nDetails are in the browser dev tools console.`,
    version_unknown: "unknown",
  },
};

const LANG = (document.documentElement.lang || "ja").toLowerCase().startsWith("en")
  ? "en"
  : "ja";
const M = MESSAGES[LANG];

const PARTS = [
  { url: url("firmware/bootloader.bin"), offset: 0x0000, labelKey: "label_bootloader" },
  { url: url("firmware/partitions.bin"), offset: 0x8000, labelKey: "label_partitions" },
  { url: url("firmware/boot_app0.bin"), offset: 0xe000, labelKey: "label_bootapp" },
  { url: url("firmware/hdzap.bin"), offset: 0x10000, labelKey: "label_hdzap" },
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
    throw new NetworkError(M.err_download_failed(url));
  }
  if (!r.ok) throw new Error(M.err_http(url, r.status));
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
      msg: M.err_internal,
      hint: M.hint_console(err.name, err.message),
    };
  }

  if (err instanceof ChipMismatchError) {
    return {
      msg: err.message,
      hint: M.hint_chip_only_m5,
    };
  }

  if (err instanceof NetworkError) {
    return {
      msg: err.message,
      hint: M.hint_check_network,
    };
  }

  const msg = (err && err.message) || String(err);
  const lc = msg.toLowerCase();

  if (lc.includes("failed to connect") || lc.includes("timed out") || lc.includes("no serial data")) {
    return {
      msg: M.err_bootloader_connect,
      hint: M.hint_dfu_mode,
    };
  }
  if (lc.includes("access denied") || lc.includes("failed to open")) {
    return {
      msg: M.err_serial_open,
      hint: M.hint_serial_in_use,
    };
  }
  if (
    lc.includes("chip not supported") ||
    lc.includes("unsupported chip") ||
    lc.includes("chip is esp")
  ) {
    return {
      msg: M.err_chip_unsupported,
      hint: M.hint_only_m5,
    };
  }
  if (lc.includes("status 201") || lc.includes("too much data")) {
    return {
      msg: M.err_too_much_data,
      hint: M.hint_reseat_cable,
    };
  }
  return {
    msg: M.err_generic,
    hint: M.hint_console_msg(msg),
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
  setStatus(M.status_select_port);
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

    setStatus(M.status_connecting);
    setProgress(2, M.detail_few_seconds);

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
        M.err_chip_mismatch(SUPPORTED_CHIP, chipName || M.chip_unknown)
      );
    }

    setStatus(M.status_chip_detected(chipName));
    setProgress(5, "");

    const fileArray = [];
    for (let i = 0; i < PARTS.length; i++) {
      const p = PARTS[i];
      setProgress(5 + Math.floor((i / PARTS.length) * 5), M.detail_fetching(M[p.labelKey]));
      const data = await fetchBinary(p.url);
      fileArray.push({ data, address: p.offset });
    }

    if (eraseAll) {
      setStatus(M.status_erasing);
      setProgress(10, M.detail_erase_warn);
    } else {
      setStatus(M.status_starting_write);
      setProgress(10, M.detail_keep_data);
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
        setStatus(M.status_writing);
        setProgress(
          overall,
          M.progress_part(M[part.labelKey], fileIndex + 1, PARTS.length, Math.floor(filePct * 100))
        );
      },
    });

    setStatus(M.status_done_restarting);
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

  fetch(url("manifest.json"), { cache: "no-store" })
    .then((r) => {
      if (!r.ok) throw new Error(`manifest HTTP ${r.status}`);
      return r.json();
    })
    .then((m) => {
      $("version").textContent = m.version || M.version_unknown;
    })
    .catch((err) => {
      console.warn("[flasher] manifest load failed:", err);
      $("version").textContent = M.version_unknown;
    });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
