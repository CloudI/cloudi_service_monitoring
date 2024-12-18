%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Monitoring Metrics==
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2015-2024 Michael Truog <mjtruog at protonmail dot com>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a
%%% copy of this software and associated documentation files (the "Software"),
%%% to deal in the Software without restriction, including without limitation
%%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%%% and/or sell copies of the Software, and to permit persons to whom the
%%% Software is furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%%% DEALINGS IN THE SOFTWARE.
%%%
%%% @author Michael Truog <mjtruog at protonmail dot com>
%%% @copyright 2015-2024 Michael Truog
%%% @version 2.0.8 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_monitoring_cloudi).
-author('mjtruog at protonmail dot com').

%% external interface
-export([update_or_create/5,
         aspect_init_after_internal/0,
         aspect_init_after_external/0,
         aspect_request_before_internal/0,
         aspect_request_before_external/0,
         aspect_request_after_internal/0,
         aspect_request_after_external/0,
         aspect_info_before_internal/0,
         aspect_info_after_internal/0,
         aspect_terminate_before_internal/0,
         aspect_terminate_before_external/0,
         aspect_log/1,
         services_state/1,
         basic_update/1,
         services_init/6,
         services_terminate/1,
         services_update/8,
         nodes_update/3]).

%% internal functions used by anonymous aspect functions
-export([aspect_init/0,
         aspect_pid_to_service_id/1,
         aspect_pid_to_object/0,
         aspect_ref_to_object/2,
         aspect_cloudi/0]).

-include("cloudi_service_monitoring.hrl").
-include("cloudi_service_monitoring_cloudi.hrl").

-type pid_object() :: {pid(), metric_name(), module()}.

% monitoring config for aspects_init_after
-define(ETS_CONFIG, cloudi_service_monitoring_cloudi).
% service pid to pid_object() global lookup
-define(ETS_PID2METRIC, cloudi_service_monitoring_cloudi_pids).
% aspect function ref to pid_object() global lookup
-define(ETS_REF2METRIC, cloudi_service_monitoring_cloudi_refs).

% timeout for getting state from a service process
-define(SERVICE_PROCESS_TIMEOUT, 250). % milliseconds

-type metric_name() :: cloudi_service_monitoring:metric_name().
-type metric_list() :: cloudi_service_monitoring:metric_list().

-record(scope_data,
    {
        count_internal = 0 :: non_neg_integer(),
        count_external = 0 :: non_neg_integer(),
        concurrency_internal = 0 :: non_neg_integer(),
        concurrency_external = 0 :: non_neg_integer()
    }).

-record(service_data,
    {
        process_info :: #{pid() := #process_info{}},
        % modifications to ?ETS_PID2METRIC
        ets_insert = [] :: list(pid_object()),
        ets_delete = [] :: list(pid()),
        % metrics data
        count_internal = 0 :: non_neg_integer(),
        count_external = 0 :: non_neg_integer(),
        concurrency_internal = 0 :: non_neg_integer(),
        concurrency_external = 0 :: non_neg_integer(),
        scopes = #{} :: #{atom() := #scope_data{}},
        metrics = [] :: metric_list()
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

update_or_create(undefined, Type, Name, Value, []) ->
    try ets:lookup(?ETS_CONFIG, init) of
        [] ->
            {error, invalid_state};
        [{init, _, Driver}] ->
            cloudi_service_monitoring:update(Type,
                                             Name,
                                             Value, Driver)
    catch
        error:badarg ->
            {error, invalid_state}
    end;
update_or_create(Service, Type, Name, Value, Options) ->
    try ets:lookup(?ETS_PID2METRIC, Service) of
        [] ->
            {error, not_service};
        [{_, MetricPrefix, Driver}] ->
            [ServiceMetric] = cloudi_proplists:
                              take_values([{service_metric, false}],
                                          Options),
            if
                ServiceMetric =:= true ->
                    cloudi_service_monitoring:update(Type,
                                                     MetricPrefix ++ Name,
                                                     Value, Driver);
                ServiceMetric =:= false ->
                    cloudi_service_monitoring:update(Type,
                                                     Name,
                                                     Value, Driver)
            end
    catch
        error:badarg ->
            {error, invalid_state}
    end.

aspect_init_after_internal() ->
    aspect_init_after_internal_f().

aspect_init_after_external() ->
    aspect_init_after_external_f().

aspect_request_before_internal() ->
    aspect_request_before_internal_f(erlang:make_ref()).

aspect_request_before_external() ->
    aspect_request_before_external_f().

aspect_request_after_internal() ->
    aspect_request_after_internal_f(erlang:make_ref()).

aspect_request_after_external() ->
    aspect_request_after_external_f().

aspect_info_before_internal() ->
    aspect_info_before_internal_f(erlang:make_ref()).

aspect_info_after_internal() ->
    aspect_info_after_internal_f(erlang:make_ref()).

aspect_terminate_before_internal() ->
    aspect_terminate_before_internal_f().

aspect_terminate_before_external() ->
    aspect_terminate_before_external_f().

aspect_log(OutputTime) ->
    aspect_log_f(OutputTime).

basic_update(ProcessInfo0) ->
    LoggingPid = whereis(cloudi_core_i_logger),
    {Logging,
     ProcessInfo1} = process_info_update(LoggingPid, ProcessInfo0),
    ConfiguratorPid = whereis(cloudi_core_i_configurator),
    {Configurator,
     ProcessInfo2} = process_info_update(ConfiguratorPid, ProcessInfo1),
    ServicesMonitorPid = whereis(cloudi_core_i_services_monitor),
    {ServicesMonitor,
     ProcessInfoN} = process_info_update(ServicesMonitorPid, ProcessInfo2),
    {process_info_metrics(Logging,
                          [logging]) ++
     process_info_metrics(Configurator,
                          [configurator]) ++
     process_info_metrics(ServicesMonitor,
                          [services, monitor]),
     ProcessInfoN}.

services_state(Timeout) ->
    try sys:get_state(cloudi_core_i_services_monitor, Timeout) of
        State ->
            8 = tuple_size(State),
            state = element(1, State),
            {ok, element(2, State)}
    catch
        exit:{Reason, _} ->
            {error, Reason}
    end.

services_init(undefined, ProcessInfo0, _, _, _, _) ->
    ProcessInfo0;
services_init(Interval, ProcessInfo0,
              MetricPrefix, UseAspectsOnly, Driver, EnvironmentLookup) ->
    {ok, Services} = services_state(Interval * 1000),
    ?ETS_CONFIG = ets:new(?ETS_CONFIG,
                          [set, public, named_table,
                           {read_concurrency, true}]),
    true = ets:insert(?ETS_CONFIG, [{init, MetricPrefix, Driver}]),
    ?ETS_PID2METRIC = ets:new(?ETS_PID2METRIC,
                              [set, public, named_table,
                               {read_concurrency, true}]),
    ?ETS_REF2METRIC = ets:new(?ETS_REF2METRIC,
                              [set, public, named_table,
                               {read_concurrency, true}]),
    {InsertsN,
     ProcessInfoN} = key2value:fold1(fun(_ID, Pids,
                                                  #service{} = Service, A) ->
        ServiceMetricId = service_metric_id_from_service(Service,
                                                         EnvironmentLookup),
        lists:foldl(fun(Pid, {Inserts1, ProcessInfo1}) ->
            Inserts2 = if
                UseAspectsOnly =:= true ->
                    Inserts1;
                UseAspectsOnly =:= false ->
                    ServiceMetricPrefix = MetricPrefix ++
                                          [services | ServiceMetricId],
                    [{Pid, ServiceMetricPrefix, Driver} | Inserts1]
            end,
            {Inserts2, process_info_store(Pid, ProcessInfo1)}
        end, A, Pids)
    end, {[], ProcessInfo0}, Services),
    if
        UseAspectsOnly =:= true ->
            % rely completely on aspects_init_after to add the
            % service pid object to be used for service metrics
            ok;
        UseAspectsOnly =:= false ->
            true = ets:insert(?ETS_PID2METRIC, InsertsN)
    end,
    ProcessInfoN.

services_terminate(undefined) ->
    ok;
services_terminate(_) ->
    true = ets:delete(?ETS_CONFIG),
    true = ets:delete(?ETS_PID2METRIC),
    true = ets:delete(?ETS_REF2METRIC),
    ok.

services_update(undefined, ServicesNew, ProcessInfo0, QueuedEmptySize,
                MetricPrefix, UseAspectsOnly, Driver, EnvironmentLookup) ->
    ChangesN = key2value:
               fold1(fun(_ID, PidsNew,
                         #service{} = Service,
                         #service_data{process_info = ProcessInfo1,
                                       ets_insert = Inserts0,
                                       metrics = Metrics0} = Changes1) ->
        ServiceMetricId = service_metric_id_from_service(Service,
                                                         EnvironmentLookup),
        {Inserts3,
         ProcessInfo3} = lists:foldl(fun(PidNew, {Inserts1, ProcessInfo2}) ->
            Inserts2 = if
                UseAspectsOnly =:= true ->
                    Inserts1;
                UseAspectsOnly =:= false ->
                    [{PidNew, MetricPrefix ++ ServiceMetricId, Driver} |
                     Inserts1]
            end,
            {Inserts2, process_info_store(PidNew, ProcessInfo2)}
        end, {Inserts0, ProcessInfo1}, PidsNew),
        {Metrics1,
         ProcessInfo4} = service_metrics(PidsNew, ProcessInfo3, Service,
                                         QueuedEmptySize,
                                         ServicesNew, ServiceMetricId),
        services_accumulate(Service,
                            Changes1#service_data{process_info = ProcessInfo4,
                                                  ets_insert = Inserts3,
                                                  metrics = Metrics1 ++
                                                            Metrics0})
    end, #service_data{process_info = ProcessInfo0}, ServicesNew),
    #service_data{process_info = ProcessInfoN,
                  ets_insert = InsertsN,
                  count_internal = CountInternal,
                  count_external = CountExternal,
                  concurrency_internal = ConcurrencyInternal,
                  concurrency_external = ConcurrencyExternal,
                  scopes = Scopes,
                  metrics = MetricsN} = ChangesN,
    if
        UseAspectsOnly =:= true ->
            ok;
        UseAspectsOnly =:= false ->
            true = ets:delete_all_objects(?ETS_PID2METRIC),
            true = ets:insert(?ETS_PID2METRIC, InsertsN)
    end,
    {services_metrics(CountInternal, CountExternal,
                      ConcurrencyInternal, ConcurrencyExternal,
                      Scopes) ++ MetricsN,
     ProcessInfoN};
services_update(ServicesOld, ServicesNew, ProcessInfo0, QueuedEmptySize,
                MetricPrefix, UseAspectsOnly, Driver, EnvironmentLookup) ->
    ChangesN = key2value:
               fold1(fun(ID, PidsNew,
                         #service{} = Service,
                         #service_data{process_info = ProcessInfo1,
                                       ets_insert = Inserts0,
                                       ets_delete = Deletes0,
                                       metrics = Metrics0} = Changes1) ->
        ServiceMetricId = service_metric_id_from_service(Service,
                                                         EnvironmentLookup),
        Changes2 = case key2value:find1(ID, ServicesOld) of
            {ok, {PidsNew, #service{}}} ->
                ProcessInfo3 = lists:foldl(fun(PidNew, ProcessInfo2) ->
                    process_info_store(PidNew, ProcessInfo2)
                end, ProcessInfo1, PidsNew),
                Changes1#service_data{process_info = ProcessInfo3};
            {ok, {PidsOld, #service{}}} ->
                {Inserts3,
                 ProcessInfo3} = lists:foldl(fun(PidNew,
                                                 {Inserts1, ProcessInfo2}) ->
                    Inserts2 = case lists:member(PidNew, PidsOld) of
                        true ->
                            Inserts1;
                        false ->
                            if
                                UseAspectsOnly =:= true ->
                                    Inserts1;
                                UseAspectsOnly =:= false ->
                                    [{PidNew, MetricPrefix ++ ServiceMetricId,
                                      Driver} | Inserts1]
                            end
                    end,
                    {Inserts2, process_info_store(PidNew, ProcessInfo2)}
                end, {Inserts0, ProcessInfo1}, PidsNew),
                {Deletes3,
                 ProcessInfo5} = lists:foldl(fun(PidOld,
                                                 {Deletes1, ProcessInfo4}) ->
                    case lists:member(PidOld, PidsNew) of
                        true ->
                            {Deletes1, ProcessInfo4};
                        false ->
                            Deletes2 = if
                                UseAspectsOnly =:= true ->
                                    Deletes1;
                                UseAspectsOnly =:= false ->
                                    [PidOld | Deletes1]
                            end,
                            {Deletes2,
                             process_info_erase(PidOld, ProcessInfo4)}
                    end
                end, {Deletes0, ProcessInfo3}, PidsOld),
                Changes1#service_data{process_info = ProcessInfo5,
                                      ets_insert = Inserts3,
                                      ets_delete = Deletes3};
            error ->
                {Inserts3,
                 ProcessInfo3} = lists:foldl(fun(PidNew,
                                                 {Inserts1, ProcessInfo2}) ->
                    Inserts2 = if
                        UseAspectsOnly =:= true ->
                            Inserts1;
                        UseAspectsOnly =:= false ->
                            [{PidNew, MetricPrefix ++ ServiceMetricId,
                              Driver} | Inserts1]
                    end,
                    {Inserts2, process_info_store(PidNew, ProcessInfo2)}
                end, {Inserts0, ProcessInfo1}, PidsNew),
                Changes1#service_data{process_info = ProcessInfo3,
                                      ets_insert = Inserts3}
        end,
        #service_data{process_info = ProcessInfo6} = Changes2,
        {Metrics1,
         ProcessInfo7} = service_metrics(PidsNew, ProcessInfo6, Service,
                                         QueuedEmptySize,
                                         ServicesNew, ServiceMetricId),
        services_accumulate(Service,
                            Changes2#service_data{process_info = ProcessInfo7,
                                                  metrics = Metrics1 ++
                                                            Metrics0})
    end, #service_data{process_info = ProcessInfo0}, ServicesNew),
    #service_data{process_info = ProcessInfoN,
                  ets_insert = InsertsN,
                  ets_delete = DeletesN,
                  count_internal = CountInternal,
                  count_external = CountExternal,
                  concurrency_internal = ConcurrencyInternal,
                  concurrency_external = ConcurrencyExternal,
                  scopes = Scopes,
                  metrics = MetricsN} = ChangesN,
    if
        UseAspectsOnly =:= true ->
            ok;
        UseAspectsOnly =:= false ->
            true = ets:insert(?ETS_PID2METRIC, InsertsN),
            _ = ets:select_delete(?ETS_PID2METRIC,
                                  [{{PidOld, '_', '_'},[],[true]}
                                   || PidOld <- DeletesN]),
            ok
    end,
    {services_metrics(CountInternal, CountExternal,
                      ConcurrencyInternal, ConcurrencyExternal,
                      Scopes) ++ MetricsN,
     ProcessInfoN}.

nodes_update(NodesVisible, NodesHidden, NodesAll) ->
    [metric(gauge, [visible], NodesVisible),
     metric(gauge, [hidden], NodesHidden),
     metric(gauge, [all], NodesAll)].

%%%------------------------------------------------------------------------
%%% Internal functions used by anonymous aspect functions
%%%------------------------------------------------------------------------

aspect_init() ->
    try ets:lookup(?ETS_CONFIG, init) of
        [] ->
            undefined;
        [{init, MetricPrefix, Driver}] ->
            Pid = self(),
            case service_metric_id_from_pid(Pid) of
                undefined ->
                    undefined;
                ServiceMetricId ->
                    ServiceMetricPrefix = MetricPrefix ++
                                          [services | ServiceMetricId],
                    PidObject = {Pid, ServiceMetricPrefix, Driver},
                    true = ets:insert(?ETS_PID2METRIC, PidObject),
                    PidObject
            end
    catch
        error:badarg ->
            undefined
    end.

aspect_pid_to_service_id(Pid) ->
    try ets:lookup(?ETS_PID2METRIC, Pid) of
        [] ->
            undefined;
        [{_, MetricPrefix, _}] ->
            service_metric_id_from_metric_prefix(MetricPrefix)
    catch
        error:badarg ->
            undefined
    end.

aspect_pid_to_object() ->
    try ets:lookup(?ETS_PID2METRIC, self()) of
        [] ->
            undefined;
        [PidObject] ->
            PidObject
    catch
        error:badarg ->
            undefined
    end.

aspect_ref_to_object(Ref, Dispatcher)
    when is_reference(Ref) ->
    try ets:lookup(?ETS_REF2METRIC, Ref) of
        [] ->
            case ets:lookup(?ETS_PID2METRIC, cloudi_service:self(Dispatcher)) of
                [] ->
                    undefined;
                [PidObject] ->
                    RefObject = {Ref, PidObject},
                    true = ets:insert(?ETS_REF2METRIC, RefObject),
                    PidObject
            end;
        [{Ref, PidObject}] ->
            PidObject
    catch
        error:badarg ->
            undefined
    end.

aspect_cloudi() ->
    try ets:lookup(?ETS_CONFIG, init) of
        [] ->
            undefined;
        [{_, _, _} = Init] ->
            Init
    catch
        error:badarg ->
            undefined
    end.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

scopes_accumulate_internal(Scope, Concurrency, Scopes) ->
    maps:update_with(Scope,
                fun(#scope_data{count_internal = Count,
                                concurrency_internal = ConcurrencySum} = V) ->
        V#scope_data{count_internal = Count + 1,
                     concurrency_internal = ConcurrencySum + Concurrency}
    end, #scope_data{count_internal = 1,
                     concurrency_internal = Concurrency}, Scopes).

scopes_accumulate_external(Scope, Concurrency, Scopes) ->
    maps:update_with(Scope,
                fun(#scope_data{count_external = Count,
                                concurrency_external = ConcurrencySum} = V) ->
        V#scope_data{count_external = Count + 1,
                     concurrency_external = ConcurrencySum + Concurrency}
    end, #scope_data{count_external = 1,
                     concurrency_external = Concurrency}, Scopes).

services_accumulate(#service{service_f = ServiceF,
                             process_count = ProcessCount,
                             thread_count = ThreadCount,
                             scope = Scope},
                    #service_data{count_internal = CountInternal,
                                  count_external = CountExternal,
                                  concurrency_internal = ConcurrencyInternal,
                                  concurrency_external = ConcurrencyExternal,
                                  scopes = Scopes} = Changes) ->
    Concurrency = ProcessCount * ThreadCount,
    case service_type(ServiceF) of
        internal ->
            NewScopes = scopes_accumulate_internal(Scope, Concurrency, Scopes),
            Changes#service_data{count_internal = CountInternal + 1,
                                 concurrency_internal = ConcurrencyInternal +
                                                        Concurrency,
                                 scopes = NewScopes};
        external ->
            NewScopes = scopes_accumulate_external(Scope, Concurrency, Scopes),
            Changes#service_data{count_external = CountExternal + 1,
                                 concurrency_external = ConcurrencyExternal +
                                                        Concurrency,
                                 scopes = NewScopes}
    end.

service_process_metrics({undefined, _, _}, _, ProcessInfo0, _, _, _) ->
    {[], ProcessInfo0};
service_process_metrics({ServiceMemory, ServiceMessages, ServiceReductionsNow},
                        internal, ProcessInfo0, Pid,
                        QueuedEmptySize, MetricPrefix) ->
    case service_state(Pid) of
        {ok, State} -> % gen_server/proc_lib
            {Outgoing,
             QueuedRequests,
             QueuedRequestsSize0,
             WordSize,
             QueuedInfo,
             Memory,
             Messages,
             ReductionsNow,
             RequestPidInfo,
             InfoPidInfo,
             ProcessInfoN} = case tuple_size(State) of
                32 -> % duo_mode == false
                    state = element(1, State),
                    RequestPid = element(25, State),
                    InfoPid = element(26, State),
                    {RequestPidInfoValue,
                     ProcessInfo1} = if
                        RequestPid =:= undefined ->
                            {{undefined, undefined, undefined},
                             ProcessInfo0};
                        is_pid(RequestPid) ->
                            process_info_update(RequestPid, ProcessInfo0)
                    end,
                    {InfoPidInfoValue,
                     ProcessInfo2} = if
                        InfoPid =:= undefined ->
                            {{undefined, undefined, undefined},
                             ProcessInfo1};
                        is_pid(InfoPid) ->
                            process_info_update(InfoPid, ProcessInfo1)
                    end,
                    {map_size(element(3, State)),   % send_timeouts
                     element(11, State),            % queued
                     element(12, State),            % queued_size
                     element(13, State),            % queued_word_size
                     element(14, State),            % queued_info
                     ServiceMemory,
                     ServiceMessages,
                     ServiceReductionsNow,
                     RequestPidInfoValue,
                     InfoPidInfoValue,
                     ProcessInfo2};
                17 -> % duo_mode == true
                    state_duo = element(1, State),
                    Dispatcher =  element(15, State),
                    RequestPid = element(16, State),
                    {RequestPidInfoValue,
                     ProcessInfo1} = if
                        RequestPid =:= undefined ->
                            {{undefined, undefined, undefined},
                             ProcessInfo0};
                        is_pid(RequestPid) ->
                            process_info_update(RequestPid, ProcessInfo0)
                    end,
                    InfoPidInfoValue = {ServiceMemory,
                                        ServiceMessages,
                                        ServiceReductionsNow},
                    DispatcherOutgoing = case service_state(Dispatcher) of
                        {ok, DispatcherState} -> % gen_server/proc_lib
                            32 = tuple_size(DispatcherState),
                            state = element(1, DispatcherState),
                            map_size(element(3, DispatcherState));
                        {error, _} ->
                            undefined
                    end,
                    {MemoryValue,
                     MessagesValue,
                     ReductionsNowValue,
                     ProcessInfo3} = case process_info_update(Dispatcher,
                                                              ProcessInfo1) of
                        {{undefined, _, _}, ProcessInfo2} ->
                            {ServiceMemory,
                             ServiceMessages,
                             ServiceReductionsNow,
                             ProcessInfo2};
                        {{DispatcherMemory,
                          DispatcherMessages,
                          DispatcherReductionsNow}, ProcessInfo2}
                        when ServiceReductionsNow =:= undefined;
                             DispatcherReductionsNow =:= undefined ->
                            {ServiceMemory + DispatcherMemory,
                             ServiceMessages + DispatcherMessages,
                             undefined,
                             ProcessInfo2};
                        {{DispatcherMemory,
                          DispatcherMessages,
                          DispatcherReductionsNow}, ProcessInfo2} ->
                            {ServiceMemory + DispatcherMemory,
                             ServiceMessages + DispatcherMessages,
                             ServiceReductionsNow + DispatcherReductionsNow,
                             ProcessInfo2}
                    end,
                    {DispatcherOutgoing,
                     element(8, State),   % queued
                     element(9, State),   % queued_size
                     element(10, State),  % queued_word_size
                     element(11, State),  % queued_info
                     MemoryValue,
                     MessagesValue,
                     ReductionsNowValue,
                     RequestPidInfoValue,
                     InfoPidInfoValue,
                     ProcessInfo3}
            end,
            QueuedRequestsLength = pqueue4:len(QueuedRequests),
            QueuedRequestsSizeN = if
                QueuedRequestsLength > 0, QueuedRequestsSize0 == 0 ->
                    erlang_term:byte_size(QueuedRequests,
                                                   WordSize) -
                    QueuedEmptySize * WordSize;
                true ->
                    QueuedRequestsSize0
            end,
            QueuedInfoLength = queue:len(QueuedInfo),
            Metrics0 = [],
            Metrics1 = case RequestPidInfo of
                {undefined, _, _} ->
                    Metrics0;
                {RequestPidMemory,
                 RequestPidMessages,
                 RequestPidReductionsNow} ->
                    % the metrics here will only appear with
                    % the service configuration option request_pid_uses > 1
                    % with the metrics update becoming more
                    % likely with higher values
                    [metric(gauge, MetricPrefix ++ [request, memory],
                            RequestPidMemory),
                     metric(gauge, MetricPrefix ++ [request, message_queue_len],
                            RequestPidMessages) |
                     if
                        RequestPidReductionsNow =:= undefined ->
                            Metrics0;
                        is_integer(RequestPidReductionsNow) ->
                            [metric(spiral,
                                    MetricPrefix ++ [request, reductions],
                                    RequestPidReductionsNow) | Metrics0]
                     end]
            end,
            Metrics2 = case InfoPidInfo of
                {undefined, _, _} ->
                    Metrics1;
                {InfoPidMemory,
                 InfoPidMessages,
                 InfoPidReductionsNow} ->
                    % the metrics here will only appear with
                    % the service configuration option info_pid_uses > 1
                    % with the metrics update becoming more
                    % likely with higher values
                    [metric(gauge, MetricPrefix ++ [info, memory],
                            InfoPidMemory),
                     metric(gauge, MetricPrefix ++ [info, message_queue_len],
                            InfoPidMessages) |
                     if
                        InfoPidReductionsNow =:= undefined ->
                            Metrics1;
                        is_integer(InfoPidReductionsNow) ->
                            [metric(spiral,
                                    MetricPrefix ++ [info, reductions],
                                    InfoPidReductionsNow) | Metrics1]
                     end]
            end,
            Metrics3 = if
                Outgoing =:= undefined ->
                    Metrics2;
                is_integer(Outgoing) ->
                    [metric(gauge, MetricPrefix ++ [outgoing_requests],
                            Outgoing) | Metrics2]
            end,
            MetricsN = if
                ReductionsNow =:= undefined ->
                    Metrics3;
                is_integer(ReductionsNow) ->
                    [metric(spiral, MetricPrefix ++ [reductions],
                            ReductionsNow) | Metrics3]
            end,
            {[metric(gauge, MetricPrefix ++ [memory],
                     Memory),
              metric(gauge, MetricPrefix ++ [message_queue_len],
                     Messages),
              metric(gauge, MetricPrefix ++ [incoming_requests],
                     QueuedRequestsLength),
              metric(gauge, MetricPrefix ++ [incoming_requests_size],
                     QueuedRequestsSizeN),
              metric(gauge, MetricPrefix ++ [incoming_info],
                     QueuedInfoLength) | MetricsN],
             ProcessInfoN};
        {error, _} ->
            {[], ProcessInfo0}
    end;
service_process_metrics({ServiceMemory, ServiceMessages, ServiceReductionsNow},
                        external, ProcessInfo0, Pid,
                        QueuedEmptySize, MetricPrefix) ->
    case service_state(Pid) of
        {ok, {_, State}} -> % gen_statem
            43 = tuple_size(State),
            state = element(1, State),
            Outgoing = map_size(element(3, State)),   % send_timeouts
            QueuedRequests = element(11, State),      % queued
            QueuedRequestsSize0 = element(12, State), % queued_size
            WordSize = element(13, State),            % queued_word_size
            QueuedRequestsLength = pqueue4:len(QueuedRequests),
            QueuedRequestsSizeN = if
                QueuedRequestsLength > 0, QueuedRequestsSize0 == 0 ->
                    erlang_term:byte_size(QueuedRequests,
                                                   WordSize) -
                    QueuedEmptySize * WordSize;
                true ->
                    QueuedRequestsSize0
            end,
            MetricsN = if
                ServiceReductionsNow =:= undefined ->
                    [];
                is_integer(ServiceReductionsNow) ->
                    [metric(spiral, MetricPrefix ++ [reductions],
                            ServiceReductionsNow)]
            end,
            {[metric(gauge, MetricPrefix ++ [memory],
                     ServiceMemory),
              metric(gauge, MetricPrefix ++ [message_queue_len],
                     ServiceMessages),
              metric(gauge, MetricPrefix ++ [outgoing_requests],
                     Outgoing),
              metric(gauge, MetricPrefix ++ [incoming_requests],
                     QueuedRequestsLength),
              metric(gauge, MetricPrefix ++ [incoming_requests_size],
                     QueuedRequestsSizeN) | MetricsN],
             ProcessInfo0};
        {error, _} ->
            {[], ProcessInfo0}
    end.

service_metrics_pid_internal([], Metrics, ProcessInfo0, _, _, _) ->
    {Metrics, ProcessInfo0};
service_metrics_pid_internal([Pid | Pids], Metrics, ProcessInfo0,
                             QueuedEmptySize,
                             Services, MetricPrefix) ->
    {[_],
     #service{process_index = ProcessIndex}} =
        key2value:fetch2(Pid, Services),
    ProcessMetricPrefix = MetricPrefix ++
                          [process, erlang:integer_to_list(ProcessIndex)],
    {MetricsNew,
     ProcessInfoN} = service_process_metrics(process_info_find(Pid,
                                                               ProcessInfo0),
                                             internal, ProcessInfo0, Pid,
                                             QueuedEmptySize,
                                             ProcessMetricPrefix),
    service_metrics_pid_internal(Pids, MetricsNew ++ Metrics, ProcessInfoN,
                                 QueuedEmptySize,
                                 Services, MetricPrefix).

service_metrics_pid_external([], Metrics, ProcessInfo0, _, _, _, _) ->
    {Metrics, ProcessInfo0};
service_metrics_pid_external([Pid | Pids], Metrics, ProcessInfo0,
                             ThreadIndexLookup, QueuedEmptySize,
                             Services, MetricPrefix) ->
    {[_],
     #service{process_index = ProcessIndex}} =
        key2value:fetch2(Pid, Services),
    ThreadIndex = case maps:find(ProcessIndex, ThreadIndexLookup) of
        {ok, ThreadIndexNext} ->
            ThreadIndexNext;
        error ->
            0
    end,
    ThreadMetricPrefix = MetricPrefix ++
                         [process, erlang:integer_to_list(ProcessIndex),
                          thread, erlang:integer_to_list(ThreadIndex)],
    {MetricsNew,
     ProcessInfoN} = service_process_metrics(process_info_find(Pid,
                                                               ProcessInfo0),
                                             external, ProcessInfo0, Pid,
                                             QueuedEmptySize,
                                             ThreadMetricPrefix),
    service_metrics_pid_external(Pids, MetricsNew ++ Metrics, ProcessInfoN,
                                 maps:put(ProcessIndex,
                                          ThreadIndex + 1, ThreadIndexLookup),
                                 QueuedEmptySize,
                                 Services, MetricPrefix).

service_metrics_pid(internal, Pids, ProcessInfo,
                    QueuedEmptySize, Services, MetricPrefix) ->
    service_metrics_pid_internal(Pids, [], ProcessInfo,
                                 QueuedEmptySize, Services, MetricPrefix);
service_metrics_pid(external, Pids, ProcessInfo,
                    QueuedEmptySize, Services, MetricPrefix) ->
    service_metrics_pid_external(Pids, [], ProcessInfo, #{},
                                 QueuedEmptySize, Services, MetricPrefix).

service_metrics(Pids, ProcessInfo0,
                #service{service_f = ServiceF,
                         process_count = ProcessCount,
                         thread_count = ThreadCount},
                QueuedEmptySize, Services, MetricPrefix) ->
    Metrics0 = [metric(gauge, MetricPrefix ++ [concurrency],
                       ProcessCount * ThreadCount)],
    {Metrics1,
     ProcessInfoN} = service_metrics_pid(service_type(ServiceF),
                                         Pids, ProcessInfo0, QueuedEmptySize,
                                         Services, MetricPrefix),
    {Metrics0 ++ Metrics1, ProcessInfoN}.

service_state(Pid) ->
    try sys:get_state(Pid, ?SERVICE_PROCESS_TIMEOUT) of
        State ->
            {ok, State}
    catch
        exit:{Reason, _} ->
            {error, Reason}
    end.

services_metrics(CountInternal, CountExternal,
                 ConcurrencyInternal, ConcurrencyExternal, Scopes) ->
    maps:fold(fun(Scope, 
                  #scope_data{
                      count_internal = ScopeCountInternal,
                      count_external = ScopeCountExternal,
                      concurrency_internal = ScopeConcurrencyInternal,
                      concurrency_external = ScopeConcurrencyExternal},
                  ScopeMetrics) ->
        ScopeName = ?SCOPE_FORMAT(Scope),
        [metric(gauge, [scopes, ScopeName, concurrency],
                ScopeConcurrencyInternal + ScopeConcurrencyExternal),
         metric(gauge, [scopes, ScopeName, count],
                ScopeCountInternal + ScopeCountExternal),
         metric(gauge, [scopes, ScopeName, internal, concurrency],
                ScopeConcurrencyInternal),
         metric(gauge, [scopes, ScopeName, internal, count],
                ScopeCountInternal),
         metric(gauge, [scopes, ScopeName, external, concurrency],
                ScopeConcurrencyExternal),
         metric(gauge, [scopes, ScopeName, external, count],
                ScopeCountExternal) | ScopeMetrics]
    end,
    [metric(gauge, [scopes, count],
            map_size(Scopes)),
     metric(gauge, [concurrency],
            ConcurrencyInternal + ConcurrencyExternal),
     metric(gauge, [count],
            CountInternal + CountExternal),
     metric(gauge, [internal, concurrency],
            ConcurrencyInternal),
     metric(gauge, [internal, count],
            CountInternal),
     metric(gauge, [external, concurrency],
            ConcurrencyExternal),
     metric(gauge, [external, count],
            CountExternal)],
    Scopes).

process_info_store(Pid, ProcessInfo) ->
    case erlang:process_info(Pid, [memory, message_queue_len, reductions]) of
        [{memory, MemoryNew},
         {message_queue_len, MessagesNew},
         {reductions, ReductionsNew}] ->
            case maps:find(Pid, ProcessInfo) of
                {ok, #process_info{reductions = ReductionsOld}} ->
                    ReductionsNow = if
                        ReductionsOld =:= undefined ->
                            undefined;
                        is_integer(ReductionsOld) ->
                            ReductionsNew - ReductionsOld
                    end,
                    InfoNew = #process_info{memory = MemoryNew,
                                            message_queue_len = MessagesNew,
                                            reductions = ReductionsNew,
                                            reductions_now = ReductionsNow},
                    maps:put(Pid, InfoNew, ProcessInfo);
                error ->
                    InfoNew = #process_info{memory = MemoryNew,
                                            message_queue_len = MessagesNew,
                                            reductions = ReductionsNew},
                    maps:put(Pid, InfoNew, ProcessInfo)
            end;
        undefined ->
            maps:put(Pid, #process_info{}, ProcessInfo)
    end.

process_info_update(Pid, ProcessInfo) ->
    case erlang:process_info(Pid, [memory, message_queue_len, reductions]) of
        [{memory, MemoryNew},
         {message_queue_len, MessagesNew},
         {reductions, ReductionsNew}] ->
            case maps:find(Pid, ProcessInfo) of
                {ok, #process_info{reductions = ReductionsOld}} ->
                    ReductionsNow = if
                        ReductionsOld =:= undefined ->
                            undefined;
                        is_integer(ReductionsOld) ->
                            ReductionsNew - ReductionsOld
                    end,
                    InfoNew = #process_info{memory = MemoryNew,
                                            message_queue_len = MessagesNew,
                                            reductions = ReductionsNew,
                                            reductions_now = ReductionsNow},
                    {{MemoryNew, MessagesNew, ReductionsNow},
                     maps:put(Pid, InfoNew, ProcessInfo)};
                error ->
                    InfoNew = #process_info{memory = MemoryNew,
                                            message_queue_len = MessagesNew,
                                            reductions = ReductionsNew},
                    {{MemoryNew, MessagesNew, undefined},
                     maps:put(Pid, InfoNew, ProcessInfo)}
            end;
        undefined ->
            {{undefined, undefined, undefined},
             maps:put(Pid, #process_info{}, ProcessInfo)}
    end.

process_info_find(Pid, ProcessInfo) ->
    case maps:find(Pid, ProcessInfo) of
        {ok, #process_info{memory = Memory,
                           message_queue_len = Messages,
                           reductions_now = ReductionsNow}} ->
            {Memory, Messages, ReductionsNow};
        error ->
            {undefined, undefined, undefined}
    end.

process_info_erase(Pid, ProcessInfo) ->
    maps:remove(Pid, ProcessInfo).

process_info_metrics({Memory, Messages, ReductionsNow}, MetricPrefix) ->
    L0 = [],
    L1 = if
        Memory =:= undefined ->
            L0;
        is_integer(Memory) ->
            [metric(gauge, MetricPrefix ++ [memory],
                    Memory) | L0]
    end,
    L2 = if
        Messages =:= undefined ->
            L1;
        is_integer(Messages) ->
            [metric(gauge, MetricPrefix ++ [message_queue_len],
                    Messages) | L1]
    end,
    LN = if
        ReductionsNow =:= undefined ->
            L2;
        is_integer(ReductionsNow) ->
            [metric(spiral, MetricPrefix ++ [reductions],
                    ReductionsNow) | L2]
    end,
    LN.

service_type(start_internal) ->
    internal;
service_type(start_external) ->
    external.

metric(spiral, [_ | _] = Name, Value) ->
    {spiral, Name, Value};
metric(gauge, [_ | _] = Name, Value) ->
    {gauge, Name, Value}.

aspect_init_after_internal_f() ->
    fun(_Args, _Prefix, _Timeout, State, _Dispatcher) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_init() of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(spiral, MetricPrefix ++ [init], 1, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_init_after_external_f() ->
    fun(_CommandLine, _Prefix, _Timeout, State) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_init() of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(spiral, MetricPrefix ++ [init], 1, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_request_before_internal_f(Ref) ->
    fun(_Type, _Name, _Pattern, _RequestInfo, _Request,
        _Timeout, _Priority, _TransId, Source, State, Dispatcher) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_ref_to_object(Ref, Dispatcher) of
            {_, MetricPrefix, Driver} ->
                case ?MODULE:aspect_pid_to_service_id(Source) of
                    undefined ->
                        cloudi_service_monitoring:
                        update(spiral, MetricPrefix ++ [request, nonservice],
                               1, Driver);
                    ServiceMetricId ->
                        cloudi_service_monitoring:
                        update(spiral, MetricPrefix ++ [request |
                                                        ServiceMetricId],
                               1, Driver)
                end;
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_request_before_external_f() ->
    fun(_Type, _Name, _Pattern, _RequestInfo, _Request,
        _Timeout, _Priority, _TransId, Source, State) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_pid_to_object() of
            {_, MetricPrefix, Driver} ->
                case ?MODULE:aspect_pid_to_service_id(Source) of
                    undefined ->
                        cloudi_service_monitoring:
                        update(spiral, MetricPrefix ++ [request, nonservice],
                               1, Driver);
                    ServiceMetricId ->
                        cloudi_service_monitoring:
                        update(spiral, MetricPrefix ++ [request |
                                                        ServiceMetricId],
                               1, Driver)
                end;
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_request_after_internal_f(Ref) ->
    fun(_Type, _Name, _Pattern, _RequestInfo, _Request,
        Timeout, _Priority, _TransId, _Source, _Result, State, Dispatcher) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_ref_to_object(Ref, Dispatcher) of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(histogram, MetricPrefix ++ [request, timeout],
                       Timeout, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_request_after_external_f() ->
    fun(_Type, _Name, _Pattern, _RequestInfo, _Request,
        Timeout, _Priority, _TransId, _Source, _Result, State) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_pid_to_object() of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(histogram, MetricPrefix ++ [request, timeout],
                       Timeout, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_info_before_internal_f(Ref) ->
    fun(_Request, State, Dispatcher) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_ref_to_object(Ref, Dispatcher) of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(spiral, MetricPrefix ++ [info], 1, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_info_after_internal_f(_Ref) ->
    fun(_Request, State, _Dispatcher) ->
        % only remote function calls here to allow a module reload
        %case ?MODULE:aspect_ref_to_object(Ref, Dispatcher) of
        %    {_, MetricPrefix, Driver} ->
        %        ok;
        %    undefined ->
        %        ok
        %end,
        {ok, State}
    end.

aspect_terminate_before_internal_f() ->
    fun(_Reason, _Timeout, State) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_pid_to_object() of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(counter, MetricPrefix ++ [terminate], 1, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_terminate_before_external_f() ->
    fun(_Reason, _Timeout, State) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_pid_to_object() of
            {_, MetricPrefix, Driver} ->
                cloudi_service_monitoring:
                update(counter, MetricPrefix ++ [terminate], 1, Driver);
            undefined ->
                ok
        end,
        {ok, State}
    end.

aspect_log_f(OutputTime)
    when OutputTime =:= 'before'; OutputTime =:= 'after' ->
    fun(Level, _Timestamp, _Node, _Pid,
        _FileName, _Line, _Function, _Arity, _MetaData, _LogMessage) ->
        % only remote function calls here to allow a module reload
        case ?MODULE:aspect_cloudi() of
            {_, MetricPrefix, Driver} ->
                Name = MetricPrefix ++ [logging, output, OutputTime, Level],
                cloudi_service_monitoring:
                update(spiral, Name, 1, Driver);
            undefined ->
                ok
        end,
        ok
    end.

service_metric_id_from_service(#service{service_m = cloudi_core_i_spawn,
                                        service_f = start_internal,
                                        service_a = [_, Module,
                                                     _, _, _, _, _, _,
                                                     _, _, _, _, ID]},
                               _) ->
    service_metric_id(Module, ID);
service_metric_id_from_service(#service{service_m = cloudi_core_i_spawn,
                                        service_f = start_external,
                                        service_a = [_, FileNameEnv,
                                                     _, _, _, _, _, _, _, _,
                                                     _, _, _, _, _, ID]},
                               EnvironmentLookup) ->
    FileName = cloudi_environment:transform(FileNameEnv, EnvironmentLookup),
    service_metric_id(FileName, ID).

service_metric_id_from_pid(Pid) ->
    case erlang:process_info(Pid, dictionary) of
        {dictionary, Dictionary} ->
            case lists:keyfind(?SERVICE_ID_PDICT_KEY, 1,
                               Dictionary) of
                false ->
                    undefined;
                {_, ID} ->
                    case lists:keyfind(?SERVICE_FILE_PDICT_KEY, 1,
                                       Dictionary) of
                        false ->
                            undefined;
                        {_, FileName} ->
                            service_metric_id(FileName, ID)
                    end
            end;
        undefined ->
            undefined
    end.

service_metric_id_from_metric_prefix(MetricPrefix) ->
    [Index, MetricIdName, TypeChar | _] = lists:reverse(MetricPrefix),
    [TypeChar, MetricIdName, Index].

service_metric_id(FileName, ID)
    when is_atom(FileName) ->
    ["i",
     service_metric_id_name(FileName),
     service_metric_id_index(internal, FileName, ID)];
service_metric_id(FileName, ID)
    when is_list(FileName) ->
    ["e",
     service_metric_id_name(FileName),
     service_metric_id_index(external, FileName, ID)].

service_metric_id_name(FileName)
    when is_atom(FileName) ->
    service_metric_id_name_sanitize(erlang:atom_to_list(FileName));
service_metric_id_name(FileName)
    when is_list(FileName) ->
    service_metric_id_name_sanitize(filename:basename(FileName)).

service_metric_id_name_sanitize(Name) ->
    service_metric_id_name_sanitize(Name, []).

service_metric_id_name_sanitize([], Name) ->
    lists:reverse(Name);
service_metric_id_name_sanitize([H | T], Name) ->
    if
        (H >= $a andalso H =< $z) orelse
        (H >= $A andalso H =< $Z) orelse
        (H >= $0 andalso H =< $9) orelse
        (H == $_) ->
            service_metric_id_name_sanitize(T, [H | Name]);
        true ->
            service_metric_id_name_sanitize(T, Name)
    end.

service_metric_id_index(Type, FileName, ID) ->
    Key = {Type, FileName},
    Count = try ets:lookup(?ETS_CONFIG, Key) of
        [] ->
            true = ets:insert(?ETS_CONFIG, {Key, [ID]}),
            1;
        [{_, IDList}] ->
            case cloudi_lists:index(ID, IDList) of
                undefined ->
                    IDListNew = lists:umerge(IDList, [ID]),
                    true = ets:insert(?ETS_CONFIG, {Key, IDListNew}),
                    cloudi_lists:index(ID, IDListNew);
                CountValue ->
                    CountValue
            end
                
    catch
        error:badarg ->
            1
    end,
    erlang:integer_to_list(Count - 1).

