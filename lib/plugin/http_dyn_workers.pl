/*  Part of SWISH

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2018, VU University Amsterdam
			 CWI Amsterdam
    All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions
    are met:

    1. Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in
       the documentation and/or other materials provided with the
       distribution.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
    FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
    COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
    INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
    BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
    LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
    CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
    LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
    ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
    POSSIBILITY OF SUCH DAMAGE.
*/

:- module(http_dyn_workers,
          [
          ]).
:- use_module(library(http/thread_httpd)).
:- use_module(library(debug)).
:- use_module(library(settings)).
:- use_module(library(aggregate)).

:- setting(http:max_workers, integer, 100,
           "Maximum number of workers to create").

/** <module> Dynamically schedule HTTP workers.

This module defines  hooks  into  the   HTTP  framework  to  dynamically
schedule worker threads.
*/

:- multifile
    http:schedule_workers/1.

http:schedule_workers(Dict) :-
    get_time(Now),
    catch(thread_send_message(http_scheduler, no_workers(Now, Dict)),
          error(existence_error(message_queue, _), _),
          fail),
    !.
http:schedule_workers(Dict) :-
    create_scheduler,
    http:schedule_workers(Dict).

create_scheduler :-
    catch(thread_create(http_scheduler, _,
                        [ alias(http_scheduler),
                          inherit_from(main),
                          debug(false),
                          detached(true)
                        ]),
          error(_,_),
          fail).

http_scheduler :-
    get_time(Now),
    http_scheduler(_{ waiting:0,
                      time:Now
                    }).

http_scheduler(State) :-
    thread_get_message(Task),
    (   catch(reschedule(Task, State, State1),
              Error,
              ( print_message(warning, Error),
                fail))
    ->  !,
        http_scheduler(State1)
    ;   http_scheduler(State)
    ).

reschedule(no_workers(Reported, Dict), State0, State) :-
    Backlog = Dict.waiting + State0.waiting*(0.5**((Reported-State0.time)/60.0)),
    State = State0.put(_{waiting:Backlog, time:Reported}),
    aggregate_all(count, http_current_worker(Dict.port, _), Workers),
    debug(http(scheduler), 'Waiting: ~w; accumulated: ~1f; active: ~w',
          [Dict.waiting, Backlog, Workers]),
    setting(http:max_workers, MaxWorkers),
    Backlog > MaxWorkers/(MaxWorkers-Workers),
    http_add_worker(Dict.port,
                    [ max_idle_time(10)
                    ]).