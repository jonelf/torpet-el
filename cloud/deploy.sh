#!/usr/bin/env bash
# Deploys the stack, then uploads the function code (no S3 bucket needed).
#   ./deploy.sh              uses the AWS profile "personal"
#   AWS_PROFILE=x ./deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

export AWS_PROFILE="${AWS_PROFILE:-personal}"
export AWS_REGION=eu-north-1
STACK=torpet-el

aws cloudformation deploy \
  --stack-name "$STACK" \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset

# The function is bundled with the MELCloud library. It comes from GitHub Packages, which needs a token with
# read:packages in NODE_AUTH_TOKEN (see README); the token is only used here, on this machine.
if [ ! -d node_modules/@olivierzal/melcloud-api ] || [ ! -d node_modules/esbuild ]; then
  : "${NODE_AUTH_TOKEN:?Set NODE_AUTH_TOKEN to a GitHub token with read:packages (see cloud/README.md)}"
  npm install --no-audit --no-fund
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The AWS SDK v3 is part of the Lambda runtime, so it stays out of the bundle. The banner lets bundled
# CommonJS dependencies use require() inside an ES module.
npx esbuild lambda/index.mjs --bundle --platform=node --target=node22 --format=esm --minify-syntax \
  --external:'@aws-sdk/*' --outfile="$tmp/pkg/index.mjs" --log-level=warning \
  --banner:js="import { createRequire as __cr } from 'node:module'; const require = __cr(import.meta.url);"
(cd "$tmp/pkg" && zip -q -r "$tmp/function.zip" .)
aws lambda update-function-code --function-name torpet-el --zip-file "fileb://$tmp/function.zip" \
  --query 'LastUpdateStatus' --output text >/dev/null
aws lambda wait function-updated-v2 --function-name torpet-el

url="$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FunctionUrl'].OutputValue" --output text)"
echo "Deployed. Function URL: $url"
