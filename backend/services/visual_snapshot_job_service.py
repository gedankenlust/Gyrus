"""Cancellable background orchestration for Chromium design inspections."""

from services.background_job import BackgroundJob
from services import visual_snapshot_service


job = BackgroundJob(
    bookmark_id=None,
    stage="idle",
    completed=0,
    total=visual_snapshot_service.DESIGN_INSPECTION_STEPS,
    snapshot=None,
)


def _failure_message(snapshot: dict) -> str:
    reasons = [
        str(error.get("message") or "").strip()
        for error in snapshot.get("errors") or []
        if isinstance(error, dict)
    ]
    reason = next((text for text in reasons if text), "")
    message = "The design inspection could not capture the page."
    return f"{message} {reason}"[:500] if reason else message


def get_status() -> dict:
    return job.get_status()


def cancel() -> dict:
    if job.is_running():
        job.state["stage"] = "cancelling"
    return job.cancel()


async def start(bookmark_id: str, url: str, title: str = "") -> dict:
    if job.is_running():
        return job.get_status()

    def progress(stage: str, completed: int, total: int) -> None:
        job.state["stage"] = stage
        job.state["completed"] = completed
        job.state["total"] = total

    run_id = visual_snapshot_service.new_snapshot_run_id()

    async def runner(active_job: BackgroundJob) -> None:
        try:
            snapshot = await visual_snapshot_service.capture_snapshot(
                bookmark_id,
                url,
                title=title,
                run_id=run_id,
                on_progress=progress,
            )
            active_job.state["snapshot"] = snapshot
            if not snapshot.get("promoted", True):
                # Nothing was captured; the previous inspection stays current.
                # "error" is what the app already surfaces after polling, and
                # the failed run remains listed in the run history.
                active_job.state["stage"] = "failed"
                active_job.state["error"] = _failure_message(snapshot)
            else:
                active_job.state["stage"] = "finished"
        finally:
            if active_job.cancelled:
                visual_snapshot_service.discard_snapshot_run(bookmark_id, run_id)
                active_job.state["stage"] = "cancelled"

    return await job.start(
        runner,
        reset={
            "bookmark_id": bookmark_id,
            "stage": "queued",
            "completed": 0,
            "total": visual_snapshot_service.DESIGN_INSPECTION_STEPS,
            "snapshot": None,
        },
    )
