#!/usr/bin/env bash

set -e

#-------------------------------------------------------------------------
# Description: this script scans all repositories of an Azure DevOps project and sends its findings in an Azure Application Insights.
#--------------------------------------------------------------------------
usage() {
  echo "usage: $0 -o <organization> -p <project_name> -c <connection_string> -n <event_name>" 1>&2
  echo "where:" 1>&2
  echo "<organization_uri>: Azure DevOps Organization URI" 1>&2
  echo "<project_name>: Azure DevOps Project name" 1>&2
  echo "<connection_string>: Specify the connection string of your Azure Application Insights instance. This is the recommended method as it will point to the correct region and the the instrumentation key method support will end, see https://learn.microsoft.com/azure/azure-monitor/app/migrate-from-instrumentation-keys-to-connection-strings?WT.mc_id=AZ-MVP-5003548." 1>&2
  echo "<event_name>: Specify the name of your custom event." 1>&2
}

while getopts 'o:p:c:n:' OPTS; do
  case "$OPTS" in
  o)
    echo "Using the Azure DevOps Organization URI [$OPTARG] provided as input of this script"
    organization_uri=$OPTARG
    ;;
  p)
    echo "Using the Azure DevOps projet name [$OPTARG] provided as input of this script"
    project_name=$OPTARG
    ;;
  c)
    redacted="$(echo "$OPTARG" | cut -c1-27)-redacted"
    echo "Using the connection string [$redacted] provided as input of this script"
    connection_string="$OPTARG"
    ;;
  n)
    echo "Using the custom event name [$OPTARG] provided as input of this script"
    event_name="$OPTARG"
    ;;
  *)
    usage
    exit 1
    ;;
  esac
done

# Variable
iteration=0
iteration_expiration=0
uuid=$(uuidgen)
operation_id=$(echo "$uuid" | tr '[:upper:]' '[:lower:]')

# Enable scripts to run Git commands, cf https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/git-commands?view=azure-devops&tabs=yaml&WT.mc_id=DOP-MVP-5003548#enable-scripts-to-run-git-commands
if [ ! -z "$GIT_USER_NAME" ] || [ ! -z "$GIT_USER_NAME" ]; then
  echo "Enable scripts to run Git commands for user.email $GIT_USER_EMAIL and user.name $GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  git config --global user.name "$GIT_USER_NAME"
else
  echo "Git user.email and user.name will use the current setting"
fi

# Action
## List Azure DevOps repos
repos=$(az repos list --organization "$organization_uri" --project "$project_name" | jq -r '.[] | @base64')

for repo in $repos; do
  _jqrepo() {
    echo ${repo} | base64 -d | jq -r ${1}
  }
  iteration=$((iteration + 1))
  repo_id=$(_jqrepo '.id')
  repo_name=$(_jqrepo '.name')
  repo_default_branch=$(_jqrepo '.defaultBranch')
  repo_url=$(_jqrepo '.webUrl')

  echo "[$iteration] Repo [$repo_name] with id [$repo_id] has the default branch [$repo_default_branch]"

  latest_ref_id=$(az repos ref list --organization "$organization_uri" \
    --project "$project_name" \
    --repository "$repo_id" \
    --filter heads --query "[?name=='${repo_default_branch}'].objectId" --output tsv)

  echo "[$iteration] Fetching the commit id [$latest_ref_id] of the Repo [$repo_name] on branch [$repo_default_branch]"

  commit=$(az devops invoke \
    --organization "$organization_uri" \
    --area git \
    --resource commits \
    --route-parameters \
    project="$project_name" \
    repositoryId="$repo_id" \
    commitId="$latest_ref_id" | jq -r '.')

  latest_ref_committer_date=$(echo "$commit" | jq -r '.committer.date')
  latest_ref_committer_email=$(echo "$commit" | jq -r '.committer.email')
  latest_ref_committer_name=$(echo "$commit" | jq -r '.committer.name')
  latest_ref_comment=$(echo "$commit" | jq -r '.comment')

  echo "[$iteration] Clone the repo [$repo_url]"

  SOURCE_REPOSITORY_URI_SUFFIX=$(echo ${repo_url//https:\/\//})
  SOURCE_REPOSITORY_URI="https://$AZURE_DEVOPS_EXT_PAT@$SOURCE_REPOSITORY_URI_SUFFIX"

  git clone $SOURCE_REPOSITORY_URI $repo_id

  echo "[$iteration] Scanning the repo [$repo_url] with Gitleaks"

  cd $repo_id

  ../gitleaks/gitleaks detect -v --no-git --exit-code 0 --redact --report-format json --report-path ./gitleaks.json

  for secret in $(cat ./gitleaks.json | jq -r '.[] | @base64'); do
    _jqsecret() {
      echo ${secret} | base64 --decode | jq -r ${1}
    }
    description=$(_jqsecret '.Description')
    start_line=$(_jqsecret '.StartLine')
    file_path=$(_jqsecret '.File')
    rule_id=$(_jqsecret '.RuleID')
    fingerprint=$(_jqsecret '.Fingerprint')

    echo "[$iteration] Sending telemetry events into the Azure Application Insights table [$event_name] for secret start line [$start_line] in file [$file_path] on repo [$repo_name]"

    custom_properties=$(jq -n \
      --arg u "$operation_id" \
      --arg o "$organization_uri" \
      --arg p "$project_name" \
      --arg n "$repo_name" \
      --arg w "$repo_url" \
      --arg b "$repo_default_branch" \
      --arg d "$description" \
      --arg s "$start_line" \
      --arg f "$file_path" \
      --arg i "$rule_id" \
      --arg fp "$fingerprint" \
      --arg rc "$latest_ref_id" \
      --arg cd "$latest_ref_committer_date" \
      --arg cn "$latest_ref_committer_name" \
      --arg cm "$latest_ref_committer_email" \
      '{
            operation_id: $u,
            organization_uri: $o,
            project_name: $p,
            repo_name: $n,
            repo_url: $w,
            git_branch: $b,
            description: $d,
            start_line: $s,
            file_path: $f,
            rule_id: $i,
            fingerprint: $fp,
            ref_commit_id: $rc,
            latest_ref_committer_date: $cd,
            latest_ref_committer_name: $cn,
            latest_ref_committer_email: $cm,
          }')

    base64=$(echo -n "$custom_properties" | base64)

    chmod +x ../send_az_appinsights_event_telemetry.sh
    ../send_az_appinsights_event_telemetry.sh -s "$connection_string" \
      -n "$event_name" \
      -c "${base64}"
  done

  cd ../
  rm -rf $repo_id

done
