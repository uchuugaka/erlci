%%% @doc Starts/Stops/Monitor builds.
%%%
%%% Copyright 2017 Marcelo Gornstein &lt;marcelog@@gmail.com&gt;
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%% @end
%%% @copyright Marcelo Gornstein <marcelog@gmail.com>
%%% @author Marcelo Gornstein <marcelog@gmail.com>
%%%
-module(erlci_build_monitor).
-author("marcelog@gmail.com").
-github("https://github.com/marcelog").
-homepage("http://marcelog.github.com/").
-license("Apache License 2.0").
-behavior(gen_server).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Includes.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-include("include/erlci.hrl").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Types.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-type state():: map().

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Exports.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-export([
  start_link/0,
  init/1,
  handle_call/3,
  handle_info/2,
  handle_cast/2,
  code_change/3,
  terminate/2
]).

-export([start_build/2, build_is_running/1]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Public API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Starts and links the build monitor.
-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Starts a new build for the given job name.
-spec start_build(
  erlci_job_name(), erlci_build_description()
) -> {ok, erlci_build()} | {error, term()}.
start_build(JobName, BuildDescription) ->
  gen_server:call(?MODULE, {start_build, JobName, BuildDescription}).

%% @doc Returns true if there is a build currently running for the given
%% job name.
-spec build_is_running(erlci_job_name()) -> false | {true, erlci_build()}.
build_is_running(JobName) ->
  gen_server:call(?MODULE, {build_is_running, JobName}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% gen_server API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc http://erlang.org/doc/man/gen_server.html#Module:init-1
-spec init([]) -> {ok, state()}.
init([]) ->
  lager:debug("Build monitor started"),
  {ok, #{
    monitor_refs => [],
    current_jobs => #{}
  }}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:handle_call-3
-spec handle_call(
  term(), {pid(), term()}, state()
) -> {reply, term(), state()}.
handle_call({build_is_running, JobName}, _From, State) ->
  #{current_jobs := CurrentJobs} = State,
  Result = case maps:get(JobName, CurrentJobs, not_found) of
    not_found -> false;
    Build -> {true, Build}
  end,
  {reply, Result, State};

handle_call({start_build, JobName, BuildDescription}, _From, State) ->
  #{monitor_refs := MonitorRefs} = State,
  {Result, NewState} = try
    Job = ?JOB:load(JobName),
    Build = ?BUILD:create(Job, BuildDescription),
    {ok, BuildPid} = ?BUILD:start(Build),
    BuildRef = erlang:monitor(process, BuildPid),
    NewMonitorRefs = [{BuildRef, BuildPid, Build}|MonitorRefs],
    {{ok, Build}, State#{
      monitor_refs := NewMonitorRefs
    }}
  catch
    _:E -> {{error, E}, State}
  end,
  {reply, Result, NewState};

handle_call(Message, _From, State) ->
  lager:warning("Build Monitor got unknown request: ~p", [Message]),
  {reply, not_implemented, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:handle_cast-2
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(Message, State) ->
  lager:warning("Build Monitor got unknown msg: ~p", [Message]),
  {noreply, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:handle_info-2
-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({'DOWN', BuildRef, process, BuildPid, Info}, State) ->
  #{monitor_refs := MonitorRefs, current_jobs := CurrentJobs} = State,
  {BuildRef, BuildPid, Build} = find_build(BuildRef, MonitorRefs),
  Job = ?BUILD:job(Build),
  JobName = ?JOB:name(Job),
  lager:info(
    "Build process finished with ~p pid (~p) Build: ~p ",
    [Info, BuildPid, Build]
  ),
  {noreply, State#{current_jobs := maps:remove(JobName, CurrentJobs)}};

handle_info({build_started, BuildPid, Build}, State) ->
  #{monitor_refs := MonitorRefs, current_jobs := CurrentJobs} = State,
  {_BuildRef, BuildPid, _Build} = find_build(BuildPid, MonitorRefs),
  lager:info("Build Started with pid (~p): ~p", [BuildPid, Build]),
  Job = ?BUILD:job(Build),
  JobName = ?JOB:name(Job),
  {noreply, State#{current_jobs := maps:put(JobName, Build, CurrentJobs)}};

handle_info({build_finished, BuildPid, Build}, State) ->
  #{monitor_refs := MonitorRefs} = State,
  {_BuildRef, BuildPid, _Build} = find_build(BuildPid, MonitorRefs),
  lager:info("Build Finished with pid (~p): ~p", [BuildPid, Build]),
  {noreply, State};

handle_info(Info, State) ->
  lager:warning("Build Monitor got unknown msg: ~p", [Info]),
  {noreply, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:code_change-3
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%% @doc http://erlang.org/doc/man/gen_server.html#Module:terminate-2
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
  ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Private API.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% @doc Finds a build by monitor reference.
-spec find_build(
  reference() | pid(), [{reference(), pid(), erlci_build()}]
) -> undefined | {reference(), pid(), erlci_build()}.
find_build(_RefOrPid, []) ->
  undefined;

find_build(Ref, [Result = {Ref, _Pid, _Build}|_]) ->
  Result;

find_build(Pid, [Result = {_Ref, Pid, _Build}|_]) ->
  Result;

find_build(RefOrPid, [_|NextRefs]) ->
  find_build(RefOrPid, NextRefs).
