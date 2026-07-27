from models.bookmark import Bookmark
from schemas.bookmark import BookmarkAnalysisOut, BookmarkOut, BookmarkSummaryOut
from services import bookmark_enrichment_service, visual_snapshot_service


def _enrich_common(bookmark: Bookmark, output):
    item = output.model_validate(bookmark)
    item.tags = sorted(
        (bookmark_tag.tag for bookmark_tag in bookmark.bookmark_tags),
        key=lambda tag: tag.name,
    )
    captured_at, complete = visual_snapshot_service.snapshot_summary(bookmark.id)
    item.design_snapshot_captured_at = captured_at
    item.design_snapshot_complete = complete
    item.analysis = BookmarkAnalysisOut(
        **bookmark_enrichment_service.analysis_summary(
            bookmark,
            design_captured=captured_at is not None,
            design_complete=complete,
        )
    )
    return item


def enrich_bookmark_summary(bookmark: Bookmark) -> BookmarkSummaryOut:
    return _enrich_common(bookmark, BookmarkSummaryOut)


def enrich_bookmark(bookmark: Bookmark) -> BookmarkOut:
    return _enrich_common(bookmark, BookmarkOut)
