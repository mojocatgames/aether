_ = window?._ ? self?._ ? global?._ ? require 'lodash'  # rely on lodash existing, since it busts CodeCombat to browserify it--TODO
traceur = window?.traceur ? self?.traceur ? global?.traceur ? require 'traceur'  # rely on traceur existing, since it busts CodeCombat to browserify it--TODO

esprima = require 'esprima'  # getting our Esprima Harmony
acorn_loose = require 'acorn/acorn_loose'  # for if Esprima dies. Note it can't do ES6.
jshint = require('jshint').JSHINT
normalizer = require 'JS_WALA/normalizer/lib/normalizer'
escodegen = require 'escodegen'
#infer = require 'tern/lib/infer'  # Not enough time to figure out how to integrate this yet

defaults = require './defaults'
problems = require './problems'
execution = require './execution'
morph = require './morph'
transforms = require './transforms'

optionsValidator = require './validators/options'

module.exports = class Aether
  #various declarations
  @defaults: defaults
  @problems: problems
  @execution: execution

  #MODIFIES: @options
  #EFFECTS: Initialize the Aether object by modifying @options by combining the default options with the options parameter
  #         and doing validation.
  constructor: (options) ->

    #do a deep copy of the options (using lodash, not underscore)
    @originalOptions = _.cloneDeep options

    #if options and options.problems do not exist, create them as empty objects
    options ?= {}
    options.problems ?= {}
    #unless the user has specified to exclude the default options, merge the given options with the default options
    unless options.excludeDefaultProblems
      options.problems = _.merge _.cloneDeep(Aether.problems.problems), options.problems

    #validate the options
    optionsValidation = optionsValidator options
    throw new Error("Options array is not valid: " + JSON.stringify(optionsValidation.errors, null, 4)) if not optionsValidation.valid

    #merge the given options with the default
    @options = _.merge _.cloneDeep(Aether.defaults), options

    #reset the state of the Aether object
    @reset()

  #EFFECTS: Performs quick heuristics to determine whether the code will run or produce compilation errors.
  #         If the bool thorough is specified, it will perform detailed linting. Returns true if raw will run, and false if it won't.
  #NOTES:   First check inspired by ACE: https://github.com/ajaxorg/ace/blob/master/lib/ace/mode/javascript_worker.js
  canTranspile: (raw, thorough=false) ->

    return true if not raw #blank code should compile, but bypass the other steps
    try
      eval "'use strict;'\nthrow 0;" + raw  # evaluated code can only create variables in this function
    catch e
      return false if e isnt 0
    return true unless thorough
    #lint the code and return errors
    lintProblems = @lint raw
    return lintProblems.errors.length is 0

  # Determine whether two strings of code are significantly different.
  # If careAboutLineNumbers, we strip trailing comments and whitespace and compare line count.
  # If careAboutLint, we also lint and make sure lint problems are the same. Use this instance for lint config.
  hasChangedSignificantly: (a, b, careAboutLineNumbers=false, careAboutLint=false) ->
    lintAether = @ if careAboutLint
    Aether.hasChangedSignificantly a, b, careAboutLineNumbers, lintAether

  # If the simple tests fail, we compare abstract syntax trees for equality.
  # We try first with Esprima, to be precise, then with acorn_loose if that doesn't work.
  @hasChangedSignificantly: (a, b, careAboutLineNumbers=false, lintAether=null) ->
    return true unless a? and b?
    return false if a is b
    return true if careAboutLineNumbers and @hasChangedLineNumbers a, b
    return true if lintAether?.hasChangedLintProblems a, b
    options = {loc: false, range: false, raw: true, comment: false, tolerant: true}
    [aAST, bAST] = [null, null]
    try aAST = esprima.parse a, options
    try bAST = esprima.parse b, options
    return true if (not aAST or not bAST) and (aAST or bAST)
    if aAST and bAST
      return true if (aAST.errors ? []).length isnt (bAST.errors ? []).length
      return not _.isEqual(aAST.body, bAST.body)
    # Esprima couldn't parse either ASTs, so let's fall back to acorn_loose
    options = {locations: false, tabSize: 4, ecmaVersion: 5}
    aAST = acorn_loose.parse_dammit a, options
    bAST = acorn_loose.parse_dammit b, options
    # acorn_loose annoyingly puts start/end in every node; we'll remove before comparing
    walk = (node) ->
      node.start = node.end = null
      for key, child of node
        if _.isArray child
          for grandchild in child
            walk grandchild if _.isString grandchild?.type
        else if _.isString child?.type
          walk child
    walk(aAST)
    walk(bAST)
    return not _.isEqual(aAST, bAST)

  @hasChangedLineNumbers: (a, b) ->
    unless String.prototype.trimRight
      String.prototype.trimRight = -> String(@).replace /\s\s*$/, ''
    a = a.replace(/^[ \t]+\/\/.*/g, '').trimRight()
    b = b.replace(/^[ \t]+\/\/.*/g, '').trimRight()
    return a.split('\n').length isnt b.split('\n').length

  hasChangedLintProblems: (a, b) ->
    aLintProblems = [p.id, p.message, p.hint] for p in @getAllProblems @lint a
    bLintProblems = [p.id, p.message, p.hint] for p in @getAllProblems @lint b
    return not _.isEqual aLintProblems, bLintProblems

  #EFFECTS: Resets the state of Aether.
  reset: ->
    @problems = errors: [], warnings: [], infos: []
    @style = {}
    @flow = {}
    @metrics = {}
    @visualization = {}
    @pure = null

  transpile: (@raw) ->
    # Transpile it. Even if it can't transpile, it will give syntax errors and warnings and such. Clears any old state.
    @reset()
    @problems = @lint @raw
    @pure = @purifyCode @raw
    @pure

  addProblem: (problem, problems=null) ->
    return if problem.level is "ignore"
    #console.log "found problem:", problem.serialize()
    (problems ? @problems)[problem.level + "s"].push problem
    problem

  wrap: (rawCode) ->
    @wrappedCodePrefix ?="""
    function #{@options.functionName or 'foo'}(#{@options.functionParameters.join(', ')}) {
    \"use strict\";
    """
    # Should add \n after? (Not `"use strict";this.moveXY(30, 26);` on one line.)
    # TODO: Try it and make sure our line counts are fine.
    @wrappedCodeSuffix ?= "\n}"
    @wrappedCodePrefix + rawCode + @wrappedCodeSuffix

  lint: (rawCode) ->
    wrappedCode = @wrap rawCode
    lintProblems = errors: [], warnings: [], infos: []

    # Run it through JSHint first, because that doesn't rely on Esprima
    # See also how ACE does it: https://github.com/ajaxorg/ace/blob/master/lib/ace/mode/javascript_worker.js
    # TODO: make JSHint stop providing these globals somehow; the below doesn't work
    jshintOptions = browser: false, couch: false, devel: false, dojo: false, jquery: false, mootools: false, node: false, nonstandard: false, phantom: false, prototypejs: false, rhino: false, worker: false, wsh: false, yui: false
    jshintGlobals = _.keys(@options.global)
    jshintGlobals = _.zipObject jshintGlobals, (false for g in jshintGlobals)  # JSHint expects {key: writable} globals
    try
      jshintSuccess = jshint(wrappedCode, jshintOptions, jshintGlobals)
    catch e
      console.warn "JSHint died with error", e  #, "on code\n", wrappedCode
    for error in jshint.errors
      @addProblem new problems.TranspileProblem(@, 'jshint', error?.code, error, {}, wrappedCode, @wrappedCodePrefix), lintProblems

    lintProblems

  createFunction: ->
    # Return a ready-to-execute, instrumented function from the purified code
    # Because JS_WALA normalizes it to define a wrapper function on this, we need to run the wrapper to get our real function out.
    wrapper = new Function ['_aether'], @pure
    dummyContext = {Math: Math}  # TODO: put real globals in
    wrapper.call dummyContext, @
    dummyContext[@options.functionName or 'foo']

  createMethod: ->
    # Like createFunction, but binds method to thisValue if specified
    func = @createFunction()
    func = _.bind func, @options.thisValue if @options.thisValue
    func

  run: (fn, args...) ->
    # Convenience wrapper for running the compiled function with default error handling
    try
      fn ?= @createMethod()
      fn(args...)
    catch error
      @addProblem new Aether.problems.RuntimeProblem @, error, {}

  getAllProblems: (problems) ->
    _.flatten _.values (problems ? @problems)

  serialize: ->
    # Convert to JSON so we can pass it across web workers and HTTP requests and store it in databases and such
    serialized = originalOptions: @originalOptions, raw: @raw, pure: @pure, problems: @problems
    serialized.flow = @flow if @options.includeFlow
    serialized.metrics = @metrics if @options.includeMetrics
    serialized.style = @style if @options.includeStyle
    serialized.visualization = @visualization if @options.includeVisualization
    serialized = _.cloneDeep serialized
    serialized.originalOptions.thisValue = null  # TODO: haaack, what
    # TODO: serialize problems, too
    #console.log "Serialized into", serialized
    serialized

  @deserialize: (serialized) ->
    # Convert a serialized Aether instance back from JSON
    aether = new Aether serialized.originalOptions
    for prop, val of serialized
      aether[prop] = val
    aether

  walk: (node, fn) ->
    # TODO: this is redundant with morph walk logic
    for key, child of node
      if _.isArray child
        for grandchild in child
          @walk grandchild, fn if _.isString grandchild?.type
      else if _.isString child?.type
        @walk child, fn
      fn child

  traceurify: (code) ->
    # TODO: where to put this?
    project = new traceur.semantics.symbols.Project('codecombat')
    reporter = new traceur.util.ErrorReporter()
    compiler = new traceur.codegeneration.Compiler(reporter, project)
    sourceFile = new traceur.syntax.SourceFile("randotron_" + Math.random(), code)
    project.addFile(sourceFile)
    trees = compiler.compile_()
    if reporter.hadError()
      console.log "traceur had error trying to compile"
    tree = trees.values()[0]
    opts = showLineNumbers: false
    tree.generatedSource = traceur.outputgeneration.TreeWriter.write(tree, opts)
    tree.generatedSource

  transform: (code, transforms, parser="esprima", withAST=false) ->
    transformedCode = morph code, (_.bind t, @ for t in transforms), parser
    return transformedCode unless withAST
    [parse, options] = switch parser
      when "esprima" then [esprima.parse, {loc: true, range: true, raw: true, comment: true, tolerant: true}]
      when "acorn_loose" then [acorn_loose.parse_dammit, {locations: true, tabSize: 4, ecmaVersion: 5}]
    transformedAST = parse transformedCode, options
    [transformedCode, transformedAST]

  purifyCode: (rawCode) ->
    preprocessedCode = @checkCommonMistakes rawCode  # TODO: if we could somehow not change the source ranges here, that would be awesome....
    wrappedCode = @wrap preprocessedCode
    @vars = {}

    originalNodeRanges = []
    preNormalizationTransforms = [
      transforms.makeGatherNodeRanges originalNodeRanges, @wrappedCodePrefix
      transforms.makeCheckThisKeywords @options.global
      transforms.checkIncompleteMembers
    ]
    try
      [transformedCode, transformedAST] = @transform wrappedCode, preNormalizationTransforms, "esprima", true
    catch error
      problem = new problems.TranspileProblem @, 'esprima', error.id, error, {}, wrappedCode, ''
      @addProblem problem
      originalNodeRanges.splice()  # Reset any ranges we did find; we'll try again
      [transformedCode, transformedAST] = @transform wrappedCode, preNormalizationTransforms, "acorn_loose", true

    # TODO: need to insert 'use strict' after normalization, since otherwise you get tmp2 = 'use strict'
    normalizedAST = normalizer.normalize transformedAST
    normalizedNodeIndex = []
    @walk normalizedAST, (node) ->
      return unless pos = node?.attr?.pos
      node.loc = {start: {line: 1, column: normalizedNodeIndex.length}, end: {line: 1, column: normalizedNodeIndex.length + 1}}
      normalizedNodeIndex.push node

    normalized = escodegen.generate normalizedAST, {sourceMap: @options.functionName or 'foo', sourceMapWithCode: true}
    normalizedCode = normalized.code
    normalizedSourceMap = normalized.map

    postNormalizationTransforms = []
    postNormalizationTransforms.unshift transforms.validateReturns if @options.thisValue?.validateReturn  # TODO: parameter/return validation should be part of Aether, not some half-external function call
    postNormalizationTransforms.unshift transforms.yieldConditionally if @options.yieldConditionally
    postNormalizationTransforms.unshift transforms.yieldAutomatically if @options.yieldAutomatically
    postNormalizationTransforms.unshift transforms.makeInstrumentStatements() if @options.includeMetrics or @options.includeFlow
    postNormalizationTransforms.unshift transforms.makeInstrumentCalls() if @options.includeMetrics or @options.includeFlow
    postNormalizationTransforms.unshift transforms.makeFindOriginalNodes originalNodeRanges, @wrappedCodePrefix, wrappedCode, normalizedSourceMap, normalizedNodeIndex
    instrumentedCode = "return " + @transform normalizedCode, postNormalizationTransforms
    if @options.yieldConditionally or @options.yieldAutomatically
      # Unlabel breaks and pray for correct behavior: https://github.com/google/traceur-compiler/issues/605
      instrumentedCode = instrumentedCode.replace /(break|continue) [A-z0-9]+;/g, '$1;'
      purifiedCode = @traceurify instrumentedCode
    else
      purifiedCode = instrumentedCode
    if false
      console.log "---NODE RANGES---:\n" + _.map(originalNodeRanges, (n) -> "#{n.originalRange.start} - #{n.originalRange.end}\t#{n.originalSource.replace(/\n/g, '↵')}").join('\n')
      console.log "---RAW CODE----: #{rawCode.split('\n').length}\n", {code: rawCode}
      console.log "---WRAPPED-----: #{wrappedCode.split('\n').length}\n", {code: wrappedCode}
      console.log "---TRANSFORMED-: #{transformedCode.split('\n').length}\n", {code: transformedCode}
      console.log "---NORMALIZED--: #{normalizedCode.split('\n').length}\n", {code: normalizedCode}
      console.log "---INSTRUMENTED: #{instrumentedCode.split('\n').length}\n", {code: "return " + instrumentedCode}
      console.log "---PURIFIED----: #{purifiedCode.split('\n').length}\n", {code: purifiedCode}
    return purifiedCode

  getLineNumberForPlannedMethod: (plannedMethod, numMethodsSeen) ->
    n = 0
    for methods, lineNumber in [] # @methodLineNumbers
      for method, j in methods
        if n++ < numMethodsSeen then continue
        if method is plannedMethod
          return lineNumber - 1
    null

  checkCommonMistakes: (code) ->
    # Stop this.\n from failing on the next weird line
    code = code.replace /this.\s*?\n/g, "this.IncompleteThisReference;"
    # If we wanted to do it just when it would hit the ending } but allow multiline this refs:
    #code = code.replace /this.(\s+})$/, "this.IncompleteThisReference;$1"
    code

  @getFunctionBody: (func) ->
    # Remove function() { ... } wrapper and any extra indentation
    source = if _.isString func then func else func.toString()
    return "" if source.trim() is "function () {}"
    source = source.substring(source.indexOf('{') + 2, source.lastIndexOf('}'))  #.trim()
    lines = source.split /\r?\n/
    indent = if lines.length then lines[0].length - lines[0].replace(/^ +/, '').length else 0
    (line.slice indent for line in lines).join '\n'

  ### Flow/metrics -- put somewhere else? ###
  logStatement: (start, end, source, userInfo) ->
    range = [start, end]
    if @options.includeMetrics
      m = (@metrics.statements ?= {})[range] ?= {source: source}
      m.executions ?= 0
      ++m.executions
      @metrics.statementsExecuted ?= 0
      @metrics.statementsExecuted += 1
    if @options.includeFlow
      state =
        range: [start, end]
        source: source
        variables: {}  # TODO
        userInfo: _.cloneDeep userInfo
      callState = _.last @callStack
      callState.push state

    #console.log "Logged statement", range, "'#{source}'", "with userInfo", userInfo#, "and now have metrics", @metrics

  logCallStart: ->
    call = []
    (@callStack ?= []).push call
    if @options.includeMetrics
      @metrics.callsExecuted ?= 0
      ++@metrics.callsExecuted
      @metrics.maxDepth = Math.max(@metrics.maxDepth or 0, @callStack.length)
    if @options.includeFlow
      if @callStack.length is 1
        ((@flow ?= {}).states ?= []).push call
      else
        3
        # TODO: Nest the current call into the parent call? Otherwise it's just thrown away.
    #console.log "Logged call to", @options.functionName, @metrics, @flow

  logCallEnd: ->
    @callStack.pop()

self.Aether = Aether if self?
window.Aether = Aether if window?
self.esprima ?= esprima if self?
window.esprima ?= esprima if window?



# In order to be able to highlight the currently executing statement, then every time we yield, we can just grab the last-executed AST start/end and store it in our Thang as a trackedProperty. ... per method...
# Then eventually we can convert those start/ends to handle changed whitespace in identical ASTs, but we'll wait until we've refactored the editor for that.
# But what about stepping through non-yielding flow?
# The easiest thing from the editor's point of view would be to have, for each frame, for each method, a flat list of calls (list of statements) in the flow.
# Aether isn't going to organize things by frame, though; that's a CoCo concept.
# Aether can organize them by calls.
# We can reorganize them by frame, or make a getter that appears to, after we're done.
# We just need to have the frame numbers inserted in each ... statement, to support yielding, or call, if not, but let's do statements to make it general.
# So logStatement needs to include userInfo.
# It is already supposed to capture variable values.
# Let's see how JSDares did that part.
# Ah, every operation is wrapped in a function which outputs step messages.
# So we could do something like that: every time there's an assignment expression where the LHS has an original node, we add a mapping from that to the value of the RHS to our flow state.
# By the way, CoCo will eventually give its nodes IDs and then convert between ranges and IDs, but we might do this in Aether instead, since other users of Aether might also want to change the code and still preserve the range info when the ASTs haven't changed.
# So if that's how we track variable states, then we actually won't get anything that happens as a side effect.
# Like if I call this.setTarget(nearestEnemy), then this.target won't be updated, because I didn't explicitly assign to it.
# Hmm; maybe I should worry about that a bit later and get the stepping working properly.
# All that requires is to include the frameIndex as part of the userInfo for each logStatement.
# I could just set _aetherUserInfo to whatever value I want, just like I set _shouldYield (which should be _aetherShouldYield).
# Okay, let's try that.
# Okay, that works. (Shudder to think of performance.)
# Checked JSDares, and it looks like there's no means of inspecting the value of an arbitrary variable.
# It just allows you step forward and backward with an annotation of what happened in that operation.
