from dataclasses import dataclass
from email.message import Message

import httpx


class DownloadTooLarge(RuntimeError):
    pass


@dataclass(frozen=True)
class LimitedResponse:
    status_code: int
    headers: dict[str, str]
    content: bytes
    url: str

    @property
    def text(self) -> str:
        message = Message()
        message["content-type"] = self.headers.get("content-type", "")
        encoding = message.get_content_charset() or "utf-8"
        return self.content.decode(encoding, errors="replace")


async def get_limited(
    client: httpx.AsyncClient,
    url: str,
    *,
    max_bytes: int,
    timeout: float | httpx.Timeout | None = None,
) -> LimitedResponse:
    """Stream a response and stop once its decoded body exceeds max_bytes."""
    async with client.stream("GET", url, timeout=timeout) as response:
        content_length = response.headers.get("content-length")
        if content_length:
            try:
                if int(content_length) > max_bytes:
                    raise DownloadTooLarge(
                        f"Response exceeds the {max_bytes}-byte safety limit"
                    )
            except ValueError:
                pass

        chunks: list[bytes] = []
        size = 0
        async for chunk in response.aiter_bytes():
            size += len(chunk)
            if size > max_bytes:
                raise DownloadTooLarge(
                    f"Response exceeds the {max_bytes}-byte safety limit"
                )
            chunks.append(chunk)

        return LimitedResponse(
            status_code=response.status_code,
            headers=dict(response.headers),
            content=b"".join(chunks),
            url=str(response.url),
        )
