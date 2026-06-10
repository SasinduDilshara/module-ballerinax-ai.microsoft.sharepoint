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

# OAuth2 Client Credentials Grant Configs
public type OAuth2ClientCredentialsGrantConfig record {|
    *http:OAuth2ClientCredentialsGrantConfig;
    # Token URL
    string tokenUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
|};

# OAuth2 Refresh Token Grant Configs
public type OAuth2RefreshTokenGrantConfig record {|
    *http:OAuth2RefreshTokenGrantConfig;
    # Refresh URL
    string refreshUrl = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
|};

# Authentication and connection configuration used to reach SharePoint through
# the Microsoft Graph API. The HTTP-level options mirror those of the underlying
# Microsoft Graph `sites` and `pages` clients and are forwarded to both.
public type ConnectionConfig record {|
    # Configurations related to client authentication
    OAuth2ClientCredentialsGrantConfig|http:BearerTokenConfig|OAuth2RefreshTokenGrantConfig auth;
    # The HTTP version understood by the client
    http:HttpVersion httpVersion = http:HTTP_2_0;
    # Configurations related to HTTP/1.x protocol
    http:ClientHttp1Settings http1Settings = {};
    # Configurations related to HTTP/2 protocol
    http:ClientHttp2Settings http2Settings = {};
    # The maximum time to wait (in seconds) for a response before closing the connection
    decimal timeout = 30;
    # The choice of setting `forwarded`/`x-forwarded` header
    string forwarded = "disable";
    # Configurations associated with Redirection
    http:FollowRedirects followRedirects = {
        enabled: true,
        maxCount: 5,
        allowAuthHeaders: true
    };
    # Configurations associated with request pooling
    http:PoolConfiguration poolConfig?;
    # HTTP caching related configurations
    http:CacheConfig cache = {};
    # Specifies the way of handling compression (`accept-encoding`) header
    http:Compression compression = http:COMPRESSION_AUTO;
    # Configurations associated with the behaviour of the Circuit Breaker
    http:CircuitBreakerConfig circuitBreaker?;
    # Configurations associated with retrying
    http:RetryConfig retryConfig?;
    # Configurations associated with cookies
    http:CookieConfig cookieConfig?;
    # Configurations associated with inbound response size limits
    http:ResponseLimitConfigs responseLimits = {};
    # SSL/TLS-related options
    http:ClientSecureSocket secureSocket?;
    # Proxy server related options
    http:ProxyConfig proxy?;
    # Provides settings related to client socket configuration
    http:ClientSocketConfig socketConfig = {};
    # Enables the inbound payload validation functionality which provided by the constraint package. Enabled by default
    boolean validation = true;
    # Enables relaxed data binding on the client side. When enabled, `nil` values are treated as optional, 
    # and absent fields are handled as `nilable` types. Enabled by default.
    boolean laxDataBinding = true;
    # The base URL of the Microsoft Graph service
    string serviceUrl = "https://graph.microsoft.com/v1.0";
|};

# A rule selecting what to load from one library within a site, or from every
# library on the site when `name` is `"*"` (the paths then apply to each).
public type Library record {|
    # The library's display name as shown in SharePoint, or `"*"` for every
    # library on the site. Defaults to `"Documents"`, the English name of the
    # standard library; localized tenants report a translated name (e.g.
    # `Dokumente`, `Documentos`), so set this to match what SharePoint shows
    string name = "Documents";
    # File/folder paths relative to the library root (e.g. `/Reports`).
    # Defaults to `["/"]`, the whole library; `[]` skips this library
    string[] paths = ["/"];
    # Whether folder paths are traversed into sub-folders. Defaults to `false`
    boolean recursive = false;
    # Case-insensitive extension allowlist for folder contents.
    # Defaults to `()`, all types
    string[]? includeExtensions = ();
|};

# A SharePoint site to load documents from. Several may be configured per loader.
public type Source record {|
    # The Graph site id, which uniquely identifies a SharePoint site. It is either
    # the composite id (`{hostname},{spsite-guid},{spweb-guid}`) or the path form
    # (`{hostname}:/sites/{site-name}`).
    #
    # The browser URL is not supported directly, but you can derive the site id
    # from the site URL as follows:
    # ```
    # https://contoso.sharepoint.com/sites/Marketing
    #         └──────────┬─────────┘└──────┬───────┘
    #               hostname          server-relative path
    # siteID = contoso.sharepoint.com:/sites/Marketing
    # ```
    #
    # Alternatively, you can obtain the site id by calling the SharePoint REST
    # API at `{site-url}/_api/site/id`, for example:
    # ```
    # https://contoso.sharepoint.com/sites/Marketing/_api/site/id
    # ```
    string siteId;
    # The libraries to read from, each with its own paths and options.
    # Defaults to the site's default document library.
    Library[] libraries = [{}];
    # Site pages to load as text, matched by name, title, or id.
    # Defaults to `()`, no pages
    string[]? pages = ();
|};

// A minimal projection of the Microsoft Graph `driveItem` resource, modelling only the
// fields this loader reads. These are intentionally open records (no `{| |}`) so that any
// other fields Graph returns are tolerated, and so the `@odata.nextLink` of a collection
// page survives data binding and remains available for pagination.

# A file or folder in a SharePoint document library (Microsoft Graph `driveItem`).
type DriveItem record {
    # The drive item's unique identifier
    string id?;
    # The file or folder name
    string name?;
    # The size of the item in bytes
    decimal size?;
    # The creation timestamp (ISO 8601)
    string createdDateTime?;
    # The last-modified timestamp (ISO 8601)
    string lastModifiedDateTime?;
    # Present when the item is a folder; its presence distinguishes folders from files
    Folder folder?;
    # Present when the item is a file, carrying its MIME type
    File file?;
};

# The `folder` facet of a `DriveItem`; its presence marks the item as a folder.
type Folder record {
    # The number of immediate children in the folder
    int childCount?;
};

# The `file` facet of a `DriveItem`, carrying the file's MIME type.
type File record {
    # The MIME type of the file, as reported by Graph
    string mimeType?;
};

# A page of a Microsoft Graph `driveItem` collection (a folder/root children listing).
type DriveItemCollectionResponse record {
    # The drive items on this page
    DriveItem[] value?;
};
