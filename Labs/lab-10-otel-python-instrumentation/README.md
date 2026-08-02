# Lab 10: Instrumenting a Python API with OpenTelemetry

Install the OpenTelemetry distro and HTTP exporter, run a Flask API under the auto-instrumentation wrapper, and see a request trace land in Grafana Tempo.

![Architecture](./images/otel-auto-instrumentation-flow.drawio.svg)

## What You Will Build

- A virtual environment with `opentelemetry-distro`, the OTLP HTTP exporter, and Flask instrumentation.
- A one-route Flask app served on port 5000.
- A wrapped launch that sends every request as a span to Lab 9's Tempo.

## Prerequisites

- Lab 9 stack running **on a different container** and exposed through the lab load balancer. Lab 10's wrapper sends spans to Tempo over the load balancer, not over `localhost`.
- The Load Balancer modal on this container must already expose:
  - `4318` (Tempo OTLP) on `LB_IP`
  - `3200` (Tempo query) on `LB_IP`
  - `3001` (Grafana UI) on `LB_IP`
- Python 3.10 or newer with pip. On Debian/Ubuntu lab images, install `sudo apt install -y python3-venv python3-pip` first.

## Step 1 — Create the project and a Flask app

```bash
mkdir -p lab-10-otel-python-instrumentation
cd lab-10-otel-python-instrumentation
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
```

> If a previous attempt left an empty `lab-10-otel-python-instrumentation/` folder, run `cd ~` first and `rm -rf lab-10-otel-python-instrumentation` before these commands. The four lines must run from your home directory, not from inside another copy of the same folder.

```bash
cat > app.py <<'EOF'
from flask import Flask

app = Flask(__name__)

@app.get("/hello")
def hello():
    return {"message": "hello from instrumented api"}, 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF
```

On Windows activate with `.venv\Scripts\activate` instead.

## Step 2 — Install Flask and the OpenTelemetry packages

```bash
pip install flask
pip install opentelemetry-distro opentelemetry-exporter-otlp-proto-http opentelemetry-instrumentation-flask
```
![](./images/output-1.png)

In recent versions of `opentelemetry-distro` the `opentelemetry-distro` console script is no longer installed. Install the auto-instrumentations explicitly:

```bash
pip install opentelemetry-instrumentation-requests \
            opentelemetry-instrumentation-urllib3
```
```bash
pip list | grep opentelemetry
```
![](./images/output-2.png)

The list should include `-distro`, `-exporter-otlp-proto-http`, `-instrumentation-flask`, `-instrumentation-wsgi` (pulled in by `-flask`), plus `-requests` and `-urllib3`.

## Step 3 — Configure the OTLP exporter

The wrapper sends spans to Tempo over the load balancer. Replace `<LB_IP>` with the IP you exposed Tempo on in Lab 9 (the **first** address from `hostname -I`).

```bash
export OTEL_SERVICE_NAME=my-api
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<LB_IP>:4318
export OTEL_TRACES_EXPORTER=otlp
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```
```bash
env | grep OTEL_
```
![](./images/output-3.png)

Four lines should print with the values above. `OTEL_SERVICE_NAME` sets the `service.name` resource attribute that Tempo will display. `OTEL_EXPORTER_OTLP_ENDPOINT` must use `<LB_IP>:4318`, **not** `localhost`, because Tempo lives on a different container reachable only through the load balancer.

## Step 4 — Expose the Flask port through the load balancer

Open the **Load Balancer** modal in the lab UI. Run this once to find the IP to enter:

```bash
hostname -I
```

Use the **first** IP printed as `LB_IP`. Expose:

| Enter IP | Enter Port |
|---|---|
| `LB_IP` | `5000` (Flask API) |

The same `LB_IP` value must already have `4318`, `3200`, and `3001` exposed from Lab 9 for the rest of this lab to work.

## Step 5 — Run the app under the wrapper

Run the wrapped Flask in the background so it survives the next `curl` command. Stop it with `kill %1` (or `pkill -f 'flask run'`) when you finish.

```bash
nohup opentelemetry-instrument \
    --service_name my-api \
    --exporter_otlp_endpoint http://<LB_IP>:4318 \
    --exporter_otlp_protocol http/protobuf \
    -- python -m flask run --host=0.0.0.0 --port=5000 \
    > /tmp/flask.log 2>&1 &

sleep 3
tail -n 5 /tmp/flask.log
```

You should see `Running on http://0.0.0.0:5000`. The wrapper injects bytecode at import time so every Flask request becomes a span, and sends them to `<LB_IP>:4318` through the load balancer.

## Step 6 — Send one request through the load balancer

```bash
curl http://<LB_IP>:5000/hello
```

The JSON payload from the Flask handler should return. The wrapper has already exported the matching span to Tempo.

## Step 7 — View the trace in Grafana

Open `http://<LB_IP>:3001` in your browser, choose Explore, select the `Tempo` datasource, switch to **Search**, enter `my-api`, and click **Run query**.

The trace for `/hello` should appear with attributes such as `http.method=GET` and `http.route=/hello`.

## Next Steps

Stop the wrapped process with `Ctrl+C` when you finish. Remove the `5000` port from the Load Balancer modal. Lab 11 adds manual spans with `tracer.start_as_current_span` and custom attributes.