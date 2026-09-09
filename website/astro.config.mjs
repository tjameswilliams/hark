// @ts-check
import { defineConfig } from "astro/config";
import sitemap from "@astrojs/sitemap";
import { existsSync, readFileSync } from "node:fs";

// Static output for S3 + CloudFront, same shape as the sibling sites.
//
// The canonical origin drives sitemap, canonical links and og:url. Until a
// domain is registered it is the CloudFront URL, which deploy.sh reads from
// the CDK outputs and passes in as SITE_URL; a plain `npm run dev` falls back
// to whatever the last deploy recorded, then to localhost.
function siteUrl() {
  if (process.env.SITE_URL) return process.env.SITE_URL;
  const outputs = new URL("./infra/outputs.json", import.meta.url);
  if (existsSync(outputs)) {
    const url = JSON.parse(readFileSync(outputs, "utf8")).HarkWebsite?.SiteUrl;
    if (url) return url;
  }
  return "http://localhost:4321";
}

export default defineConfig({
  output: "static",
  site: siteUrl(),
  trailingSlash: "never",
  integrations: [sitemap()],
  build: {
    // /download.html -> /download, so the CloudFront url-rewrite function
    // can keep paths clean.
    format: "file",
  },
});
