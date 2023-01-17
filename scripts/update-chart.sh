#!/usr/bin/env bash

# update-chart.sh handles creating a new version of the parent chart, updating
# its dependencies and pushing the chart into the repository.

# In order to compare chart dependencies, we transform the information into a
# JSON map of service to version. Then we can use jq, which has more powerful
# comparison operators than bash to determine the difference.

set -Eeo pipefail

USAGE="
Usage:
  $(basename "$0")

Environment variables:
  COMMIT_TARGET_BRANCH: Name of the GitHub branch where the committed changes
                        will be pushed. Defaults to 'main'
  GITHUB_ORG:           Name of the GitHub organisation where committed changes
                        to the chart will be pushed.
                        Defaults to 'aws-controllers-k8s'
  GITHUB_REPO:          Name of the GitHub repository where committed changes to
                        the chart will be pushed.
                        Defaults to 'ack-parent-chart'
  GITHUB_TOKEN:        Personal Access Token for '$GITHUB_ACTOR'
"

SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
ROOT_DIR="$SCRIPTS_DIR/.."
WORKSPACE_DIR="$ROOT_DIR/.."

TEST_INFRA_LIB_DIR="$WORKSPACE_DIR/test-infra/scripts/lib"

PARENT_CHART_CONFIG="$ROOT_DIR/Chart.yaml"

LOCAL_GIT_BRANCH="main"

DEFAULT_GITHUB_ORG="aws-controllers-k8s"
GITHUB_ORG=${GITHUB_ORG:-$DEFAULT_GITHUB_ORG}

DEFAULT_GITHUB_REPO="ack-parent-chart"
GITHUB_REPO=${GITHUB_REPO:-$DEFAULT_GITHUB_REPO}

DEFAULT_COMMIT_TARGET_BRANCH="main"
COMMIT_TARGET_BRANCH=${COMMIT_TARGET_BRANCH:-$DEFAULT_COMMIT_TARGET_BRANCH}

# DEPENDENCY_DIFF is an enumeration for storing how the chart depedencies have
# changed between the last and current versions of the parent chart. Storing the
# values as integers allows the script to compare values using mathematical
# operators.
DEPENDENCY_DIFF_PATCH="0"
DEPENDENCY_DIFF_MINOR="1"
DEPENDENCY_DIFF_MAJOR="2"

source "$TEST_INFRA_LIB_DIR/common.sh"

_upgrade_dependency_and_chart_versions() {
    local parent_chart_diff="$DEPENDENCY_DIFF_PATCH"

    pushd "$WORKSPACE_DIR" >/dev/null
        local controller_names=$(find . -maxdepth 1 -name "*-controller" -type d | cut -d"/" -f2)
    popd >/dev/null

    for controller_name in $controller_names; do
        local service_name=$(echo "$controller_name"| sed 's/-controller$//g')
        local controller_dir="$WORKSPACE_DIR/$controller_name"

        local controller_chart="$controller_dir/helm/Chart.yaml"
        if [[ ! -f "$controller_chart" ]]; then
            continue
        fi

        # Determine if the chart is in GA
        chart_major_version="$(yq '.version | split(".") | .[0] | sub("v(\d+)", "$1")' $controller_chart)"
        [[ "$chart_major_version" == "0" ]] && continue

        chart_name="$(yq '.name' $controller_chart)"
        chart_version="$(yq '.version' $controller_chart)"

        local existing_version="$(_get_chart_dependency_version $chart_name)"
        if [[ "$existing_version" == "" ]]; then
            echo -e "Adding $chart_name as a new dependency \t $chart_version"

            _add_chart_dependency $chart_name $chart_version $service_name

            # For new chart dependencies, upgrade the minor version
            parent_chart_diff="$DEPENDENCY_DIFF_MINOR"

        elif [[ "$existing_version" != "$chart_version" ]]; then
            echo -e "Upgrading $chart_name \t $chart_version"

            _upgrade_chart_dependency $chart_name $chart_version $service_name

            # Determine the difference in semver
            local semver_diff="$(_get_semver_diff $existing_version $chart_version)"
            if [[ "$semver_diff" -gt "$parent_chart_diff" ]]; then
                parent_chart_diff="$semver_diff"
            fi
        fi
    done
    
    local current_chart_version="$(yq '.version' $PARENT_CHART_CONFIG)"
    local new_chart_version="$(_increment_chart_version $current_chart_version $parent_chart_diff)"

    echo "Updating chart from version $current_chart_version to $new_chart_version"

    VERSION="$new_chart_version" yq --inplace '.version = env(VERSION)' $PARENT_CHART_CONFIG
}

_get_chart_dependency_version() {
    local __dependency_name=$1

    local dependency_version="$(NAME=$__dependency_name yq '.dependencies[] | select(.name == env(NAME)) | .version' $PARENT_CHART_CONFIG)"
    echo "$dependency_version"
}

_get_semver_diff() {
    local __current_version=$1
    local __new_version=$2

    local trimmed_current="$(echo "$__current_version" | cut -c2-)"
    local trimmed_new="$(echo "$__new_version" | cut -c2-)"

    if [[ "$(echo "$trimmed_current" | cut -d"." -f1)" != "$(echo "$trimmed_new" | cut -d"." -f1)" ]]; then
        echo "$DEPENDENCY_DIFF_MAJOR"
    elif [[ "$(echo "$trimmed_current" | cut -d"." -f2)" != "$(echo "$trimmed_new" | cut -d"." -f2)" ]]; then
        echo "$DEPENDENCY_DIFF_MINOR"
    elif [[ "$(echo "$trimmed_current" | cut -d"." -f3)" != "$(echo "$trimmed_new" | cut -d"." -f3)" ]]; then
        echo "$DEPENDENCY_DIFF_PATCH"
    else
        echo ""
    fi
}

_increment_chart_version() {
    local __current_version=$1
    local __patch_diff=$2

    local current_major="$(echo "$__current_version" | cut -d"." -f1)"
    local current_minor="$(echo "$__current_version" | cut -d"." -f2)"
    local current_patch="$(echo "$__current_version" | cut -d"." -f3)"

    # Increment the largest diff number and reset any smaller parts
    if [[ "$__patch_diff" == "$DEPENDENCY_DIFF_PATCH" ]]; then
        current_patch="$((current_patch + 1))"
    elif [[ "$__patch_diff" == "$DEPENDENCY_DIFF_MINOR" ]]; then
        current_patch="0"
        current_minor="$((current_minor + 1))"
    elif [[ "$__patch_diff" == "$DEPENDENCY_DIFF_MAJOR" ]]; then
        current_patch="0"
        current_minor="0"
        current_major="$((current_major + 1))"
    fi

    echo "${current_major}.${current_minor}.${current_patch}"
}

_add_chart_dependency() {
    local __dependency_name=$1
    local __dependency_version=$2
    local __service_name=$3

    NAME=$__dependency_name SERVICE_NAME=$__service_name VERSION=$__dependency_version \
    yq --inplace '.dependencies += {
        "name": env(NAME),
        "alias": env(SERVICE_NAME),
        "version": env(VERSION),
        "repository": "oci://public.ecr.aws/aws-controllers-k8s",
        "condition": (env(SERVICE_NAME) + ".enabled")
    }' $PARENT_CHART_CONFIG
}

_upgrade_chart_dependency() {
    local __dependency_name=$1
    local __dependency_version=$2
    local __service_name=$3

    NAME=$__dependency_name yq --inplace 'del(.dependencies[] | select(.name == env(NAME)))' $PARENT_CHART_CONFIG

    _add_chart_dependency $__dependency_name $__dependency_version $__service_name
}

_rebuild_chart_dependencies() {
    local ecr_pw=$(aws ecr-public get-login-password --region us-east-1)
    echo "$ecr_pw" | helm registry login -u AWS --password-stdin public.ecr.aws

    helm dependency update
}

_commit_chart_changes() {
    echo "Adding git remote ... "
    git remote add upstream "https://github.com/$GITHUB_ORG/$GITHUB_REPO.git" >/dev/null || :

    git fetch --all >/dev/null
    git checkout -b $COMMIT_TARGET_BRANCH upstream/$COMMIT_TARGET_BRANCH >/dev/null || :

    # Add all the files & create a GitHub commit
    git add .
    COMMIT_MSG="Updating chart dependencies" # TODO: Add a more descriptive commit message using the version diffs
    echo "Adding commit with message: '$COMMIT_MSG' ... "
    git commit -m "$COMMIT_MSG" >/dev/null

    git pull --rebase

    echo "Pushing changes to branch '$COMMIT_TARGET_BRANCH' ... "
    git push "https://$GITHUB_TOKEN@github.com/$GITHUB_ORG/$GITHUB_REPO.git" "$LOCAL_GIT_BRANCH:$COMMIT_TARGET_BRANCH" 2>&1
}

run() {
    # Upgrade all the version numbers
    _upgrade_dependency_and_chart_versions

    # Rebuild the chart
    _rebuild_chart_dependencies

    # Create a new commit and push the changes
    _commit_chart_changes

    exit 0
}

ensure_binaries() {
    check_is_installed "jq"
    check_is_installed "yq"
    check_is_installed "helm"
}

ensure_binaries

# The purpose of the `return` subshell command in this script is to determine
# whether the script was sourced, or whether it is being executed directly.
# https://stackoverflow.com/a/28776166
(return 0 2>/dev/null) || run