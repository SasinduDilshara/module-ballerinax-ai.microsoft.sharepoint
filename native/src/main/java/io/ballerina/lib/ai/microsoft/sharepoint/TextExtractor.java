/*
 * Copyright (c) 2026, WSO2 LLC. (http://www.wso2.com).
 *
 * WSO2 LLC. licenses this file to you under the Apache License,
 * Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package io.ballerina.lib.ai.microsoft.sharepoint;

import io.ballerina.runtime.api.creators.ErrorCreator;
import io.ballerina.runtime.api.utils.StringUtils;
import io.ballerina.runtime.api.values.BArray;
import io.ballerina.runtime.api.values.BString;
import org.apache.tika.metadata.Metadata;
import org.apache.tika.metadata.TikaCoreProperties;
import org.apache.tika.parser.ParseContext;
import org.apache.tika.parser.Parser;
import org.apache.tika.parser.pdf.PDFParser;
import org.apache.tika.sax.BodyContentHandler;

import java.io.ByteArrayInputStream;
import java.io.InputStream;

/**
 * Extracts plain text from PDF documents using Apache Tika.
 *
 * <p>This loader extracts text from PDFs only; Microsoft Office formats are not
 * supported (the caller classifies and skips them), so the Office (POI) stack is not
 * shipped.
 *
 * <p>Unlike {@code ai:TextDataLoader}, which reads from a file path, this reads straight
 * from the in-memory bytes downloaded from SharePoint via a {@link ByteArrayInputStream},
 * so no temporary file is ever written.
 *
 * <p>A {@link PDFParser} is used directly rather than {@code AutoDetectParser}; the latter
 * runs Tika's container detection, which probes archive formats via {@code commons-compress}
 * and is both unnecessary here (the caller only routes PDFs to this method) and sensitive to
 * the runtime's transitive library versions.
 */
public final class TextExtractor {

    // A BodyContentHandler write limit of -1 means "no limit" on extracted content size.
    private static final int UNLIMITED_CONTENT_SIZE = -1;

    private TextExtractor() {
    }

    /**
     * Extracts the textual content of a document held entirely in memory.
     *
     * @param content  the raw file bytes
     * @param fileName the file name, used to select the parser and as a Tika hint
     * @return the extracted text as a {@link BString}, or a Ballerina error on failure
     */
    public static Object extractText(BArray content, BString fileName) {
        byte[] bytes = content.getBytes();
        try (InputStream stream = new ByteArrayInputStream(bytes)) {
            Parser parser = new PDFParser();
            BodyContentHandler handler = new BodyContentHandler(UNLIMITED_CONTENT_SIZE);
            Metadata metadata = new Metadata();
            metadata.set(TikaCoreProperties.RESOURCE_NAME_KEY, fileName.getValue());
            parser.parse(stream, handler, metadata, new ParseContext());
            return StringUtils.fromString(handler.toString());
        } catch (Exception e) {
            String message = e.getMessage();
            return ErrorCreator.createError(StringUtils.fromString(
                    message != null ? message : e.getClass().getSimpleName()));
        }
    }
}
