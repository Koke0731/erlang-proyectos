#!/usr/bin/env python3
"""Run the requested 64-team double-elimination tournament scenario.

Requires the running app and ``python3 -m pip install websockets``.
"""

import argparse
import asyncio
import json
import time
import urllib.error
import urllib.request

try:
    from websockets.asyncio.client import connect
except ImportError:
    try:
        from websockets import connect
    except ImportError as exc:
        raise SystemExit("Install websockets with: python3 -m pip install websockets") from exc


def request(base_url: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        base_url.rstrip("/") + path, data=data,
        headers={"Content-Type": "application/json"},
        method="GET" if body is None else "POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        payload = json.loads(exc.read() or b"{}")
        return exc.code, payload


async def api(base_url: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    return await asyncio.to_thread(request, base_url, path, body)


def websocket_url(base_url: str, tournament_id: int) -> str:
    if base_url.startswith("https://"):
        scheme, host = "wss", base_url[8:].rstrip("/")
    else:
        scheme, host = "ws", base_url.removeprefix("http://").rstrip("/")
    return f"{scheme}://{host}/ws?tournament_id={tournament_id}"


async def open_viewer(url: str, timeout: float):
    ws = await connect(url, open_timeout=timeout, ping_interval=20, ping_timeout=20)
    await ws.send(json.dumps({"type": "subscribe_tournament"}))
    message = json.loads(await asyncio.wait_for(ws.recv(), timeout=timeout))
    if message.get("type") != "tournament_state":
        await ws.close()
        raise RuntimeError("A viewer did not receive the initial tournament state")
    return ws


def require_status(label: str, status: int, expected: set[int], body: dict) -> None:
    if status not in expected:
        raise RuntimeError(f"{label} failed (HTTP {status}): {body}")


def find_round_one_matches(brackets: list[dict]) -> list[dict]:
    winners = next((b for b in brackets if "winner" in b.get("name", "").lower()), None)
    if winners is None:
        winners = next((b for b in brackets if b.get("format") == "double_elim"), None)
    if winners is None:
        raise RuntimeError("Could not find the winners bracket")
    return [m for m in winners.get("matches", [])
            if m.get("round") == 1 and m.get("team1_id") is not None
            and m.get("team2_id") is not None]


async def run(args: argparse.Namespace) -> None:
    stamp = time.strftime("%Y%m%d-%H%M%S")
    name = f"Demo escenario 64 equipos {stamp}"
    status, tournament = await api(args.base_url, "/api/torneos", {
        "name": name,
        "format": "double_elim",
        "series_format": "bo3",
        "max_teams": 64,
        "config": {"tables_count": 8},
    })
    require_status("Tournament creation", status, {201}, tournament)
    tournament_id = tournament["id"]
    print(f"Torneo creado: #{tournament_id}, doble eliminación, 64 equipos, 8 mesas configuradas")

    for seed in range(1, 65):
        status, team = await api(args.base_url, f"/api/torneos/{tournament_id}/equipos", {
            "name": f"Equipo {seed:02d}", "players": [f"Jugador {seed:02d}"], "seed": seed,
        })
        require_status(f"Register team {seed}", status, {201}, team)
    status, started = await api(args.base_url, f"/api/torneos/{tournament_id}/start", {})
    require_status("Tournament start", status, {200}, started)
    status, bracket_data = await api(args.base_url, f"/api/torneos/{tournament_id}/bracket")
    require_status("Bracket load", status, {200}, bracket_data)
    first_round = find_round_one_matches(bracket_data.get("brackets", []))
    if len(first_round) < 2:
        raise RuntimeError(f"Expected at least two first-round matches, got {len(first_round)}")
    disputed_match, dq_match = first_round[:2]
    match_path = f"/api/torneos/{tournament_id}/partidas"
    print(f"Cuadro generado: {len(bracket_data['brackets'])} brackets; espectadores conectando…")

    viewers = await asyncio.gather(*[
        open_viewer(websocket_url(args.base_url, tournament_id), args.connect_timeout)
        for _ in range(args.clients)
    ])
    print(f"Espectadores WebSocket conectados: {len(viewers)}/{args.clients}")

    team_a, team_b = disputed_match["team1_id"], disputed_match["team2_id"]
    status, first = await api(args.base_url,
        f"{match_path}/{disputed_match['id']}/resultado", {
            "team_id": team_a, "winner_team_id": team_a, "loser_team_id": team_b,
            "scores": [[team_a, 2], [team_a, 2], [team_b, 1]],
        })
    require_status("First team result", status, {200}, first)
    status, second = await api(args.base_url,
        f"{match_path}/{disputed_match['id']}/resultado", {
            "team_id": team_b, "winner_team_id": team_b, "loser_team_id": team_a,
            "scores": [[team_b, 2], [team_b, 2], [team_a, 1]],
        })
    require_status("Contradictory result", status, {202}, second)
    print(f"Disputa creada: partida #{disputed_match['id']} (ambos equipos reportaron victoria)")

    dq_team = dq_match["team1_id"]
    advancing_team = dq_match["team2_id"]
    status, dq_result = await api(args.base_url,
        f"{match_path}/{dq_match['id']}/dq", {
            "team_id": dq_team, "reason": "Descalificación a media ronda (demo)",
        })
    require_status("Disqualification", status, {200}, dq_result)
    if dq_result.get("result", {}).get("winner_team_id") != advancing_team:
        raise RuntimeError("The disqualified team's opponent was not declared the winner")

    deadline = time.monotonic() + args.verify_timeout
    advanced = False
    while time.monotonic() < deadline:
        status, latest = await api(args.base_url, f"/api/torneos/{tournament_id}/bracket")
        require_status("Bracket verification", status, {200}, latest)
        advanced = any(
            m.get("round") == 2 and advancing_team in (m.get("team1_id"), m.get("team2_id"))
            for bracket in latest.get("brackets", []) for m in bracket.get("matches", [])
        )
        if advanced:
            break
        await asyncio.sleep(0.2)
    if not advanced:
        raise RuntimeError(f"Team {advancing_team} did not appear in round two")

    try:
        print(f"Descalificación confirmada: #{dq_team}; rival #{advancing_team} avanza a ronda 2")
        print(f"Demo listo. Torneo #{tournament_id}; deja abiertas las {len(viewers)} conexiones para mostrar espectadores.")
        if args.hold_seconds:
            await asyncio.sleep(args.hold_seconds)
    finally:
        await asyncio.gather(*(ws.close() for ws in viewers), return_exceptions=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--clients", type=int, default=300)
    parser.add_argument("--connect-timeout", type=float, default=45)
    parser.add_argument("--verify-timeout", type=float, default=10)
    parser.add_argument("--hold-seconds", type=int, default=60,
                        help="keep spectators connected after the scenario (0 exits immediately)")
    args = parser.parse_args()
    if args.clients < 1 or args.hold_seconds < 0:
        parser.error("clients must be positive and hold-seconds cannot be negative")
    try:
        asyncio.run(run(args))
    except Exception as exc:
        raise SystemExit(f"Demo failed: {exc}") from exc


if __name__ == "__main__":
    main()
