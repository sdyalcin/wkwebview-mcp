import Foundation
import WebKit

enum JavaScript {
  /// Turns caller code into a function body for `callAsyncJavaScript` that always returns a
  /// JSON string `{ type, value }`, so DOM nodes, cycles, BigInts and functions come back as
  /// something readable instead of failing WebKit's own serialization.
  ///
  /// Code is a function body: `await` works and `return` gives the result. A single expression
  /// with no `return` (`document.title`) is returned for you.
  static func wrap(_ code: String) -> String {
    """
    const __wvdbgValue = await (async () => {
    \(implicitReturn(code))
    })();
    const __wvdbgType = __wvdbgValue === null ? 'null'
      : Array.isArray(__wvdbgValue) ? 'array'
      : (typeof Element !== 'undefined' && __wvdbgValue instanceof Element) ? 'element'
      : typeof __wvdbgValue;
    const __wvdbgSeen = new WeakSet();
    try {
      return JSON.stringify({ type: __wvdbgType, value: __wvdbgValue }, function (key, item) {
        if (typeof Element !== 'undefined' && item instanceof Element) {
          const html = item.outerHTML;
          return html.length > 2000 ? html.slice(0, 2000) + '…' : html;
        }
        if (typeof NodeList !== 'undefined' && (item instanceof NodeList || item instanceof HTMLCollection)) {
          return Array.from(item);
        }
        if (typeof item === 'bigint') { return item.toString(); }
        if (typeof item === 'function') { return '[Function ' + (item.name || 'anonymous') + ']'; }
        if (typeof item === 'symbol') { return item.toString(); }
        if (item instanceof Error) { return item.name + ': ' + item.message; }
        if (typeof Window !== 'undefined' && item instanceof Window) { return '[Window ' + item.location.href + ']'; }
        if (item && typeof item === 'object') {
          if (__wvdbgSeen.has(item)) { return '[Circular]'; }
          __wvdbgSeen.add(item);
        }
        return item;
      });
    } catch (error) {
      return JSON.stringify({ type: __wvdbgType, value: String(__wvdbgValue) });
    }
    """
  }

  static func implicitReturn(_ code: String) -> String {
    var body = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.hasSuffix(";") {
      let withoutSemicolon = String(body.dropLast())
      if !withoutSemicolon.contains(";") {
        body = withoutSemicolon
      }
    }
    let isSingleExpression = !body.contains("\n")
      && !body.contains(";")
      && !body.hasPrefix("return")
      && !startsWithStatementKeyword(body)
    return isSingleExpression ? "return (\(body));" : code
  }

  private static func startsWithStatementKeyword(_ code: String) -> Bool {
    let keywords = ["const ", "let ", "var ", "if ", "if(", "for ", "for(", "while ", "while(", "throw ", "try ", "try{", "function ", "class ", "switch ", "switch(", "do ", "do{"]
    return keywords.contains { code.hasPrefix($0) }
  }

  /// A JavaScript exception thrown by `callAsyncJavaScript`, as a JSON-ready dictionary.
  static func describe(_ error: Error) -> [String: Any] {
    let nsError = error as NSError
    var result: [String: Any] = ["ok": false]
    let userInfo = nsError.userInfo
    if let message = userInfo["WKJavaScriptExceptionMessage"] as? String {
      result["error"] = message
      result["exception"] = true
      if let line = userInfo["WKJavaScriptExceptionLineNumber"] as? Int {
        // Line 1 of the wrapper is the async arrow function opening the caller's code.
        result["line"] = max(line - 1, 1)
      }
      if let column = userInfo["WKJavaScriptExceptionColumnNumber"] as? Int {
        result["column"] = column
      }
    } else {
      result["error"] = nsError.localizedDescription
    }
    return result
  }
}
