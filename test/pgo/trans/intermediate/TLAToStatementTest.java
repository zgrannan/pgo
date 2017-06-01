package pgo.trans.intermediate;

import org.junit.Before;
import org.junit.Test;

import pcal.TLAToken;

import static org.junit.Assert.*;

import java.util.Vector;

import pgo.model.golang.Expression;
import pgo.model.golang.FunctionCall;
import pgo.model.golang.Imports;
import pgo.model.golang.SimpleExpression;
import pgo.model.golang.Statement;
import pgo.model.golang.Token;
import pgo.model.intermediate.PGoType;
import pgo.model.intermediate.PGoVariable;
import pgo.model.tla.*;
import pgo.trans.PGoTransException;
import pgo.trans.intermediate.PGoTransIntermediateData;

/**
 * Test the conversion of parsed TLA asts to Go asts.
 *
 */
public class TLAToStatementTest {
	private Imports imports;
	private PGoTempData data;
	
	@Before
	public void init() {
		imports = new Imports();
		data = new PGoTempData(new PGoTransIntermediateData());
	}
	
	@Test
	public void testBool() throws PGoTransException {
		PGoTLABool tla = new PGoTLABool("TRUE", 0);
		Vector<Statement> expected = new Vector<>();
		expected.add(new Token("true"));
		assertEquals(expected, new TLAExprToGo(tla, imports, null).getStatements());
		tla = new PGoTLABool("FALSE", 0);
		expected.set(0, new Token("false"));
		assertEquals(expected, new TLAExprToGo(tla, imports, null).getStatements());
	}
	
	@Test
	public void testNumber() throws PGoTransException {
		PGoTLANumber tla = new PGoTLANumber("-15", 0);
		Vector<Statement> expected = new Vector<>();
		expected.add(new Token("-15"));
		assertEquals(expected, new TLAExprToGo(tla, imports, null).getStatements());
	}
	
	@Test
	public void testString() throws PGoTransException {
		PGoTLAString tla = new PGoTLAString("string", 0);
		Vector<Statement> expected = new Vector<>();
		expected.add(new Token("string"));
		assertEquals(expected, new TLAExprToGo(tla, imports, null).getStatements());
	}
	
	@Test
	public void testArith() throws PGoTransException {
		PGoTLASimpleArithmetic tla = new PGoTLASimpleArithmetic("*", new PGoTLANumber("3", 0), new PGoTLAVariable("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("int")));
		Vector<Statement> expected = new Vector<>();
		Vector<Statement> result = new TLAExprToGo(tla, imports, data).getStatements();
		Vector<Expression> se = new Vector<>();
		se.add(new Token("3"));
		se.add(new Token(" * "));
		se.add(new Token("x"));
		expected.add(new SimpleExpression(se));
		assertEquals(expected, result);
		tla = new PGoTLASimpleArithmetic("^", new PGoTLAVariable("y", 0), new PGoTLANumber("5", 0), 0);
		data.globals.put("y", PGoVariable.convert("y", PGoType.inferFromGoTypeName("int")));
		result = new TLAExprToGo(tla, imports, data).getStatements();
		expected.clear();
		Vector<Expression> params = new Vector<>();
		params.add(new Token("y"));
		params.add(new Token("5"));
		expected.add(new FunctionCall("math.Pow", params));
		assertEquals(expected, result);
		// TODO add test where cast is needed
	}
	
	@Test
	public void testGroup() throws PGoTransException {
		PGoTLAGroup tla = new PGoTLAGroup(new Vector<PGoTLA>() {
			{
				add(new PGoTLASimpleArithmetic("*", new PGoTLANumber("3", 0), new PGoTLAVariable("x", 0), 0));
			}
		}, 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("int")));
		Vector<Statement> expected = new Vector<>();
		Vector<Statement> result = new TLAExprToGo(tla, imports, data).getStatements();
		Vector<Expression> se = new Vector<>();
		se.add(new Token("("));
		se.add(new Token("3"));
		se.add(new Token(" * "));
		se.add(new Token("x"));
		se.add(new Token(")"));
		expected.add(new SimpleExpression(se));
		assertEquals(expected, result);
	}
	
	@Test
	public void testArray() {
		// TODO
	}
	
	@Test
	public void testFunction() {
		// TODO
	}
	
	@Test
	public void testSequence() throws PGoTransException {
		PGoTLASequence tla = new PGoTLASequence(new PGoTLANumber("1", 0), new PGoTLAVariable("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("int")));
		Vector<Statement> expected = new Vector<>();
		Vector<Expression> args = new Vector<>();
		args.add(new Token("1"));
		args.add(new Token("x"));
		expected.add(new FunctionCall("pgoutil.Sequence", args));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
	}
	
	@Test
	public void testBoolOp() throws PGoTransException {
		PGoTLABoolOp tla = new PGoTLABoolOp("/=", new PGoTLANumber("2", 0), new PGoTLAVariable("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("int")));
		Vector<Expression> expr = new Vector<>();
		Vector<Statement> expected = new Vector<>();
		expr.add(new Token("2"));
		expr.add(new Token(" != "));
		expr.add(new Token("x"));
		expected.add(new SimpleExpression(expr));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
		
		tla = new PGoTLABoolOp("\\/", new PGoTLAVariable("y", 0), new PGoTLAVariable("z", 0), 0);
		data.globals.put("y", PGoVariable.convert("y", PGoType.inferFromGoTypeName("bool")));
		data.globals.put("z", PGoVariable.convert("z", PGoType.inferFromGoTypeName("bool")));
		expr.clear();
		expr.add(new Token("y"));
		expr.add(new Token(" || "));
		expr.add(new Token("z"));
		expected.set(0, new SimpleExpression(expr));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
		// TODO add equality test for sets
	}
	
	@Test
	public void testSet() throws PGoTransException {
		PGoTLASet tla = new PGoTLASet(new Vector<>(), 0);
		Vector<Statement> expected = new Vector<>();
		expected.add(new FunctionCall("mapset.NewSet", new Vector<>()));
		assertEquals(expected, new TLAExprToGo(tla, imports, null).getStatements());
		
		Vector<TLAToken> between = new Vector<>();
		between.add(new TLAToken("1", 0, TLAToken.NUMBER));
		between.add(new TLAToken(",", 0, TLAToken.BUILTIN));
		between.add(new TLAToken("x", 0, TLAToken.IDENT));
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("float64")));
		tla = new PGoTLASet(between, 0);
		Vector<Expression> args = new Vector<>();
		args.add(new Token("1"));
		args.add(new Token("x"));
		expected.set(0, new FunctionCall("mapset.NewSet", args));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
		
		between.clear();
		between.add(new TLAToken("x", 0, TLAToken.IDENT));
		between.add(new TLAToken("\\in", 0, TLAToken.BUILTIN));
		between.add(new TLAToken("S", 0, TLAToken.IDENT));
		between.add(new TLAToken(":", 0, TLAToken.BUILTIN));
		between.add(new TLAToken("TRUE", 0, TLAToken.BUILTIN));
		tla = new PGoTLASet(between, 0);
		// TODO finish set constructor test
	}
	
	@Test
	public void testSetOp() throws PGoTransException {
		PGoTLASetOp tla = new PGoTLASetOp("\\union", new PGoTLASet(new Vector<>(), 0), new PGoTLAVariable("A", 0), 0);
		data.globals.put("A", PGoVariable.convert("A", PGoType.inferFromGoTypeName("set[int]")));
		Vector<Statement> expected = new Vector<>();
		Vector<Expression> args = new Vector<>();
		args.add(new FunctionCall("mapset.NewSet", new Vector<>()));
		expected.add(new FunctionCall("Union", args, new Token("A")));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
		
		tla = new PGoTLASetOp("\\notin", new PGoTLAVariable("a", 0), new PGoTLASet(new Vector<>(), 0), 0);
		data.globals.put("a", PGoVariable.convert("a", PGoType.inferFromGoTypeName("int")));
		Vector<Expression> se = new Vector<>();
		se.add(new Token("!"));
		args.clear();
		args.add(new Token("a"));
		se.add(new FunctionCall("Contains", args, new FunctionCall("mapset.NewSet", new Vector<>())));
		expected.set(0, new SimpleExpression(se));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
	}
	
	@Test
	public void testUnary() throws PGoTransException {
		PGoTLAUnary tla = new PGoTLAUnary("\\neg", new PGoTLAVariable("p", 0), 0);
		data.globals.put("p", PGoVariable.convert("p", PGoType.inferFromGoTypeName("bool")));
		Vector<Statement> expected = new Vector<>();
		Vector<Expression> expr = new Vector<>();
		expr.add(new Token("!"));
		expr.add(new Token("p"));
		expected.add(new SimpleExpression(expr));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
		
		tla = new PGoTLAUnary("SUBSET", new PGoTLAVariable("S", 0), 0);
		data.globals.put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("set[int]")));
		expected.set(0, new FunctionCall("PowerSet", new Vector<>(), new Token("S")));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
		// TODO add elt union and predicate operations
	}
	
	@Test
	public void testVar() throws PGoTransException {
		PGoTLAVariable tla = new PGoTLAVariable("varName", 0);
		data.globals.put("varName", PGoVariable.convert("varName", PGoType.inferFromGoTypeName("string")));
		Vector<Statement> expected = new Vector<>();
		expected.add(new Token("varName"));
		assertEquals(expected, new TLAExprToGo(tla, imports, data).getStatements());
	}
}
