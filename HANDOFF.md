# HANDOFF — evolution-api-patched

Last updated: 15 Sep 2026 (work done 14 Sep 2026). Current production image: `ghcr.io/fivestarhospitality/evolution-api-patched:2.4.0-rc2-lp3`.

This document is for someone (human or Claude Code) who has to rebuild this image against a newer Evolution API
release and remembers nothing. Read sections 1–3 for context, then go straight to **section 7 (check first)** and
**section 6 (upgrade checklist)**.

How claims are labelled:

- **[verified in repo]**: checked directly while this repo was built (bundle bytes, Baileys source, registry
  contents, CI results). How it was checked is stated next to the claim.
- **[operator-verified]**: checked by the operator on the live system and reported to the repo sessions. The exact
  method was not recorded here.
- **[assumption]**: believed true, not verified.

---

## 0. Repo at a glance

| File | Purpose |
|---|---|
| `Dockerfile` | `FROM evoapicloud/evolution-api:2.4.0-rc2`, copies `patch.sh` to `/tmp`, runs it, deletes it. No ENTRYPOINT/CMD/ENV/USER of its own; everything is inherited. |
| `patch.sh` | POSIX sh. Applies 3 edits to `/evolution/dist/main.js` in order. Every edit is anchored on exact literals from the 2.4.0-rc2 bundle and exits 1 with `PATCH FAILED: …` on any deviation. |
| `.github/workflows/build.yml` | On push to `main` and `workflow_dispatch`: logs in to ghcr.io with `GITHUB_TOKEN`, builds, pushes **one** tag (currently `2.4.0-rc2-lp3`). |
| `HANDOFF.md` | This file. |

Nothing is built locally; GitHub Actions builds the image. The workstation used to create the repo (Windows) has no Docker.

**Gotcha: every push to `main` rebuilds and re-pushes whatever tag is in `build.yml`**, including documentation-only
pushes. That overwrites the production tag with a fresh build, which gets a new digest even if the content is
identical. For doc-only commits put `[skip ci]` in the commit message (this file was committed that way), or add a
`paths:` filter to the workflow.

---

## 1. Why this repo exists

### Symptom
Evolution API 2.4.0-rc2 sends links to WhatsApp Channels (`…@newsletter` JIDs). On Channels the link preview
rendered as a **play-button card with no image** [operator-verified].

### Root cause (Evolution side) [verified in repo]
`BaileysStartupService` (bundled into `/evolution/dist/main.js`) has its own preview routine. The original minified
source in 2.4.0-rc2 is:

```js
async generateLinkPreview(e){try{let t=/https?:\/\/[^\s]+/,o=e.match(t);if(!o)return;let i=o[0].replace(/[.,);\]]+$/u,"");if(!i)return;let n=await(0,dc.getLinkPreview)(i,{imagesPropertyType:"og",headers:{"user-agent":"googlebot"}});if(!n||!n.title)return;let r=n.images&&n.images.length>0?n.images[0]:void 0;return{externalAdReply:{title:n.title,body:n.description,mediaType:2,thumbnailUrl:r,sourceUrl:i,mediaUrl:i,renderLargerThumbnail:!0}}}catch(t){this.logger.error(`Error generating link preview: ${t}`);return}}
```

It scrapes the URL with `link-preview-js` and returns a `contextInfo.externalAdReply` with `mediaType:2` and a
`thumbnailUrl` **string**, meaning no embedded image bytes. Its only caller, in the send-text path, is:

```js
let p=o?.linkPreview===!1?!1:void 0,l;p!==!1&&t?.conversation&&(l=await this.generateLinkPreview(t.conversation));
```

`l` is then spread into the message's `contextInfo` (`...l`) and also passed to `sendMessage`. So whenever
`linkPreview` is not explicitly `false`, Evolution's ad-reply card is attached. That card pre-empts Baileys' own
link-preview generator, which does work.

[assumption] `mediaType:2` is `VIDEO` in WAProto's `ExternalAdReplyInfo.MediaType` enum (`NONE=0, IMAGE=1, VIDEO=2`),
which would explain the play button. This was not checked against the proto files in the image.

### Diagnosis chain: already done, do not repeat
Each of these was ruled out as the cause before any patching:

| # | Check | Result | Status |
|---|---|---|---|
| 1 | Target page's Open Graph tags (`og:title`, `og:description`, `og:image`) | Correct | [operator-verified] |
| 2 | Target server reachable from the Evolution host (not blocked or geo-filtered) | Reachable | [operator-verified] |
| 3 | `link-preview-js` run **inside the Evolution container** against the URL | Returned correct title/description/image | [operator-verified] |
| 4 | Baileys' `getUrlInfo()` run against the URL | Produced a correct preview **with a correct thumbnail** | [operator-verified] |
| 5 | The broken card is built by Evolution's `generateLinkPreview`, not by Baileys | Confirmed by reading the 2.4.0-rc2 bundle (above) | [verified in repo] |

Conclusion: the page, the network and the scraping library were fine. The broken output came from Evolution's
routine, and Baileys' own generator was being bypassed.

### Where the code actually lives [verified in repo]
- `package.json`: `"main": "./dist/main.js"`, `"type": "commonjs"`, `"start:prod": "node --network-family-autoselection-attempt-timeout=1000 dist/main"`, `"version": "2.4.0"` (the upstream image tag is `2.4.0-rc2`, but the package version says `2.4.0`).
- Image ENTRYPOINT: `["/bin/bash","-c",". ./Docker/scripts/deploy_database.sh && npm run start:prod"]`, WORKDIR `/evolution`, no `USER` (runs as root), Node 24.15.0, Alpine.
- tsup emits a separate self-contained bundle per entry, so **unpatched copies of the same code exist in ~75 other
  files** under `/evolution/dist/**` (`*.js` and `*.mjs`, e.g. `dist/api/integrations/channel/whatsapp/whatsapp.baileys.service.js`).
  They are never loaded: `main.js` has 61 distinct `require()`s, all package names, with zero relative requires and
  zero dynamic `import()` of relative paths (checked by regex over the bundle). **Only `/evolution/dist/main.js` needs
  patching.** Re-check this on every new version (section 6, step 5).

---

## 2. The three patches

All three edit `/evolution/dist/main.js` and run in order in `patch.sh`. Each one:
- runs `node --check` on the file before editing,
- does the string edit in Node (a quoted heredoc, so the shell never touches bundle text),
- requires every anchor to match **exactly once** and verifies the result byte-for-byte,
- writes to a temp file (`/evolution/dist/.main.lp-patch.tmp.js`), runs `node --check` on it, `mv`s it over `main.js`,
  then re-greps and runs `node --check` again,
- prints sha256 before/after and the exact text removed/inserted,
- on any deviation prints `PATCH FAILED: …` (patches 2 and 3 prefix `patch 2:` / `patch 3:`) and exits 1, failing
  the Docker build.

sha256 of `main.js` through the chain (2.4.0-rc2, amd64) [verified in repo]:

| Stage | sha256 |
|---|---|
| upstream original | `fe6170f88c64cff705ce18808dd3473fae929a9af3c5fc08a1b3d12edbd14c02` |
| after patch 1 | `1fbce9f9bbc246c855084f5ec89805c91310c8bbbb624f3a9c66dbfdd66d5a0c` |
| after patch 2 | `44434c839fad72a743c76bceab5e9cf8ea0deb104d5fef5adec61a87c029a68d` |
| after patch 3 (= `main.js` in published `-lp3`) | `14fc64ff9fcd0ba055c54b6d3847cec4fc8936c1e9a98bb3ac5fc1c385c6e000` |

The last row was checked by downloading the top layer of the published `-lp3` image from ghcr.io and hashing its `main.js`.

### Patch 1: neuter `generateLinkPreview` so Baileys handles previews

- **Before** (516 chars): the full method quoted in section 1.
- **After** (43 chars): `async generateLinkPreview(e){return void 0}`
- Anchors: `async generateLinkPreview(` exactly once; signature exactly `async generateLinkPreview(e){`; end of method
  = the next `}async sendMessage(`. Sanity checks on the cut body: starts with `try{`, contains `getLinkPreview)(` and
  `externalAdReply:`, ends with `return}`, braces balance, no `}async <name>` inside, under 2000 chars.
- Why: with `l` undefined, no `externalAdReply` is attached. The `linkPreview` flag falls through to Baileys'
  `sendMessage`, whose `generateWAMessage` calls `getUrlInfo()` (Baileys' own generator). The signature stays the
  same, so the caller still works (`await` of `undefined`, `...undefined` is a no-op).
- Result on Channels: the preview became a real card with an image, but the image was **blurred** [operator-verified].

### Patch 2: add `linkPreviewImageThumbnailWidth:640` to the socket config

- **Before:** `generateHighQualityLinkPreview:!0,getMessage:async p=>await this.getMessage(p),`
- **After:**  `generateHighQualityLinkPreview:!0,linkPreviewImageThumbnailWidth:640,getMessage:async p=>await this.getMessage(p),`
- Inserted text (35 chars, nothing removed): `linkPreviewImageThumbnailWidth:640,`
- How the object was confirmed to be the `makeWASocket` config [verified in repo]:
  - `generateHighQualityLinkPreview` occurs once in the bundle; `linkPreviewImageThumbnailWidth` occurred zero times.
  - `_=R(require("baileys"))` occurs once, so `_.default` is Baileys' default export, `makeWASocket`.
  - The key is a depth-1 property of the object literal starting `let a={...r,version:o,`, which also contains
    `auth:{creds:`, `printQRInTerminal:`, `getMessage:`, `patchMessageBeforeSending(`.
  - That object literal is immediately followed by `};return this.endSession=!1,this.client=(0,_.default)(a),`.
  - `patch.sh` re-checks all of this at build time.
- Why: Baileys' default is `linkPreviewImageThumbnailWidth: 192` (`node_modules/baileys/lib/Defaults/index.js:56`).
  The idea was to make the inline thumbnail sharper.
- **Result: no visible change.** `-lp2` looked identical to `-lp` [operator-verified]. The reason is patch 3's finding:
  with `generateHighQualityLinkPreview` true, Baileys never reads this width.

### Patch 3: set `generateHighQualityLinkPreview` to false

- **Before:** `generateHighQualityLinkPreview:!0,linkPreviewImageThumbnailWidth:640,getMessage:async p=>await this.getMessage(p),`
- **After:**  `generateHighQualityLinkPreview:!1,linkPreviewImageThumbnailWidth:640,getMessage:async p=>await this.getMessage(p),`
- Exact change: one character, `generateHighQualityLinkPreview:!0` → `generateHighQualityLinkPreview:!1`.
- Anchors: same socket-config checks as patch 2, plus `generateHighQualityLinkPreview:!0,linkPreviewImageThumbnailWidth:640,getMessage:`
  must exist, so patch 2 must be in place. `…:!1` must not already exist, and the output may differ from the input in that one byte only.
- Why [verified in repo, by reading Baileys 7.0.0-rc.9 from the image's `node_modules` layer]:
  - `lib/Socket/messages-send.js:~898–907` passes `getUrlInfo(text, { thumbnailWidth: linkPreviewImageThumbnailWidth, fetchOpts, logger, uploadImage: generateHighQualityLinkPreview ? waUploadToServer : undefined })`.
  - `lib/Utils/link-preview.js:59–66`, **high-quality path** (`opts.uploadImage` set): calls
    `prepareWAMessageMedia({ image: { url: image } }, { upload: opts.uploadImage, mediaTypeOverride: 'thumbnail-link', options: opts.fetchOpts })`
    and takes `jpegThumbnail` from the result. **`thumbnailWidth` is not passed.**
  - `lib/Utils/messages.js:156–158`: `prepareWAMessageMedia` builds the thumbnail with `generateThumbnail(originalFilePath, mediaType, options)`.
  - `lib/Utils/messages-media.js:271`: `generateThumbnail` calls `extractImageThumb(file)` with no width, and
    `messages-media.js:97` has `extractImageThumb = async (bufferOrFilePath, width = 32)`.
    **So the embedded JPEG is 32 px wide** (quality 50). It is not 192 px, and it ignores `linkPreviewImageThumbnailWidth`.
  - The high-res copy is uploaded and referenced via `thumbnailDirectPath`/`thumbnailSha256`/… (`messages.js:277–285`).
    Channels cannot fetch that copy, so they stretch the 32 px inline JPEG, which is the blur.
  - `lib/Utils/link-preview.js:68–70`, **normal path** (flag false):
    `jpegThumbnail = (await getCompressedJpegThumbnail(image, opts)).buffer`, i.e. `extractImageThumb(stream, thumbnailWidth)`,
    which uses the 640 set by patch 2.
  - Both paths need `sharp` or `jimp`. The image ships `sharp` 0.34.5 and `jimp` 1.6.0 (from `package-lock.json`).
- Why Channels can't fetch the high-res copy: Baileys newsletter media bug **WhiskeySockets/Baileys issue #2199**,
  "[BUG] Newsletter image upload returns wrong directPath (/o1/ instead of /m1/) - images don't appear in channel".
  It was **open** when checked via the GitHub API on 14 Sep 2026 (created 2025-12-19).
  [assumption] The link-preview upload fails for the same reason. The exact mechanism for `thumbnail-link` uploads
  was not isolated; the observed behaviour matches it.
- Result: `-lp3` fixed the Channels preview and is in production [operator-verified].

---

## 3. Accepted trade-off (decided 14 Sep 2026)

With `generateHighQualityLinkPreview` false, Baileys attaches no high-res image. Link previews render in the
**compact small-thumbnail layout instead of the large hero card**. This applies **everywhere this Evolution instance
sends links: DMs and groups as well as Channels** [operator-verified]. The flag is socket-wide; there is no
per-JID switch in this patch.

This was accepted deliberately on 14 Sep 2026 because the hero card was unusable on Channels. Do not "fix" it by
turning the flag back on unless section 7's Baileys check shows #2199 is fixed and a live Channel test confirms the
hero card renders.

Side effect [assumption, not measured]: each link message now carries a 640 px JPEG (quality 50) inline, typically
tens of KB, instead of a 32 px one.

---

## 4. Published tags (ghcr.io/fivestarhospitality/evolution-api-patched)

All built by GitHub Actions from this repo, amd64 only. Digests were read from ghcr.io anonymously on 14 Sep 2026,
which also confirms the package is public.

| Tag | Patches | Commit | Actions run | Manifest digest | Behaviour on Channels |
|---|---|---|---|---|---|
| `2.4.0-rc2-lp` | 1 | `f1d8160` | 34888698756 (success) | `sha256:4f6dcb2ce627c3badddf1de6dc5c671929455af60d3cafa386f9ac7dcb8c6997` | Large card with image, **blurred** [operator-verified] |
| `2.4.0-rc2-lp2` | 1+2 | `cfc13ee` | 34892049888 (success) | `sha256:2b98128a178e324e6d0fac521fd75af0f63bac07bf17304236fffb33f765b125` | Identical in practice to `-lp` [operator-verified] |
| `2.4.0-rc2-lp3` | 1+2+3 | `22ea885` | 34893387777 (success) | `sha256:32e277560e028ee2cba2d1190da3bd3343edd9c37432e14de10ebb08f4cd2e76` | Sharp compact preview; **current production** [operator-verified] |

Tags are mutable. The old tags only survive because `build.yml` was bumped to a new tag each time. **Never change
`build.yml` back to an existing tag.** For a rollback that cannot be affected by a later push, reference the digest:
`image: ghcr.io/fivestarhospitality/evolution-api-patched@sha256:…`.

**Rollback:** in Coolify, edit the `image:` line of the Evolution **Api** service in the Docker Compose file to the
previous tag (or digest) and redeploy. Nothing else in the compose file belongs to this repo.

---

## 5. Versions that do NOT work

| Version | Why not | Status |
|---|---|---|
| `2.3.7` | Link previews work, but there is **no `@newsletter` (Channels) support**. | [operator-verified] |
| `2.4.0-rc1` | Contains the **same broken `generateLinkPreview` routine** as rc2. | [operator-verified] by grepping the image |
| `2.4.0-rc2` unpatched | Play-button card with no image on Channels (section 1). | [operator-verified] symptom, [verified in repo] code |

---

## 6. Upgrade procedure (new upstream version)

Assume **every patch may no longer apply**. Minified identifiers (`e`, `a`, `_`, `R`, `dc`, `p`…) and code shape can
change between releases, even between rc builds. The anchors in `patch.sh` are deliberately exact, so a changed
bundle fails the build. That is intended. **Never loosen a match to get a build green; re-derive the patch from the
new bundle.**

1. **Do section 7 first** (has upstream fixed it?). If yes, stop and follow its guidance.
2. Pick the new upstream tag, e.g. `NEW=2.4.1`. Confirm it exists and has linux/amd64:
   see `fetch-upstream.sh` below, which prints the platform list.
3. Pull **only the relevant layers** of the new upstream image and read the real bundle (script below). Do not work
   from GitHub source or from memory; the minified output is what gets patched.
4. Record baseline counts in the new `main.js` (commands below) and compare with the 2.4.0-rc2 baseline in section 7.
5. Re-check that `package.json` `start:prod` still runs `dist/main` and that `main.js` still has no relative
   `require`/`import` (command below). If the entry point changed, the file to patch changed.
6. Read the new Baileys source from the image (`node_modules/baileys`) and re-check the patch 3 reasoning:
   `link-preview.js` `if (opts.uploadImage)` branch, `extractImageThumb` default width, `messages-send.js` `getUrlInfo(` options.
7. Run `patch.sh` locally against a **copy** of the new `main.js` (needs only `node`, no Docker):
   `cp main.js /tmp/test-main.js && MAIN_JS=/tmp/test-main.js sh patch.sh` (`MAIN_JS` overrides the default
   `/evolution/dist/main.js`; the Dockerfile does not set it).
   - If it passes: review the printed before/after text and confirm it is still the right code.
   - If it fails: the message says which patch and which check. Re-derive **that** patch against the new bundle,
     updating its literal anchors (`HEAD`/`TAIL`, `OBJ_HEAD`, `OBJ_TAIL`, `BAILEYS_IMPORT`, the final `grep -qF`
     strings) and keeping every check. Then test failure cases too: run it on an already-patched copy, and on
     copies with the anchor duplicated or altered, and confirm each exits 1 with `PATCH FAILED`.
8. Edit `Dockerfile`: `FROM evoapicloud/evolution-api:<NEW>`.
9. Edit `.github/workflows/build.yml`: `tags: ghcr.io/fivestarhospitality/evolution-api-patched:<NEW>-lp3` (or a new
   suffix if the patch set changed). **Never reuse an existing tag.**
10. Commit and push to `main`. The workflow builds automatically. Watch the run:
    `https://github.com/fivestarhospitality/evolution-api-patched/actions` (or
    `curl -s https://api.github.com/repos/fivestarhospitality/evolution-api-patched/actions/runs?per_page=3`).
    A failed run means a patch did not apply; open the log and read the `PATCH FAILED:` line.
11. Verify the pushed image on the host (commands below) **before** switching Coolify.
12. In Coolify change the Api service `image:` line to the new tag, redeploy, then test by sending a link to
    a Channel, a DM and a group.
13. Update this file: tags table, sha256 chain, baselines, anything re-derived.

### fetch-upstream.sh: pull only the needed layers, no Docker required
Tested on 15 Sep 2026 (Git Bash on Windows) against `2.4.0-rc2`: it reproduced `main.js` sha256 `fe6170f8…` in
about 25 s. The inspection commands and section 7 greps below were run on its output with the expected results, and
`patch.sh` applied to that copy with the sha256 chain in section 2. The Docker commands in this document were **not**
run, because the workstation has no Docker.
Needs `curl`, `node`, GNU `tar`. Save it and run `bash fetch-upstream.sh 2.4.0-rc2`.

```bash
#!/usr/bin/env bash
# Usage: bash fetch-upstream.sh <tag> [arch=amd64]
# Downloads package.json, dist/ and node_modules/baileys from evoapicloud/evolution-api:<tag> without Docker.
set -euo pipefail
REPO=evoapicloud/evolution-api
TAG=${1:?usage: fetch-upstream.sh <tag> [arch]}
ARCH=${2:-amd64}
OUT="upstream-$TAG"
mkdir -p "$OUT" && cd "$OUT"

TOKEN=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull" \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).token))')
AUTH="Authorization: Bearer $TOKEN"
REG="https://registry-1.docker.io/v2/$REPO"
ACCEPT="Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"

curl -fsS -H "$AUTH" -H "$ACCEPT" "$REG/manifests/$TAG" > index.json
DIGEST=$(node -e '
  const j=JSON.parse(require("fs").readFileSync("index.json","utf8"));
  if (j.layers) { console.log(""); process.exit(0); }
  console.error("platforms: "+j.manifests.map(m=>m.platform.os+"/"+m.platform.architecture).join(", "));
  const m=j.manifests.find(m=>m.platform.os==="linux"&&m.platform.architecture===process.argv[1]);
  if(!m){console.error("no linux/"+process.argv[1]+" manifest");process.exit(1)}
  console.log(m.digest);' "$ARCH")
if [ -n "$DIGEST" ]; then
  curl -fsS -H "$AUTH" -H "$ACCEPT" "$REG/manifests/$DIGEST" > manifest.json
else
  cp index.json manifest.json
fi
CFG=$(node -e 'console.log(JSON.parse(require("fs").readFileSync("manifest.json","utf8")).config.digest)')
curl -fsSL -H "$AUTH" "$REG/blobs/$CFG" > config.json

# Map non-empty history entries to layers, and find the layers that COPY package.json, dist and node_modules.
node -e '
  const fs=require("fs");
  const m=JSON.parse(fs.readFileSync("manifest.json","utf8")), c=JSON.parse(fs.readFileSync("config.json","utf8"));
  const steps=c.history.filter(h=>!h.empty_layer);
  if (steps.length!==m.layers.length) { console.error("history/layer count mismatch"); process.exit(1); }
  const find=re=>{const i=steps.findIndex(h=>re.test(h.created_by)); if(i<0){console.error("no layer for "+re);process.exit(1)} return m.layers[i].digest};
  fs.writeFileSync("layers.env",
    "PKG="+find(/COPY \S*package\.json /)+"\n"+
    "DIST="+find(/COPY \S*\/dist /)+"\n"+
    "NODEMOD="+find(/COPY \S*\/node_modules /)+"\n");
  console.log("Entrypoint:", JSON.stringify(c.config.Entrypoint), "Cmd:", JSON.stringify(c.config.Cmd),
              "WorkingDir:", c.config.WorkingDir, "User:", JSON.stringify(c.config.User||""));'
. ./layers.env

curl -fsSL -H "$AUTH" "$REG/blobs/$PKG"  | tar -xzf -
curl -fsSL -H "$AUTH" "$REG/blobs/$DIST" | tar -xzf -
# node_modules is a large layer (~215 MB compressed for rc2); it is streamed and only Baileys is kept on disk.
curl -fsSL -H "$AUTH" "$REG/blobs/$NODEMOD" \
  | tar -xzf - --wildcards 'evolution/node_modules/baileys/package.json' 'evolution/node_modules/baileys/lib/*'

sha256sum evolution/dist/main.js
echo "Extracted into $(pwd)/evolution"
```

If the `find(...)` step fails, upstream changed their Dockerfile. Look at `config.json` `.history[].created_by`.

On a machine **with Docker** (e.g. the Hetzner host) the simpler alternative pulls the whole image (several hundred MB):

```bash
docker pull evoapicloud/evolution-api:<NEW>
docker create --name evo-inspect evoapicloud/evolution-api:<NEW>
mkdir -p upstream && docker cp evo-inspect:/evolution/dist/main.js upstream/main.js \
  && docker cp evo-inspect:/evolution/package.json upstream/package.json \
  && docker cp evo-inspect:/evolution/node_modules/baileys upstream/baileys
docker rm evo-inspect
```

### Inspection commands on the extracted bundle
Run from `upstream-<tag>/`:

```bash
F=evolution/dist/main.js
node --check "$F" && echo "node --check OK"
for p in 'async generateLinkPreview(' 'externalAdReply:{' 'mediaType:2' 'generateHighQualityLinkPreview' \
         'linkPreviewImageThumbnailWidth' '_=R(require("baileys"))' 'this.client=(0,_.default)(a)'; do
  printf '%-40s %s\n' "$p" "$(grep -oF "$p" "$F" | wc -l)"
done
# Show the method and the socket config in context
grep -oE '.{0,120}async generateLinkPreview\(.{0,700}' "$F"
grep -oE '.{0,400}generateHighQualityLinkPreview.{0,300}' "$F"
# Entry point still dist/main, and main.js self-contained?
grep -E '"(main|type|start:prod|version)"' evolution/package.json
node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");
  console.log("relative requires:", [...s.matchAll(/require\(["\x27`](\.[^"\x27`]*)/g)].map(m=>m[1]));
  console.log("relative dynamic imports:", [...s.matchAll(/import\(["\x27`](\.[^"\x27`]*)/g)].map(m=>m[1]));' "$F"
# Baileys
node -p 'require("./evolution/node_modules/baileys/package.json").version'
B=evolution/node_modules/baileys/lib
grep -n -A8 'if (opts.uploadImage)' $B/Utils/link-preview.js
grep -n 'export const extractImageThumb' $B/Utils/messages-media.js
grep -n -A1 'extractImageThumb(file' $B/Utils/messages-media.js
grep -n -B2 -A8 'getUrlInfo: text => getUrlInfo' $B/Socket/messages-send.js
grep -n 'linkPreviewImageThumbnailWidth' $B/Defaults/index.js
```

### Verify the built image on the host (after the workflow pushes it)
On the Hetzner host (or anywhere with Docker). The image's ENTRYPOINT runs migrations and the server, so override it:

```bash
IMG=ghcr.io/fivestarhospitality/evolution-api-patched:<NEW>-lp3
docker pull "$IMG"
docker image inspect "$IMG" --format 'arch={{.Architecture}} entrypoint={{json .Config.Entrypoint}} cmd={{json .Config.Cmd}} workdir={{.Config.WorkingDir}} user={{json .Config.User}}'
docker run --rm --entrypoint sh "$IMG" -c '
  F=/evolution/dist/main.js
  echo "patch 1 (want 1):          $(grep -oF "async generateLinkPreview(e){return void 0}" $F | wc -l)"
  echo "patch 2+3 (want 1):        $(grep -oF "generateHighQualityLinkPreview:!1,linkPreviewImageThumbnailWidth:640," $F | wc -l)"
  echo "old card builder (want 0): $(grep -oF "externalAdReply:{title:" $F | wc -l)"
  echo "HQ flag on (want 0):       $(grep -oF "generateHighQualityLinkPreview:!0" $F | wc -l)"
  echo "leftover patch.sh (want 0): $(ls /tmp/patch.sh 2>/dev/null | wc -l)"
  node --check $F && echo "node --check OK"
  echo "baileys $(node -p "require(\"/evolution/node_modules/baileys/package.json\").version")"
  sha256sum $F
'
```

If a patch was re-derived, its literal strings (e.g. the parameter name `e`) may differ; adjust the greps to match
what `patch.sh` now prints. Compare `entrypoint`/`workdir` with the upstream image
(`docker image inspect evoapicloud/evolution-api:<NEW> …`); they must be identical.

For 2.4.0-rc2-lp3 the expected output is 1 / 1 / 0 / 0 / 0, `node --check OK`, `baileys 7.0.0-rc.9`,
sha256 `14fc64ff9fcd0ba055c54b6d3847cec4fc8936c1e9a98bb3ac5fc1c385c6e000`, and arch amd64, entrypoint
`["/bin/bash","-c",". ./Docker/scripts/deploy_database.sh && npm run start:prod"]` (Docker prints `&&` as
`&&` in JSON), cmd `null`, workdir `/evolution`, user `""`. [verified in repo from the registry, not by running the host commands]

---

## 7. Check FIRST on any new version: has upstream fixed it?

Get the new `main.js` (section 6, `fetch-upstream.sh`), then:

```bash
F=evolution/dist/main.js
grep -oF 'async generateLinkPreview(' "$F" | wc -l   # 2.4.0-rc2: 1
grep -oF 'externalAdReply:{'          "$F" | wc -l   # 2.4.0-rc2: 1  (the card builder)
grep -oF 'mediaType:2'                "$F" | wc -l   # 2.4.0-rc2: 1  (inside the card builder)
grep -oF 'generateHighQualityLinkPreview' "$F" | wc -l   # 2.4.0-rc2: 1
grep -oF 'linkPreviewImageThumbnailWidth' "$F" | wc -l   # 2.4.0-rc2: 0
```

Do **not** grep for bare `externalAdReply`: 2.4.0-rc2 has 28 occurrences, 27 of them code that *reads*
`externalAdReply` from incoming messages (`getAdsMessage`, `externalAdReplyBody`…), which has nothing to do with this
bug. `externalAdReply:{` (object construction) is the meaningful count.

Interpretation:

- **`async generateLinkPreview(` is 0**, or **`externalAdReply:{` and `mediaType:2` are both 0**: Evolution no longer
  builds its ad-reply card. Patch 1 is probably unnecessary. Read the send-text path around `linkPreview` to see what
  replaced it.
- **`generateLinkPreview` still exists but no longer returns `externalAdReply` with `mediaType:2`** (e.g. it now
  returns a Baileys-style `linkPreview` object with bytes): read it. It may be fixed.
- Evolution's routine being fixed **does not make patch 3 unnecessary**. Patch 3 works around Baileys (32 px HQ
  thumbnail plus issue #2199), not Evolution. With Evolution fixed but the HQ flag still on, expect the blurred
  large card again on Channels (`-lp` behaviour).
- **`linkPreviewImageThumbnailWidth` is non-zero**: upstream sets it now; patch 2 will fail with "already present".
  Read the value and decide whether patch 2 is still needed.

Then the **Baileys check** (bundled version: `node -p 'require("./evolution/node_modules/baileys/package.json").version'`):

```bash
curl -s https://api.github.com/repos/WhiskeySockets/Baileys/issues/2199 \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);console.log(j.state,j.state_reason,"closed:",j.closed_at,"-",j.title)})'
# Also look at the issue page for a linked fix PR and the first Baileys release containing it:
#   https://github.com/WhiskeySockets/Baileys/issues/2199
#   https://github.com/WhiskeySockets/Baileys/releases
```

- If #2199 is fixed **and** the bundled Baileys version was released after the fix: the hero card might work on
  Channels again, and patch 3 could be dropped. Build a variant with patches 1+2 only under a **new** tag and test it on
  a real Channel before switching production. Also check whether `link-preview.js` now passes `thumbnailWidth` in the
  `uploadImage` branch, which would make patch 2 meaningful on the HQ path.
- If Evolution's routine is fixed **and** Baileys #2199 is fixed (confirmed on a real Channel with the unpatched
  upstream image), the repo can be retired: point Coolify at the upstream image.

As of 14 Sep 2026: #2199 open; Baileys in the image 7.0.0-rc.9; all three patches needed.

---

## 8. Environment facts

- Runs on **Hetzner**, deployed with **Coolify** as a **Docker Compose** service with three services: **Api**
  (Evolution), **Redis**, **Postgres** [operator-verified]. Only the Api service's `image:` line refers to this repo;
  Redis, Postgres and all env/volumes are managed in Coolify, not here.
- The GHCR package `ghcr.io/fivestarhospitality/evolution-api-patched` **must be public**, or Coolify cannot pull it
  (no registry credentials configured) [operator-verified]. Anonymous pulls of all three tags worked on 14 Sep 2026
  [verified in repo]. New GHCR packages default to private; a brand-new package name would need its visibility changed.
- **Builds are amd64 only.** `build.yml` sets no `platforms:`, so buildx builds for the runner (linux/amd64). Upstream
  also publishes arm64; that bundle was never checked against the patches. [assumption] The Hetzner host is amd64,
  since production runs this image.
- `build.yml` uses `pull: true` (always re-pulls the base tag) and `provenance: false` (single manifest, no
  attestation index). Upstream tags like `2.4.0-rc2` are not digest-pinned. If upstream re-pushes a tag with a
  different bundle, the next build either still patches correctly or fails loudly.
- Upstream image metadata for 2.4.0-rc2: source `https://github.com/evolution-foundation/evolution-api`, revision
  `5624bdaea81c58e4db60fe2a3a8de7c48bba1e60`, created 2026-05-17. Layer order in its Dockerfile: … `COPY package.json`,
  `COPY package-lock.json`, `COPY node_modules`, `COPY dist`, `COPY prisma`, …
- **`patch.sh` must keep LF line endings.** A CRLF `patch.sh` breaks under `/bin/sh` in Alpine. The repo has
  `core.autocrlf=false` set in `.git/config` (local, **not** committed, so a fresh clone on Windows does not inherit
  it; set it again with `git config core.autocrlf false` before editing). Check with `git ls-files --eol patch.sh`
  (want `i/lf w/lf`).
- The image's `COPY patch.sh` layer still contains the script; the following `RUN` deletes it from the final
  filesystem only. Harmless, since the script has no secrets.
- Local testing on Windows works with Git Bash's `sh` plus Node; no Docker needed (see section 6, step 7).
