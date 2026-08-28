import Foundation

/// The JavaScript behind the DOM half of the step vocabulary.
///
/// Every snippet is a self-contained expression: nothing is left on `window`,
/// so a navigation cannot leave the engine talking to a stale helper, and a
/// page cannot tamper with one. Values are injected as JSON literals rather
/// than string-concatenated, so a selector containing a quote is a selector,
/// not an injection.
///
/// Note the deliberate restraint in `click` and `type`. They dispatch the
/// events a real interaction produces so that React and Vue forms notice the
/// change — and they stop there. There is no fingerprint spoofing, no
/// `navigator.webdriver` deletion, no captcha handling: §8.4 of the
/// specification forbids circumventing a portal's protections, and a plugin
/// that hits one is supposed to fail and ask the user to step in.
enum DOMScripts {

    /// Resolves the three selector flavours the format supports:
    /// `css`, `text=Visible label`, `xpath=//…`.
    static let prelude = """
    const __find = (sel) => {
      if (sel.startsWith('xpath=')) {
        const r = document.evaluate(sel.slice(6), document, null,
                                    XPathResult.FIRST_ORDERED_NODE_TYPE, null);
        return r.singleNodeValue;
      }
      if (sel.startsWith('text=')) {
        const needle = sel.slice(5).trim().toLowerCase();
        const nodes = document.querySelectorAll('a, button, [role="button"], label, span, div, td, li, h1, h2, h3');
        for (const n of nodes) {
          const t = (n.innerText || n.textContent || '').trim().toLowerCase();
          if (t === needle) return n;
        }
        for (const n of nodes) {
          const t = (n.innerText || n.textContent || '').trim().toLowerCase();
          if (t.includes(needle)) return n;
        }
        return null;
      }
      return document.querySelector(sel);
    };
    const __findAll = (sel) => {
      if (sel.startsWith('xpath=')) {
        const out = [];
        const r = document.evaluate(sel.slice(6), document, null,
                                    XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
        for (let i = 0; i < r.snapshotLength; i++) out.push(r.snapshotItem(i));
        return out;
      }
      if (sel.startsWith('text=')) { const e = __find(sel); return e ? [e] : []; }
      return Array.from(document.querySelectorAll(sel));
    };
    const __findIn = (root, sel) => {
      if (!sel) return root;
      if (sel.startsWith('xpath=')) {
        const r = document.evaluate(sel.slice(6), root, null,
                                    XPathResult.FIRST_ORDERED_NODE_TYPE, null);
        return r.singleNodeValue;
      }
      return root.querySelector(sel);
    };
    const __read = (el, attribute) => {
      if (!el) return null;
      if (!attribute) return (el.innerText || el.textContent || '').trim();
      if (attribute === 'value') return el.value != null ? String(el.value) : null;
      // href and src come back absolute, which is what a download step needs.
      if (attribute === 'href' && el.href != null) return el.href;
      if (attribute === 'src' && el.src != null) return el.src;
      const v = el.getAttribute(attribute);
      return v == null ? null : v;
    };
    """

    static func literal(_ value: String) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func literal<T: Encodable>(json value: T) -> String {
        let data = try! JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func exists(_ selector: String) -> String {
        """
        (function(){ \(prelude) return __find(\(literal(selector))) !== null; })()
        """
    }

    static func click(_ selector: String) -> String {
        """
        (function(){
          \(prelude)
          const el = __find(\(literal(selector)));
          if (!el) return { ok: false, reason: 'not-found' };
          el.scrollIntoView({ block: 'center' });
          // Fire the pointer sequence a real click produces; some frameworks
          // listen for mousedown rather than click.
          for (const type of ['pointerdown','mousedown','pointerup','mouseup']) {
            el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window }));
          }
          el.click();
          return { ok: true };
        })()
        """
    }

    static func type(_ selector: String, value: String, pressEnter: Bool) -> String {
        """
        (function(){
          \(prelude)
          const el = __find(\(literal(selector)));
          if (!el) return { ok: false, reason: 'not-found' };
          el.focus();
          const setter = Object.getOwnPropertyDescriptor(
            el instanceof HTMLTextAreaElement
              ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype, 'value');
          const text = \(literal(value));
          // Going through the native setter is what makes React notice: it
          // caches the previous value on the element and ignores a plain
          // assignment.
          if (setter && setter.set) { setter.set.call(el, text); }
          else if ('value' in el) { el.value = text; }
          else { el.textContent = text; }
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          \(pressEnter ? """
          el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
          el.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true }));
          if (el.form && typeof el.form.requestSubmit === 'function') { el.form.requestSubmit(); }
          """ : "")
          return { ok: true };
        })()
        """
    }

    static func select(_ selector: String, value: String) -> String {
        """
        (function(){
          \(prelude)
          const el = __find(\(literal(selector)));
          if (!el) return { ok: false, reason: 'not-found' };
          const wanted = \(literal(value));
          let matched = false;
          for (const option of el.options || []) {
            const label = (option.textContent || '').trim();
            if (option.value === wanted || label === wanted) { el.value = option.value; matched = true; break; }
          }
          if (!matched) return { ok: false, reason: 'no-such-option' };
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return { ok: true };
        })()
        """
    }

    static func extract(_ selector: String?, attribute: String?, from: ExtractSource) -> String {
        switch from {
        case .url:
            return "(function(){ return window.location.href; })()"
        case .title:
            return "(function(){ return document.title; })()"
        case .page:
            return "(function(){ return document.body ? document.body.innerText : ''; })()"
        case .element:
            return """
            (function(){
              \(prelude)
              const el = __find(\(literal(selector ?? "body")));
              return __read(el, \(attribute.map(literal) ?? "null"));
            })()
            """
        }
    }

    static func extractAll(_ selector: String, fields: [String: FieldSpec], limit: Int?) -> String {
        let specs = fields.mapValues { spec in
            ["selector": spec.selector, "attribute": spec.attribute]
        }
        return """
        (function(){
          \(prelude)
          const specs = \(literal(json: specs));
          const rows = __findAll(\(literal(selector)));
          const limit = \(limit.map(String.init) ?? "rows.length");
          const out = [];
          for (let i = 0; i < Math.min(rows.length, limit); i++) {
            const row = rows[i];
            const item = { __index: i, __text: (row.innerText || row.textContent || '').trim() };
            for (const key of Object.keys(specs)) {
              const spec = specs[key];
              const target = __findIn(row, spec.selector);
              item[key] = __read(target, spec.attribute);
            }
            out.push(item);
          }
          return out;
        })()
        """
    }

    /// The whole page as text, used by the metadata extractor when a portal
    /// shows an invoice as HTML rather than a PDF.
    static let pageText = "(function(){ return document.body ? document.body.innerText : ''; })()"

    static let readyState = "(function(){ return document.readyState; })()"
}
