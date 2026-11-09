#!/usr/bin/env bash
TOKEN=amr-dev-token
URL=http://127.0.0.1:8080/api/v1/map/meta
echo "T0:"
curl -s -H "Authorization: Bearer $TOKEN" "$URL"
echo
sleep 15
echo "T15:"
curl -s -H "Authorization: Bearer $TOKEN" "$URL"
echo
echo "STDOUT_TAIL:"
tail -6 /tmp/amr_probe/gateway_stdout.log
