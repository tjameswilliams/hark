#!/bin/bash
# Build and ship the Hark site. Infra via CDK, content via s3 sync, then a
# CloudFront invalidation. Same shape and same AWS profile (radius) as the
# sibling sites.
#
#   website/scripts/deploy.sh
#
# Infra deploys first so the site can be built against the real origin, read
# back from the CDK outputs. harkdictate.com is registered in the radius
# account (hosted zone present), so it is the default; empty SITE_DOMAIN to
# fall back to the bare CloudFront URL.
set -euo pipefail

PROFILE="${AWS_PROFILE_OVERRIDE:-radius}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(cd "$ROOT/.." && pwd)"
DMG="${HARK_DMG:-$REPO/dist/Hark.dmg}"
UPDATES="$(dirname "$DMG")/updates"
export SITE_DOMAIN="${SITE_DOMAIN-harkdictate.com}"

echo "==> Deploying infra (profile: $PROFILE, domain: ${SITE_DOMAIN:-none})"
(cd "$ROOT/infra" && npx cdk deploy HarkWebsite \
  --require-approval never \
  --profile "$PROFILE" \
  --outputs-file outputs.json)

BUCKET=$(node -p "require('$ROOT/infra/outputs.json').HarkWebsite.SiteBucketName")
DIST_ID=$(node -p "require('$ROOT/infra/outputs.json').HarkWebsite.DistributionId")
URL=$(node -p "require('$ROOT/infra/outputs.json').HarkWebsite.SiteUrl")

echo "==> Building site for $URL"
(cd "$ROOT" && SITE_URL="$URL" npm run build)

echo "==> Syncing site to s3://$BUCKET"
# --exclude downloads/*: releases are uploaded below and must survive a
# --delete sync of the site content.
aws s3 sync "$ROOT/dist" "s3://$BUCKET" \
  --delete \
  --exclude "downloads/*" \
  --profile "$PROFILE" \
  --region us-east-1

if [ -f "$DMG" ]; then
  echo "==> Uploading evergreen dmg ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
  aws s3 cp "$DMG" "s3://$BUCKET/downloads/Hark.dmg" \
    --content-type application/x-apple-diskimage \
    --profile "$PROFILE" \
    --region us-east-1
else
  echo "==> No dmg at $DMG, skipping binary (set HARK_DMG to override)"
fi

# Versioned dmgs are what the Homebrew cask pins by sha256. Uploaded without
# --delete so every version stays fetchable after later releases.
if [ -d "$UPDATES" ]; then
  echo "==> Uploading versioned dmgs from $UPDATES"
  aws s3 sync "$UPDATES" "s3://$BUCKET/downloads" \
    --exclude "*" --include "Hark-*.dmg" \
    --content-type application/x-apple-diskimage \
    --profile "$PROFILE" \
    --region us-east-1
  if [ -f "$UPDATES/latest-version.txt" ]; then
    aws s3 cp "$UPDATES/latest-version.txt" "s3://$BUCKET/downloads/latest-version.txt" \
      --content-type text/plain \
      --cache-control "max-age=300" \
      --profile "$PROFILE" \
      --region us-east-1
  fi
fi

echo "==> Invalidating CloudFront cache"
aws cloudfront create-invalidation \
  --distribution-id "$DIST_ID" \
  --paths "/*" \
  --profile "$PROFILE" \
  --no-cli-pager \
  --query 'Invalidation.Id' \
  --output text

echo "==> Live at $URL"
