"""Cancellable background orchestration for Chromium design inspections."""

from services.background_job import BackgroundJob
from services import visual_snapshot_service


job = BackgroundJob(
    bookmark_id=None,
    stage="idle",
    completed=0,
    total=len(visual_snapshot_service.VIEWPORTS),
    snapshot=None,
)


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
            "total": len(visual_snapshot_service.VIEWPORTS),
            "snapshot": None,
        },
    )
