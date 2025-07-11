%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_exchange_type_management).
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include_lib("rabbit/include/mc.hrl").
-behaviour(rabbit_exchange_type).

-export([description/0, serialise_events/0, route/2, route/3]).
-export([validate/1, validate_binding/2,
         create/2, delete/2, policy_changed/2,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).
-export([info/1, info/2]).

-import(rabbit_misc, [pget/2, pget/3]).

-rabbit_boot_step(
   {rabbit_exchange_type_management,
    [{description, "exchange type x-management"},
     {mfa,         {rabbit_registry, register,
                    [exchange, <<"x-management">>, ?MODULE]}},
     {cleanup,     {rabbit_registry, unregister,
                    [exchange, <<"x-management">>]}},
     {requires,    rabbit_registry},
     {enables,     kernel_ready}]}).

info(_X) -> [].
info(_X, _) -> [].

description() ->
    [{description, <<"Management Exchange">>}].

serialise_events() -> false.

route(Exchange, _Message) ->
    route(Exchange, _Message, #{}).

route(#exchange{name = #resource{virtual_host = VHost}},Msg,_Opts) ->
    Keys = mc:routing_keys(Msg),
    Content0 = mc:protocol_state(mc:convert(mc_amqpl, Msg)),
    #content{properties            = #'P_basic'{reply_to       = ReplyTo,
                                                type           = Method,
                                                correlation_id = Id},
             payload_fragments_rev = PFR} =
        rabbit_binary_parser:ensure_content_decoded(Content0),
    Payload = case PFR of
                  [] -> <<>>;
                  _  -> erlang:iolist_to_binary(lists:reverse(PFR))
              end,
    [handle_rpc(Method, K, Id, VHost, ReplyTo, Payload) || K <- Keys],
    []. %% Don't route anything!


validate(_X) -> ok.

validate_binding(_X, _B) -> {error, {'binding_invalid', "cannot_bind_to_management_exchange", []}}.

create(_Tx, _X)          -> ok.
delete(_Tx, _X)          -> ok.
policy_changed(_X1, _X2) -> ok.

-spec add_binding(any(), any(), any()) -> no_return().
add_binding(_Tx, _X, _B)      -> exit(should_never_happen).

-spec remove_bindings(any(), any(), any()) -> no_return().
remove_bindings(_Tx, _X, _Bs) -> exit(should_never_happen).

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).

%%----------------------------------------------------------------------------

%% httpc seems to get racy when using HTTP 1.1
-define(HTTPC_OPTS, [{version, "HTTP/1.0"}]).

handle_rpc(_Method, _Path, _Id, _VHost, undefined = _ReplyTo, _ReqBody) ->
    fail_because_reply_to_is_missing();
handle_rpc(_Method, _Path, _Id, _VHost, "" = _ReplyTo, _ReqBody) ->
    fail_because_reply_to_is_missing();
handle_rpc(_Method, _Path, _Id, _VHost, <<"">> = _ReplyTo, _ReqBody) ->
    fail_because_reply_to_is_missing();
handle_rpc(Method, Path, Id, VHost, ReplyTo, ReqBody) ->
    case req(method(Method), binary_to_list(Path), ReqBody) of
        {ok, {{_HTTP, Code, _}, _Headers, ResBody}} ->
            Props = #'P_basic'{correlation_id = Id,
                       type           = list_to_binary(integer_to_list(Code)),
                       content_type   = <<"application/json">>},
            Content = rabbit_basic:build_content(Props, [list_to_binary(ResBody)]),
            ExchangeDst = rabbit_misc:r(VHost, exchange, <<>>),
            {ok, Msg} = mc_amqpl:message(ExchangeDst, ReplyTo, Content),
            _ = rabbit_queue_type:publish_at_most_once(ExchangeDst,Msg),
            ok;
        {error, Reason} ->
            error_logger:info_msg("Management exchange error:~p~n ",Reason),
            exit({error, Reason})
    end.

-spec fail_because_reply_to_is_missing() -> no_return().
fail_because_reply_to_is_missing() ->
    Msg = "reply_to property isn't set or is blank, x-management won't be able to publish a response",
    rabbit_log:error(Msg),
    exit({error, Msg}).

req(Method, Path, Body) ->
    {ok, U} = application:get_env(rabbitmq_management_exchange, username),
    {ok, P} = application:get_env(rabbitmq_management_exchange, password),
    req(Method, Path, [auth_header(U, P)], Body).

req(Method, Path, Headers, <<>>) ->
    httpc:request(Method, {prefix() ++ Path, Headers}, ?HTTPC_OPTS, []);

req(Method, Path, Headers, Body) ->
    httpc:request(Method, {prefix() ++ Path, Headers, "application/json", Body},
                  ?HTTPC_OPTS, []).

auth_header(Username, Password) ->
    {"Authorization",
     "Basic " ++ binary_to_list(base64:encode(Username ++ ":" ++ Password))}.

method(<<"GET">>)    -> get;
method(<<"get">>)    -> get;
method(<<"PUT">>)    -> put;
method(<<"put">>)    -> put;
method(<<"POST">>)   -> post;
method(<<"post">>)   -> post;
method(<<"DELETE">>) -> delete;
method(<<"delete">>) -> delete;
method(M)            -> exit({method_not_recognised, M}).

prefix() ->
    {ok, {Scheme, Port}} = get_management_listener(),
    rabbit_misc:format("~s://localhost:~p/api", [Scheme, Port]).

get_management_listener() ->
    Keys = [listener, tcp_config, ssl_config],
    catch maybe_get_management_listener(Keys).

maybe_get_management_listener([]) ->
    % Note: nothing configured, so just guess
    {ok, {"http", 15672}};
maybe_get_management_listener([K|Tail]) ->
    case application:get_env(rabbitmq_management, K) of
        undefined ->
            maybe_get_management_listener(Tail);
        {ok, L} ->
            Ssl = pget(ssl, L),
            Scheme = case {K, Ssl} of
                            {ssl_config, _} ->
                                "https";
                            {_, true} ->
                                "https";
                            _ ->
                                "http"
                        end,
            Port = pget(port, L),
            throw({ok, {Scheme, Port}})
    end.
