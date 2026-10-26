// WKWebView 内で pptx を描く。Swift 側とは window.ppv（呼び出し）と
// webkit.messageHandlers.ppv（通知）でやりとりする。
import { createPptxViewer } from 'pptx-vanilla-viewer';
import 'pptx-vanilla-viewer/styles.css';
import { releasePptxRenderCaches } from 'ooxml-ui/pptx/dom';

// 外部への通信はしない。ライブラリが Google Fonts を取りに行くので、その場で断る（ローカルのフォントで描く）
const nativeFetch = window.fetch.bind(window);
window.fetch = (input, init) => {
  const url = typeof input === 'string' ? input : input?.url ?? String(input);
  if (/^https?:/i.test(url) && !url.startsWith(location.origin)) {
    return Promise.reject(new TypeError('external requests are disabled'));
  }
  return nativeFetch(input, init);
};

const root = document.getElementById('root');
let current = null;      // { viewer, host }
let loadSeq = 0;
let wanted = -1;         // 表示したいスライド（読み込み中に移動があっても、差し替え時にこれを使う）
let userZoomed = false;  // プロデューサーが拡大・縮小したか（したなら、描き直しても倍率と位置を保つ）

/** 拡大したときにスクロールする枠（ステージを包む、はみ出しをスクロールさせている要素） */
function scroller(host) {
  let el = host?.querySelector('.pptxv-stage')?.parentElement;
  while (el && el !== host) {
    const cs = getComputedStyle(el);
    if (/(auto|scroll)/.test(cs.overflow + cs.overflowX + cs.overflowY)) return el;
    el = el.parentElement;
  }
  return null;
}

function post(msg) {
  try { window.webkit.messageHandlers.ppv.postMessage(msg); } catch { console.log('[ppv]', JSON.stringify(msg)); }
}

function makeHost() {
  const host = document.createElement('div');
  host.className = 'ppv-host';
  root.appendChild(host);
  return host;
}

/** 描画が落ち着くまで待つ（フォントと画像の読み込み、2 フレーム）。
 *  frames: false なら 2 フレームは待たない。撮影（takeSnapshot）は自分で描画の更新を待つので、撮るだけなら要らない */
async function settle(host, frames = true) {
  await document.fonts.ready;
  const imgs = [...host.querySelectorAll('img')];
  await Promise.all(imgs.map((im) => (im.complete ? 0 : new Promise((r) => { im.onload = im.onerror = r; setTimeout(r, 3000); }))));
  // 描画の合図（2 フレーム）を待つ。表示が止まっていて合図が来ないときのために、上限を置く
  // 画面が消えているときは合図が来ない。撮影（takeSnapshot）は自分で描画の完了を待つので、ここは短く切り上げてよい
  if (!frames) return;
  await new Promise((r) => { const t = setTimeout(r, 150); requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(t); r(); })); });
}

window.ppv = {
  /** 新しい版を裏で描いてから差し替える。返り値はスライド枚数。 */
  async load(url, slideIndex, opts = {}) {
    const seq = ++loadSeq;
    wanted = Math.max(0, slideIndex | 0);
    const t0 = performance.now();
    const bytes = await (await fetch(url)).arrayBuffer();
    // 描き直す前の倍率とスクロール位置
    let keep = null;
    if (current && userZoomed) {
      const sc = scroller(current.host);
      keep = { zoom: current.viewer.getZoom(), left: sc?.scrollLeft ?? 0, top: sc?.scrollTop ?? 0 };
    }
    if (seq !== loadSeq) return -1;
    // ライブラリは描いた画像を全体で覚えている。読み込み直しのたびに増え続けないよう、新しい版を描く前に捨てる
    releasePptxRenderCaches();
    const host = makeHost();
    host.classList.add('ppv-pending');
    let viewer;
    const count = await new Promise((resolve, reject) => {
      viewer = createPptxViewer(host, {
        source: bytes,
        initialSlide: Math.max(0, slideIndex | 0),
        editable: false,
        showToolbar: false,
        showThumbnails: !!opts.thumbnails,
        showCompatibilityToasts: false,
        showFormatToolbar: false,
        showInspector: false,
        autosave: false,
        fitPadding: 0,
        maxFitScale: null,
        onLoad: ({ slideCount }) => resolve(slideCount),
        onError: (m) => reject(new Error(String(m))),
        onSlideChange: (i) => { if (current && current.viewer === viewer) post({ type: 'slide', index: i }); },
      });
    }).catch((e) => { viewer?.destroy(); host.remove(); post({ type: 'error', message: e.message }); return -1; });
    if (count < 0) return -1;
    if (seq !== loadSeq) { viewer.destroy(); host.remove(); return -1; }
    // 読み込んでいる間に移動があれば、その最新の行き先で出す
    const idx = Math.min(Math.max(0, wanted), count - 1);
    if (viewer.getCurrentSlide() !== idx) viewer.goToSlide(idx);
    if (keep && typeof keep.zoom === 'number') {
      viewer.setZoom(keep.zoom);
      await settle(host);
      const sc = scroller(host);
      if (sc) { sc.scrollLeft = keep.left; sc.scrollTop = keep.top; }
    }
    await settle(host);
    if (seq !== loadSeq) { viewer.destroy(); host.remove(); return -1; }
    const old = current;
    host.classList.remove('ppv-pending');
    current = { viewer, host };
    if (old) { old.viewer.destroy(); old.host.remove(); }
    post({ type: 'loaded', count, index: idx, ms: Math.round(performance.now() - t0) });
    return count;
  },

  async goTo(index, frames = true) {
    wanted = Math.max(0, index | 0);
    if (!current) return;
    current.viewer.goToSlide(index);
    await settle(current.host, frames);
    post({ type: 'shown', index });
  },

  current() { return current ? current.viewer.getCurrentSlide() : -1; },

  /** 表示を捨ててメモリを返す（裏の撮影用の表示で、仕事が終わったあとに使う） */
  unload() {
    loadSeq++;
    if (current) { current.viewer.destroy(); current.host.remove(); current = null; }
    releasePptxRenderCaches();
  },

  /**
   * 表示中のスライドの、文字の収まりの問題を拾う（MCP の check_layout 用）。
   * slideWidthIn: スライドの幅（インチ）。返す量はインチ。
   */
  layoutIssues(slideWidthIn) {
    const host = current?.host;
    const stage = host?.querySelector('.pptxv-stage');
    if (!stage) return [];
    const S = stage.getBoundingClientRect();
    const k = slideWidthIn / S.width;
    const tol = 1.5;
    const issues = [];
    const boxes = [];
    for (const el of stage.querySelectorAll('.pptxv-element')) {
      const t = el.querySelector('.pptxv-text');
      if (!t || t.closest('.pptxv-element') !== el) continue;
      const text = (t.innerText || '').replace(/\s+/g, ' ').trim();
      if (!text) continue;
      const E = el.getBoundingClientRect();
      const range = document.createRange();
      range.selectNodeContents(t);
      const rects = [...range.getClientRects()].filter((q) => q.width > 0.5 && q.height > 0.5);
      if (!rects.length) continue;
      const B = {
        l: Math.min(...rects.map((q) => q.left)), t: Math.min(...rects.map((q) => q.top)),
        r: Math.max(...rects.map((q) => q.right)), b: Math.max(...rects.map((q) => q.bottom)),
      };
      const snippet = text.slice(0, 40);
      const over = { bottom: B.b - E.bottom, right: B.r - E.right, top: E.top - B.t, left: E.left - B.l };
      // 行の上下の余白も行の箱に入るので、1 行の文でも 0.1 インチほど「はみ出す」。本物は 1 行ぶん（0.25 インチ前後）以上になる
      const minIn = 0.15;
      for (const [side, v] of Object.entries(over)) {
        if (v * k >= minIn) issues.push({ kind: 'text_overflows_box', side, amount_in: +(v * k).toFixed(2), text: snippet });
      }
      const off = Math.max(B.r - S.right, B.b - S.bottom, S.left - B.l, S.top - B.t);
      if (off * k >= minIn) issues.push({ kind: 'text_off_slide', amount_in: +(off * k).toFixed(2), text: snippet });
      boxes.push({ B, snippet });
    }
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i].B, b = boxes[j].B;
        const w = Math.min(a.r, b.r) - Math.max(a.l, b.l), h = Math.min(a.b, b.b) - Math.max(a.t, b.t);
        if (w <= tol || h <= tol) continue;
        const area = w * h, small = Math.min((a.r - a.l) * (a.b - a.t), (b.r - b.l) * (b.b - b.t));
        if (area / small > 0.15) issues.push({ kind: 'text_overlaps_text', overlap_ratio: +(area / small).toFixed(2), text: boxes[i].snippet, other_text: boxes[j].snippet });
      }
    }
    return issues;
  },

  /** スライドショーのときは地を黒に */
  setBackground(color) {
    for (const el of [document.documentElement, document.body, root]) el.style.background = color;
  },
  zoomIn() { userZoomed = true; current?.viewer.zoomIn(); },
  zoomOut() { userZoomed = true; current?.viewer.zoomOut(); },
  zoomToFit() { userZoomed = false; current?.viewer.zoomToFit(); },
  /** 表示の倍率と位置（前の版を同じ見え方で出すのに使う） */
  viewState() {
    if (!current) return null;
    const sc = scroller(current.host);
    return { userZoomed, zoom: current.viewer.getZoom(), left: sc?.scrollLeft ?? 0, top: sc?.scrollTop ?? 0 };
  },
  async applyView(state) {
    if (!current || !state) return;
    if (!state.userZoomed) { userZoomed = false; current.viewer.zoomToFit(); await settle(current.host); return; }
    userZoomed = true;
    current.viewer.setZoom(state.zoom);
    await settle(current.host);
    const sc = scroller(current.host);
    if (sc) { sc.scrollLeft = state.left; sc.scrollTop = state.top; }
  },
  zoomState() { return current ? { zoom: current.viewer.getZoom(), userZoomed, scrollTop: scroller(current.host)?.scrollTop ?? -1 } : null; },
  focus() { current?.host.querySelector('[tabindex]')?.focus(); },

  /** 表示中のスライドの、ページ内での位置（比較用の切り出しに使う） */
  slideRect() {
    const el = current?.host.querySelector('.pptxv-stage');
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  },
};

post({ type: 'ready' });
