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

// A SECOND, richer mock of the Microsoft Graph `sites`/`pages` APIs, the OneDrive
// drive-items API, and an OAuth2 token endpoint, listening on its own port. Unlike
// the stateless `mock_service.bal`, this service is fully DATA-DRIVEN from the
// corpus declared in `complex_tests.bal`: it serves a realistic multi-library,
// multi-site SharePoint tree (deep folders, ~250-file paginated bulk folder,
// awkward names, a second document library, a second site and modern pages). It
// mirrors how the LIVE `sharepoint-tests` suite provisions its corpus, so the same
// scenarios can be asserted here without touching a real tenant.
//
// The corpus is the single source of truth: both the responses below and the
// expectations in `complex_tests.bal` derive from it, so they can never drift.

const int CX_PORT = 9092;
const string CX_SERVICE_URL = "http://localhost:9092";
const string CX_TOKEN_URL = "http://localhost:9092/oauth/token";
const string CX_BAD_TOKEN_URL = "http://localhost:9092/oauth/badtoken";

// The two sites the suite reads from.
const string CX_SITE = "cx-site";
const string CX_SITE2 = "cx-site2";

// The drive (document-library) identifiers served by the two sites.
const string CX_DOCS_DRIVE = "cxDocuments"; // "Documents" library of CX_SITE
const string CX_SPECS_DRIVE = "cxSpecs"; // "Specs" library of CX_SITE
const string CX_ASSETS_DRIVE = "cxSiteAssets"; // an empty system library of CX_SITE
const string CX_SITE2_DRIVE = "cxSite2Docs"; // "Documents" library of CX_SITE2

// The folder-listing page size. Chosen below the bulk-folder file count so that a
// bulk listing genuinely paginates over several `@odata.nextLink` pages, while the
// smaller corpus folders fit in a single page.
const int CX_PAGE_SIZE = 100;

listener http:Listener cxMockListener = new (CX_PORT);

// A single resolved file in a drive, paired with its absolute in-library path.
type CxEntry record {|
    string absPath;
    CxFileSpec spec;
|};

service / on cxMockListener {

    # Handles all Microsoft Graph / OneDrive GET requests for the rich corpus.
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

        // `@odata.nextLink` follow-up pages for a paginated folder listing.
        if p == "/cxpage" {
            return cxPageFollow(raw);
        }
        // /sites/{siteId}/drives
        if p.startsWith("/sites/") && p.endsWith("/drives") {
            return cxDrivesResponse(slice(p, "/sites/", "/drives"));
        }
        // /sites/{siteId}/pages/{pageId}/microsoft.graph.sitePage?$expand=canvasLayout
        if p.endsWith("/microsoft.graph.sitePage") {
            string pageId = decodeSeg(slice(p, "/pages/", "/microsoft.graph.sitePage"));
            return cxSitePageResponse(pageId);
        }
        // /sites/{siteId}/pages
        if p.startsWith("/sites/") && p.endsWith("/pages") {
            return cxPagesResponse(slice(p, "/sites/", "/pages"));
        }
        // /drives/{driveId}/items/{itemId}/content
        if p.startsWith("/drives/") && p.endsWith("/content") {
            return cxContentResponse(slice(p, "/drives/", "/items/"), slice(p, "/items/", "/content"));
        }
        // /drives/{driveId}/root/children
        if p.endsWith("/root/children") {
            return cxChildrenResponse(slice(p, "/drives/", "/root/children"), "", 0);
        }
        // /drives/{driveId}/root:{folderPath}:/children
        if p.includes("/root:") && p.endsWith(":/children") {
            string driveId = slice(p, "/drives/", "/root:");
            string folderPath = decodeSeg(slice(p, "/root:", ":/children"));
            return cxChildrenResponse(driveId, folderPath, 0);
        }
        // /drives/{driveId}/root:{itemPath}
        if p.includes("/root:") {
            string driveId = slice(p, "/drives/", "/root:");
            string itemPath = decodeSeg(after(p, "/root:"));
            return cxResolveItem(driveId, itemPath);
        }
        return jsonResp(404, {"error": {message: "unrecognized path: " + p}});
    }

    # Mock OAuth2 token endpoint used by the client-credentials and refresh-token
    # grants; always issues a token.
    resource function post oauth/token() returns json {
        return {access_token: "cx-oauth-token", token_type: "Bearer", expires_in: 3600};
    }

    # Mock OAuth2 token endpoint that always fails (for the auth error ring).
    resource isolated function post oauth/badtoken() returns http:Response|error {
        return jsonResp(400, {"error": "invalid_client"});
    }
}

// ---- drive (library) listing -------------------------------------------------

# Builds the `/sites/{id}/drives` response: the libraries of each known site.
isolated function cxDrivesResponse(string siteId) returns http:Response|error {
    if siteId == CX_SITE {
        return jsonResp(200, {
            value: [
                {id: CX_DOCS_DRIVE, name: CX_LIBRARY},
                {id: CX_SPECS_DRIVE, name: CX_SPECS_LIBRARY},
                {id: CX_ASSETS_DRIVE, name: "Site Assets"}
            ]
        });
    }
    if siteId == CX_SITE2 {
        return jsonResp(200, {value: [{id: CX_SITE2_DRIVE, name: CX_LIBRARY}]});
    }
    // An unknown site fails resolution (the invalid-site error ring).
    return jsonResp(404, {"error": {message: "site not found: " + siteId}});
}

// ---- drive contents (data-driven from the corpus) ----------------------------

# The flattened, ordered files of a drive, each with its absolute in-library path.
# The order is stable (corpus declaration order), so item ids and pagination are
# deterministic across calls.
#
# + driveId - The drive identifier
# + return - Every file in the drive
isolated function cxDriveEntries(string driveId) returns CxEntry[] {
    CxEntry[] entries = [];
    if driveId == CX_DOCS_DRIVE {
        foreach CxFileSpec spec in cxCorpus() {
            entries.push({absPath: cxAbs(CX_ROOT, spec.path), spec});
        }
        foreach CxFileSpec spec in cxBulkFiles() {
            entries.push({absPath: cxAbs(CX_BULK_ROOT, spec.path), spec});
        }
        foreach CxFileSpec spec in cxSpecialFiles() {
            entries.push({absPath: cxAbs(CX_SPECIAL_ROOT, spec.path), spec});
        }
        return entries;
    }
    if driveId == CX_SPECS_DRIVE {
        foreach CxFileSpec spec in cxSpecsCorpus() {
            entries.push({absPath: cxAbs(CX_ROOT, spec.path), spec});
        }
        return entries;
    }
    if driveId == CX_SITE2_DRIVE {
        foreach CxFileSpec spec in cxSecondSiteFiles() {
            entries.push({absPath: cxAbs(CX_ROOT, spec.path), spec});
        }
        return entries;
    }
    // CX_ASSETS_DRIVE (and any unknown drive) is empty.
    return entries;
}

# Folders that exist but contain no files in a drive (the empty-folder path).
#
# + driveId - The drive identifier
# + return - The absolute in-library paths of empty folders
isolated function cxEmptyFolders(string driveId) returns string[] =>
    driveId == CX_DOCS_DRIVE ? [cxAbs(CX_ROOT, "EmptyFolder")] : [];

# Builds the `getItemByPath` response: a file (exact match), a folder (an ancestor
# of some file, or a known empty folder), or a 404.
#
# + driveId - The drive identifier
# + itemPath - The requested absolute in-library path
# + return - The drive-item response
isolated function cxResolveItem(string driveId, string itemPath) returns http:Response|error {
    CxEntry[] entries = cxDriveEntries(driveId);
    int i = 0;
    while i < entries.length() {
        if entries[i].absPath == itemPath {
            return jsonResp(200, cxFileItem(i, entries[i].absPath, entries[i].spec));
        }
        i += 1;
    }
    string folderPrefix = itemPath + "/";
    foreach CxEntry entry in entries {
        if entry.absPath.startsWith(folderPrefix) {
            return jsonResp(200, cxFolderItem(cxLeaf(itemPath)));
        }
    }
    foreach string emptyFolder in cxEmptyFolders(driveId) {
        if emptyFolder == itemPath {
            return jsonResp(200, cxFolderItem(cxLeaf(itemPath)));
        }
    }
    return jsonResp(404, {"error": {message: "item not found: " + itemPath}});
}

# Builds one page of a folder's immediate children, emitting `@odata.nextLink` when
# more children remain.
#
# + driveId - The drive identifier
# + folderPath - The absolute in-library folder path (`""` for the drive root)
# + skip - The number of children already returned by earlier pages
# + return - The (possibly paginated) children listing response
isolated function cxChildrenResponse(string driveId, string folderPath, int skip) returns http:Response|error {
    json[] all = cxImmediateChildren(driveId, folderPath);
    int end = all.length() < skip + CX_PAGE_SIZE ? all.length() : skip + CX_PAGE_SIZE;
    json[] pageItems = all.slice(skip, end);
    map<json> body = {value: pageItems};
    if end < all.length() {
        body["@odata.nextLink"] = string `${CX_SERVICE_URL}/cxpage?d=${driveId}&f=${cxEnc(folderPath)}&s=${end}`;
    }
    return jsonResp(200, body);
}

# Serves a follow-up page requested via an emitted `@odata.nextLink`.
#
# + raw - The raw request path (with query string)
# + return - The next children page
isolated function cxPageFollow(string raw) returns http:Response|error {
    string driveId = cxQueryParam(raw, "d") ?: "";
    string folderPath = decodeSeg(cxQueryParam(raw, "f") ?: "");
    int skip = check int:fromString(cxQueryParam(raw, "s") ?: "0");
    return cxChildrenResponse(driveId, folderPath, skip);
}

# Computes the immediate children (files and sub-folders) of a folder, mirroring
# the Graph folder-listing semantics: distinct sub-folders appear once, and empty
# folders that are direct children are included.
#
# + driveId - The drive identifier
# + folderPath - The absolute in-library folder path (`""` for the drive root)
# + return - The child drive-items as JSON
isolated function cxImmediateChildren(string driveId, string folderPath) returns json[] {
    CxEntry[] entries = cxDriveEntries(driveId);
    string prefix = folderPath == "" ? "/" : folderPath + "/";
    json[] result = [];
    map<boolean> seenFolders = {};
    int i = 0;
    while i < entries.length() {
        CxEntry entry = entries[i];
        if entry.absPath.startsWith(prefix) {
            string remainder = entry.absPath.substring(prefix.length());
            int? slash = remainder.indexOf("/");
            if slash is () {
                result.push(cxFileItem(i, entry.absPath, entry.spec));
            } else {
                string folderName = remainder.substring(0, slash);
                if !seenFolders.hasKey(folderName) {
                    seenFolders[folderName] = true;
                    result.push(cxFolderItem(folderName));
                }
            }
        }
        i += 1;
    }
    foreach string emptyFolder in cxEmptyFolders(driveId) {
        if emptyFolder.startsWith(prefix) {
            string remainder = emptyFolder.substring(prefix.length());
            if remainder != "" && remainder.indexOf("/") is () && !seenFolders.hasKey(remainder) {
                seenFolders[remainder] = true;
                result.push(cxFolderItem(remainder));
            }
        }
    }
    return result;
}

# Builds the binary content response for a drive item, returning the exact corpus
# bytes so callers can assert content byte-for-byte.
#
# + driveId - The drive identifier
# + itemId - The item id (`f{index}` into `cxDriveEntries`)
# + return - The binary content response
isolated function cxContentResponse(string driveId, string itemId) returns http:Response|error {
    CxEntry[] entries = cxDriveEntries(driveId);
    if !itemId.startsWith("f") {
        return jsonResp(404, {"error": {message: "unknown item: " + itemId}});
    }
    int idx = check int:fromString(itemId.substring(1));
    if idx < 0 || idx >= entries.length() {
        return jsonResp(404, {"error": {message: "item out of range: " + itemId}});
    }
    http:Response res = new;
    res.statusCode = 200;
    res.setBinaryPayload(cxContentBytes(entries[idx].spec));
    return res;
}

// ---- pages -------------------------------------------------------------------

# Builds the `/sites/{id}/pages` listing for a site (only the first site has pages).
#
# + siteId - The site identifier
# + return - The pages listing response
isolated function cxPagesResponse(string siteId) returns http:Response|error {
    if siteId != CX_SITE {
        return jsonResp(200, {value: []});
    }
    CxPageSpec[] specs = cxPages();
    json[] values = [];
    int i = 0;
    while i < specs.length() {
        values.push({
            id: "cp" + i.toString(),
            name: specs[i].name,
            title: specs[i].title,
            webUrl: "https://contoso.sharepoint.com/" + specs[i].name,
            createdDateTime: VALID_TS,
            lastModifiedDateTime: VALID_TS2
        });
        i += 1;
    }
    return jsonResp(200, {value: values});
}

# Builds the expanded `microsoft.graph.sitePage` response for a page, embedding one
# text web part per HTML body inside the page's `canvasLayout` so that multi-web-part
# pages are modelled faithfully in a single request.
#
# + pageId - The page id (`cp{index}` into `cxPages`)
# + return - The site-page response with its canvas inlined
isolated function cxSitePageResponse(string pageId) returns http:Response|error {
    if !pageId.startsWith("cp") {
        return jsonResp(200, {canvasLayout: {}});
    }
    int|error idx = int:fromString(pageId.substring(2));
    CxPageSpec[] specs = cxPages();
    if idx is error || idx < 0 || idx >= specs.length() {
        return jsonResp(200, {canvasLayout: {}});
    }
    CxPageSpec page = specs[idx];
    json[] parts = [{id: "wp0", innerHtml: page.innerHtml}];
    int i = 0;
    while i < page.additionalHtml.length() {
        parts.push({id: "wp" + (i + 1).toString(), innerHtml: page.additionalHtml[i]});
        i += 1;
    }
    return jsonResp(200, {
        id: pageId,
        canvasLayout: {horizontalSections: [{columns: [{webparts: parts}]}]}
    });
}

// ---- drive-item JSON builders ------------------------------------------------

# Builds a file `DriveItem` JSON value. The MIME type is derived from the spec's
# document kind so the loader's classification always matches the expected type,
# and the size/timestamps populate the document metadata.
#
# + id - The file's index in `cxDriveEntries` (used as the item id)
# + absPath - The file's absolute in-library path
# + spec - The file spec
# + return - The drive-item JSON
isolated function cxFileItem(int id, string absPath, CxFileSpec spec) returns json => {
    id: "f" + id.toString(),
    name: cxLeaf(absPath),
    file: {mimeType: cxMime(spec)},
    size: cxContentBytes(spec).length(),
    createdDateTime: VALID_TS,
    lastModifiedDateTime: VALID_TS2
};

# Builds a folder `DriveItem` JSON value.
#
# + name - The folder name
# + return - the drive-item JSON
isolated function cxFolderItem(string name) returns json => {id: "folder-" + name, name, folder: {childCount: 1}};

# Returns a representative MIME type for a spec's document kind, consistent with
# the loader's MIME/extension classification.
#
# + spec - The file spec
# + return - The MIME type
isolated function cxMime(CxFileSpec spec) returns string {
    if spec.docType == CX_TEXT {
        return "text/plain";
    }
    if spec.docType == CX_IMAGE {
        return "image/png";
    }
    if spec.docType == CX_AUDIO {
        return "audio/mpeg";
    }
    return "application/octet-stream";
}

// ---- small helpers -----------------------------------------------------------

# Joins a library-root folder and a relative path into an absolute in-library path.
#
# + root - The library-root folder (e.g. `SPLoaderTests`)
# + rel - The path relative to `root`
# + return - The absolute in-library path (e.g. `/SPLoaderTests/Policies/leave.pdf`)
isolated function cxAbs(string root, string rel) returns string => string `/${root}/${rel}`;

# Returns the last `/`-separated segment of a path.
#
# + path - The path
# + return - The leaf segment
isolated function cxLeaf(string path) returns string {
    int? idx = path.lastIndexOf("/");
    return idx is int ? path.substring(idx + 1) : path;
}

# URL-encodes a folder path for embedding in an `@odata.nextLink` query parameter.
#
# + s - The value to encode
# + return - The encoded value (or the input unchanged on failure)
isolated function cxEnc(string s) returns string {
    string|error encoded = url:encode(s, "UTF8");
    return encoded is string ? encoded : s;
}

# Reads a query parameter from a raw request path.
#
# + raw - The raw request path (with query string)
# + key - The parameter name
# + return - The parameter value, or `()` if absent
isolated function cxQueryParam(string raw, string key) returns string? {
    int? qi = raw.indexOf("?");
    if qi is () {
        return ();
    }
    string query = raw.substring(qi + 1);
    foreach string pair in re `&`.split(query) {
        int? eq = pair.indexOf("=");
        if eq is int && pair.substring(0, eq) == key {
            return pair.substring(eq + 1);
        }
    }
    return ();
}
