#!/bin/sh
set -eu
for app in ssh telnet sqlite python; do
  ruby /opt/playground/dialogues.rb "$app"
done
ruby /opt/playground/failure_checks.rb
ruby /src/examples/local_replay.rb
ruby /src/applications/routers/examples/local_router.rb
