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
import ballerina/jballerina.java;
import ballerina/time;
import ballerina/url;

// Forwards the shared HTTP options — together with the configured `auth`, so the
// HTTP layer attaches the token itself — to the raw `http:Client` used for both
// `@odata.nextLink` pagination and the OneDrive drive API calls.
isolated function toHttpClientConfig(ConnectionConfig config) returns http:ClientConfiguration {
    http:ClientConfiguration httpConfig = {
        auth: config.auth,
        httpVersion: config.httpVersion,
        timeout: config.timeout,
        forwarded: config.forwarded,
        compression: config.compression,
        validation: config.validation,
        // The Graph `/items/{id}/content` endpoint replies with a 302 redirect to a
        // pre-authenticated download URL; without following it the body is empty and
        // every file downloads as 0 bytes.
        followRedirects: config.followRedirects,
        cookieConfig: config.cookieConfig,
        socketConfig: config.socketConfig,
        laxDataBinding: config.laxDataBinding
    };

    httpConfig.http1Settings = config.http1Settings;
    http:ClientHttp2Settings? http2Settings = config.http2Settings;
    if http2Settings is http:ClientHttp2Settings {
        httpConfig.http2Settings = http2Settings;
    }
    http:PoolConfiguration? poolConfig = config.poolConfig;
    if poolConfig is http:PoolConfiguration {
        httpConfig.poolConfig = poolConfig;
    }
    http:CacheConfig? cache = config.cache;
    if cache is http:CacheConfig {
        httpConfig.cache = cache;
    }
    http:CircuitBreakerConfig? circuitBreaker = config.circuitBreaker;
    if circuitBreaker is http:CircuitBreakerConfig {
        httpConfig.circuitBreaker = circuitBreaker;
    }
    http:RetryConfig? retryConfig = config.retryConfig;
    if retryConfig is http:RetryConfig {
        httpConfig.retryConfig = retryConfig;
    }
    http:ResponseLimitConfigs? responseLimits = config.responseLimits;
    if responseLimits is http:ResponseLimitConfigs {
        httpConfig.responseLimits = responseLimits;
    }
    http:ClientSecureSocket? secureSocket = config.secureSocket;
    if secureSocket is http:ClientSecureSocket {
        httpConfig.secureSocket = secureSocket;
    }
    http:ProxyConfig? proxy = config.proxy;
    if proxy is http:ProxyConfig {
        httpConfig.proxy = proxy;
    }
    return httpConfig;
}

// Percent-encodes a single path/identifier segment for a Graph drive URL, mirroring
// the encoding the OneDrive connector applied to drive ids, item ids, and paths.
isolated function encodeUri(string value) returns string {
    string|error encoded = url:encode(value, "UTF8");
    return encoded is string ? encoded : value;
}

// How a file's content is turned into text, derived from its MIME type / extension.
enum DocumentKind {
    // Inherently textual; decoded directly from its bytes.
    PLAIN_TEXT,
    // A PDF document whose text is extracted via Apache Tika.
    EXTRACTABLE,
    // A Microsoft Office document (.doc/.docx/.ppt/.pptx/.xls/.xlsx). This loader
    // extracts text from PDFs only and does not support Office formats (see the
    // OFFICE_* lists / classify), so these are skipped in folder loads and rejected
    // with a clear, format-specific error when named explicitly.
    UNSUPPORTED_OFFICE,
    // Cannot be represented as text (images, audio, unknown binary); skipped.
    UNSUPPORTED
}

// Builds an `ai:TextDocument` from downloaded file content, extracting the text of
// PDF documents via Apache Tika. Returns `()` for content that cannot be represented
// as text (images, audio, Office documents, unknown binary), signalling the caller to skip.
isolated function buildDocument(byte[] content, string fileName, string? mimeType, decimal? fileSize,
        string? createdDateTime, string? modifiedDateTime) returns ai:TextDocument?|ai:Error {
    ai:Metadata metadata = {fileName};
    if mimeType is string {
        metadata.mimeType = mimeType;
    }
    if fileSize is decimal {
        metadata.fileSize = fileSize;
    }
    time:Utc? createdAt = toUtc(createdDateTime);
    if createdAt is time:Utc {
        metadata.createdAt = createdAt;
    }
    time:Utc? modifiedAt = toUtc(modifiedDateTime);
    if modifiedAt is time:Utc {
        metadata.modifiedAt = modifiedAt;
    }

    match classify(fileName, mimeType) {
        PLAIN_TEXT => {
            string|error text = string:fromBytes(content);
            if text is error {
                return error ai:Error(
                    string `Failed to decode text content of '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
        EXTRACTABLE => {
            string|error text = extractText(content, fileName);
            if text is error {
                return error ai:Error(
                    string `Failed to extract text from '${fileName}': ${text.message()}`, text);
            }
            return {content: text, metadata};
        }
    }
    return ();
}

// Extracts plain text from a PDF document using Apache Tika, reading directly from the
// in-memory bytes (no temporary file). `fileName` is passed as a Tika resource-name hint.
// Returns an `error` if the content cannot be parsed.
isolated function extractText(byte[] content, string fileName) returns string|error = @java:Method {
    'class: "io.ballerina.lib.ai.microsoft.sharepoint.TextExtractor",
    name: "extractText"
} external;

// Classifies a file by how its text is obtained, using MIME type then extension.
isolated function classify(string fileName, string? mimeType) returns DocumentKind {
    string mime = (mimeType ?: "").toLowerAscii();
    string extension = getExtension(fileName);
    if mime.startsWith("text/") || (mime != "" && TEXT_MIME_TYPES.indexOf(mime) !is ())
            || TEXT_EXTENSIONS.indexOf(extension) !is () {
        return PLAIN_TEXT;
    }
    // Microsoft Office documents are recognised so they can be rejected with a clear,
    // format-specific message: this loader extracts text from PDFs (and natively textual
    // files) only and does not ship the Apache POI stack, so Office formats are skipped in
    // folder loads and rejected when named explicitly.
    if (mime != "" && OFFICE_MIME_TYPES.indexOf(mime) !is ())
            || OFFICE_EXTENSIONS.indexOf(extension) !is () {
        return UNSUPPORTED_OFFICE;
    }
    if (mime != "" && EXTRACTABLE_MIME_TYPES.indexOf(mime) !is ())
            || EXTRACTABLE_EXTENSIONS.indexOf(extension) !is () {
        return EXTRACTABLE;
    }
    return UNSUPPORTED;
}

// Reports whether a file is a Microsoft Office document, which this loader does not
// support (see `OFFICE_*` lists / `classify`). Such files are skipped in folder loads
// and rejected with an error when named explicitly.
isolated function isUnsupportedOfficeDocument(string fileName, string? mimeType) returns boolean =>
    classify(fileName, mimeType) == UNSUPPORTED_OFFICE;

// Returns the lower-cased file extension (without the dot), or `""` if none.
isolated function getExtension(string fileName) returns string {
    int? lastDotIndex = fileName.lastIndexOf(".");
    if lastDotIndex is () {
        return "";
    }
    return fileName.substring(lastDotIndex + 1).toLowerAscii();
}

// Reports whether an error represents an HTTP 404. The typed status code is
// preferred; otherwise the message and cause chain are inspected.
isolated function isNotFoundError(error e) returns boolean {
    if e is http:ClientRequestError {
        return e.detail().statusCode == http:STATUS_NOT_FOUND;
    }
    string message = e.message().toLowerAscii();
    if message.includes("itemnotfound") || message.includes("not found") || message.includes("status code '404'")
            || message.includes("status: 404") {
        return true;
    }
    error? cause = e.cause();
    return cause is error && isNotFoundError(cause);
}

// Returns the `value` array of an OData collection page, or `[]` if absent.
isolated function valuesOf(json page) returns json[] {
    if page is map<json> {
        json values = page["value"];
        if values is json[] {
            return values;
        }
    }
    return [];
}

// Returns the `@odata.nextLink` of an OData page, or `()` on the last page.
isolated function nextLinkOf(json page) returns string? {
    if page is map<json> {
        json link = page["@odata.nextLink"];
        if link is string {
            return link;
        }
    }
    return ();
}

// Reads a string-valued field from a JSON object, or `()` if absent/non-string.
isolated function strField(json value, string key) returns string? {
    if value is map<json> {
        json item = value[key];
        if item is string {
            return item;
        }
    }
    return ();
}

// Removes duplicate strings, preserving first-appearance order.
isolated function dedupeStrings(string[] values) returns string[] {
    string[] result = [];
    map<boolean> seen = {};
    foreach string value in values {
        if !seen.hasKey(value) {
            seen[value] = true;
            result.push(value);
        }
    }
    return result;
}

// Returns the scheme+authority of a URL (e.g. `https://graph.microsoft.com`), so
// an absolute `@odata.nextLink` can be requested as a relative path.
isolated function originOf(string url) returns string {
    int? schemeIndex = url.indexOf("://");
    if schemeIndex is () {
        return url;
    }
    int authorityStart = schemeIndex + 3;
    int? slashIndex = url.indexOf("/", authorityStart);
    if slashIndex is () {
        return url;
    }
    return url.substring(0, slashIndex);
}

// Converts an absolute URL into a path relative to the given origin.
isolated function relativeUrl(string origin, string absoluteUrl) returns string {
    if absoluteUrl.startsWith(origin) {
        return absoluteUrl.substring(origin.length());
    }
    return absoluteUrl;
}

// Reports whether a file passes the extension allowlist (`()`/empty matches all).
isolated function matchesExtensionFilter(string fileName, string[]? includeExtensions) returns boolean {
    if includeExtensions is () || includeExtensions.length() == 0 {
        return true;
    }
    string extension = getExtension(fileName);
    foreach string allowed in includeExtensions {
        string normalized = allowed.toLowerAscii();
        if normalized.startsWith(".") {
            normalized = normalized.substring(1);
        }
        if normalized == extension {
            return true;
        }
    }
    return false;
}

// Microsoft Graph's path-based site addressing (`{hostname}:/{server-relative-path}`)
// must terminate the path with a `:` before any child navigation such as `/drives`
// or `/pages`. The composite-id form (`{hostname},{guid},{guid}`) has no path and
// needs no colon. Normalize the path form so callers need not append it themselves.
isolated function normalizeSiteId(string siteId) returns string {
    string trimmed = siteId.trim();
    if trimmed.includes(":/") && !trimmed.endsWith(":") {
        return trimmed + ":";
    }
    return trimmed;
}

// Normalizes a path for the OneDrive API: ensures a leading slash, drops trailing
// slashes, and maps the library root (`""`/`"/"`) to an empty string.
isolated function normalizePath(string path) returns string {
    string trimmed = path.trim();
    if trimmed == "" || trimmed == "/" {
        return "";
    }
    string normalized = trimmed.startsWith("/") ? trimmed : "/" + trimmed;
    if normalized.endsWith("/") {
        normalized = normalized.substring(0, normalized.length() - 1);
    }
    return normalized;
}

// Recursively collects page text from a web part's JSON: `innerHtml` (text web
// parts) and the `searchablePlainTexts` of server-processed content.
isolated function collectWebPartText(json value, string[] acc) {
    if value is map<json> {
        foreach [string, json] [key, item] in value.entries() {
            if key == "innerHtml" && item is string {
                string text = htmlToText(item);
                if text != "" {
                    acc.push(text);
                }
            } else if key == "searchablePlainTexts" && item is json[] {
                foreach json entry in item {
                    if entry is map<json> {
                        json entryValue = entry["value"];
                        if entryValue is string && entryValue.trim() != "" {
                            acc.push(entryValue.trim());
                        }
                    }
                }
            } else {
                collectWebPartText(item, acc);
            }
        }
    } else if value is json[] {
        foreach json item in value {
            collectWebPartText(item, acc);
        }
    }
}

// Strips HTML tags, decodes common entities, and collapses whitespace to plain text.
isolated function htmlToText(string html) returns string {
    string text = re `<[^>]*>`.replaceAll(html, " ");
    text = re `&nbsp;`.replaceAll(text, " ");
    text = re `&lt;`.replaceAll(text, "<");
    text = re `&gt;`.replaceAll(text, ">");
    text = re `&quot;`.replaceAll(text, "\"");
    text = re `&#39;`.replaceAll(text, "'");
    // `&amp;` is decoded last so that `&amp;lt;` resolves to the literal `&lt;`
    // rather than being double-decoded into `<`.
    text = re `&amp;`.replaceAll(text, "&");
    text = re `\s+`.replaceAll(text, " ");
    return text.trim();
}

// Parses an ISO 8601 timestamp into `time:Utc`, or `()` if absent/unparseable.
isolated function toUtc(string? dateTime) returns time:Utc? {
    if dateTime is () {
        return ();
    }
    time:Utc|error utc = time:utcFromString(dateTime);
    return utc is time:Utc ? utc : ();
}

// MIME types (outside the `text/` family) treated as text.
final readonly & string[] TEXT_MIME_TYPES = [
    "application/json",
    "application/xml",
    "application/xhtml+xml",
    "application/javascript",
    "application/x-yaml",
    "application/yaml",
    "application/csv"
];

// File extensions treated as text.
final readonly & string[] TEXT_EXTENSIONS = [
    "txt", "text", "md", "markdown", "csv", "tsv", "json", "xml", "html", "htm",
    "yaml", "yml", "log", "ini", "conf", "properties", "css", "js", "ts"
];

// MIME types whose text is extracted via Apache Tika. PDF only — this loader does not
// support Office formats (see `OFFICE_*`).
final readonly & string[] EXTRACTABLE_MIME_TYPES = [
    "application/pdf"
];

// File extensions whose text is extracted via Apache Tika. PDF only — this loader does
// not support Office formats (see `OFFICE_*`).
final readonly & string[] EXTRACTABLE_EXTENSIONS = [
    "pdf"
];

// Microsoft Office MIME types. This loader extracts text from PDFs only and does not ship
// the Apache POI stack, so these formats are recognised solely to skip them (folder loads)
// or to reject them with a clear, format-specific error (explicitly named paths).
final readonly & string[] OFFICE_MIME_TYPES = [
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "application/vnd.ms-powerpoint",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
];

// Microsoft Office file extensions, unsupported by this loader (see above).
final readonly & string[] OFFICE_EXTENSIONS = [
    "doc", "docx", "ppt", "pptx", "xls", "xlsx"
];
