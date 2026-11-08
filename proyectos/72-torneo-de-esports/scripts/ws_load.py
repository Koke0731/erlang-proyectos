#!/usr/bin/env python3
"""Prueba conexiones WebSocket reales del broadcast del Proyecto 72.

Ejemplo:
  python3 scripts/ws_load.py --base-url http://127.0.0.1:8080 \
      --tournament-id 1 --match-id 123 --clients 300

Requiere el paquete ``websockets`` (python3 -m pip install websockets).
La medición empieza justo antes de publicar el marcador por HTTP e incluye
la llamada HTTP y la entrega del evento a los clientes conectados.
"""

import argparse
import asyncio
import json
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

try:
    from websockets.asyncio.client import connect
except ImportError:
    try:  # Compatibilidad con websockets 10.x y 11.x.
        from websockets import connect
    except ImportError as exc:
        raise SystemExit(
            "Falta la dependencia websockets. Instálala con: "
            "python3 -m pip install websockets"
        ) from exc


@dataclass
class Client:
    index: int
    ready: asyncio.Event = field(default_factory=asyncio.Event)
    received: asyncio.Event = field(default_factory=asyncio.Event)
    pong: asyncio.Event = field(default_factory=asyncio.Event)
    receive_time: float | None = None
    error: str | None = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080",
                        help="URL base de la app (http o https)")
    parser.add_argument("--tournament-id", type=int, required=True)
    parser.add_argument("--match-id", type=int, required=True)
    parser.add_argument("--clients", type=int, default=300)
    parser.add_argument("--connect-timeout", type=float, default=20,
                        help="segundos para abrir y suscribir todos los clientes")
    parser.add_argument("--event-timeout", type=float, default=10,
                        help="segundos para esperar el marcador en cada cliente")
    parser.add_argument("--no-trigger", action="store_true",
                        help="conectar y esperar; publica el marcador manualmente")
    parser.add_argument("--ping", action="store_true",
                        help="verificar ping/pong en cada conexión antes de medir")
    args = parser.parse_args()
    if args.clients < 1:
        parser.error("--clients debe ser mayor que cero")
    if args.tournament_id < 1 or args.match_id < 1:
        parser.error("los IDs deben ser enteros positivos")
    return args


def websocket_url(base_url: str, tournament_id: int) -> str:
    if base_url.startswith("https://"):
        scheme, host = "wss", base_url[8:].rstrip("/")
    elif base_url.startswith("http://"):
        scheme, host = "ws", base_url[7:].rstrip("/")
    else:
        raise ValueError("--base-url debe comenzar con http:// o https://")
    return f"{scheme}://{host}/ws?tournament_id={tournament_id}"


async def read_messages(ws: Any, client: Client, match_id: int) -> None:
    try:
        async for raw in ws:
            try:
                message = json.loads(raw)
            except (json.JSONDecodeError, TypeError):
                continue
            if message.get("type") == "tournament_state":
                client.ready.set()
            elif message.get("type") == "pong":
                client.pong.set()
            elif message.get("type") == "score_update" and message.get("data", {}).get("match_id") == match_id:
                if not client.received.is_set():
                    client.receive_time = time.perf_counter()
                    client.received.set()
    except Exception as exc:  # Guardar el error para reportar clientes caídos.
        client.error = str(exc)
    finally:
        client.ready.set()


def publish_score(base_url: str, tournament_id: int, match_id: int,
                  token: int) -> tuple[int, str]:
    url = (base_url.rstrip("/") + f"/api/torneos/{tournament_id}/"
           f"partidas/{match_id}/marcador")
    body = json.dumps({
        "team_scores": {"1": token, "2": 0},
        "current_map": token,
        "maps_won": {"1": token, "2": 0},
    }).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")


async def run(args: argparse.Namespace) -> int:
    ws_url = websocket_url(args.base_url, args.tournament_id)
    clients = [Client(i) for i in range(args.clients)]
    sockets: list[Any] = []
    readers: list[asyncio.Task[None]] = []
    connect_started = time.perf_counter()
    print(f"Conectando {args.clients} clientes a {ws_url}")

    try:
        for client in clients:
            ws = await connect(ws_url, open_timeout=args.connect_timeout,
                               ping_interval=20, ping_timeout=20, max_size=2**20)
            sockets.append(ws)
            reader = asyncio.create_task(read_messages(ws, client, args.match_id))
            readers.append(reader)
            await ws.send(json.dumps({"type": "subscribe_tournament"}))

        await asyncio.wait_for(
            asyncio.gather(*(client.ready.wait() for client in clients)),
            timeout=args.connect_timeout,
        )
        connected_elapsed = time.perf_counter() - connect_started
        ready_count = sum(client.ready.is_set() and client.error is None for client in clients)
        print(f"Suscritos: {ready_count}/{args.clients}; establecimiento: {connected_elapsed:.3f} s")
        if ready_count != args.clients:
            print("No todos los clientes recibieron tournament_state; se cancela la medición.")
            return 2

        if args.ping:
            for ws in sockets:
                await ws.send(json.dumps({"type": "ping"}))
            try:
                await asyncio.wait_for(
                    asyncio.gather(*(client.pong.wait() for client in clients)), timeout=5
                )
            except asyncio.TimeoutError:
                pass
            pongs = sum(client.pong.is_set() for client in clients)
            print(f"Ping/pong: {pongs}/{args.clients}")

        if args.no_trigger:
            print("Conexiones listas. Publica un marcador ahora; esperando score_update...")
            started = time.perf_counter()
        else:
            token = int(time.time()) % 100000
            started = time.perf_counter()
            status, response = await asyncio.to_thread(
                publish_score, args.base_url, args.tournament_id, args.match_id, token
            )
            if status < 200 or status >= 300:
                print(f"La API rechazó el marcador (HTTP {status}): {response}")
                return 2
            print(f"Marcador publicado (HTTP {status}); esperando score_update...")

        try:
            await asyncio.wait_for(
                asyncio.gather(*(client.received.wait() for client in clients)),
                timeout=args.event_timeout,
            )
        except asyncio.TimeoutError:
            pass

        elapsed = time.perf_counter() - started
        received = [client for client in clients if client.received.is_set()]
        latencies = [(client.receive_time - started) * 1000 for client in received
                     if client.receive_time is not None]
        print(f"Evento recibido: {len(received)}/{args.clients}; ventana: {elapsed:.3f} s")
        if latencies:
            print(f"Latencia desde antes del POST: min={min(latencies):.1f} ms, "
                  f"promedio={sum(latencies) / len(latencies):.1f} ms, "
                  f"máx={max(latencies):.1f} ms")
        missing = [str(client.index) for client in clients if not client.received.is_set()]
        if missing:
            print("Clientes sin evento (índices): " + ", ".join(missing[:30]) +
                  (" ..." if len(missing) > 30 else ""))
        return 0 if len(received) == args.clients else 1
    except Exception as exc:
        print(f"Error durante la prueba: {exc}", file=sys.stderr)
        return 2
    finally:
        await asyncio.gather(*(ws.close() for ws in sockets), return_exceptions=True)
        for task in readers:
            if not task.done():
                task.cancel()
        if readers:
            await asyncio.gather(*readers, return_exceptions=True)


def main() -> None:
    args = parse_args()
    try:
        exit_code = asyncio.run(run(args))
    except ValueError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        exit_code = 2
    raise SystemExit(exit_code)


if __name__ == "__main__":
    main()
