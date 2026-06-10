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

// ---- helpers -----------------------------------------------------------------

isolated function newLoader(Source[] sources) returns TextDataLoader|ai:Error {
    ConnectionConfig config = {auth: {token: "test-token"}, serviceUrl: SERVICE_URL};
    return new (config, sources);
}

isolated function loadAll(TextDataLoader loader) returns ai:Document[]|ai:Error {
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    if result is ai:Error {
        return result;
    }
    if result is ai:Document[] {
        return result;
    }
    return [result];
}

isolated function countByType(ai:Document[] docs, string docType) returns int {
    int count = 0;
    foreach ai:Document doc in docs {
        if doc.'type == docType {
            count += 1;
        }
    }
    return count;
}

isolated function findByFileName(ai:Document[] docs, string fileName) returns ai:Document? {
    foreach ai:Document doc in docs {
        if doc.metadata?.fileName == fileName {
            return doc;
        }
    }
    return ();
}

// ---- init --------------------------------------------------------------------

@test:Config {}
isolated function testInitWithoutSourcesFails() {
    TextDataLoader|ai:Error loader = newLoader([]);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("At least one source"), loader.message());
    } else {
        test:assertFail("Expected an error when no sources are provided");
    }
}

@test:Config {}
isolated function testInitWithBearerToken() returns error? {
    TextDataLoader _ = check newLoader([{siteId: "site-1", libraries: [{paths: ["/leave.pdf"]}]}]);
}

@test:Config {}
isolated function testInitWithClientCredentials() returns error? {
    oauth2:ClientCredentialsGrantConfig auth = {tokenUrl: TOKEN_URL, clientId: "id", clientSecret: "secret"};
    TextDataLoader _ = check new ({auth, serviceUrl: SERVICE_URL}, [{siteId: "site-1", libraries: [{paths: ["/x"]}]}]);
}

@test:Config {}
isolated function testInitWithRefreshToken() returns error? {
    oauth2:RefreshTokenGrantConfig auth = {
        refreshUrl: TOKEN_URL,
        refreshToken: "rt",
        clientId: "id",
        clientSecret: "secret"
    };
    TextDataLoader _ = check new ({auth, serviceUrl: SERVICE_URL}, [{siteId: "site-1", libraries: [{paths: ["/x"]}]}]);
}

@test:Config {}
isolated function testInitWithInvalidServiceUrlFails() {
    ConnectionConfig config = {auth: {token: "t"}, serviceUrl: "not a valid url"};
    TextDataLoader|ai:Error loader = new (config, [{siteId: "site-1", libraries: [{paths: ["/x"]}]}]);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("Failed to initialize"), loader.message());
    } else {
        test:assertFail("Expected an error for an invalid service URL");
    }
}

@test:Config {}
isolated function testInitForwardsAllHttpOptions() returns error? {
    ConnectionConfig config = {
        auth: {token: "t"},
        serviceUrl: SERVICE_URL,
        httpVersion: http:HTTP_1_1,
        http1Settings: {keepAlive: http:KEEPALIVE_ALWAYS, chunking: http:CHUNKING_ALWAYS, proxy: {host: "localhost", port: 8080}},
        http2Settings: {},
        timeout: 30,
        forwarded: "enable",
        poolConfig: {},
        cache: {},
        compression: http:COMPRESSION_ALWAYS,
        circuitBreaker: {
            rollingWindow: {timeWindow: 60, bucketSize: 10, requestVolumeThreshold: 0},
            failureThreshold: 0.5,
            resetTime: 10,
            statusCodes: [500, 502, 503]
        },
        retryConfig: {count: 2, interval: 1},
        responseLimits: {},
        secureSocket: {enable: false},
        proxy: {host: "localhost", port: 8080},
        validation: true,
        laxDataBinding: true
    };
    // Only constructing the loader is needed to exercise the configuration
    // forwarding; the (non-functional) proxy must not be used by a request.
    TextDataLoader _ = check new (config, [{siteId: "site-1", libraries: [{paths: ["/leave.pdf"]}]}]);
}

// ---- loading files -----------------------------------------------------------

@test:Config {}
isolated function testLoadSingleFileReturnsSingleDocument() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/leave.pdf"]}]}]);
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    test:assertFalse(result is ai:Error, "Did not expect an error");
    test:assertFalse(result is ai:Document[], "Expected a single document, not an array");
    if result is ai:TextDocument {
        test:assertEquals(result.metadata?.fileName, "leave.pdf");
        test:assertEquals(result.metadata?.fileSize, <decimal>123);
        test:assertTrue(result.metadata?.createdAt !is ());
        test:assertTrue(result.content.includes(PDF_TEXT), result.content);
    } else {
        test:assertFail("A .pdf file is extracted to a TextDocument");
    }
}

@test:Config {}
isolated function testLoadFolderReturnsOnlyTextDocuments() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-all", libraries: [{paths: ["/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    // Of the root files, only a.txt, d.bin (json), e.md, and h.pdf are text or
    // text-extractable; the image, audio, and extensionless files are skipped,
    // and the sub-folder is not descended (non-recursive).
    test:assertEquals(docs.length(), 4, "Only the text/extractable files are returned");
    test:assertEquals(countByType(docs, "text"), 4, "Every returned document is a TextDocument");
}

@test:Config {}
isolated function testLoadFolderRecursive() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-all", libraries: [{paths: ["/"], recursive: true}]}]);
    ai:Document[] docs = check loadAll(loader);
    // 4 text/extractable root files + 2 in the sub-folder (x.txt, y.pdf).
    test:assertEquals(docs.length(), 6, "4 root text files + 2 in the sub-folder");
}

@test:Config {}
isolated function testNormalizePathAddsAndTrimsSlashes() returns error? {
    // "sub/" must be normalized to "/sub" (leading slash added, trailing removed).
    TextDataLoader loader = check newLoader([{siteId: "site-all", libraries: [{paths: ["sub/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 2);
}

@test:Config {}
isolated function testExtensionFilterAllowlist() returns error? {
    TextDataLoader loader = check newLoader(
        [{siteId: "site-filter", libraries: [{paths: ["/"], includeExtensions: ["pdf"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1, "Only the .pdf file should pass the filter");
    test:assertEquals(docs[0].metadata?.fileName, "a.pdf");
}

@test:Config {}
isolated function testExtensionFilterIsCaseInsensitiveAndDotTolerant() returns error? {
    TextDataLoader loader = check newLoader(
        [{siteId: "site-filter", libraries: [{paths: ["/"], includeExtensions: [".PDF"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
}

@test:Config {}
isolated function testExplicitFilePathBypassesFilter() returns error? {
    // The filter applies to folder contents, not to explicitly named files.
    TextDataLoader loader = check newLoader(
        [{siteId: "site-1", libraries: [{paths: ["/notes.txt"], includeExtensions: ["pdf"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
    test:assertTrue(docs[0] is ai:TextDocument);
}

@test:Config {}
isolated function testLoadEmptyFolderYieldsNoDocuments() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/EmptyFolder"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 0);
}

@test:Config {}
isolated function testLoadFolderWithoutValueYieldsNoDocuments() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-novaluefolder", libraries: [{paths: ["/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 0);
}

@test:Config {}
isolated function testLoadFailsForItemWithoutId() {
    TextDataLoader|ai:Error loader = newLoader([{siteId: "site-noid", libraries: [{paths: ["/"]}]}]);
    if loader is ai:Error {
        test:assertFail(loader.message());
    }
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("without an identifier"), docs.message());
    } else {
        test:assertFail("Expected an error for a drive item without an identifier");
    }
}

@test:Config {}
isolated function testLoadFailsWhenContentDownloadFails() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-errcontent", libraries: [{paths: ["/"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to download content"), docs.message());
    } else {
        test:assertFail("Expected a content-download failure error");
    }
}

@test:Config {}
isolated function testLoadFailsForInvalidTextContent() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-badtext", libraries: [{paths: ["/"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to decode text"), docs.message());
    } else {
        test:assertFail("Expected a text-decode failure error");
    }
}

@test:Config {}
isolated function testMissingPathSingleDriveFails() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/missing.pdf"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to load path"), docs.message());
    } else {
        test:assertFail("Expected a 'failed to load path' error");
    }
}

@test:Config {}
isolated function testNonNotFoundErrorFails() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/err.txt"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    test:assertTrue(docs is ai:Error);
}

// ---- multiple libraries ------------------------------------------------------

@test:Config {}
isolated function testMultiDriveWildcardTolerantOfMissingPath() returns error? {
    // "/Reports" exists in driveDocs (a folder) but not in driveSpecs (404).
    TextDataLoader loader = check newLoader([{siteId: "site-multi", libraries: [{name: "*", paths: ["/Reports"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1, "Only driveDocs contains /Reports");
    test:assertEquals(docs[0].metadata?.fileName, "report.pdf");
}

@test:Config {}
isolated function testResolveDriveByName() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-multi", libraries: [{name: "Specs", paths: ["/specfile.txt"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
    test:assertTrue(docs[0] is ai:TextDocument);
}

@test:Config {}
isolated function testResolveDriveNameNotFound() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{name: "DoesNotExist", paths: ["/x"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("was not found"), docs.message());
    } else {
        test:assertFail("Expected a 'not found' error");
    }
}

@test:Config {}
isolated function testResolveDrivesEmptyLibraries() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-empty", libraries: [{paths: ["/x"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("No document libraries"), docs.message());
    } else {
        test:assertFail("Expected a 'no document libraries' error");
    }
}

@test:Config {}
isolated function testResolveDrivesNoValue() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-novalue", libraries: [{paths: ["/x"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("No document libraries"), docs.message());
    } else {
        test:assertFail("Expected a 'no document libraries' error");
    }
}

@test:Config {}
isolated function testResolveDrivesHttpError() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-err", libraries: [{paths: ["/x"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to resolve document libraries"), docs.message());
    } else {
        test:assertFail("Expected a library-resolution error");
    }
}

// ---- loading pages -----------------------------------------------------------

@test:Config {}
isolated function testLoadAllPages() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages", pages: ["*"]}]);
    ai:Document[] docs = check loadAll(loader);
    // p1, p2, p3 are loaded; the page without an id is skipped.
    test:assertEquals(docs.length(), 3);

    ai:Document? home = findByFileName(docs, "Home");
    if home is ai:TextDocument {
        test:assertTrue(home.content.includes("Home"));
        test:assertTrue(home.content.includes("Hello"), home.content);
        test:assertTrue(home.content.includes("World"), home.content);
        test:assertTrue(home.content.includes("Searchable text"), home.content);
        test:assertTrue(home.content.includes("Deep"), home.content);
        test:assertFalse(home.content.includes("<h1>"), "HTML tags should be stripped");
        test:assertEquals(home.metadata?.mimeType, "text/plain");
        test:assertEquals(home.metadata?.fileName, "Home");
        test:assertTrue(home.metadata?.createdAt !is ());
        ai:Metadata? homeMeta = home.metadata;
        if homeMeta is ai:Metadata {
            test:assertEquals(homeMeta["webUrl"], "https://contoso/home");
        } else {
            test:assertFail("Expected metadata on the home page document");
        }
    } else {
        test:assertFail("Expected the 'Home' page to load as a TextDocument");
    }

    // p3 has an unparseable timestamp; the document is still produced.
    ai:Document? bad = findByFileName(docs, "Bad");
    if bad is ai:TextDocument {
        test:assertTrue(bad.metadata?.createdAt is (), "Unparseable timestamp should be dropped");
    } else {
        test:assertFail("Expected the 'Bad' page to load as a TextDocument");
    }
}

@test:Config {}
isolated function testLoadNamedPageByTitle() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages", pages: ["News"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
    test:assertEquals(docs[0].metadata?.fileName, "News");
}

@test:Config {}
isolated function testLoadNamedPageByNameAndId() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages", pages: ["home.aspx", "p3"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 2);
}

@test:Config {}
isolated function testLoadPageNotFound() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages", pages: ["Ghost"]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("was not found"), docs.message());
    } else {
        test:assertFail("Expected a 'not found' error");
    }
}

@test:Config {}
isolated function testLoadPagesListError() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pageserr", pages: ["*"]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to load pages"), docs.message());
    } else {
        test:assertFail("Expected a 'failed to load pages' error");
    }
}

@test:Config {}
isolated function testLoadWebPartsError() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pageswperr", pages: ["*"]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to load page"), docs.message());
    } else {
        test:assertFail("Expected a 'failed to load page' error");
    }
}

@test:Config {}
isolated function testLoadAllPagesNoValue() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages-novalue", pages: ["*"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 0);
}

@test:Config {}
isolated function testLoadNamedPageNoValueFails() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages-novalue", pages: ["Home"]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    test:assertTrue(docs is ai:Error);
}

@test:Config {}
isolated function testLoadFilesAndPagesTogether() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pages", libraries: [{paths: ["/leave.pdf"]}], pages: ["News"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 2);
    test:assertTrue(findByFileName(docs, "leave.pdf") is ai:Document);
    test:assertTrue(findByFileName(docs, "News") is ai:Document);
}

// ---- pagination (@odata.nextLink) --------------------------------------------

@test:Config {}
isolated function testPagedDriveListing() returns error? {
    // The drive listing spans two pages; the requested library is on the first.
    TextDataLoader loader = check newLoader([{siteId: "site-paged", libraries: [{paths: ["/leave.pdf"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
}

@test:Config {}
isolated function testPagedDriveListingFollowError() returns error? {
    // The second drive page fails to load, which surfaces as a resolution error.
    TextDataLoader loader = check newLoader([{siteId: "site-pagederr", libraries: [{paths: ["/x"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("paginated result"), docs.message());
    } else {
        test:assertFail("Expected a pagination error");
    }
}

@test:Config {}
isolated function testDriveEntryWithoutIdIsSkipped() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-noiddrive", libraries: [{paths: ["/notes.txt"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
}

@test:Config {}
isolated function testPagedFolderListing() returns error? {
    // The folder listing spans two pages (1 file + 2 files).
    TextDataLoader loader = check newLoader([{siteId: "site-folderpaged", libraries: [{paths: ["/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 3);
}

@test:Config {}
isolated function testFolderListingHttpError() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-folderlisterr", libraries: [{paths: ["/"]}]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("Failed to list folder"), docs.message());
    } else {
        test:assertFail("Expected a 'failed to list folder' error");
    }
}

@test:Config {}
isolated function testPagedPagesListing() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-pagespaged", pages: ["*"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 2);
}

@test:Config {}
isolated function testPagesListingPaginationError() returns error? {
    // The pages listing spans two pages and the follow-up page fails to load,
    // which surfaces as a pagination error.
    TextDataLoader loader = check newLoader([{siteId: "site-wperr", pages: ["*"]}]);
    ai:Document[]|ai:Error docs = loadAll(loader);
    if docs is ai:Error {
        test:assertTrue(docs.message().includes("paginated result"), docs.message());
    } else {
        test:assertFail("Expected a pagination error");
    }
}

@test:Config {}
isolated function testInitWithPathInServiceUrl() returns error? {
    // A service URL with a path exercises the origin extraction (scheme+authority).
    ConnectionConfig config = {auth: {token: "t"}, serviceUrl: "http://localhost:9091/v1.0"};
    TextDataLoader _ = check new (config, [{siteId: "site-1", libraries: [{paths: ["/x"]}]}]);
}

// ---- authentication ----------------------------------------------------------

@test:Config {}
isolated function testOAuth2ClientCredentialsTokenIsUsed() returns error? {
    oauth2:ClientCredentialsGrantConfig auth = {tokenUrl: TOKEN_URL, clientId: "id", clientSecret: "secret"};
    TextDataLoader loader = check new ({auth, serviceUrl: SERVICE_URL}, [
        {siteId: "site-1", libraries: [{paths: ["/leave.pdf"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
}

@test:Config {}
isolated function testOAuth2TokenFailureSurfacesError() {
    // Each Graph client carries the configured `auth`, so an OAuth2 client fetches
    // the token eagerly when constructed; a failing token endpoint therefore
    // surfaces as a graceful initialization error (the `trap` in `init`).
    oauth2:ClientCredentialsGrantConfig auth = {tokenUrl: BAD_TOKEN_URL, clientId: "id", clientSecret: "secret"};
    TextDataLoader|ai:Error loader = new ({auth, serviceUrl: SERVICE_URL}, [
        {siteId: "site-1", libraries: [{paths: ["/leave.pdf"]}]}]);
    if loader is ai:Error {
        test:assertTrue(loader.message().includes("Failed to initialize"), loader.message());
    } else {
        test:assertFail("Expected initialization to fail for a failing token endpoint");
    }
}

// ---- complex real-world scenarios --------------------------------------------

// The `site-corpus` library models a realistic, deep, partly-paginated tree:
//   /readme.md, /logo.png
//   /Policies/{leave.pdf, code.txt, Archive/{old.pdf, notes.txt}}
//   /Reports/{q1.pdf, q2.pdf, 2023/annual.pdf}
// and the site additionally has two modern pages (home.aspx, about.aspx).

@test:Config {}
isolated function testRealWorldDeepRecursiveTree() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/"], recursive: true}]}]);
    ai:Document[] docs = check loadAll(loader);
    // The image (logo.png) is skipped; the remaining 8 text/PDF files all load.
    test:assertEquals(docs.length(), 8, "Every text/extractable file across the tree loads; the image is skipped");
    test:assertEquals(countByType(docs, "text"), 8, "Every returned document is a TextDocument");
    // A deeply nested PDF is reached, downloaded, and its text extracted.
    ai:Document? annual = findByFileName(docs, "annual.pdf");
    if annual is ai:TextDocument {
        test:assertTrue(annual.content.includes(PDF_TEXT), annual.content);
    } else {
        test:assertFail("Expected 'annual.pdf' to load as a TextDocument");
    }
    ai:Document? readme = findByFileName(docs, "readme.md");
    if readme is ai:TextDocument {
        test:assertEquals(readme.content, "content-of-c-readme.md");
    } else {
        test:assertFail("Expected 'readme.md' to load as a TextDocument");
    }
}

@test:Config {}
isolated function testRealWorldNonRecursiveLoadsOnlyTopLevel() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    // Of the two root files only readme.md is text; logo.png is skipped, and the
    // Policies and Reports folders are not descended (non-recursive).
    test:assertEquals(docs.length(), 1);
    test:assertTrue(findByFileName(docs, "readme.md") is ai:Document);
    test:assertTrue(findByFileName(docs, "logo.png") is (), "The image is skipped");
}

@test:Config {}
isolated function testRealWorldRecursivePdfFilterAcrossTree() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/"], recursive: true, includeExtensions: ["pdf"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 5, "Only PDFs anywhere in the tree should pass the filter");
    foreach ai:Document doc in docs {
        test:assertTrue(doc is ai:TextDocument, "Each PDF is extracted to a TextDocument");
    }
}

@test:Config {}
isolated function testRealWorldLoadSpecificSubfolderRecursive() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/Policies"], recursive: true}]}]);
    ai:Document[] docs = check loadAll(loader);
    // leave.pdf, code.txt, Archive/old.pdf, Archive/notes.txt
    test:assertEquals(docs.length(), 4);
    test:assertTrue(findByFileName(docs, "old.pdf") is ai:Document, "The nested Archive file should be reached");
}

@test:Config {}
isolated function testRealWorldLoadSpecificSubfolderNonRecursive() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/Policies"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    // Only the immediate files; the Archive sub-folder is skipped.
    test:assertEquals(docs.length(), 2);
    test:assertTrue(findByFileName(docs, "old.pdf") is (), "The Archive file must not be loaded");
}

@test:Config {}
isolated function testRealWorldPaginatedNestedReports() returns error? {
    // The Reports folder spans two pages and contains a nested year folder.
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/Reports"], recursive: true}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 3); // q1.pdf (page 1), q2.pdf (page 2), 2023/annual.pdf
}

@test:Config {}
isolated function testRealWorldMultiLibraryWildcardRecursive() returns error? {
    // Two libraries on one site, both read recursively via the "*" wildcard.
    TextDataLoader loader = check newLoader([{siteId: "site-multilib", libraries: [{name: "*", paths: ["/"], recursive: true}]}]);
    ai:Document[] docs = check loadAll(loader);
    // driveCorpus recursive yields 8 (logo.png skipped); driveSmall yields 2.
    test:assertEquals(docs.length(), 10, "8 from Documents + 2 from Archive");
}

@test:Config {}
isolated function testRealWorldFullSiteFilesAndPages() returns error? {
    // A single source ingesting the entire library tree plus every site page.
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/"], recursive: true}], pages: ["*"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 10, "8 files (the image is skipped) + 2 pages");
    ai:Document? home = findByFileName(docs, "CorpusHome");
    test:assertTrue(home is ai:TextDocument);
}

@test:Config {}
isolated function testRealWorldOAuthWithPaginatedTree() returns error? {
    // An OAuth2 client-credentials token combined with a paginated, nested load.
    oauth2:ClientCredentialsGrantConfig auth = {tokenUrl: TOKEN_URL, clientId: "id", clientSecret: "secret"};
    TextDataLoader loader = check new ({auth, serviceUrl: SERVICE_URL}, [
        {siteId: "site-corpus", libraries: [{paths: ["/"], recursive: true}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 8);
}

@test:Config {}
isolated function testRealWorldMultipleSourcesAggregated() returns error? {
    // Several sources (different sites, files + pages) aggregated by one loader.
    TextDataLoader loader = check newLoader([{siteId: "site-corpus", libraries: [{paths: ["/Policies"], recursive: true}]},
        {siteId: "site-pages", pages: ["News"]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 5, "4 policy files + 1 page");
    test:assertTrue(findByFileName(docs, "News") is ai:Document);
    test:assertTrue(findByFileName(docs, "leave.pdf") is ai:Document);
}

// ---- multiple library targets per source -------------------------------------

@test:Config {}
isolated function testSourceWithNoLibrariesOrPagesYieldsNothing() returns error? {
    // A source with the defaults (no libraries, no pages) contributes nothing.
    TextDataLoader loader = check newLoader([{siteId: "site-1"}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 0);
}

@test:Config {}
isolated function testLibraryTargetWithEmptyPathsIsSkipped() returns error? {
    // A library target whose `paths` is empty is skipped (no drive resolution).
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: []}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 0);
}

@test:Config {}
isolated function testLibraryTargetDefaultsToEntireLibrary() returns error? {
    // An empty `{}` target uses the defaults: the "Documents" library, paths
    // ["/"], non-recursive.
    TextDataLoader loader = check newLoader([{siteId: "site-all", libraries: [{}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 4, "The default target loads the whole 'Documents' root (text/extractable files only)");
}

@test:Config {}
isolated function testTwoNamedLibraryTargetsInOneSource() returns error? {
    // One source binding two different libraries, each to its own path.
    TextDataLoader loader = check newLoader([{
        siteId: "site-multi",
        libraries: [
            {name: "Documents", paths: ["/Reports"]},
            {name: "Specs", paths: ["/specfile.txt"]}
        ]
    }]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 2, "report.pdf from Documents + specfile.txt from Specs");
    test:assertTrue(findByFileName(docs, "report.pdf") is ai:Document);
    test:assertTrue(findByFileName(docs, "specfile.txt") is ai:Document);
}

@test:Config {}
isolated function testPerLibraryTargetRecursionAndFilter() returns error? {
    // Two targets on the same library with different traversal options: Policies
    // recursively (all 4 files) and Reports recursively but PDFs only (3 files).
    TextDataLoader loader = check newLoader([{
        siteId: "site-corpus",
        libraries: [
            {paths: ["/Policies"], recursive: true},
            {paths: ["/Reports"], recursive: true, includeExtensions: ["pdf"]}
        ]
    }]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 7, "4 policy files + 3 report PDFs");
    test:assertTrue(findByFileName(docs, "notes.txt") is ai:Document, "A recursive policy file");
    test:assertTrue(findByFileName(docs, "annual.pdf") is ai:Document, "A nested report PDF");
}

@test:Config {}
isolated function testMultipleLibraryTargetsSameLibraryDifferentPaths() returns error? {
    TextDataLoader loader = check newLoader([{
        siteId: "site-corpus",
        libraries: [
            {paths: ["/Policies"]},
            {paths: ["/Reports"]}
        ]
    }]);
    ai:Document[] docs = check loadAll(loader);
    // Policies non-recursive (leave.pdf, code.txt) + Reports non-recursive
    // (q1.pdf page 1, q2.pdf page 2); the nested folders are skipped.
    test:assertEquals(docs.length(), 4);
}

// ---- additional coverage -----------------------------------------------------

@test:Config {}
isolated function testPaginatedUnbindableDriveItemSkipped() returns error? {
    // The folder's second page contains entries that cannot bind to `DriveItem`;
    // they are skipped (and logged) while the valid first-page file still loads.
    TextDataLoader loader = check newLoader([{siteId: "site-folderbadpage", libraries: [{paths: ["/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1, "Only the bindable first-page file should load");
    test:assertEquals(docs[0].metadata?.fileName, "good.txt");
}

@test:Config {}
isolated function testForwardsAllHttpOptionsOnLoad() returns error? {
    // Unlike `testInitForwardsAllHttpOptions` (construction only), this performs a
    // real load so the full option set is forwarded to the `graphClient` via
    // `toHttpClientConfig`. No proxy is set, so the load can succeed.
    ConnectionConfig config = {
        auth: {token: "test-token"},
        serviceUrl: SERVICE_URL,
        httpVersion: http:HTTP_1_1,
        http1Settings: {keepAlive: http:KEEPALIVE_ALWAYS, chunking: http:CHUNKING_ALWAYS},
        http2Settings: {},
        timeout: 30,
        forwarded: "enable",
        poolConfig: {},
        cache: {},
        compression: http:COMPRESSION_ALWAYS,
        circuitBreaker: {
            rollingWindow: {timeWindow: 60, bucketSize: 10, requestVolumeThreshold: 0},
            failureThreshold: 0.5,
            resetTime: 10,
            statusCodes: [500, 502, 503]
        },
        retryConfig: {count: 2, interval: 1},
        responseLimits: {},
        secureSocket: {enable: false},
        validation: true,
        laxDataBinding: true
    };
    TextDataLoader loader = check new (config, [{siteId: "site-1", libraries: [{paths: ["/leave.pdf"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 1);
}

@test:Config {}
isolated function testToHttpClientConfigForwardsAuthProxyAndHttp1Proxy() {
    // The raw Graph client (used for both `@odata.nextLink` pagination and the
    // OneDrive drive APIs) must carry the configured `auth` plus the proxy and the
    // HTTP/1.x proxy nested under `http1Settings`, which a successful live load
    // cannot exercise; assert the mapping directly instead.
    ConnectionConfig config = {
        auth: {token: "t"},
        serviceUrl: SERVICE_URL,
        http1Settings: {proxy: {host: "h1proxy", port: 8081, userName: "u", password: "p"}},
        proxy: {host: "proxy.example", port: 8080}
    };
    http:ClientConfiguration hcc = toHttpClientConfig(config);
    test:assertTrue(hcc.auth is http:BearerTokenConfig);
    test:assertEquals(hcc.proxy?.host, "proxy.example");
    test:assertEquals(hcc.proxy?.port, 8080);
    test:assertEquals(hcc.http1Settings?.proxy?.host, "h1proxy");
}

// ---- file-type handling (image skipped / pdf + pptx extracted) ---------------

@test:Config {}
isolated function testLoadImageFileExplicitPathErrors() returns error? {
    // A deliberately named non-text file cannot be represented as text, so an
    // explicit image path is an error (folder contents are skipped instead).
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/photo.png"]}]}]);
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    if result is ai:Error {
        test:assertTrue(result.message().includes("Unsupported (non-text) file type"), result.message());
    } else {
        test:assertFail("An explicitly named image path should error");
    }
}

@test:Config {}
isolated function testLoadPdfFileReturnsTextDocument() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/report.pdf"]}]}]);
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    if result is ai:TextDocument {
        test:assertEquals(result.metadata?.fileName, "report.pdf");
        test:assertTrue(result.content.includes(PDF_TEXT), result.content);
    } else {
        test:assertFail("A .pdf file is extracted to a TextDocument");
    }
}

@test:Config {}
isolated function testLoadPptxFileErrorsAsUnsupportedOffice() returns error? {
    // Office text extraction is temporarily disabled, so an explicitly named .pptx
    // path is rejected as an unsupported file type.
    TextDataLoader loader = check newLoader([{siteId: "site-1", libraries: [{paths: ["/slides.pptx"]}]}]);
    ai:Document[]|ai:Document|ai:Error result = loader.load();
    if result is ai:Error {
        test:assertTrue(result.message().includes("Microsoft Office documents"), result.message());
    } else {
        test:assertFail("A .pptx file should error as an unsupported Office document");
    }
}

@test:Config {}
isolated function testLoadFolderWithImagePdfAndPptx() returns error? {
    // A folder holding an image, a PDF, a PPTX, and a text file: the image and the
    // PPTX (temporarily unsupported Office) are skipped, while the PDF is extracted to
    // text alongside the text file.
    TextDataLoader loader = check newLoader([{siteId: "site-filetypes", libraries: [{paths: ["/"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    test:assertEquals(docs.length(), 2, "The image and PPTX are skipped; PDF and text are returned");
    test:assertEquals(countByType(docs, "text"), 2, "Every returned document is a TextDocument");
    test:assertTrue(findByFileName(docs, "photo.png") is (), "The image is skipped");
    test:assertTrue(findByFileName(docs, "slides.pptx") is (), "The Office document is skipped");

    ai:Document? report = findByFileName(docs, "report.pdf");
    if report is ai:TextDocument {
        test:assertTrue(report.content.includes(PDF_TEXT), report.content);
    } else {
        test:assertFail("Expected 'report.pdf' to load as a TextDocument");
    }
}

@test:Config {}
isolated function testRecursivePptxAndImageFilterAcrossKindsFolder() returns error? {
    TextDataLoader loader = check newLoader([{siteId: "site-filetypes", libraries: [{paths: ["/"], includeExtensions: ["pptx", "png"]}]}]);
    ai:Document[] docs = check loadAll(loader);
    // Both pass the extension filter, but the PNG is skipped as non-text and the PPTX
    // is skipped as a temporarily unsupported Office document, so nothing is returned.
    test:assertEquals(docs.length(), 0, "Neither the PPTX nor the PNG is text-extractable");
    test:assertTrue(findByFileName(docs, "slides.pptx") is (), "The Office document is skipped");
    test:assertTrue(findByFileName(docs, "photo.png") is (), "The image is skipped despite passing the filter");
}

// ---- internal helper unit tests ----------------------------------------------

@test:Config {}
isolated function testOriginOfReturnsInputWhenNoScheme() {
    // A string without a scheme separator is returned unchanged.
    test:assertEquals(originOf("localhost-no-scheme"), "localhost-no-scheme");
}

@test:Config {}
isolated function testRelativeUrlReturnsInputWhenOriginMismatch() {
    // A URL that does not start with the origin is returned unchanged.
    test:assertEquals(relativeUrl("http://a.example", "http://b.example/path?x=1"),
            "http://b.example/path?x=1");
}

@test:Config {}
isolated function testIsNotFoundErrorFromMessageText() {
    // 404-ness reported only in the error message (not as a typed status).
    test:assertTrue(isNotFoundError(error("ItemNotFound: the item is gone")));
    test:assertTrue(isNotFoundError(error("Resource not found")));
    test:assertTrue(isNotFoundError(error("failed with status code '404'")));
    test:assertTrue(isNotFoundError(error("failed with status: 404")));
}

@test:Config {}
isolated function testIsNotFoundErrorFromCauseChain() {
    // The top error is opaque but its cause is a textual 404.
    error cause = error("the requested item was not found");
    error wrapped = error("request failed", cause);
    test:assertTrue(isNotFoundError(wrapped));
}

@test:Config {}
isolated function testIsNotFoundErrorFalseForOtherErrors() {
    test:assertFalse(isNotFoundError(error("internal server error")));
}
