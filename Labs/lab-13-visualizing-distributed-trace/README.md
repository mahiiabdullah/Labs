# Lab 13 — Visualizing the End-to-End Distributed Trace in Grafana Tempo

## Introduction

Distributed tracing produces spans in two services — a Flask API on the request side and a Celery worker on the task side — and ships both to the same Tempo instance. This lab turns that pipeline into something that can be read visually: one trace ID, one waterfall, one service graph showing which service is slow and why.

<p align="center"><img src="./images/full-system-trace-flow.drawio.svg" alt="End-to-end trace flow from HTTP client through Flask API, Redis broker, Celery worker, into Tempo and out to Grafana Explore"></p>

---

## Learning Objectives

- Capture the active trace ID on the Flask response using `X-Trace-ID`.
- Query Tempo by trace ID in Grafana Explore.
- Read the waterfall to identify the slowest span in a trace.
- Read the service graph to identify which service contributes the most latency.
- Inject latency into the worker span and observe how the waterfall attributes it.

## Prerequisites

- Lab 9 — running Grafana + Tempo stack reachable on `http://localhost:3000` with the Tempo datasource provisioned.
- Lab 10 — Flask API auto-instrumented with `opentelemetry-instrument` and exporting OTLP/HTTP to Tempo.
- Lab 11 — manual child spans using `tracer.start_as_current_span(...)` with custom attributes.
- Lab 12 — Celery worker that calls `propagate.extract(carrier)` and `start_as_current_span(..., context=ctx)`.
- Redis running locally on `localhost:6379`.

---

## Prologue

OpenTelemetry emits a **span** for every unit of work in a process. A span carries a name, start/end timestamps, attributes, and — crucially — a **trace ID** that is shared with every other span in the same trace. A **tracer** is the object that creates spans via `tracer.start_as_current_span(...)`. The mechanism that moves a trace ID across a process boundary (HTTP, Redis, Celery, Kafka) is called **context propagation**: the sender packages the current trace context into a plain Python dict called a **carrier**, the receiver reads it back and starts a child span from it. The serialized form is a single header named **traceparent** defined by the W3C Trace Context standard. The place where all spans end up — indexed by trace ID and searchable — is **Tempo**, which speaks the **OTLP** (OpenTelemetry Line Protocol) format over HTTP on port `4318`. In Grafana, Tempo renders spans as a **waterfall**, a left-to-right diagram in which each row is one span and the bar width is the span's duration.

---

## Environment Setup

Create the project directory and Python virtual environment:

```bash
mkdir trace-lab && cd trace-lab
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install --upgrade pip
pip install -r requirements.txt
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

Start the system in three terminals:

```bash
redis-server                                    # terminal 1
celery -A tasks worker --loglevel=info           # terminal 2
opentelemetry-instrument --service_name=flask-api \
  flask --app app run --port 8000               # terminal 3
```

The Flask API is now reachable at `http://localhost:8000`, the worker is consuming tasks from Redis, and both processes are exporting OTLP/HTTP spans to Tempo.

---

## Chapter 1 — Trigger the Full Request and Capture the Trace ID

### Opening Context

Tempo organizes spans by trace ID. Without the trace ID on the request response, locating the matching spans in Grafana requires searching by service name and time window. Exposing the trace ID on the response makes the next chapter trivial.

### What You Will Build

A Flask endpoint that sets the current trace ID on the response under the `X-Trace-ID` header so any HTTP client can capture it with `curl -i`.

### Think First

<details><summary>If the Celery worker picks up the task 3 seconds after the Flask span ends, predict how this gap will appear in the trace waterfall. Will it be drawn as part of the parent span? Will it be hidden? Will it show up at all?</summary>

The gap is not part of any span. Tempo only stores spans, so the 3 seconds of waiting in the queue appear as whitespace between the end of the Flask bar and the start of the `celery-process` bar in the waterfall.
</details>

### Implementation

In `app.py`, before returning from `/process`, read the active span and put its trace ID on the response:

```python
from flask import jsonify, request, make_response
from opentelemetry import trace

@flask_app.post("/process")
def enqueue_process():
    item_id = request.json.get("item_id")
    carrier = {}
    propagate.inject(carrier)
    process_item.delay(item_id, carrier=carrier)
    span = trace.get_current_span()
    trace_id_hex = format(span.get_span_context().trace_id, "032x")
    response = make_response(jsonify({"task_id": "...", "trace_id": trace_id_hex}))
    response.headers["___________"] = trace_id_hex   # blank 1
    return response
```

**Fill in the blanks**

- Blank 1 — the response header name used to expose the trace ID. The same string is used later for the deep-link URL.

> **Hint:** A common convention is `X-Trace-ID`. Use the same string here and in Chapter 2.

<details><summary>Show answer</summary>

```
response.headers["X-Trace-ID"] = trace_id_hex
```
</details>

Trigger the request and capture the header:

```bash
curl -i -X POST http://localhost:8000/process \
  -H "Content-Type: application/json" \
  -d '{"item_id": 7}'
```

Sample response:

```
HTTP/1.1 200 OK
Content-Type: application/json
X-Trace-ID: a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4

{"task_id":"f1c8...","trace_id":"a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"}
```

Save the `X-Trace-ID` value for use in the next chapter.

### Understanding the Code

`trace.get_current_span()` returns the active span — the Flask server span opened by the auto-instrumentation. `span.get_span_context().trace_id` is an integer; formatting it as `"032x"` produces a 32-character lowercase hex string that matches what Tempo stores internally. Setting it as a response header makes the value reachable by any HTTP client without parsing the JSON body.

### Test and Verify

- Confirm the response carries the header named in blank 1.
- Confirm the value is a 32-character lowercase hex string.
- Confirm the worker terminal logged the task being processed.

### Checkpoint

- The trace ID is on the response.
- The worker logged the task.
- The trace ID has been saved.

### Experiment

Replace the blank with a different header name (for example `X-Request-ID`) and trigger the request again. Confirm that the value is still 32 characters of lowercase hex but is no longer named `X-Trace-ID`. Restore `X-Trace-ID` after observing.

---

## Chapter 2 — Navigate the Trace Waterfall in Grafana

### Opening Context

A trace ID is only useful if it can be turned into a waterfall in a small number of steps. Grafana's Explore view provides two ways: a Search-by-trace-ID tab for direct lookup, and a TraceQL tab for attribute-based queries.

### What You Will Build

A repeatable navigation flow: open Grafana Explore, pick the Tempo datasource, paste the trace ID, and arrive at the waterfall in two clicks.

### Think First

<details><summary>What is the practical difference between the Search by Trace ID tab and the TraceQL tab in Grafana's Tempo datasource? When would each be used?</summary>

The Search tab takes a single trace ID and returns one trace. The TraceQL tab accepts a query expression like `{ resource.service.name = "flask-api" && traceID = "..." }` and returns matching traces. Use Search when the exact trace ID is known; use TraceQL when traces must be located by attribute without a known ID.
</details>

### Implementation

Navigate to `http://localhost:3000/explore`. In the top datasource dropdown, choose the **Tempo** datasource configured in Lab 9. In the query type selector, switch to **Search**. Type the trace ID from `X-Trace-ID` into the **Trace ID** field, then click **Run query**.

<p align="center"><img src="./images/tempo-service-graph.drawio.svg" alt="Tempo service graph showing flask-api connected to celery-worker with a p95 latency label on the edge"></p>

The waterfall opens. Each row is one span:

- The top row is the root span — `POST /process`, the Flask server span from Lab 10.
- The second row is `celery-process`, the child span from Lab 12, indented under its parent.

The bar width is the span's duration. Click any bar to expand it and see attributes (`item.id`, `worker.hostname`).

TraceQL alternative — in the query type dropdown, choose **TraceQL** and write:

```traceql
{ resource.service.name = "flask-api" && traceID = "___________" }
```

(blank 2 — paste the trace ID captured in Chapter 1)

<details><summary>Show answer</summary>

```
{ resource.service.name = "flask-api" && traceID = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4" }
```
</details>

Deep-link directly to a trace using the URL pattern:

```
http://localhost:3000/explore?orgId=1&left=%7B%22datasource%22:%22Tempo%22,%22queries%22:%5B%7B%22query%22:%22___________%22%7D%5D%7D
```

(blank 3 — the URL field that carries the trace ID)

Build and open it from the shell:

```bash
echo "http://localhost:3000/explore?datasource=Tempo&query=$TRACE_ID"
```

<details><summary>Show answer</summary>

```
http://localhost:3000/explore?orgId=1&left=%7B%22datasource%22:%22Tempo%22,%22queries%22:%5B%7B%22query%22:%22a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4%22%7D%5D%7D
```
</details>

### Understanding the Code

The URL is a standard Grafana Explore deep link. The `datasource` field selects Tempo; the nested `query` field is the value pasted into the search input. The percent-encoded curly braces and quotes are the JSON object Grafana reads to restore the panel state on load.

### Test and Verify

- Confirm the waterfall opens with exactly two spans.
- Confirm the spans share a trace ID — both rows display the same 32-character hex value in their details.
- Confirm the `celery-process` span shows the custom attribute `item.id = 7`.

### Checkpoint

- The waterfall is reachable in two clicks from the trace ID.
- The TraceQL query returns the same trace.
- The deep-link URL opens the same waterfall.

### Experiment

Open the deep-link URL in an incognito window with the same Grafana instance reachable. Confirm the trace loads without any prior session state. Close the window and reopen — Tempo is stateless, so the result is reproducible.

---

## Chapter 3 — Interpret Latency Using the Waterfall and Service Graph

### Opening Context

The waterfall answers the question *"how long did each step take in this trace?"* The service graph answers the question *"which service contributes the most latency across all traces?"* Both views are required to read the system end-to-end.

### What You Will Build

A procedure for reading a single trace's waterfall, switching to the service graph to compare aggregate latency, and confirming the attribution by injecting a known delay.

### Think First

<details><summary>Predict which span will be widest in the waterfall if the Celery task contains a time.sleep(2). After observing, explain why removing the sleep makes the two bars look closer in width.</summary>

The `celery-process` span will be the widest by approximately 2 seconds. The Flask server span duration does not change because the sleep runs in the worker, not in the API. Removing the sleep drops the worker span's duration back to its baseline, leaving only the queue wait time as the gap between bars.
</details>

### Implementation

Open the waterfall from Chapter 2. Look at the bars left-to-right. The wider the bar, the longer that span ran. The span whose bar reaches farthest to the right is the slowest operation in the trace.

In the trace from Chapter 1 the `celery-process` bar is wider than the Flask bar — the worker is the slow part, not the API. **The widest bar in the waterfall is the slowest span** (blank 4).

<details><summary>Show answer</summary>

The `celery-process` span is the widest bar in the waterfall.
</details>

Switch from the trace view to the **Service Graph** view in Grafana Explore. Tempo renders two nodes and an edge:

- **`flask-api`** node.
- **`celery-worker`** node.
- An arrow labeled with rolled-up traffic stats — requests per second and a percentile latency (for example `p95 = 2.3s`).

The service graph shows aggregate dependency and latency over many traces. It does not show individual span attributes or parent-child links within a single trace (blank 5).

<details><summary>Show answer</summary>

The service graph shows aggregate traffic and latency statistics between services, which the per-trace waterfall view does not display.
</details>

For a single trace, the widest bar in the waterfall identifies the slowest span. For aggregate analysis across many traces, the service graph identifies which edge contributes the most latency on average.

### Understanding the Code

Tempo computes the service graph by extracting the parent-child span relationships across all stored traces and rolling them up by `service.name`. The `p95` label on the edge is the 95th percentile of the time the downstream service spent processing each request, calculated from the span durations themselves.

### Test and Verify

- Confirm the widest bar is the `celery-process` span.
- Confirm the Flask span duration did not grow when the worker was slowed down.
- Confirm the service graph's `p95` value returns to its previous value after the sleep is removed.

### Checkpoint

- The widest-bar rule is verified for the baseline trace.
- The service graph distinction from the waterfall is understood.

### Experiment

1. In `tasks.py`, add `time.sleep(2)` at the start of `do_work` inside the `celery-process` block.
2. Trigger a new request: `curl -X POST http://localhost:8000/process -H "Content-Type: application/json" -d '{"item_id": 99}'`.
3. Open Grafana, paste the new `X-Trace-ID` into the Tempo search.
4. Observe the waterfall. The `celery-process` bar is now the widest by far — about 2 seconds wide — while the Flask span stays the same as before.
5. Remove the `time.sleep(2)` after observing.

The latency is attributed to the worker, where it actually happened. The waterfall does not blame the API.

---

## Epilogue

By the end of this lab, the request trace is fully observable end-to-end:

- Flask exposes the active trace ID on the response under `X-Trace-ID`.
- Grafana Explore's Tempo search opens the full waterfall by trace ID in two clicks.
- TraceQL filters traces by attribute when no specific ID is known.
- The widest bar in the waterfall identifies the slowest span in this trace.
- The service graph view summarizes traffic and latency across all traces between services.

The system built across Labs 9–13 is now capable of answering the question *"why is this request slow?"* from a single trace ID.

---

## The Principles

1. **A trace ID is the join key.** Anything that carries it — headers, Redis payloads, log fields — becomes searchable in Tempo.
2. **The waterfall is local to a trace.** It shows the timing of individual spans in one request.
3. **The service graph is aggregate.** It summarizes traffic and latency across many traces.
4. **Latency lives in the span that incurred it.** Injecting a delay into one span widens only that span's bar.
5. **Propagation must be deliberate.** Without `inject` and `extract`, spans in different processes form separate traces.

---

## Troubleshooting

| Problem | Likely Cause | Resolution |
|---------|--------------|------------|
| Tempo search returns no results | The trace ID is wrong, the trace has not yet been exported, or the Tempo datasource is misconfigured | Verify the trace ID format (32 lowercase hex); wait a few seconds for OTLP export; re-check the Tempo datasource URL in Connections → Data sources |
| Waterfall shows only one span | The Celery worker lost the carrier, or `propagate.extract` was not called | Confirm the Flask endpoint calls `propagate.inject(carrier)` and the worker calls `propagate.extract(carrier)` before `start_as_current_span` |
| Service graph is empty | Tempo has not yet aggregated enough spans, or `service.name` is not set | Send several requests; confirm each process sets `OTEL_SERVICE_NAME` |
| `time.sleep(2)` does not widen the bar | The sleep is outside the `with tracer.start_as_current_span(...)` block | Move `time.sleep(2)` inside the block |
| Deep-link URL opens an empty panel | The trace ID is missing from the `query` field or wrong datasource is selected | Verify the `datasource=Tempo` segment and that `query=<trace_id>` is present |

---

## Next Steps

- Add **metrics** (Prometheus) and **logs** (Loki) and correlate them by trace ID.
- Add more services to the trace and observe the cascade in the service graph.
- Configure **sampling** in the OTLP exporter to reduce storage cost while preserving long-tail traces.
- Set up **alerts** in Grafana when `p95` latency on a service graph edge exceeds a threshold.

---

## Additional Resources

- Grafana Tempo documentation: https://grafana.com/docs/tempo/latest/
- Grafana TraceQL reference: https://grafana.com/docs/tempo/latest/traceql/
- OpenTelemetry context propagation: https://opentelemetry.io/docs/concepts/context-propagation/
- W3C Trace Context specification: https://www.w3.org/TR/trace-context/
- OpenTelemetry Python API — `opentelemetry.propagate`: https://opentelemetry-python.readthedocs.io/en/stable/api/propagate.html