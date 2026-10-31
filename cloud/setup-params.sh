#!/usr/bin/env bash
# Stores the settings in Parameter Store under /torpet-el (standard tier: free).
# Secrets are SecureStrings encrypted with the AWS managed key aws/ssm. Run it again to change something;
# press Enter to keep a value that's already there.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-personal}"
export AWS_REGION=eu-north-1
P=/torpet-el

current() { aws ssm get-parameter --name "$P/$1" --with-decryption --query Parameter.Value --output text 2>/dev/null || true; }
put() { aws ssm put-parameter --name "$P/$1" --type "$2" --value "$3" --overwrite >/dev/null; echo "  saved $P/$1"; }
random() { openssl rand -hex 32 | cut -c "1-$1"; }

echo "Tuya cloud project (platform.tuya.com → your project → Overview)"
read -r -p "  Access ID [$(current tuya-access-id)]: " id
[ -n "$id" ] && put tuya-access-id String "$id"
read -r -s -p "  Access Secret (hidden, Enter keeps current): " secret; echo
[ -n "$secret" ] && put tuya-access-secret SecureString "$secret"
echo "  Data centers: centralEurope westernEurope westernAmerica easternAmerica china india"
old_region="$(current tuya-region)"
read -r -p "  Data center [${old_region:-centralEurope}]: " region
put tuya-region String "${region:-${old_region:-centralEurope}}"

echo
topic="$(current ntfy-topic)"
if [ -z "$topic" ]; then
  topic="torpet-el-$(random 16)"
  put ntfy-topic SecureString "$topic"
fi
echo "ntfy topic: $topic"
echo "  Subscribe to it in the ntfy app (iPhone/Android) or at https://ntfy.sh/$topic"
echo "  Anyone who knows the name can read it, so keep it to yourself."

key="$(current api-key)"
if [ -z "$key" ]; then
  key="$(random 40)"
  put api-key SecureString "$key"
fi
echo
echo "API key for the Mac app (Authorization: Bearer <key>):"
echo "  $key"
