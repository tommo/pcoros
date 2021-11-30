# This is just an example to get you started. You may wish to put all of your
# tests into a single file, or separate them into multiple `test1`, `test2`
# etc. files (better names are recommended, just make sure the name starts with
# the letter 't').
#
# To run these tests, simply execute `nimble test`.

import unittest

import pcoros

test "can yield and resume":
  var counter = 0
  proc pingpong() {.pcoro:(input:int).} =
    counter = 1
    pyield()
    counter = 2
  var coro = spawnPCoro pingpong()
  check counter == 0
  coro.resume 1
  check coro.running
  check counter == 1
  coro.resume 1
  check counter == 2
  check coro.finished

template notCompiles*(e: untyped): untyped =
  not compiles(e)

test "can call other coroutines from a coroutine ":
  var state = ""
  proc pong() {.pcoro:(msg:int).} =
    state = "pong"
    pyield()

  proc ping() {.pcoro:(msg:int).} =
    state = "ping"
    pyield()
    pong()
    state = "done"

  var coro = spawnPCoro ping()
  coro.resume 1
  check state == "ping"
  coro.resume 1
  check state == "pong"
  coro.resume 1
  check state == "done"

test "forbid call coroutines outside a coroutine":
  check: 
    notCompiles:
      proc pong() {.pcoro:(msg:int).} =
        discard
      pong()
