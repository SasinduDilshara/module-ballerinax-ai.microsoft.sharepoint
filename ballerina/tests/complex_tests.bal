// Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ai;
import ballerina/http;
import ballerina/oauth2;
import ballerina/test;

// Mock-backed ports of the scenarios exercised by the LIVE `sharepoint-tests`
// suite (its simple / medium / large / complex / init / real-world test files).
// Every scenario there that runs against the live Microsoft Graph API is replayed
// here against the data-driven mock in `complex_mock_service.bal`, so the module
// is verified end-to-end with no live tenant. The corpus below mirrors the live
// `corpus.bal`, and the assertions derive their expectations from it, so the mock
// responses and the expected `load()` output can never drift apart.

// ---- corpus model ------------------------------------------------------------

// The document categories the loader maps files onto. (Lower-cased to match the
// `ai:Document` discriminator; named with a `CX_` prefix to avoid clashing with
// the module's internal `DocumentKind` enum members.)
const string CX_TEXT = "text";
const string CX_IMAGE = "image";
const string CX_AUDIO = "audio";
const string CX_BINARY = "binary";

// The library-root folder that contains the main corpus.
const string CX_ROOT = "SPLoaderTests";
// A library-root folder holding a large flat file set, forcing listing pagination.
const string CX_BULK_ROOT = "SPLoaderBulk";
// A library-root folder holding files/folders with awkward, realistic names.
const string CX_SPECIAL_ROOT = "SPLoaderSpecial";
// The display names of the two document libraries on the first site.
const string CX_LIBRARY = "Documents";
const string CX_SPECS_LIBRARY = "Specs";
// The number of files in the bulk folder (exceeds the mock's page size).
const int CX_BULK_COUNT = 250;

# A single file in the corpus. Exactly one of `text` / `bytes` is set.
#
# + path - The path relative to its library-root folder
# + text - The exact text content (for text files)
# + bytes - The exact binary content (for non-text files)
# + docType - The `ai:Document` subtype the loader must produce
public type CxFileSpec record {|
    string path;
    string text?;
    byte[] bytes?;
    string docType;
|};

# A modern site page in the corpus.
#
# + name - The page file name within the Site Pages library
# + title - The page title (becomes the first text block and the `fileName`)
# + innerHtml - The HTML body of the page's first text web part
# + additionalHtml - HTML bodies of any further text web parts
# + expectedSubstrings - Plain-text fragments that must survive HTML stripping
public type CxPageSpec record {|
    string name;
    string title;
    string innerHtml;
    string[] additionalHtml = [];
    string[] expectedSubstrings;
|};

// ---- binary blobs ------------------------------------------------------------

isolated function cxPdf(string tag) returns byte[] => string `%PDF-1.4 ${tag} %%EOF`.toBytes();

isolated function cxZip(string tag) returns byte[] => string `PK${"\u{0003}"}${"\u{0004}"} ${tag}`.toBytes();

isolated function cxPng(string tag) returns byte[] => string `${"\u{0089}"}PNG${"\r"}${"\n"} ${tag}`.toBytes();

isolated function cxJpg(string tag) returns byte[] => string `${"\u{00FF}"}${"\u{00D8}"}${"\u{00FF}"} ${tag}`.toBytes();

isolated function cxGif(string tag) returns byte[] => string `GIF89a ${tag}`.toBytes();

isolated function cxMp3(string tag) returns byte[] => string `ID3 ${tag}`.toBytes();

isolated function cxWav(string tag) returns byte[] => string `RIFF ${tag} WAVE`.toBytes();

isolated function cxBin(string tag) returns byte[] => string `BLOB ${tag}`.toBytes();

# The main corpus (provisioned under `CX_ROOT` in the Documents library).
#
# + return - Every file in the main corpus, keyed by its `CX_ROOT`-relative path
isolated function cxCorpus() returns CxFileSpec[] => [
    // ---- root-level files: one of (almost) every supported extension --------
    {path: "root-note.txt", text: "Root level plain text note.", docType: CX_TEXT},
    {path: "overview.md", text: "# Overview\n\nProject overview in Markdown.", docType: CX_TEXT},
    {path: "data.json", text: "{\"name\":\"corpus\",\"size\":36}", docType: CX_TEXT},
    {path: "records.csv", text: "id,name\n1,alpha\n2,beta", docType: CX_TEXT},
    {path: "config.yaml", text: "service: sharepoint\nenabled: true", docType: CX_TEXT},
    {path: "landing.html", text: "<html><body><h1>Landing</h1></body></html>", docType: CX_TEXT},
    {path: "app.log", text: "INFO startup complete", docType: CX_TEXT},
    {path: "diagram.png", bytes: cxPng("diagram"), docType: CX_IMAGE},
    {path: "photo.jpg", bytes: cxJpg("photo"), docType: CX_IMAGE},
    {path: "icon.gif", bytes: cxGif("icon"), docType: CX_IMAGE},
    {path: "clip.mp3", bytes: cxMp3("clip"), docType: CX_AUDIO},
    {path: "voice.wav", bytes: cxWav("voice"), docType: CX_AUDIO},
    {path: "report.pdf", bytes: cxPdf("report"), docType: CX_BINARY},
    {path: "bundle.zip", bytes: cxZip("bundle"), docType: CX_BINARY},
    {path: "manifest.docx", bytes: cxZip("manifest"), docType: CX_BINARY},
    {path: "slides.pptx", bytes: cxZip("slides"), docType: CX_BINARY},
    {path: "blob.bin", bytes: cxBin("blob"), docType: CX_BINARY},

    // ---- Policies/ (+ nested Archive/ + deeply nested Deep/) -----------------
    {path: "Policies/leave-policy.txt", text: "Employees accrue 20 days of leave.", docType: CX_TEXT},
    {path: "Policies/conduct.md", text: "## Code of Conduct\n\nBe excellent to each other.", docType: CX_TEXT},
    {path: "Policies/benefits.pdf", bytes: cxPdf("benefits"), docType: CX_BINARY},
    {path: "Policies/Archive/old-policy.txt", text: "Superseded leave policy from 2019.", docType: CX_TEXT},
    {path: "Policies/Archive/legacy.pdf", bytes: cxPdf("legacy"), docType: CX_BINARY},
    {path: "Policies/Archive/Deep/ancient.md", text: "# Ancient\n\nThe oldest record in the archive.", docType: CX_TEXT},

    // ---- Reports/ (+ nested 2023/) ------------------------------------------
    {path: "Reports/q1.pdf", bytes: cxPdf("q1"), docType: CX_BINARY},
    {path: "Reports/q2.pdf", bytes: cxPdf("q2"), docType: CX_BINARY},
    {path: "Reports/summary.csv", text: "quarter,revenue\nq1,100\nq2,140", docType: CX_TEXT},
    {path: "Reports/2023/annual.pdf", bytes: cxPdf("annual"), docType: CX_BINARY},
    {path: "Reports/2023/annual-notes.txt", text: "Annual report supporting notes.", docType: CX_TEXT},

    // ---- Media/ (images + audio only) ---------------------------------------
    {path: "Media/banner.png", bytes: cxPng("banner"), docType: CX_IMAGE},
    {path: "Media/jingle.mp3", bytes: cxMp3("jingle"), docType: CX_AUDIO},
    {path: "Media/promo.wav", bytes: cxWav("promo"), docType: CX_AUDIO},

    // ---- Mixed/ (one of each kind side by side) -----------------------------
    {path: "Mixed/mix-a.txt", text: "Mixed folder text file.", docType: CX_TEXT},
    {path: "Mixed/mix-b.pdf", bytes: cxPdf("mix-b"), docType: CX_BINARY},
    {path: "Mixed/mix-c.png", bytes: cxPng("mix-c"), docType: CX_IMAGE},
    {path: "Mixed/mix-d.mp3", bytes: cxMp3("mix-d"), docType: CX_AUDIO},
    {path: "Mixed/mix-e.json", text: "{\"mixed\":true}", docType: CX_TEXT},
    {path: "Mixed/mix-f.docx", bytes: cxZip("mix-f"), docType: CX_BINARY},
    {path: "Mixed/mix-g.pptx", bytes: cxZip("mix-g"), docType: CX_BINARY},

    // ---- Shared/ exists in BOTH libraries, for the wildcard union test -------
    {path: "Shared/doc-shared.txt", text: "Shared file living in the Documents library.", docType: CX_TEXT}
];

# The files in the second document library (`Specs`), under `CX_ROOT`.
#
# + return - The Specs-library files, keyed by `CX_ROOT`-relative path
isolated function cxSpecsCorpus() returns CxFileSpec[] => [
    {path: "spec-overview.md", text: "# Specs\n\nOverview of the specs library.", docType: CX_TEXT},
    {path: "api-design.pdf", bytes: cxPdf("api-design"), docType: CX_BINARY},
    {path: "Shared/spec-shared.txt", text: "Shared file living in the Specs library.", docType: CX_TEXT},
    {path: "Drafts/draft-one.txt", text: "First draft document.", docType: CX_TEXT},
    {path: "Drafts/draft-two.pdf", bytes: cxPdf("draft-two"), docType: CX_BINARY}
];

# A large flat set of text files (under `CX_BULK_ROOT`) that forces the folder
# listing to paginate over the mock's `@odata.nextLink`.
#
# + return - `CX_BULK_COUNT` text files named `file-001.txt` .. `file-NNN.txt`
isolated function cxBulkFiles() returns CxFileSpec[] {
    CxFileSpec[] files = [];
    int i = 1;
    while i <= CX_BULK_COUNT {
        string num = i < 10 ? string `00${i}` : (i < 100 ? string `0${i}` : i.toString());
        files.push({path: string `file-${num}.txt`, text: string `bulk file ${num}`, docType: CX_TEXT});
        i += 1;
    }
    return files;
}

# Files and folders with realistic, awkward names (under `CX_SPECIAL_ROOT`): spaces,
# non-ASCII characters, ampersands, and the SAME leaf name in two folders.
#
# + return - The special-name files, keyed by `CX_SPECIAL_ROOT`-relative path
isolated function cxSpecialFiles() returns CxFileSpec[] => [
    // Direct children (loaded by item id, so the awkward names are safe).
    {path: "R&D Notes.txt", text: "Research and development notes.", docType: CX_TEXT},
    {path: "Q3 Report.pdf", bytes: cxPdf("q3"), docType: CX_BINARY},
    {path: "résumé.txt", text: "Curriculum vitae.", docType: CX_TEXT},
    {path: "日本語.md", text: "# 日本語\n\nUnicode file name.", docType: CX_TEXT},
    {path: "a+b (final).pptx", bytes: cxZip("a-b-final"), docType: CX_BINARY},
    // Sub-folders with spaces (reached by path during recursion).
    {path: "Project Plans/roadmap 2026.txt", text: "Roadmap for 2026.", docType: CX_TEXT},
    {path: "Project Plans/Sub Folder/deep note.md", text: "# Deep\n\nA deeply nested note.", docType: CX_TEXT},
    // Duplicate leaf name in two different folders.
    {path: "Reports A/summary.csv", text: "team,score\nA,10", docType: CX_TEXT},
    {path: "Reports B/summary.csv", text: "team,score\nB,20", docType: CX_TEXT}
];

# A small marker corpus in the SECOND site's Documents library, under `CX_ROOT`.
#
# + return - The second-site files, keyed by `CX_ROOT`-relative path
isolated function cxSecondSiteFiles() returns CxFileSpec[] => [
    {path: "site2-readme.md", text: "# Site Two\n\nSecond site readme.", docType: CX_TEXT},
    {path: "site2-data.json", text: "{\"site\":2}", docType: CX_TEXT},
    {path: "site2-report.pdf", bytes: cxPdf("site2"), docType: CX_BINARY}
];

# The modern pages in the corpus (hosted by the first site).
#
# + return - Every page to expect
isolated function cxPages() returns CxPageSpec[] => [
    {
        name: "SPLoaderHome.aspx",
        title: "SP Loader Home",
        innerHtml: "<h1>Welcome</h1><p>This is the <b>home</b> page of the loader test site.</p>",
        expectedSubstrings: ["SP Loader Home", "Welcome", "home", "loader test site"]
    },
    {
        name: "SPLoaderNews.aspx",
        title: "SP Loader News",
        innerHtml: "<h2>Latest News</h2><p>Quarterly results are <i>strong</i>.</p>",
        expectedSubstrings: ["SP Loader News", "Latest News", "Quarterly results", "strong"]
    },
    {
        name: "SPLoaderHandbook.aspx",
        title: "Employee Handbook",
        innerHtml: "<h1>Handbook</h1><p>Section&nbsp;1: Leave &amp; benefits &lt;policy&gt;.</p>",
        expectedSubstrings: ["Employee Handbook", "Handbook", "Section 1", "Leave & benefits", "<policy>"]
    },
    {
        name: "SPLoaderRoadmap.aspx",
        title: "Product Roadmap",
        innerHtml: "<h2>Roadmap</h2><ul><li>Phase One</li><li>Phase Two</li><li>Phase Three</li></ul>",
        expectedSubstrings: ["Product Roadmap", "Roadmap", "Phase One", "Phase Two", "Phase Three"]
    },
    {
        name: "SPLoaderContacts.aspx",
        title: "Contacts",
        innerHtml: "<h3>Contacts</h3><p>Email: team&#64;example.com &mdash; HQ.</p>",
        expectedSubstrings: ["Contacts", "Email", "HQ"]
    },
    {
        // A page split across several text web parts; the loader must collect and
        // concatenate the text from all of them.
        name: "SPLoaderQuarterly.aspx",
        title: "Quarterly Review",
        innerHtml: "<h1>Quarterly Review</h1><p>Executive summary for the quarter.</p>",
        additionalHtml: [
            "<h2>Revenue</h2><p>Revenue grew across all regions.</p>",
            "<h2>Risks</h2><p>Supply chain remains a watch item.</p>"
        ],
        expectedSubstrings: [
            "Quarterly Review", "Executive summary", "Revenue grew", "all regions",
            "Risks", "Supply chain"
        ]
    }
];

// ---- corpus derivation helpers -----------------------------------------------

# Returns the byte content the mock should serve for a file spec. Text files serve
# their exact UTF-8 text; PDF files serve a real, Tika-extractable fixture (so the
# loader produces a `TextDocument`); other binaries (images, audio, Office documents)
# serve their placeholder bytes, which the loader downloads and then discards as a
# skipped non-text file.
isolated function cxContentBytes(CxFileSpec spec) returns byte[] {
    byte[]? fixture = extractableFixture(cxExt(cxLeafName(spec)));
    if fixture is byte[] {
        return fixture;
    }
    string? text = spec?.text;
    return text is string ? text.toBytes() : (spec?.bytes ?: []);
}

# The lower-cased extension (without the dot) of a leaf file name, or `""`.
isolated function cxExt(string name) returns string {
    int? dot = name.lastIndexOf(".");
    return dot is () ? "" : name.substring(dot + 1).toLowerAscii();
}

# Whether a file's text is extracted by Tika. Currently PDF only: Microsoft Office
# document formats (.doc/.docx/.ppt/.pptx/.xls/.xlsx) are temporarily unsupported in
# the loader and are skipped like other binaries.
isolated function cxIsExtractable(string name) returns boolean {
    return cxExt(name) == "pdf";
}

# The subset of specs the loader returns as `TextDocument`s: text files (decoded)
# and extractable document formats. Images, audio, and other binaries are skipped.
isolated function cxReturned(CxFileSpec[] specs) returns CxFileSpec[] {
    CxFileSpec[] result = [];
    foreach CxFileSpec spec in specs {
        if spec?.text is string || cxIsExtractable(cxLeafName(spec)) {
            result.push(spec);
        }
    }
    return result;
}

# Returns the leaf file name of a file spec.
isolated function cxLeafName(CxFileSpec spec) returns string {
    int? idx = spec.path.lastIndexOf("/");
    return idx is () ? spec.path : spec.path.substring(idx + 1);
}

# Returns the loader path for a `CX_ROOT`-relative path (`""` for the root itself).
isolated function cxLoaderPath(string rel) returns string => cxRootPath(CX_ROOT, rel);

# Returns the loader path under an arbitrary library-root folder.
isolated function cxRootPath(string root, string rel) returns string =>
    rel == "" ? string `/${root}` : string `/${root}/${rel}`;

# The specs reachable under a `CX_ROOT`-relative folder in the main corpus.
isolated function cxSpecsUnder(string rel, boolean recursive) returns CxFileSpec[] =>
    cxSpecsUnderIn(cxCorpus(), rel, recursive);

# Like `cxSpecsUnder`, but against an explicit corpus.
isolated function cxSpecsUnderIn(CxFileSpec[] all, string rel, boolean recursive) returns CxFileSpec[] {
    string prefix = rel == "" ? "" : rel + "/";
    CxFileSpec[] result = [];
    foreach CxFileSpec spec in all {
        if !spec.path.startsWith(prefix) {
            continue;
        }
        string remainder = spec.path.substring(prefix.length());
        boolean nested = remainder.indexOf("/") !is ();
        if nested && !recursive {
            continue;
        }
        result.push(spec);
    }
    return result;
}

# Applies the loader's extension allowlist to a set of specs.
isolated function cxFilterByExtension(CxFileSpec[] specs, string[]? extensions) returns CxFileSpec[] {
    if extensions is () || extensions.length() == 0 {
        return specs;
    }
    string[] normalized = [];
    foreach string ext in extensions {
        string e = ext.toLowerAscii();
        normalized.push(e.startsWith(".") ? e.substring(1) : e);
    }
    CxFileSpec[] result = [];
    foreach CxFileSpec spec in specs {
        string name = cxLeafName(spec);
        int? dot = name.lastIndexOf(".");
        string ext = dot is () ? "" : name.substring(dot + 1).toLowerAscii();
        if normalized.indexOf(ext) !is () {
            result.push(spec);
        }
    }
    return result;
}

# Finds a single file spec by its relative path in the main corpus.
isolated function cxSpecOf(string rel) returns CxFileSpec => cxSpecOfIn(cxCorpus(), rel);

# Like `cxSpecOf`, but against an explicit corpus.
isolated function cxSpecOfIn(CxFileSpec[] all, string rel) returns CxFileSpec {
    foreach CxFileSpec spec in all {
        if spec.path == rel {
            return spec;
        }
    }
    panic error(string `No corpus file at '${rel}'`);
}

# Counts loaded documents whose file name equals the given leaf name.
isolated function cxCountByLeaf(ai:Document[] docs, string leaf) returns int {
    int count = 0;
    foreach ai:Document doc in docs {
        if doc.metadata?.fileName == leaf {
            count += 1;
        }
    }
    return count;
}

// ---- loader / load helpers ---------------------------------------------------

# Builds a loader with the default (bearer-token) configuration against the rich
# mock service.
isolated function cxNewLoader(Source[] sources) returns TextDataLoader|ai:Error =>
    new ({auth: {token: "cx-token"}, serviceUrl: CX_SERVICE_URL}, sources);

# Builds a loader with an explicit connection configuration.
isolated function cxNewLoaderWith(ConnectionConfig config, Source[] sources)
        returns TextDataLoader|ai:Error => new (config, sources);

# Builds a `Source` targeting the first mock site, defaulting unset fields. Each
# name in `driveNames` becomes its own `Library` (the per-library model).
isolated function cxMkSource(string[] paths = [], boolean recursive = false, string[]? includeExtensions = (),
        string[]? pages = (), string[] driveNames = [CX_LIBRARY], string siteId = CX_SITE) returns Source {
    Library[] libraries = [];
    if paths.length() > 0 {
        foreach string name in driveNames {
            libraries.push({name: name, paths, recursive, includeExtensions});
        }
    }
    return {siteId, libraries, pages};
}

# Runs the raw load and normalizes the result to an array.
isolated function cxLoadDocs(TextDataLoader loader) returns ai:Document[]|ai:Error {
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    if result is ai:Error {
        return result;
    }
    return result is ai:Document[] ? result : [result];
}

# Convenience: build a loader for a single source and load it.
isolated function cxLoadSource(Source src) returns ai:Document[]|ai:Error {
    TextDataLoader loader = check cxNewLoader([src]);
    return cxLoadDocs(loader);
}

# Convenience: build a loader for a single source and return the RAW result so a
# single-document return can be distinguished from an array.
isolated function cxLoadRaw(Source src) returns ai:Document[]|ai:Document|ai:Error {
    TextDataLoader|ai:Error loader = cxNewLoader([src]);
    if loader is ai:Error {
        return loader;
    }
    return loader.load();
}

// ---- assertions --------------------------------------------------------------

# Asserts a loaded document set is EXACTLY the text documents implied by the given
# specs: the text/extractable specs (images, audio, and other binaries are skipped),
# each loaded as a `TextDocument` with matching name and content.
# Note: not for spec sets with duplicate leaf names (those use count assertions).
isolated function cxAssertCorpus(ai:Document[] docs, CxFileSpec[] expected) {
    CxFileSpec[] returned = cxReturned(expected);
    test:assertEquals(docs.length(), returned.length(),
            string `Expected ${returned.length()} documents but loaded ${docs.length()}`);
    test:assertEquals(countByType(docs, CX_TEXT), returned.length(),
            "every loaded document must be a TextDocument");
    foreach CxFileSpec spec in returned {
        string name = cxLeafName(spec);
        ai:Document? doc = findByFileName(docs, name);
        if doc is ai:Document {
            cxAssertDoc(doc, spec);
        } else {
            test:assertFail(string `Expected document '${name}' was not loaded`);
        }
    }
}

# Asserts a single document matches its spec: it is a `TextDocument` whose content is
# the exact decoded text (text files) or contains the fixture's marker text (extracted
# PDF/Office files).
isolated function cxAssertDoc(ai:Document doc, CxFileSpec spec) {
    string name = cxLeafName(spec);
    test:assertEquals(doc.metadata?.fileName, name, string `Wrong file name for '${name}'`);
    if doc !is ai:TextDocument {
        test:assertFail(string `Expected '${name}' to be a TextDocument`);
    }
    string? text = spec?.text;
    if text is string {
        test:assertEquals(doc.content, text, string `Wrong text content for '${name}'`);
        return;
    }
    string? marker = extractableText(cxExt(name));
    if marker is string {
        test:assertTrue(doc.content.includes(marker),
                string `Extracted text for '${name}' is missing its marker. Content: ${doc.content}`);
    }
}

# Asserts a single corpus file loaded as a single document and matches its spec.
isolated function cxAssertSingleFile(ai:Document[]|ai:Document|ai:Error result, string rel) {
    if result is ai:Error {
        test:assertFail(string `Loading '${rel}' failed: ${result.message()}`);
    }
    test:assertFalse(result is ai:Document[], string `Loading the single file '${rel}' should return one document`);
    ai:Document doc = result is ai:Document[] ? result[0] : result;
    cxAssertDoc(doc, cxSpecOf(rel));
}

# Asserts a combined load of files AND pages contains exactly the expected file
# documents and page documents.
isolated function cxAssertFilesAndPages(ai:Document[] docs, CxFileSpec[] files, CxPageSpec[] pageSpecs) {
    CxFileSpec[] returned = cxReturned(files);
    test:assertEquals(docs.length(), returned.length() + pageSpecs.length(),
            string `Expected ${returned.length()} files + ${pageSpecs.length()} pages but loaded ${docs.length()}`);
    foreach CxFileSpec spec in returned {
        string name = cxLeafName(spec);
        ai:Document? doc = findByFileName(docs, name);
        if doc is ai:Document {
            cxAssertDoc(doc, spec);
        } else {
            test:assertFail(string `Expected file '${name}' was not loaded`);
        }
    }
    foreach CxPageSpec page in pageSpecs {
        cxAssertPage(docs, page);
    }
}

# Asserts a loaded page document carries the expected plain text with HTML stripped.
isolated function cxAssertPage(ai:Document[] docs, CxPageSpec page) {
    ai:Document? doc = findByFileName(docs, page.title);
    if doc is ai:TextDocument {
        foreach string fragment in page.expectedSubstrings {
            test:assertTrue(doc.content.includes(fragment),
                    string `Page '${page.title}' is missing '${fragment}'. Content: ${doc.content}`);
        }
        test:assertFalse(doc.content.includes("<h1"), "HTML tags should be stripped from page content");
        test:assertFalse(doc.content.includes("<p>"), "HTML tags should be stripped from page content");
        test:assertEquals(doc.metadata?.mimeType, "text/plain", "Pages must be text/plain");
    } else {
        test:assertFail(string `Page '${page.title}' was not loaded as a TextDocument`);
    }
}

// ==============================================================================
// SIMPLE: single files & single shallow folders
// ==============================================================================

@test:Config {}
isolated function testCxSimpleSingleTextFile() {
    cxAssertSingleFile(cxLoadRaw(cxMkSource(paths = [cxLoaderPath("root-note.txt")])), "root-note.txt");
}

@test:Config {}
isolated function testCxSimpleSinglePdf() {
    cxAssertSingleFile(cxLoadRaw(cxMkSource(paths = [cxLoaderPath("report.pdf")])), "report.pdf");
}

@test:Config {}
isolated function testCxSimpleSingleImageErrors() {
    // A deliberately named non-text file cannot be represented as text, so an
    // explicit image path is an error (whereas in a folder it would be skipped).
    ai:Document[]|ai:Document|ai:Error result = cxLoadRaw(cxMkSource(paths = [cxLoaderPath("diagram.png")]));
    if result is ai:Error {
        test:assertTrue(result.message().includes("Unsupported (non-text) file type"), result.message());
    } else {
        test:assertFail("An explicit image path should error");
    }
}

@test:Config {}
isolated function testCxSimpleSingleAudioErrors() {
    ai:Document[]|ai:Document|ai:Error result = cxLoadRaw(cxMkSource(paths = [cxLoaderPath("clip.mp3")]));
    if result is ai:Error {
        test:assertTrue(result.message().includes("Unsupported (non-text) file type"), result.message());
    } else {
        test:assertFail("An explicit audio path should error");
    }
}

@test:Config {}
isolated function testCxSimpleSingleDocx() {
    // Office text extraction is temporarily disabled, so an explicitly named .docx
    // path is rejected as an unsupported file type.
    ai:Document[]|ai:Document|ai:Error result = cxLoadRaw(cxMkSource(paths = [cxLoaderPath("manifest.docx")]));
    if result is ai:Error {
        test:assertTrue(result.message().includes("Microsoft Office documents"), result.message());
    } else {
        test:assertFail("An explicit Office document path should error");
    }
}

@test:Config {}
isolated function testCxSimpleSingleJson() {
    cxAssertSingleFile(cxLoadRaw(cxMkSource(paths = [cxLoaderPath("data.json")])), "data.json");
}

@test:Config {}
isolated function testCxSimpleSinglePptx() {
    // Office text extraction is temporarily disabled, so an explicitly named .pptx
    // path is rejected as an unsupported file type.
    ai:Document[]|ai:Document|ai:Error result = cxLoadRaw(cxMkSource(paths = [cxLoaderPath("slides.pptx")]));
    if result is ai:Error {
        test:assertTrue(result.message().includes("Microsoft Office documents"), result.message());
    } else {
        test:assertFail("An explicit Office document path should error");
    }
}

@test:Config {}
isolated function testCxSimpleSingleCsv() {
    cxAssertSingleFile(cxLoadRaw(cxMkSource(paths = [cxLoaderPath("records.csv")])), "records.csv");
}

@test:Config {}
isolated function testCxSimpleSingleHtml() {
    cxAssertSingleFile(cxLoadRaw(cxMkSource(paths = [cxLoaderPath("landing.html")])), "landing.html");
}

@test:Config {}
isolated function testCxSimpleEmptyFolder() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("EmptyFolder")]));
    test:assertEquals(docs.length(), 0, "An empty folder must yield no documents");
}

@test:Config {}
isolated function testCxSimpleFlatMediaFolder() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Media")]));
    cxAssertCorpus(docs, cxSpecsUnder("Media", false));
}

// ==============================================================================
// MEDIUM: folders, recursion, extension filters, multi-path
// ==============================================================================

@test:Config {}
isolated function testCxMediumCorpusRootNonRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("")]));
    cxAssertCorpus(docs, cxSpecsUnder("", false));
}

@test:Config {}
isolated function testCxMediumCorpusRootRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("")], recursive = true));
    cxAssertCorpus(docs, cxSpecsUnder("", true));
}

@test:Config {}
isolated function testCxMediumPoliciesNonRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Policies")]));
    cxAssertCorpus(docs, cxSpecsUnder("Policies", false));
}

@test:Config {}
isolated function testCxMediumPoliciesRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Policies")], recursive = true));
    cxAssertCorpus(docs, cxSpecsUnder("Policies", true));
}

@test:Config {}
isolated function testCxMediumReportsRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Reports")], recursive = true));
    cxAssertCorpus(docs, cxSpecsUnder("Reports", true));
}

@test:Config {}
isolated function testCxMediumRecursivePdfFilter() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["pdf"]));
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnder("", true), ["pdf"]));
}

@test:Config {}
isolated function testCxMediumRecursivePngAndMp3Filter() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["png", "mp3"]));
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnder("", true), ["png", "mp3"]));
}

@test:Config {}
isolated function testCxMediumMixedFolderTextOnlyFilter() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("Mixed")], includeExtensions = ["txt", "json"]));
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnder("Mixed", false), ["txt", "json"]));
}

@test:Config {}
isolated function testCxMediumMultipleExplicitFiles() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [
        cxLoaderPath("root-note.txt"),
        cxLoaderPath("report.pdf"),
        cxLoaderPath("data.json")
    ]));
    cxAssertCorpus(docs, [cxSpecOf("root-note.txt"), cxSpecOf("report.pdf"), cxSpecOf("data.json")]);
}

@test:Config {}
isolated function testCxMediumExplicitFileBypassesExtensionFilter() {
    ai:Document[]|ai:Document|ai:Error result =
            cxLoadRaw(cxMkSource(paths = [cxLoaderPath("overview.md")], includeExtensions = ["pdf"]));
    cxAssertSingleFile(result, "overview.md");
}

// ==============================================================================
// LARGE: whole-tree, pages, and multi-path aggregations
// ==============================================================================

@test:Config {}
isolated function testCxLargeWholeTreeWithAllPages() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("")], recursive = true, pages = ["*"]));
    cxAssertFilesAndPages(docs, cxSpecsUnder("", true), cxPages());
}

@test:Config {}
isolated function testCxLargeAllPagesOnly() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(pages = ["*"]));
    foreach CxPageSpec page in cxPages() {
        cxAssertPage(docs, page);
    }
    test:assertTrue(docs.length() >= cxPages().length(), "Every page should be loaded");
}

@test:Config {}
isolated function testCxLargeMultipleFoldersRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(
            paths = [cxLoaderPath("Policies"), cxLoaderPath("Reports"), cxLoaderPath("Media")], recursive = true));
    CxFileSpec[] expected = [
        ...cxSpecsUnder("Policies", true),
        ...cxSpecsUnder("Reports", true),
        ...cxSpecsUnder("Media", true)
    ];
    cxAssertCorpus(docs, expected);
}

@test:Config {}
isolated function testCxLargeTextExtensionsAcrossTree() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["txt", "md"]));
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnder("", true), ["txt", "md"]));
}

@test:Config {}
isolated function testCxLargeBinaryExtensionsAcrossTree() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["pdf", "docx", "zip", "bin"]));
    // The filter passes pdf/docx/zip/bin; only the pdf is extracted to text, while
    // docx (temporarily unsupported Office), zip, and bin are skipped as non-text, so
    // only the pdf documents are returned.
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnder("", true), ["pdf", "docx", "zip", "bin"]));
    foreach ai:Document doc in docs {
        test:assertEquals(doc.'type, CX_TEXT, "Every returned document is a TextDocument");
    }
}

@test:Config {}
isolated function testCxLargeTwoSourcesAggregated() returns error? {
    TextDataLoader loader = check cxNewLoader([cxMkSource(paths = [cxLoaderPath("Policies")], recursive = true),
            cxMkSource(paths = [cxLoaderPath("Media")])]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, [...cxSpecsUnder("Policies", true), ...cxSpecsUnder("Media", false)]);
}

@test:Config {}
isolated function testCxLargeDeepArchiveRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Policies/Archive")], recursive = true));
    cxAssertCorpus(docs, cxSpecsUnder("Policies/Archive", true));
}

@test:Config {}
isolated function testCxLargeDeepArchiveNonRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Policies/Archive")]));
    cxAssertCorpus(docs, cxSpecsUnder("Policies/Archive", false));
}

@test:Config {}
isolated function testCxLargeNamedPagesSubset() returns error? {
    CxPageSpec home = cxPages()[0];
    CxPageSpec handbook = cxPages()[2];
    ai:Document[] docs = check cxLoadSource(cxMkSource(pages = [home.title, handbook.title]));
    test:assertEquals(docs.length(), 2, "Exactly the two named pages should load");
    cxAssertPage(docs, home);
    cxAssertPage(docs, handbook);
}

@test:Config {}
isolated function testCxLargeNestedYearFolder() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Reports/2023")]));
    cxAssertCorpus(docs, cxSpecsUnder("Reports/2023", false));
}

// ==============================================================================
// COMPLEX: multi-source, multi-drive, files+pages, HTTP & auth
// ==============================================================================

@test:Config {}
isolated function testCxComplexMultiSourceFilesAndPages() returns error? {
    CxPageSpec home = cxPages()[0];
    TextDataLoader loader = check cxNewLoader([cxMkSource(paths = [cxLoaderPath("Policies")], recursive = true, pages = [home.title]),
            cxMkSource(paths = [cxLoaderPath("Reports")], recursive = true)]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertFilesAndPages(docs, [...cxSpecsUnder("Policies", true), ...cxSpecsUnder("Reports", true)], [home]);
}

@test:Config {}
isolated function testCxComplexMultiDriveWildcardTolerant() returns error? {
    // The wildcard reads every library; Policies exists only in Documents, and a
    // library that lacks the path is tolerated rather than failing the load.
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("Policies")], recursive = true, driveNames = ["*"]));
    cxAssertCorpus(docs, cxSpecsUnder("Policies", true));
}

@test:Config {}
isolated function testCxComplexExplicitLibraryWithMixedFilter() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(
            paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["pdf", "png", "mp3"],
            driveNames = [CX_LIBRARY]));
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnder("", true), ["pdf", "png", "mp3"]));
}

@test:Config {}
isolated function testCxComplexTwoDisjointSourcesNoDuplicates() returns error? {
    TextDataLoader loader = check cxNewLoader([cxMkSource(paths = [cxLoaderPath("")]),
            cxMkSource(paths = [cxLoaderPath("Mixed")])]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, [...cxSpecsUnder("", false), ...cxSpecsUnder("Mixed", false)]);
}

@test:Config {}
isolated function testCxComplexHttp1WithRetryAndTimeout() returns error? {
    ConnectionConfig config = {
        auth: {token: "cx-token"},
        serviceUrl: CX_SERVICE_URL,
        httpVersion: http:HTTP_1_1,
        timeout: 90,
        http1Settings: {keepAlive: http:KEEPALIVE_ALWAYS},
        retryConfig: {count: 2, interval: 1}
    };
    TextDataLoader loader =
            check cxNewLoaderWith(config, [cxMkSource(paths = [cxLoaderPath("Reports")], recursive = true)]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, cxSpecsUnder("Reports", true));
}

@test:Config {}
isolated function testCxComplexCompressionAndResponseLimits() returns error? {
    ConnectionConfig config = {
        auth: {token: "cx-token"},
        serviceUrl: CX_SERVICE_URL,
        compression: http:COMPRESSION_ALWAYS,
        http2Settings: {},
        responseLimits: {},
        poolConfig: {}
    };
    TextDataLoader loader =
            check cxNewLoaderWith(config, [cxMkSource(paths = [cxLoaderPath("Policies")], recursive = true)]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, cxSpecsUnder("Policies", true));
}

@test:Config {}
isolated function testCxComplexBearerTokenAuth() {
    ConnectionConfig config = {auth: {token: "cx-bearer-token"}, serviceUrl: CX_SERVICE_URL};
    TextDataLoader|ai:Error loader =
            cxNewLoaderWith(config, [cxMkSource(paths = [cxLoaderPath("root-note.txt")])]);
    if loader is ai:Error {
        test:assertFail(loader.message());
    }
    cxAssertSingleFile(loader.load(), "root-note.txt");
}

@test:Config {}
isolated function testCxComplexClientCredentialsAuth() returns error? {
    oauth2:ClientCredentialsGrantConfig auth = {tokenUrl: CX_TOKEN_URL, clientId: "id", clientSecret: "secret"};
    TextDataLoader loader =
            check cxNewLoaderWith({auth, serviceUrl: CX_SERVICE_URL}, [cxMkSource(paths = [cxLoaderPath("Media")])]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, cxSpecsUnder("Media", false));
}

@test:Config {}
isolated function testCxComplexRefreshTokenAuth() returns error? {
    oauth2:RefreshTokenGrantConfig auth = {
        refreshUrl: CX_TOKEN_URL,
        refreshToken: "rt",
        clientId: "id",
        clientSecret: "secret",
        scopes: ["https://graph.microsoft.com/.default"]
    };
    TextDataLoader loader =
            check cxNewLoaderWith({auth, serviceUrl: CX_SERVICE_URL}, [cxMkSource(paths = [cxLoaderPath("Policies")])]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, cxSpecsUnder("Policies", false));
}

@test:Config {}
isolated function testCxComplexRichPageEntityDecoding() returns error? {
    // The handbook page mixes HTML tags with entities (&nbsp; &amp; &lt; &gt;);
    // the loader must strip tags but decode entities into literal characters.
    CxPageSpec handbook = cxPages()[2];
    ai:Document[] docs = check cxLoadSource(cxMkSource(pages = [handbook.title]));
    test:assertEquals(docs.length(), 1, "Exactly the handbook page should load");
    cxAssertPage(docs, handbook);
}

@test:Config {}
isolated function testCxComplexEverythingCombined() returns error? {
    // PDFs across the whole tree + the Media folder + every page, aggregated.
    TextDataLoader loader = check cxNewLoader([cxMkSource(paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["pdf"]),
            cxMkSource(paths = [cxLoaderPath("Media")]),
            cxMkSource(pages = ["*"])]);
    ai:Document[] docs = check cxLoadDocs(loader);
    CxFileSpec[] expectedFiles = [
        ...cxFilterByExtension(cxSpecsUnder("", true), ["pdf"]),
        ...cxSpecsUnder("Media", false)
    ];
    cxAssertFilesAndPages(docs, expectedFiles, cxPages());
}

@test:Config {}
isolated function testCxComplexMultipleLibraryTargetsOneSource() returns error? {
    Source src = {
        siteId: CX_SITE,
        libraries: [
            {name: CX_LIBRARY, paths: [cxLoaderPath("Policies")], recursive: true},
            {name: CX_LIBRARY, paths: [cxLoaderPath("Media")]}
        ]
    };
    ai:Document[] docs = check cxLoadSource(src);
    cxAssertCorpus(docs, [...cxSpecsUnder("Policies", true), ...cxSpecsUnder("Media", false)]);
}

@test:Config {}
isolated function testCxComplexPerLibraryTargetFilters() returns error? {
    Source src = {
        siteId: CX_SITE,
        libraries: [
            {name: CX_LIBRARY, paths: [cxLoaderPath("Reports")], recursive: true, includeExtensions: ["pdf"]},
            {name: CX_LIBRARY, paths: [cxLoaderPath("Mixed")], includeExtensions: ["pptx", "png"]}
        ]
    };
    ai:Document[] docs = check cxLoadSource(src);
    CxFileSpec[] expected = [
        ...cxFilterByExtension(cxSpecsUnder("Reports", true), ["pdf"]),
        ...cxFilterByExtension(cxSpecsUnder("Mixed", false), ["pptx", "png"])
    ];
    cxAssertCorpus(docs, expected);
}

@test:Config {}
isolated function testCxComplexLibraryTargetDefaultsToEntireLibrary() returns error? {
    // An empty/default-shaped target resolves to the "Documents" library; here it
    // loads the whole corpus root recursively.
    Source src = {siteId: CX_SITE, libraries: [{paths: [cxLoaderPath("")], recursive: true}]};
    ai:Document[] docs = check cxLoadSource(src);
    cxAssertCorpus(docs, cxSpecsUnder("", true));
}

// ==============================================================================
// INIT & CONNECTION-CONFIG: auth happy paths, HTTP forwarding, error rings
// ==============================================================================

@test:Config {}
isolated function testCxInitExplicitLibraryByName() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Reports")], driveNames = [CX_LIBRARY]));
    cxAssertCorpus(docs, cxSpecsUnder("Reports", false));
}

@test:Config {}
isolated function testCxInitForwardsAllHttpOptionsAndLoads() returns error? {
    ConnectionConfig config = {
        auth: {token: "cx-token"},
        serviceUrl: CX_SERVICE_URL,
        httpVersion: http:HTTP_2_0,
        http1Settings: {keepAlive: http:KEEPALIVE_AUTO, chunking: http:CHUNKING_AUTO},
        http2Settings: {},
        timeout: 120,
        forwarded: "enable",
        poolConfig: {},
        cache: {},
        compression: http:COMPRESSION_AUTO,
        circuitBreaker: {
            rollingWindow: {timeWindow: 60, bucketSize: 10, requestVolumeThreshold: 0},
            failureThreshold: 0.5,
            resetTime: 10,
            statusCodes: [500, 502, 503]
        },
        retryConfig: {count: 2, interval: 1},
        responseLimits: {},
        validation: true,
        laxDataBinding: true
    };
    TextDataLoader loader =
            check cxNewLoaderWith(config, [cxMkSource(paths = [cxLoaderPath("Reports")], recursive = true)]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, cxSpecsUnder("Reports", true));
}

@test:Config {}
isolated function testCxInitHttp2ExplicitSettingsLoads() returns error? {
    ConnectionConfig config = {
        auth: {token: "cx-token"},
        serviceUrl: CX_SERVICE_URL,
        httpVersion: http:HTTP_2_0,
        http2Settings: {http2PriorKnowledge: false},
        timeout: 75
    };
    TextDataLoader loader = check cxNewLoaderWith(config, [cxMkSource(paths = [cxLoaderPath("Media")])]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, cxSpecsUnder("Media", false));
}

@test:Config {}
isolated function testCxInitBadTokenEndpointFails() {
    // Each Graph client carries the configured `auth`, so an OAuth2 client fetches
    // the token eagerly when constructed; a failing token endpoint therefore
    // surfaces as a graceful initialization error (the `trap` in `init`).
    oauth2:ClientCredentialsGrantConfig auth = {tokenUrl: CX_BAD_TOKEN_URL, clientId: "id", clientSecret: "secret"};
    TextDataLoader|ai:Error loader =
            cxNewLoaderWith({auth, serviceUrl: CX_SERVICE_URL}, [cxMkSource(paths = [cxLoaderPath("root-note.txt")])]);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("Failed to initialize"), loader.message());
    } else {
        test:assertFail("A failing token endpoint must fail initialization");
    }
}

@test:Config {}
isolated function testCxInitInvalidSiteFailsResolution() returns error? {
    ai:Document[]|ai:Error docs =
            cxLoadSource(cxMkSource(paths = [cxLoaderPath("root-note.txt")], siteId = "no-such-site-404"));
    test:assertTrue(docs is ai:Error, "An invalid site must fail the load");
}

@test:Config {}
isolated function testCxInitNonexistentLibraryFails() returns error? {
    ai:Document[]|ai:Error docs =
            cxLoadSource(cxMkSource(paths = [cxLoaderPath("root-note.txt")], driveNames = ["NoSuchLibrary999"]));
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("was not found"), docs.message());
    } else {
        test:assertFail("A nonexistent library must fail");
    }
}

@test:Config {}
isolated function testCxInitMissingPathSingleLibraryFails() returns error? {
    ai:Document[]|ai:Error docs = cxLoadSource(cxMkSource(paths = [cxLoaderPath("does-not-exist-12345.pdf")]));
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to load path"), docs.message());
    } else {
        test:assertFail("A missing path in a single library must fail");
    }
}

@test:Config {}
isolated function testCxInitMissingPageFails() returns error? {
    ai:Document[]|ai:Error docs = cxLoadSource(cxMkSource(pages = ["NoSuchPage_zzz999"]));
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("was not found"), docs.message());
    } else {
        test:assertFail("A missing page must fail");
    }
}

// ==============================================================================
// REAL-WORLD: bulk pagination, second library, wildcard union, awkward names,
// cross-site aggregation, multi-web-part pages, metadata
// ==============================================================================

// ---- bulk pagination (~250 files force @odata.nextLink) ----------------------

@test:Config {}
isolated function testCxRWBulkFolderPaginates() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxRootPath(CX_BULK_ROOT, "")]));
    test:assertEquals(docs.length(), CX_BULK_COUNT, "Every bulk file should load across all listing pages");
    test:assertEquals(countByType(docs, CX_TEXT), CX_BULK_COUNT);
}

@test:Config {}
isolated function testCxRWBulkRecursiveMatchesFlat() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxRootPath(CX_BULK_ROOT, "")], recursive = true));
    test:assertEquals(docs.length(), CX_BULK_COUNT);
}

@test:Config {}
isolated function testCxRWBulkExtensionFilterKeepsAll() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxRootPath(CX_BULK_ROOT, "")], includeExtensions = ["txt"]));
    test:assertEquals(docs.length(), CX_BULK_COUNT, "All bulk files are .txt");
}

@test:Config {}
isolated function testCxRWBulkExtensionFilterDropsAll() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxRootPath(CX_BULK_ROOT, "")], includeExtensions = ["pdf"]));
    test:assertEquals(docs.length(), 0, "No bulk file is a .pdf");
}

@test:Config {}
isolated function testCxRWBulkExplicitSingleFile() {
    ai:Document[]|ai:Document|ai:Error result = cxLoadRaw(cxMkSource(paths = [cxRootPath(CX_BULK_ROOT, "file-100.txt")]));
    test:assertFalse(result is ai:Error, "Did not expect an error");
    test:assertFalse(result is ai:Document[], "A single file must return one document");
    if result is ai:TextDocument {
        test:assertEquals(result.metadata?.fileName, "file-100.txt");
        test:assertEquals(result.content, "bulk file 100");
    } else {
        test:assertFail("Expected a TextDocument for file-100.txt");
    }
}

// ---- second document library (Specs) -----------------------------------------

@test:Config {}
isolated function testCxRWNamedSecondLibraryFullRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, driveNames = [CX_SPECS_LIBRARY]));
    cxAssertCorpus(docs, cxSpecsUnderIn(cxSpecsCorpus(), "", true));
}

@test:Config {}
isolated function testCxRWSecondLibrarySubfolder() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("Drafts")], driveNames = [CX_SPECS_LIBRARY]));
    cxAssertCorpus(docs, cxSpecsUnderIn(cxSpecsCorpus(), "Drafts", false));
}

@test:Config {}
isolated function testCxRWSecondLibrarySingleFile() {
    ai:Document[]|ai:Document|ai:Error result =
            cxLoadRaw(cxMkSource(paths = [cxLoaderPath("api-design.pdf")], driveNames = [CX_SPECS_LIBRARY]));
    test:assertFalse(result is ai:Document[], "A single file must return one document");
    if result is ai:TextDocument {
        test:assertEquals(result.metadata?.fileName, "api-design.pdf");
        test:assertTrue(result.content.includes(PDF_TEXT), result.content);
    } else {
        test:assertFail("Expected a TextDocument for api-design.pdf in the Specs library");
    }
}

@test:Config {}
isolated function testCxRWSecondLibraryPdfFilter() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, includeExtensions = ["pdf"],
                    driveNames = [CX_SPECS_LIBRARY]));
    cxAssertCorpus(docs, cxFilterByExtension(cxSpecsUnderIn(cxSpecsCorpus(), "", true), ["pdf"]));
}

// ---- multi-library wildcard returning a true union ---------------------------

@test:Config {}
isolated function testCxRWWildcardSharedUnion() returns error? {
    // `Shared/` exists in BOTH libraries; the wildcard returns both files and
    // tolerates every other library that lacks the path.
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxLoaderPath("Shared")], driveNames = ["*"]));
    cxAssertCorpus(docs, [cxSpecOf("Shared/doc-shared.txt"), cxSpecOfIn(cxSpecsCorpus(), "Shared/spec-shared.txt")]);
}

@test:Config {}
isolated function testCxRWWildcardWholeRootBothLibraries() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, driveNames = ["*"]));
    cxAssertCorpus(docs, [...cxSpecsUnder("", true), ...cxSpecsUnderIn(cxSpecsCorpus(), "", true)]);
}

// ---- multiple LibraryTargets per source, across libraries --------------------

@test:Config {}
isolated function testCxRWPerTargetAcrossTwoLibraries() returns error? {
    Source src = {
        siteId: CX_SITE,
        libraries: [
            {name: CX_LIBRARY, paths: [cxLoaderPath("Policies")], recursive: true},
            {name: CX_SPECS_LIBRARY, paths: [cxLoaderPath("Drafts")], recursive: true}
        ]
    };
    ai:Document[] docs = check cxLoadSource(src);
    cxAssertCorpus(docs, [...cxSpecsUnder("Policies", true), ...cxSpecsUnderIn(cxSpecsCorpus(), "Drafts", true)]);
}

@test:Config {}
isolated function testCxRWPerTargetDifferentFiltersAcrossLibraries() returns error? {
    Source src = {
        siteId: CX_SITE,
        libraries: [
            {name: CX_LIBRARY, paths: [cxLoaderPath("")], recursive: true, includeExtensions: ["pdf"]},
            {name: CX_SPECS_LIBRARY, paths: [cxLoaderPath("")], recursive: true, includeExtensions: ["pdf"]}
        ]
    };
    ai:Document[] docs = check cxLoadSource(src);
    CxFileSpec[] expected = [
        ...cxFilterByExtension(cxSpecsUnder("", true), ["pdf"]),
        ...cxFilterByExtension(cxSpecsUnderIn(cxSpecsCorpus(), "", true), ["pdf"])
    ];
    cxAssertCorpus(docs, expected);
}

@test:Config {}
isolated function testCxRWThreeTargetsMixedLibraries() returns error? {
    Source src = {
        siteId: CX_SITE,
        libraries: [
            {name: CX_LIBRARY, paths: [cxLoaderPath("Media")]},
            {name: CX_SPECS_LIBRARY, paths: [cxLoaderPath("Drafts")], recursive: true},
            {name: CX_LIBRARY, paths: [cxLoaderPath("Reports")], recursive: true}
        ]
    };
    ai:Document[] docs = check cxLoadSource(src);
    CxFileSpec[] expected = [
        ...cxSpecsUnder("Media", false),
        ...cxSpecsUnderIn(cxSpecsCorpus(), "Drafts", true),
        ...cxSpecsUnder("Reports", true)
    ];
    cxAssertCorpus(docs, expected);
}

// ---- realistic / awkward names -----------------------------------------------

@test:Config {}
isolated function testCxRWSpecialNamesDirectChildren() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxRootPath(CX_SPECIAL_ROOT, "")]));
    cxAssertCorpus(docs, cxSpecsUnderIn(cxSpecialFiles(), "", false));
}

@test:Config {}
isolated function testCxRWSpecialNamesPresentByExactName() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxRootPath(CX_SPECIAL_ROOT, "")]));
    test:assertTrue(findByFileName(docs, "R&D Notes.txt") is ai:Document, "Ampersand name should round-trip");
    test:assertTrue(findByFileName(docs, "résumé.txt") is ai:Document, "Accented name should round-trip");
    test:assertTrue(findByFileName(docs, "日本語.md") is ai:Document, "Non-ASCII name should round-trip");
    // The plus/parenthesis name is a .pptx, whose extraction is temporarily disabled,
    // so it is skipped rather than loaded.
    test:assertTrue(findByFileName(docs, "a+b (final).pptx") is (),
            "Office documents are skipped, even with special names");
}

@test:Config {}
isolated function testCxRWSpacedSubfolderRecursive() returns error? {
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxRootPath(CX_SPECIAL_ROOT, "Project Plans")], recursive = true));
    test:assertEquals(docs.length(), 2);
    test:assertTrue(findByFileName(docs, "roadmap 2026.txt") is ai:Document);
    test:assertTrue(findByFileName(docs, "deep note.md") is ai:Document, "A file under a nested spaced folder");
}

@test:Config {}
isolated function testCxRWSpecialRecursiveFullTree() returns error? {
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxRootPath(CX_SPECIAL_ROOT, "")], recursive = true));
    // Every special file is text or a PDF (no images/audio); the one .pptx is skipped
    // as a temporarily unsupported Office document. All returnable files load as
    // TextDocuments.
    int expected = cxReturned(cxSpecialFiles()).length();
    test:assertEquals(docs.length(), expected, "Every special file across the tree should load");
    test:assertEquals(countByType(docs, CX_TEXT), expected, "Every loaded document is a TextDocument");
}

@test:Config {}
isolated function testCxRWDuplicateLeafNamesBothLoaded() returns error? {
    // The same leaf name `summary.csv` lives in two folders; BOTH must load with
    // their distinct contents.
    ai:Document[] docs = check cxLoadSource(cxMkSource(paths = [cxRootPath(CX_SPECIAL_ROOT, "")], recursive = true));
    test:assertEquals(cxCountByLeaf(docs, "summary.csv"), 2, "Both summary.csv files should load");
    boolean sawA = false;
    boolean sawB = false;
    foreach ai:Document doc in docs {
        if doc.metadata?.fileName == "summary.csv" && doc is ai:TextDocument {
            if doc.content == "team,score\nA,10" {
                sawA = true;
            }
            if doc.content == "team,score\nB,20" {
                sawB = true;
            }
        }
    }
    test:assertTrue(sawA && sawB, "Both distinct summary.csv contents should be present");
}

// ---- cross-site aggregation --------------------------------------------------

@test:Config {}
isolated function testCxRWSecondSiteAlone() returns error? {
    Source src = {
        siteId: CX_SITE2,
        libraries: [{name: CX_LIBRARY, paths: [cxLoaderPath("")], recursive: true}]
    };
    ai:Document[] docs = check cxLoadSource(src);
    cxAssertCorpus(docs, cxSpecsUnderIn(cxSecondSiteFiles(), "", true));
}

@test:Config {}
isolated function testCxRWCrossSiteAggregation() returns error? {
    TextDataLoader loader = check cxNewLoader([cxMkSource(paths = [cxLoaderPath("Policies")], recursive = true),
            {siteId: CX_SITE2, libraries: [{name: CX_LIBRARY, paths: [cxLoaderPath("")], recursive: true}]}]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertCorpus(docs, [...cxSpecsUnder("Policies", true), ...cxSpecsUnderIn(cxSecondSiteFiles(), "", true)]);
}

@test:Config {}
isolated function testCxRWCrossSitePagesAndFiles() returns error? {
    TextDataLoader loader = check cxNewLoader([cxMkSource(pages = ["*"]),
            {siteId: CX_SITE2, libraries: [{name: CX_LIBRARY, paths: [cxLoaderPath("")], recursive: true}]}]);
    ai:Document[] docs = check cxLoadDocs(loader);
    cxAssertFilesAndPages(docs, cxSpecsUnderIn(cxSecondSiteFiles(), "", true), cxPages());
}

// ---- pages: multi-web-part + metadata ----------------------------------------

@test:Config {}
isolated function testCxRWMultiWebPartPageExtraction() returns error? {
    CxPageSpec quarterly = cxPages()[5];
    ai:Document[] docs = check cxLoadSource(cxMkSource(pages = [quarterly.title]));
    test:assertEquals(docs.length(), 1);
    cxAssertPage(docs, quarterly);
}

@test:Config {}
isolated function testCxRWFileMetadataPopulated() {
    ai:Document[]|ai:Document|ai:Error result = cxLoadRaw(cxMkSource(paths = [cxLoaderPath("report.pdf")]));
    if result is ai:TextDocument {
        ai:Metadata? meta = result.metadata;
        if meta is ai:Metadata {
            test:assertEquals(meta.fileName, "report.pdf");
            test:assertTrue(meta.mimeType is string, "mimeType should be populated");
            decimal? size = meta.fileSize;
            test:assertTrue(size is decimal && size > 0d, "fileSize should be positive");
            test:assertTrue(meta.createdAt !is (), "createdAt should be populated");
            test:assertTrue(meta.modifiedAt !is (), "modifiedAt should be populated");
        } else {
            test:assertFail("Expected metadata on the loaded document");
        }
    } else {
        test:assertFail("Expected a TextDocument for report.pdf");
    }
}

@test:Config {}
isolated function testCxRWPageMetadataPopulated() returns error? {
    CxPageSpec home = cxPages()[0];
    ai:Document[] docs = check cxLoadSource(cxMkSource(pages = [home.title]));
    ai:Document? doc = findByFileName(docs, home.title);
    if doc is ai:TextDocument {
        ai:Metadata? meta = doc.metadata;
        if meta is ai:Metadata {
            test:assertEquals(meta.mimeType, "text/plain");
            test:assertTrue(meta["webUrl"] is string, "Page webUrl should be populated");
            test:assertTrue(meta.createdAt !is (), "Page createdAt should be populated");
        } else {
            test:assertFail("Expected metadata on the page document");
        }
    } else {
        test:assertFail("Expected a TextDocument for the home page");
    }
}

@test:Config {}
isolated function testCxRWMegaTwoLibrariesAndAllPages() returns error? {
    // The whole root recursively across every library, plus every page, in one
    // source: the broadest single-source ingest.
    ai:Document[] docs = check cxLoadSource(
            cxMkSource(paths = [cxLoaderPath("")], recursive = true, pages = ["*"], driveNames = ["*"]));
    cxAssertFilesAndPages(docs, [...cxSpecsUnder("", true), ...cxSpecsUnderIn(cxSpecsCorpus(), "", true)], cxPages());
}
