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
