# Lab 11: Adding Manual Spans and Custom Attributes

Wrap a Flask route in `tracer.start_as_current_span`, attach domain attributes, and nest child spans to model a multi-step workflow.

![Architecture](./images/span-hierarchy.drawio.svg)

## What You Will Build

- A Flask route with a root `handle_request` span.
- Custom attributes such as `user.id`, `request.id`, and `db.query_time_ms`.
- Two nested child spans: `db_lookup` and `cache_check`.

## Prerequisites

- Lab 9 stack running locally (Tempo on 4318, Grafana on 3001) **and** exposed through the lab load balancer.
- Lab 10 project (`lab-10-otel-python-instrumentation`) with its virtual environment active.
- Python 3.10 or newer.

## Step 1 — Copy the Lab 10 project forward

```bash
cp -r lab-10-otel-python-instrumentation lab-11-manual-spans
cd lab-11-manual-spans
source .venv/bin/activate
```

On Windows, use `.venv\Scripts\activate`. Tempo and Grafana should still be reachable from Lab 9.

## Step 2 — Add a root span with custom attributes

```bash
cat > app.py <<'EOF'
import time
from flask import Flask
from opentelemetry import trace

app = Flask(__name__)
tracer = trace.get_tracer(__name__)

@app.get("/hello")
def hello():
    user_id = "u-42"
    request_id = "r-1001"
    with tracer.start_as_current_span("handle_request") as span:
        span.set_attribute("user.id", user_id)
        span.set_attribute("request.id", request_id)
        start = time.perf_counter()
        time.sleep(0.05)
        elapsed_ms = (time.perf_counter() - start) * 1000
        span.set_attribute("db.query_time_ms", round(elapsed_ms, 2))
        return {"message": "hello from instrumented api"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF
```

`start_as_current_span` activates the span for the duration of the `with` block. Any nested spans created inside automatically attach as children. `set_attribute` accepts strings, numbers, and booleans.

## Step 3 — Expose the Flask port through the load balancer

Open the **Load Balancer** modal in the lab UI. Run this once to find the IP to enter:

```bash
hostname -I
```

Use the **first** IP printed as `LB_IP`. Expose:

| Enter IP | Enter Port |
|---|---|
| `LB_IP` | `5000` (Flask API) |

Lab 9 must already have exposed `4318`, `3200`, and `3001` for the rest of this lab to work.

## Step 4 — Run the app and trigger a request

```bash
export OTEL_SERVICE_NAME=my-api
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

opentelemetry-instrument \
    --service_name my-api \
    --exporter_otlp_endpoint http://localhost:4318 \
    --exporter_otlp_protocol http/protobuf \
    -- python -m flask run --host=0.0.0.0 --port=5000
```
```bash
curl http://<LB_IP>:5000/hello
```
![](./images/output-1.png)

The Flask handler returns the JSON payload. The wrapper exports the trace to Tempo.

## Step 5 — Verify the span in Grafana

Open `http://<LB_IP>:3001`, click Explore, pick the `Tempo` datasource, switch to **Search**, enter `my-api`, and click **Run query**.
![](./images/output-2.png)

The `handle_request` span should appear with `user.id`, `request.id`, and `db.query_time_ms` in its attribute panel.

## Step 6 — Add nested child spans

```bash
cat > app.py <<'EOF'
import time
from flask import Flask
from opentelemetry import trace

app = Flask(__name__)
tracer = trace.get_tracer(__name__)

@app.get("/hello")
def hello():
    user_id = "u-42"
    request_id = "r-1001"
    with tracer.start_as_current_span("handle_request") as root:
        root.set_attribute("user.id", user_id)
        root.set_attribute("request.id", request_id)

        with tracer.start_as_current_span("db_lookup") as db:
            start = time.perf_counter()
            time.sleep(0.03)
            elapsed_ms = (time.perf_counter() - start) * 1000
            db.set_attribute("db.query_time_ms", round(elapsed_ms, 2))
            db.set_attribute("db.system", "postgres")

        with tracer.start_as_current_span("cache_check") as cache:
            start = time.perf_counter()
            time.sleep(0.01)
            elapsed_ms = (time.perf_counter() - start) * 1000
            cache.set_attribute("cache.lookup_time_ms", round(elapsed_ms, 2))
            cache.set_attribute("cache.hit", False)

        return {"message": "hello from instrumented api"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF
```

Inner `start_as_current_span` calls attach to the currently active span. The `db_lookup` and `cache_check` spans become siblings under `handle_request`.

## Step 7 — Verify the waterfall

Restart the wrapped Flask process, trigger one request through the load balancer, and reload the trace in Grafana.

```bash
curl http://<LB_IP>:5000/hello
```
![](./images/output-3.png)

The waterfall should show three rows: `handle_request` at the top, then `db_lookup` and `cache_check` indented underneath.

## Next Steps

Stop the wrapped process with `Ctrl+C`. Remove the `5000` port from the Load Balancer modal. Lab 12 propagates the trace context from a Flask request into a Celery worker over Redis.