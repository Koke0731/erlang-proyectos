%% -*- mode: erlang -*-
-module(p72_dispute_resolver).
-behaviour(gen_server).

-include("p72_torneo_de_esports.hrl").

-export([start_link/1, submit_dispute/3, resolve_dispute/3, resolve_and_recalculate/3, escalate_dispute/2,
         resolve_and_recalculate/4,
         get_dispute/2, get_disputes_for_match/2, get_open_disputes/1]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% API
start_link(TournamentId) ->
    gen_server:start_link({global, {?MODULE, TournamentId}}, ?MODULE, TournamentId, []).

submit_dispute(TournamentId, MatchId, DisputeData) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {submit_dispute, MatchId, DisputeData}).

resolve_dispute(TournamentId, DisputeId, Resolution) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {resolve_dispute, DisputeId, Resolution}).

resolve_and_recalculate(TournamentId, DisputeId, Resolution) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {resolve_and_recalculate, DisputeId, Resolution}).

resolve_and_recalculate(TournamentId, DisputeId, Resolution, OfficialResult) ->
    gen_server:call({global, {?MODULE, TournamentId}},
                    {resolve_and_recalculate, DisputeId, Resolution, OfficialResult}).

escalate_dispute(TournamentId, DisputeId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {escalate_dispute, DisputeId}).

get_dispute(TournamentId, DisputeId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {get_dispute, DisputeId}).

get_disputes_for_match(TournamentId, MatchId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, {get_disputes_for_match, MatchId}).

get_open_disputes(TournamentId) ->
    gen_server:call({global, {?MODULE, TournamentId}}, get_open_disputes).

%% Callbacks
init(TournamentId) ->
    logger:info("~s iniciado para torneo ~p", [?MODULE, TournamentId]),
    {ok, #{
        tournament_id => TournamentId,
        disputes => #{},              %% dispute_id => #dispute{}
        match_disputes => #{},        %% match_id => [dispute_id]
        next_dispute_id => 1
    }}.

handle_call({submit_dispute, MatchId, DisputeData}, _From, State) ->
    DisputeId = maps:get(next_dispute_id, State),
    Dispute = #dispute{
        id = DisputeId,
        match_id = MatchId,
        tournament_id = maps:get(tournament_id, State),
        reported_by = maps:get(reported_by, DisputeData),
        claimed_winner = maps:get(claimed_winner, DisputeData),
        claimed_scores = maps:get(claimed_scores, DisputeData, []),
        reason = maps:get(reason, DisputeData, <<>>),
        reported_at = erlang:system_time(second),
        status = open,
        resolution = undefined,
        resolved_at = undefined,
        resolved_by = undefined
    },
    NewDisputes = maps:put(DisputeId, Dispute, maps:get(disputes, State)),
    MatchDisputes = [DisputeId | maps:get(MatchId, maps:get(match_disputes, State), [])],
    NewMatchDisputes = maps:put(MatchId, MatchDisputes, maps:get(match_disputes, State)),
    NewState = State#{
        disputes => NewDisputes,
        match_disputes => NewMatchDisputes,
        next_dispute_id => DisputeId + 1
    },
    {reply, {ok, Dispute}, NewState};

handle_call({resolve_dispute, DisputeId, Resolution}, _From, State) ->
    case maps:find(DisputeId, maps:get(disputes, State)) of
        {ok, Dispute} ->
            ResolvedDispute = Dispute#dispute{
                status = resolved,
                resolution = Resolution,
                resolved_at = erlang:system_time(second),
                resolved_by = admin  %% In real impl, get from context
            },
            NewDisputes = maps:put(DisputeId, ResolvedDispute, maps:get(disputes, State)),
            {reply, {ok, ResolvedDispute}, State#{disputes => NewDisputes}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({resolve_and_recalculate, DisputeId, Resolution}, _From, State) ->
    case maps:find(DisputeId, maps:get(disputes, State)) of
        {ok, Dispute} ->
            %% First resolve the dispute
            ResolvedDispute = Dispute#dispute{
                status = resolved,
                resolution = Resolution,
                resolved_at = erlang:system_time(second),
                resolved_by = admin
            },
            NewDisputes = maps:put(DisputeId, ResolvedDispute, maps:get(disputes, State)),
            NewState = State#{disputes => NewDisputes},
            %% Then trigger bracket recalculation
            TournamentId = maps:get(tournament_id, State),
            case p72_bracket_server:recalculate_bracket(TournamentId) of
                {ok, _Brackets} ->
                    {reply, {ok, ResolvedDispute, recalculated}, NewState};
                {error, Reason} ->
                    {reply, {ok, ResolvedDispute, {recalc_failed, Reason}}, NewState}
            end;
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({resolve_and_recalculate, DisputeId, Resolution, OfficialResult}, _From, State) ->
    case maps:find(DisputeId, maps:get(disputes, State)) of
        {ok, Dispute} ->
            TournamentId = maps:get(tournament_id, State),
            MatchId = Dispute#dispute.match_id,
            case p72_match_server:resolve_dispute(TournamentId, MatchId, OfficialResult) of
                {ok, _ResolvedResult} ->
                    ResolvedDispute = Dispute#dispute{
                        status = resolved,
                        resolution = Resolution,
                        resolved_at = erlang:system_time(second),
                        resolved_by = admin
                    },
                    NewState = State#{disputes => maps:put(
                        DisputeId, ResolvedDispute, maps:get(disputes, State))},
                    case p72_bracket_server:recalculate_bracket(TournamentId) of
                        {ok, _Brackets} ->
                            {reply, {ok, ResolvedDispute, recalculated}, NewState};
                        {error, Reason} ->
                            {reply, {ok, ResolvedDispute, {recalc_failed, Reason}}, NewState}
                    end;
                {error, Reason} -> {reply, {error, Reason}, State}
            end;
        error -> {reply, {error, not_found}, State}
    end;

handle_call({escalate_dispute, DisputeId}, _From, State) ->
    case maps:find(DisputeId, maps:get(disputes, State)) of
        {ok, Dispute} ->
            EscalatedDispute = Dispute#dispute{status = escalated},
            NewDisputes = maps:put(DisputeId, EscalatedDispute, maps:get(disputes, State)),
            {reply, {ok, EscalatedDispute}, State#{disputes => NewDisputes}};
        error ->
            {reply, {error, not_found}, State}
    end;

handle_call({get_dispute, DisputeId}, _From, State) ->
    case maps:find(DisputeId, maps:get(disputes, State)) of
        {ok, Dispute} -> {reply, {ok, Dispute}, State};
        error -> {reply, {error, not_found}, State}
    end;

handle_call({get_disputes_for_match, MatchId}, _From, State) ->
    DisputeIds = maps:get(MatchId, maps:get(match_disputes, State), []),
    Disputes = lists:map(
        fun(Id) -> maps:get(Id, maps:get(disputes, State)) end,
        DisputeIds
    ),
    {reply, {ok, Disputes}, State};

handle_call(get_open_disputes, _From, State) ->
    OpenDisputes = lists:filter(
        fun(D) -> D#dispute.status =:= open end,
        maps:values(maps:get(disputes, State))
    ),
    {reply, {ok, OpenDisputes}, State}.

handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
