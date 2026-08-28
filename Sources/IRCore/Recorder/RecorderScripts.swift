import Foundation

/// The JavaScript behind interactive plugin recording.
///
/// Two jobs. While the user drives the browser by hand, `observer` reports what
/// they did — where they went, what they clicked, which field they typed into.
/// Then `analysis` looks at whatever page they stopped on and works out where
/// the invoices are.
///
/// The second is the interesting half. A plugin's hard part is never the
/// navigation, it is `extractAll`: which element repeats, and which bit of a row
/// is the date, the amount, the number, the PDF. That is exactly what a person
/// can see at a glance and a contributor spends twenty minutes writing by hand
/// with an inspector open. The page already contains the answer — a billing
/// table is a set of siblings with the same shape — so the analyser finds the
/// repeating structure and classifies each column by what its text looks like.
///
/// **Values are never recorded.** A `type` event carries the field it happened
/// in and nothing else. Recording a password would put it in a JSON file the
/// user is about to open a pull request with, which is the worst outcome this
/// project has.
enum RecorderScripts {

    /// Builds a selector for one element, preferring the ones that survive a
    /// redesign. The order matters and is the same advice CONTRIBUTING gives.
    static let selectorHelper = """
    const __stable = (el) => {
      if (!el || el.nodeType !== 1) return null;
      // 1. Something someone put there on purpose.
      for (const attr of ['data-testid', 'data-test', 'data-test-id', 'data-cy', 'data-qa']) {
        const v = el.getAttribute(attr);
        if (v) return '[' + attr + '="' + CSS.escape(v) + '"]';
      }
      // 2. An id, unless it looks generated.
      if (el.id && !/[0-9a-f]{8}|^:r|^ember\\d/.test(el.id)) return '#' + CSS.escape(el.id);
      // 3. A form field's name.
      if (el.name && /^(input|select|textarea|button)$/i.test(el.tagName)) {
        return el.tagName.toLowerCase() + '[name="' + CSS.escape(el.name) + '"]';
      }
      // 4. An input distinguished by its type.
      if (/^input$/i.test(el.tagName) && el.type) {
        const same = document.querySelectorAll('input[type="' + el.type + '"]');
        if (same.length === 1) return 'input[type="' + el.type + '"]';
      }
      return null;
    };

    // Class names that carry meaning, as opposed to the ones a build tool made up.
    const __meaningfulClasses = (el) => Array.from(el.classList).filter(
      (c) => !/^(css|sc|jsx|emotion|styles)[-_]|^[a-z]{1,3}[0-9]{3,}$|[0-9a-f]{6,}/.test(c)
    );

    const __selectorFor = (el, root) => {
      const direct = __stable(el);
      if (direct && (root || document).querySelectorAll(direct).length === 1) return direct;

      // Walk up until the path is unique, keeping it as short as it can be.
      const parts = [];
      let node = el;
      while (node && node.nodeType === 1 && node !== (root || document.body)) {
        let part = node.tagName.toLowerCase();
        const stable = __stable(node);
        if (stable) {
          parts.unshift(stable);
          break;
        }
        const classes = __meaningfulClasses(node);
        if (classes.length) part += '.' + classes.slice(0, 2).map((c) => CSS.escape(c)).join('.');
        else {
          const siblings = node.parentElement
            ? Array.from(node.parentElement.children).filter((s) => s.tagName === node.tagName) : [];
          if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
        }
        parts.unshift(part);
        const candidate = parts.join(' > ');
        if ((root || document).querySelectorAll(candidate).length === 1) break;
        node = node.parentElement;
      }
      return parts.join(' > ') || el.tagName.toLowerCase();
    };
    """

    /// Injected at document start for the life of a recording. Reports the
    /// user's actions; reads no values.
    static let observer = """
    (function() {
      if (window.__irRecording) return;
      window.__irRecording = true;

      \(selectorHelper)

      const send = (event) => {
        try { window.webkit.messageHandlers.irRecorder.postMessage(event); } catch (e) {}
      };

      send({ kind: 'navigate', url: location.href, title: document.title });

      document.addEventListener('click', (e) => {
        const el = e.target.closest('a, button, [role="button"], input[type="submit"], label, li, td');
        if (!el) return;
        send({
          kind: 'click',
          selector: __selectorFor(el),
          tag: el.tagName.toLowerCase(),
          // Visible text helps a human read the recording back. It is a button
          // label, never a value.
          label: (el.innerText || el.value || '').trim().slice(0, 60),
          href: el.tagName === 'A' ? el.href : null,
          url: location.href
        });
      }, true);

      const seenFields = new Set();
      document.addEventListener('input', (e) => {
        const el = e.target;
        if (!/^(input|textarea|select)$/i.test(el.tagName)) return;
        const selector = __selectorFor(el);
        if (seenFields.has(selector)) return;
        seenFields.add(selector);
        send({
          kind: 'type',
          selector: selector,
          // The field's identity and nothing else. What was typed is not
          // recorded, ever: a password in a plugin file is the worst thing
          // this project could ship.
          fieldType: el.type || 'text',
          label: (el.labels && el.labels[0] ? el.labels[0].innerText : el.placeholder || el.name || '').trim().slice(0, 60),
          url: location.href
        });
      }, true);
    })();
    """

    /// Looks at the current page and works out where the invoices are.
    static let analysis = """
    (function() {
      \(selectorHelper)

      const MONEY = /^[^0-9]{0,3}-?[0-9][0-9\\s.,\\u00A0\\u202F]*(?:[.,][0-9]{2})?\\s*(?:€|EUR|\\\\$|USD|£|GBP|CHF)?$/i;
      const DATE = /^(?:[0-9]{1,2}[\\/.\\-][0-9]{1,2}[\\/.\\-][0-9]{2,4}|[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{1,2}\\s+\\p{L}{3,10}\\s+[0-9]{4})$/u;
      const REFERENCE = /^[A-Z0-9][A-Z0-9\\-\\/_.]{4,30}$/;

      // A row's shape: the tag path of its descendants. Two siblings with the
      // same shape are two rows of the same table, whatever the markup.
      const shape = (el) => {
        const parts = [];
        const walk = (n, d) => {
          if (d > 3) return;
          for (const c of n.children) { parts.push(d + c.tagName); walk(c, d + 1); }
        };
        walk(el, 0);
        return parts.join(',');
      };

      const candidates = [];
      for (const parent of document.querySelectorAll('body *')) {
        const children = Array.from(parent.children);
        if (children.length < 3 || children.length > 400) continue;
        const shapes = new Map();
        for (const c of children) {
          const s = shape(c);
          if (s.length < 4) continue;
          shapes.set(s, (shapes.get(s) || 0) + 1);
        }
        if (!shapes.size) continue;
        const [best, count] = [...shapes.entries()].sort((a, b) => b[1] - a[1])[0];
        if (count < 3) continue;

        const rows = children.filter((c) => shape(c) === best);
        const text = rows.map((r) => (r.innerText || '')).join(' ');
        // A billing table has dates and amounts in it. Rank on that rather than
        // on size, or the winner is always the navigation menu.
        const looksFinancial =
          (/[0-9]{1,2}[\\/.\\-][0-9]{1,2}[\\/.\\-][0-9]{2,4}|[0-9]{4}-[0-9]{2}-[0-9]{2}/.test(text) ? 3 : 0) +
          (/€|EUR|\\\\$|USD|CHF|£/.test(text) ? 3 : 0) +
          (rows.some((r) => r.querySelector('a[href*="pdf" i], a[download]')) ? 4 : 0);
        if (looksFinancial === 0) continue;

        candidates.push({ parent, rows, score: looksFinancial * 10 + Math.min(rows.length, 30) });
      }

      if (!candidates.length) return { found: false, url: location.href, title: document.title };

      candidates.sort((a, b) => b.score - a.score);
      const winner = candidates[0];
      const row = winner.rows[0];

      // Every leaf inside a row becomes a candidate column.
      const columns = [];
      const leaves = Array.from(row.querySelectorAll('*')).filter(
        (n) => n.children.length === 0 && (n.innerText || '').trim()
      );
      for (const leaf of leaves) {
        const samples = winner.rows.slice(0, 6).map((r) => {
          const sel = __selectorFor(leaf, row);
          const el = (() => { try { return r.querySelector(sel); } catch (e) { return null; } })();
          return el ? (el.innerText || '').trim() : '';
        }).filter(Boolean);
        if (!samples.length) continue;

        let kind = 'text';
        if (samples.every((s) => DATE.test(s))) kind = 'date';
        else if (samples.every((s) => MONEY.test(s) && /[0-9]/.test(s))) kind = 'money';
        else if (samples.every((s) => REFERENCE.test(s))) kind = 'reference';

        columns.push({
          selector: __selectorFor(leaf, row),
          kind: kind,
          samples: samples.slice(0, 3)
        });
      }

      // The download link, which is what a document step needs.
      let link = null;
      const anchor = row.querySelector('a[href*="pdf" i], a[download], a[href*="invoice" i], a[href*="facture" i]')
                  || row.querySelector('a[href]');
      if (anchor) {
        link = { selector: __selectorFor(anchor, row), href: anchor.href,
                 isPdf: /\\.pdf|pdf=/i.test(anchor.href) };
      }

      return {
        found: true,
        url: location.href,
        title: document.title,
        rowSelector: __selectorFor(row, null).replace(/:nth-of-type\\(\\d+\\)$/, ''),
        rowCount: winner.rows.length,
        columns: columns,
        link: link
      };
    })();
    """
}


/// The recorder's scripts, for browser drivers outside this module.
public enum RecorderScriptSource {
    /// Injected at document start for the life of a recording.
    public static var observer: String { RecorderScripts.observer }
    /// Run on demand against whatever page the user is looking at.
    public static var analysis: String { RecorderScripts.analysis }
}
