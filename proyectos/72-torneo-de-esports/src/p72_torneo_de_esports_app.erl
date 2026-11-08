%% -*- mode: erlang -*-
-module(p72_torneo_de_esports_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    p72_torneo_de_esports_sup:start_link().

stop(_State) ->
    ok.