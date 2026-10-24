#!/bin/sh
# ci-annotate.sh — the last lines of a failed CI step's output, as one GitHub error annotation. Downloading a job's log
# through the API takes a token with admin rights; a check run's annotations take none, so a failure can be read from
# anywhere (GET /repos/cosmic-canopy/kama-postgres/check-runs/<job id>/annotations).
#
#   tools/ci-annotate.sh <output file> [lines]     60 lines by default
set -eu
file=${1:?usage: tools/ci-annotate.sh <output file> [lines]}
lines=${2:-60}
[ -f "$file" ] || exit 0
# An annotation's message is one line: a newline is %0A, so a literal % is %25. A CR is dropped.
message=$(tail -n "$lines" "$file" | tr -d '\r' | sed -e 's/%/%25/g' | awk '{ printf "%s%%0A", $0 }')
echo "::error title=The failed step's last lines::$message"
