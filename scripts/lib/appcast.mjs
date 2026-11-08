#!/usr/bin/env bun
// Writes a Sparkle appcast for one release (KNOCK-21). This is the "equivalent
// template" the story allows instead of generate_appcast: it embeds the exact
// values sign_update produced, so the app's Sparkle verifies the enclosure.
//
//   appcast.mjs <out.xml> <version> <build> <signature> <length> <url> <pubDate> [notes-file]
import { readFileSync, writeFileSync } from "node:fs";

const [out, version, build, signature, length, url, pubDate, notesFile] = process.argv.slice(2);
if (!out || !version || !build || !signature || !length || !url || !pubDate) {
  process.stderr.write(
    "usage: appcast.mjs <out.xml> <version> <build> <signature> <length> <url> <pubDate> [notes-file]\n",
  );
  process.exit(2);
}

const notes = notesFile ? readFileSync(notesFile, "utf8").trim() : "";
// A CDATA section cannot contain "]]>"; split it the standard way.
const cdata = notes.replace(/]]>/g, "]]]]><![CDATA[>");

const xml = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Waggle</title>
    <description>Most recent updates to Waggle.</description>
    <language>en</language>
    <item>
      <title>Version ${version}</title>
      <sparkle:version>${build}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <description><![CDATA[${cdata}]]></description>
      <pubDate>${pubDate}</pubDate>
      <enclosure url="${url}" sparkle:edSignature="${signature}" length="${length}" type="application/octet-stream" />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
`;
writeFileSync(out, xml);
