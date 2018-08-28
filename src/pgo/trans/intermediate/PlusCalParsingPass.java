package pgo.trans.intermediate;

import pgo.errors.IssueContext;
import pgo.model.pcal.PlusCalAlgorithm;
import pgo.parser.LexicalContext;
import pgo.parser.ParseFailureException;
import pgo.parser.PlusCalParser;
import pgo.trans.passes.tlaparse.ParsingIssue;

import java.nio.file.Path;

public class PlusCalParsingPass {
	private PlusCalParsingPass() {}

	public static PlusCalAlgorithm perform(IssueContext ctx, Path inputFileName, CharSequence inputFileContents) {
		try {
			return PlusCalParser.readAlgorithm(new LexicalContext(inputFileName, inputFileContents));
		} catch (ParseFailureException e) {
			ctx.error(new ParsingIssue("PlusCal", e.getReason()));
			return null;
		}
	}
}