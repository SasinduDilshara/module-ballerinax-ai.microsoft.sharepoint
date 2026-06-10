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

import ballerina/http;
import ballerina/url;

// A stateless mock of the Microsoft Graph `sites`/`pages` APIs, the OneDrive
// drive-items API, and an OAuth2 token endpoint. All responses are derived
// deterministically from identifiers embedded in the request path, so the tests
// select a behaviour purely by the `siteId`/`driveName`/`path` they configure on
// a `Source`.

const string MOCK_HOST = "localhost";
const int MOCK_PORT = 9091;
const string SERVICE_URL = "http://localhost:9091";
const string TOKEN_URL = "http://localhost:9091/oauth/token";
const string BAD_TOKEN_URL = "http://localhost:9091/oauth/badtoken";

listener http:Listener mockListener = new (MOCK_PORT);

# A valid ISO 8601 timestamp accepted by the OneDrive payload constraints.
const string VALID_TS = "2024-01-15T10:30:00Z";
const string VALID_TS2 = "2024-01-16T10:30:00Z";

service / on mockListener {

    # Handles all Microsoft Graph / OneDrive GET requests.
    resource isolated function get [string... segs](http:Request req) returns http:Response|error {
        string raw = req.rawPath;
        int? qi = raw.indexOf("?");
        string p = qi is int ? raw.substring(0, qi) : raw;

        // The drive APIs are addressed through the raw Graph client with the `/v1.0`
        // version prefix; strip it so the matching below stays version-agnostic (the
        // test `serviceUrl` is the bare origin, unlike the real `.../v1.0` root).
        if p.startsWith("/v1.0/") {
            p = p.substring(5);
        }

        // /sites/{siteId}/drives
        if p.startsWith("/sites/") && p.endsWith("/drives") {
            return drivesResponse(slice(p, "/sites/", "/drives"));
        }
        // /sites/{siteId}/pages/{pageId}/microsoft.graph.sitePage?$expand=canvasLayout
        if p.endsWith("/microsoft.graph.sitePage") {
            string pageId = decodeSeg(slice(p, "/pages/", "/microsoft.graph.sitePage"));
            return sitePageResponse(pageId);
        }
        // /sites/{siteId}/pages
        if p.startsWith("/sites/") && p.endsWith("/pages") {
            return pagesResponse(slice(p, "/sites/", "/pages"));
        }
        // /drives/{driveId}/items/{itemId}/content
        if p.startsWith("/drives/") && p.endsWith("/content") {
            return contentResponse(slice(p, "/items/", "/content"));
        }
        // /drives/{driveId}/root/children
        if p.endsWith("/root/children") {
            return childrenResponse(slice(p, "/drives/", "/root/children"), "");
        }
        // /drives/{driveId}/root:{folderPath}:/children
        if p.includes("/root:") && p.endsWith(":/children") {
            string driveId = slice(p, "/drives/", "/root:");
            string folderPath = decodeSeg(slice(p, "/root:", ":/children"));
            return childrenResponse(driveId, folderPath);
        }
        // /drives/{driveId}/root:{itemPath}
        if p.includes("/root:") {
            string driveId = slice(p, "/drives/", "/root:");
            string itemPath = decodeSeg(after(p, "/root:"));
            return itemResponse(driveId, itemPath);
        }
        // `@odata.nextLink` follow-up pages (requested as absolute URLs).
        if p == "/drives-page2" {
            return jsonResp(200, {value: [{id: "d2", name: "Extra"}]});
        }
        if p == "/folder-page2" {
            return jsonResp(200, {value: [fileItem("fp1", "p1.txt", ()), fileItem("fp2", "p2.pdf", ())]});
        }
        // A second folder page whose entries cannot be bound to `DriveItem`
        // (a bare string and an object with the wrong field shapes): both must be
        // skipped (and logged) while the valid first-page file is still loaded.
        if p == "/folder-badbind-page2" {
            return jsonResp(200, {value: ["not-an-item", {id: 123, name: ["x"]}]});
        }
        if p == "/pages-page2" {
            return jsonResp(200, {value: [{id: "pp2", name: "more.aspx", title: "More"}]});
        }
        if p == "/corpus-root-2" {
            return jsonResp(200, {value: [folderItem("Reports"), fileItem("c-logo", "logo.png", ())]});
        }
        if p == "/corpus-reports-2" {
            return jsonResp(200, {value: [fileItem("c-q2", "q2.pdf", ())]});
        }
        if p == "/err-page" {
            return jsonResp(500, {"error": "boom"});
        }
        return jsonResp(404, {"error": {message: "unrecognized path: " + p}});
    }

    # Mock OAuth2 token endpoint that issues a token.
    resource function post oauth/token() returns json {
        return {access_token: "mock-oauth-token", token_type: "Bearer", expires_in: 3600};
    }

    # Mock OAuth2 token endpoint that always fails.
    resource isolated function post oauth/badtoken() returns http:Response {
        return checkpanic jsonResp(400, {"error": "invalid_client"});
    }
}

// ---- response builders -------------------------------------------------------

# Builds the `/sites/{id}/drives` response for a given site id.
isolated function drivesResponse(string siteId) returns http:Response|error {
    match siteId {
        "site-multi" => {
            return jsonResp(200, {value: [{id: "driveDocs", name: "Documents"}, {id: "driveSpecs", name: "Specs"}]});
        }
        "site-empty" => {
            return jsonResp(200, {value: []});
        }
        "site-novalue" => {
            return jsonResp(200, {});
        }
        "site-err" => {
            return jsonResp(500, {"error": "boom"});
        }
        "site-all" => {
            return jsonResp(200, {value: [{id: "driveAll", name: "Documents"}]});
        }
        "site-filter" => {
            return jsonResp(200, {value: [{id: "driveFilter", name: "Documents"}]});
        }
        "site-noid" => {
            return jsonResp(200, {value: [{id: "driveNoId", name: "Documents"}]});
        }
        "site-errcontent" => {
            return jsonResp(200, {value: [{id: "driveErrContent", name: "Documents"}]});
        }
        "site-badtext" => {
            return jsonResp(200, {value: [{id: "driveBadText", name: "Documents"}]});
        }
        "site-novaluefolder" => {
            return jsonResp(200, {value: [{id: "driveNoValueFolder", name: "Documents"}]});
        }
        "site-folderpaged" => {
            return jsonResp(200, {value: [{id: "drivePaged", name: "Documents"}]});
        }
        "site-folderlisterr" => {
            return jsonResp(200, {value: [{id: "driveListErr", name: "Documents"}]});
        }
        "site-folderbadpage" => {
            return jsonResp(200, {value: [{id: "driveBadPage", name: "Documents"}]});
        }
        "site-paged" => {
            return jsonResp(200, {
                value: [{id: "d1paged", name: "Documents"}],
                "@odata.nextLink": "http://localhost:9091/drives-page2"
            });
        }
        "site-pagederr" => {
            return jsonResp(200, {
                value: [{id: "d1err", name: "Documents"}],
                "@odata.nextLink": "http://localhost:9091/err-page"
            });
        }
        "site-noiddrive" => {
            return jsonResp(200, {value: [{name: "Ghost"}, {id: "d1", name: "Documents"}]});
        }
        "site-corpus" => {
            return jsonResp(200, {value: [{id: "driveCorpus", name: "Documents"}]});
        }
        "site-filetypes" => {
            return jsonResp(200, {value: [{id: "driveKinds", name: "Documents"}]});
        }
        "site-multilib" => {
            return jsonResp(200, {value: [{id: "driveCorpus", name: "Documents"}, {id: "driveSmall", name: "Archive"}]});
        }
    }
    // Default: a single standard library.
    return jsonResp(200, {value: [{id: "driveDocs", name: "Documents"}]});
}

# Builds the `getItemByPath` response, deciding whether the path is a file,
# a folder, missing (404), or an error (500).
isolated function itemResponse(string driveId, string itemPath) returns http:Response|error {
    if itemPath == "/missing.pdf" {
        return jsonResp(404, {"error": {message: "item not found"}});
    }
    if itemPath == "/Reports" && driveId == "driveSpecs" {
        return jsonResp(404, {"error": {message: "not in this library"}});
    }
    if itemPath == "/err.txt" {
        return jsonResp(500, {"error": {message: "server error"}});
    }
    // Heuristic: a name with an extension is a file, otherwise it is a folder.
    string name = basename(itemPath);
    if name.includes(".") {
        return jsonResp(200, fileItem("id-" + name, name, ()));
    }
    return jsonResp(200, folderItem(name));
}

# Builds the folder/root children listing for a given drive and folder path.
isolated function childrenResponse(string driveId, string folderPath) returns http:Response|error {
    if driveId == "driveAll" && folderPath == "" {
        return jsonResp(200, {value: classifyVariants()});
    }
    if driveId == "driveAll" && folderPath == "/sub" {
        return jsonResp(200, {value: [fileItem("s1", "x.txt", ()), fileItem("s2", "y.pdf", ())]});
    }
    if driveId == "driveFilter" && folderPath == "" {
        return jsonResp(200, {value: [fileItem("fa", "a.pdf", ()), fileItem("fb", "b.txt", ()),
                fileItem("fc", "c.png", ())]});
    }
    if driveId == "driveNoId" && folderPath == "" {
        return jsonResp(200, {value: [{name: "noid.txt", file: {mimeType: "text/plain"}}]});
    }
    if driveId == "driveErrContent" && folderPath == "" {
        return jsonResp(200, {value: [fileItem("errcontent", "report.pdf", ())]});
    }
    if driveId == "driveBadText" && folderPath == "" {
        return jsonResp(200, {value: [fileItem("badtextid", "bad.txt", ())]});
    }
    if driveId == "driveNoValueFolder" && folderPath == "" {
        return jsonResp(200, {});
    }
    if driveId == "driveDocs" && folderPath == "/Reports" {
        return jsonResp(200, {value: [fileItem("rep1", "report.pdf", ())]});
    }
    if driveId == "driveDocs" && folderPath == "/EmptyFolder" {
        return jsonResp(200, {value: []});
    }
    if driveId == "drivePaged" && folderPath == "" {
        return jsonResp(200, {
            value: [fileItem("fpa", "root1.txt", ())],
            "@odata.nextLink": "http://localhost:9091/folder-page2"
        });
    }
    if driveId == "driveListErr" && folderPath == "" {
        return jsonResp(500, {"error": "listing failed"});
    }
    if driveId == "driveBadPage" && folderPath == "" {
        return jsonResp(200, {
            value: [fileItem("bp1", "good.txt", ())],
            "@odata.nextLink": "http://localhost:9091/folder-badbind-page2"
        });
    }
    // A realistic, deep, partly-paginated document library:
    //   /readme.md, /logo.png
    //   /Policies/{leave.pdf, code.txt, Archive/{old.pdf, notes.txt}}
    //   /Reports/{q1.pdf, q2.pdf, 2023/annual.pdf}
    if driveId == "driveCorpus" {
        match folderPath {
            "" => {
                return jsonResp(200, {
                    value: [folderItem("Policies"), fileItem("c-readme", "readme.md", ())],
                    "@odata.nextLink": "http://localhost:9091/corpus-root-2"
                });
            }
            "/Policies" => {
                return jsonResp(200, {value: [fileItem("c-leave", "leave.pdf", ()),
                        fileItem("c-code", "code.txt", ()), folderItem("Archive")]});
            }
            "/Policies/Archive" => {
                return jsonResp(200, {value: [fileItem("c-old", "old.pdf", ()), fileItem("c-notes", "notes.txt", ())]});
            }
            "/Reports" => {
                return jsonResp(200, {
                    value: [fileItem("c-q1", "q1.pdf", ()), folderItem("2023")],
                    "@odata.nextLink": "http://localhost:9091/corpus-reports-2"
                });
            }
            "/Reports/2023" => {
                return jsonResp(200, {value: [fileItem("c-annual", "annual.pdf", ())]});
            }
        }
        return jsonResp(200, {value: []});
    }
    if driveId == "driveSmall" && folderPath == "" {
        return jsonResp(200, {value: [fileItem("sm-a", "a.txt", ()), fileItem("sm-b", "b.pdf", ())]});
    }
    // A folder mixing an image, a PDF, a PPTX deck, and a text note, exercising
    // the image / binary (pdf, pptx) / text classifications side by side.
    if driveId == "driveKinds" && folderPath == "" {
        return jsonResp(200, {value: [
            fileItem("kind-img", "photo.png", "image/png"),
            fileItem("kind-pdf", "report.pdf", "application/pdf"),
            fileItem("kind-pptx", "slides.pptx",
                    "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
            fileItem("kind-txt", "notes.txt", "text/plain")
        ]});
    }
    return jsonResp(200, {value: []});
}

# Builds the binary content response for a drive item id.
isolated function contentResponse(string itemId) returns http:Response|error {
    if itemId.startsWith("errcontent") {
        return jsonResp(500, {"error": {message: "content unavailable"}});
    }
    http:Response res = new;
    res.statusCode = 200;
    if itemId.startsWith("badtextid") {
        // Invalid UTF-8 byte sequence to trigger a text-decoding failure.
        res.setBinaryPayload([0xFF, 0xFE, 0xFF]);
        return res;
    }
    // A PDF/DOCX/PPTX id serves real, Tika-extractable document bytes; any other
    // (text) file serves deterministic plain text derived from its id.
    byte[]? fixture = extractableFixture(getExtension(itemId));
    res.setBinaryPayload(fixture is byte[] ? fixture : ("content-of-" + itemId).toBytes());
    return res;
}

# Builds the `/sites/{id}/pages` listing response.
isolated function pagesResponse(string siteId) returns http:Response|error {
    match siteId {
        "site-pages" => {
            return jsonResp(200, {
                value: [
                    {
                        id: "p1",
                        name: "home.aspx",
                        title: "Home",
                        webUrl: "https://contoso/home",
                        createdDateTime: VALID_TS,
                        lastModifiedDateTime: VALID_TS2
                    },
                    {id: "p2", name: "news.aspx", title: "News"},
                    {id: "p3", name: "bad.aspx", title: "Bad", createdDateTime: "not-a-valid-timestamp"},
                    {name: "noid.aspx", title: "NoId"}
                ]
            });
        }
        "site-pages-novalue" => {
            return jsonResp(200, {});
        }
        "site-pageserr" => {
            return jsonResp(500, {"error": "boom"});
        }
        "site-pageswperr" => {
            return jsonResp(200, {value: [{id: "pwe", name: "we.aspx", title: "WE"}]});
        }
        "site-pagespaged" => {
            return jsonResp(200, {
                value: [{id: "pp1", name: "a.aspx", title: "PagedHome"}],
                "@odata.nextLink": "http://localhost:9091/pages-page2"
            });
        }
        "site-wperr" => {
            // The pages listing's follow-up page fails, surfacing a pagination error.
            return jsonResp(200, {
                value: [{id: "pwperr", name: "w.aspx", title: "WPErr"}],
                "@odata.nextLink": "http://localhost:9091/err-page"
            });
        }
        "site-corpus" => {
            return jsonResp(200, {value: [{id: "cp1", name: "home.aspx", title: "CorpusHome"},
                    {id: "cp2", name: "about.aspx", title: "About"}]});
        }
    }
    return jsonResp(200, {value: []});
}

# Builds the expanded `microsoft.graph.sitePage` response for a given page id,
# embedding the page's web parts inside its `canvasLayout`.
isolated function sitePageResponse(string pageId) returns http:Response|error {
    match pageId {
        "p1" => {
            return jsonResp(200, {
                id: pageId,
                canvasLayout: {
                    horizontalSections: [{columns: [{webparts: [
                        {id: "wp1", innerHtml: "<h1>Hello</h1> &amp; <b>World</b>&nbsp;&lt;tag&gt; &quot;q&quot; &#39;a&#39;"},
                        {
                            id: "wp2",
                            data: {serverProcessedContent: {searchablePlainTexts: [{key: "t", value: "Searchable text"}, {key: "e", value: "   "}]}}
                        },
                        {id: "wp3", nested: {deep: [{innerHtml: "<p>Deep</p>"}]}},
                        {id: "wp4", innerHtml: "<br>"}
                    ]}]}]
                }
            });
        }
        "pwe" => {
            return jsonResp(500, {"error": "boom"});
        }
    }
    return jsonResp(200, {id: pageId, canvasLayout: {}});
}

// ---- fixtures ----------------------------------------------------------------

# The set of files exercising every classification branch. Of these, only the
# four text/extractable files are returned; the image, audio, and extensionless
# files are skipped (logged) because they cannot be represented as text.
isolated function classifyVariants() returns json[] {
    return [
        fileItem("i1", "a.txt", "text/plain"), // mime text/*     -> TextDocument (decoded)
        fileItem("i2", "b.png", "image/png"), // mime image/*     -> skipped
        fileItem("i3", "c.mp3", "audio/mpeg"), // mime audio/*    -> skipped
        fileItem("i4", "d.bin", "application/json"), // mime allowlist -> TextDocument (decoded)
        fileItem("i5", "e.md", ()), // ext text                  -> TextDocument (decoded)
        fileItem("i6", "f.jpeg", ()), // ext image               -> skipped
        fileItem("i7", "g.wav", ()), // ext audio                -> skipped
        fileItem("i8", "h.pdf", ()), // ext pdf                  -> TextDocument (Tika)
        fileItemNoTimestamps("i9", "READMENOEXT"), // no extension -> skipped
        folderItem("sub")
    ];
}

# Builds a file `DriveItem` JSON value with timestamps.
isolated function fileItem(string id, string name, string? mimeType) returns json {
    json file = mimeType is string ? {mimeType} : {};
    return {
        id: itemIdWithExt(id, name),
        name,
        file,
        size: 123,
        createdDateTime: VALID_TS,
        lastModifiedDateTime: VALID_TS2
    };
}

# Appends the file's extension to its item id (unless already present), so that the
# stateless `contentResponse` can route to the matching real document fixture using
# only the id carried in the `/items/{id}/content` request path.
isolated function itemIdWithExt(string id, string name) returns string {
    int? dot = name.lastIndexOf(".");
    if dot is () {
        return id;
    }
    string ext = name.substring(dot);
    return id.endsWith(ext) ? id : id + ext;
}

# Builds a file `DriveItem` JSON value without timestamps (covers the absent
# timestamp branch of metadata building).
isolated function fileItemNoTimestamps(string id, string name) returns json {
    return {id, name, file: {}};
}

# Builds a folder `DriveItem` JSON value.
isolated function folderItem(string name) returns json {
    return {id: "folder-" + name, name, folder: {childCount: 1}};
}

// ---- helpers -----------------------------------------------------------------

# Builds an `http:Response` with the given status code and JSON payload.
isolated function jsonResp(int code, json payload) returns http:Response|error {
    http:Response res = new;
    res.statusCode = code;
    res.setJsonPayload(payload);
    return res;
}

# Returns the substring strictly between the first occurrence of `a` and the
# next occurrence of `b` after it.
isolated function slice(string s, string a, string b) returns string {
    int startIdx = (s.indexOf(a) ?: 0) + a.length();
    int endIdx = s.indexOf(b, startIdx) ?: s.length();
    return s.substring(startIdx, endIdx);
}

# Returns the substring after the first occurrence of `marker`.
isolated function after(string s, string marker) returns string {
    int idx = s.indexOf(marker) ?: 0;
    return s.substring(idx + marker.length());
}

# Returns the last `/`-separated segment of a path.
isolated function basename(string path) returns string {
    int? idx = path.lastIndexOf("/");
    return idx is int ? path.substring(idx + 1) : path;
}

# URL-decodes a path segment.
isolated function decodeSeg(string s) returns string {
    string|error decoded = url:decode(s, "UTF8");
    return decoded is string ? decoded : s;
}
