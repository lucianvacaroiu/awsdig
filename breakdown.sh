#!/usr/bin/env bash
# breakdown.sh — 30-day AWS cost breakdown with AUTO drill-downs
#
# ▸ Zero arguments: ./breakdown.sh
# ▸ Environment overrides:
#       METRIC      (UnblendedCost | AmortizedCost …)
#       AWS_PROFILE (CLI profile / role to use)
#
# Requirements: AWS CLI v2, jq, awk (BSD or GNU)
# ---------------------------------------------------------------------------

set -euo pipefail

#################### 1. tiny cross-platform date helper ######################
date_ymd() {                                           # "30 days ago" | "tomorrow"
  if date -u -d "@0" +%Y-%m-%d >/dev/null 2>&1; then date -u -d "$1" +%Y-%m-%d
  elif command -v gdate >/dev/null 2>&1;          then gdate -u -d "$1" +%Y-%m-%d
  else case "$1" in
         "30 days ago") date -u -v-30d +%Y-%m-%d ;;
         "14 days ago") date -u -v-14d +%Y-%m-%d ;;
         "tomorrow")    date -u -v+1d  +%Y-%m-%d ;;
         "today")       date -u        +%Y-%m-%d ;;
         *) echo "Unsupported date phrase: $1" >&2; exit 1 ;;
       esac
  fi
}

#################### 2. globals ################################################
START_AGO=$(date_ymd "6 days ago")  # inclusive
END=$(date_ymd "tomorrow")           # exclusive per CE API
TODAY=$(date_ymd "today")

METRIC="${METRIC:-UnblendedCost}"
PROFILE="${AWS_PROFILE:-default}"

#################### 3. helper → choose best drill-down key ###################
choose_key() {
  local service=$1
  local dim
  for dim in INSTANCE_TYPE_FAMILY INSTANCE_TYPE USAGE_TYPE OPERATION; do
    # Ask CE which values exist for this dimension for the service
    local json
    if ! json=$(aws ce get-dimension-values \
                  --profile "$PROFILE" \
                  --time-period "Start=$START_AGO,End=$END" \
                  --dimension "$dim" \
                  --filter "{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"$service\"]}}" \
                  --output json 2>/dev/null); then
      continue          # dimension not valid for the service → try next
    fi
    # Count values that are NOT "NoXXX"
    local cnt
    cnt=$(echo "$json" | jq '[.DimensionValues[].Value |
                              select(startswith("No")|not)] | length')
    if [[ $cnt -gt 1 ]]; then
      echo "$dim"
      return            # first dimension with >1 real buckets wins
    fi
  done
  echo "USAGE_TYPE"     # fallback: always works
}

#################### 4. investigate "No..." buckets ########################
investigate_no_bucket() {
  local service=$1
  local no_key_name=$2    # e.g., "NoInstanceType", "NoInstanceTypeFamily"
  local no_key_cost=$3    # e.g., "26.30"
  local dimension_key=$4  # e.g., "INSTANCE_TYPE", "INSTANCE_TYPE_FAMILY"

  # Only investigate if cost is significant (>$1.00)
  if (( $(echo "$no_key_cost < 1.00" | awk '{print ($1 < 1.00)}') )); then
    return
  fi

  echo "    ┌─ Investigating '$no_key_name' ($no_key_cost) → breakdown by USAGE_TYPE:"

  # For "No..." buckets, we'll just show the service breakdown by USAGE_TYPE
  # since filtering by "NoXXX" values often doesn't work as expected
  local usage_json
  if usage_json=$(aws ce get-cost-and-usage \
    --profile "$PROFILE" \
    --time-period "Start=$START_AGO,End=$END" \
    --granularity MONTHLY \
    --metrics "$METRIC" \
    --filter "{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"$service\"]}}" \
    --group-by Type=DIMENSION,Key=USAGE_TYPE \
    --output json 2>/dev/null); then

    echo "$usage_json" | jq -r --arg m "$METRIC" '
      .ResultsByTime[].Groups[] |
      [.Keys[0], (.Metrics[$m].Amount|tonumber)] |
      @tsv' |
    awk -F'\t' 'BEGIN{total=0} {total+=$2; printf "    │   %-45s %8.2f\n", $1, $2} END{if(NR>0) printf "    └─ Total for service: %8.2f\n", total}' |
    sort -t$'\t' -k2 -nr | head -10  # Show top 10 usage types
  else
    echo "    └─ Unable to investigate (API error)"
  fi
}

#################### 5. top-level service breakdown (aggregate & print) #######
service_json=$(aws ce get-cost-and-usage \
  --profile "$PROFILE" \
  --time-period "Start=$START_AGO,End=$END" \
  --granularity MONTHLY \
  --metrics "$METRIC" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --output json)

echo -e "\n### AWS cost breakdown by service (last 30 days: $START_AGO → $TODAY) [$METRIC]\n"
echo "$service_json" | jq -r --arg m "$METRIC" '
  .ResultsByTime[].Groups[] |
  [.Keys[0], (.Metrics[$m].Amount|tonumber)] |
  @tsv' |
awk -F'\t' '{tot[$1]+=$2} END{for(s in tot) printf "%-55s %12.2f\n",s,tot[s]}' |
sort -t$'\t' -k2 -nr

#################### 6. drill-downs ###########################################
echo
echo "### Per-service drill-downs (auto-selected secondary key)"
echo "-------------------------------------------------------------------"

# array of all services that spent >0
mapfile -t SERVICES < <(echo "$service_json" | jq -r --arg m "$METRIC" '
  .ResultsByTime[].Groups[] |
  select(.Metrics[$m].Amount|tonumber>0) |
  .Keys[0]' | sort -u)

for SERVICE in "${SERVICES[@]}"; do
  KEY=$(choose_key "$SERVICE")

  API="ce get-cost-and-usage"
  START="$START_AGO"
  if [[ $KEY == "RESOURCE_ID" ]]; then
    API="ce get-cost-and-usage-with-resources"
    START=$(date_ymd "14 days ago")   # CE limit for RESOURCE_ID
  fi

  drill_json=$(aws $API \
    --profile "$PROFILE" \
    --time-period "Start=$START,End=$END" \
    --granularity MONTHLY \
    --metrics "$METRIC" \
    --filter "{\"Dimensions\":{\"Key\":\"SERVICE\",\"Values\":[\"$SERVICE\"]}}" \
    --group-by "Type=DIMENSION,Key=$KEY" \
    --output json)

  echo -e "\n▶ $SERVICE — by $KEY  (window: $START → $TODAY)"

  # Store the drill-down output and check for "No..." buckets
  drill_output=$(echo "$drill_json" | jq -r --arg m "$METRIC" '
    .ResultsByTime[].Groups[] |
    [.Keys[0], (.Metrics[$m].Amount|tonumber)] |
    @tsv' |
  awk -F'\t' '{tot[$1]+=$2} END{for(k in tot)printf "%-55s %12.2f\n",k,tot[k]}' |
  sort -t$'\t' -k2 -nr)

  echo "$drill_output"

    # Check for "No..." buckets and investigate them
  while read -r line; do
    # Extract key name and cost from the formatted line
    key_name=$(echo "$line" | awk '{print $1}')
    cost=$(echo "$line" | awk '{print $NF}')

    if [[ $key_name =~ ^No.* ]] && [[ $cost =~ ^[0-9]+\.[0-9]+$ ]]; then
      investigate_no_bucket "$SERVICE" "$key_name" "$cost" "$KEY"
    fi
  done <<< "$drill_output"
done
