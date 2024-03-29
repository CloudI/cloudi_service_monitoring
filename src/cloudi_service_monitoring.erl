%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et nomod:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI Monitoring Service==
%%% This service will update monitoring metrics at regular intervals for the
%%% Erlang VM and CloudI.  To disable the update, set the interval to
%%% undefined.
%%%
%%% To allow services to provide metrics based on their execution,
%%% add service configuration option entries for aspects provided by this
%%% module (if other aspects are already being used,
%%% add it to the end of the list).  This can be done automatically with
%%% the add/1 function, if the service configuration is provided
%%% programmatically.
%%%
%%% Internal services need to add:
%%%  {aspects_init_after,
%%%   [{{cloudi_service_monitoring, aspect_init_after_internal}}]},
%%%  {aspects_request_before,
%%%   [{{cloudi_service_monitoring, aspect_request_before_internal}}]},
%%%  {aspects_request_after,
%%%   [{{cloudi_service_monitoring, aspect_request_after_internal}}]},
%%%  {aspects_info_before,
%%%   [{{cloudi_service_monitoring, aspect_info_before_internal}}]},
%%%  {aspects_info_after,
%%%   [{{cloudi_service_monitoring, aspect_info_after_internal}}]},
%%%  {aspects_terminate_before,
%%%   [{{cloudi_service_monitoring, aspect_terminate_before_internal}}]}
%%%
%%% External services need to add:
%%%  {aspects_init_after,
%%%   [{{cloudi_service_monitoring, aspect_init_after_external}}]},
%%%  {aspects_request_before,
%%%   [{{cloudi_service_monitoring, aspect_request_before_external}}]},
%%%  {aspects_request_after,
%%%   [{{cloudi_service_monitoring, aspect_request_after_external}}]},
%%%  {aspects_terminate_before,
%%%   [{{cloudi_service_monitoring, aspect_terminate_before_external}}]}
%%%
%%% To monitor logging usage, add (to the logging configuration):
%%%  {aspects_log_after,
%%%   [{{cloudi_service_monitoring, aspect_log_after}}]},
%%%
%%% @end
%%%
%%% MIT License
%%%
%%% Copyright (c) 2015-2022 Michael Truog <mjtruog at protonmail dot com>
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
%%% @copyright 2015-2022 Michael Truog
%%% @version 2.0.5 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_service_monitoring).
-author('mjtruog at protonmail dot com').

-behaviour(cloudi_service).

%% external interface
-export([update_or_create/4,
         update_or_create/5,
         add/1,
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
         aspect_log_before/0,
         aspect_log_after/0]).

%% internal interface
-export([update/4]).

%% cloudi_service callbacks
-export([cloudi_service_init/4,
         cloudi_service_handle_info/3,
         cloudi_service_terminate/3]).

-include("cloudi_service_monitoring.hrl").
-include_lib("cloudi_core/include/cloudi_constants.hrl").
-include_lib("cloudi_core/include/cloudi_logger.hrl").
-include_lib("cloudi_core/include/cloudi_service_api.hrl").

-define(DEFAULT_DRIVER,                 exometer).
-define(DEFAULT_DRIVER_OPTIONS,
        [{reporter,
          [{name, exometer_report_tty}]}]).
-define(DEFAULT_ERLANG_DRIVER_OPTIONS,
        ?DEFAULT_DRIVER_OPTIONS).
-define(DEFAULT_ERLANG_INTERVAL,              15). % seconds
-define(DEFAULT_ERLANG_PREFIX,          [erlang]).
-define(DEFAULT_ERLANG_MEMORY,
        [atom, atom_used, binary, code, ets, processes, processes_used,
         system, total]).
-define(DEFAULT_ERLANG_SYSTEM_INFO,
        [dirty_cpu_schedulers, dirty_cpu_schedulers_online,
         dirty_io_schedulers,
         logical_processors, logical_processors_available,
         logical_processors_online,
         port_count, port_limit,
         process_count, process_limit,
         schedulers, schedulers_online,
         thread_pool_size]).
-define(DEFAULT_ERLANG_STATISTICS,
        [context_switches, garbage_collection, io, reductions,
         run_queue, scheduler_wall_time]).
-define(DEFAULT_ERLANG_PROCESS_INFO,
        [message_queue_len]).
-define(DEFAULT_ERLANG_PORT_INFO,
        [memory, queue_size]).
-define(DEFAULT_INTERVAL,                     15). % seconds
-define(DEFAULT_PREFIX,                 [cloudi]).
-define(DEFAULT_USE_ASPECTS_ONLY,          false).

-type interval() :: 1..(?TIMEOUT_MAX_ERLANG div 1000).

-type exometer_reporter_name() :: atom().
-type exometer_reporter_extra() :: any().
-type exometer_interval() :: pos_integer(). % milliseconds
-type driver_exometer() :: {exometer,
                            Reporters ::
                                nonempty_list({exometer_reporter_name(),
                                               exometer_reporter_extra()}),
                            Interval :: exometer_interval(),
                            Owner :: cloudi_service:source()}.
% supported drivers
-type driver() :: driver_exometer().

-type metric_type() :: counter | spiral | gauge | histogram.
-type metric_name() :: nonempty_list(atom() | binary() | integer()).
-type metric_value() :: non_neg_integer().
-type metric_list() :: list({metric_type(), metric_name(), metric_value()}).
-export_type([metric_type/0,
              metric_name/0,
              metric_value/0,
              metric_list/0]).

-record(erlang_state,
    {
        driver :: driver() | undefined,
        metric_prefix :: metric_name(),
        memory :: list(),
        system_info :: list(),
        statistics :: list(),
        process_info :: list(),
        port_info :: list()
    }).

-record(state,
    {
        service :: pid(),
        environment :: cloudi_environment:lookup(),
        driver :: driver() | undefined,
        erlang_state :: #erlang_state{},
        erlang_interval :: interval() | undefined,
        interval :: interval() | undefined,
        metric_prefix :: metric_name(),
        aspects_only :: boolean(),
        services :: key2value:
                    key2value(cloudi_service_api:service_id(),
                                       pid(), tuple()) | undefined,
        process_info :: #{pid() := #process_info{}},
        queue_empty_size :: non_neg_integer(),
        nodes_visible :: non_neg_integer(),
        nodes_hidden :: non_neg_integer(),
        nodes_all :: non_neg_integer()
    }).

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

%%-------------------------------------------------------------------------
%% @doc
%% ===Update/Create a metric.===
%% Use cloudi_service:self/1 to get the service process when passing a
%% service metric, otherwise use 'undefined' instead of the service process.
%% @end
%%-------------------------------------------------------------------------

-spec update_or_create(Service :: cloudi_service:source() | undefined,
                       Type :: metric_type(),
                       Name :: metric_name(),
                       Value :: metric_value()) ->
    ok | {error, any()}.

update_or_create(undefined, Type, Name, Value) ->
    cloudi_service_monitoring_cloudi:update_or_create(undefined,
                                                      Type, Name, Value,
                                                      []);
update_or_create(Service, Type, Name, Value) ->
    update_or_create(Service, Type, Name, Value, []).

%%-------------------------------------------------------------------------
%% @doc
%% ===Update/Create a metric with options.===
%% Must be called from a service process.  Use cloudi_service:self/1
%% to get the service process.  The option service_metric determines
%% whether the cloudi_service_monitoring service metric prefix is used
%% (which includes the service id, service_metric defaults to false).
%% @end
%%-------------------------------------------------------------------------

-spec update_or_create(Service :: cloudi_service:source(),
                       Type :: metric_type(),
                       Name :: metric_name(),
                       Value :: metric_value(),
                       Options :: list({service_metric, boolean()})) ->
    ok | {error, any()}.

update_or_create(Service, Type, Name, Value, Options)
    when is_pid(Service) ->
    cloudi_service_monitoring_cloudi:update_or_create(Service,
                                                      Type, Name, Value,
                                                      Options).

%%-------------------------------------------------------------------------
%% @doc
%% ===Add cloudi_service_monitoring service configuration options.===
%% Programmatically adds service configuration options to provide
%% service metrics based on service events.
%% @end
%%-------------------------------------------------------------------------

-spec add(cloudi_service_api:service_internal() |
          cloudi_service_api:service_external() |
          cloudi_service_api:service_proplist()) ->
    cloudi_service_api:service_internal() |
    cloudi_service_api:service_external() |
    cloudi_service_api:service_proplist().

add(#internal{options = Options} = ServiceConfig) ->
    ServiceConfig#internal{options = add_options(internal, Options)};
add(#external{options = Options} = ServiceConfig) ->
    ServiceConfig#external{options = add_options(external, Options)};
add([_ | _] = ServiceConfig) ->
    Type = case lists:keyfind(module, 1, ServiceConfig) of
        {_, _} ->
            internal;
        false ->
            external
    end,
    case lists:keytake(options, 1, ServiceConfig) of
        {value, {_, Options}, NextServiceConfig} ->
            [{options, add_options(Type, Options)} | NextServiceConfig];
        false ->
            [{options, add_options(Type, [])} | ServiceConfig]
    end.

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_init_after service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_init_after_internal}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_init_after_internal() ->
    cloudi_service_api:aspect_init_after_internal_f().

aspect_init_after_internal() ->
    cloudi_service_monitoring_cloudi:aspect_init_after_internal().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_init_after service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_init_after_external}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_init_after_external() ->
    cloudi_service_api:aspect_init_after_external_f().

aspect_init_after_external() ->
    cloudi_service_monitoring_cloudi:aspect_init_after_external().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_request_before service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_request_before_internal}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_request_before_internal() ->
    cloudi_service_api:aspect_request_before_internal_f().

aspect_request_before_internal() ->
    cloudi_service_monitoring_cloudi:aspect_request_before_internal().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_request_before service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_request_before_external}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_request_before_external() ->
    cloudi_service_api:aspect_request_before_external_f().

aspect_request_before_external() ->
    cloudi_service_monitoring_cloudi:aspect_request_before_external().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_request_after service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_request_after_internal}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_request_after_internal() ->
    cloudi_service_api:aspect_request_after_internal_f().

aspect_request_after_internal() ->
    cloudi_service_monitoring_cloudi:aspect_request_after_internal().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_request_after service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_request_after_external}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_request_after_external() ->
    cloudi_service_api:aspect_request_after_external_f().

aspect_request_after_external() ->
    cloudi_service_monitoring_cloudi:aspect_request_after_external().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_info_before service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_info_before_internal}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_info_before_internal() ->
    cloudi_service_api:aspect_info_before_internal_f().

aspect_info_before_internal() ->
    cloudi_service_monitoring_cloudi:aspect_info_before_internal().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_info_after service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_info_after_internal}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_info_after_internal() ->
    cloudi_service_api:aspect_info_after_internal_f().

aspect_info_after_internal() ->
    cloudi_service_monitoring_cloudi:aspect_info_after_internal().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_terminate_before service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_terminate_before_internal}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_terminate_before_internal() ->
    cloudi_service_api:aspect_terminate_before_internal_f().

aspect_terminate_before_internal() ->
    cloudi_service_monitoring_cloudi:aspect_terminate_before_internal().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_terminate_before service configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_terminate_before_external}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_terminate_before_external() ->
    cloudi_service_api:aspect_terminate_before_external_f().

aspect_terminate_before_external() ->
    cloudi_service_monitoring_cloudi:aspect_terminate_before_external().

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_log_before logging configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_log_before}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_log_before() ->
    cloudi_service_api:aspect_log_f().

aspect_log_before() ->
    cloudi_service_monitoring_cloudi:aspect_log('before').

%%-------------------------------------------------------------------------
%% @doc
%% ===Function for aspects_log_after logging configuration option.===
%% Add as {{cloudi_service_monitoring, aspect_log_after}}.
%% @end
%%-------------------------------------------------------------------------

-spec aspect_log_after() ->
    cloudi_service_api:aspect_log_f().

aspect_log_after() ->
    cloudi_service_monitoring_cloudi:aspect_log('after').

%%%------------------------------------------------------------------------
%%% Internal interface functions
%%%------------------------------------------------------------------------
                                     
-spec update(Type :: metric_type(),
             Name :: metric_name(),
             Value :: metric_value(),
             Driver :: driver()) ->
    ok.

update(Type, Name, Value,
       {exometer, Reporters, Interval, Owner}) ->
    case exometer:update(Name, Value) of
        ok ->
            ok;
        {error, not_found} ->
            Opts = [],
            try exometer:ensure(Name, Type, Opts) of
                ok ->
                    case exometer:update(Name, Value) of
                        ok ->
                            % automatically delete the metric when the
                            % cloudi_service_monitoring process dies
                            exometer_admin:monitor(Name, Owner),
                            % reporters subscribe dynamically
                            DataPoints = if
                                Type =:= spiral ->
                                    [count,one];
                                Type =:= histogram ->
                                    [n,mean,min,max,median,50,75,90,95,99,999];
                                Type =:= gauge;
                                Type =:= counter ->
                                    [value]
                            end,
                            Retry = false,
                            lists:foreach(fun({ReporterName, Extra}) ->
                                case exometer_report:
                                     subscribe(ReporterName,
                                               Name,
                                               DataPoints,
                                               Interval,
                                               Extra,
                                               Retry) of
                                    ok ->
                                        ok;
                                    Reason ->
                                        ?LOG_ERROR("exometer_report:"
                                                   "subscribe/6 "
                                                   "error: ~p", [Reason])
                                end
                            end, Reporters);
                        {error, Reason} ->
                            ?LOG_ERROR("exometer:update/2 "
                                       "error: ~p", [Reason])
                    end
            catch
                error:Reason ->
                    ?LOG_ERROR("exometer:ensure/3 "
                               "error: ~p", [Reason])
            end
    end.

%%%------------------------------------------------------------------------
%%% Callback functions from cloudi_service
%%%------------------------------------------------------------------------

cloudi_service_init(Args, _Prefix, _Timeout, Dispatcher) ->
    Defaults = [
        {driver,                     ?DEFAULT_DRIVER},
        {driver_options,             ?DEFAULT_DRIVER_OPTIONS},
        {erlang_driver_options,      ?DEFAULT_ERLANG_DRIVER_OPTIONS},
        {erlang_interval,            ?DEFAULT_ERLANG_INTERVAL},
        {erlang_prefix,              ?DEFAULT_ERLANG_PREFIX},
        {erlang_memory,              ?DEFAULT_ERLANG_MEMORY},
        {erlang_system_info,         ?DEFAULT_ERLANG_SYSTEM_INFO},
        {erlang_statistics,          ?DEFAULT_ERLANG_STATISTICS},
        {erlang_process_info,        ?DEFAULT_ERLANG_PROCESS_INFO},
        {erlang_port_info,           ?DEFAULT_ERLANG_PORT_INFO},
        {interval,                   ?DEFAULT_INTERVAL},
        {prefix,                     ?DEFAULT_PREFIX},
        {use_aspects_only,           ?DEFAULT_USE_ASPECTS_ONLY}],
    [DriverName, DriverOptions, ErlangDriverOptions,
     ErlangInterval, ErlangMetricPrefix, ErlangMemory,
     ErlangSystemInfo, ErlangStatistics, ErlangProcessInfo, ErlangPortInfo,
     Interval, MetricPrefix, UseAspectsOnly
     ] = cloudi_proplists:take_values(Defaults, Args),
    Service = cloudi_service:self(Dispatcher),
    1 = cloudi_service:process_count_max(Dispatcher),
    true = (ErlangInterval =:= undefined) orelse
           (is_integer(ErlangInterval) andalso
            (ErlangInterval > 0) andalso
            (ErlangInterval =< ?TIMEOUT_MAX_ERLANG div 1000)),
    true = (Interval =:= undefined) orelse
           (is_integer(Interval) andalso
            (Interval > 0) andalso
            (Interval =< ?TIMEOUT_MAX_ERLANG div 1000)),
    true = (ErlangInterval /= undefined) orelse
           (Interval /= undefined),
    true = is_list(ErlangDriverOptions),
    ErlangDriver = if
        DriverName =:= exometer ->
            if
                ErlangInterval =:= undefined ->
                    undefined;
                is_integer(ErlangInterval),
                is_tuple(hd(ErlangDriverOptions)) ->
                    {exometer,
                     exometer_reporters(ErlangDriverOptions),
                     ErlangInterval * 1000, Service}
            end
    end,
    true = is_list(DriverOptions),
    Driver = if
        DriverName =:= exometer ->
            if
                Interval =:= undefined ->
                    undefined;
                is_integer(Interval),
                is_tuple(hd(DriverOptions)) ->
                    {exometer,
                     exometer_reporters(DriverOptions),
                     Interval * 1000, Service}
            end
    end,
    true = is_atom(hd(ErlangMetricPrefix)) andalso
           lists:all(fun is_atom/1, ErlangMetricPrefix),
    true = is_list(ErlangMemory),
    [] = ErlangMemory --
         [atom,
          atom_used,
          binary,
          code,
          ets,
          processes,
          processes_used,
          system,
          total],
    true = is_list(ErlangSystemInfo),
    [] = ErlangSystemInfo --
         [dirty_cpu_schedulers,
          dirty_cpu_schedulers_online,
          dirty_io_schedulers,
          logical_processors,
          logical_processors_available,
          logical_processors_online,
          port_count,
          port_limit,
          process_count,
          process_limit,
          schedulers,
          schedulers_online,
          thread_pool_size],
    true = is_list(ErlangStatistics),
    [] = ErlangStatistics --
         [context_switches,
          garbage_collection,
          io,
          reductions,
          run_queue,
          scheduler_wall_time],
    true = is_list(ErlangProcessInfo),
    [] = ErlangProcessInfo --
         [message_queue_len],
    true = is_list(ErlangPortInfo),
    [] = ErlangPortInfo --
         [memory,
          queue_size],
    true = is_atom(hd(MetricPrefix)) andalso
           lists:all(fun is_atom/1, MetricPrefix),
    true = is_boolean(UseAspectsOnly),
    EnvironmentLookup = cloudi_environment:lookup(),
    ProcessInfo0 = #{},
    ProcessInfoN = cloudi_service_monitoring_cloudi:
                   services_init(Interval, ProcessInfo0, MetricPrefix,
                                 UseAspectsOnly, Driver, EnvironmentLookup),
    % no binaries are stored within pqueue4, so using 1 for the word size works
    QueuedEmptySize = erlang_term:byte_size(pqueue4:new(), 1),
    ErlangState = erlang_init(ErlangMetricPrefix,
                              ErlangMemory,
                              ErlangSystemInfo,
                              ErlangStatistics,
                              ErlangProcessInfo,
                              ErlangPortInfo,
                              ErlangDriver),
    if
        ErlangInterval =:= undefined ->
            ok;
        is_integer(ErlangInterval) ->
            _ = erlang:send_after(ErlangInterval * 1000, Service,
                                  erlang_update),
            ok
    end,
    if
        Interval =:= undefined ->
            ok;
        is_integer(Interval) ->
            _ = erlang:send_after(Interval * 1000, Service,
                                  cloudi_update),
            ok
    end,
    ok = monitor_nodes(true, cpg_app:listen_type()),
    {ok, #state{service = Service,
                environment = EnvironmentLookup,
                driver = Driver,
                erlang_state = ErlangState,
                erlang_interval = ErlangInterval,
                interval = Interval,
                metric_prefix = MetricPrefix,
                services = undefined,
                process_info = ProcessInfoN,
                queue_empty_size = QueuedEmptySize,
                aspects_only = UseAspectsOnly,
                nodes_visible = erlang:length(erlang:nodes(visible)),
                nodes_hidden = erlang:length(erlang:nodes(hidden)),
                nodes_all = erlang:length(erlang:nodes(connected))}}.

cloudi_service_handle_info(cloudi_update,
                           #state{service = Service,
                                  environment = EnvironmentLookup,
                                  driver = Driver,
                                  interval = Interval,
                                  metric_prefix = MetricPrefix,
                                  services = ServicesOld,
                                  process_info = ProcessInfo0,
                                  queue_empty_size = QueuedEmptySize,
                                  aspects_only = UseAspectsOnly,
                                  nodes_visible = NodesVisible,
                                  nodes_hidden = NodesHidden,
                                  nodes_all = NodesAll} = State,
                           _Dispatcher) ->
    erlang:send_after(Interval * 1000, Service, cloudi_update),
    Start = cloudi_timestamp:milliseconds_monotonic(),
    ServicesNew = case cloudi_service_monitoring_cloudi:
                       services_state(Interval * 1000) of
        {ok, ServicesUpdate} ->
            ServicesUpdate;
        {error, Reason} ->
            ?LOG_ERROR("cloudi_update failed: ~p", [Reason]),
            undefined
    end,
    {BasicMetrics,
     ProcessInfo1} = cloudi_service_monitoring_cloudi:
                     basic_update(ProcessInfo0),
    {ServicesMetrics, ProcessInfoN} = if
        ServicesNew /= undefined ->
            cloudi_service_monitoring_cloudi:
            services_update(ServicesOld, ServicesNew, ProcessInfo1,
                            QueuedEmptySize, MetricPrefix ++ [services],
                            UseAspectsOnly, Driver, EnvironmentLookup);
        true ->
            {[], ProcessInfo1}
    end,
    NodesMetrics = cloudi_service_monitoring_cloudi:
                   nodes_update(NodesVisible, NodesHidden, NodesAll),
    ok = update(BasicMetrics,
                MetricPrefix, Driver),
    ok = update(ServicesMetrics,
                MetricPrefix ++ [services], Driver),
    ok = update(NodesMetrics,
                MetricPrefix ++ [nodes], Driver),
    Elapsed = cloudi_timestamp:milliseconds_monotonic() - Start,
    if
        Elapsed > (Interval * 1000) div 2 ->
            ?LOG_WARN("CloudI update took ~.3f s", [Elapsed / 1000]);
        true ->
            ok
    end,
    {noreply, State#state{services = ServicesNew,
                          process_info = ProcessInfoN}};
cloudi_service_handle_info(erlang_update,
                           #state{service = Service,
                                  erlang_state = ErlangStateOld,
                                  erlang_interval = ErlangInterval} = State,
                           _Dispatcher) ->
    erlang:send_after(ErlangInterval * 1000, Service, erlang_update),
    Start = cloudi_timestamp:milliseconds_monotonic(),
    ErlangStateNew = erlang_update(ErlangStateOld),
    Elapsed = cloudi_timestamp:milliseconds_monotonic() - Start,
    if
        Elapsed > (ErlangInterval * 1000) div 2 ->
            ?LOG_WARN("Erlang update took ~.3f s", [Elapsed / 1000]);
        true ->
            ok
    end,
    {noreply, State#state{erlang_state = ErlangStateNew}};
cloudi_service_handle_info({nodeup, _Node, OptionList},
                           State, _Dispatcher) ->
    {_, NodeType} = lists:keyfind(node_type, 1, OptionList),
    {noreply, node_update(NodeType, 1, State)};
cloudi_service_handle_info({nodedown, _Node, OptionList},
                           State, _Dispatcher) ->
    {_, NodeType} = lists:keyfind(node_type, 1, OptionList),
    {noreply, node_update(NodeType, -1, State)};
cloudi_service_handle_info(Request, State, _Dispatcher) ->
    {stop, cloudi_string:format("Unknown info \"~w\"", [Request]), State}.

cloudi_service_terminate(_Reason, _Timeout, undefined) ->
    ok;
cloudi_service_terminate(_Reason, _Timeout,
                         #state{interval = Interval}) ->
    ok = cloudi_service_monitoring_cloudi:services_terminate(Interval),
    ok.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

monitor_nodes(Flag, Listen) ->
    net_kernel:monitor_nodes(Flag, [{node_type, Listen}]).

node_update(all, Change,
            #state{nodes_visible = NodesVisible,
                   nodes_hidden = NodesHidden,
                   nodes_all = NodesAll} = State) ->
    State#state{nodes_visible = NodesVisible + Change,
                nodes_hidden = NodesHidden + Change,
                nodes_all = NodesAll + Change};
node_update(visible, Change,
            #state{nodes_visible = NodesVisible,
                   nodes_all = NodesAll} = State) ->
    State#state{nodes_visible = NodesVisible + Change,
                nodes_all = NodesAll + Change};
node_update(hidden, Change,
            #state{nodes_hidden = NodesHidden,
                   nodes_all = NodesAll} = State) ->
    State#state{nodes_hidden = NodesHidden + Change,
                nodes_all = NodesAll + Change}.

erlang_init(ErlangMetricPrefix, _, _, _, _, _, undefined) ->
    #erlang_state{driver = undefined,
                  metric_prefix = ErlangMetricPrefix,
                  memory = [],
                  system_info = [],
                  statistics = [],
                  process_info = [],
                  port_info = []};
erlang_init(ErlangMetricPrefix,
            ErlangMemory, ErlangSystemInfo, ErlangStatistics,
            ErlangProcessInfo, ErlangPortInfo, ErlangDriver) ->
    MemoryEntries = cloudi_service_monitoring_erlang:
                    memory_init(ErlangMemory),
    SystemInfoEntries = cloudi_service_monitoring_erlang:
                        system_info_init(ErlangSystemInfo),
    StatisticsEntries = cloudi_service_monitoring_erlang:
                        statistics_init(ErlangStatistics),
    ProcessInfoEntries = cloudi_service_monitoring_erlang:
                         process_info_init(ErlangProcessInfo),
    PortInfoEntries = cloudi_service_monitoring_erlang:
                      port_info_init(ErlangPortInfo),
    #erlang_state{driver = ErlangDriver,
                  metric_prefix = ErlangMetricPrefix,
                  memory = MemoryEntries,
                  system_info = SystemInfoEntries,
                  statistics = StatisticsEntries,
                  process_info = ProcessInfoEntries,
                  port_info = PortInfoEntries}.

erlang_update(#erlang_state{driver = ErlangDriver,
                            metric_prefix = ErlangMetricPrefix,
                            memory = MemoryEntriesOld,
                            system_info = SystemInfoEntriesOld,
                            statistics = StatisticsEntriesOld,
                            process_info = ProcessInfoEntriesOld,
                            port_info = PortInfoEntriesOld} = ErlangState) ->
    BasicMetrics = cloudi_service_monitoring_erlang:
                   basic_update(),
    {MemoryMetrics,
     MemoryEntriesNew} = cloudi_service_monitoring_erlang:
                         memory_update(MemoryEntriesOld),
    {SystemInfoMetrics,
     SystemInfoEntriesNew} = cloudi_service_monitoring_erlang:
                             system_info_update(SystemInfoEntriesOld),
    {StatisticsMetrics,
     StatisticsEntriesNew} = cloudi_service_monitoring_erlang:
                             statistics_update(StatisticsEntriesOld),
    {ProcessInfoMetrics,
     ProcessInfoEntriesNew} = cloudi_service_monitoring_erlang:
                              process_info_update(ProcessInfoEntriesOld),
    {PortInfoMetrics,
     PortInfoEntriesNew} = cloudi_service_monitoring_erlang:
                           port_info_update(PortInfoEntriesOld),
    ok = update(BasicMetrics,
                ErlangMetricPrefix, ErlangDriver),
    ok = update(MemoryMetrics,
                ErlangMetricPrefix ++ [memory], ErlangDriver),
    ok = update(SystemInfoMetrics,
                ErlangMetricPrefix ++ [system_info], ErlangDriver),
    ok = update(StatisticsMetrics,
                ErlangMetricPrefix ++ [statistics], ErlangDriver),
    ok = update(ProcessInfoMetrics,
                ErlangMetricPrefix ++ [process_info], ErlangDriver),
    ok = update(PortInfoMetrics,
                ErlangMetricPrefix ++ [port_info], ErlangDriver),
    ErlangState#erlang_state{memory = MemoryEntriesNew,
                             system_info = SystemInfoEntriesNew,
                             statistics = StatisticsEntriesNew,
                             process_info = ProcessInfoEntriesNew,
                             port_info = PortInfoEntriesNew}.

add_options(internal = Type, Options0) ->
    Options1 = add_option(Type, aspects_init_after, Options0),
    Options2 = add_option(Type, aspects_request_before, Options1),
    Options3 = add_option(Type, aspects_request_after, Options2),
    Options4 = add_option(Type, aspects_info_before, Options3),
    OptionsN = add_option(Type, aspects_info_after, Options4),
    add_option(Type, aspects_terminate_before, OptionsN);
add_options(external = Type, Options0) ->
    Options1 = add_option(Type, aspects_init_after, Options0),
    Options2 = add_option(Type, aspects_request_before, Options1),
    OptionsN = add_option(Type, aspects_request_after, Options2),
    add_option(Type, aspects_terminate_before, OptionsN).

add_option(Type, Option, Options) ->
    F = if
        Option =:= aspects_init_after ->
            if
                Type =:= internal ->
                    aspect_init_after_internal;
                Type =:= external ->
                    aspect_init_after_external
            end;
        Option =:= aspects_request_before ->
            if
                Type =:= internal ->
                    aspect_request_before_internal;
                Type =:= external ->
                    aspect_request_before_external
            end;
        Option =:= aspects_request_after ->
            if
                Type =:= internal ->
                    aspect_request_after_internal;
                Type =:= external ->
                    aspect_request_after_external
            end;
        Option =:= aspects_info_before, Type =:= internal ->
            aspect_info_before_internal;
        Option =:= aspects_info_after, Type =:= internal ->
            aspect_info_after_internal;
        Option =:= aspects_terminate_before ->
            if
                Type =:= internal ->
                    aspect_terminate_before_internal;
                Type =:= external ->
                    aspect_terminate_before_external
            end
    end,
    Aspect = {{?MODULE, F}},
    case lists:keytake(Option, 1, Options) of
        {value, {_, OptionL}, NextOptions} ->
            [{Option, OptionL ++ [Aspect]} | NextOptions];
        false ->
            [{Option, [Aspect]} | Options]
    end.

-spec update(L :: metric_list(),
             MetricPrefix :: metric_name(),
             Driver :: any()) ->
    ok.

update([], _, _) ->
    ok;
update([{Type, Name, Value} | L], MetricPrefix, Driver) ->
    ok = update(Type, MetricPrefix ++ Name, Value, Driver),
    update(L, MetricPrefix, Driver).

exometer_reporters([]) ->
    [];
exometer_reporters([{reporter, ReporterOptions} | L]) ->
    [ReporterName,
     ReporterModule,
     ReporterExtra |
     Options0] = cloudi_proplists:take_values([{name, undefined},
                                               {module, undefined},
                                               {extra, undefined}],
                                              ReporterOptions),
    true = (ReporterName /= undefined),
    OptionsN = if
        ReporterModule =:= undefined ->
            [{module, ReporterName} | Options0];
        is_atom(ReporterModule) ->
            [{module, ReporterModule} | Options0]
    end,
    case exometer_report:add_reporter(ReporterName, OptionsN) of
        ok ->
            ok;
        {error, already_running} ->
            ok;
        {error, Reason} ->
            erlang:exit({exometer_report, {ReporterName, Reason}})
    end,
    [{ReporterName,
      ReporterExtra} | exometer_reporters(L)].

