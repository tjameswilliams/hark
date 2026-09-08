#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { WebsiteStack } from "../lib/website-stack.js";

const app = new cdk.App();

// The stack id is the CloudFormation identity of the bucket and the
// distribution. Changing it would destroy and recreate both, and the
// /downloads prefix is what every Homebrew install fetches from.
new WebsiteStack(app, "HarkWebsite", {
  // us-east-1: CloudFront requires its ACM certificate there. The account id
  // comes from the radius profile at synth time; the hosted-zone lookup
  // needs it.
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: "us-east-1" },
  // Set once a domain is registered and its Route 53 hosted zone exists.
  // Until then the stack deploys on the CloudFront domain alone.
  domainName: process.env.SITE_DOMAIN || undefined,
  description: "Hark marketing site: S3 + CloudFront static hosting",
});
