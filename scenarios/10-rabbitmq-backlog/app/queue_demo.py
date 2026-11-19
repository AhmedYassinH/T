"""Small publisher and worker used by the RabbitMQ training lab."""
import os
from pathlib import Path
import sys
import time

import pika

JOBS = "report-jobs"
RESULTS = "report-results"


def broker_connection():
    creds = pika.PlainCredentials(os.environ["RABBITMQ_USER"], os.environ["RABBITMQ_PASSWORD"])
    return pika.BlockingConnection(pika.ConnectionParameters(
        host="report-broker", credentials=creds, socket_timeout=4,
        blocked_connection_timeout=6,
    ))


def publish(channel, queue, body):
    channel.basic_publish("", queue, body, mandatory=True,
                          properties=pika.BasicProperties(delivery_mode=2))


def worker(channel):
    queue = os.environ["WORK_QUEUE"]
    channel.queue_declare(queue, durable=True)
    channel.basic_qos(prefetch_count=1)

    def process(ch, method, properties, body):
        # The demo produces one completion record before acknowledging the input.
        publish(ch, RESULTS, body + b"|completed|36")
        ch.basic_ack(method.delivery_tag)
        print("Completed job", body.decode("ascii"), flush=True)

    channel.basic_consume(queue, process, auto_ack=False)
    print("Listening on", queue, flush=True)
    Path("/tmp/ready").touch()
    try:
        channel.start_consuming()
    finally:
        Path("/tmp/ready").unlink(missing_ok=True)


def counts(channel, queue):
    state = channel.queue_declare(queue, passive=True).method
    return state.message_count, state.consumer_count


def snapshot_results(connection):
    # Hold deliveries unacknowledged on a separate channel, then requeue them.
    reader = connection.channel()
    completed = set()
    try:
        while True:
            delivery, _, body = reader.basic_get(RESULTS, auto_ack=False)
            if delivery is None:
                break
            job, state, total = body.decode("ascii").split("|")
            if state == "completed" and total == "36":
                completed.add(job)
    finally:
        reader.close()
    return completed


def check(connection, channel, expected):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        waiting, consumers = counts(channel, JOBS)
        if not waiting and consumers and set(expected) <= snapshot_results(connection):
            print("PASS: The worker completed every required job and drained report-jobs.")
            return
        connection.sleep(1)
    sys.exit("FAIL: The required job results are missing or the backlog remains.")


def main(args):
    action, *jobs = args
    with broker_connection() as connection:
        channel = connection.channel()
        for queue in (JOBS, RESULTS):
            channel.queue_declare(queue, durable=True)
        channel.confirm_delivery()
        if action == "worker":
            worker(channel)
        elif action == "publish":
            for job in jobs:
                publish(channel, JOBS, job.encode("ascii"))
                print("Queued", job)
        elif action == "status":
            waiting, consumers = counts(channel, JOBS)
            print(f"report-jobs: {waiting} waiting, {consumers} consumer(s)")
        elif action == "incident":
            if counts(channel, JOBS) != (2, 0):
                sys.exit("Expected two waiting jobs and zero consumers on report-jobs.")
        elif action == "check":
            check(connection, channel, jobs)
        else:
            sys.exit("Unknown queue action.")


if __name__ == "__main__":
    main(sys.argv[1:])
