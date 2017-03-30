package pgo.pcalparser;

import java.util.Vector;

/**
 * Tester class for the Queens pluscal algorithm
 * 
 * This class stores the annotations, exceptions if any, and ast that is
 * expected.
 *
 */
public class QueensPluscalProcedureParserTester extends PGoPluscalParserTesterBase {

	@Override
	public Vector<String> getAnnotations() {
		Vector<String> v = new Vector<String>();
		v.add("arg int N");
		v.add("return rVal");
		return v;
	}

	@Override
	public boolean expectException() {
		return false;
	}

	@Override
	protected String getAlg() {
		return "QueensPluscalProcedure";
	}

	@Override
	public int exceptionLine() {
		return 0;
	}

}