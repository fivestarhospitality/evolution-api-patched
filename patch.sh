#!/bin/sh
# Neuters BaileysStartupService.generateLinkPreview in Evolution API's bundle so
# it returns undefined immediately. Evolution then never builds its own
# externalAdReply card and the linkPreview flag falls through to Baileys'
# native preview generator.
#
# Built against evoapicloud/evolution-api:2.4.0-rc2. The edit is anchored on
# exact literals from that bundle; if anything does not match, this script
# exits non-zero and the image build fails.

set -eu

MAIN_JS="${MAIN_JS:-/evolution/dist/main.js}"
TMP_JS="$(dirname "$MAIN_JS")/.main.lp-patch.tmp.js"

fail() {
  echo "PATCH FAILED: $*" >&2
  rm -f "$TMP_JS"
  exit 1
}

command -v node >/dev/null 2>&1 || fail "node not found in PATH"
[ -f "$MAIN_JS" ] || fail "$MAIN_JS does not exist"

echo "==> Target: $MAIN_JS"
echo "==> sha256 before: $(sha256sum "$MAIN_JS" | cut -d' ' -f1)"

echo "==> node --check on original bundle"
node --check "$MAIN_JS" || fail "original $MAIN_JS is not valid JavaScript (before patching)"

# The string surgery runs in node so no shell quoting touches the bundle.
MAIN_JS="$MAIN_JS" TMP_JS="$TMP_JS" node <<'EOF' || fail "could not apply edit (see message above)"
const fs = require('fs');

const src = fs.readFileSync(process.env.MAIN_JS, 'utf8');

const HEAD = 'async generateLinkPreview(e){';
const TAIL = '}async sendMessage(';
const NEW_BODY = 'return void 0';

function die(msg) {
  console.error('PATCH FAILED: ' + msg);
  process.exit(1);
}

function count(haystack, needle) {
  let n = 0;
  for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + 1)) n++;
  return n;
}

const headCount = count(src, 'async generateLinkPreview(');
if (headCount !== 1) {
  die(`expected exactly 1 occurrence of "async generateLinkPreview(", found ${headCount}`);
}

const start = src.indexOf(HEAD);
if (start === -1) {
  die(`method found but signature is not exactly "${HEAD}" - bundle differs from 2.4.0-rc2`);
}
const bodyStart = start + HEAD.length;

const end = src.indexOf(TAIL, bodyStart);
if (end === -1) {
  die(`could not find end of method (expected "${TAIL}" after it)`);
}

const oldMethod = src.slice(start, end + 1);
const body = src.slice(bodyStart, end);

// Sanity checks that we cut exactly the method we think we cut.
if (body === NEW_BODY) die('bundle is already patched');
if (!body.startsWith('try{')) die('method body does not start with "try{"');
if (!body.includes('getLinkPreview)(')) die('method body does not call getLinkPreview');
if (!body.includes('externalAdReply:')) die('method body does not build externalAdReply');
if (!body.endsWith('return}')) die('method body does not end with the expected catch block');
if (/\}async [A-Za-z_$]/.test(body)) die('cut region spans more than one method');
if (body.length > 2000) die(`cut region is suspiciously large (${body.length} chars)`);

let depth = 0;
for (const ch of body) {
  if (ch === '{') depth++;
  else if (ch === '}') depth--;
  if (depth < 0) die('cut region has unbalanced braces');
}
if (depth !== 0) die('cut region has unbalanced braces');

const newMethod = HEAD + NEW_BODY + '}';
const out = src.slice(0, start) + newMethod + src.slice(end + 1);

// Verify the result is exactly the original with one region swapped.
if (out.length !== src.length - oldMethod.length + newMethod.length) die('unexpected output length');
if (count(out, newMethod) !== 1) die('patched method not present exactly once in output');
if (count(out, 'async generateLinkPreview(') !== 1) die('method count changed');
if (!out.includes(newMethod + 'async sendMessage(')) die('patched method not followed by sendMessage');
if (!out.includes('this.generateLinkPreview(')) die('call site of generateLinkPreview is missing');

fs.writeFileSync(process.env.TMP_JS, out);

console.log('==> Offset: ' + start);
console.log('==> REMOVED (' + oldMethod.length + ' chars):');
console.log('    ' + oldMethod);
console.log('==> INSERTED (' + newMethod.length + ' chars):');
console.log('    ' + newMethod);
EOF

[ -s "$TMP_JS" ] || fail "patched output was not written"

echo "==> node --check on patched bundle"
node --check "$TMP_JS" || fail "patched bundle is not valid JavaScript"

mv -f "$TMP_JS" "$MAIN_JS"

grep -qF 'async generateLinkPreview(e){return void 0}async sendMessage(' "$MAIN_JS" \
  || fail "patched method not found in $MAIN_JS after replacing it"
grep -qF 'externalAdReply:{title:n.title' "$MAIN_JS" \
  && fail "original preview-card code still present in $MAIN_JS"
node --check "$MAIN_JS" || fail "final $MAIN_JS is not valid JavaScript"

echo "==> sha256 after:  $(sha256sum "$MAIN_JS" | cut -d' ' -f1)"
echo "==> OK: generateLinkPreview now returns undefined immediately"

# ---------------------------------------------------------------------------
# Patch 2: raise Baileys' inline link-preview thumbnail width.
#
# Evolution creates the socket with generateHighQualityLinkPreview:!0 but never
# sets linkPreviewImageThumbnailWidth, so Baileys embeds a 192 px JPEG. Channels
# cannot fetch the high-res CDN copy and stretch that thumbnail full width.
# Insert linkPreviewImageThumbnailWidth:640 into the same makeWASocket config.
# ---------------------------------------------------------------------------

echo
echo "==> [patch 2] sha256 before: $(sha256sum "$MAIN_JS" | cut -d' ' -f1)"

echo "==> [patch 2] node --check before"
node --check "$MAIN_JS" || fail "patch 2: $MAIN_JS is not valid JavaScript before patching"

MAIN_JS="$MAIN_JS" TMP_JS="$TMP_JS" node <<'EOF' || fail "patch 2: could not apply edit (see message above)"
const fs = require('fs');

const src = fs.readFileSync(process.env.MAIN_JS, 'utf8');

const KEY = 'generateHighQualityLinkPreview:!0';
const INSERT = 'linkPreviewImageThumbnailWidth:640,';
// The socket config is a local object literal handed straight to Baileys'
// default export (makeWASocket), with `_` bound to require("baileys").
const BAILEYS_IMPORT = '_=R(require("baileys"))';
const OBJ_HEAD = 'let a={...r,version:o,';
const OBJ_TAIL = '};return this.endSession=!1,this.client=(0,_.default)(a),';

function die(msg) {
  console.error('PATCH FAILED: patch 2: ' + msg);
  process.exit(1);
}

function count(haystack, needle) {
  let n = 0;
  for (let i = haystack.indexOf(needle); i !== -1; i = haystack.indexOf(needle, i + 1)) n++;
  return n;
}

const keyCount = count(src, KEY);
if (keyCount !== 1) die(`expected exactly 1 occurrence of "${KEY}", found ${keyCount}`);
if (count(src, 'generateHighQualityLinkPreview') !== 1) die('generateHighQualityLinkPreview appears in more than one form');
const existing = count(src, 'linkPreviewImageThumbnailWidth');
if (existing !== 0) die(`linkPreviewImageThumbnailWidth is already present (${existing} occurrence(s))`);

// Confirm the enclosing object literal is the makeWASocket config.
if (count(src, BAILEYS_IMPORT) !== 1) die(`expected exactly 1 "${BAILEYS_IMPORT}"`);
if (count(src, OBJ_HEAD) !== 1) die(`expected exactly 1 "${OBJ_HEAD}"`);
if (count(src, OBJ_TAIL) !== 1) die(`expected exactly 1 "${OBJ_TAIL}"`);

const keyIdx = src.indexOf(KEY);
const objStart = src.indexOf(OBJ_HEAD) + OBJ_HEAD.indexOf('{');
if (objStart > keyIdx || keyIdx - objStart > 5000) die('key is not inside the socket config object');

let depth = 0;
let keyDepth = -1;
let objEnd = -1;
for (let i = objStart; i < src.length && i - objStart < 10000; i++) {
  if (i === keyIdx) keyDepth = depth;
  const ch = src[i];
  if (ch === '{') depth++;
  else if (ch === '}' && --depth === 0) { objEnd = i; break; }
}
if (objEnd === -1) die('could not find end of socket config object');
if (!src.startsWith(OBJ_TAIL, objEnd)) die('object containing the key is not the one passed to makeWASocket');
if (keyIdx > objEnd) die('key lies outside the socket config object');
if (keyDepth !== 1) die(`key is nested (depth ${keyDepth}), not a direct property of the socket config`);

const obj = src.slice(objStart, objEnd + 1);
for (const marker of ['auth:{creds:', 'printQRInTerminal:', 'getMessage:', 'patchMessageBeforeSending(']) {
  if (!obj.includes(marker)) die(`socket config object lacks "${marker}"`);
}

const insertAt = keyIdx + KEY.length;
if (src[insertAt] !== ',') die(`expected "," after "${KEY}", found "${src[insertAt]}"`);
const pos = insertAt + 1;
const out = src.slice(0, pos) + INSERT + src.slice(pos);

// Verify the result is exactly the original plus the inserted text.
if (out.slice(0, pos) + out.slice(pos + INSERT.length) !== src) die('output is not original + insertion');
if (count(out, KEY + ',' + INSERT) !== 1) die('inserted property not found exactly once in output');
if (count(out, 'linkPreviewImageThumbnailWidth') !== 1) die('linkPreviewImageThumbnailWidth count is not 1 in output');

fs.writeFileSync(process.env.TMP_JS, out);

const ctxFrom = src.lastIndexOf(',', keyIdx - 1) + 1;
const ctxTo = src.indexOf(',', pos) + 1;
console.log('==> [patch 2] Offset: ' + pos + ' (inside makeWASocket config, ' + obj.length + ' chars)');
console.log('==> [patch 2] REMOVED: nothing');
console.log('==> [patch 2] INSERTED (' + INSERT.length + ' chars): ' + INSERT);
console.log('==> [patch 2] before: ' + src.slice(ctxFrom, ctxTo));
console.log('==> [patch 2] after:  ' + out.slice(ctxFrom, ctxTo + INSERT.length));
EOF

[ -s "$TMP_JS" ] || fail "patch 2: patched output was not written"

echo "==> [patch 2] node --check on patched bundle"
node --check "$TMP_JS" || fail "patch 2: patched bundle is not valid JavaScript"

mv -f "$TMP_JS" "$MAIN_JS"

grep -qF 'generateHighQualityLinkPreview:!0,linkPreviewImageThumbnailWidth:640,getMessage:' "$MAIN_JS" \
  || fail "patch 2: inserted property not found in $MAIN_JS after replacing it"
grep -qF 'async generateLinkPreview(e){return void 0}async sendMessage(' "$MAIN_JS" \
  || fail "patch 2: patch 1 no longer present in $MAIN_JS"
node --check "$MAIN_JS" || fail "patch 2: final $MAIN_JS is not valid JavaScript"

echo "==> [patch 2] sha256 after:  $(sha256sum "$MAIN_JS" | cut -d' ' -f1)"
echo "==> OK: makeWASocket config now sets linkPreviewImageThumbnailWidth:640"
