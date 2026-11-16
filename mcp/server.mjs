#!/usr/bin/env node
// wkwebview-mcp: an MCP server for debugging WKWebViews inside iOS apps.
//
// The app embeds the WebViewMCP Swift package, which serves its web views on a local HTTP port
// (127.0.0.1:9333 by default). This process speaks MCP over stdio and forwards each tool call
// to that port. No dependencies: Node 18+ only.

import { execFile } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

const VERSION = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;
const HOST = process.env.WKWEBVIEW_MCP_HOST || '127.0.0.1';
const BASE_PORT = Number(process.env.WKWEBVIEW_MCP_PORT || 9333);
const PORT_RANGE = Number(process.env.WKWEBVIEW_MCP_PORT_RANGE || 10);
const SUPPORTED_PROTOCOLS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

// ---------------------------------------------------------------------------------------------
// Talking to the app

class ToolError extends Error {}

async function request(port, method, path, body, timeoutMs = 15000) {
  let response;
  try {
    response = await fetch(`http://${HOST}:${port}${path}`, {
      method,
      headers: body ? { 'content-type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(timeoutMs),
    });
  } catch (error) {
    if (error.name === 'TimeoutError') {
      throw new ToolError(`The app on port ${port} did not answer within ${timeoutMs} ms.`);
    }
    throw new ToolError(`Could not reach the app on ${HOST}:${port} (${error.cause?.code || error.message}). Is it still running?`);
  }
  if ((response.headers.get('content-type') || '').startsWith('image/')) {
    if (!response.ok) {
      throw new ToolError(`Snapshot failed with HTTP ${response.status}`);
    }
    return Buffer.from(await response.arrayBuffer());
  }
  const json = await response.json().catch(() => ({ ok: false, error: `HTTP ${response.status} with a non-JSON body` }));
  if (!response.ok && json.ok !== false) {
    json.ok = false;
  }
  return json;
}

/** Every app currently serving web views in the port range. */
async function discoverApps() {
  const ports = Array.from({ length: PORT_RANGE }, (_, index) => BASE_PORT + index);
  const results = await Promise.all(ports.map(async (port) => {
    try {
      const response = await fetch(`http://${HOST}:${port}/info`, { signal: AbortSignal.timeout(700) });
      const info = await response.json();
      return info && info.server === 'wkwebview-mcp' ? { ...info, port } : null;
    } catch {
      return null;
    }
  }));
  return results.filter(Boolean);
}

/** Resolves the `app` argument (port, bundle id, app name or simulator name) to a port. */
async function resolveApp(selector) {
  if (selector !== undefined && selector !== null && selector !== '' && /^\d+$/.test(String(selector))) {
    return { port: Number(selector), note: '' };
  }
  const apps = await discoverApps();
  if (apps.length === 0) {
    throw new ToolError(
      `No app is serving web views on ${HOST}:${BASE_PORT}-${BASE_PORT + PORT_RANGE - 1}. ` +
      'Make sure the app is running a debug build that calls WebViewMCP.start(). ' +
      `For a physical device, forward the port over USB first: iproxy ${BASE_PORT} ${BASE_PORT}`
    );
  }
  if (selector) {
    const needle = String(selector).toLowerCase();
    const match = apps.find((app) => [app.app?.bundleId, app.app?.name, app.device?.name, app.device?.udid]
      .some((value) => value && String(value).toLowerCase() === needle));
    if (!match) {
      throw new ToolError(`No running app matches "${selector}". Running: ${apps.map(describeApp).join('; ')}`);
    }
    return { port: match.port, note: '' };
  }
  const note = apps.length > 1
    ? `Note: ${apps.length} apps are running; using ${describeApp(apps[0])}. Pass "app" to pick another.\n`
    : '';
  return { port: apps[0].port, note };
}

function describeApp(app) {
  const device = app.device?.simulator ? `${app.device.name || 'Simulator'} (iOS ${app.device.systemVersion})` : `${app.device?.model || 'device'} (${app.device?.systemName || ''} ${app.device?.systemVersion || ''})`;
  return `${app.app?.name || app.app?.bundleId} on ${device}, port ${app.port}`;
}

async function call(args, method, path, body, timeoutMs) {
  const { port, note } = await resolveApp(args.app);
  const query = [];
  if (method === 'GET') {
    for (const [key, value] of Object.entries(body || {})) {
      if (value !== undefined && value !== null && value !== '') {
        query.push(`${encodeURIComponent(key)}=${encodeURIComponent(Array.isArray(value) ? value.join(',') : value)}`);
      }
    }
  }
  const fullPath = query.length ? `${path}?${query.join('&')}` : path;
  const result = await request(port, method, fullPath, method === 'GET' ? undefined : body, timeoutMs);
  if (!Buffer.isBuffer(result) && result.ok === false) {
    throw new ToolError(note + (result.error || 'The app returned an error') + formatLocation(result));
  }
  return { result, note, port };
}

function formatLocation(result) {
  return result.line ? ` (line ${result.line}${result.column ? `, column ${result.column}` : ''})` : '';
}

/** Runs JavaScript in the page and returns the decoded value. */
async function evaluate(args, code, timeoutMs = 10000) {
  const { result, note } = await call(args, 'POST', '/eval', {
    webview: args.webview,
    frame: args.frame,
    code,
    timeoutMs,
  }, timeoutMs + 5000);
  return { value: result.value, type: result.type, note, durationMs: result.durationMs };
}

// ---------------------------------------------------------------------------------------------
// Page scripts. Each is a function body run through /eval; ARGS is replaced with JSON.

const FIND_ELEMENT = `
  function describeElement(el) {
    if (!el) { return null; }
    const isField = el.tagName === 'INPUT' || el.tagName === 'SELECT' || el.tagName === 'TEXTAREA';
    let text = (el.getAttribute('aria-label') || (isField ? el.placeholder || el.name : el.innerText) || el.title || '').replace(/\\s+/g, ' ').trim();
    if (text.length > 60) { text = text.slice(0, 60) + '…'; }
    return '<' + el.tagName.toLowerCase() + (el.id ? '#' + el.id : '') + (typeof el.className === 'string' && el.className.trim() ? '.' + el.className.trim().split(/\\s+/).slice(0, 3).join('.') : '') + '>' + (text ? ' "' + text + '"' : '');
  }
  function findElement(args) {
    if (args.ref !== undefined && args.ref !== null) {
      const el = document.querySelector('[data-wvdbg-ref="' + args.ref + '"]');
      if (!el) { throw new Error('No element with ref ' + args.ref + '. Refs come from get_page_content with format "interactive" and are reassigned each time it runs.'); }
      return el;
    }
    if (args.selector) {
      const el = document.querySelector(args.selector);
      if (!el) { throw new Error('No element matches ' + args.selector); }
      return el;
    }
    if (args.text) {
      const needle = args.text.replace(/\\s+/g, ' ').trim().toLowerCase();
      const textOf = (el) => (el.getAttribute('aria-label') || el.innerText || el.value || '').replace(/\\s+/g, ' ').trim().toLowerCase();
      const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
      let best = null, bestScore = Infinity;
      for (const el of document.body.querySelectorAll('*')) {
        if (el.tagName === 'SCRIPT' || el.tagName === 'STYLE') { continue; }
        const text = textOf(el);
        if (!text.includes(needle) || !visible(el)) { continue; }
        const score = (text === needle ? 0 : 100000) + text.length;
        if (score <= bestScore) { best = el; bestScore = score; }
      }
      if (!best) { throw new Error('No visible element contains the text "' + args.text + '"'); }
      return best.closest('a,button,[role=button],[role=link],[role=tab],[role=menuitem],[onclick],label,summary,input,select,textarea') || best;
    }
    throw new Error('Pass ref, selector or text');
  }
`;

const SCRIPTS = {
  content: `
    const ARGS = __ARGS__;
    const root = ARGS.selector ? document.querySelector(ARGS.selector) : (document.body || document.documentElement);
    if (!root) { throw new Error('No element matches ' + ARGS.selector); }
    let content;
    if (ARGS.format === 'html') {
      const clone = root.cloneNode(true);
      if (!ARGS.keepScripts) { clone.querySelectorAll('script,style,noscript').forEach((el) => el.remove()); }
      content = clone.outerHTML;
    } else {
      content = root.innerText;
    }
    return { url: location.href, title: document.title, length: content.length, content: content.slice(0, ARGS.maxChars) };
  `,

  interactive: `
    const ARGS = __ARGS__;
    const root = ARGS.selector ? document.querySelector(ARGS.selector) : document.body;
    if (!root) { throw new Error('No element matches ' + ARGS.selector); }
    document.querySelectorAll('[data-wvdbg-ref]').forEach((el) => el.removeAttribute('data-wvdbg-ref'));
    const query = 'a[href],button,input,select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=switch],[role=option],[onclick],[contenteditable=""],[contenteditable=true],[tabindex]:not([tabindex="-1"])';
    const width = innerWidth, height = innerHeight;
    const elements = [];
    let ref = 0;
    for (const el of root.querySelectorAll(query)) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 && r.height === 0) { continue; }
      const style = getComputedStyle(el);
      if (style.visibility === 'hidden' || style.display === 'none') { continue; }
      ref += 1;
      el.setAttribute('data-wvdbg-ref', String(ref));
      if (elements.length >= ARGS.limit) { continue; }
      const item = {
        ref,
        tag: el.tagName.toLowerCase(),
        label: (el.getAttribute('aria-label') || el.innerText || el.value || el.placeholder || el.title || el.getAttribute('alt') || '').replace(/\\s+/g, ' ').trim().slice(0, 80),
        rect: [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)],
        onScreen: r.bottom > 0 && r.right > 0 && r.top < height && r.left < width,
      };
      if (el.type && el.tagName !== 'BUTTON') { item.type = el.type; }
      if (el.name) { item.name = el.name; }
      if (el.id) { item.id = el.id; }
      if (el.href) { item.href = el.href; }
      if (el.disabled) { item.disabled = true; }
      if (el.checked) { item.checked = true; }
      if (style.pointerEvents === 'none') { item.pointerEventsNone = true; }
      elements.push(item);
    }
    return { url: location.href, title: document.title, viewport: [width, height], scrollY: Math.round(scrollY), total: ref, elements, iframes: root.querySelectorAll('iframe').length };
  `,

  click: `
    const ARGS = __ARGS__;
    ${FIND_ELEMENT}
    const el = findElement(ARGS);
    el.scrollIntoView({ block: 'center', inline: 'center' });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2, y = r.top + r.height / 2;
    const top = document.elementFromPoint(x, y);
    const covered = top && top !== el && !el.contains(top) && !top.contains(el);
    const init = { bubbles: true, cancelable: true, composed: true, view: window, clientX: x, clientY: y, button: 0 };
    el.dispatchEvent(new PointerEvent('pointerdown', { ...init, pointerType: 'touch', isPrimary: true }));
    el.dispatchEvent(new MouseEvent('mousedown', init));
    el.dispatchEvent(new PointerEvent('pointerup', { ...init, pointerType: 'touch', isPrimary: true }));
    el.dispatchEvent(new MouseEvent('mouseup', init));
    if (typeof el.focus === 'function') { el.focus({ preventScroll: true }); }
    el.click();
    return {
      clicked: describeElement(el),
      at: [Math.round(x), Math.round(y)],
      coveredBy: covered ? describeElement(top) : undefined,
    };
  `,

  fill: `
    const ARGS = __ARGS__;
    ${FIND_ELEMENT}
    const el = findElement(ARGS);
    el.scrollIntoView({ block: 'center' });
    if (typeof el.focus === 'function') { el.focus({ preventScroll: true }); }
    const value = String(ARGS.value);
    if (el.isContentEditable) {
      el.textContent = value;
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
    } else if (el.tagName === 'SELECT') {
      const option = Array.from(el.options).find((o) => o.value === value || o.text.trim() === value);
      if (!option) { throw new Error('No option "' + value + '". Options: ' + Array.from(el.options).map((o) => o.text.trim()).join(', ')); }
      el.value = option.value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else if (el.type === 'checkbox' || el.type === 'radio') {
      const wanted = /^(true|1|on|yes|checked)$/i.test(value);
      if (el.checked !== wanted) { el.click(); }
    } else if ('value' in el) {
      // Use the prototype's setter so React, Vue and friends notice the change.
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value').set;
      setter.call(el, value);
      el.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: value }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    } else {
      throw new Error(describeElement(el) + ' is not a form field');
    }
    if (ARGS.submit) {
      const key = { key: 'Enter', code: 'Enter', keyCode: 13, which: 13, bubbles: true, cancelable: true };
      const proceed = el.dispatchEvent(new KeyboardEvent('keydown', key));
      el.dispatchEvent(new KeyboardEvent('keyup', key));
      if (proceed && el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
    }
    const isToggle = el.type === 'checkbox' || el.type === 'radio';
    return { filled: describeElement(el), value: isToggle ? el.checked : ('value' in el ? el.value : el.textContent) };
  `,

  scroll: `
    const ARGS = __ARGS__;
    ${FIND_ELEMENT}
    if (ARGS.selector || ARGS.ref !== undefined || ARGS.text) {
      const el = findElement(ARGS);
      el.scrollIntoView({ block: 'center' });
      return { scrolledTo: describeElement(el), scrollY: Math.round(scrollY) };
    }
    if (ARGS.to === 'top') { scrollTo(0, 0); }
    else if (ARGS.to === 'bottom') { scrollTo(0, document.documentElement.scrollHeight); }
    else { scrollBy(0, ARGS.by || innerHeight * 0.8); }
    return { scrollY: Math.round(scrollY), scrollHeight: document.documentElement.scrollHeight, viewportHeight: innerHeight };
  `,

  waitFor: `
    const ARGS = __ARGS__;
    const started = Date.now();
    const present = () => {
      if (ARGS.selector) {
        const el = document.querySelector(ARGS.selector);
        if (!el) { return false; }
        const r = el.getBoundingClientRect();
        return ARGS.visible ? r.width > 0 && r.height > 0 : true;
      }
      return (document.body ? document.body.innerText : '').toLowerCase().includes(ARGS.text.toLowerCase());
    };
    while (Date.now() - started < ARGS.timeoutMs) {
      if (present() !== Boolean(ARGS.gone)) { return { matched: true, waitedMs: Date.now() - started, url: location.href }; }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
    return { matched: false, waitedMs: Date.now() - started, url: location.href };
  `,
};

function script(name, args) {
  return SCRIPTS[name].replace('__ARGS__', JSON.stringify(args));
}

// ---------------------------------------------------------------------------------------------
// Formatting

function time(ms) {
  if (!ms) { return '--:--:--.---'; }
  const date = new Date(ms);
  return date.toTimeString().slice(0, 8) + '.' + String(date.getMilliseconds()).padStart(3, '0');
}

function formatConsole(entries) {
  return entries.map((entry) => {
    let line = `#${entry.seq} ${time(entry.time)} ${String(entry.level || 'log').toUpperCase().padEnd(5)} ${entry.message}`;
    if (entry.kind && entry.kind !== 'console') { line += `  [${entry.kind}]`; }
    if (entry.source) { line += `\n      at ${entry.source}`; }
    if (entry.frameURL) { line += `\n      in frame ${entry.frameURL}`; }
    if (entry.stack && entry.level === 'error') {
      line += '\n' + String(entry.stack).split('\n').slice(0, 6).map((frame) => `      ${frame}`).join('\n');
    }
    return line;
  }).join('\n');
}

function formatNetwork(requests) {
  return requests.map((r) => {
    const status = r.error ? 'FAILED' : r.state === 'pending' ? 'PENDING' : String(r.status ?? '—');
    const duration = r.duration !== undefined ? `${r.duration}ms` : '';
    let line = `#${r.seq} [${r.id}] ${(r.method || 'GET').padEnd(6)} ${status.padEnd(7)} ${duration.padEnd(7)} ${(r.kind || '').padEnd(8)} ${r.url}`;
    if (r.error) { line += `\n      error: ${r.error}`; }
    return line;
  }).join('\n');
}

function formatInteractive(page) {
  const lines = page.elements.map((el) => {
    const attributes = [];
    if (el.type) { attributes.push(`type=${el.type}`); }
    if (el.name) { attributes.push(`name=${el.name}`); }
    if (el.id) { attributes.push(`#${el.id}`); }
    if (el.href) { attributes.push(`href=${el.href}`); }
    if (el.disabled) { attributes.push('disabled'); }
    if (el.checked) { attributes.push('checked'); }
    if (el.pointerEventsNone) { attributes.push('pointer-events:none'); }
    if (!el.onScreen) { attributes.push('offscreen'); }
    return `[${el.ref}] ${el.tag} "${el.label}" ${attributes.join(' ')} @${el.rect[0]},${el.rect[1]} ${el.rect[2]}x${el.rect[3]}`.replace(/ +/g, ' ');
  });
  let more = page.total > page.elements.length ? `\n… ${page.total - page.elements.length} more (raise limit or narrow with selector)` : '';
  if (page.iframes) { more += `\n(${page.iframes} iframe${page.iframes > 1 ? 's' : ''} not listed: get frame ids from list_frames and pass frame)`; }
  return `${page.title} — ${page.url}\nviewport ${page.viewport[0]}x${page.viewport[1]}, scrollY ${page.scrollY}\n\n${lines.join('\n')}${more}`;
}

/**
 * App-bundle file URLs in the simulator are long and say nothing useful past the bundle name:
 * file:///Users/…/Containers/Bundle/Application/<UUID>/My.app/www/index.html → file://…/My.app/www/index.html
 */
function shortenURLs(text) {
  return String(text).replace(/file:\/\/\/[^\s"'()]*?\/([^/\s"'()]+\.app\/)/g, 'file://…/$1');
}

function json(value) {
  return JSON.stringify(value, null, 2);
}

function text(value) {
  return { content: [{ type: 'text', text: shortenURLs(value) }] };
}

// ---------------------------------------------------------------------------------------------
// Tools

const target = {
  app: { type: ['string', 'number'], description: 'Which app: port, bundle id, app name or simulator name. Defaults to the first one found.' },
  webview: { type: 'string', description: 'Web view id (e.g. "wv1") or the name it was registered with. Defaults to the visible one registered last.' },
};
const frame = { frame: { type: 'string', description: 'Frame id from list_frames, to run inside an iframe. Defaults to the main frame.' } };
const elementTarget = {
  ref: { type: 'integer', description: 'Element ref from get_page_content with format "interactive".' },
  selector: { type: 'string', description: 'CSS selector.' },
  text: { type: 'string', description: 'Visible text of the element (exact match preferred, else the smallest element containing it).' },
};

const TOOLS = [
  {
    name: 'list_apps',
    description: 'Find running iOS apps (simulators, or devices forwarded with iproxy) that expose WKWebViews through the WebViewMCP Swift package, with their web views.',
    inputSchema: { type: 'object', properties: {} },
    annotations: { readOnlyHint: true },
    async run() {
      const apps = await discoverApps();
      if (apps.length === 0) {
        return text(`No apps found on ${HOST}:${BASE_PORT}-${BASE_PORT + PORT_RANGE - 1}. Start a debug build of an app that calls WebViewMCP.start(). For a physical device run: iproxy ${BASE_PORT} ${BASE_PORT}`);
      }
      return text(apps.map((app) => {
        const views = (app.webViews || []).map((wv) => `  - ${wv.id}${wv.name ? ` (${wv.name})` : ''}: ${wv.title || '(no title)'} — ${wv.url || 'about:blank'}${wv.visible ? '' : ' [not on screen]'}`);
        return `${describeApp(app)}\n  bundle ${app.app?.bundleId}, pid ${app.app?.pid}${app.device?.udid ? `, simulator ${app.device.udid}` : ''}\n${views.join('\n') || '  (no web views registered)'}`;
      }).join('\n\n'));
    },
  },
  {
    name: 'list_webviews',
    description: 'List the web views registered in an app, with URL, title, loading state and whether each is on screen.',
    inputSchema: { type: 'object', properties: { app: target.app } },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result, note } = await call(args, 'GET', '/webviews');
      return text(note + json(result.webViews));
    },
  },
  {
    name: 'page_info',
    description: 'URL, title, loading state, history and frames of a web view.',
    inputSchema: { type: 'object', properties: { ...target } },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result: list, note } = await call(args, 'GET', '/webviews');
      const { result: frames } = await call(args, 'GET', '/frames', { webview: args.webview });
      const views = list.webViews || [];
      const view = (args.webview && views.find((wv) => wv.id === args.webview || wv.name === args.webview))
        || views.filter((wv) => wv.visible).pop() || views[views.length - 1];
      return text(note + json({ ...view, frames: frames.frames }));
    },
  },
  {
    name: 'list_frames',
    description: 'List the frames (main frame and iframes) of a web view. Use a frame id with evaluate_javascript and the DOM tools to work inside an iframe.',
    inputSchema: { type: 'object', properties: { ...target } },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result, note } = await call(args, 'GET', '/frames', { webview: args.webview });
      return text(note + json(result.frames));
    },
  },
  {
    name: 'evaluate_javascript',
    description: 'Run JavaScript in the page and return the result. The code is an async function body: use `await` freely and `return` the value you want. A single expression without `return` (like `document.title`) is returned automatically. DOM elements come back as their outerHTML.',
    inputSchema: {
      type: 'object',
      properties: {
        code: { type: 'string', description: 'JavaScript function body.' },
        ...target,
        ...frame,
        timeout_ms: { type: 'integer', description: 'Give up after this long (default 10000).' },
      },
      required: ['code'],
    },
    async run(args) {
      const { value, type, note, durationMs } = await evaluate(args, args.code, args.timeout_ms || 10000);
      const rendered = type === 'undefined' ? 'undefined' : typeof value === 'string' ? value : json(value);
      return text(`${note}${rendered}\n\n(${type}, ${durationMs} ms)`);
    },
  },
  {
    name: 'get_page_content',
    description: 'Read the page. format "text" (default) returns the visible text; "interactive" lists clickable and editable elements with refs to pass to click/fill; "html" returns the markup without scripts and styles.',
    inputSchema: {
      type: 'object',
      properties: {
        format: { type: 'string', enum: ['text', 'interactive', 'html'] },
        selector: { type: 'string', description: 'Limit to this element (CSS selector).' },
        max_chars: { type: 'integer', description: 'Truncate text/html to this many characters (default 20000).' },
        limit: { type: 'integer', description: 'Max elements for "interactive" (default 150).' },
        ...target,
        ...frame,
      },
    },
    annotations: { readOnlyHint: true },
    async run(args) {
      const format = args.format || 'text';
      if (format === 'interactive') {
        const { value, note } = await evaluate(args, script('interactive', { selector: args.selector, limit: args.limit || 150 }));
        return text(note + formatInteractive(value));
      }
      const maxChars = args.max_chars || 20000;
      const { value, note } = await evaluate(args, script('content', { selector: args.selector, format, maxChars }));
      const truncated = value.length > maxChars ? `\n\n… truncated, ${value.length - maxChars} more characters (raise max_chars or pass a selector)` : '';
      return text(`${note}${value.title} — ${value.url}\n\n${value.content}${truncated}`);
    },
  },
  {
    name: 'click',
    description: 'Click an element by ref, CSS selector or visible text, using DOM events (pointer, mouse, click). Reports the element that is on top at that point if something else covers it. For a real touch (native gesture recognizers, hit-testing), tap the simulator instead.',
    inputSchema: { type: 'object', properties: { ...elementTarget, ...target, ...frame } },
    async run(args) {
      const before = await evaluate(args, 'location.href');
      const { value, note } = await evaluate(args, script('click', { ref: args.ref, selector: args.selector, text: args.text }));
      await new Promise((resolve) => setTimeout(resolve, 400));
      let after = null;
      try { after = await evaluate(args, '({ url: location.href, title: document.title })'); } catch { /* page is navigating */ }
      const lines = [`Clicked ${value.clicked} at ${value.at.join(',')}`];
      if (value.coveredBy) { lines.push(`Warning: ${value.coveredBy} is on top of it at that point, so a real tap would hit that instead.`); }
      if (after && after.value.url !== before.value) { lines.push(`Page changed to ${after.value.url} (${after.value.title})`); }
      if (!after) { lines.push('The page is navigating.'); }
      return text(note + lines.join('\n'));
    },
  },
  {
    name: 'fill',
    description: 'Set the value of an input, textarea, select, checkbox or contenteditable, firing input/change events the way frameworks (React, Vue, Angular) expect. Optionally press Enter / submit the form.',
    inputSchema: {
      type: 'object',
      properties: {
        value: { type: 'string', description: 'Text to set. For a select, the option value or label; for a checkbox, "true" or "false".' },
        submit: { type: 'boolean', description: 'Press Enter and submit the form afterwards.' },
        ...elementTarget,
        ...target,
        ...frame,
      },
      required: ['value'],
    },
    async run(args) {
      const { value, note } = await evaluate(args, script('fill', { ref: args.ref, selector: args.selector, text: args.text, value: args.value, submit: Boolean(args.submit) }));
      const verb = typeof value.value === 'boolean' ? `${value.value ? 'Checked' : 'Unchecked'} ${value.filled}` : `Filled ${value.filled} with ${JSON.stringify(value.value)}`;
      return text(`${note}${verb}${args.submit ? ' and submitted' : ''}`);
    },
  },
  {
    name: 'scroll',
    description: 'Scroll the page: to an element (ref, selector or text), to "top" or "bottom", or by a number of pixels.',
    inputSchema: {
      type: 'object',
      properties: {
        to: { type: 'string', enum: ['top', 'bottom'] },
        by: { type: 'integer', description: 'Pixels to scroll down (negative for up). Default: most of a screen.' },
        ...elementTarget,
        ...target,
        ...frame,
      },
    },
    async run(args) {
      const { value, note } = await evaluate(args, script('scroll', { ref: args.ref, selector: args.selector, text: args.text, to: args.to, by: args.by }));
      return text(note + json(value));
    },
  },
  {
    name: 'wait_for',
    description: 'Wait until an element matching a selector, or some text, appears (or disappears with gone: true).',
    inputSchema: {
      type: 'object',
      properties: {
        selector: { type: 'string' },
        text: { type: 'string' },
        gone: { type: 'boolean', description: 'Wait for it to disappear instead.' },
        visible: { type: 'boolean', description: 'With selector: also require a non-zero size.' },
        timeout_ms: { type: 'integer', description: 'Default 10000.' },
        ...target,
        ...frame,
      },
    },
    async run(args) {
      if (!args.selector && !args.text) { throw new ToolError('Pass selector or text'); }
      const timeoutMs = args.timeout_ms || 10000;
      const { value, note } = await evaluate(args, script('waitFor', { selector: args.selector, text: args.text, gone: Boolean(args.gone), visible: Boolean(args.visible), timeoutMs }), timeoutMs + 2000);
      const what = args.selector ? `"${args.selector}"` : `text "${args.text}"`;
      return text(note + (value.matched
        ? `${what} ${args.gone ? 'is gone' : 'appeared'} after ${value.waitedMs} ms (${value.url})`
        : `Timed out after ${value.waitedMs} ms: ${what} ${args.gone ? 'is still there' : 'never appeared'} (${value.url})`));
    },
  },
  {
    name: 'console_messages',
    description: 'Console output of the page and its iframes: console.log/info/warn/error/debug, failed assertions, uncaught exceptions, unhandled promise rejections, resources that failed to load and CSP violations. Recorded from document start, also while no client is connected.',
    inputSchema: {
      type: 'object',
      properties: {
        level: { type: 'array', items: { type: 'string', enum: ['log', 'info', 'warn', 'error', 'debug'] } },
        search: { type: 'string', description: 'Only messages containing this text.' },
        since: { type: 'integer', description: 'Only entries with a sequence number above this (the #N in earlier output).' },
        limit: { type: 'integer', description: 'Most recent N entries (default 100).' },
        clear: { type: 'boolean', description: 'Clear the buffer after reading.' },
        ...target,
      },
    },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result, note } = await call(args, 'GET', '/console', {
        webview: args.webview, level: args.level, search: args.search, since: args.since, limit: args.limit || 100, clear: args.clear,
      });
      if (result.entries.length === 0) {
        return text(`${note}No console messages${args.level || args.search || args.since ? ' match' : ' yet'}. (last #${result.lastSeq})`);
      }
      const header = result.matched > result.entries.length ? `Showing the last ${result.entries.length} of ${result.matched}.\n` : '';
      return text(note + header + formatConsole(result.entries));
    },
  },
  {
    name: 'list_network_requests',
    description: 'Requests made by the page: fetch and XMLHttpRequest with status, headers and bodies, plus documents, scripts, images and styles (URL and timing only). Use get_network_request for the full detail of one.',
    inputSchema: {
      type: 'object',
      properties: {
        url_substring: { type: 'string' },
        method: { type: 'string' },
        kind: { type: 'array', items: { type: 'string' }, description: 'fetch, xhr, document, script, img, css, link, other…' },
        failed_only: { type: 'boolean', description: 'Only network errors and HTTP status >= 400.' },
        status_min: { type: 'integer' },
        status_max: { type: 'integer' },
        since: { type: 'integer' },
        limit: { type: 'integer', description: 'Most recent N (default 100).' },
        clear: { type: 'boolean' },
        ...target,
      },
    },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result, note } = await call(args, 'GET', '/network', {
        webview: args.webview, url: args.url_substring, method: args.method, kind: args.kind, failed: args.failed_only,
        statusMin: args.status_min, statusMax: args.status_max, since: args.since, limit: args.limit || 100, clear: args.clear,
      });
      if (result.requests.length === 0) {
        return text(`${note}No requests match.`);
      }
      const header = result.matched > result.requests.length ? `Showing the last ${result.requests.length} of ${result.matched}.\n` : '';
      return text(note + header + formatNetwork(result.requests));
    },
  },
  {
    name: 'get_network_request',
    description: 'Full detail of one request from list_network_requests: headers, request and response bodies (text bodies, truncated at 64 KB), timing and error.',
    inputSchema: { type: 'object', properties: { id: { type: 'string', description: 'The [id] from list_network_requests.' }, ...target }, required: ['id'] },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result, note } = await call(args, 'GET', '/network/entry', { webview: args.webview, id: args.id });
      return text(note + json(result.request));
    },
  },
  {
    name: 'navigation_history',
    description: 'What the web view loaded, in order: documents, URL changes, load start/finish seen natively, and in-page navigation (pushState, replaceState, popstate, hashchange). Useful for redirects, double loads and single-page-app routing bugs.',
    inputSchema: { type: 'object', properties: { limit: { type: 'integer', description: 'Most recent N (default 50).' }, since: { type: 'integer' }, ...target } },
    annotations: { readOnlyHint: true },
    async run(args) {
      const { result, note } = await call(args, 'GET', '/navigation', { webview: args.webview, limit: args.limit || 50, since: args.since });
      const lines = result.entries.map((e) => `#${e.seq} ${time(e.time)} ${String(e.source).padEnd(6)} ${String(e.event).padEnd(16)} ${e.url || ''}${e.title ? `  "${e.title}"` : ''}${e.detail ? `\n      ${e.detail}` : ''}`);
      return text(note + (lines.join('\n') || 'Nothing recorded yet.'));
    },
  },
  {
    name: 'navigate',
    description: 'Load a URL in the web view, or reload, go back, go forward or stop. Waits for the load to finish unless wait is false.',
    inputSchema: {
      type: 'object',
      properties: {
        url: { type: 'string' },
        action: { type: 'string', enum: ['load', 'reload', 'back', 'forward', 'stop'] },
        wait: { type: 'boolean', description: 'Wait for loading to finish (default true).' },
        ...target,
      },
    },
    async run(args) {
      const action = args.action || (args.url ? 'load' : 'reload');
      const { result: before } = await call(args, 'GET', '/navigation', { webview: args.webview, limit: 1 });
      const lastSeq = before.entries.length ? before.entries[before.entries.length - 1].seq : 0;
      const { result, note } = await call(args, 'POST', '/navigate', {
        webview: args.webview, url: args.url, action, wait: args.wait !== false, timeoutMs: 20000,
      }, 30000);
      const view = result.webView;
      const lines = [`${action}: now at ${view.url || 'about:blank'} "${view.title || ''}"${view.isLoading ? ' (still loading)' : ''}`];
      const { result: afterwards } = await call(args, 'GET', '/navigation', { webview: args.webview, since: lastSeq });
      const failure = afterwards.entries.find((entry) => entry.event === 'loadFailed');
      if (failure) {
        lines.push(`Load failed: ${failure.url}. ${failure.detail}`);
      }
      if (!view.visible) {
        lines.push('Note: this web view is not on screen. WebKit may delay loading and running pages in a web view that is not in a window.');
      }
      return text(note + lines.join('\n'));
    },
  },
  {
    name: 'screenshot',
    description: 'Screenshot of the web view as WebKit renders it. With full_screen on a simulator, captures the whole screen instead, native UI included.',
    inputSchema: {
      type: 'object',
      properties: {
        full_screen: { type: 'boolean', description: 'Capture the whole simulator screen (simulators only).' },
        scale: { type: 'number', description: 'Pixels per point for web view captures (default 1, use 2 or 3 for full detail).' },
        save_path: { type: 'string', description: 'Where to write the PNG. Defaults to a temporary file.' },
        ...target,
      },
    },
    annotations: { readOnlyHint: true },
    async run(args) {
      const path = args.save_path || join(tmpdir(), `wkwebview-mcp-${Date.now()}.png`);
      let note = '';
      if (args.full_screen) {
        const apps = await discoverApps();
        const { port, note: resolvedNote } = await resolveApp(args.app);
        note = resolvedNote;
        const app = apps.find((candidate) => candidate.port === port);
        if (!app?.device?.simulator || !app.device.udid) {
          throw new ToolError('full_screen needs the app to run in a simulator. Leave it off to capture the web view.');
        }
        await new Promise((resolve, reject) => execFile('xcrun', ['simctl', 'io', app.device.udid, 'screenshot', path], (error, _stdout, stderr) => (error ? reject(new ToolError(stderr || error.message)) : resolve())));
      } else {
        const { result, note: resolvedNote } = await call(args, 'GET', '/snapshot', { webview: args.webview, scale: args.scale || 1 }, 20000);
        note = resolvedNote;
        writeFileSync(path, result);
      }
      const data = readFileSync(path).toString('base64');
      return {
        content: [
          { type: 'image', data, mimeType: 'image/png' },
          { type: 'text', text: `${note}Saved to ${path}` },
        ],
      };
    },
  },
  {
    name: 'clear_logs',
    description: 'Clear the recorded console, network or navigation log (or all of them), e.g. before reproducing a bug.',
    inputSchema: { type: 'object', properties: { what: { type: 'string', enum: ['all', 'console', 'network', 'navigation'] }, ...target } },
    async run(args) {
      const { note } = await call(args, 'POST', '/clear', { webview: args.webview, what: args.what || 'all' });
      return text(`${note}Cleared ${args.what || 'all'}.`);
    },
  },
];

// ---------------------------------------------------------------------------------------------
// MCP over stdio (JSON-RPC 2.0, one message per line)

const INSTRUCTIONS = `Debugs WKWebViews inside iOS apps (native, Capacitor, Cordova, React Native, Flutter) running in the simulator or on a USB-connected device.
Start with list_apps to see what is running. Then read the page with get_page_content (format "interactive" gives refs for click and fill), check console_messages and list_network_requests for errors, and use evaluate_javascript for anything else.
Logs are recorded from page start, so reproduce first and read afterwards; clear_logs gives a clean slate.`;

function send(message) {
  process.stdout.write(JSON.stringify(message) + '\n');
}

async function handle(message) {
  const { id, method, params } = message;
  const isRequest = id !== undefined && id !== null;

  switch (method) {
    case 'initialize': {
      const requested = params?.protocolVersion;
      return {
        protocolVersion: SUPPORTED_PROTOCOLS.includes(requested) ? requested : SUPPORTED_PROTOCOLS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: 'wkwebview-mcp', title: 'WKWebView debugger', version: VERSION },
        instructions: INSTRUCTIONS,
      };
    }
    case 'ping':
      return {};
    case 'tools/list':
      return {
        tools: TOOLS.map(({ name, description, inputSchema, annotations }) => ({
          name, description, inputSchema, ...(annotations ? { annotations } : {}),
        })),
      };
    case 'tools/call': {
      const tool = TOOLS.find((candidate) => candidate.name === params?.name);
      if (!tool) {
        throw Object.assign(new Error(`Unknown tool: ${params?.name}`), { code: -32602 });
      }
      try {
        return await tool.run(params.arguments || {});
      } catch (error) {
        const message = error instanceof ToolError ? error.message : `${error.name}: ${error.message}`;
        return { content: [{ type: 'text', text: message }], isError: true };
      }
    }
    default:
      if (isRequest) {
        throw Object.assign(new Error(`Method not found: ${method}`), { code: -32601 });
      }
      return undefined; // notifications we do not need (initialized, cancelled, …)
  }
}

function serve() {
  const lines = createInterface({ input: process.stdin });
  lines.on('line', async (line) => {
    if (!line.trim()) { return; }
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      send({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'Parse error' } });
      return;
    }
    const isRequest = message.id !== undefined && message.id !== null;
    try {
      const result = await handle(message);
      if (isRequest) { send({ jsonrpc: '2.0', id: message.id, result }); }
    } catch (error) {
      if (isRequest) { send({ jsonrpc: '2.0', id: message.id, error: { code: error.code || -32603, message: error.message } }); }
    }
  });
  lines.on('close', () => process.exit(0));
}

// ---------------------------------------------------------------------------------------------
// CLI

const command = process.argv[2];
if (command === '--version' || command === '-v') {
  console.log(VERSION);
} else if (command === '--help' || command === '-h') {
  console.log(`wkwebview-mcp ${VERSION}: MCP server for debugging WKWebViews in iOS apps.

Usage:
  wkwebview-mcp            Run the MCP server on stdio (what MCP clients launch).
  wkwebview-mcp doctor     List the apps it can see right now.

Environment:
  WKWEBVIEW_MCP_HOST        Host to connect to (default 127.0.0.1)
  WKWEBVIEW_MCP_PORT        First port to scan (default 9333)
  WKWEBVIEW_MCP_PORT_RANGE  How many ports to scan (default 10)`);
} else if (command === 'doctor') {
  const result = await TOOLS.find((tool) => tool.name === 'list_apps').run({});
  console.log(result.content[0].text);
} else {
  serve();
}
