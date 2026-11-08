%% -*- mode: erlang -*-
-module(p72_torneo_de_esports_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%% Top-level supervisor for the entire application
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    logger:info("Iniciando supervisor principal ~s", [?MODULE]),

    Children = [
        %% Tournament Registry - manages all tournaments
        #{id => tournament_registry,
          start => {p72_tournament_registry, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [p72_tournament_registry]},

        %% Tournament Supervisor Manager - manages per-tournament supervisors
        #{id => tournament_sup_manager,
          start => {p72_tournament_sup, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [p72_tournament_sup]},

        %% Metrics Collector - global metrics
        #{id => metrics_collector,
          start => {p72_metrics_collector, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [p72_metrics_collector]},

        %% HTTP and WebSocket listener
        #{id => http_server,
          start => {p72_http_server, start_link, []},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [ranch_listener_sup]}

        %% Dispute Resolver - will be started per tournament via tournament_sup
        %% (not started here, started dynamically per tournament)
        %% TODO: Add when needed globally
    ],

    {ok, {{one_for_one, 10, 60}, Children}}.
