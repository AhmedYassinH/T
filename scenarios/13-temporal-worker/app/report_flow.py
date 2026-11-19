"""Deterministic Temporal sample workflow for the practice namespace."""
import asyncio
from datetime import timedelta
import os
from pathlib import Path
import sys

from temporalio import activity, workflow
from temporalio.client import Client
from temporalio.worker import Worker

QUEUE = "daily-reports"


@activity.defn
async def calculate_total(samples: list[int]) -> int:
    return sum(samples)


@workflow.defn(sandboxed=False)
class DailyReport:
    @workflow.run
    async def run(self, samples: list[int]) -> int:
        return await workflow.execute_activity(
            calculate_total, samples, start_to_close_timeout=timedelta(seconds=10)
        )


async def main():
    action, *args = sys.argv[1:]
    client = await asyncio.wait_for(Client.connect("report-orchestrator:7233"), 10)
    if action == "worker":
        queue = os.environ["REPORT_QUEUE"]
        ready = Path("/tmp/worker-ready")
        ready.unlink(missing_ok=True)
        try:
            async with Worker(client, task_queue=queue, workflows=[DailyReport],
                              activities=[calculate_total]):
                print(f"Polling {queue}", flush=True)
                ready.touch()
                await asyncio.Future()
        finally:
            ready.unlink(missing_ok=True)
    elif action == "start":
        await asyncio.wait_for(client.start_workflow(
            DailyReport.run, [4, 8, 24], id=args[0], task_queue=QUEUE,
        ), 10)
        print(f"Started {args[0]}")
    elif action in ("inspect", "pending"):
        desc = await asyncio.wait_for(client.get_workflow_handle(args[0]).describe(), 10)
        status = desc.status.name
        print(f"{args[0]} is {status} on {desc.task_queue}")
        if action == "pending" and (status != "RUNNING" or desc.task_queue != QUEUE):
            raise SystemExit("Expected to find the original workflow waiting for a worker.")
    elif action == "check":
        for job in args:
            handle = client.get_workflow_handle(job)
            result = await asyncio.wait_for(handle.result(), 15)
            if result != 36:
                raise SystemExit(f"Unexpected result for {job}: {result}")
            print(f"PASS: {job} returned 36.")
    else:
        raise SystemExit("Unknown workflow action.")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except TimeoutError:
        sys.exit("The workflow service or requested result did not respond in time.")
