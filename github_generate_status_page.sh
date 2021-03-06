#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2020-02-07 15:01:31 +0000 (Fri, 07 Feb 2020)
#
#  https://github.com/harisekhon/bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/harisekhon
#

# Script to generate GIT_STATUS.md containing the headers and status badges of the Top N rated by stars GitHub repos across all CI platforms on a single page
#
# Usage:
#
# without arguments queries for all non-fork repos for your $GITHUB_USER and iterate them up to $top_N to generate the page
#
#   GITHUB_USER=HariSekhon ./github_generate_status_page.sh
#
# with arguments will query those repo's README.md at the top level - if omitting the prefix will prepend $GITHUB_USER/
#
#   GITHUB_USER=HariSekhon ./github_generate_status_page.sh  HariSekhon/DevOps-Python-tools  HariSekhon/DevOps-Perl-tools
#
#   GITHUB_USER=HariSekhon ./github_generate_status_page.sh  DevOps-Python-tools  DevOps-Perl-tools
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(dirname "$0")"

trap 'echo ERROR >&2' exit

file="GIT_STATUS.md"

top_N=100

repolist="$*"

# this leads to confusion as it generates some randomly unexpected output by querying a github user who happens to have the same name as your local user eg. hari, so force explicit now
#USER="${GITHUB_USER:-${USERNAME:-${USER}}}"
if [ -z "${GITHUB_USER:-}" ] ; then
    echo "\$GITHUB_USER not set!"
    exit 1
fi

get_repos(){
    page=1
    while true; do
        echo "fetching repos page $page" >&2
        if ! output="$("$srcdir/github_api.sh" "/users/$GITHUB_USER/repos?page=$page&per_page=100")"; then
            echo "ERROR" >&2
            exit 1
        fi
        # use authenticated requests if you are hitting the API rate limit - this is automatically done above now if USER/PASSWORD GITHUB_USER/GITHUB_PASSWORD/GITHUB_TOKEN environment variables are detected
        # eg. CURL_OPTS="-u harisekhon:$GITHUB_TOKEN" ...
        # shellcheck disable=SC2086
        if [ -z "$(jq '.[]' <<< "$output")" ]; then
            break
        elif jq -r '.message' <<< "$output" >&2 2>/dev/null; then
            exit 1
        fi
        jq -r '.[] | select(.fork | not) | select(.private | not) | [.full_name, .stargazers_count, .forks] | @tsv' <<< "$output"
        ((page+=1))
    done
}

original_sources=0

if [ -z "$repolist" ]; then
    repolist="$(get_repos | grep -v spark-apps | sort -k2nr -k3nr | awk '{print $1}' | head -n "$top_N")"
    original_sources=1
fi

num_repos="$(wc -w <<< "$repolist")"
num_repos="${num_repos// /}"

#echo "$repolist" >&2

# make portable between linux and mac
head(){
    if [ "$(uname -s)" = Darwin ]; then
        # from brew's coreutils package (installed by 'make')
        ghead "$@"
    else
        command head "$@"
    fi
}

tempfile="$(mktemp)"
trap 'echo ERROR >&2; rm -f $tempfile' exit

{
actual_repos=0

for repo in $repolist; do
    if ! [[ "$repo" =~ / ]]; then
        repo="$GITHUB_USER/$repo"
    fi
    echo "getting github repo $repo" >&2
    echo "---"
    #perl -e '$/ = undef; my $content=<STDIN>; $content =~ s/<!--[^>]+-->//gs; print $content' |
    curl -sS "https://raw.githubusercontent.com/$repo/master/README.md" |
    perl -pe '$/ = undef; s/<!--[^>]+-->//gs' |
    sed -n '1,/^[^\[[:space:]<=-]/ p' |
    head -n -1 |
    #perl -ne 'print unless /=============/;' |
    grep -v "===========" |
    sed '1 s/^[^#]/# &/' |
    # \\ escapes the newlines to allow them inside the sed for literal replacement since \n doesn't work
    sed "2 s|^|\\
Link:  [$repo](https://github.com/$repo)\\
\\
|"
    echo
    ((actual_repos+=1))
done
} > "$tempfile"

if [ "$num_repos" != "$actual_repos" ]; then
    echo "ERROR: differing number of target github repos ($num_repos) vs actual repos ($actual_repos)"
    exit 1
fi

hosted_build_regex='travis-ci.+\.svg'
hosted_build_regex+='|github\.com/.+/workflows/.+/badge\.svg'
hosted_build_regex+='|dev\.azure\.com/.+/_apis/build/status'
hosted_build_regex+='|app\.codeship\.com/projects/.+/status'
hosted_build_regex+='|appveyor\.com/api/projects/status'
hosted_build_regex+='|circleci\.com/.+\.svg'
hosted_build_regex+='|cloud\.drone\.io/api/badges/.+/status.svg'
hosted_build_regex+='|g\.codefresh\.io/api/badges/pipeline/'
hosted_build_regex+='|api\.shippable\.com/projects/.+/badge'
hosted_build_regex+='|app\.wercker\.com/status/'
hosted_build_regex+='|img\.shields\.io/.+/pipeline'
hosted_build_regex+='|img\.shields\.io/.+/build/'
hosted_build_regex+='|img\.shields\.io/buildkite/'
hosted_build_regex+='|img\.shields\.io/cirrus/'
hosted_build_regex+='|img\.shields\.io/docker/build/'
hosted_build_regex+='|img\.shields\.io/docker/cloud/build/'
hosted_build_regex+='|img\.shields\.io/travis/'
hosted_build_regex+='|img\.shields\.io/shippable/'

self_hosted_build_regex='\[\!\[[^]]+\]\(.*\)\]\(.*/blob/master/('
self_hosted_build_regex+='Jenkinsfile'
self_hosted_build_regex+='|.concourse.yml'
self_hosted_build_regex+='|.gocd.yml'
self_hosted_build_regex+=')\)'

if [ -n "${DEBUG:-}" ]; then
    echo
    echo "Hosted Builds:"
    echo
    grep -E "$hosted_build_regex" "$tempfile" >&2 || :
    echo
    echo "Self-Hosted Builds:"
    echo
    grep -E "$self_hosted_build_regex" "$tempfile" >&2 || :
fi
num_hosted_builds="$(grep -Ec "$hosted_build_regex" "$tempfile" || :)"
num_self_hosted_builds="$(grep -Ec "$self_hosted_build_regex" "$tempfile" || :)"

num_builds=$((num_hosted_builds + num_self_hosted_builds))

{
cat <<EOF
# GitHub Status Page

generated by \`${0##*/}\` in [HariSekhon/DevOps-Bash-tools](https://github.com/HariSekhon/DevOps-Bash-tools)

This page usually loads better on [BitBucket](https://bitbucket.org/harisekhon/devops-bash-tools/src/master/STATUS.md) due to less aggressive proxy timeouts cutting off badge loading than GitHub / GitLab

EOF
printf "%s " "$num_repos"
if [ "$original_sources" = 1 ]; then
    printf "original source "
fi
printf 'git repos with %s CI builds (%s hosted, %s self-hosted):\n\n' "$num_builds" "$num_hosted_builds" "$num_self_hosted_builds"
cat "$tempfile"
printf '\n%s git repos summarized with %s CI builds(%s hosted, %s self-hosted)\n' "$actual_repos" "$num_builds" "$num_hosted_builds" "$num_self_hosted_builds"
} | tee "$file"

trap '' exit
