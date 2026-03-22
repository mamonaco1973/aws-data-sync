#!/bin/bash
# ================================================================================
# validate.sh
#
# Purpose:
#   - Prints EC2 instance endpoints for quick SSH/RDP access.
#   - Reads DataSync task ARNs from Terraform output in 03-datasync.
#   - Starts all four DataSync tasks concurrently.
#   - Polls each task execution until all reach SUCCESS or any reach ERROR.
#
# Notes:
#   - Requires jq for parsing Terraform JSON output.
#   - All four tasks run in parallel — each transfers one EFS project to S3.
# ================================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLL_INTERVAL=15
MAX_WAIT=3600  # 1 hour — DataSync transfers can take time depending on data size

# ------------------------------------------------------------------------------
# Helper: Get EC2 public DNS by Name tag
# ------------------------------------------------------------------------------
get_public_dns_by_name_tag() {
  local name_tag="$1"
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=${name_tag}" \
    --query "Reservations[].Instances[].PublicDnsName" \
    --output text | xargs
}

# ------------------------------------------------------------------------------
# EC2 Endpoint Output
# ------------------------------------------------------------------------------
windows_dns="$(get_public_dns_by_name_tag "windows-ad-admin")"
linux_dns="$(get_public_dns_by_name_tag "efs-client-gateway")"

echo ""
echo "============================================================================"
echo "EFS + Active Directory — Instance Endpoints"
echo "============================================================================"
echo ""

if [[ -n "${windows_dns}" && "${windows_dns}" != "None" ]]; then
  echo "NOTE: Windows RDP Host: ${windows_dns}"
else
  echo "WARN: windows-ad-admin not found or has no public DNS."
fi

if [[ -n "${linux_dns}" && "${linux_dns}" != "None" ]]; then
  echo "NOTE: Linux SSH Host:   ${linux_dns}"
else
  echo "WARN: efs-client-gateway not found or has no public DNS."
fi

echo ""

# ------------------------------------------------------------------------------
# Read DataSync Task ARNs from Terraform Output
# Terraform outputs a JSON map of { project-name: task-arn }.
# Parse into an associative array for named tracking through execution.
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync — Starting Tasks"
echo "============================================================================"
echo ""

declare -A TASK_MAP
while IFS=$'\t' read -r NAME ARN; do
  TASK_MAP["${NAME}"]="${ARN}"
done < <(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -json datasync_task_arns \
  | jq -r 'to_entries[] | [.key, .value] | @tsv')

if [[ "${#TASK_MAP[@]}" -eq 0 ]]; then
  echo "ERROR: No DataSync tasks found in 03-datasync Terraform output."
  exit 1
fi

# ------------------------------------------------------------------------------
# Start All Tasks Concurrently
# Each start-task-execution call returns a unique execution ARN used for polling.
# ------------------------------------------------------------------------------
declare -A EXEC_MAP
for NAME in "${!TASK_MAP[@]}"; do
  TASK_ARN="${TASK_MAP[${NAME}]}"
  EXEC_ARN=$(aws datasync start-task-execution \
    --task-arn "${TASK_ARN}" \
    --query 'TaskExecutionArn' \
    --output text)
  EXEC_MAP["${NAME}"]="${EXEC_ARN}"
  echo "NOTE: Started ${NAME}"
  echo "      Task:      ${TASK_ARN}"
  echo "      Execution: ${EXEC_ARN}"
  echo ""
done

# ------------------------------------------------------------------------------
# Poll Until All Executions Complete
# Statuses: QUEUED → LAUNCHING → PREPARING → TRANSFERRING → VERIFYING → SUCCESS
# Terminal error state: ERROR
# ------------------------------------------------------------------------------
echo "============================================================================"
echo "DataSync — Waiting for All Tasks to Complete"
echo "============================================================================"
echo ""

ELAPSED=0
while true; do
  ALL_DONE=true

  for NAME in "${!EXEC_MAP[@]}"; do
    EXEC_ARN="${EXEC_MAP[${NAME}]}"
    STATUS=$(aws datasync describe-task-execution \
      --task-execution-arn "${EXEC_ARN}" \
      --query 'Status' \
      --output text 2>/dev/null || echo "UNKNOWN")

    echo "NOTE: ${NAME} — ${STATUS}"

    case "${STATUS}" in
      SUCCESS)
        ;;
      ERROR)
        echo "ERROR: DataSync task ${NAME} failed."
        echo "       Execution ARN: ${EXEC_ARN}"
        exit 1
        ;;
      *)
        ALL_DONE=false
        ;;
    esac
  done

  if [[ "${ALL_DONE}" == "true" ]]; then
    echo ""
    echo "NOTE: All DataSync tasks completed successfully."
    break
  fi

  if [[ "${ELAPSED}" -ge "${MAX_WAIT}" ]]; then
    echo "ERROR: Timed out after ${MAX_WAIT}s waiting for DataSync tasks."
    exit 1
  fi

  sleep "${POLL_INTERVAL}"
  ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
  echo ""
done

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "============================================================================"
echo "DataSync — Transfer Summary"
echo "============================================================================"
echo ""

BUCKET=$(terraform -chdir="${SCRIPT_DIR}/03-datasync" output -raw datasync_bucket_name 2>/dev/null || true)

for NAME in "${!EXEC_MAP[@]}"; do
  EXEC_ARN="${EXEC_MAP[${NAME}]}"
  RESULT=$(aws datasync describe-task-execution \
    --task-execution-arn "${EXEC_ARN}" \
    --query '[Status, Result.TransferredCount, Result.VerifiedCount]' \
    --output text 2>/dev/null || echo "UNKNOWN")
  echo "NOTE: ${NAME} — ${RESULT}"
done

if [[ -n "${BUCKET}" ]]; then
  echo ""
  echo "NOTE: Destination bucket: s3://${BUCKET}"
fi

echo ""
echo "NOTE: Validation complete."
echo ""
