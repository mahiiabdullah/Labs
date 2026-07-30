# Lab 12: Propagating Trace Context from Flask to Celery

Inject the active trace context from a Flask endpoint into a Celery task and extract it in the worker so both spans share one trace ID.

![Architecture](./images/trace-propagation-flow.drawio.svg)

<!-- TODO: drop a real terminal screenshot here, e.g. ![Celery worker consuming task](./images/screenshot.png) -->

## What You Will Build

- A Flask API that enqueues Celery tasks through Redis.
- `propagate.inject(carrier)` in the Flask route and `propagate.extract(carrier)` in the worker.
- One trace in Tempo that contains both the Flask span and the worker span.

## Prerequisites

- Lab 9 stack running on `http://localhost:4318` and `http://localhost:3001`.
- Lab 10 API exported to the same Tempo.
- Redis running on `localhost:6379`.
- Python 3.10 or newer with pip.

## Step 1 — Create the project

```bash
mkdir trace-lab && cd trace-lab
python -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
```

```bash
cat > requirements.txt <<'EOF'
flask==3.0.3
celery==5.4.0
redis==5.0.4
opentelemetry-api==1.27.0
opentelemetry-sdk==1.27.0
opentelemetry-exporter-otlp-proto-http==1.27.0
opentelemetry-instrumentation-flask==0.48b0
opentelemetry-instrumentation-celery==0.48b0
EOF
```

```bash
pip install -r requirements.txt
```

The packages give you the propagation API, both instrumentations, and the OTLP exporter.

## Step 2 — Configure Celery with Redis

```bash
cat > tasks.py <<'EOF'
import socket
from celery import Celery
from opentelemetry import trace
from opentelemetry.propagate import extract

celery_app = Celery("trace-lab", broker="redis://localhost:6379/0", backend="redis://localhost:6379/0")
tracer = trace.get_tracer(__name__)

@celery_app.task(name="trace-lab.process_item")
def process_item(item_id, carrier=None):
    ctx = extract(carrier)
    with tracer.start_as_current_span("celery-process", context=ctx) as span:
        span.set_attribute("item.id", item_id)
        span.set_attribute("worker.hostname", socket.gethostname())
        result = do_work(item_id)
        span.set_attribute("result.size", len(result))
        return result

def do_work(item_id):
    return f"processed {item_id}"
EOF
```

`extract(carrier)` reads the W3C `traceparent` header from the carrier dict and rebuilds a `Context`. Passing `context=ctx` to `start_as_current_span` makes the new span a child of the original Flask span.

## Step 3 — Build the Flask API with inject

```bash
cat > app.py <<'EOF'
from flask import Flask, jsonify, request
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
    task_result = process_item.delay(item_id, carrier=carrier)
    return jsonify({
        "task_id": task_result.id,
        "trace_id": format(trace.get_current_span().get_span_context().trace_id, "032x"),
    })
EOF
```

`inject(carrier)` writes a single `traceparent` entry into the carrier dict. The carrier travels through Redis as a task kwarg.

## Step 4 — Start Redis, the worker, and the API

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

The worker should print `ready`. The Flask API should answer on `http://localhost:8000`.

## Step 5 — Trigger a request

```bash
curl -i -X POST http://localhost:8000/process \
  -H "Content-Type: application/json" \
  -d '{"item_id": 42}'
```
![](./images/output-3.png)

Save the `trace_id` from the JSON body. Both spans will share this ID.

## Step 6 — Verify a single trace in Tempo

Open `http://localhost:3001`, choose the Tempo datasource, switch to **Search**, paste the `trace_id`, and click **Run query**.
![](./images/output-4.png)

Exactly two spans appear: `POST /process` as the root and `celery-process` as a child with `item.id` and `worker.hostname` attributes.

## Checkpoint

- [ ] Redis is running and the worker reports `ready`.
- [ ] The Flask API responds on `http://localhost:8000/process`.
- [ ] `curl` returns a 32-character hex `trace_id`.
- [ ] Tempo search by `trace_id` returns one trace with both `POST /process` and `celery-process`.

## Next Steps

Stop the worker and API with `Ctrl+C`. Lab 13 exposes the trace ID on the response header and uses the service graph to read aggregate latency.