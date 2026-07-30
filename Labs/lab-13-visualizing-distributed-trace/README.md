# Lab 13: Visualizing the End-to-End Distributed Trace in Grafana Tempo

Expose the trace ID on the Flask response, open the trace in Grafana, and read the waterfall and service graph to identify the slowest span.

![Architecture](./images/full-system-trace-flow.drawio.svg)

<!-- TODO: drop a real Grafana screenshot here, e.g. ![Tempo waterfall in Grafana](./images/screenshot.png) -->

## What You Will Build

- A Flask endpoint that exposes the trace ID under `X-Trace-ID`.
- A repeatable Tempo search flow by trace ID.
- A latency-injection experiment that confirms where the slow span lives.

## Prerequisites

- Labs 9 through 12 complete: Tempo on `http://localhost:4318`, Grafana on `http://localhost:3001`, Flask + Celery + Redis all running.
- The `trace-lab/` project from Lab 12 with the virtual environment active.

## Step 1 — Restart the stack

Open three terminals in `trace-lab/` with the virtual environment active.

```bash
# terminal 1
redis-server
```

```bash
# terminal 2
celery -A tasks worker --loglevel=info
```
![](./images/output-1.png)

```bash
# terminal 3
export OTEL_SERVICE_NAME=flask-api
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
opentelemetry-instrument --service_name=flask-api \
  flask --app app run --port 8000
```
![](./images/output-2.png)

The Flask API is reachable on `http://localhost:8000`. The worker is consuming tasks from Redis.

## Step 2 — Add the trace ID header to the response

```bash
cat > app.py <<'EOF'
import socket
from flask import Flask, jsonify, request, make_response
from celery import Celery
from tasks import celery_app, process_item
from opentelemetry import trace
from opentelemetry.propagate import inject

flask_app = Flask(__name__)
flask_app.config["CELERY_BROKER_URL"] = "redis://localhost:6379/0"
flask_app.config["CELERY_RESULT_BACKEND"] = "redis://localhost:6379/0"
celery_app.conf.update(broker_url=flask_app.config["CELERY_BROKER_URL"])
tracer = trace.get_tracer(__name__)

@flask_app.post("/process")
def enqueue_process():
    item_id = request.json.get("item_id")
    carrier = {}
    inject(carrier)
    process_item.delay(item_id, carrier=carrier)
    span = trace.get_current_span()
    trace_id_hex = format(span.get_span_context().trace_id, "032x")
    response = make_response(jsonify({"task_id": "...", "trace_id": trace_id_hex}))
    response.headers["X-Trace-ID"] = trace_id_hex
    return response
EOF
```

`format(..., "032x")` produces a 32-character lowercase hex string. Setting it as a header makes the value reachable by any HTTP client.

## Step 3 — Trigger the request and capture the header

```bash
curl -i -X POST http://localhost:8000/process \
  -H "Content-Type: application/json" \
  -d '{"item_id": 7}'
```
![](./images/output-3.png)

Save the `X-Trace-ID` value from the response headers.

## Step 4 — Open the trace in Grafana

Open `http://localhost:3001/explore`, pick the Tempo datasource, switch to **Search**, paste the trace ID, and click **Run query**.
![](./images/output-4.png)

The waterfall opens with two rows: `POST /process` as the root and `celery-process` as the child.

## Step 5 — Read the waterfall

The bar width is the span duration. The widest bar in the trace is the slowest operation. Click any bar to expand its attributes.
![](./images/output-5.png)

The `celery-process` bar is wider than the Flask bar. The worker is the slow part, not the API.

## Step 6 — Inject latency and confirm attribution

Add `time.sleep(2)` inside `do_work` in `tasks.py`, restart the worker, and trigger another request.

```bash
curl -i -X POST http://localhost:8000/process \
  -H "Content-Type: application/json" \
  -d '{"item_id": 99}'
```
![](./images/output-6.png)

Paste the new `X-Trace-ID` into Tempo. The `celery-process` bar is now the widest by far. The latency is attributed to the worker, where it happened. Remove the `sleep` after observing.

## Checkpoint

- [ ] The Flask response carries an `X-Trace-ID` header with a 32-character hex value.
- [ ] Tempo search by trace ID returns a single trace with two spans.
- [ ] The widest bar in the baseline trace is `celery-process`.
- [ ] After injecting `time.sleep(2)`, the worker span dominates the waterfall.

## Next Steps

Stop the worker and API with `Ctrl+C`. The Labs 9–13 series now answers "why is this request slow?" from a single trace ID. The next module covers metrics and logs with Prometheus and Loki.