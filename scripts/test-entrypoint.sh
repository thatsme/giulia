#!/bin/sh
# Test entrypoint for docker-compose.test.yml
# Forwards all arguments to `mix test` inside /projects/Giulia
set -e

cd /projects/Giulia
mix deps.get --only test > /dev/null 2>&1
exec mix test "$@"
