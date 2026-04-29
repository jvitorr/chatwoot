import DOMPurify from 'dompurify';

// Wrapper classes mainstream mail clients emit around the quoted reply.

const QUOTE_INDICATORS = [
  '.gmail_quote_container',
  '.gmail_quote',
  '.OutlookQuote',
  '.email-quote',
  '.quoted-text',
  '.quote',
  '[class*="quote"]',
  '[class*="Quote"]',
  '.moz-cite-prefix', // Thunderbird attribution
  '.yahoo_quoted', // Yahoo Mail wrapper
  '#divRplyFwdMsg', // Outlook web/desktop reply/forward header
];

// Soft attribution markers — match removes the containing block only.
// Anchored to a line start AND tightened so prose lines that legitimately
// begin with "From: " / "Sent: " don't false-trigger:
//   - From:  must be followed by email-shape content with `@` on the line
//            (real headers are "From: name <addr@host>" or "From: addr@host").
//   - Sent:  must be followed by a 4-digit year (real timestamps include one,
//            "Sent: yesterday by …" doesn't).
const SOFT_HEADERS = [/^On .* wrote:/im, /^From: .*@/im, /^Sent: .*\d{4}/im];

// Hard markers — match removes the containing block AND every following
// sibling within its parent, so the quoted body itself (not just the
// attribution) gets stripped on forwarded / reply-with-original messages.
// Anchored to a full line so a sentence containing the phrase ("the markdown
// for `-----Original Message-----` should render correctly") can't trigger.
const HARD_HEADERS = [
  /^\s*-+\s*Original Message\s*-+\s*$/im,
  /^\s*-+\s*Forwarded message\s*-+\s*$/im,
  /^\s*Begin forwarded message:\s*$/im,
];

const BLOCK_SELECTOR = 'div, p, blockquote, section';

export class EmailQuoteExtractor {
  // ---------- public API ----------

  static extractQuotes(html) {
    const root = this.parse(html);
    this.removeIndicatorElements(root);
    this.removeHardHeaderTails(root);
    this.removeTrailingBlockquote(root);
    this.removeSoftHeaderBlocks(root);
    this.removePlainTextTail(root);
    return root.innerHTML;
  }

  static hasQuotes(html) {
    const root = this.parse(html);
    return (
      this.hasIndicatorElement(root) ||
      this.findBlocksMatching(root, HARD_HEADERS).length > 0 ||
      this.hasTrailingBlockquote(root) ||
      this.findBlocksMatching(root, SOFT_HEADERS).length > 0 ||
      this.findPlainTextTailStart(root) !== -1
    );
  }

  // ---------- shared parser ----------

  static parse(html) {
    const root = document.createElement('div');
    root.innerHTML = DOMPurify.sanitize(html);
    return root;
  }

  // ---------- 1. Wrapper-class strip ----------

  static removeIndicatorElements(root) {
    QUOTE_INDICATORS.forEach(selector => {
      root.querySelectorAll(selector).forEach(el => el.remove());
    });
  }

  static hasIndicatorElement(root) {
    return QUOTE_INDICATORS.some(selector => root.querySelector(selector));
  }

  // ---------- 2. Hard header tails ----------
  // For each block that matches a hard header, trim from the marker child
  // forward (preserving any reply text that sits before the marker in the
  // same block) and then strip every following sibling at the parent level.

  static removeHardHeaderTails(root) {
    this.findBlocksMatching(root, HARD_HEADERS).forEach(block => {
      this.stripFromHardMarkerWithin(block);
      this.removeFollowingSiblings(block);
      if (block.childNodes.length === 0) block.remove();
    });
  }

  static stripFromHardMarkerWithin(block) {
    const children = Array.from(block.childNodes);
    const markerIdx = children.findIndex(child =>
      HARD_HEADERS.some(p => p.test(this.nodeText(child)))
    );
    if (markerIdx === -1) return;
    const start = this.walkBackOverNeutrals(children, markerIdx);
    for (let i = start; i < children.length; i += 1) children[i].remove();
  }

  static nodeText(node) {
    if (node.nodeType === Node.TEXT_NODE) return node.textContent;
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    return this.blockText(node);
  }

  static removeFollowingSiblings(node) {
    let cursor = node.nextSibling;
    while (cursor) {
      const next = cursor.nextSibling;
      cursor.remove();
      cursor = next;
    }
  }

  // ---------- 3. Trailing blockquote ----------

  static removeTrailingBlockquote(root) {
    const last = root.lastElementChild;
    if (last?.matches?.('blockquote')) last.remove();
  }

  static hasTrailingBlockquote(root) {
    return root.lastElementChild?.matches?.('blockquote') ?? false;
  }

  // ---------- 4. Soft header blocks ----------

  static removeSoftHeaderBlocks(root) {
    this.findBlocksMatching(root, SOFT_HEADERS).forEach(el => el.remove());
  }

  // ---------- shared block matcher ----------
  // Iterate DIV/P/BLOCKQUOTE/SECTION descendants. For each, read its text
  // treating <br> as a real newline so the line-anchored patterns work even
  // for `<p>From: Sam<br>Sent: …</p>` shapes.

  static findBlocksMatching(root, patterns) {
    const blocks = [];
    root.querySelectorAll(BLOCK_SELECTOR).forEach(el => {
      const text = this.blockText(el);
      if (patterns.some(p => p.test(text))) blocks.push(el);
    });
    return blocks;
  }

  static blockText(el) {
    const tmp = document.createElement('div');
    tmp.innerHTML = el.innerHTML.replace(/<br\s*\/?>/gi, '\n');
    return tmp.textContent;
  }

  // ---------- 5. Top-level RFC `>` / header tail ----------
  // Replies that arrive as text + <br> with no block wrapper. RFC `>`-prefixed
  // text only counts when nothing substantive follows it (preserves bottom /
  // inline posting). A header marker as a top-level text node is a hard cut.

  static removePlainTextTail(root) {
    const start = this.findPlainTextTailStart(root);
    if (start === -1) return;
    const nodes = Array.from(root.childNodes);
    for (let i = start; i < nodes.length; i += 1) nodes[i].remove();
  }

  static findPlainTextTailStart(root) {
    const children = Array.from(root.childNodes);
    for (let i = 0; i < children.length; i += 1) {
      const idx = this.tailStartAt(children, i);
      if (idx !== -1) return idx;
    }
    return -1;
  }

  static tailStartAt(children, i) {
    const node = children[i];
    if (this.isRfcQuotedTextNode(node)) {
      return this.isPureRfcTailFrom(children, i)
        ? this.walkBackOverNeutrals(children, i)
        : -1;
    }
    if (this.isHeaderMarkerTextNode(node)) {
      return this.walkBackOverNeutrals(children, i);
    }
    return -1;
  }

  static isRfcQuotedTextNode(node) {
    if (node.nodeType !== Node.TEXT_NODE) return false;
    const text = node.textContent;
    if (!text.trim()) return false;
    const lines = text.split('\n').filter(line => line.trim() !== '');
    return lines.length > 0 && lines.every(l => l.trim().startsWith('>'));
  }

  static isHeaderMarkerTextNode(node) {
    if (node.nodeType !== Node.TEXT_NODE) return false;
    const text = node.textContent;
    if (!text.trim()) return false;
    return [...SOFT_HEADERS, ...HARD_HEADERS].some(p => p.test(text));
  }

  static isPureRfcTailFrom(children, startIdx) {
    return children
      .slice(startIdx)
      .every(n => this.isRfcQuotedTextNode(n) || this.isNeutralNode(n));
  }

  static walkBackOverNeutrals(children, idx) {
    let start = idx;
    while (start > 0 && this.isNeutralNode(children[start - 1])) {
      start -= 1;
    }
    return start;
  }

  static isNeutralNode(node) {
    if (node.nodeType === Node.TEXT_NODE) {
      return node.textContent.trim() === '';
    }
    if (node.nodeType === Node.ELEMENT_NODE) {
      return node.tagName === 'BR';
    }
    return false;
  }
}
