import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart' show AnalysisSession;
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

/// Prints the usage instructions for the add_docstring command.
void _printUsage() {
  print('add_docstring <openai api key> <path to dart file>');
}

/// Processes the input path by analyzing the files within it and returns a list of Procedures.
List<Procedure> _process(String inputPath) {
  final List<String> includedPaths = <String>[
    path.absolute(path.normalize(inputPath))
  ];
  final AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: includedPaths,
  );
  for (final AnalysisContext context in collection.contexts) {
    for (final String path in context.contextRoot.analyzedFiles()) {
      final AnalysisSession session = context.currentSession;
      final ParsedUnitResult result =
          session.getParsedUnit(path) as ParsedUnitResult;
      final ProcedureVisitor visitor = ProcedureVisitor();
      result.unit.accept(visitor);
      return visitor.procedures;
    }
  }
  return [];
}

class ProcedureVisitor extends RecursiveAstVisitor<void> {
  final List<Procedure> procedures = [];

  /// Adds a procedure to the list of procedures with the given [nameToken],
  /// [returnType], [metadata], and [endToken].
  void _addProcedure(Token nameToken, TypeAnnotation? returnType,
      NodeList<Annotation> metadata, Token endToken) {
    final String name = nameToken.lexeme;
    int begin = returnType!.offset;
    if (metadata.isNotEmpty) {
      begin = metadata.beginToken!.offset;
    }
    final Range range = Range(begin, endToken.end);
    procedures.add(Procedure(name, range));
  }

  /// Visits a [FunctionDeclaration] node and adds a procedure with the given name, return type, metadata, and end token.
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _addProcedure(node.name, node.returnType, node.metadata, node.endToken);
  }

  /// Adds a procedure with the given [name], [returnType], [metadata], and [endToken] to the list of procedures.
  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _addProcedure(node.name, node.returnType, node.metadata, node.endToken);
  }
}

class Range {
  Range(this.begin, this.end);
  final int begin;
  final int end;

  /// Returns a string representation of the object, consisting of the beginning and ending values.
  @override
  String toString() {
    return '($begin, $end)';
  }
}

class Procedure {
  Procedure(this.name, this.range);
  final String name;
  final Range range;
}

/// Generates a docstring for the specified dart function, [name], using OpenAI's API. The [procedure] parameter contains the code of the function.
Future<String> _generateDocstring(
    String openaiApiKey, String name, String procedure) async {
  print('looking up $name');
  String prompt =
      '''Generate a docstring for the following dart function, $name.
Follow this format:
/// Calculates the division between [x] and [y] where [x] is the numerator and
/// [y] is the denominator.
--
$procedure
''';
  final String model = 'text-davinci-003';
  final int maxTokens = 100;
  final double temperature = 0.5;

  Map<String, dynamic> requestBody = {
    'prompt': prompt,
    'model': model,
    'max_tokens': maxTokens,
    'temperature': temperature,
  };

  Completer<String> result = Completer<String>();
  http
      .post(
    Uri.parse('https://api.openai.com/v1/completions'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $openaiApiKey',
    },
    body: jsonEncode(requestBody),
  )
      .then((response) {
    if (response.statusCode == 200) {
      final Map<String, Object?> decoded =
          jsonDecode(response.body) as Map<String, Object?>;
      final List<Object?> choices = (decoded["choices"] as List<Object?>?)!;
      final Map<String, Object?> first = (choices[0] as Map<String, Object?>?)!;
      final String docstring = (first["text"] as String?)!;
      result.complete(docstring);
    } else {
      result.completeError(Exception(
          'Request failed with status: ${response.statusCode} ${response.body}'));
    }
  }).catchError((error) {
    result.completeError(Exception('Request failed with error: $error.'));
  });

  return await result.future;
}

/// Calculates the division between the given source code and OpenAI's servers. Takes two arguments, the API key and the input path, to generate a docstring for the procedures in the source code.
void main(List<String> arguments) async {
  if (arguments.length != 2) {
    _printUsage();
  } else {
    print('''
WARNING: You are about to submit source code to OpenAI's servers.

Proceed? [N\\y]''');

    final Future<String> input = stdin.transform(utf8.decoder).first;
    final String char = String.fromCharCode((await input).codeUnitAt(0));
    if (char != 'y') {
      return;
    }

    final String apiKey = arguments[0];
    final String inputPath = arguments[1];
    final List<Procedure> procedures = _process(inputPath);
    final String originalText = File(inputPath).readAsStringSync();

    int lastOffset = 0;
    StringBuffer buffer = StringBuffer();
    for (var procedure in procedures) {
      buffer.write(originalText.substring(lastOffset, procedure.range.begin));
      buffer.writeln(await _generateDocstring(apiKey, procedure.name,
          originalText.substring(procedure.range.begin, procedure.range.end)));
      lastOffset = procedure.range.begin;
    }
    buffer.write(originalText.substring(lastOffset));

    File('output.dart').writeAsStringSync(buffer.toString());
  }
}
