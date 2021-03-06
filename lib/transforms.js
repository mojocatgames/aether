(function() {
  var S, SourceMap, checkIncompleteMembers, esprima, getFunctionNestingLevel, getLineNumberForNode, getParents, getParentsOfType, makeCheckThisKeywords, makeFindOriginalNodes, makeGatherNodeRanges, makeInstrumentCalls, makeInstrumentStatements, possiblyGeneratorifyAncestorFunction, problems, statements, validateReturns, yieldAutomatically, yieldConditionally, _, _ref, _ref1, _ref2,
    __indexOf = [].indexOf || function(item) { for (var i = 0, l = this.length; i < l; i++) { if (i in this && this[i] === item) return i; } return -1; };

  _ = (_ref = (_ref1 = (_ref2 = typeof window !== "undefined" && window !== null ? window._ : void 0) != null ? _ref2 : typeof self !== "undefined" && self !== null ? self._ : void 0) != null ? _ref1 : typeof global !== "undefined" && global !== null ? global._ : void 0) != null ? _ref : require('lodash');

  problems = require('./problems');

  esprima = require('esprima');

  SourceMap = require('source-map');

  S = esprima.Syntax;

  statements = [S.EmptyStatement, S.ExpressionStatement, S.BreakStatement, S.ContinueStatement, S.DebuggerStatement, S.DoWhileStatement, S.ForStatement, S.FunctionDeclaration, S.ClassDeclaration, S.IfStatement, S.ReturnStatement, S.SwitchStatement, S.ThrowStatement, S.TryStatement, S.VariableStatement, S.WhileStatement, S.WithStatement];

  getParents = function(node) {
    var parents;
    parents = [];
    while (node.parent) {
      parents.push(node = node.parent);
    }
    return parents;
  };

  getParentsOfType = function(node, type) {
    return _.filter(getParents(node), {
      type: type
    });
  };

  getFunctionNestingLevel = function(node) {
    return getParentsOfType(node, S.FunctionExpression).length;
  };

  getLineNumberForNode = function(node) {
    var fullSource, i, line, parent, _i, _ref3;
    parent = node;
    while (parent.type !== S.Program) {
      parent = parent.parent;
    }
    fullSource = parent.source();
    line = -2;
    for (i = _i = 0, _ref3 = node.range[0]; 0 <= _ref3 ? _i < _ref3 : _i > _ref3; i = 0 <= _ref3 ? ++_i : --_i) {
      if (fullSource[i] === '\n') {
        ++line;
      }
    }
    return line;
  };

  module.exports.makeGatherNodeRanges = makeGatherNodeRanges = function(nodeRanges, codePrefix) {
    return function(node) {
      node.originalRange = {
        start: node.range[0] - codePrefix.length,
        end: node.range[1] - codePrefix.length
      };
      node.originalSource = node.source();
      return nodeRanges.push(node);
    };
  };

  module.exports.makeCheckThisKeywords = makeCheckThisKeywords = function(global) {
    var vars;
    vars = {};
    return function(node) {
      var p, problem, v, _i, _len, _ref3;
      if (node.type === S.VariableDeclarator) {
        return vars[node.id.name] = true;
      } else if (node.type === S.FunctionDeclaration) {
        return vars[node.id.name] = true;
      } else if (node.type === S.CallExpression) {
        v = node.callee.name;
        if (v && !vars[v] && !global[v]) {
          _ref3 = getParentsOfType(node, S.FunctionDeclaration);
          for (_i = 0, _len = _ref3.length; _i < _len; _i++) {
            p = _ref3[_i];
            vars[p.id.name] = true;
            if (p.id.name === v) {
              return;
            }
          }
          problem = new problems.TranspileProblem(this, 'aether', 'MissingThis', {}, '', '');
          problem.message = "Missing `this.` keyword; should be `this." + v + "`.";
          problem.hint = "There is no function `" + v + "`, but `this` has a method `" + v + "`.";
          this.addProblem(problem);
          if (!this.options.requiresThis) {
            return node.update("this." + (node.source()));
          }
        }
      }
    };
  };

  module.exports.validateReturns = validateReturns = function(node) {
    var _ref3;
    if (getFunctionNestingLevel(node) !== 2) {
      return;
    }
    if (node.type === S.ReturnStatement && !node.argument) {
      return node.update(node.source().replace("return;", "return this.validateReturn('" + this.options.functionName + "', null);"));
    } else if (((_ref3 = node.parent) != null ? _ref3.type : void 0) === S.ReturnStatement) {
      return node.update("this.validateReturn('" + this.options.functionName + "', (" + (node.source()) + "))");
    }
  };

  module.exports.checkIncompleteMembers = checkIncompleteMembers = function(node) {
    var error, exp, lineNumber, m, _ref3;
    if (node.type === 'ExpressionStatement') {
      lineNumber = getLineNumberForNode(node);
      exp = node.expression;
      if (exp.type === 'MemberExpression') {
        if (exp.property.name === "IncompleteThisReference") {
          m = "this.what? (Check available spells below.)";
        } else {
          m = "" + (exp.source()) + " has no effect.";
          if (_ref3 = exp.property.name, __indexOf.call(problems.commonMethods, _ref3) >= 0) {
            m += " It needs parentheses: " + exp.property.name + "()";
          }
        }
        error = new Error(m);
        return error.lineNumber = lineNumber + 2;
      }
    }
  };

  module.exports.makeFindOriginalNodes = makeFindOriginalNodes = function(originalNodes, codePrefix, wrappedCode, normalizedSourceMap, normalizedNodeIndex) {
    var normalizedPosToOriginalNode, smc;
    normalizedPosToOriginalNode = function(pos) {
      var end, node, start, _i, _len;
      start = pos.start_offset - codePrefix.length;
      end = pos.end_offset - codePrefix.length;
      for (_i = 0, _len = originalNodes.length; _i < _len; _i++) {
        node = originalNodes[_i];
        if (start === node.originalRange.start && end === node.originalRange.end) {
          return node;
        }
      }
      return null;
    };
    smc = new SourceMap.SourceMapConsumer(normalizedSourceMap.toString());
    return function(node) {
      var mapped, normalizedNode;
      if (!(mapped = smc.originalPositionFor({
        line: node.loc.start.line,
        column: node.loc.start.column
      }))) {
        return;
      }
      if (!(normalizedNode = normalizedNodeIndex[mapped.column])) {
        return;
      }
      return node.originalNode = normalizedPosToOriginalNode(normalizedNode.attr.pos);
    };
  };

  possiblyGeneratorifyAncestorFunction = function(node) {
    while (node.type !== S.FunctionExpression) {
      node = node.parent;
    }
    return node.mustBecomeGeneratorFunction = true;
  };

  module.exports.yieldConditionally = yieldConditionally = function(node) {
    var _ref3;
    if (node.type === S.ExpressionStatement && ((_ref3 = node.expression.right) != null ? _ref3.type : void 0) === S.CallExpression) {
      if (getFunctionNestingLevel(node) !== 2) {
        return;
      }
      node.update("" + (node.source()) + " if (this._aetherShouldYield) { var _yieldValue = this._aetherShouldYield; this._aetherShouldYield = false; yield _yieldValue; }");
      node.yields = true;
      return possiblyGeneratorifyAncestorFunction(node);
    } else if (node.mustBecomeGeneratorFunction) {
      return node.update(node.source().replace(/^function \(/, 'function* ('));
    }
  };

  module.exports.yieldAutomatically = yieldAutomatically = function(node) {
    var _ref3;
    if (_ref3 = node.type, __indexOf.call(statements, _ref3) >= 0) {
      if (getFunctionNestingLevel(node) !== 2) {
        return;
      }
      node.update("" + (node.source()) + " yield 'waiting...';");
      node.yields = true;
      return possiblyGeneratorifyAncestorFunction(node);
    } else if (node.mustBecomeGeneratorFunction) {
      return node.update(node.source().replace(/^function \(/, 'function* ('));
    }
  };

  module.exports.makeInstrumentStatements = makeInstrumentStatements = function() {
    return function(node) {
      var range, safeSource, source, _ref3, _ref4;
      if (!(node.originalNode && node.originalNode.originalRange.start >= 0)) {
        return;
      }
      if (_ref3 = node.type, __indexOf.call(statements, _ref3) < 0) {
        return;
      }
      if ((_ref4 = node.originalNode.type) === S.ThisExpression || _ref4 === S.Identifier || _ref4 === S.Literal) {
        return;
      }
      if (!(getFunctionNestingLevel(node) > 1)) {
        return;
      }
      range = [node.originalNode.originalRange.start, node.originalNode.originalRange.end];
      source = node.originalNode.originalSource;
      safeSource = source.replace(/\"/g, '\\"').replace(/\n/g, '\\n');
      return node.update("" + (node.source()) + " _aether.logStatement(" + range[0] + ", " + range[1] + ", \"" + safeSource + "\", this._aetherUserInfo);");
    };
  };

  module.exports.makeInstrumentCalls = makeInstrumentCalls = function() {
    return function(node) {
      if (getFunctionNestingLevel(node) !== 2) {
        return;
      }
      if (node.type === S.ReturnStatement) {
        node.update("_aether.logCallEnd(); " + (node.source()));
      }
      if (node.type !== S.VariableDeclaration) {
        return;
      }
      return node.update("_aether.logCallStart(); " + (node.source()));
    };
  };

}).call(this);
