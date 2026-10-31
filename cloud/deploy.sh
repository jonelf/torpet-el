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

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
(cd lambda && zip -q -r "$tmp/function.zip" .)
aws lambda update-function-code --function-name torpet-el --zip-file "fileb://$tmp/function.zip" \
  --query 'LastUpdateStatus' --output text >/dev/null
aws lambda wait function-updated-v2 --function-name torpet-el

url="$(aws cloudformation describe-stacks --stack-name "$STACK" \
  --query "Stacks[0].Outputs[?OutputKey=='FunctionUrl'].OutputValue" --output text)"
echo "Deployed. Function URL: $url"
