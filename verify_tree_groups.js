#!/usr/bin/env node
// Offline DOM verification of the actual saved-report JavaScript. No native app/browser access.
'use strict';
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

class Element {
  constructor(tag, document) {
    this.tagName = tag.toUpperCase(); this.ownerDocument = document; this.children = [];
    this.parentElement = null; this.attributes = {}; this.dataset = {}; this.style = {};
    this.listeners = new Map(); this._text = ''; this._id = ''; this.className = '';
    this.value = ''; this.disabled = false; this.hidden = false; this.scrollTop = 0; this.clientHeight = 500;
    this.classList = {
      contains: name => this.className.split(/\s+/).includes(name),
      add: (...names) => { this.className = [...new Set([...this.className.split(/\s+/).filter(Boolean), ...names])].join(' '); },
      remove: (...names) => { this.className = this.className.split(/\s+/).filter(name => !names.includes(name)).join(' '); },
      toggle: (name, force) => { const add = force === undefined ? !this.classList.contains(name) : force; this.classList[add ? 'add' : 'remove'](name); return add; }
    };
  }
  get id() { return this._id; }
  set id(value) { this._id = String(value); }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(''); }
  set textContent(value) { this._text = String(value); this.replaceChildren(); }
  get innerHTML() { throw Error('The offline verifier does not permit HTML string rendering'); }
  set innerHTML(value) { throw Error('The offline verifier does not permit HTML string rendering'); }
  get firstElementChild() { return this.children[0] || null; }
  get lastElementChild() { return this.children[this.children.length - 1] || null; }
  get childElementCount() { return this.children.length; }
  append(...items) {
    for (let item of items) {
      if (typeof item === 'string') item = this.ownerDocument.createTextNode(item);
      if (item.tagName === '#FRAGMENT') { this.append(...item.children.slice()); continue; }
      if (item.parentElement) item.remove();
      item.parentElement = this; this.children.push(item);
    }
  }
  appendChild(item) { this.append(item); return item; }
  replaceChildren(...items) { for (const child of this.children) child.parentElement = null; this.children = []; this.append(...items); }
  remove() { if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(child => child !== this); this.parentElement = null; }
  setAttribute(name, value) {
    this.attributes[name] = String(value);
    if (name === 'id') this.id = value;
    if (name === 'class') this.className = String(value);
    if (name === 'value') this.value = String(value);
    if (name === 'hidden') this.hidden = true;
    if (name === 'disabled') this.disabled = true;
    if (name.startsWith('data-')) this.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] = String(value);
  }
  getAttribute(name) {
    if (name === 'id') return this.id || null;
    if (name === 'class') return this.className || null;
    if (name.startsWith('data-')) return this.dataset[name.slice(5).replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())] ?? null;
    return this.attributes[name] ?? null;
  }
  removeAttribute(name) { delete this.attributes[name]; if (name === 'hidden') this.hidden = false; }
  hasAttribute(name) { return this.getAttribute(name) !== null; }
  addEventListener(type, listener) { if (!this.listeners.has(type)) this.listeners.set(type, []); this.listeners.get(type).push(listener); }
  dispatchEvent(event) {
    if (!event.target) event.target = this;
    event.currentTarget = this;
    event.preventDefault ||= () => { event.defaultPrevented = true; };
    event.stopPropagation ||= () => { event.stopped = true; };
    for (const listener of this.listeners.get(event.type) || []) listener(event);
    if (event.bubbles !== false && !event.stopped && this.parentElement) this.parentElement.dispatchEvent(event);
    return !event.defaultPrevented;
  }
  click() { if (!this.disabled) this.dispatchEvent({type: 'click', bubbles: true}); }
  focus() { this.ownerDocument.activeElement = this; }
  scrollIntoView() { this.scrolledIntoView = true; }
  matches(selector) {
    return selector.split(',').some(part => {
      part = part.trim();
      if (/:(?:not)\(\[disabled\]\)/.test(part)) {
        if (this.disabled) return false;
        part = part.replace(/:not\(\[disabled\]\)/g, '');
      }
      const attrs = [...part.matchAll(/\[([^=\]]+)(?:=["']?([^\]"']+)["']?)?\]/g)];
      for (const match of attrs) if (!this.hasAttribute(match[1]) || (match[2] !== undefined && this.getAttribute(match[1]) !== match[2])) return false;
      const base = part.replace(/\[[^\]]+\]/g, '');
      const tag = base.match(/^[A-Za-z][\w-]*/)?.[0];
      if (tag && this.tagName !== tag.toUpperCase()) return false;
      const id = base.match(/#([\w-]+)/)?.[1];
      if (id && this.id !== id) return false;
      return [...base.matchAll(/\.([\w-]+)/g)].every(match => this.classList.contains(match[1]));
    });
  }
  closest(selector) { for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node; return null; }
  querySelectorAll(selector) {
    const found = [];
    const descend = node => { for (const child of node.children) { if (child.matches(selector)) found.push(child); descend(child); } };
    descend(this); return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  contains(node) { return node === this || this.children.some(child => child.contains(node)); }
}

class Document extends Element {
  constructor() { super('#document', null); this.ownerDocument = this; this.activeElement = null; }
  createElement(tag) { return new Element(tag, this); }
  createDocumentFragment() { return this.createElement('#fragment'); }
  createTextNode(text) { const node = this.createElement('#text'); node._text = String(text); return node; }
  getElementById(id) { return this.querySelector('#' + id); }
}

function loadReport(html, replacementPayload) {
  const jsonMatch = html.match(/<script type="application\/json" id="tree-data">([\s\S]*?)<\/script>/);
  assert(jsonMatch, 'Saved HTML lacks tree-data payload');
  const data = replacementPayload ? JSON.stringify(replacementPayload) : jsonMatch[1];
  const code = html.slice(jsonMatch.index + jsonMatch[0].length).match(/<script>([\s\S]*?)<\/script>/)?.[1];
  assert(code, 'Saved HTML lacks actual viewer JavaScript');
  const document = new Document();
  const stack = [document];
  const prefix = html.slice(0, jsonMatch.index).replace(/<style>[\s\S]*?<\/style>/, '');
  for (const token of prefix.match(/<[^>]+>/g) || []) {
    if (token.startsWith('</')) { if (stack.length > 1) stack.pop(); continue; }
    const tag = token.match(/^<([\w-]+)/)?.[1]; if (!tag) continue;
    const element = document.createElement(tag);
    for (const attribute of token.matchAll(/([\w-]+)="([^"]*)"/g)) element.setAttribute(attribute[1], attribute[2]);
    if (/\bhidden\b/.test(token)) element.hidden = true;
    stack[stack.length - 1].append(element);
    if (!['meta', 'input', 'link', 'br', 'hr'].includes(tag)) stack.push(element);
  }
  document.body = document.querySelector('body');
  const scriptData = document.createElement('script'); scriptData.id = 'tree-data'; scriptData.textContent = data; document.body.append(scriptData);
  document.getElementById('filter').value = 'all';
  const window = document.createElement('#window');
  const queued = new Map(); let nextTimer = 0;
  const context = vm.createContext({document, window, console, requestAnimationFrame: callback => { const id = ++nextTimer; queued.set(id, callback); return id; },
    setTimeout: callback => { const id = ++nextTimer; queued.set(id, callback); return id; }, clearTimeout: id => queued.delete(id),
    KeyboardEvent: function(type, options) { Object.assign(this, options, {type}); }});
  vm.runInContext(code, context, {timeout: 30000, filename: 'actual-saved-viewer.js'});
  const flush = () => { while (queued.size) { const entries = [...queued.values()]; queued.clear(); for (const callback of entries) callback(); } };
  flush();
  assert.equal(document.getElementById('fatal').textContent, '', 'Actual viewer failed to initialize');
  return {document, window, flush, payload: JSON.parse(data)};
}

function run() {
  const reportPath = process.argv[2];
  assert(reportPath, 'Usage: node verify_tree_groups.js report.html [template.html]');
  let html = fs.readFileSync(reportPath, 'utf8');
  if (process.argv[3]) {
    const payload = html.match(/<script type="application\/json" id="tree-data">([\s\S]*?)<\/script>/)[1];
    html = fs.readFileSync(process.argv[3], 'utf8').replace('__TREE_PAYLOAD__', payload);
  }
  const result = loadReport(html);
  const {document: doc, flush, payload} = result;
  const metric = category => doc.querySelector(`[data-category="${category}"]`);
  const get = id => { const element = doc.getElementById(id); assert(element, 'Missing #' + id); return element; };
  assert(metric('nodes'), 'Clickable metric handlers are not present yet');
  const expandedNodes = payload.nodes.map(node => ({...node,
    issues: node.issues || node.issue_pattern_indexes.map(index => ({...payload.tables.issue_patterns[index], node: node.id}))}));
  const expectedCounts = {nodes: 16405, leaves: 12299, unresolved: 16, hierarchy: 32, native_read: 16183, serialization: 46423};
  const groupExpected = category => expandedNodes.flatMap(node => {
    if (['nodes', 'leaves', 'unresolved'].includes(category)) {
      return (category === 'nodes' || (category === 'leaves' && node.leaf === 'leaf') ||
        (category === 'unresolved' && node.leaf === 'unknown')) ? [{id: node.id, index: null}] : [];
    }
    return node.issues.flatMap((issue, index) => issue.kind === category ? [{id: node.id, index, issue}] : []);
  });
  const rowKeys = () => get('category-list').querySelectorAll('.category-row').map(row =>
    `${row.dataset.node}:${row.dataset.issueIndex ?? 'node'}`);
  const key = item => `${item.id}:${item.index ?? 'node'}`;
  const input = (id, value, event = 'input') => { get(id).value = value; get(id).dispatchEvent({type: event}); flush(); };
  const findings = [];
  for (const category of Object.keys(expectedCounts)) {
    const expected = groupExpected(category);
    assert.equal(expected.length, expectedCounts[category], `${category} count differs from the independent saved-export totals`);
    const card = metric(category); card.click(); flush();
    assert.equal(get('category-overlay').hidden, false);
    assert.equal(doc.activeElement, get('category-search'));
    assert.equal(get('workbench').inert, true);
    assert(get('category-description').textContent.startsWith(expected.length.toLocaleString() + ' '));
    const observed = []; let page = 0;
    do {
      const rows = rowKeys(), expectedPage = expected.slice(page * 50, (page + 1) * 50).map(key);
      assert.deepEqual(rows, expectedPage, `${category} page ${page + 1} omitted/duplicated/reordered records`);
      assert(rows.length <= 50, 'Category pagination rendered more than 50 records');
      assert.equal(Number(get('category-page-number').value), page + 1);
      observed.push(...rows); page++;
      if (!get('category-next').disabled) get('category-next').click(); else break;
    } while (page <= Math.ceil(expected.length / 50));
    assert.equal(page, Math.ceil(expected.length / 50));
    assert.deepEqual(observed, expected.map(key));
    assert.equal(new Set(observed).size, expected.length, `${category} has duplicate records across pages`);
    assert.equal(get('category-last').disabled, true);
    get('category-first').click();
    assert.deepEqual(rowKeys(), expected.slice(0, 50).map(key));
    get('category-last').click();
    assert.deepEqual(rowKeys(), expected.slice((page - 1) * 50).map(key), `${category} last page is incomplete`);
    input('category-page-number', '1', 'change');
    assert.deepEqual(rowKeys(), expected.slice(0, 50).map(key));
    input('category-page-number', '999999', 'change');
    assert.deepEqual(rowKeys(), expected.slice((page - 1) * 50).map(key));
    input('category-page-number', '-20', 'change');
    assert.deepEqual(rowKeys(), expected.slice(0, 50).map(key));
    input('category-search', '__no_native_record_matches_this_1bb752__');
    assert.deepEqual(rowKeys(), []);
    assert.equal(get('category-list').querySelector('.category-empty').textContent, 'No records match this search.');
    assert.equal(get('category-next').disabled, true);
    assert.equal(get('category-count').textContent, `0 of 0 matching / ${expected.length.toLocaleString()} total`);
    input('category-search', '');
    assert.deepEqual(rowKeys(), expected.slice(0, 50).map(key));
    if (expected[0].issue) {
      const term = expected[0].issue.attribute;
      input('category-search', term);
      assert(rowKeys().length > 0);
      for (const row of get('category-list').querySelectorAll('.category-row')) {
        const node = expandedNodes.find(node => node.id === Number(row.dataset.node));
        assert(JSON.stringify(node.issues[Number(row.dataset.issueIndex)]).toLowerCase().includes(term.toLowerCase()) ||
          JSON.stringify(node).toLowerCase().includes(term.toLowerCase()), `${category} search returned unrelated evidence`);
      }
      input('category-search', '');
    }
    get('category-dialog').dispatchEvent({type: 'keydown', key: 'Escape'});
    assert.equal(get('category-overlay').hidden, true);
    assert.equal(get('workbench').inert, false);
    assert.equal(doc.activeElement, card);
    // A category click must reveal a target even while the main tree excludes it.
    input('search', '__no_node_matches_this_6dcc5__');
    card.click(); flush(); get('category-last').click();
    const chosen = expected[(page - 1) * 50], chosenRow = get('category-list').querySelector('.category-row');
    chosenRow.click(); flush();
    assert.equal(get('category-overlay').hidden, true);
    assert.equal(get('workbench').inert, false);
    assert.equal(get('search').value, '', 'Choosing a record did not reveal a node excluded by the tree filter');
    assert(get('detail-tags').textContent.includes('#' + chosen.id));
    if (chosen.issue) {
      const evidence = get(`issue-${chosen.id}-${chosen.index}`);
      assert(evidence.classList.contains('selected-evidence'));
      assert.equal(doc.activeElement, evidence);
      assert(evidence.scrolledIntoView);
      assert.deepEqual(JSON.parse(evidence.querySelector('pre').textContent), chosen.issue,
        `${category} clicked record did not reveal its exact native evidence`);
    } else assert.equal(doc.activeElement, get('tree-scroll'));
    card.click(); get('category-close').click();
    assert.equal(get('category-overlay').hidden, true);
    assert.equal(doc.activeElement, card);
    findings.push({category, records: expected.length, pages: page, final_page_records: expected.length - (page - 1) * 50,
      all_records_unique_and_reachable: true, search_and_exact_reveal: true});
  }
  // Exercise Escape, backdrop, and actual keyboard focus-trap handlers on the 46k-record group.
  metric('serialization').click();
  const focusable = get('category-dialog').querySelectorAll('button:not([disabled]),input:not([disabled])');
  const first = focusable[0], last = focusable[focusable.length - 1];
  last.focus(); get('category-dialog').dispatchEvent({type: 'keydown', key: 'Tab'});
  assert.equal(doc.activeElement, first);
  first.focus(); get('category-dialog').dispatchEvent({type: 'keydown', key: 'Tab', shiftKey: true});
  assert.equal(doc.activeElement, last);
  get('category-overlay').click(); assert.equal(get('category-overlay').hidden, true);

  const emptyPayload = {schema: payload.schema, source: {}, nodes: [], meta: {...payload.meta, app: {name: 'Empty fixture', pid: 0},
    canonical_roots: [], node_count: 0, leaf_count: 0, unknown_leaf_count: 0, hierarchy_failure_count: 0,
    metadata_read_failure_count: 0, serialization_warning_count: 0}};
  const empty = loadReport(html, emptyPayload);
  for (const category of Object.keys(expectedCounts)) {
    empty.document.querySelector(`[data-category="${category}"]`).click();
    const list = empty.document.getElementById('category-list');
    assert.equal(list.querySelectorAll('.category-row').length, 0);
    assert.equal(list.querySelector('.category-empty').textContent, 'No recorded items in this category.');
    assert.equal(empty.document.getElementById('category-next').disabled, true);
    empty.document.getElementById('category-dialog').dispatchEvent({type: 'keydown', key: 'Escape'});
    assert.equal(empty.document.getElementById('category-overlay').hidden, true);
  }
  console.log(JSON.stringify({passed: true, initialized: true, categories: findings,
    exact_issue_evidence: true, keyboard_focus_and_close: true, six_empty_groups: true,
    verification: 'Actual generated HTML JavaScript executed offline through DOM/event stubs; no live browser or native app access'}));
}

if (require.main === module) run();
module.exports = {Element, Document, loadReport};
