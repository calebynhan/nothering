#!/bin/bash
# Publishes a run's summary and errors as the only commit of a branch, ci-logs-<name>, so they can
# be read with git alone. A run's own log needs a download that not every reader can make.
#   scripts/ci/publish-logs.sh <name> <output dir of the run>
set -u
name=$1
from=$2
[[ -n ${GITHUB_REPOSITORY:-} && -n ${GH_TOKEN:-} ]] || { echo "not on GitHub, nothing to publish"; exit 0; }
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

{
  echo "run: https://github.com/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-}"
  echo "commit: ${GITHUB_SHA:-}"
  echo "job: $name"
} > "$work/run.txt"
if [[ -d $from ]]; then
  # The summary, each step's errors, the end of each step's log, and anything that is plain text.
  find "$from" -maxdepth 1 -type f \( -name '*.txt' -o -name '*.json' \) -size -512k -exec cp {} "$work/" \;
  if [[ -d $from/logs ]]; then
    mkdir "$work/logs"
    for log in "$from"/logs/*.log; do
      [[ -f $log ]] || continue
      step=$(basename "$log" .log)
      [[ -f $from/logs/$step.errors.txt ]] && cp "$from/logs/$step.errors.txt" "$work/logs/"
      tail -150 "$log" > "$work/logs/$step.tail.txt"
      # The whole log too, when it is small enough to keep the branch light.
      if (( $(wc -c < "$log") < 3000000 )); then
        gzip -c "$log" > "$work/logs/$step.log.gz"
      fi
    done
  fi
else
  echo "the run left no $from" >> "$work/run.txt"
fi

cd "$work" || exit 1
git init -q
git checkout -q --orphan logs
git add -A
git -c user.name="github-actions[bot]" -c user.email="github-actions[bot]@users.noreply.github.com" \
  commit -q -m "Logs of ${GITHUB_SHA:-a run}, $name"
# Publishing the logs must not turn a passing run into a failing one.
git push -q -f "https://x-access-token:$GH_TOKEN@github.com/$GITHUB_REPOSITORY.git" "HEAD:refs/heads/ci-logs-$name" \
  || echo "::warning::the logs weren't published"
