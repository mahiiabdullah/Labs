# Lab 12 — Propagating Trace Context from Flask to Celery

## Introduction

In the previous labs a single trace was shipped from a Flask request into Tempo. Now the request hands work to a background worker, and the worker span should live **inside the same trace** as the Flask span — not as a separate, orphaned trace.

The mechanism for that is **context propagation**: Flask packs the current trace context into a small dict (the carrier), hands it to Celery as a task argument, and the worker extracts the context and opens a child span from it.

<p align="center"><img src="./images/trace-propagation-flow.drawio.svg" alt="Trace context propagation flow showing HTTP client, Flask API injecting context into a carrier, Redis broker, Celery worker extracting context into a child span, and Tempo storing both spans under one trace ID"></p>

## Learning Objectives

By the end of this lab you will be able to:

- Inject the current trace context into a carrier dict with `propagate.inject(carrier)`.
- Pass the carrier as a task argument to a Celery worker.
- Extract the trace context from the carrier in the worker with `propagate.extract(carrier)`.
- Continue the original trace from the worker by passing the extracted context to `start_as_current_span`.
- Verify in Grafana Tempo that both spans share one trace ID.

## Task Description

In this lab, a Flask endpoint enqueues a Celery task with the trace context as a carrier, the worker extracts that context, opens a child span from it, and the resulting shared trace is verified in Tempo.

## Table of Contents

1. Chapter 1 — Set Up the Project (Flask + Celery + OpenTelemetry)
2. Chapter 2 — Inject Trace Context in the Flask Endpoint
3. Chapter 3 — Extract Context and Continue the Trace in the Worker

## Architecture

The system has two services on the host: a Flask API that accepts HTTP requests, and a Celery worker that consumes tasks from a Redis broker. Both processes emit OpenTelemetry spans to the same Tempo instance from Lab 9. The Flask instrumentation opens a server span for each request. Before enqueueing the Celery task, the endpoint packages that span's trace context into a plain dict (the carrier) and hands it to Celery as a task kwarg. The worker reads the carrier, reconstructs the context, and opens a child span from it so the two spans share one trace ID.

## Prerequisites

- Completion of Lab 9 with the Grafana and Tempo stack running on `http://localhost:3000`.
- Completion of Lab 10 with the Flask API auto-instrumented and exporting OTLP/HTTP to Tempo.
- Completion of Lab 11 with manual spans using `tracer.start_as_current_span(...)` and `set_attribute`.
- Redis running locally on `localhost:6379`.
- Python 3.10 or newer with `pip` and a virtual environment manager.

## Environment Setup

You will need two services that talk to each other: a Flask API that receives HTTP requests, and a Celery worker that processes long-running tasks in the background. Both processes must emit OpenTelemetry spans to the same Tempo instance you stood up in Lab 9.

Open three terminals side by side. Each one must be inside `trace-lab/` so the modules import the same way.

```bash
mkdir trace-lab && cd trace-lab
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install --upgrade pip
```

Create the application files in this layout:

```
trace-lab/
├── app.py
├── tasks.py
├── otel_setup.py
└── requirements.txt
```

`requirements.txt`:

```
flask==3.0.3
celery==5.4.0
redis==5.0.4
opentelemetry-api==1.27.0
opentelemetry-sdk==1.27.0
opentelemetry-exporter-otlp-proto-http==1.27.0
opentelemetry-instrumentation-flask==0.48b0
opentelemetry-instrumentation-celery==0.48b0
```

Install everything from the same folder:

```bash
pip install -r requirements.txt
```

These packages give you:

- `opentelemetry-api` — the propagation API (`inject`, `extract`) and the `Tracer` used to start spans.
- `opentelemetry-instrumentation-flask` and `opentelemetry-instrumentation-celery` — auto-instrumentation that opens server spans for Flask requests and for Celery task execution.
- `opentelemetry-exporter-otlp-proto-http` — ships spans to Tempo over OTLP HTTP.

### Configure Celery with Redis as the broker

`tasks.py` — run from inside `trace-lab/`. The blank is filled with the answer so the file is runnable immediately:

```bash
cat > tasks.py <<'EOF'
from celery import Celery

celery_app = Celery(
    "trace-lab",
    broker="redis://localhost:6379/0",
    backend="redis://localhost:6379/0",
)
EOF
```

`app.py`:

```bash
cat > app.py <<'EOF'
from celery import Celery
from flask import Flask, jsonify, request
from tasks import celery_app
from opentelemetry import trace
from opentelemetry.propagate import inject, extract

flask_app = Flask(__name__)
flask_app.config["CELERY_BROKER_URL"] = "redis://localhost:6379/0"
flask_app.config["CELERY_RESULT_BACKEND"] = "redis://localhost:6379/0"
celery_app.conf.update(broker_url=flask_app.config["CELERY_BROKER_URL"])
tracer = trace.get_tracer(__name__)
EOF
```

Celery and Flask must agree on the broker, or Flask will enqueue into a queue the worker never listens to. Both point at `redis://localhost:6379/0`.

### Start Redis and verify both processes

Open three terminals. Terminal 1 starts Redis, terminal 2 starts the worker, terminal 3 starts the Flask API. Run each `cd trace-lab` before the corresponding command.

```bash
# terminal 1
redis-server
```

```bash
# terminal 2
cd trace-lab && source .venv/bin/activate
celery -A tasks worker --loglevel=info
```

```bash
# terminal 3
cd trace-lab && source .venv/bin/activate
export OTEL_SERVICE_NAME=flask-api
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
opentelemetry-instrument --service_name=flask-api \
  flask --app app run --port 8000
```

Visit `http://localhost:8000/` and you should see a running API. The worker terminal should print that it is ready to receive tasks.

## Chapter 1 — Set Up the Project (Flask + Celery + OpenTelemetry)

This chapter corresponds to the **Environment Setup** block above. The implementation steps for the project layout, dependency install, broker configuration, and process startup are documented there so the running stack is ready before the propagation code in the next chapters.

### Checkpoint

- [ ] Redis is running and the worker reports `ready`.
- [ ] The Flask API responds on `http://localhost:8000/`.

### Screenshots

> *Drop your screenshots at `./images/lab-12-ch1-redis-running.png`, `./images/lab-12-ch1-celery-worker-ready.png`, and `./images/lab-12-ch1-flask-root.png`.*

<p align="center"><img src="./images/lab-12-ch1-redis-running.png" alt="Screenshot TODO — terminal 1 showing redis-server running"></p>

<p align="center"><img src="./images/lab-12-ch1-celery-worker-ready.png" alt="Screenshot TODO — terminal 2 showing celery worker reporting ready"></p>

<p align="center"><img src="./images/lab-12-ch1-flask-root.png" alt="Screenshot TODO — terminal 3 showing the Flask API running on port 8000"></p>
- [ ] Both processes export spans to the same Tempo instance.

## Chapter 2 — Inject Trace Context in the Flask Endpoint

When a request comes in, Flask instrumentation opens a server span and makes it the current context. Before the work is handed off to Celery, that context is captured into a carrier dict and passed as a task argument.

### The endpoint that creates a task

`app.py` — the blanks are filled with the answers so the file is runnable as soon as the heredoc finishes. Append this block to the `app.py` you created in Environment Setup:

```bash
cat >> app.py <<'EOF'
from opentelemetry.propagate import inject

@flask_app.post("/process")
def enqueue_process():
    item_id = request.json.get("item_id")
    carrier = {}
    propagate.inject(carrier)
    task_result = process_item.delay(item_id, carrier=carrier)
    return jsonify({"task_id": task_result.id, "trace_id": format(trace.get_current_span().get_span_context().trace_id, "032x")})
EOF
```

`propagate.inject(carrier)` walks up to the currently active span context (here: the Flask server span) and writes the W3C `traceparent` header into the carrier dict. After `inject`, the carrier looks like:

```python
{"traceparent": "00-aaaa....-bbbb....-01"}
```

That single string is enough to identify the trace and the parent span — no other state needs to be serialized. The carrier is passed as a keyword argument (`carrier=carrier`) so the worker can read it by name.

### Confirm the trace ID is logged

The `trace_id` returned in the JSON is something to search for in Tempo:

```bash
curl -X POST http://localhost:8000/process \
  -H "Content-Type: application/json" \
  -d '{"item_id": 42}'
```

Response:

```json
{
  "task_id": "f1c8...",
  "trace_id": "a1b2c3d4e5f6..."
}
```

Save that `trace_id`. It will be needed in Chapter 3.

### Checkpoint

- [ ] `curl` returns a 32-character hex `trace_id` from the JSON body.
- [ ] The worker terminal logs the task being processed.

### Screenshot

> *Drop your screenshot at `./images/lab-12-ch2-curl-process.png`.*

<p align="center"><img src="./images/lab-12-ch2-curl-process.png" alt="Screenshot TODO — curl POST /process returning the JSON response with task_id and trace_id"></p>

## Chapter 3 — Extract Context and Continue the Trace in the Worker

On the worker side, the carrier is received, `extract` rebuilds the context, and a child span is opened from it. The child's `trace_id` will match the Flask span's `trace_id` exactly.

### The Celery task

`tasks.py` — replace the file from Environment Setup with this version. The blanks are filled with the answers so the file is runnable as soon as the heredoc finishes. Run from inside `trace-lab/`:

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
    ctx = propagate.extract(carrier)
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

`extract(carrier)` reads the `traceparent` header from the carrier dict and reconstructs a `Context` object. That context carries the original trace_id and the parent span_id. When the context is passed as `context=ctx` to `start_as_current_span`, the new span becomes a *child* of the Flask span — same trace, different span.

### Confirm a single trace in Grafana

Open Grafana Explore → choose the Tempo datasource → paste the `trace_id` captured earlier → search.

Exactly **two spans** are joined under that trace:

- `POST /process` — the Flask server span (root).
- `celery-process` — the worker span (child), with `item.id` set.

Click the root span. The trace tree shows the worker span indented underneath, with the parent link drawn between them.

### Checkpoint

- [ ] The Tempo search by `trace_id` returns a single trace with two spans: `POST /process` and `celery-process`.

### Screenshot

> *Drop your screenshot at `./images/lab-12-ch3-grafana-shared-trace.png`.*

<p align="center"><img src="./images/lab-12-ch3-grafana-shared-trace.png" alt="Screenshot TODO — Grafana Explore showing a single trace with both POST /process and celery-process spans"></p>

### Experiment — break propagation, then fix it

This is the most important exercise in the lab. The value of `inject`/`extract` is demonstrated by removing them.

1. In `app.py`, comment out the `inject(carrier)` line.
2. In `tasks.py`, change the `with tracer.start_as_current_span(...)` block to open a *new* span without a `context=` argument — just `tracer.start_as_current_span("celery-process")`.
3. Trigger a request: `curl -X POST http://localhost:8000/process -H "Content-Type: application/json" -d '{"item_id": 99}'`.
4. Open Tempo and search for the `trace_id` returned in the response.

Only the Flask span appears — the worker span exists in Tempo but with a brand-new trace ID, so it does not show up under this search. The two spans are now two unrelated traces.

5. Restore the `inject`/`extract` calls. Repeat the request and search again. The two spans share one trace ID again.

## Conclusion

`propagate.inject(carrier)` packs the active span's W3C trace context into a plain dict. `propagate.extract(carrier)` rebuilds the `Context` from that dict on the receiving side. Passing the extracted context as `context=ctx` to `start_as_current_span` makes the new span a child of the original trace. The carrier is a regular Python dict — it travels through any boundary that can carry a dict (Celery task kwargs, Redis, RabbitMQ, Kafka headers, HTTP headers).

The propagation-break experiment demonstrated that without `inject` and `extract`, the Flask and Celery spans end up in separate traces. Restoring the calls reunites them under one trace ID.

In the next lab this setup is used to add metrics and logs and observe how Tempo, Prometheus, and Loki correlate by trace ID.