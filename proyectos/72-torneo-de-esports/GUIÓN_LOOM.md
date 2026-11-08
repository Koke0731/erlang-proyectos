# Guion breve para Loom — Proyecto 72: Torneo de Esports

Duración sugerida: **4–6 minutos**. El texto entre comillas se puede leer en voz alta; las indicaciones entre corchetes son para la grabación.

## Antes de grabar

1. En la VM, compila y abre la shell:

   ```bash
   cd /home/pi/72-torneo-de-esports
   PATH=/home/pi/otp/26.2.5/bin:$PATH \
   REBAR_CACHE_DIR=/home/pi/otp/26.2.5/.cache/rebar3 \
   rebar3 compile

   PATH=/home/pi/otp/26.2.5/bin:$PATH \
   REBAR_CACHE_DIR=/home/pi/otp/26.2.5/.cache/rebar3 \
   rebar3 shell
   ```

   Deja esta terminal abierta. Si el puerto ya está ocupado, revisa el proceso con `ss -ltnp | grep ':8080'` antes de iniciar otra instancia.

2. En PowerShell de Windows, abre el túnel SSH en otra ventana y déjalo abierto:

   ```powershell
   ssh -L 0.0.0.0:8080:localhost:8080 -J 72b5d755-7a8b-457a-bec4-c2bd904106ab@proxy.app.avh.corellium.com pi@10.11.0.3
   ```

3. Confirma que la API contesta y abre el frontend:

   ```powershell
   curl.exe -i http://127.0.0.1:8080/health
   ```

   Debe responder `HTTP/1.1 200 OK`. En el navegador abre `http://127.0.0.1:8080/` y usa **Ctrl+F5** para cargar la versión más reciente.

4. En el Dashboard pulsa **Cargar torneo de demostración**. Antes de grabar, confirma que el mensaje indique resultados guardados y que el bracket muestre las partidas y marcadores. El demo usa cuatro equipos y eliminación simple.

## Guion hablado

### 1. Presentación

> “Este es el Proyecto 72, una aplicación para administrar torneos de esports. El backend está escrito en Erlang/OTP y ofrece una API HTTP y actualizaciones por WebSocket. El frontend se sirve desde la misma aplicación.”

[Muestra el Dashboard y el indicador de conexión a la API.]

### 2. Cómo está organizado

> “La aplicación usa el árbol de supervisión de OTP. Un registro administra los torneos; cada torneo tiene procesos supervisados para el bracket, las partidas, el marcador en vivo y la resolución de disputas. Cowboy sirve el frontend y las rutas de la API.”

[Si quieres mostrar código, enseña `src/p72_torneo_de_esports_sup.erl`, `src/p72_tournament_sup.erl` y `src/p72_http_server.erl`.]

### 3. Demo y bracket

> “Para que la prueba sea reproducible, cargo los datos de demostración. Se crean cuatro equipos, se genera un cuadro de eliminación simple y se simulan los resultados para que se vea cómo avanzan los ganadores hasta la final.”

[Pulsa **Cargar torneo de demostración**. Después abre **Brackets** y señala las semifinales, la final y los marcadores.]

### 4. Partidas y actividad

> “En Partidas se muestran los equipos y el detalle de la partida seleccionada. Desde aquí se pueden iniciar partidas, registrar resultados, publicar marcadores y reportar disputas. La Bitácora muestra las disputas abiertas y la actividad de las partidas.”

[Muestra las pestañas **Partidas** y **Bitácora y alertas**. Si quieres demostrar una acción, publica un marcador o reporta una disputa en una partida de prueba.]

### 5. Broadcast en vivo

> “El frontend se conecta al endpoint WebSocket del mismo servidor. Los clientes pueden suscribirse a un torneo y recibir actualizaciones de marcador y finalización de partidas.”

[Abre **Broadcast en vivo**, conecta el WebSocket y, si la conexión aparece activa, publica un marcador desde Partidas para mostrar el mensaje recibido.]

### 6. Cierre

> “La base funcional ya conecta el frontend con servicios Erlang/OTP y permite recorrer el flujo principal de un torneo. Los siguientes pasos son reforzar la persistencia, completar la integración del estado de las partidas y ampliar la cobertura de pruebas y formatos.”

## Qué está implementado

- Aplicación Erlang/OTP compilable con Rebar3 y supervisor principal.
- Registro en memoria para crear, consultar y eliminar torneos.
- Registro de equipos y generación de brackets.
- Servidor HTTP Cowboy con frontend estático, API REST y health check (`/health`).
- Pestañas del frontend para Dashboard, Brackets, Partidas, Bitácora y Broadcast.
- Acción para cargar datos demo y simular resultados en eliminación simple.
- WebSocket para suscribirse a un torneo y recibir eventos de marcador.
- Procesos OTP para partidas, puntuación en vivo, disputas y métricas.
- EUnit cubre eliminación doble de 64 equipos, dos finales cuando se reinicia la gran final, corrección de resultados propagados, byes con cinco equipos, arbitraje de disputas, descalificación/no-show, reinicio de una partida y 300 espectadores locales.

## Pendientes y límites actuales

- **Persistencia:** torneos, equipos, brackets y resultados viven en memoria; al reiniciar `rebar3 shell` se pierden. Carga el demo después del reinicio.
- **Verificación de la demo web:** antes de grabar, confirma en la VM que el botón termina mostrando resultados. La verificación automatizada cubre servicios y brackets, no una sesión real del navegador.
- **Estado de partidas:** la prueba automatizada valida transiciones y propagación, aunque una auditoría de consistencia frente a reinicios y actualizaciones concurrentes sigue pendiente.
- **Formatos:** eliminación simple y doble tienen cobertura funcional en EUnit. Suizo y grupos no están terminados. La prueba doble de 64 equipos usa posiciones potencia de dos; el caso doble con byes requiere validación adicional.
- **Pruebas automatizadas:** `rebar3 compile` y `rebar3 eunit` pasan; EUnit reporta 15 pruebas. La prueba de 300 espectadores usa procesos locales, no conexiones WebSocket reales.
- **Producción:** faltan, entre otros, almacenamiento persistente, autenticación/autorización y configuración de despliegue.

## Archivos principales

- `src/p72_torneo_de_esports_sup.erl` — supervisor raíz.
- `src/p72_tournament_registry.erl` — ciclo de vida de torneos en memoria.
- `src/p72_tournament_process.erl` — estado del torneo y registro de equipos.
- `src/p72_bracket_server.erl` — generación y avance de brackets.
- `src/p72_match_server.erl` — estado de cada partida.
- `src/p72_http_handler.erl` — rutas HTTP y serialización JSON.
- `src/p72_ws_handler.erl` — protocolo WebSocket.
- `priv/www/index.html` — dashboard del frontend.
