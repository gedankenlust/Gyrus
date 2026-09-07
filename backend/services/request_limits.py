"""Enforce byte limits before a route can mutate data, also for chunked bodies."""
import tempfile
from starlette.responses import JSONResponse


class RequestSizeMiddleware:
    def __init__(self, app, limit):
        self.app, self.limit = app, limit

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            return await self.app(scope, receive, send)
        maximum = self.limit()
        with tempfile.SpooledTemporaryFile(max_size=1024 * 1024) as body:
            size = 0
            while True:
                message = await receive()
                if message['type'] == 'http.disconnect':
                    return
                chunk = message.get('body', b'')
                size += len(chunk)
                if size > maximum:
                    return await JSONResponse({'detail': 'Request body is too large'}, status_code=413)(scope, receive, send)
                body.write(chunk)
                if not message.get('more_body', False):
                    break
            body.seek(0)
            remaining = size
            delivered = False

            async def replay():
                nonlocal remaining, delivered
                if delivered:
                    return await receive()
                chunk = body.read(64 * 1024)
                remaining -= len(chunk)
                delivered = remaining == 0
                return {'type': 'http.request', 'body': chunk, 'more_body': not delivered}

            await self.app(scope, replay, send)
