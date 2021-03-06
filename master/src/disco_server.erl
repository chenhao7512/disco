
-module(disco_server).
-behaviour(gen_server).

-export([start_link/0, stop/0, jobhome/1, debug_flags/1, format_time/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, 
        terminate/2, code_change/3]).

-include("task.hrl").
-record(dnode, {name, blacklisted, slots, num_running, 
                stats_ok, stats_failed, stats_crashed}).

-record(state, {workers, nodes}).

-define(BLACKLIST_PERIOD, 600000).

start_link() ->
        error_logger:info_report([{"DISCO SERVER STARTS"}]),
        case gen_server:start_link({local, disco_server}, 
                        disco_server, [], debug_flags("disco_server")) of
                {ok, Server} ->
                        {ok, _} = disco_config:get_config_table(),
                        {ok, Server};
                {error, {already_started, Server}} ->
                        {ok, Server}
        end.

stop() ->
        gen_server:call(disco_server, stop).

debug_flags(Server) ->
        case os:getenv("DISCO_DEBUG") of
                "trace" -> 
                        {ok, Root} = application:get_env(disco_root),
                        A = [{debug, [{log_to_file, filename:join(Root,
                                Server ++ "_trace.log")}]}],
                        A;
                _ -> []
        end.

jobhome(JobName) when is_list(JobName) -> jobhome(list_to_binary(JobName));
jobhome(JobName) ->
        <<D0:8, _/binary>> = erlang:md5(JobName),
        [D1] = io_lib:format("~.16b", [D0]),
        Prefix = if length(D1) == 1 -> "0"; true -> "" end,
        lists:flatten([Prefix, D1, "/", binary_to_list(JobName), "/"]).

format_time(T) ->
        MS = 1000,
        SEC = 1000 * MS,
        MIN = 60 * SEC,
        HOUR = 60 * MIN,
        D = timer:now_diff(now(), T),
        Ms = (D rem SEC) div MS,
        Sec = (D rem MIN) div SEC,
        Min = (D rem HOUR) div MIN,
        Hour = D div HOUR,
        lists:flatten(io_lib:format("~B:~2.10.0B:~2.10.0B.~3.10.0B",
                [Hour, Min, Sec, Ms])).

init(_Args) ->
        process_flag(trap_exit, true),
        {ok, _} = fair_scheduler:start_link(),
        {ok, Name} = application:get_env(disco_name),
        register(slave_master, spawn_link(fun() ->
                slave_master(lists:flatten([Name, "_slave"]))
        end)),
        {ok, #state{workers = gb_trees:empty(), nodes = gb_trees:empty()}}.

handle_cast({update_config_table, Config}, S) ->
        error_logger:info_report([{"Config table update"}]),
        NewNodes = lists:foldl(fun({Node, Slots}, NewNodes) ->
                NewNode = case gb_trees:lookup(Node, S#state.nodes) of
                        none -> 
                                #dnode{name = Node,
                                       slots = Slots,
                                       blacklisted = false,
                                       stats_ok = 0,
                                       num_running = 0,
                                       stats_failed = 0,
                                       stats_crashed = 0};
                        {value, N} ->
                                #dnode{name = Node,
                                       slots = Slots,
                                       blacklisted = N#dnode.blacklisted,
                                       stats_ok = N#dnode.stats_ok,
                                       num_running = N#dnode.num_running,
                                       stats_failed = N#dnode.stats_failed,
                                       stats_crashed = N#dnode.stats_crashed}
                end,
                gb_trees:insert(Node, NewNode, NewNodes)
        end, gb_trees:empty(), Config),

        gen_server:cast(scheduler, {update_nodes, Config}),
        gen_server:cast(self(), schedule_next),
        {noreply, S#state{nodes = NewNodes}};

handle_cast(schedule_next, #state{nodes = Nodes, workers = Workers} = S) ->
        AvailableNodes = [N || #dnode{slots = X, num_running = Y, name = N,
                                        blacklisted = false}
                                        <- gb_trees:values(Nodes), X > Y],
        if AvailableNodes =/= [] ->
                case gen_server:call(scheduler, {next_task, AvailableNodes}) of
                        {ok, {JobSchedPid, {Node, Task}}} -> 
                                
                                WorkerPid = start_worker(Node, Task),
                                UWorkers = gb_trees:insert(
                                        WorkerPid, {Node, Task}, Workers),
                                gen_server:cast(JobSchedPid,
                                        {task_started, Node, WorkerPid}),

                                M = gb_trees:get(Node, Nodes),
                                UNodes = gb_trees:update(Node, 
                                        M#dnode{num_running = 
                                                M#dnode.num_running + 1},
                                                         Nodes),

                                if length(AvailableNodes) > 1 ->
                                        gen_server:cast(self, schedule_next);
                                true -> ok
                                end,
                                {noreply, S#state{nodes = UNodes,
                                        workers = UWorkers}};
                        nojobs -> 
                                {noreply, S}
                end;
        true -> {noreply, S}
        end;

handle_cast({update_stats, Node, ReplyType}, #state{nodes = Nodes} = S) ->
        N = gb_trees:get(Node, Nodes),
        M = N#dnode{num_running = N#dnode.num_running - 1},
        M0 = case ReplyType of
                job_ok ->
                        M#dnode{stats_ok = M#dnode.stats_ok + 1};
                data_error ->
                        M#dnode{stats_failed = M#dnode.stats_failed + 1};
                job_error ->
                        M#dnode{stats_crashed = M#dnode.stats_crashed + 1};
                _ ->
                        M#dnode{stats_crashed = M#dnode.stats_crashed + 1}
        end,
        {noreply, S#state{nodes = gb_trees:update(Node, M0, Nodes)}};

handle_cast({exit_worker, Pid, {Type, _} = Res}, S) ->
        {Node, Task} = gb_trees:get(Pid, S#state.workers),
        UWorkers = gb_trees:delete(Pid, S#state.workers),
        Task#task.from ! {Res, Task, Node},
        gen_server:cast(self(), {update_stats, Node, Type}),
        gen_server:cast(self(), schedule_next),
        {noreply, S#state{workers = UWorkers}};

handle_cast({purge_job, JobName}, S) ->
        % SECURITY NOTE! This function leads to the following command
        % being executed:
        %
        % os:cmd("rm -Rf " ++ filename:join([Root, JobName]))
        %
        % Evidently, if JobName is not checked correctly, this function
        % can be used to remove any directory in the system. This function
        % is totally unsuitable for untrusted environments!
        C0 = string:chr(JobName, $.) + string:chr(JobName, $/),
        C1 = string:chr(JobName, $@),
        if C0 =/= 0 orelse C1 == 0 ->
                error_logger:warning_report(
                        {"Tried to purge an invalid job", JobName});
        true ->
                spawn_link(fun() ->
                        {ok, Root} = application:get_env(disco_root),
                        handle_call({clean_job, JobName}, none, S),
                        Nodes = [lists:flatten(["dir://", Node, "/", Node, "/",
                                jobhome(JobName), "/null"]) ||
                                        #dnode{name = Node}
                                        <- gb_trees:values(S#state.nodes)],
                        garbage_collect:remove_job(Nodes),
                        garbage_collect:remove_dir(
                                filename:join([Root, jobhome(JobName)]))
                end)
        end,
        {noreply, S}.

handle_call(dbg_get_state, _, S) ->
        {reply, S, S};

handle_call({new_job, JobName, JobCoord}, _, S) ->
        {reply, catch gen_server:call(scheduler,
                {new_job, JobName, JobCoord}), S};

handle_call({new_task, Task}, _, State) ->
        case catch gen_server:call(scheduler, {new_task, Task}) of
                ok ->
                        gen_server:cast(self(), schedule_next),
                        event_server:event(Task#task.jobname, 
                                "~s:~B added to waitlist",
                                [Task#task.mode, Task#task.taskid], []),
                        {reply, ok, State};
                Error ->
                        error_logger:warning_report({"Scheduling task failed",
                                Task, Error}),
                        {reply, failed, State}
        end;

handle_call({get_active, JobName}, _From, #state{workers = Workers} = S) ->
        {Nodes, Tasks} = lists:unzip([{N, M} || 
                {N, #task{mode = M, jobname = X}} <- gb_trees:values(Workers),
                        X == JobName]),
        {reply, {ok, {Nodes, Tasks}}, S};

handle_call({get_nodeinfo, all}, _From, S) ->
       Active = [{N, Name} || {N, #task{jobname = Name}}
                <- gb_trees:values(S#state.workers)], 
       Available = lists:map(fun(N) ->
                {obj, [{node, list_to_binary(N#dnode.name)},
                       {job_ok, N#dnode.stats_ok},
                       {data_error, N#dnode.stats_failed},
                       {error, N#dnode.stats_crashed}, 
                       {max_workers, N#dnode.slots},
                       {blacklisted, N#dnode.blacklisted}]}
        end, gb_trees:values(S#state.nodes)),
        {reply, {ok, {Available, Active}}, S};

handle_call(get_num_cores, _, #state{nodes = Nodes} = S) ->
        NumCores = lists:sum([N#dnode.slots || N <- gb_trees:values(Nodes)]),
        {reply, {ok, NumCores}, S};

handle_call({kill_job, JobName}, _From, S) ->
        event_server:event(JobName, "WARN: Job killed", [], []),
        % Make sure that scheduler don't accept new tasks from this job
        gen_server:cast(scheduler, {job_done, JobName}),
        {reply, ok, S};

handle_call({clean_job, JobName}, From, State) ->
        handle_call({kill_job, JobName}, From, State),
        gen_server:cast(event_server, {clean_job, JobName}),
        {reply, ok, State};

handle_call({blacklist, Node}, _From, #state{nodes = Nodes} = S) ->
        {reply, ok, S#state{nodes = toggle_blacklist(Node, Nodes, true)}};

handle_call({whitelist, Node}, _From, #state{nodes = Nodes} = S) ->
        {reply, ok, S#state{nodes = toggle_blacklist(Node, Nodes, false)}}.

handle_info({'EXIT', Pid, normal}, S) ->
        V = gb_trees:lookup(Pid, S#state.workers),
        if V == none ->
                {noreply, S};
        true ->
                {value, {Node, T}} = V,
                error_logger:warning_report(
                        {"Task failed to call exit_worker", Node, T}),
                event_server:event(Node, T#task.jobname,
                        "WARN: [~s:~B] Died unexpectedly without a reason",
                                [T#task.mode, T#task.taskid],
                                        {task_failed, T#task.mode}),
                gen_server:cast(self(), {exit_worker, Pid,
                        {data_error, "unexpected"}}),
                {noreply, S}
        end;

handle_info({'EXIT', Pid, {worker_dies, {Msg, Args}}}, S) ->
        {Node, T} = gb_trees:get(Pid, S#state.workers),
        event_server:event(Node, T#task.jobname, "WARN: [~s:~B] ~s",
                [T#task.mode, T#task.taskid, io_lib:fwrite(Msg, Args)],
                        {task_failed, T#task.mode}),
        gen_server:cast(self(), {exit_worker, Pid, {data_error, "worker_dies"}}),
        {noreply, S};
        
handle_info({'EXIT', Pid, noconnection}, S) ->
        {Node, T} = gb_trees:get(Pid, S#state.workers),
        event_server:event(Node, T#task.jobname,
                "WARN: [~s:~B] Connection lost to the node (network busy?)",
                [T#task.mode, T#task.taskid], {task_failed, T#task.mode}),
        gen_server:cast(self(), {exit_worker, Pid, {data_error, "noconnection"}}),
        {noreply, S};

handle_info({'EXIT', Pid, Reason}, State) when Pid == self() ->
        error_logger:warning_report(["Disco server dies on error!", Reason]),
        {stop, stop_requested, State};

handle_info({'EXIT', Pid, Reason}, S) ->
        Worker = gb_trees:lookup(Pid, S#state.workers),
        if Worker =/= none ->
                {_, {Node, T}} = Worker,
                event_server:event(Node, T#task.jobname,
                        "WARN: [~s:~B] Worker died unexpectedly: ~p",
                                [T#task.mode, T#task.taskid, Reason],
                                        {task_failed, T#task.mode}),
                gen_server:cast(self(), {exit_worker, Pid,
                        {data_error, "unexpected"}});
                {noreply, S};
        true ->
                error_logger:warning_report({"Unknown exit signal", Pid, Reason}),
                {noreply, S}
        end.
                
toggle_blacklist(Node, Nodes, IsBlacklisted) ->
        case gb_trees:lookup(Node, Nodes) of
                none -> Nodes;
                {value, M} ->
                        UpdatedNodes = gb_trees:update(Node, 
                                M#dnode{blacklisted = IsBlacklisted}, Nodes),
                        Config = [{N#dnode.name, N#dnode.slots} || 
                                #dnode{blacklisted = false} = N 
                                        <- gb_trees:values(UpdatedNodes)],
                        gen_server:cast(scheduler, {update_nodes, Config}),
                        gen_server:cast(self(), schedule_next),
                        UpdatedNodes
        end.

start_worker(Node, T) ->
        event_server:event(T#task.jobname, "~s:~B assigned to ~s",
                [T#task.mode, T#task.taskid, Node], []),
        spawn_link(disco_worker, start_link_remote, 
                [self(), whereis(event_server), Node, T]).

% slave:start() contains a race condition, thus it is not safe to call it
% simultaneously in many parallel processes. Instead, we serialize the calls
% through slave_master().
slave_master(SlaveName) ->
        receive
            {start, Pid, Node, Args} -> 
                launch(fun() ->
                               slave:start(list_to_atom(Node),
                                           SlaveName, Args, self(),
                                           os:getenv("DISCO_ERLANG"))
                       end, Pid, Node),
                slave_master(SlaveName)
        end.

launch(F, Pid, Node) ->
        case catch F() of
                {ok, _} -> 
                        Pid ! slave_started;
                {error, {already_running, _}} ->
                        Pid ! slave_started;
                {error, timeout} ->
                        Pid ! {slave_failed, lists:flatten(
                                ["Couldn't connect to ", Node, " (timeout). ",
                                "Node blacklisted temporarily."])},
                        spawn_link(fun() -> blacklist_guard(Node) end);
                X ->
                        error_logger:warning_report(
                                {"Couldn't start slave at ", Node, X}),
                        Pid ! {slave_failed, lists:flatten(
                                ["Couldn't connect to ", Node,
                                ". See logs for more information. ",
                                "Node blacklisted temporarily."])},
                        spawn_link(fun() -> blacklist_guard(Node) end)
        end.

blacklist_guard(Node) ->
        error_logger:info_report({"Blacklisting", Node,
                "for", ?BLACKLIST_PERIOD, "ms."}), 
        gen_server:call(disco_server, {blacklist, Node}),
        timer:sleep(?BLACKLIST_PERIOD),
        gen_server:call(disco_server, {whitelist, Node}),
        error_logger:info_report({"Quarantine ended for", Node}).

% callback stubs
terminate(_Reason, _State) ->
        error_logger:warning_report({"Disco server dies"}).

code_change(_OldVsn, State, _Extra) -> {ok, State}.

