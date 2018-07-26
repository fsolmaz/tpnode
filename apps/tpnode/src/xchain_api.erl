-module(xchain_api).

%% API
-export([h/3, after_filter/1]).

after_filter(Req) ->
  Origin = cowboy_req:header(<<"origin">>, Req, <<"*">>),
  Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>,
                                    Origin, Req),
  Req2 = cowboy_req:set_resp_header(<<"access-control-allow-methods">>,
                                    <<"GET, POST, OPTIONS">>, Req1),
  Req3 = cowboy_req:set_resp_header(<<"access-control-allow-credentials">>,
                                    <<"true">>, Req2),
  Req4 = cowboy_req:set_resp_header(<<"access-control-max-age">>,
                                    <<"86400">>, Req3),
  cowboy_req:set_resp_header(<<"access-control-allow-headers">>,
                             <<"content-type">>, Req4).

reply(Code, Result) ->
  EHF=fun([{Type, Str}|Tokens],{parser, State, Handler, Stack}, Conf) ->
          Conf1=jsx_config:list_to_config(Conf),
          if size(Str) == 32 ->
               jsx_parser:resume([{Type, <<"0x",(hex:encode(Str))/binary>>}|Tokens],
                                 State, Handler, Stack, Conf1);
             true ->
               jsx_parser:resume([{Type, base64:encode(Str)}|Tokens],
                                 State, Handler, Stack, Conf1)
          end
      end,


  {Code,
   {Result,
    #{jsx=>[ strict, {error_handler, EHF} ]}
   }
  }.

h(<<"GET">>, [<<"compat">>], _Req) ->
  reply(200,
        #{ ok => true,
           version => 2
         });

h(<<"POST">>, [<<"ping">>], _Req) ->
  reply(200,
        #{ ok => true,
           data => [<<"pong">>]
         });

h(<<"OPTIONS">>, _, _Req) ->
  {200, [], ""};


h(<<"GET">>, [<<"parent">>,BChain,<<"last">>], _Req) ->
  h(<<"GET">>, [<<"last">>,BChain], _Req);

h(<<"GET">>, [<<"parent">>,BChain,SParent], _Req) ->
  try
    Parent=case SParent of
             <<"0x", BArr/binary>> ->
               hex:parse(BArr);
             <<_:32/binary>> ->
               SParent;
             Any ->
               base64:decode(Any)
           end,
    Chain=binary_to_integer(BChain),
    Res=blockchain:rel(Parent,child),
    if is_map(Res) -> ok;
       is_atom(Res) ->
         throw({noblock, Res})
    end,
    O=maps:get(settings, Res),
    P=block:outward_ptrs(O,Chain),
    reply(200,
          #{ ok => true,
             pointers => P
           })

  catch error:{badkey,outbound} ->
          reply(404,
                #{ ok=>false,
                   error => <<"no outbound">>
                 });
        throw:noout ->
          reply(404,
                #{ ok=>false,
                   error => <<"no outbound for this chain">>
                 });
        throw:{noblock, _R} ->
          reply(404,
                #{ ok=>false,
                   error => <<"no block">>
                 })
  end;

h(<<"GET">>, [<<"last">>,BChain], _Req) ->
  Chain=binary_to_integer(BChain),
  ChainPath=[<<"current">>, <<"outward">>, xchain:pack_chid(Chain)],
  Last=chainsettings:get_settings_by_path(ChainPath),
  reply(200, #{ pointers=>Last,
                ok=>true });

h(<<"GET">>, [<<"owbyparent">>,BChain,SParent], _Req) ->
  Parent=case SParent of
           <<"0x", BArr/binary>> ->
             hex:parse(BArr);
           <<_:32/binary>> ->
             SParent;
           Any ->
             base64:decode(Any)
         end,
  Chain=binary_to_integer(BChain),
  Res=blockchain:rel(Parent,child),
  OutwardBlock=block:outward_chain(Res,Chain),
  case OutwardBlock of
    none ->
      reply(404,
            #{ ok=>false,
               block => false}
           );
    _AnyBlock ->
      reply(200,
            #{ ok => true,
               block => block:pack(OutwardBlock),
               header => maps:with([hash, header, extdata],OutwardBlock)
             })
  end;

h(_Method, [<<"status">>], Req) ->
  {RemoteIP, _Port} = cowboy_req:peer(Req),
  lager:info("api call from ~p", [inet:ntoa(RemoteIP)]),
  Body = apixiom:body_data(Req),

  reply(200, #{
    ok=>true,
    data => #{
      request => Body
     }
   }).




