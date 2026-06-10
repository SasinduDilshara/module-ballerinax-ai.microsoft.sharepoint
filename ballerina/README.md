# Ballerina SharePoint Data Loader

The `ballerinax/ai.microsoft.sharepoint` module provides a `TextDataLoader` that retrieves documents from SharePoint document libraries and returns them as `ai:TextDocument` values, ready to be chunked, embedded, and indexed by the [Ballerina AI](https://central.ballerina.io/ballerina/ai) module. Inherently textual files are decoded directly, while PDF documents have their text extracted with Apache Tika.

It implements the `ai:DataLoader` abstraction, so it can be used anywhere an `ai:DataLoader` is expected (for example, in a Retrieval-Augmented Generation ingestion pipeline).

## Overview

- Resolves a document library (drive) for each configured site using the Microsoft Graph `sites` API.
- Downloads file content through the Microsoft Graph drive (drive items) API.
- Supports loading individual files as well as entire folders, optionally recursively.
- Optionally loads SharePoint **site pages** (modern web-part pages) as `ai:TextDocument`s.
- Reads from multiple sites and libraries with a single loader instance.
- Returns every file as an `ai:TextDocument`, based on its MIME type / extension:
  - Inherently textual files (e.g. `txt`, `md`, `html`, `json`, `csv`, `xml`) are decoded directly.
  - `pdf` files have their text extracted with Apache Tika.
  - Other files that cannot be represented as text (e.g. images, audio, archives) are skipped with a
    logged warning; explicitly naming such a file as a path is an error.

## Authentication

SharePoint is accessed through the Microsoft Graph API. The loader supports three authentication mechanisms via `ConnectionConfig.auth`:

| Mechanism | Type | Best for |
| --- | --- | --- |
| Client credentials grant | `OAuth2ClientCredentialsGrantConfig` | App-only, server-to-server access (requires the `Sites.Read.All` application permission, which also covers site pages; use `Sites.Selected` for least-privilege, per-site access) |
| Refresh token grant | `OAuth2RefreshTokenGrantConfig` | User-delegated access |
| Bearer token | `http:BearerTokenConfig` | A pre-obtained access token (testing or externally managed tokens) |

## Usage

### Initialization

```ballerina
import ballerina/ai;
import ballerinax/ai.microsoft.sharepoint;

final sharepoint:TextDataLoader loader = check new (
    {
        auth: {
            tokenUrl: "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token",
            clientId: "<client-id>",
            clientSecret: "<client-secret>",
            scopes: ["https://graph.microsoft.com/.default"]
        }
    },
    {
        // Load only PDFs found under /Onboarding (recursively), plus one explicit file.
        siteId: "contoso.sharepoint.com:/sites/HR",
        libraries: [
            {
                paths: ["/Policies/leave-policy.pdf", "/Onboarding"],
                recursive: true,
                includeExtensions: ["pdf"]
            }
        ]
    },
    {
        // Read from several document libraries on the same site; each library
        // carries its own paths and traversal options.
        siteId: "contoso.sharepoint.com:/sites/Engineering",
        libraries: [
            {name: "Specs", paths: ["/api-design.md"]},
            {name: "Site Assets", paths: ["/diagrams"], recursive: true}
        ]
    },
    {
        // Files and site pages can be combined; `pages: ["*"]` loads every page,
        // an empty/omitted `pages` (the default) loads none.
        siteId: "contoso.sharepoint.com:/sites/News",
        pages: ["*"]
    }
);
```

### Loading site pages

Set the `pages` field on a `Source` to ingest SharePoint modern pages as text:

- `pages: ["*"]` — load **every** page on the site.
- `pages: ["Home", "Q3-Update"]` — load specific pages, matched by name, title, or id. Note that a page's `name` is its file name including the `.aspx` extension (e.g. `Home.aspx`), so matching by the human-friendly `title` is usually more convenient.
- `pages` omitted or `()` (the default) — load **no** pages.

Each page becomes a single `ai:TextDocument` whose content is the page title followed by the plain text extracted from its web parts (`innerHtml` and server-processed searchable text, with HTML stripped). Metadata includes the page title, `webUrl`, and timestamps.

> **Note:** Web-part text extraction relies on the Microsoft Graph `pages`/`webParts` API, which is best-effort — for some pages Graph returns little or no web-part content, in which case the resulting document may contain only the page title.

### Reading from multiple libraries

A SharePoint site can host several document libraries. The `libraries` field takes one `Library` per library, each binding a library to **its own** paths and traversal options — mirroring the Microsoft Graph model, where a path is always resolved relative to a specific library (a Graph `drive`):

```ballerina
libraries: [
    {name: "Documents", paths: ["/Reports"], recursive: true},
    {name: "Specs", paths: ["/api-design.md"]}
]
```

Each target's `paths` default to `["/"]`, so a bare `{name: "Specs"}` loads that whole library; set `paths` to narrow it. The `libraries` field itself defaults to `[{}]`, so a `Source` with only a `siteId` loads the whole of the site's default document library; set `libraries` to `[]` to load no document-library content.

- `name: "Documents"` (the default) — the standard library. Note that this is the **English** display name; on tenants provisioned in another language the default library is reported by a localized name (e.g. `Dokumente`, `Documentos`, `文档`), so set `name` explicitly to match what SharePoint shows.
- `name: "*"` — read from **every** library on the site. Because the target's `paths` are then applied to all libraries, a path that does not exist in a given library is **skipped** for it rather than treated as an error. A named library resolves to exactly one drive, so a missing path there is still reported as an error to help catch typos.

### Filtering by file type

Each `Library` has its own `includeExtensions` to restrict which files are loaded from that library's folders:

- `includeExtensions: ["pdf"]` — only PDF files.
- `includeExtensions: ["pdf", ".md", "TXT"]` — case-insensitive; a leading dot is optional.
- omitted / `()` (the default) — load all file types.

The filter applies to files discovered while traversing folders. A file listed **explicitly** in that target's `paths` is always loaded, even if its extension isn't in the list.

### Loading documents

```ballerina
public function main() returns error? {
    ai:Document[]|ai:Document documents = check loader.load();
    // Pass the documents to a chunker / embedding provider / vector store ...
}
```

`load()` returns a single `ai:Document` when exactly one file is resolved, and an `ai:Document[]` otherwise (mirroring `ai:TextDataLoader`).

## Configuration reference

### `ConnectionConfig`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `auth` | `http:BearerTokenConfig \| OAuth2ClientCredentialsGrantConfig \| OAuth2RefreshTokenGrantConfig` | — | Authentication configuration |
| `serviceUrl` | `string` | `"https://graph.microsoft.com/v1.0"` | Microsoft Graph base URL |
| `httpVersion` | `http:HttpVersion` | `http:HTTP_2_0` | HTTP version understood by the client |
| `http1Settings` | `ClientHttp1Settings` | — | HTTP/1.x protocol settings (keep-alive, chunking, proxy) |
| `http2Settings` | `http:ClientHttp2Settings` | — | HTTP/2 protocol settings |
| `timeout` | `decimal` | `30` | Response timeout, in seconds |
| `forwarded` | `string` | `"disable"` | Handling of the `forwarded`/`x-forwarded` header |
| `followRedirects` | `http:FollowRedirects` | `{enabled: true, maxCount: 5, allowAuthHeaders: true}` | Redirect handling. Enabled by default so the Graph `/items/{id}/content` 302 download redirect is followed |
| `poolConfig` | `http:PoolConfiguration` | — | Request pooling configuration |
| `cache` | `http:CacheConfig` | — | HTTP caching configuration |
| `compression` | `http:Compression` | `http:COMPRESSION_AUTO` | `accept-encoding` handling |
| `circuitBreaker` | `http:CircuitBreakerConfig` | — | Circuit breaker configuration |
| `retryConfig` | `http:RetryConfig` | — | Retry configuration |
| `cookieConfig` | `http:CookieConfig` | — | Cookie configuration |
| `responseLimits` | `http:ResponseLimitConfigs` | — | Inbound response size limits |
| `secureSocket` | `http:ClientSecureSocket` | — | SSL/TLS options |
| `proxy` | `http:ProxyConfig` | — | Proxy server options |
| `socketConfig` | `http:ClientSocketConfig` | `{}` | Client socket configuration |
| `validation` | `boolean` | `true` | Inbound payload validation |
| `laxDataBinding` | `boolean` | `true` | Relaxed data binding |

The HTTP-level fields mirror those of the underlying Microsoft Graph `sites` and `pages` clients and are forwarded to both.

### `Source`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `siteId` | `string` | — | Microsoft Graph site id. Accepts the composite id (`{hostname},{spsite-guid},{spweb-guid}`) or the path form (`{hostname}:/sites/{site-name}`) |
| `libraries` | `Library[]` | `[{}]` | Document libraries to read from, each paired with its own paths and traversal options. The default `[{}]` loads the whole of the site's default document library; `[]` loads no document-library content |
| `pages` | `string[]?` | `()` | Site pages to load as text. Matched by name, title, or id. Use `["*"]` for all pages; `()` for none |

### `Library`

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `name` | `string` | `"Documents"` | Display name of the document library to read from, as shown in SharePoint. The default `"Documents"` is the English name; localized tenants use a translated name. Use `"*"` for every library on the site |
| `paths` | `string[]` | `["/"]` | File and/or folder paths relative to this library's root. The default `["/"]` loads the entire library; `[]` loads nothing from it |
| `recursive` | `boolean` | `false` | Whether folder paths are traversed recursively |
| `includeExtensions` | `string[]?` | `()` | Extension allowlist applied to this library's folder contents (e.g. `["pdf"]`). Case-insensitive; `()` loads all types. Explicit file paths bypass it |
