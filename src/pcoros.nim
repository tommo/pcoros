# Copyright (c) 2021 Tommo Zhou(tommo.zhou@gmail.com)

# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

import macros
export newIdentNode

type
  PCoroutineState* = enum
    csRunning
    csFinished
    csAborted

  PCoroutine*[T] = ref PCoroutineObj[T]

  PCoroutineObj*[T] {.acyclic.} = object
    state*:PCoroutineState
    forwarded*:PCoroutine[T]
    body*:iterator( input:T ):PCoroutineState #not nil

proc resume*[T]( coro:PCoroutine[T], input:T = default(T) ):PCoroutineState {.discardable.} = 
    if unlikely( coro.body == nil ):
      raise newException( ValueError, "dead coroutine" )

    if coro.forwarded != nil:
      let rstate = coro.forwarded.resume( input )
      if rstate == csRunning:
        return csRunning
      else:
        coro.forwarded = nil

    let state = coro.body( input )

    if finished( coro.body ):
      coro.state = csFinished
      coro.body = nil
    else:
      if state == csAborted:
        coro.body = nil
      coro.state = state

    return coro.state

proc running*[T]( coro:PCoroutine[T] ):bool {.inline.} = 
  coro.state == csRunning

proc aborted*[T]( coro:PCoroutine[T] ):bool {.inline.} = 
  coro.state == csAborted

proc finished*[T]( coro:PCoroutine[T] ):bool {.inline.} = 
  coro.state == csFinished
#================================================================
template pyield*():untyped =
  yield csRunning
  # if thisPCoroutine.state == csAborted:
  # return csAborted

proc stripPublic(node: NimNode): NimNode =
  if node.kind == nnkPostfix:
    return node[1]
  else:
    return node

proc getArgIds( procDef:NimNode ):seq[ NimNode ] =
  let params = procDef[ 3 ]
  for n in params:
    if n.kind == nnkIdentDefs:
      for i in 0 .. n.len() - 3:
        let id = n[ i ]
        if id.kind == nnkIdent:
          result.add( id )

macro cleanupPCoroBody( body:typed ):untyped =
  if body.getType().strVal == "void":
    result = body
  else:
    result = nnkStmtList.newTree( nnkDiscardStmt.newTree( body ) )

proc definePCoro*( procDef, inputArg, inputArgT:NimNode ):NimNode =
  expectKind procDef, nnkProcDef
  if procDef[3].len > 0 and procDef[3][0].kind != nnkEmpty:
    error("Coroutines can't return anything", procDef[3][0])

  let procName = stripPublic procDef[0]
  let coroConstrName = ident "createPCoroutine_" & $procName
  let procBody = procDef[^1]
  var coroConstrDeclName = coroConstrName
  var procDeclName = procName
  if procDef[0].kind == nnkPostfix:
    procDeclName = nnkPostfix.newTree( ident "*", procName )
    coroConstrDeclName = nnkPostfix.newTree( ident "*", coroConstrName )
  var output = quote do:
    macro `procDeclName`( replaceThis ):untyped {.used.}=
      result = quote do:
        when not declared( thisPCoroutine ): {.error:"attempt to call coroutine proc outside a coroutine".}
        thisPCoroutine.forwarded = `coroConstrName`()
        if thisPCoroutine.forwarded.resume() == csRunning:
          yield csRunning

    proc `coroConstrDeclName`( replaceThis ):PCoroutine[ replaceThis ] =
      var thisPCoroutine{.inject, cursor.} = PCoroutine[ replaceThis ]()  #deltatime
      thisPCoroutine.body = iterator( replaceThis ):PCoroutineState =
        cleanupPCoroBody `procBody`
      return thisPCoroutine


  var macroDef = output[0]
  var createDef = output[1]
  
  block:
    macroDef[3] = procDef[3].copyNimTree()
    macroDef[3][0] = ident "untyped"
    var macroArgs = getArgIds( procDef )
    var call = macroDef[^1][0][1][1][1][1]
    for node in macroArgs:
      call.add( nnkAccQuoted.newTree( node ) )

  block:    
    #replace generic param
    var createBody = createDef[^1]
    var returnParam = createDef[3][0]
    returnParam[2] = inputArgT

    createDef[3] = procDef[3].copyNimTree()
    createDef[3][0] = returnParam

    createBody[0][0][2][0][2] = inputArgT
    #replace iterator param
    var iterParams = createBody[1][1][3]
    iterParams[1] = nnkIdentDefs.newTree(
      inputArg,
      inputArgT,
      newEmptyNode()
    )

  # echo macroDef.treerepr
  # echo createDef.treerepr
  # echo output.repr

  result = output

macro pcoro*( coroInput, procDef:untyped ):untyped =
  # let procDef = args[ ^1 ]
  expectKind procDef, nnkProcDef
  expectKind coroInput, nnkTupleConstr
  expectKind coroInput[0], nnkExprColonExpr
  
  let inputArg = coroInput[0][0]
  let inputArgT = coroInput[0][1]

  result = definePCoro( procDef, inputArg, inputArgT )
  # echo result.repr

macro spawnPCoro*( call:untyped ):untyped =
  let createCoroName = ident "createPCoroutine_" & $call[0]
  # if not declared( createCoroName ):
  #   error( "no coroutine defined", call )
  var callNameStr = $call[0]
  call[0] = createCoroName
  result = quote do:
    when declared( `createCoroName` ):
      `call`
    else:
      {.error:"no coroutine defined: " & `callNameStr`.}

