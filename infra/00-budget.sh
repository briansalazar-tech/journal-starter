#!/usr/bin/env bash
# Phase 0: cost guardrails, before anything billable exists.
#
# Creates:
#   - the resource group every later phase deploys into (empty groups are free)
#   - a monthly cost budget scoped to that group, with email alerts at
#     50%, 80% and 100% of actual spend and 100% of forecast spend
#
# Budgets only notify; they never stop resources. Cost data lags 8-24 hours.
# The subscription-wide budget you already have keeps covering everything else,
# including any AI resources that live outside this group.
#
# Safe to re-run: it updates the same budget in place.

# shellcheck source=config.sh
source "$(dirname "$0")/config.sh"

API_VERSION="2024-08-01"
SCOPE="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RG}"
BUDGET_URL="https://management.azure.com${SCOPE}/providers/Microsoft.Consumption/budgets/${BUDGET_NAME}?api-version=${API_VERSION}"

# A budget period must start on the first day of a month.
START_DATE="$(date -u +%Y-%m-01)"
END_DATE="$(date -u -d "${START_DATE} +2 years" +%Y-%m-01)"

notification() { # <threshold-percent> <Actual|Forecasted>
  cat <<EOF
"${2,,}_${1}": {
        "enabled": true,
        "operator": "GreaterThanOrEqualTo",
        "threshold": ${1},
        "thresholdType": "${2}",
        "contactEmails": ["${BUDGET_EMAIL}"],
        "locale": "en-us"
      }
EOF
}

build_body() { # [etag]
  local etag_line=""
  [[ -n ${1:-} ]] && etag_line="\"eTag\": \"${1}\","
  cat <<EOF
{
  ${etag_line}
  "properties": {
    "category": "Cost",
    "amount": ${BUDGET_AMOUNT},
    "timeGrain": "Monthly",
    "timePeriod": {
      "startDate": "${START_DATE}T00:00:00Z",
      "endDate": "${END_DATE}T00:00:00Z"
    },
    "notifications": {
      $(notification 50 Actual),
      $(notification 80 Actual),
      $(notification 100 Actual),
      $(notification 100 Forecasted)
    }
  }
}
EOF
}

echo "Budget       : ${BUDGET_NAME}, \$${BUDGET_AMOUNT}/month on ${RG}"
echo "Alerts to    : ${BUDGET_EMAIL}"
echo "Thresholds   : actual 50% / 80% / 100%, forecast 100%"
echo "Period       : ${START_DATE} to ${END_DATE}"
confirm "create resource group ${RG} (free) and the budget above"

log "Resource group ${RG}"
az group create --name "$RG" --location "$LOCATION" --tags "${TAGS[@]}" -o none

log "Budget ${BUDGET_NAME}"
# Updating an existing budget requires its current eTag (optimistic concurrency).
etag="$(az_tsv rest --method get --url "$BUDGET_URL" --query eTag 2>/dev/null || true)"
body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
build_body "$etag" >"$body_file"
az rest --method put --url "$BUDGET_URL" --body "@$(native_path "$body_file")" -o none

log "Done"
az rest --method get --url "$BUDGET_URL" \
  --query "{name:name, amountUSD:properties.amount, alerts:properties.notifications.*.[thresholdType, threshold]}" \
  -o json
echo
echo "Check it in the portal: Cost Management > Budgets (scope: ${RG})."
