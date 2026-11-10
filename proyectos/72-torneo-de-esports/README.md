# Proyecto 72: Torneo de Esports

Sistema Erlang/OTP para gestión de torneos de videojuegos con brackets, partidas simultáneas y marcadores en vivo.

## Stack Tecnológico

- **Backend**: Erlang/OTP 26+
- **Web Server**: Cowboy 2.12
- **JSON**: Jiffy
- **Logging**: Lager
- **Diagnostics**: Recon
- **Build**: Rebar3
- **Frontend**: Google Stitch (diseño UI)

## Arquitectura OTP

```
p72_torneo_de_esports_sup (top-level, one_for_one)
├── tournament_registry (gen_server)          # Gestión de torneos
├── tournament_sup (simple_one_for_one)       # Supervisa tournament_sup per torneo
│   └── tournament_sup (per torneo, one_for_one)
│       ├── bracket_server (gen_server)       # Lógica de cuadros
│       ├── match_sup (dynamic_supervisor)    # Supervisa partidas
│       │   └── match_server (gen_statem)     # scheduled → in_play → finished
│       ├── live_score_server (gen_server)    # Scores tiempo real + WS
│       ├── tournament_process (gen_statem)   # registration → in_progress → completed
│       └── dispute_resolver (gen_server)     # Resolución de conflictos
└── metrics_collector (gen_server)            # Métricas /metrics
```

## Formatos de Torneo Soportados

| Formato | Descripción | Partidas |
|---------|-------------|----------|
| `single_elim` | Eliminación simple | N-1 |
| `double_elim` | Doble eliminación (winners/losers bracket) | ~2N-2 |
| `swiss` | Valor reconocido por el modelo; flujo no validado | Pendiente |
| `groups` | Valor reconocido por el modelo; flujo no validado | Pendiente |

La generación y el avance verificados corresponden a eliminación simple y doble. No se debe presentar suizo ni grupos como formatos terminados.

## Series

- `bo1` - Best of 1
- `bo3` - Best of 3
- `bo5` - Best of 5

## Cómo ejecutar el proyecto (guía rápida)

### Requisitos

| Herramienta | Versión | Comprobación |
|---|---|---|
| Erlang/OTP | 26 o superior | `erl -version` |
| rebar3 | 3.22 o superior | `rebar3 version` |
| git | reciente | `git --version` |
| curl | opcional (probar la API) | `curl --version` |

En Ubuntu 22.04/24.04, la forma más directa de tener OTP 26 es [kerl](https://github.com/kerl/kerl) (así se aprovisionó la instancia del proyecto) o los paquetes de [Erlang Solutions](https://www.erlang-solutions.com/downloads/). El proyecto no necesita base de datos: todo el estado vive en memoria.

### 1. Clonar el repositorio

```bash
git clone https://github.com/Koke0731/erlang-proyectos.git
cd erlang-proyectos/proyectos/72-torneo-de-esports
```

La implementación del proyecto está en la rama `feature/72-torneo-implementacion`.

### 2. Compilar

```bash
rebar3 compile
```

### 3. Ejecutar las pruebas

```bash
rebar3 eunit     # 17 pruebas
rebar3 xref      # referencias cruzadas
```

### 4. Arrancar en desarrollo

```bash
rebar3 shell
```

La aplicación escucha en el puerto **8080** (se define en `config/sys.config`). Con ella iniciada:

| Recurso | URL |
|---|---|
| Dashboard | <http://localhost:8080/> |
| Health check | <http://localhost:8080/health> |
| API de torneos | <http://localhost:8080/api/torneos> |
| Métricas | <http://localhost:8080/metrics> |

Para salir de la shell de Erlang: `q().`

### 5. Arrancar como release (sin shell)

```bash
rebar3 as prod release
_build/prod/rel/p72_torneo_de_esports/bin/p72_torneo_de_esports foreground
```

En segundo plano usa `daemon` en lugar de `foreground`. Para detenerlo:

```bash
_build/prod/rel/p72_torneo_de_esports/bin/p72_torneo_de_esports stop
```

### 6. Verificar que responde

```bash
curl -s http://localhost:8080/health
# {"timestamp":1794344628,"status":"ok"}

curl -s http://localhost:8080/api/torneos
# {"tournaments":[]}
```

### 7. Servicio systemd (instancia del proyecto)

En la VM del proyecto el release está instalado como servicio:

```bash
sudo systemctl status p72-esports
sudo systemctl restart p72-esports
sudo journalctl -u p72-esports -f
```

### Problemas comunes

| Síntoma | Causa / solución |
|---|---|
| `rebar3: command not found` | añade rebar3 al `PATH` o instálalo desde <https://rebar3.org/> |
| `eaddrinuse` / puerto ocupado | algo usa el 8080: `ss -ltnp \| grep 8080`; cambia `http_port` en `config/sys.config` |
| El dashboard carga pero la API falla | revisa `journalctl -u p72-esports` o la consola de Erlang |
| Los cambios no aparecen | recompila con `rebar3 compile` y reinicia el release o el servicio |

## Frontend

Con la aplicación iniciada, el dashboard está disponible en `http://localhost:8080/`.
Incluye pestañas para torneos, brackets, equipos y partidas, disputas y marcadores en vivo.
El dashboard usa la API del mismo servidor (`/api/...`) y el WebSocket `/ws`.

Si Erlang corre en una VM de Corellium, mantén abierto un túnel SSH local hacia el puerto 8080 y abre el dashboard desde el equipo donde corre el túnel.

## API REST

### Torneos

```
POST   /api/torneos                    # Crear torneo
GET    /api/torneos                    # Listar torneos
GET    /api/torneos/:id                # Obtener torneo
DELETE /api/torneos/:id                # Eliminar torneo
POST   /api/torneos/:id/start          # Iniciar torneo
POST   /api/torneos/:id/finish         # Finalizar torneo
```

### Equipos

```
POST   /api/torneos/:id/equipos        # Registrar equipo
```

### Brackets

```
GET    /api/torneos/:id/bracket        # Obtener todos los brackets
GET    /api/torneos/:id/bracket/:bid   # Obtener bracket específico
GET    /api/torneos/:id/bracket/progress # Progreso del bracket
```

### Partidas

```
GET    /api/torneos/:id/partidas       # Listar partidas (próximas)
GET    /api/torneos/:id/partidas/:mid  # Obtener partida
POST   /api/torneos/:id/partidas/:mid/start  # Iniciar partida
POST   /api/torneos/:id/partidas/:mid/resultado  # Enviar resultado
```

### Disputas

```
POST   /api/torneos/:id/partidas/:mid/disputa  # Reportar disputa
GET    /api/torneos/:id/disputas       # Listar disputas abiertas
POST   /api/torneos/:id/disputas/:did/resolver # Resolver disputa
```

### Métricas

```
GET    /metrics                        # Métricas Prometheus-style
```

### Health Check

```
GET    /health                         # Health check
```

## WebSocket (Live Scores)

```
WS /ws?match_id=<id>&tournament_id=<id>
```

### Mensajes Cliente → Servidor

```json
{"type": "subscribe", "match_id": 1}          # Suscribirse a partida
{"type": "subscribe_tournament"}              # Suscribirse a torneo
{"type": "unsubscribe"}                       # Desuscribirse
{"type": "ping"}                              # Keepalive
```

### Mensajes Servidor → Cliente

```json
{"type": "score_update", "data": {...}}
{"type": "match_finished", "match_id": 1, "result": {...}}
{"type": "tournament_state", "data": {...}}
{"type": "pong", "timestamp": 1234567890}
```

## Ejemplo: Crear Torneo y Registrar Equipos

```bash
# Crear torneo
curl -X POST http://localhost:8080/api/torneos \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Mi Torneo",
    "format": "double_elim",
    "series_format": "bo3",
    "max_teams": 16,
    "config": {
      "tables_count": 8,
      "match_duration_estimate": 45,
      "allow_disputes": true,
      "dispute_timeout": 300
    }
  }'

# Registrar equipos
curl -X POST http://localhost:8080/api/torneos/1/equipos \
  -H "Content-Type: application/json" \
  -d '{"name": "Team Alpha", "players": ["Player1", "Player2"], "seed": 1}'

# Iniciar torneo (genera brackets)
curl -X POST http://localhost:8080/api/torneos/1/start

# Ver bracket
curl http://localhost:8080/api/torneos/1/bracket

# Enviar resultado de partida
curl -X POST http://localhost:8080/api/torneos/1/partidas/1/resultado \
  -H "Content-Type: application/json" \
  -d '{
    "team_id": 1,
    "winner_team_id": 1,
    "loser_team_id": 2,
    "scores": [[1, 2], [2, 0], [1, 2]]
  }'
```

### Demo del escenario de 64 equipos

Con la aplicación iniciada, ejecuta el simulador desde otra terminal:

```bash
python3 -m pip install websockets
python3 scripts/scenario_demo.py --base-url http://localhost:8080
```

El script crea un torneo de doble eliminación con 64 equipos y 8 mesas configuradas, conecta 300 espectadores WebSocket reales, registra dos resultados opuestos para abrir una disputa y descalifica a un equipo en otra partida. Al final comprueba que el rival del equipo descalificado aparece en la segunda ronda. Las conexiones de espectadores permanecen abiertas 60 segundos; usa `--hold-seconds 0` para cerrarlas al terminar o `--hold-seconds 300` para mantenerlas cinco minutos.

El torneo queda en memoria después de la demo; elimínalo desde el Dashboard al terminar. La aplicación guarda el número de mesas en la configuración, pero todavía no asigna ni reserva mesas automáticamente durante las partidas.

## Métricas Disponibles (/metrics)

- `tournaments_total` - Total torneos creados
- `tournaments_active` - Torneos en curso
- `matches_total` - Total partidas
- `matches_in_progress` - Partidas en juego
- `matches_finished` - Partidas finalizadas
- `matches_disputed` - Partidas en disputa
- `viewers_total` - Espectadores conectados
- `viewers_per_match` - Espectadores por partida
- `bracket_progress` - Progreso por torneo (0.0-1.0)

## Resolución de Disputas

Cuando dos equipos reportan resultados contradictorios:
1. Sistema detecta conflicto automáticamente
2. Marca partida como `disputed`
3. Crea registro en `dispute_resolver`
4. Admin resuelve via API `/disputas/:id/resolver`
5. Bracket se recalcula con resultado oficial

## Tests de Caos

```bash
# Ejecutar todos los tests
rebar3 eunit

# Test específico
rebar3 eunit --module=p72_torneo_de_esports_tests --test=arbol_de_supervision_test
```

`rebar3 eunit` ejecuta 17 pruebas. El árbol del test omite el listener HTTP porque el entorno de pruebas no permite abrir sockets; se comprueba su child spec en el supervisor raíz.

Prueba de caos reproducible (`match_process_restarts_case`): mata con `kill` un proceso `p72_match_server`; espera un PID distinto y comprueba que el servidor de marcadores del torneo sigue vivo. El supervisor informa `reason: killed` y reinicia la partida. Esta prueba no mata el bracket ni simula una caída de la VM o de la red.

También se verifican: cierre automático de la final de eliminación simple, reapertura y cierre posterior al apelar un resultado, corrección de un resultado propagado en eliminación simple, byes con cinco equipos, reportes contradictorios y arbitraje administrativo, descalificación/no-show a nivel de proceso, reserva concurrente de mesa y árbitro, doble eliminación con 64 equipos y final reiniciada, y 300 procesos espectadores que reciben un marcador en menos de 2 segundos dentro de la misma VM. Es una prueba funcional de entrega en memoria, no una prueba de carga de red ni de cientos de conexiones WebSocket reales.

### Entrega del problema #72

**Diseño OTP.** El registro y el supervisor dinámico administran la vida de cada torneo. Cada torneo supervisa su estado, bracket, marcador y disputas; cada partida usa un `gen_statem` para validar transiciones. El supervisor de partidas reinicia una partida caída sin reiniciar el bracket. El bracket mantiene los resultados y recalcula las rondas posteriores cuando se adjudica un resultado corregido. Al finalizar la final de eliminación simple el torneo pasa a `completed`; si el resultado se apela, vuelve a `in_progress` hasta que la disputa se resuelva. En doble eliminación reconstruye los cuadros y vuelve a reproducir los resultados que siguen siendo válidos para los mismos participantes. El administrador arbitra disputas; la aplicación no decide automáticamente quién dice la verdad.

**Escenario simulado.** EUnit genera 64 equipos, juega el cuadro de ganadores y perdedores hasta la final, hace que gane el campeón del cuadro de perdedores en la primera gran final y comprueba el reinicio y cierre del torneo. La ejecución final contiene 127 partidas (126 del formato más la final de reinicio). El test adicional registra 300 procesos locales como espectadores y mide la entrega de una actualización. No representa 8 mesas físicas ni 300 conexiones TCP/WebSocket.

**Supuestos.** Las cifras de 64 equipos, 8 mesas y 300 espectadores son parámetros del enunciado, no mediciones de producción. El resultado de cada serie se representa como lista de mapas ganados; el árbitro autenticado aún no existe, así que el test invoca directamente la función administrativa. La descalificación y el no-show se modelan como victoria del rival. Los byes se verifican en eliminación simple con cinco equipos; un cuadro doble con tamaño no potencia de dos todavía requiere validación específica. Los procesos mantienen estado en memoria, por lo que un reinicio total pierde el torneo.

**Cifras verificadas/documentadas.** La eliminación simple de N participantes requiere N−1 partidas; para 64 equipos son 63. El cuadro doble generado contiene 63 partidas de ganadores, 62 de perdedores y una gran final: 126 partidas; el reinicio añade una y da 127. FACEIT documenta el reinicio de la gran final cuando el equipo del cuadro de perdedores vence al equipo invicto: [guía de formatos de eliminación simple y doble](https://support.faceit.com/hc/es/articles/17048704436508-Torneos-en-formato-de-eliminaci%C3%B3n-simple-y-doble) (consultada el 6 de noviembre de 2026). Los límites de 1–2 segundos y 300 espectadores del enunciado se usan como objetivo de la prueba local, no se citan como garantía medida en producción.

**Interfaz.** Las capturas exportadas de Stitch están en [`stitch_esports_tournament_hub/`](stitch_esports_tournament_hub/): dashboard, brackets, detalle de partida y bitácora. No se adjunta captura de una sesión real del frontend en este entorno.

## Estructura de Directorios

```
├── config/
│   ├── sys.config      # Configuración app + lager
│   └── vm.args         # Parámetros VM Erlang
├── design/
│   ├── PROMPT_STITCH.md    # Prompt para Google Stitch
│   └── DESIGN.md           # Exportado desde Stitch
├── problema/
│   └── readme.md       # Descripción del problema
├── src/
│   ├── p72_torneo_de_esports.app.src
│   ├── p72_torneo_de_esports_app.erl
│   ├── p72_torneo_de_esports_sup.erl
│   ├── p72_torneo_de_esports.hrl         # Records de dominio
│   ├── p72_tournament_registry.erl       # Registro de torneos
│   ├── p72_tournament_sup.erl            # Supervisores por torneo
│   ├── p72_bracket_server.erl            # Lógica de brackets
│   ├── p72_match_sup.erl                 # Supervisor dinámico de partidas
│   ├── p72_match_server.erl              # gen_statem por partida
│   ├── p72_live_score_server.erl         # Scores tiempo real
│   ├── p72_tournament_process.erl        # Estado torneo (gen_statem)
│   ├── p72_dispute_resolver.erl          # Resolución disputas
│   ├── p72_metrics_collector.erl         # Métricas globales
│   ├── p72_http_handler.erl              # REST API (Cowboy)
│   └── p72_ws_handler.erl                # WebSocket (Cowboy)
├── test/
│   └── p72_torneo_de_esports_tests.erl   # EUnit tests
├── rebar.config
├── .gitignore
└── README.md
```

## Próximos Pasos (Roadmap)

- [ ] Pantallas Stitch UI (Dashboard, Detalle, Historial)
- [ ] Autenticación/Autorización (JWT)
- [ ] Persistencia (Mnesia/PostgreSQL)
- [ ] Notificaciones push (FCM/APNS)
- [ ] Panel admin web
- [ ] Integración con Discord/Stream overlays
- [ ] Tests de carga (tsung/wrk)
- [ ] Deploy con systemd + Docker

## Licencia

MIT
