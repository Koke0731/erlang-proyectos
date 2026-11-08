%% -*- mode: erlang -*-
-module(p72_http_server).

-export([start_link/0]).

start_link() ->
    Port = application:get_env(p72_torneo_de_esports, http_port, 8080),
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/ws", p72_ws_handler, #{}},
            {"/", cowboy_static,
             {priv_file, p72_torneo_de_esports, "www/index.html"}},
            {"/[...]", p72_http_handler, #{}}
        ]}
    ]),
    logger:info("Iniciando API HTTP en 0.0.0.0:~p", [Port]),
    cowboy:start_clear(
        p72_http_listener,
        [{ip, {0, 0, 0, 0}}, {port, Port}],
        #{env => #{dispatch => Dispatch}}
    ).
