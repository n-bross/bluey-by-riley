"""Bluey viewer for Hermes' Bot Desktop RFB bridge and control lease."""
import asyncio
import hashlib
import json
import secrets
import time
from contextlib import suppress
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import ClientError, ClientSession, ClientTimeout, DummyCookieJar, WSMsgType, web
from yarl import URL

CLIENT = web.AppKey("client", ClientSession)
SCREEN = Path(__file__).with_name("screen")
ASSETS = SCREEN / "node_modules" / "@novnc" / "novnc"
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
               "te", "trailer", "transfer-encoding", "upgrade"}


class DisplayError(Exception):
    pass


class DisplayRPC:
    def __init__(self, socket, config):
        self.socket = socket
        self.profile = config.get("profile")
        self.pending = {}
        self.sequence = 0
        self.profile_key = None
        self.viewer_id = None
        self.controls = False

    async def read(self, viewer):
        try:
            async for frame in self.socket:
                if frame.type != WSMsgType.TEXT:
                    break
                message = json.loads(frame.data)
                future = self.pending.get(message.get("id"))
                if future is not None and not future.done():
                    future.set_result(message)
                event = message.get("params", {})
                if message.get("method") == "event" and event.get("type") == "display.lease":
                    payload = event.get("payload", {})
                    if self.profile_key and payload.get("profile_key") == self.profile_key:
                        await viewer.send_json({"controls": self.has_control(payload.get("lease", {}))})
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(DisplayError("Hermes control connection closed."))

    def has_control(self, lease):
        viewer_hash = hashlib.sha256(self.viewer_id.encode()).hexdigest()[:12] if self.viewer_id else None
        self.controls = bool(viewer_hash and lease.get("holder") == "human" and lease.get("viewer_hash") == viewer_hash)
        return self.controls

    async def call(self, method, **params):
        self.sequence += 1
        request_id = self.sequence
        if self.profile:
            params["profile"] = self.profile
        future = asyncio.get_running_loop().create_future()
        self.pending[request_id] = future
        try:
            await self.socket.send_json({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
            message = await asyncio.wait_for(future, 20)
        finally:
            self.pending.pop(request_id, None)
        if error := message.get("error"):
            raise DisplayError(error.get("message") or "Hermes refused the display request.")
        return message["result"]


async def stream_desktop(request, viewer, dashboard, config):
    token = Path(config["token_file"]).expanduser().read_text().strip()
    if not token:
        raise DisplayError("Hermes dashboard token file is empty.")
    upstream = request.app[CLIENT]
    async with upstream.ws_connect(dashboard / "api/ws" % {"token": token}, heartbeat=20) as socket:
        rpc = DisplayRPC(socket, config)
        reader = asyncio.create_task(rpc.read(viewer))
        try:
            status = await rpc.call("display.status")
            if not status.get("running"):
                await rpc.call("display.start")
            observation = await rpc.call("display.observe")
            rpc.profile_key = observation["profile_key"]
            rpc.viewer_id = observation["viewer_id"]
            address = dashboard / "api/display/ws" % {"display_ticket": observation["ticket"]}
            async with upstream.ws_connect(address, heartbeat=20) as display:
                await relay_display(viewer, display, rpc, reader)
        finally:
            if rpc.viewer_id and not reader.done():
                with suppress(DisplayError, ClientError, ConnectionError, asyncio.TimeoutError):
                    await asyncio.wait_for(rpc.call("display.lease.release", viewer_id=rpc.viewer_id), 3)
            reader.cancel()
            await asyncio.gather(reader, return_exceptions=True)


async def relay_display(viewer, display, rpc, reader):
    async def to_viewer():
        async for frame in display:
            if frame.type == WSMsgType.BINARY:
                await viewer.send_bytes(frame.data)
            else:
                break
        if display.close_code == 4000:
            await viewer.close(code=4000, message=b"control-taken")

    async def to_hermes():
        async for frame in viewer:
            if frame.type == WSMsgType.BINARY:
                if not display.closed:
                    await display.send_bytes(frame.data)
            elif frame.type == WSMsgType.TEXT:
                command = json.loads(frame.data)
                action = command.get("action") if isinstance(command, dict) else None
                if action not in {"take", "release"}:
                    continue
                method = "acquire" if action == "take" else "release"
                try:
                    result = await rpc.call(f"display.lease.{method}", viewer_id=rpc.viewer_id)
                    await viewer.send_json({"reply": True, "controls": rpc.has_control(result["lease"])})
                except DisplayError as error:
                    await viewer.send_json({"reply": True, "error": str(error)})
            else:
                break

    pumps = [asyncio.create_task(to_viewer()), asyncio.create_task(to_hermes())]
    try:
        done, _ = await asyncio.wait([reader, *pumps], return_when=asyncio.FIRST_COMPLETED)
        for task in done:
            task.result()
    finally:
        for task in pumps:
            task.cancel()
        await asyncio.gather(*pumps, return_exceptions=True)


def create_app(legacy_port, cfg, authorized):
    config = cfg["hermes_screen"]
    dashboard = URL(config["dashboard_url"])
    if (dashboard.scheme not in {"http", "https"} or dashboard.host not in {"127.0.0.1", "localhost", "::1"}
            or dashboard.user is not None or dashboard.query_string or dashboard.fragment):
        raise ValueError("hermes_screen.dashboard_url must name the local Hermes dashboard")
    if not (ASSETS / "core" / "rfb.js").is_file():
        raise RuntimeError("Install noVNC with npm install --prefix hub/screen")
    page = (SCREEN / "index.html").read_text()
    tickets = {}
    viewers = set()
    app = web.Application()

    async def client_session(app):
        async with ClientSession(timeout=ClientTimeout(total=None, sock_connect=10), auto_decompress=False,
                                 cookie_jar=DummyCookieJar()) as client:
            app[CLIENT] = client
            yield

    app.cleanup_ctx.append(client_session)

    async def viewer_page(request):
        if not authorized(request.headers, cfg):
            raise web.HTTPUnauthorized(text="Connect to Bluey Hub to open the Hermes screen.")
        now = time.monotonic()
        for ticket in list(tickets):
            if tickets[ticket] <= now:
                del tickets[ticket]
        if len(tickets) >= 64:
            raise web.HTTPTooManyRequests()
        ticket = secrets.token_urlsafe(24)
        tickets[ticket] = now + 30
        return web.Response(text=page.replace("__SCREEN_TICKET__", ticket), content_type="text/html", headers={
            "Cache-Control": "no-store",
            "Content-Security-Policy": ("default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
                                        "img-src 'self' data: blob:; connect-src 'self' wss: ws:; "
                                        "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"),
        })

    async def viewer_socket(request):
        origin = urlsplit(request.headers.get("Origin", ""))
        if origin.scheme not in {"https", "http"} or origin.netloc.lower() != request.host.lower():
            raise web.HTTPForbidden()
        ticket = request.query.get("ticket", "")
        if tickets.pop(ticket, 0) <= time.monotonic():
            raise web.HTTPUnauthorized()
        if len(viewers) >= 8:
            raise web.HTTPServiceUnavailable()
        viewer = web.WebSocketResponse(heartbeat=20, max_msg_size=1024 * 1024)
        viewers.add(viewer)
        try:
            await viewer.prepare(request)
            try:
                await stream_desktop(request, viewer, dashboard, config)
            except DisplayError as error:
                await viewer.send_json({"error": str(error)})
            except (OSError, ClientError, asyncio.TimeoutError, KeyError, ValueError):
                if not viewer.closed:
                    await viewer.send_json({"error": "Couldn't connect to Hermes Bot Desktop."})
        finally:
            viewers.discard(viewer)
            await viewer.close()
        return viewer

    async def legacy(request):
        # Keep every existing Hub URL (including Hermes SSE) on the same listener.
        target = URL(f"http://127.0.0.1:{legacy_port}" + request.raw_path, encoded=True)
        headers = {name: value for name, value in request.headers.items()
                   if name.lower() not in HOP_HEADERS | {"host"}}
        # The existing handler reads fixed-length bodies. Buffer only incoming chunked bodies.
        data = await request.read() if request.can_read_body and request.content_length is None else (
            request.content.iter_any() if request.can_read_body else None)
        try:
            async with request.app[CLIENT].request(request.method, target, headers=headers, data=data,
                                                      allow_redirects=False) as response:
                forwarded = [(name, value) for name, value in response.headers.items()
                             if name.lower() not in HOP_HEADERS]
                result = web.StreamResponse(status=response.status, headers=forwarded)
                await result.prepare(request)
                async for chunk in response.content.iter_any():
                    await result.write(chunk)
                return result
        except ClientError as error:
            raise web.HTTPBadGateway(text="Bluey Hub is unavailable.") from error

    app.router.add_get("/screen", viewer_page)
    app.router.add_get("/screen/ws", viewer_socket)
    for name in ("viewer.js", "style.css"):
        async def asset(request, name=name):
            return web.FileResponse(SCREEN / name)
        app.router.add_get("/screen/" + name, asset)
    for directory in ("core", "vendor"):
        if (ASSETS / directory).is_dir():
            app.router.add_static("/screen/assets/" + directory, ASSETS / directory)
    app.router.add_route("*", "/{path:.*}", legacy)

    async def close_viewers(app):
        await asyncio.gather(*(viewer.close(code=1001) for viewer in list(viewers)), return_exceptions=True)

    app.on_shutdown.append(close_viewers)
    return app


def serve_screen(host, port, httpd, cfg, authorized):
    app = create_app(httpd.server_port, cfg, authorized)
    web.run_app(app, host=host, port=port, access_log=None, handler_cancellation=True)
