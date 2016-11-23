-module(mad_port).
-copyright('Maxim Sokhatsky').
-compile(export_all).

compile(Dir,Config) ->
  case mad_utils:get_value(port_specs, Config, []) of
      [] -> [false];
       X -> compile_port(Dir,X,Config) end.

compile_port(Dir,Specs0,Config) ->
  {_,Flavour} = os:type(),
  System = atom_to_list(Flavour),
  Specs = [ {O,F} || {Sys,O,F} <- Specs0, Sys == System] ++
          [ {O,F} || {O,F} <- Specs0],
  filelib:ensure_dir(Dir ++ "/priv/"),
  Env = [ {Var,Val} || {Sys,Var,Val} <- mad_utils:get_value(port_env, Config, []), system(Sys,System) ] ++
        [ {Var,Val} || {Var,Val} <- mad_utils:get_value(port_env, Config, []) ],

  Job = fun({Target, Patterns}) ->
          Files      = files(Dir,Patterns),
          LinkLang   = link_lang(Files),
          TargetType = target_type(extension(Target)),

          Compile = fun(F) ->
                       Obj = to_obj(F),
                       case is_compiled(Obj,F) of
                        false ->
                           Ext   = extension(F),
                           CC    = compiler(Ext),
                           TplCC = tpl_cc(TargetType,CC),
                           Env1  = [{"PORT_IN_FILES", F},{"PORT_OUT_FILE", Obj}] ++ Env ++ default_env(),
                           CmdCC = string:strip(expand(System,TplCC,Env1)),
                           Cmd = expand(System,CmdCC,[{"CXXFLAGS",""},{"LDFLAGS",""},{"CFLAGS",""}]),
                           {_,Status,Report} = sh:run("cc",string:tokens(Cmd," "),binary,Dir,Env),
                           case Status of 
                            0 -> {ok,Obj};
                            _ -> {error, "Port Compilation Error:~n" ++ io_lib:format("~ts",[Report])},true
                           end;
                        true -> {even,Obj}
                       end 
                    end,

          Res = lists:foldl(fun({ok,X},Acc)   -> [X|Acc];
                               ({event,X},Acc)-> [X|Acc];
                               ({error,Err},_)-> {error,Err} 
                            end,[],[Compile(F) || F <- Files]),
          case Res of
            {error, _}=Err -> Err;
            Objs ->  Env2  = [{"PORT_IN_FILES", string:join(Objs," ")},
                              {"PORT_OUT_FILE", Target}] ++ Env ++ default_env(),
                     TplLD = tpl_ld(TargetType,LinkLang),
                     CmdLD = string:strip(expand(System,TplLD,Env2)),
                     Cmd = expand(System,CmdLD,[{"CXXFLAGS",""},{"LDFLAGS",""},{"CFLAGS",""}]),
                     {_,Status,Report} = sh:run("cc",string:tokens(Cmd," "),binary,Dir,Env),
                     case Status of 
                      0 -> false;
                      _ -> mad:info("Port Compilation Error:~n" ++ io_lib:format("~ts",[Report]),[]),
                           {error, Report},true
                     end                      
          end
        end,
  [Job(S)||S<-Specs].

to_obj(F) -> filename:rootname(F) ++ ".o".

%%FIXME
expand(System, String, []) -> String;
expand(System, String, [{K,V}|Env]) ->
  New = re:replace(String, io_lib:format("\\${?(~s)}?",[K]), V, [global, {return, list}]),
  expand(System,New,Env);
expand(System, String, [{Sys,K,V}|Env]) -> 
  case system(Sys,System) of
    true -> New = re:replace(String, io_lib:format("\\${?(~s)}?",[K]), V, [global, {return, list}]),
            expand(System,New,Env);
    false -> expand(System,String,Env)
  end.

extension(F)       -> filename:extension(F).
is_compiled(O,F)   -> filelib:is_file(O) andalso (mad_utils:last_modified(O) >= mad_utils:last_modified(F)). 
join(A,B)          -> filename:join(A,B).
concat(X)          -> lists:concat(X).
system(Sys,System) -> Sys == System orelse match(Sys,System).
match(Re,System)   -> case re:run(System, Re, [{capture,none}]) of match -> true; nomatch -> false end.
erts_dir()         -> join(code:root_dir(), concat(["erts-", erlang:system_info(version)])) .
erts_dir(include)  -> " -I"++join(erts_dir(), "include").
ei_dir()           -> case code:lib_dir(erl_interface) of {error,bad_name} -> ""; E -> E end.
ei_dir(include)    -> case ei_dir() of "" -> ""; E -> " -I"++join(E,"include") end;
ei_dir(lib)        -> case ei_dir() of "" -> ""; E -> " -L"++join(E,"lib") end.
link_lang(Files)   -> lists:foldl(fun(F,cxx) -> cxx;
                                     (F,cc) -> case compiler(extension(F)) == "$CXX" of 
                                                true -> cxx;false -> cc end
                                  end,cc,Files).

files(Dir,Patterns)-> files(Dir,Patterns, []).
files(_,[], Acc) -> lists:reverse(Acc);
files(D,[H|T], Acc) ->
  files(D,T,filelib:wildcard(H)++Acc). 
  %files(D,T,filelib:wildcard(join(D,H))++Acc). 


target_type(".so")   -> drv;
target_type(".dll")  -> drv;
target_type("")      -> exe;
target_type(".exe")  -> exe.

tpl_cc(drv,"$CC") -> " -c $CFLAGS $DRV_CFLAGS $PORT_IN_FILES -o $PORT_OUT_FILE";  
tpl_cc(drv,"$CXX")-> " -c $CXXFLAGS $DRV_CFLAGS $PORT_IN_FILES -o $PORT_OUT_FILE";  
tpl_cc(exe,"$CC") -> " -c $CFLAGS $EXE_CFLAGS $PORT_IN_FILES -o $PORT_OUT_FILE";  
tpl_cc(exe,"$CXX")-> " -c $CXXFLAGS $EXE_CFLAGS $PORT_IN_FILES -o $PORT_OUT_FILE".  

tpl_ld(drv,cc)  -> " $PORT_IN_FILES $LDFLAGS $DRV_LDFLAGS -o $PORT_OUT_FILE";
tpl_ld(drv,cxx) -> " $PORT_IN_FILES $LDFLAGS $DRV_LDFLAGS -o $PORT_OUT_FILE";
tpl_ld(exe,cc)  -> " $PORT_IN_FILES $LDFLAGS $EXE_LDFLAGS -o $PORT_OUT_FILE";
tpl_ld(exe,cxx) -> " $PORT_IN_FILES $LDFLAGS $EXE_LDFLAGS -o $PORT_OUT_FILE".

erl_ldflag() -> concat([ei_dir(include), erts_dir(include), " "]).

default_env() ->
    Arch = os:getenv("REBAR_TARGET_ARCH"),
    Vsn = os:getenv("REBAR_TARGET_ARCH_VSN"),
    [
     {"darwin", "DRV_LDFLAGS", "-bundle -flat_namespace -undefined suppress " ++ei_dir(lib) ++" -lerl_interface -lei"},
     {"DRV_CFLAGS" , "-g -Wall -fPIC -MMD " ++ erl_ldflag()},
     {"DRV_LDFLAGS", "-shared " ++ erl_ldflag()},
     {"EXE_CFLAGS" , "-g -Wall -fPIC -MMD " ++ erl_ldflag()},
     {"EXE_LDFLAGS", ei_dir(lib)++" -lerl_interface -lei"},
     {"ERL_EI_LIBDIR", ei_dir(lib)}
    ].

compiler(".cc")  -> "$CXX";
compiler(".cp")  -> "$CXX";
compiler(".cxx") -> "$CXX";
compiler(".cpp") -> "$CXX";
compiler(".CPP") -> "$CXX";
compiler(".c++") -> "$CXX";
compiler(".C")   -> "$CXX";
compiler(cxx)    -> "$CXX";
compiler(cc)     -> "$CC";
compiler(_)      -> "$CC".                       
