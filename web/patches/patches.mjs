// node_modules のライブラリに当てる手直し。build.mjs がビルドのたびに当てる（何度当てても同じ結果になる）。
// 元のライブラリ: pptx-vanilla-viewer 3.50.1 / ooxml-core 1.25.1 / ooxml-ui 1.26.1（すべて Apache-2.0）
// 直した内容は、元のリポジトリ（github.com/ChristopherVR/ooxml）にも還す。
export const patches = [
  {
    id: 'text-color-alpha',
    why: '文字色の透明度（a:alpha）を捨てていた。半透明の大きな数字が真っ黒になる',
    // 同じ処理の写しがいくつかのファイルにあるので、見つかったもの全部に当てる
    files: ['ooxml-core/dist/chunk-5F7OB7PA.mjs', 'ooxml-core/dist/chunk-TX2QFS3J.mjs'],
    find: `    if (solidFill2) {
      style.color = this.parseColor(solidFill2);
      const colorXml2 = extractColorChoiceXml(solidFill2);`,
    replace: `    if (solidFill2) {
      style.color = this.parseColor(solidFill2);
      /* ppv-patch: text-color-alpha */
      {
        const ppvOpacity = this.extractColorOpacity(solidFill2);
        if (ppvOpacity !== void 0 && ppvOpacity < 1 && /^#[0-9a-f]{6}$/i.test(style.color || "")) {
          style.color = style.color + Math.round(ppvOpacity * 255).toString(16).padStart(2, "0");
        }
      }
      const colorXml2 = extractColorChoiceXml(solidFill2);`,
  },
  {
    id: 'hanging-punctuation-no-zero-width',
    why: '句読点のぶら下げを、幅ゼロの箱と空白の組で表していた。WebKit ではその箱の中の句読点が描かれない（読点が消える）。'
       + '箱を作らず、WebKit が持つ hanging-punctuation で同じ効果を出す（下の手直しと対）',
    files: ['ooxml-ui/dist/pptx/chunk-NHRL2D4I.mjs'],
    find: `  const hangingPunctuation = props.hangingPunctuation === true;
  const breakAnywhere = props.eaLineBreak === false;`,
    replace: `  const hangingPunctuation = false; /* ppv-patch: hanging-punctuation-no-zero-width */
  const breakAnywhere = props.eaLineBreak === false;`,
  },
  {
    id: 'hanging-punctuation-css',
    why: '上の手直しの対。段落に hanging-punctuation: allow-end を付けて、行末の句読点を枠の外に出す（WebKit が対応。Chrome は無視する）',
    files: ['ooxml-ui/dist/pptx/chunk-NHRL2D4I.mjs'],
    find: `  const result = {};
  if (textStyle.eaLineBreak === true) {
    result.lineBreak = "strict";`,
    replace: `  const result = {};
  /* ppv-patch: hanging-punctuation-css */
  if (textStyle.hangingPunctuation === true) {
    result.hangingPunctuation = "allow-end";
  }
  if (textStyle.eaLineBreak === true) {
    result.lineBreak = "strict";`,
  },
  {
    id: 'ppr-array',
    why: '段落書式 a:pPr が同じ段落に複数回書かれた pptx（pptxgenjs の改行つき文字列で起こる）で、XML パーサが配列を返し、揃え方などを読めずに左揃えになる。一つ目を使う',
    files: ["ooxml-core/dist/chunk-5F7OB7PA.mjs", "ooxml-core/dist/chunk-TX2QFS3J.mjs"],
    all: true,
    find: 'const pPr = paragraph2["a:pPr"];',
    replace: 'const pPr = Array.isArray(paragraph2["a:pPr"]) ? paragraph2["a:pPr"][0] : paragraph2["a:pPr"]; /* ppv-patch: ppr-array */',
  },
  {
    id: 'ppr-array',
    why: '段落書式 a:pPr が同じ段落に複数回書かれた pptx（pptxgenjs の改行つき文字列で起こる）で、XML パーサが配列を返し、揃え方などを読めずに左揃えになる。一つ目を使う',
    files: ["ooxml-core/dist/chunk-5F7OB7PA.mjs", "ooxml-core/dist/chunk-TX2QFS3J.mjs"],
    all: true,
    find: 'const paragraphProps = paragraph2["a:pPr"];',
    replace: 'const paragraphProps = Array.isArray(paragraph2["a:pPr"]) ? paragraph2["a:pPr"][0] : paragraph2["a:pPr"]; /* ppv-patch: ppr-array */',
  },
  {
    id: 'ppr-array',
    why: '段落書式 a:pPr が同じ段落に複数回書かれた pptx（pptxgenjs の改行つき文字列で起こる）で、XML パーサが配列を返し、揃え方などを読めずに左揃えになる。一つ目を使う',
    files: ["ooxml-core/dist/chunk-5F7OB7PA.mjs", "ooxml-core/dist/chunk-TX2QFS3J.mjs"],
    all: true,
    find: 'const pPr = p["a:pPr"];',
    replace: 'const pPr = Array.isArray(p["a:pPr"]) ? p["a:pPr"][0] : p["a:pPr"]; /* ppv-patch: ppr-array */',
  },
  {
    id: 'ppr-array',
    why: '同上（段落書式 a:pPr が配列になる pptx への対応）',
    files: ["ooxml-core/dist/chunk-5F7OB7PA.mjs", "ooxml-core/dist/chunk-TX2QFS3J.mjs"],
    all: true,
    find: '    const directPPr = this.mergeXmlObjects(\n      inheritedParagraph?.["a:pPr"],\n      p["a:pPr"]\n    );',
    replace: '    const directPPr = this.mergeXmlObjects(\n      Array.isArray(inheritedParagraph?.["a:pPr"]) ? inheritedParagraph["a:pPr"][0] : inheritedParagraph?.["a:pPr"],\n      Array.isArray(p["a:pPr"]) ? p["a:pPr"][0] : p["a:pPr"] /* ppv-patch: ppr-array */\n    );',
  },
  {
    id: 'ppr-array',
    why: '同上（段落書式 a:pPr が配列になる pptx への対応）',
    files: ["ooxml-core/dist/chunk-5F7OB7PA.mjs", "ooxml-core/dist/chunk-TX2QFS3J.mjs"],
    all: true,
    find: 'const paragraphLevel = parseParagraphLevel(p["a:pPr"]);',
    replace: 'const paragraphLevel = parseParagraphLevel(Array.isArray(p["a:pPr"]) ? p["a:pPr"][0] : p["a:pPr"]); /* ppv-patch: ppr-array */',
  },
  {
    id: 'ppr-array',
    why: '同上（段落書式 a:pPr が配列になる pptx への対応）',
    files: ["ooxml-core/dist/chunk-5F7OB7PA.mjs", "ooxml-core/dist/chunk-TX2QFS3J.mjs"],
    all: true,
    find: 'const pPrRaw = p["a:pPr"];',
    replace: 'const pPrRaw = Array.isArray(p["a:pPr"]) ? p["a:pPr"][0] : p["a:pPr"]; /* ppv-patch: ppr-array */',
  },
  {
    id: 'star5-geometry',
    why: '五芒星（star5）のプリセット定義が OOXML の公式定義（presetShapeDefinitions.xml）からずれていて、下側の内側の頂点が低すぎ、星がつぶれる。公式の guide と path に差し替える',
    files: ["ooxml-core/dist/chunk-635WPRNJ.mjs", "ooxml-core/dist/chunk-6DHZZD5R.mjs"],
    find: '    gd16("y1", "+- svc 0 dy1"),\n    gd16("y2", "+- svc 0 dy2"),\n',
    replace: '    gd16("y1", "+- svc 0 dy2"),\n    gd16("y2", "+- svc dy1 0"),\n',
  },
  {
    id: 'star5-geometry',
    why: '同上（star5）',
    files: ["ooxml-core/dist/chunk-635WPRNJ.mjs", "ooxml-core/dist/chunk-6DHZZD5R.mjs"],
    find: '    gd16("sy2", "+- svc 0 sdy2"),\n',
    replace: '    gd16("sy2", "+- svc sdy2 0"),\n',
  },
  {
    id: 'star5-geometry',
    why: '同上（star5）',
    files: ["ooxml-core/dist/chunk-635WPRNJ.mjs", "ooxml-core/dist/chunk-6DHZZD5R.mjs"],
    find: '  rect: { l: "sx1", t: "y1", r: "sx4", b: "sy3" },\n  pathLst: [\n    {\n      commands: [\n        { kind: "moveTo", x: "x1", y: "y2" },\n        { kind: "lnTo", x: "sx2", y: "sy2" },\n        { kind: "lnTo", x: "hc", y: "t" },\n        { kind: "lnTo", x: "sx3", y: "sy2" },\n        { kind: "lnTo", x: "x4", y: "y2" },\n        { kind: "lnTo", x: "sx4", y: "sy3" },\n        { kind: "lnTo", x: "x3", y: "b" },\n        { kind: "lnTo", x: "hc", y: "sy3" },\n        { kind: "lnTo", x: "x2", y: "b" },\n        { kind: "lnTo", x: "sx1", y: "sy3" },\n        { kind: "close" }\n',
    replace: '  rect: { l: "sx1", t: "sy1", r: "sx4", b: "sy3" },\n  pathLst: [\n    {\n      commands: [\n        { kind: "moveTo", x: "x1", y: "y1" },\n        { kind: "lnTo", x: "sx2", y: "sy1" },\n        { kind: "lnTo", x: "hc", y: "t" },\n        { kind: "lnTo", x: "sx3", y: "sy1" },\n        { kind: "lnTo", x: "x4", y: "y1" },\n        { kind: "lnTo", x: "sx4", y: "sy2" },\n        { kind: "lnTo", x: "x3", y: "y2" },\n        { kind: "lnTo", x: "hc", y: "sy3" },\n        { kind: "lnTo", x: "x2", y: "y2" },\n        { kind: "lnTo", x: "sx1", y: "sy2" },\n        { kind: "close" }\n',
  },
];
