#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLICKHOUSE="${CLICKHOUSE:-/usr/bin/clickhouse}"

cd "$SCRIPT_DIR"

cleanup()
{
    if [ -f ch.pid ]
    then
        pid="$(cat ch.pid 2>/dev/null || true)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
        then
            args="$(ps -p "$pid" -o args= 2>/dev/null || true)"
            if [[ "$args" == *"$CLICKHOUSE server"* && "$args" == *"$SCRIPT_DIR/ch_data/"* ]]
            then
                kill "$pid" >/dev/null 2>&1 || true
            fi
        fi
    fi

    docker compose down -v >/dev/null 2>&1 || true
}

trap cleanup EXIT

docker compose down -v >/dev/null 2>&1 || true
docker compose up -d

rm -rf ch_data ch_logs
mkdir -p ch_data/tmp ch_data/user_files ch_data/format_schemas ch_logs
rm -f long.out long.err kill.out kill.err

"$CLICKHOUSE" server \
    --config-file="$SCRIPT_DIR/clickhouse-config.xml" \
    --daemon \
    --log-file="$SCRIPT_DIR/ch_logs/clickhouse-server.log" \
    --errorlog-file="$SCRIPT_DIR/ch_logs/clickhouse-server.err.log" \
    --pid-file="$SCRIPT_DIR/ch.pid" \
    -- \
    --path="$SCRIPT_DIR/ch_data/" \
    --tmp_path="$SCRIPT_DIR/ch_data/tmp/" \
    --user_files_path="$SCRIPT_DIR/ch_data/user_files/" \
    --format_schema_path="$SCRIPT_DIR/ch_data/format_schemas/" \
    --tcp_port=19000 \
    --http_port=18123 \
    --interserver_http_port=19009 \
    --listen_host=127.0.0.1 \
    --logger.level=test

clickhouse_ready=0
for _ in $(seq 1 30)
do
    if "$CLICKHOUSE" client --port 19000 --query "SELECT 1" >/dev/null 2>&1
    then
        clickhouse_ready=1
        break
    fi
    sleep 1
done

if [ "$clickhouse_ready" = 0 ]
then
    echo "ClickHouse did not become ready on port 19000" >&2
    exit 1
fi

proxy_ready=0
for _ in $(seq 1 30)
do
    if python3 - <<'PY' >/dev/null 2>&1
import socket
with socket.create_connection(("127.0.0.1", 15433), timeout=1):
    pass
PY
    then
        proxy_ready=1
        break
    fi
    sleep 1
done

if [ "$proxy_ready" = 0 ]
then
    echo "Proxy control port did not become ready on 127.0.0.1:15433" >&2
    exit 1
fi

"$CLICKHOUSE" client --port 19000 --query_id repro_pg_cancel \
    --query "SELECT count() FROM postgresql('127.0.0.1:15432', 'postgres_database', 'sleepy_view', 'postgres', 'clickhouse')" \
    > long.out 2> long.err &

query_running=0
for _ in $(seq 1 30)
do
    if [ "$("$CLICKHOUSE" client --port 19000 --query "SELECT count() FROM system.processes WHERE query_id = 'repro_pg_cancel'")" = "1" ]
    then
        query_running=1
        break
    fi
    sleep 1
done

if [ "$query_running" = 0 ]
then
    echo "PostgreSQL table function query did not start" >&2
    cat long.err >&2 || true
    exit 1
fi

python3 - <<'PY'
import socket
s = socket.create_connection(("127.0.0.1", 15433), timeout=5)
s.sendall(b"close_listener\n")
print(s.recv(1024).decode(), end="")
s.close()
PY

listener_closed=0
for _ in $(seq 1 30)
do
    if ! ss -ltn | grep -q ':15432\b'
    then
        listener_closed=1
        break
    fi
    sleep 1
done

if [ "$listener_closed" = 0 ]
then
    echo "Proxy data listener is still open on 127.0.0.1:15432" >&2
    exit 1
fi

set +e
"$CLICKHOUSE" client --port 19000 --query "KILL QUERY WHERE query_id = 'repro_pg_cancel' SYNC" > kill.out 2> kill.err
kill_exit=$?
"$CLICKHOUSE" client --port 19000 --query "SELECT 1" >/dev/null 2>&1
server_alive=$?
set -e

echo "KILL QUERY exit code: $kill_exit"
echo "Post-KILL SELECT 1 exit code: $server_alive"
echo
echo "Fatal log excerpt:"
grep -nE "Terminate called|pqxx::sql_error|cancel_query|PostgreSQLSource|Received signal Aborted|std::terminate" ch_logs/clickhouse-server.log | tail -40 || true
echo
echo "KILL QUERY stderr:"
cat kill.err || true
