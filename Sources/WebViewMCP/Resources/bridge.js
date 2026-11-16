// wkwebview-mcp page bridge.
//
// Injected at document start into every frame of a registered WKWebView, in the page's own
// JavaScript world, so it sees the same `console`, `fetch` and `XMLHttpRequest` the page uses.
// It reports to the native side through `webkit.messageHandlers.__wvdbg` and never changes
// what the page observes: every wrapper calls through to the original and returns its result.
(function () {
  'use strict';

  if (window.__wvdbg) { return; }
  var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.__wvdbg;
  if (!handler) { return; }

  var MAX_BODY = __WVDBG_MAX_BODY__;
  var MAX_ARG = 4000;
  var frameId = Math.random().toString(36).slice(2, 10);
  var isMainFrame = window === window.top;
  var sequence = 0;

  Object.defineProperty(window, '__wvdbg', {
    value: Object.freeze({ frameId: frameId, version: '__WVDBG_VERSION__' }),
    enumerable: false
  });

  function post(message) {
    message.frameId = frameId;
    message.time = Date.now();
    try {
      handler.postMessage(message);
    } catch (error) {
      try {
        handler.postMessage({ type: 'internal', frameId: frameId, time: Date.now(), error: String(error) });
      } catch (_) {}
    }
  }

  function truncate(text, limit) {
    if (typeof text !== 'string') { return text; }
    return text.length > limit ? text.slice(0, limit) + '… [' + (text.length - limit) + ' more chars]' : text;
  }

  function formatError(error) {
    var head = (error.name || 'Error') + ': ' + error.message;
    return error.stack ? head + '\n' + error.stack : head;
  }

  function describe(value) {
    if (value === undefined) { return 'undefined'; }
    if (value === null) { return 'null'; }
    var type = typeof value;
    if (type === 'string') { return value; }
    if (type === 'number' || type === 'boolean' || type === 'bigint' || type === 'symbol') { return String(value); }
    if (type === 'function') { return '[Function ' + (value.name || 'anonymous') + ']'; }
    if (value instanceof Error) { return formatError(value); }
    if (typeof Element !== 'undefined' && value instanceof Element) { return truncate(value.outerHTML, 300); }
    try {
      var seen = new WeakSet();
      return JSON.stringify(value, function (key, item) {
        if (typeof item === 'bigint') { return item.toString(); }
        if (typeof item === 'function') { return '[Function]'; }
        if (item instanceof Error) { return item.name + ': ' + item.message; }
        if (item && typeof item === 'object') {
          if (seen.has(item)) { return '[Circular]'; }
          seen.add(item);
        }
        return item;
      });
    } catch (_) {
      return String(value);
    }
  }

  function callerLocation() {
    var stack = new Error().stack || '';
    var lines = stack.split('\n');
    // 0: callerLocation, 1: the console wrapper, 2: whoever called console.*
    return lines[2] || undefined;
  }

  // Console ----------------------------------------------------------------------------------

  ['log', 'info', 'warn', 'error', 'debug'].forEach(function (level) {
    var original = console[level];
    if (typeof original !== 'function') { return; }
    console[level] = function () {
      try {
        var parts = Array.prototype.map.call(arguments, function (argument) {
          return truncate(describe(argument), MAX_ARG);
        });
        post({ type: 'console', level: level, message: parts.join(' '), source: callerLocation() });
      } catch (_) {}
      return original.apply(console, arguments);
    };
  });

  var originalAssert = console.assert;
  if (typeof originalAssert === 'function') {
    console.assert = function (condition) {
      if (!condition) {
        try {
          var parts = Array.prototype.slice.call(arguments, 1).map(function (argument) {
            return truncate(describe(argument), MAX_ARG);
          });
          post({ type: 'console', level: 'error', kind: 'assert', message: 'Assertion failed: ' + parts.join(' '), source: callerLocation() });
        } catch (_) {}
      }
      return originalAssert.apply(console, arguments);
    };
  }

  window.addEventListener('error', function (event) {
    var target = event.target;
    if (target && target !== window && (target.src || target.href)) {
      post({ type: 'console', level: 'error', kind: 'resource', message: 'Failed to load ' + target.tagName.toLowerCase() + ': ' + (target.src || target.href) });
      return;
    }
    post({
      type: 'console',
      level: 'error',
      kind: 'exception',
      message: event.message || 'Script error.',
      source: event.filename ? event.filename + ':' + event.lineno + ':' + event.colno : undefined,
      stack: event.error && event.error.stack ? String(event.error.stack) : undefined
    });
  }, true);

  window.addEventListener('unhandledrejection', function (event) {
    var reason = event.reason;
    post({
      type: 'console',
      level: 'error',
      kind: 'unhandledrejection',
      message: 'Unhandled promise rejection: ' + (reason instanceof Error ? (reason.name || 'Error') + ': ' + reason.message : truncate(describe(reason), MAX_ARG)),
      stack: reason && reason.stack ? String(reason.stack) : undefined
    });
  });

  document.addEventListener('securitypolicyviolation', function (event) {
    post({
      type: 'console',
      level: 'error',
      kind: 'csp',
      message: 'Content Security Policy: ' + event.violatedDirective + ' blocked ' + (event.blockedURI || 'inline')
    });
  });

  // Network ----------------------------------------------------------------------------------

  function nextId() {
    sequence += 1;
    return frameId + '-' + sequence;
  }

  function absoluteURL(url) {
    try { return new URL(url, location.href).href; } catch (_) { return String(url); }
  }

  function headersToObject(headers) {
    var result = {};
    if (!headers) { return result; }
    try {
      if (typeof headers.forEach === 'function' && !Array.isArray(headers)) {
        headers.forEach(function (value, key) { result[key] = String(value); });
      } else if (Array.isArray(headers)) {
        headers.forEach(function (pair) { result[pair[0]] = String(pair[1]); });
      } else {
        Object.keys(headers).forEach(function (key) { result[key] = String(headers[key]); });
      }
    } catch (_) {}
    return result;
  }

  function parseRawHeaders(raw) {
    var result = {};
    (raw || '').trim().split(/[\r\n]+/).forEach(function (line) {
      var index = line.indexOf(':');
      if (index > 0) { result[line.slice(0, index).trim().toLowerCase()] = line.slice(index + 1).trim(); }
    });
    return result;
  }

  function bodyToString(body) {
    if (body === undefined || body === null) { return undefined; }
    if (typeof body === 'string') { return truncate(body, MAX_BODY); }
    if (typeof URLSearchParams !== 'undefined' && body instanceof URLSearchParams) { return truncate(body.toString(), MAX_BODY); }
    if (typeof FormData !== 'undefined' && body instanceof FormData) {
      var parts = [];
      body.forEach(function (value, key) {
        parts.push(key + '=' + (typeof value === 'string' ? value : '[File ' + value.name + ', ' + value.size + ' bytes]'));
      });
      return truncate(parts.join('&'), MAX_BODY);
    }
    if (typeof Blob !== 'undefined' && body instanceof Blob) { return '[Blob, ' + body.size + ' bytes]'; }
    if (body instanceof ArrayBuffer || ArrayBuffer.isView(body)) { return '[Binary, ' + body.byteLength + ' bytes]'; }
    return '[' + Object.prototype.toString.call(body) + ']';
  }

  function isTextual(contentType) {
    return !contentType || /json|text|xml|javascript|x-www-form-urlencoded|graphql/i.test(contentType);
  }

  var originalFetch = window.fetch;
  if (typeof originalFetch === 'function') {
    window.fetch = function (input, init) {
      var id = nextId();
      var started = performance.now();
      try {
        var method = 'GET';
        var url;
        var requestHeaders = {};
        if (typeof Request !== 'undefined' && input instanceof Request) {
          url = input.url;
          method = input.method;
          requestHeaders = headersToObject(input.headers);
        } else {
          url = absoluteURL(String(input));
        }
        var requestBody;
        if (init) {
          if (init.method) { method = String(init.method).toUpperCase(); }
          if (init.headers) { requestHeaders = Object.assign(requestHeaders, headersToObject(init.headers)); }
          requestBody = bodyToString(init.body);
        }
        post({ type: 'network', phase: 'start', id: id, kind: 'fetch', method: method, url: url, requestHeaders: requestHeaders, requestBody: requestBody });
      } catch (_) {}

      return originalFetch.apply(this, arguments).then(function (response) {
        try {
          var contentType = response.headers.get('content-type') || '';
          post({
            type: 'network',
            phase: 'end',
            id: id,
            status: response.status,
            statusText: response.statusText,
            responseURL: response.url,
            redirected: response.redirected,
            mimeType: contentType,
            responseHeaders: headersToObject(response.headers),
            duration: Math.round(performance.now() - started)
          });
          // The body is read from a clone and reported separately, so a streaming response
          // (server-sent events, a long download) still shows as finished above.
          if (isTextual(contentType) && response.type !== 'opaque') {
            response.clone().text().then(function (text) {
              post({ type: 'network', phase: 'body', id: id, responseBody: truncate(text, MAX_BODY), responseSize: text.length });
            }, function () {});
          }
        } catch (_) {}
        return response;
      }, function (error) {
        post({ type: 'network', phase: 'end', id: id, error: String(error && error.message || error), duration: Math.round(performance.now() - started) });
        throw error;
      });
    };
  }

  var XHR = window.XMLHttpRequest;
  if (XHR) {
    var originalOpen = XHR.prototype.open;
    var originalSend = XHR.prototype.send;
    var originalSetRequestHeader = XHR.prototype.setRequestHeader;

    XHR.prototype.open = function (method, url) {
      this.__wvdbgRequest = { id: nextId(), method: String(method).toUpperCase(), url: absoluteURL(url), headers: {} };
      return originalOpen.apply(this, arguments);
    };

    XHR.prototype.setRequestHeader = function (name, value) {
      if (this.__wvdbgRequest) { this.__wvdbgRequest.headers[name] = String(value); }
      return originalSetRequestHeader.apply(this, arguments);
    };

    XHR.prototype.send = function (body) {
      var request = this.__wvdbgRequest;
      if (request) {
        var xhr = this;
        var started = performance.now();
        post({ type: 'network', phase: 'start', id: request.id, kind: 'xhr', method: request.method, url: request.url, requestHeaders: request.headers, requestBody: bodyToString(body) });
        xhr.addEventListener('loadend', function () {
          var message = {
            type: 'network',
            phase: 'end',
            id: request.id,
            status: xhr.status,
            statusText: xhr.statusText,
            responseURL: xhr.responseURL,
            mimeType: xhr.getResponseHeader('content-type') || '',
            responseHeaders: parseRawHeaders(xhr.getAllResponseHeaders()),
            duration: Math.round(performance.now() - started)
          };
          if (xhr.status === 0) { message.error = 'Request failed (network error, CORS, timeout or abort)'; }
          try {
            if (xhr.responseType === '' || xhr.responseType === 'text') {
              message.responseBody = truncate(xhr.responseText, MAX_BODY);
              message.responseSize = xhr.responseText.length;
            } else if (xhr.responseType === 'json') {
              message.responseBody = truncate(JSON.stringify(xhr.response), MAX_BODY);
            }
          } catch (_) {}
          post(message);
        });
      }
      return originalSend.apply(this, arguments);
    };
  }

  // Everything fetch/XHR wrappers cannot see (documents, scripts, images, styles) comes from
  // Resource Timing: URL and timing only, no headers or bodies.
  function observe(type) {
    try {
      new PerformanceObserver(function (list) {
        list.getEntries().forEach(function (entry) {
          if (entry.initiatorType === 'fetch' || entry.initiatorType === 'xmlhttprequest') { return; }
          post({
            type: 'network',
            phase: 'resource',
            id: nextId(),
            kind: type === 'navigation' ? 'document' : (entry.initiatorType || 'resource'),
            method: 'GET',
            url: entry.name,
            status: entry.responseStatus || undefined,
            transferSize: entry.transferSize,
            duration: Math.round(entry.duration)
          });
        });
      }).observe({ type: type, buffered: true });
    } catch (_) {}
  }
  if (window.PerformanceObserver) {
    observe('navigation');
    observe('resource');
  }

  // Navigation -------------------------------------------------------------------------------

  function navigation(event) {
    post({ type: 'navigation', event: event, url: location.href, title: document.title });
  }

  ['pushState', 'replaceState'].forEach(function (name) {
    var original = history[name];
    if (typeof original !== 'function') { return; }
    history[name] = function () {
      var result = original.apply(this, arguments);
      navigation(name);
      return result;
    };
  });
  window.addEventListener('popstate', function () { navigation('popstate'); });
  window.addEventListener('hashchange', function () { navigation('hashchange'); });
  document.addEventListener('DOMContentLoaded', function () { navigation('DOMContentLoaded'); });
  window.addEventListener('load', function () { navigation('load'); });
  window.addEventListener('pagehide', function () { navigation('pagehide'); });

  post({ type: 'hello', isMainFrame: isMainFrame, url: location.href, referrer: document.referrer, readyState: document.readyState });
})();
