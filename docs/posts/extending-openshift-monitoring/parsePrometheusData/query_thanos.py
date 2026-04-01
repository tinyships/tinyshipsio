#!/usr/bin/env python3
"""
Query OpenShift Thanos and export a time series CSV.

Usage:
    python query_thanos.py --query '<promql>' --days <N> [--step <step>] [--label <label>] [--output <file>]

The script auto-detects the Thanos URL and auth token via the `oc` CLI.

Requirements:
    pip install requests
    oc CLI logged into your cluster

Reference:
    https://access.redhat.com/solutions/7018296

"""

import argparse
import csv
import subprocess
import sys
from datetime import datetime, timezone, timedelta

try:
    import requests
    requests.packages.urllib3.disable_warnings()
except ImportError:
    print("Error: 'requests' package not found. Run: pip install requests")
    sys.exit(1)


def run_oc(args: list[str]) -> str:
    try:
        result = subprocess.run(
            ["oc"] + args,
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"Error running 'oc {' '.join(args)}':\n{e.stderr.strip()}")
        sys.exit(1)
    except FileNotFoundError:
        print("Error: 'oc' CLI not found. Install it and log into your cluster.")
        sys.exit(1)


def get_thanos_url() -> str:
    host = run_oc([
        "get", "route", "thanos-querier",
        "-n", "openshift-monitoring",
        "-o", "jsonpath={.spec.host}"
    ])
    if not host:
        print("Error: Could not retrieve thanos-querier route.")
        sys.exit(1)
    return f"https://{host}"


def get_auth_token() -> str:
    return run_oc(["whoami", "-t"])


def query_range(base_url: str, token: str, query: str,
                start: float, end: float, step: str) -> list:
    url = f"{base_url}/api/v1/query_range"
    headers = {"Authorization": f"Bearer {token}"}
    params = {
        "query": query,
        "start": start,
        "end": end,
        "step": step,
    }
    resp = requests.get(url, headers=headers, params=params, verify=False, timeout=120)
    if resp.status_code != 200:
        print(f"Error {resp.status_code} from Thanos:\n{resp.text}")
        sys.exit(1)
    data = resp.json()
    if data.get("status") != "success":
        print(f"Query failed: {data}")
        sys.exit(1)
    return data["data"]["result"]


def detect_label(results: list) -> str | None:
    """Pick the first label that varies across series (skip __name__)."""
    skip = {"__name__", "job", "instance"}
    if not results:
        return None
    # Collect all label keys across series
    all_keys = set()
    for series in results:
        all_keys.update(series["metric"].keys())
    all_keys -= skip
    if not all_keys:
        return None
    # Prefer 'namespace' if present
    if "namespace" in all_keys:
        return "namespace"
    return sorted(all_keys)[0]


def results_to_csv(results: list, label: str, output_path: str):
    # Build a dict: timestamp -> {label_value: value}
    time_map: dict[float, dict[str, str]] = {}
    label_values: set[str] = set()

    for series in results:
        lval = series["metric"].get(label, series["metric"].get("__name__", "value"))
        label_values.add(lval)
        for ts, val in series["values"]:
            time_map.setdefault(ts, {})[lval] = val

    sorted_times = sorted(time_map.keys())
    sorted_labels = sorted(label_values)

    with open(output_path, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["DateTime"] + sorted_labels)
        for ts in sorted_times:
            dt = datetime.fromtimestamp(ts, tz=timezone.utc)
            iso = dt.strftime("%Y-%m-%dT%H:%M:%S.000Z")
            row = [iso] + [time_map[ts].get(lv, "") for lv in sorted_labels]
            writer.writerow(row)

    print(f"Wrote {len(sorted_times)} rows x {len(sorted_labels)} series -> {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Query OpenShift Thanos and export a time series CSV."
    )
    parser.add_argument("--query", "-q", required=True, help="PromQL query string")
    parser.add_argument("--days", "-d", type=float, required=True,
                        help="Number of days of history to fetch")
    parser.add_argument("--step", "-s", default=None,
                        help="Query step (e.g. 160m, 1h). Defaults to ~100 data points.")
    parser.add_argument("--label", "-l", default=None,
                        help="Label to use as column headers (auto-detected if omitted)")
    parser.add_argument("--output", "-o", default="output.csv",
                        help="Output CSV file path (default: output.csv)")
    args = parser.parse_args()

    print("Fetching Thanos URL and auth token via 'oc'...")
    thanos_url = get_thanos_url()
    token = get_auth_token()
    print(f"Thanos URL: {thanos_url}")

    end = datetime.now(tz=timezone.utc)
    start = end - timedelta(days=args.days)

    # Default step: aim for ~100 data points
    if args.step is None:
        step_seconds = max(60, int(args.days * 86400 / 100))
        step = f"{step_seconds}s"
    else:
        step = args.step

    print(f"Querying {args.days} day(s) with step={step}...")
    results = query_range(
        thanos_url, token, args.query,
        start.timestamp(), end.timestamp(), step
    )

    if not results:
        print("No data returned for this query.")
        sys.exit(0)

    label = args.label or detect_label(results)
    if label:
        print(f"Using label '{label}' as column headers.")
    else:
        label = "__name__"

    results_to_csv(results, label, args.output)


if __name__ == "__main__":
    main()
