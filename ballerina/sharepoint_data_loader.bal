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
import ballerina/log;


# A data loader that retrieves documents from SharePoint document libraries as text.
@display {
    label: "Microsoft SharePoint Text Data Loader"
}
public isolated class TextDataLoader {
    *ai:DataLoader;

    private final http:Client graphClient;
    // Scheme+authority of `serviceUrl`, used to make `@odata.nextLink` relative.
    private final string serviceOrigin;
    private final readonly & Source[] sources;

    # Initializes the SharePoint data loader.
    #
    # + sharePointConnectionConfigs - The authentication and service configuration shared by
    #                                 all sources
    # + sources - One or more SharePoint sources to load documents from
    # + return - An `ai:Error` if the loader could not be initialized
    public isolated function init(@display {label: "SharePoint Connection Configurations"} ConnectionConfig sharePointConnectionConfigs, 
            @display {label: "Data Sources"} Source[] sources) returns ai:Error? {
        if sources.length() == 0 {
            return error ai:Error("At least one source must be provided to the SharePoint data loader");
        }

        do {
            self.sources = sources.cloneReadOnly();

            self.serviceOrigin = originOf(sharePointConnectionConfigs.serviceUrl);
            self.graphClient = check trap new (self.serviceOrigin, toHttpClientConfig(sharePointConnectionConfigs));
        } on fail error e {
            return error ai:Error("Failed to initialize the SharePoint data loader: " + e.message(), e);
        }
    }

    # Loads the configured SharePoint documents.
    #
    # + return - The loaded document when a single file is resolved, an array of
    #            documents otherwise, or an `ai:Error` on failure
    public isolated function load() returns ai:Document[]|ai:Document|ai:Error {
        ai:Document[] documents = [];
        foreach Source src in self.sources {
            string siteId = normalizeSiteId(src.siteId);
            foreach Library target in src.libraries {
                if target.paths.length() == 0 {
                    continue;
                }
                string[] driveIds = check self.resolveDrives(siteId, target.name);
                // A `"*"` target applies the paths to every library, where a path
                // need not exist in all of them, so a missing path is tolerated.
                // A named library is a single drive, so there it stays a real error.
                boolean tolerateMissing = target.name == "*";
                foreach string driveId in driveIds {
                    foreach string rawPath in target.paths {
                        ai:Document[] loaded = check self.loadPath(driveId,
                                normalizePath(rawPath), target.recursive, target.includeExtensions, tolerateMissing);
                        documents.push(...loaded);
                    }
                }
            }
            string[]? pages = src.pages;
            if pages is string[] && pages.length() > 0 {
                documents.push(...check self.loadPages(siteId, pages));
            }
        }
        if documents.length() == 1 {
            return documents[0];
        }
        return documents;
    }

    // Resolves the drive ids for a target library, or every library when `"*"`.
    private isolated function resolveDrives(string siteId, string driveName)
            returns string[]|ai:Error {
        do {
            json firstPage = check self.graphClient->/v1\.0/sites/[siteId]/drives;
            json[] drives = [...valuesOf(firstPage), ...check self.remainingValues(nextLinkOf(firstPage))];
            if drives.length() == 0 {
                return error ai:Error(string `No document libraries were found for site '${siteId}'`);
            }
            string[] allIds = [];
            map<string> idByName = {};
            foreach json drive in drives {
                string? id = strField(drive, "id");
                if id is () {
                    continue;
                }
                allIds.push(id);
                string? name = strField(drive, "name");
                if name is string && !idByName.hasKey(name) {
                    idByName[name] = id;
                }
            }
            if driveName == "*" {
                return allIds;
            }
            string? matchedId = idByName[driveName];
            if matchedId is () {
                return error ai:Error(
                    string `Document library '${driveName}' was not found in site '${siteId}'`);
            }
            return [matchedId];
        } on fail error e {
            if e is ai:Error {
                return e;
            }
            return error ai:Error(
                string `Failed to resolve document libraries in site '${siteId}': ${e.message()}`, e);
        }
    }

    // Loads the requested site pages as `ai:TextDocument`s (`"*"` loads all).
    private isolated function loadPages(string siteId, string[] pages)
            returns ai:Document[]|ai:Error {
        do {
            boolean loadAll = pages.indexOf("*") !is ();
            json firstPage = check self.graphClient->get(string `/v1.0/sites/${siteId}/pages`);
            json[] sitePages = [...valuesOf(firstPage), ...check self.remainingValues(nextLinkOf(firstPage))];
            ai:Document[] documents = [];
            if loadAll {
                foreach json page in sitePages {
                    string? pageId = strField(page, "id");
                    if pageId is () {
                        continue;
                    }
                    documents.push(check self.fetchPageDocument(siteId, pageId,
                            strField(page, "title") ?: strField(page, "name") ?: pageId, strField(page, "webUrl"),
                            strField(page, "createdDateTime"), strField(page, "lastModifiedDateTime")));
                }
                return documents;
            }
            foreach string wanted in pages {
                boolean found = false;
                foreach json page in sitePages {
                    string? pageId = strField(page, "id");
                    if pageId is () {
                        continue;
                    }
                    if pageId == wanted || strField(page, "name") == wanted || strField(page, "title") == wanted {
                        documents.push(check self.fetchPageDocument(siteId, pageId,
                                strField(page, "title") ?: strField(page, "name") ?: pageId, strField(page, "webUrl"),
                                strField(page, "createdDateTime"), strField(page, "lastModifiedDateTime")));
                        found = true;
                        break;
                    }
                }
                if !found {
                    return error ai:Error(string `Page '${wanted}' was not found in site '${siteId}'`);
                }
            }
            return documents;
        } on fail error e {
            if e is ai:Error {
                return e;
            }
            return error ai:Error(string `Failed to load pages from site '${siteId}': ${e.message()}`, e);
        }
    }

    // Fetches a single site page, extracts its web-part text, and builds a document.
    private isolated function fetchPageDocument(string siteId, string pageId, string title, string? webUrl,
            string? createdDateTime, string? modifiedDateTime)
            returns ai:Document|ai:Error {
        do {
            // Fetch the page as a site page with its canvas inlined. Graph rejects the
            // bare `.../webParts` collection with 400 `invalidRequest`; the
            // `microsoft.graph.sitePage` cast with `$expand=canvasLayout` is the
            // supported way to read a page's content in a single request. `siteId` is
            // already normalized (the path form carries its own `:` and `/`), so it is
            // not percent-encoded here.
            json sitePage = check self.graphClient->get(string `/v1.0/sites/${siteId}` +
                    string `/pages/${encodeUri(pageId)}/microsoft.graph.sitePage?$expand=canvasLayout`);
            string[] textBlocks = [];
            if title.trim() != "" {
                textBlocks.push(title);
            }
            // `collectWebPartText` walks the canvas for every web part's `innerHtml`
            // and `searchablePlainTexts`, harvesting all page copy in one pass.
            json canvasLayout = sitePage is map<json> ? sitePage["canvasLayout"] : ();
            collectWebPartText(canvasLayout, textBlocks);
            // A web part's `innerHtml` and `searchablePlainTexts` frequently encode
            // the same copy, so drop duplicate blocks while preserving order.
            textBlocks = dedupeStrings(textBlocks);

            ai:Metadata metadata = {fileName: title, mimeType: "text/plain"};
            if webUrl is string {
                metadata["webUrl"] = webUrl;
            }
            time:Utc? createdAt = toUtc(createdDateTime);
            if createdAt is time:Utc {
                metadata.createdAt = createdAt;
            }
            time:Utc? modifiedAt = toUtc(modifiedDateTime);
            if modifiedAt is time:Utc {
                metadata.modifiedAt = modifiedAt;
            }
            ai:TextDocument document = {content: string:'join("\n\n", ...textBlocks), metadata};
            return document;
        } on fail error e {
            if e is ai:Error {
                return e;
            }
            return error ai:Error(
                string `Failed to load page '${title}' from site '${siteId}': ${e.message()}`, e);
        }
    }

    // Loads a single path, dispatching to folder loading when it names a folder.
    // When `tolerateMissing`, a 404 yields no documents instead of an error.
    private isolated function loadPath(string driveId, string path,
            boolean recursive, string[]? includeExtensions, boolean tolerateMissing)
            returns ai:Document[]|ai:Error {
        do {
            if path == "" {
                return check self.loadFolder(driveId, "", recursive, includeExtensions);
            }
            DriveItem|error item =
                self.graphClient->get(string `/v1.0/drives/${encodeUri(driveId)}/root:${encodeDrivePath(path)}`);
            if item is error {
                if tolerateMissing && isNotFoundError(item) {
                    return [];
                }
                return error ai:Error(
                    string `Failed to load path '${path}' from drive '${driveId}': ${item.message()}`, item);
            }
            if item?.folder !is () {
                return check self.loadFolder(driveId, path, recursive, includeExtensions);
            }
            // An explicitly listed file path is always loaded, regardless of the filter.
            // A deliberately named non-text file is an error, unlike folder contents.
            ai:TextDocument? document = check self.toDocument(driveId, item);
            if document is () {
                if isUnsupportedOfficeDocument(item?.name ?: "", item?.file?.mimeType) {
                    return error ai:Error(string `Unsupported file type for path '${path}': text ` +
                        string `extraction for Microsoft Office documents (.doc, .docx, .ppt, .pptx, ` +
                        string `.xls, .xlsx) is not supported`);
                }
                return error ai:Error(string `Unsupported (non-text) file type for path '${path}'`);
            }
            return [document];
        } on fail ai:Error e {
            return e;
        }
    }

    // Loads every file in a folder, descending into sub-folders when `recursive`.
    private isolated function loadFolder(string driveId, string folderPath,
            boolean recursive, string[]? includeExtensions)
            returns ai:Document[]|ai:Error {
        do {
            DriveItemCollectionResponse listing;
            if folderPath == "" {
                listing = check self.graphClient->get(
                        string `/v1.0/drives/${encodeUri(driveId)}/root/children`);
            } else {
                listing = check self.graphClient->get(
                        string `/v1.0/drives/${encodeUri(driveId)}/root:${encodeDrivePath(folderPath)}:/children`);
            }
            // The first page is typed; later `@odata.nextLink` pages arrive as
            // JSON and are bound back into `DriveItem`s.
            DriveItem[] children = listing?.value ?: [];
            json[] remaining = check self.remainingValues(nextLinkOf(listing.toJson()));
            foreach json entry in remaining {
                DriveItem|error child = entry.cloneWithType();
                if child is DriveItem {
                    children.push(child);
                    continue;
                }
                // An entry that fails to bind to `DriveItem` is logged, not dropped
                // silently, so the listing is not mistaken for complete.
                log:printWarn("Skipping a drive item that could not be bound from a paginated folder listing",
                        'error = child, driveId = driveId, folderPath = folderPath);
            }

            ai:Document[] documents = [];
            foreach DriveItem child in children {
                string childName = child?.name ?: "";
                string childPath = folderPath == "" ? "/" + childName : folderPath + "/" + childName;
                if child?.folder !is () {
                    if recursive {
                        documents.push(...check self.loadFolder(driveId, childPath, recursive,
                                includeExtensions));
                    }
                } else if matchesExtensionFilter(childName, includeExtensions) {
                    ai:TextDocument? document = check self.toDocument(driveId, child);
                    if document is ai:TextDocument {
                        documents.push(document);
                    } else if isUnsupportedOfficeDocument(childName, child?.file?.mimeType) {
                        log:printWarn("Skipping an unsupported SharePoint file: text extraction for " +
                                "Microsoft Office documents (.doc, .docx, .ppt, .pptx, .xls, .xlsx) is " +
                                "not supported", fileName = childName, driveId = driveId);
                    } else {
                        log:printWarn("Skipping a non-text SharePoint file",
                                fileName = childName, driveId = driveId);
                    }
                }
            }
            return documents;
        } on fail error e {
            if e is ai:Error {
                return e;
            }
            return error ai:Error(
                string `Failed to list folder '${folderPath}' in drive '${driveId}': ${e.message()}`, e);
        }
    }

    // Downloads a drive item's content and converts it into an `ai:TextDocument`,
    // returning `()` when the file cannot be represented as text (caller skips it).
    private isolated function toDocument(string driveId, DriveItem item)
            returns ai:TextDocument?|ai:Error {
        string? itemId = item?.id;
        if itemId is () {
            return error ai:Error("Encountered a drive item without an identifier");
        }
        http:Response|error response =
            self.graphClient->get(string `/v1.0/drives/${encodeUri(driveId)}/items/${encodeUri(itemId)}/content`);
        if response is error {
            return error ai:Error(
                string `Failed to download content of drive item '${item?.name ?: itemId}': ${response.message()}`,
                response);
        }
        // Unlike a typed `byte[]` binding, a `Response` return does not error on a
        // non-2xx status, so the status is checked explicitly here.
        if response.statusCode >= 400 {
            return error ai:Error(string `Failed to download content of drive item ` +
                string `'${item?.name ?: itemId}': status code ${response.statusCode}`);
        }
        // Read the raw bytes off the response rather than binding to `byte[]`: the
        // latter routes the body through content-type negotiation, so a file served
        // as `application/json` (e.g. a `.json` drive item) fails to coerce into bytes.
        byte[]|error content = response.getBinaryPayload();
        if content is error {
            return error ai:Error(
                string `Failed to read content of drive item '${item?.name ?: itemId}': ${content.message()}`,
                content);
        }
        return buildDocument(content, item?.name ?: itemId, item?.file?.mimeType, item?.size,
                item?.createdDateTime, item?.lastModifiedDateTime);
    }

    // Follows the `@odata.nextLink` chain and returns the concatenated `value`
    // arrays of every subsequent page.
    private isolated function remainingValues(string? firstNextLink)
            returns json[]|ai:Error {
        json[] all = [];
        string? next = firstNextLink;
        while next is string {
            json page = check self.getJson(next);
            all.push(...valuesOf(page));
            next = nextLinkOf(page);
        }
        return all;
    }

    // Authenticated GET against an absolute Graph URL (resolved to a relative path).
    // The `graphClient` carries the configured `auth`, so the HTTP layer attaches the token.
    private isolated function getJson(string url) returns json|ai:Error {
        string path = relativeUrl(self.serviceOrigin, url);
        json|error resp = self.graphClient->get(path);
        if resp is error {
            return error ai:Error(string `Failed to fetch a paginated result from '${url}': ${resp.message()}`, resp);
        }
        return resp;
    }
}
