# ClickHouse PostgreSQL Cancel Repro

This reproduces an exception during `KILL QUERY` for a query reading through the `postgresql(...)` table function.

Fix in https://github.com/ClickHouse/ClickHouse/pull/105949

The setup runs PostgreSQL on `127.0.0.1:15431` and a small TCP proxy on `127.0.0.1:15432` using Docker Compose with host networking. The long ClickHouse query connects through the proxy. The repro then closes the proxy listener while keeping the active PostgreSQL connection open, so ClickHouse cannot open PostgreSQL's separate cancel connection when `KILL QUERY` calls `pqxx::connection::cancel_query`.

## Requirements

- Docker Compose
- `python3`
- `ss`
- official ClickHouse binary at `/usr/bin/clickhouse`

You can override the ClickHouse binary path with `CLICKHOUSE=/path/to/clickhouse`.

## Run

```bash
cd /root/git/clickhouse-failure-repro-20260527
./run_repro.sh
```

## Expected Result

On an affected build, `KILL QUERY` loses the ClickHouse connection and the isolated server exits. The script prints a fatal log excerpt like:

```text
pqxx::sql_error, e.what() = PQcancel() -- connect() failed: error 111
pqxx::connection::cancel_query()
DB::PostgreSQLSource<...>::onCancel()
Received signal Aborted (6)
```

Generated ClickHouse data and logs are written under `ch_data/` and `ch_logs/`. The script removes the Docker Compose services on exit.
