%% -*- mode: erlang -*-
-module(p72_tournament_sup).
-behaviour(supervisor).

-export([start_link/0, start_tournament/1, stop_tournament/1, get_tournament_sup/1,
         start_tournament_sup/1]).

-export([init/1]).

%% Supervisor for the whole tournament system (manages tournament supervisors)
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Start a new tournament supervisor tree
start_tournament(TournamentId) ->
    case supervisor:start_child(?MODULE, [TournamentId]) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        Error -> Error
    end.

%% Stop a tournament supervisor tree
stop_tournament(TournamentId) ->
    case get_tournament_sup(TournamentId) of
        {ok, Pid} -> supervisor:terminate_child(?MODULE, Pid);
        Error -> Error
    end.

get_tournament_sup(TournamentId) ->
    case global:whereis_name({?MODULE, TournamentId}) of
        undefined -> {error, not_found};
        Pid -> {ok, Pid}
    end.

%% Actual tournament supervisor (one per tournament)
start_tournament_sup(TournamentId) ->
    supervisor:start_link({global, {?MODULE, TournamentId}},
                          p72_tournament_sup, TournamentId).

init([]) ->
    %% This is the top-level tournament supervisor manager
    %% Children are added dynamically via start_tournament/1
    Child = {tournament_sup,
             {?MODULE, start_tournament_sup, []},
             permanent,
             infinity,
             supervisor,
             [?MODULE]},
    {ok, {{simple_one_for_one, 10, 60}, [Child]}};

init(TournamentId) ->
    logger:info("Iniciando supervisor para torneo ~p", [TournamentId]),

    Children = [
        %% Bracket Server - manages bracket logic
        #{id => {bracket_server, TournamentId},
          start => {p72_bracket_server, start_link, [TournamentId]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [p72_bracket_server]},

        %% Match Supervisor - dynamic supervisor for matches
        #{id => {match_sup, TournamentId},
          start => {p72_match_sup, start_link, [TournamentId]},
          restart => permanent,
          shutdown => 5000,
          type => supervisor,
          modules => [p72_match_sup]},

        %% Live Score Server - real-time scores + WebSocket broadcast
        #{id => {live_score, TournamentId},
          start => {p72_live_score_server, start_link, [TournamentId]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [p72_live_score_server]},

        %% Tournament Process - high-level tournament state machine
        #{id => {tournament_process, TournamentId},
          start => {p72_tournament_process, start_link, [TournamentId]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [p72_tournament_process]},

        %% Dispute queue for this tournament
        #{id => {dispute_resolver, TournamentId},
          start => {p72_dispute_resolver, start_link, [TournamentId]},
          restart => permanent,
          shutdown => 5000,
          type => worker,
          modules => [p72_dispute_resolver]}
    ],

    {ok, {{one_for_one, 5, 60}, Children}}.
