#!/bin/bash
# Restart Jac ML Studio so it picks up the current code and deps in this checkout.
cd "$(dirname "$0")"
sleep 1
lsof -ti :8400 | xargs kill 2>/dev/null
lsof -ti :3000 | xargs kill 2>/dev/null
sleep 1
(cd server && .venv/bin/pip install -q -r requirements.txt) >> /tmp/jacmlstudio-update.log 2>&1
(cd ui && npm install --silent) >> /tmp/jacmlstudio-update.log 2>&1
nohup ./start.sh > /tmp/jacmlstudio.log 2>&1 &
