import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


action = sys.argv[1]
job = sys.argv[2] if len(sys.argv) > 2 else ""
method, url = {
    "portal": ("GET", "http://operations-portal/api/readings"),
    "submit": ("POST", f"http://telemetry-api/api/jobs/{job}/submit"),
    "run": ("POST", f"http://job-worker/api/jobs/{job}/run"),
    "status": ("GET", f"http://telemetry-api/api/jobs/{job}"),
}[action]

try:
    with urlopen(Request(url, method=method), timeout=5) as response:
        body = json.dumps(json.load(response), sort_keys=True)
        print(f"{response.status} {body}")
except HTTPError as error:
    body = json.dumps(json.load(error), sort_keys=True)
    print(f"{error.code} {body}")
except (URLError, TimeoutError) as error:
    print(f"000 {error}")
