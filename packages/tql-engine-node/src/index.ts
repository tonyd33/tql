import * as assert from "node:assert";
import * as fs from "node:fs";
import * as Parser from "tree-sitter";
import * as JavaScript from "tree-sitter-javascript";
import * as Tql from "tree-sitter-tql";
import { desugar, type Frontend, Parser as TqlParser } from "./ast";
import { desugarProgram } from "./ast/desugar";
import { interpret } from "./interpreter";
import * as T from "./traversal";
import { explainQuery } from "./ast/explain";

function parseArgs(argvIn: string[]): { tqlFile: string; targetFile: string } {
  const tqlFile = argvIn[2];
  const targetFile = argvIn[3];
  if (tqlFile == null || targetFile == null) {
    assert.fail("Expected file");
  } else {
    return { tqlFile, targetFile };
  }
}

async function main() {
  const args = parseArgs(process.argv);
  const tqlParser = new Parser();
  tqlParser.setLanguage(Tql as Parser.Language);
  const jsParser = new Parser();
  jsParser.setLanguage(JavaScript as Parser.Language);

  const [tqlSource, targetSource] = await Promise.all([
    fs.promises.readFile(args.tqlFile, "utf8"),
    fs.promises.readFile(args.targetFile, "utf8"),
  ]);
  const targetTree = jsParser.parse(targetSource);

  const frontendProgram = TqlParser.parseTql(tqlSource);
  const backendProgram = desugarProgram(frontendProgram);
  // console.log(explainQuery(backendProgram.main))
  console.log(JSON.stringify(backendProgram, null, 2))
  const query = interpret(backendProgram.main);

  console.time();
  const matches = T.Core.runPath(
    [T.Capture.lift(targetTree.rootNode)],
    T.Core.compose(T.TreeCapture.descendant, query),
  );
  console.log(
    matches.map(m => ({
      value: m.value,
      captures: Object.fromEntries(
        Object.entries(m.captures).map(([identifier, value]) => [
          identifier,
          value.value,
        ]),
      ),
    })),
  );
  console.timeEnd();
}

main();
