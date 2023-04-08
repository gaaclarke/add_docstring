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

/// Prints the usage information for the `add_docstring` command-line tool,
/// which takes two arguments:
/// - The [openaiApiKey], which is the OpenAI API key to use for generating
///   docstrings.
/// - The [dartFilePath], which is the path to the Dart file that needs
///   docstrings to be added.
void _printUsage() {
  print('add_docstring <openai api key> <path to dart file>');
}

/// Processes the Dart file located at [inputPath] and returns a list of
/// [Procedure] objects.
///
/// The function first creates a list of included paths containing only the
/// absolute and normalized [inputPath]. It then creates an
/// [AnalysisContextCollection] with the included paths and iterates over each
/// context. For each context, it iterates over each analyzed file in the
/// context's root directory. If the path of the analyzed file matches the
/// [inputPath], it gets the parsed
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

  /// Adds a procedure with the given [nameToken], [returnType], [metadata], and
  /// [endToken] to the list of procedures.
  ///
  /// The [nameToken] represents the name of the procedure.
  ///
  /// The [returnType] represents the return type of the procedure.
  ///
  /// The [metadata] represents the annotations associated with the procedure.
  ///
  /// The [endToken] represents the end of the procedure.
  ///
  /// Throws an
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

  /// Visits a [FunctionDeclaration] node and adds a procedure with the given
  /// [name], [returnType], [metadata], and [endToken].
  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    _addProcedure(node.name, node.returnType, node.metadata, node.endToken);
  }

  /// Visits a [MethodDeclaration] node and adds a procedure to the list of
  /// procedures with the provided [name], [returnType], [metadata], and
  /// [endToken] information.
  ///
  /// Overrides the [visitMethodDeclaration] method in the base class.
  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    _addProcedure(node.name, node.returnType, node.metadata, node.endToken);
  }
}

class Range {
  Range(this.begin, this.end);
  final int begin;
  final int end;

  /// Returns a string representation of the object.
  ///
  /// The returned string is a human-readable representation of this object, and
  /// is primarily intended for debugging and logging purposes. The string
  /// representation includes the values of the begin and end properties
  /// enclosed in parentheses.
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

/// Generates a docstring for a given function [procedure] using OpenAI's GPT-3
/// model. The generated docstring will describe the purpose of the function and
/// its parameters. The [name] parameter is used for logging purposes. The
/// function requires an [openaiApiKey] to be passed in as a string.
Future<String> _generateDocstring(
    String openaiApiKey, String name, String procedure) async {
  print('looking up $name');
  final List messages = [
    {
      'role': 'system',
      'content':
          'You are an expert at programming Dart, who only responds with clear docstrings for provided functions.'
    },
    {
      'role': 'user',
      'content': '''Add a docstring to this function
--
double div(double x, double y) => x / y;
'''
    },
    {
      'role': 'assistant',
      'content':
          '/// Calculates the division between [x] and [y] where [x] is the numerator and [y] is the denominator.'
    },
    {
      'role': 'user',
      'content': '''Add a docstring to this function
--
$procedure
'''
    },
  ];
  final String model = 'gpt-3.5-turbo';
  final int maxTokens = 100;
  final double temperature = 0.5;

  Map<String, dynamic> requestBody = {
    'messages': messages,
    'model': model,
    'max_tokens': maxTokens,
    'temperature': temperature,
  };

  Completer<String> result = Completer<String>();
  http
      .post(
    Uri.parse('https://api.openai.com/v1/chat/completions'),
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
      final Map<String, Object?> message =
          (first['message'] as Map<String, Object?>?)!;
      final String content = (message['content'] as String?)!;
      result.complete(content);
    } else {
      result.completeError(Exception(
          'Request failed with status: ${response.statusCode} ${response.body}'));
    }
  }).catchError((error) {
    result.completeError(Exception('Request failed with error: $error.'));
  });

  return await result.future;
}

/// Entry point of the program that generates docstrings for functions in a Dart
/// file. Expects two arguments: an OpenAI API key and the path to the Dart file
/// to be processed. If the number of arguments is incorrect, it prints the
/// usage instructions. If the user confirms the submission, it reads the
/// contents of the input file and generates docstrings for each function found.
/// The output is written to a new file named 'output.dart' in the same
/// directory as the input
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
