%% -*- mode: erlang -*-
-module(p72_tournament_registry).
-behaviour(gen_server).

-include("p72_torneo_de_esports.hrl").

-export([start_link/0, create_tournament/1, get_tournament/1, list_tournaments/0,
         delete_tournament/1, update_tournament/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create_tournament(Req) ->
    gen_server:call(?MODULE, {create_tournament, Req}).

get_tournament(TournamentId) ->
    gen_server:call(?MODULE, {get_tournament, TournamentId}).

list_tournaments() ->
    gen_server:call(?MODULE, list_tournaments).

delete_tournament(TournamentId) ->
    gen_server:call(?MODULE, {delete_tournament, TournamentId}).

update_tournament(TournamentId, UpdateFun) ->
    gen_server:call(?MODULE, {update_tournament, TournamentId, UpdateFun}).

%% Callbacks
init([]) ->
    logger:info("~s iniciado - Tournament Registry", [?MODULE]),
    {ok, #{
        tournaments => #{},      %% tournament_id => #tournament{}
        next_id => 1,
        by_name => #{}           %% name => tournament_id
    }}.

handle_call({create_tournament, Req}, _From, State) ->
    TournamentId = maps:get(next_id, State),
    Now = erlang:system_time(second),

    Tournament = #tournament{
        id = TournamentId,
        name = maps:get(name, Req),
        format = maps:get(format, Req),
        series_format = maps:get(series_format, Req),
        max_teams = maps:get(max_teams, Req),
        state = registration_open,
        brackets = #{},
        teams = #{},
        created_at = Now,
        started_at = undefined,
        finished_at = undefined,
        config = maps:get(config, Req, #{
            tables_count => 8,
            match_duration_estimate => 45,
            allow_disputes => true,
            dispute_timeout => 300
        }),
        metadata = #{}
    },

    NewState = State#{
        tournaments => maps:put(TournamentId, Tournament, maps:get(tournaments, State)),
        next_id => TournamentId + 1,
        by_name => maps:put(maps:get(name, Req), TournamentId, maps:get(by_name, State))
    },

    %% Start tournament supervisor
    case p72_tournament_sup:start_tournament(TournamentId) of
        {ok, _SupPid} ->
            {reply, {ok, Tournament}, NewState};
        {error, Reason} ->
            %% Rollback
            RolledBack = NewState#{
                tournaments => maps:remove(TournamentId, maps:get(tournaments, NewState)),
                by_name => maps:remove(maps:get(name, Req), maps:get(by_name, NewState)),
                next_id => TournamentId
            },
            {reply, {error, Reason}, RolledBack}
    end;

handle_call({get_tournament, TournamentId}, _From, State) ->
    case maps:find(TournamentId, maps:get(tournaments, State)) of
        {ok, Tournament} -> {reply, {ok, Tournament}, State};
        error -> {reply, {error, not_found}, State}
    end;

handle_call(list_tournaments, _From, State) ->
    Tournaments = maps:values(maps:get(tournaments, State)),
    {reply, {ok, Tournaments}, State};

handle_call({delete_tournament, TournamentId}, _From, State) ->
    case maps:find(TournamentId, maps:get(tournaments, State)) of
        {ok, Tournament} ->
            %% Stop tournament supervisor
            p72_tournament_sup:stop_tournament(TournamentId),
            NewState = State#{
                tournaments => maps:remove(TournamentId, maps:get(tournaments, State)),
                by_name => maps:remove(Tournament#tournament.name, maps:get(by_name, State))
            },
            {reply, ok, NewState};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({update_tournament, TournamentId, UpdateFun}, _From, State) ->
    case maps:find(TournamentId, maps:get(tournaments, State)) of
        {ok, Tournament} ->
            NewTournament = UpdateFun(Tournament),
            NewState = State#{
                tournaments => maps:put(TournamentId, NewTournament, maps:get(tournaments, State))
            },
            {reply, {ok, NewTournament}, NewState};
        error ->
            {reply, {error, not_found}, State}
    end.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
