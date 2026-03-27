#!/usr/bin/env bash
# Post-add hook: trigger the queue runner in the background.
# The runner's flock ensures only one instance runs at a time,
# so duplicate triggers from rapid q-add calls are safe to ignore.
nohup /Users/user/dev/queue/queue-runner.sh >/dev/null 2>&1 &
disown
