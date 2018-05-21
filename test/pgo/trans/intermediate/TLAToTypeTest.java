package pgo.trans.intermediate;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import java.util.Arrays;
import java.util.Collections;
import java.util.Vector;

import org.junit.Before;
import org.junit.Test;

import pcal.PcalTranslate;
import pcal.TLAToken;
import pgo.model.intermediate.PGoCollectionType.PGoChan;
import pgo.model.intermediate.PGoCollectionType.PGoMap;
import pgo.model.intermediate.PGoCollectionType.PGoTuple;
import pgo.model.intermediate.PGoPrimitiveType.PGoDecimal;
import pgo.model.intermediate.PGoPrimitiveType.PGoInt;
import pgo.model.intermediate.PGoPrimitiveType.PGoString;
import pgo.model.intermediate.PGoType;
import pgo.model.intermediate.PGoVariable;
import pgo.model.tla.*;
import pgo.trans.PGoTransException;

/**
 * Test the TLAExprToType class.
 *
 */
public class TLAToTypeTest {

	private PGoTempData data;

	@Before
	public void setup() {
		data = new PGoTempData(new PGoTransIntermediateData());
	}

	@Test
	public void testArray() throws PGoTransException {
		PGoTLAArray tla = new PGoTLAArray(
				new Vector<>(Arrays.asList(
						new TLAToken("1", 0, TLAToken.NUMBER),
						new TLAToken(",", 0, TLAToken.BUILTIN),
						new TLAToken("2", 0, TLAToken.NUMBER),
						new TLAToken("+", 0, TLAToken.BUILTIN),
						new TLAToken("3", 0, TLAToken.NUMBER))),
				0);
		PGoVariable var = PGoVariable.convert("arr", PGoType.inferFromGoTypeName("tuple[int, float64]"));
		data.getLocals().put("arr", var);

		PGoType result = new TLAExprToType(tla, data, var, true).getType();
		assertTrue(result instanceof PGoTuple);
		assertEquals(2, ((PGoTuple) result).getLength());
		assertTrue(((PGoTuple) result).getType(1) instanceof PGoDecimal);

		var = PGoVariable.convert("channel", PGoType.inferFromGoTypeName("chan[int]"));
		data.getLocals().clear();
		data.getLocals().put("channel", var);
		result = new TLAExprToType(tla, data, var, true).getType();
		assertTrue(result instanceof PGoChan);
		assertEquals(PGoType.inferFromGoTypeName("int"), ((PGoChan) result).getElementType());

		tla = new PGoTLAArray(
				new Vector<>(Arrays.asList(
						new TLAToken("x", 0, TLAToken.IDENT),
						new TLAToken("\\in", 0, TLAToken.BUILTIN),
						new TLAToken("S", 0, TLAToken.IDENT),
						new TLAToken(",", 0, TLAToken.BUILTIN),
						new TLAToken("y", 0, TLAToken.IDENT),
						new TLAToken("\\in", 0, TLAToken.BUILTIN),
						new TLAToken("T", 0, TLAToken.IDENT),
						new TLAToken("|->", 0, TLAToken.BUILTIN),
						new TLAToken("x", 0, TLAToken.IDENT))),
				0);
		data.getLocals().clear();
		data.getLocals().put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("set[set[tuple[int...]]]")));
		data.getLocals().put("T", PGoVariable.convert("T", PGoType.inferFromGoTypeName("set[string]")));
		result = new TLAExprToType(tla, data, true).getType();
		assertTrue(result instanceof PGoMap);
		assertEquals(PGoType.inferFromGoTypeName("tuple[set[tuple[int...]], string]"), ((PGoMap) result).getKeyType());
		assertEquals(PGoType.inferFromGoTypeName("set[tuple[int...]]"), ((PGoMap) result).getElementType());
	}

	@Test(expected = PGoTransException.class)
	public void testArrayFail() throws PGoTransException {
		PGoTLAArray tla = new PGoTLAArray(
				new Vector<>(Arrays.asList(
						new TLAToken("1", 0, TLAToken.NUMBER),
						new TLAToken(",", 0, TLAToken.BUILTIN),
						new TLAToken("2", 0, TLAToken.NUMBER),
						new TLAToken("+", 0, TLAToken.BUILTIN),
						new TLAToken("3", 0, TLAToken.NUMBER))),
				0);
		PGoVariable var = PGoVariable.convert("arr", PGoType.inferFromGoTypeName("tuple[int, string]"));
		data.getLocals().put("arr", var);
		PGoType result = new TLAExprToType(tla, data, var, true).getType();
	}

	@Test
	public void testBool() throws PGoTransException {
		PGoTLABool tla = new PGoTLABool("TRUE", 0);
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("bool"), result);
	}

	@Test
	public void testBoolOp() throws PGoTransException {
		PGoTLABoolOp tla = new PGoTLABoolOp("/\\", new PGoTLABool("TRUE", 0), new PGoTLAGeneralIdentifier("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("bool")));
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("bool"), result);
	}

	@Test(expected = PGoTransException.class)
	public void testAndOrFail() throws PGoTransException {
		PGoTLABoolOp tla = new PGoTLABoolOp("\\/", new PGoTLABool("FALSE", 0), new PGoTLANumber("3", 0), 0);
		new TLAExprToType(tla, data, true);
	}

	@Test(expected = PGoTransException.class)
	public void testComparatorFail() throws PGoTransException {
		PGoTLABoolOp tla = new PGoTLABoolOp("<=", new PGoTLAGeneralIdentifier("x", 0), new PGoTLANumber("1.5", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("bool")));
		new TLAExprToType(tla, data, true);
	}

	@Test
	public void testFunction() throws PGoTransException {
		Vector<TLAToken> toks = new Vector<>();
		toks.add(new TLAToken("3", 0, TLAToken.NUMBER));
		toks.add(new TLAToken(",", 0, TLAToken.BUILTIN));
		toks.add(new TLAToken("a", 0, TLAToken.STRING));
		PGoTLAFunctionCall tla = new PGoTLAFunctionCall("foo", toks, 0);
		Vector<Vector<TLAToken>> foo = new Vector<>();
		foo.add(new Vector<>());
		foo.get(0).add(new TLAToken("b", 0, TLAToken.IDENT));
		data.defns.put("foo", new PGoTLADefinition("foo",
				Arrays.asList(
						PGoVariable.convert("a", PGoType.inferFromGoTypeName("int")),
						PGoVariable.convert("b", PGoType.inferFromGoTypeName("string"))),
				PcalTranslate.MakeExpr(foo), null, 0));
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("string"), result);

		data.defns.clear();
		data.globals.put("foo",
				PGoVariable.convert("foo", PGoType.inferFromGoTypeName("map[tuple[int, string]]set[int]")));
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), result);

		data.globals.clear();
		toks.clear();
		toks.add(new TLAToken("a", 0, TLAToken.IDENT));
		tla = new PGoTLAFunctionCall("Len", toks, 0);
		data.globals.put("a", PGoVariable.convert("a", PGoType.inferFromGoTypeName("string")));
		result = new TLAExprToType(tla, data, true).getType();
		assertTrue(result instanceof PGoInt);

		data.globals.clear();
		data.globals.put("a", PGoVariable.convert("a", PGoType.inferFromGoTypeName("tuple[int]")));
		result = new TLAExprToType(tla, data, true).getType();
		assertTrue(result instanceof PGoInt);

		tla = new PGoTLAFunctionCall("foo", toks, 0);
		data.globals.clear();
		data.globals.put("a", PGoVariable.convert("a", PGoType.inferFromGoTypeName("int")));
		data.globals.put("foo", PGoVariable.convert("foo", PGoType.inferFromGoTypeName("[]string")));
		result = new TLAExprToType(tla, data, true).getType();
		assertTrue(result instanceof PGoString);
	}

	@Test
	public void testGroup() throws PGoTransException {
		PGoTLAGroup tla = new PGoTLAGroup(Collections.singletonList(new PGoTLANumber("3", 0)), 0);
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("int"), result);
	}

	@Test
	public void testNumber() throws PGoTransException {
		PGoTLANumber tla = new PGoTLANumber("5", 0);
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("int"), result);
		tla = new PGoTLANumber("3.5", 0);
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("float64"), result);
	}

	@Test
	public void testSequence() throws PGoTransException {
		PGoTLASequence tla = new PGoTLASequence(new PGoTLANumber("0", 0), new PGoTLAGeneralIdentifier("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("natural")));
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), result);
	}

	@Test(expected = PGoTransException.class)
	public void testSequenceFail() throws PGoTransException {
		PGoTLASequence tla = new PGoTLASequence(new PGoTLANumber("-1", 0), new PGoTLAGeneralIdentifier("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("natural")));
		try {
			new TLAExprToType(tla, data, true);
		} catch (PGoTransException e) {
			fail("Unexpected PGoTransException");
		}
		data.globals.clear();
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("float64")));
		new TLAExprToType(tla, data, true);
	}

	@Test
	public void testSet() throws PGoTransException {
		PGoTLASet tla = new PGoTLASet(
				new Vector<>(Arrays.asList(
						new TLAToken("1", 0, TLAToken.NUMBER, 0),
						new TLAToken(",", 0, TLAToken.BUILTIN, 0),
						new TLAToken("2", 0, TLAToken.NUMBER, 0))),
				0);
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), result);
		tla = new PGoTLASet(
				new Vector<>(Arrays.asList(
						new TLAToken("x", 0, TLAToken.IDENT, 0),
						new TLAToken("\\in", 0, TLAToken.BUILTIN, 0),
						new TLAToken("Nat", 0, TLAToken.IDENT, 0),
						new TLAToken(":", 0, TLAToken.BUILTIN, 0),
						new TLAToken("TRUE", 0, TLAToken.BUILTIN))),
				0);
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[natural]"), result);
	}

	@Test(expected = PGoTransException.class)
	public void testSetFail() throws PGoTransException {
		PGoTLASet tla = new PGoTLASet(
				new Vector<>(Arrays.asList(
						new TLAToken("1", 0, TLAToken.NUMBER, 0),
						new TLAToken(",", 0, TLAToken.BUILTIN, 0),
						new TLAToken("2.5", 0, TLAToken.NUMBER, 0),
						new TLAToken(",", 0, TLAToken.BUILTIN, 0),
						new TLAToken("x", 0, TLAToken.IDENT, 0))),
				0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("natural")));
		try {
			PGoType result = new TLAExprToType(tla, data, true).getType();
			assertEquals(PGoType.inferFromGoTypeName("set[float64]"), result);
		} catch (PGoTransException e) {
			fail("Unexpected PGoTransException");
		}
		tla = new PGoTLASet(
				new Vector<>(Arrays.asList(
						new TLAToken("1", 0, TLAToken.NUMBER, 0),
						new TLAToken(",", 0, TLAToken.BUILTIN, 0),
						new TLAToken("2.5", 0, TLAToken.NUMBER, 0),
						new TLAToken(",", 0, TLAToken.BUILTIN, 0),
						new TLAToken("TRUE", 0, TLAToken.BUILTIN, 0))),
				0);
		new TLAExprToType(tla, data, true);
	}

	@Test
	public void testSetOp() throws PGoTransException {
<<<<<<< HEAD
		PGoTLASet set = new PGoTLASet(new Vector<TLAToken>() {
			{
				add(new TLAToken("1", 0, TLAToken.NUMBER, 0));
				add(new TLAToken(",", 0, TLAToken.BUILTIN, 0));
				add(new TLAToken("2.5", 0, TLAToken.NUMBER, 0));
			}
		}, 0);
		PGoTLASetOp tla = new PGoTLASetOp("\\union", set, new PGoTLAGeneralIdentifier("T", 0), 0);
=======
		PGoTLASet set = new PGoTLASet(
				new Vector<>(Arrays.asList(
						new TLAToken("1", 0, TLAToken.NUMBER, 0),
						new TLAToken(",", 0, TLAToken.BUILTIN, 0),
						new TLAToken("2.5", 0, TLAToken.NUMBER, 0))),
				0);
		PGoTLASetOp tla = new PGoTLASetOp("\\union", set, new PGoTLAVariable("T", 0), 0);
>>>>>>> type-system
		data.globals.put("T", PGoVariable.convert("T", PGoType.inferFromGoTypeName("set[int]")));
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[float64]"), result);

		tla = new PGoTLASetOp("\\in", new PGoTLANumber("3", 0), set, 0);
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("bool"), result);

		set = new PGoTLASet(new Vector<TLAToken>(), 0);
		tla = new PGoTLASetOp("\\intersect", set, new PGoTLAGeneralIdentifier("T", 0), 0);
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), result);
	}

	@Test(expected = PGoTransException.class)
	public void testSetOpFail() throws PGoTransException {
		PGoTLASet set = null, set2 = null;
		try {
			set = new PGoTLASet(
					new Vector<>(Arrays.asList(
							new TLAToken("1", 0, TLAToken.NUMBER, 0),
							new TLAToken(",", 0, TLAToken.BUILTIN, 0),
							new TLAToken("2", 0, TLAToken.NUMBER, 0)))
					,
					0);
			set2 = new PGoTLASet(
					new Vector<>(Collections.singletonList(new TLAToken("a", 0, TLAToken.STRING, 0))),
					0);
		} catch (PGoTransException e) {
			fail("Unexpected PGoTransException: " + e.getMessage());
		}
		PGoTLASetOp tla = new PGoTLASetOp("\\cup", set, set2, 0);
		PGoType result = new TLAExprToType(tla, data, true).getType();
		fail("Expected set types set[int] and set[string] to be incompatible");
	}

	@Test(expected = PGoTransException.class)
	public void testSetInFail() throws PGoTransException {
		PGoTLAGeneralIdentifier l = new PGoTLAGeneralIdentifier("l", 0), r = new PGoTLAGeneralIdentifier("r", 0);
		data.globals.put("l", PGoVariable.convert("l", PGoType.inferFromGoTypeName("string")));
		data.globals.put("r", PGoVariable.convert("r", PGoType.inferFromGoTypeName("set[set[string]]")));
		PGoTLASetOp tla = new PGoTLASetOp("\\in", l, r, 0);
		new TLAExprToType(tla, data, true);
	}

	@Test
	public void testSimpleArith() throws PGoTransException {
		PGoTLASimpleArithmetic tla = new PGoTLASimpleArithmetic("*", new PGoTLANumber("3", 0), new PGoTLANumber("4", 0),
				0);
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("int"), result);
		tla = new PGoTLASimpleArithmetic("/", new PGoTLANumber("3", 0), new PGoTLANumber("4", 0), 0);
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("float64"), result);
		tla = new PGoTLASimpleArithmetic("+", new PGoTLANumber("2", 0), new PGoTLAGeneralIdentifier("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("float64")));
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("float64"), result);
	}

	@Test(expected = PGoTransException.class)
	public void testSimpleArithFail() throws PGoTransException {
		PGoTLAExpression tla = new PGoTLASimpleArithmetic("+", new PGoTLAString("string", 0), new PGoTLAGeneralIdentifier("x", 0), 0);
		data.globals.put("x", PGoVariable.convert("x", PGoType.inferFromGoTypeName("string")));
		new TLAExprToType(tla, data, true);
	}

	@Test
	public void testString() throws PGoTransException {
		PGoTLAString tla = new PGoTLAString("string", 0);
		assertEquals(PGoType.inferFromGoTypeName("string"), new TLAExprToType(tla, data, true).getType());
	}

	@Test
	public void testSuchThat() throws PGoTransException {
		Vector<PGoTLAExpression> lhs = new Vector<>();
		lhs.add(new PGoTLASetOp("\\in", new PGoTLAGeneralIdentifier("x", 0), new PGoTLAGeneralIdentifier("S", 0), 0));
		Vector<TLAToken> rhs = new Vector<>();
		rhs.add(new TLAToken("TRUE", 0, TLAToken.BUILTIN, 0));
		PGoTLAVariadic tla = new PGoTLAVariadic(":", lhs, rhs, 0);
		data.globals.put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("set[set[int]]")));
		PGoType result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), result);

		lhs = new Vector<>();
		lhs.add(new PGoTLASimpleArithmetic("*", new PGoTLAGeneralIdentifier("x", 0), new PGoTLAGeneralIdentifier("y", 0), 0));
		rhs = new Vector<>();
		rhs.add(new TLAToken("x", 0, TLAToken.IDENT, 0));
		rhs.add(new TLAToken("\\in", 0, TLAToken.BUILTIN, 0));
		rhs.add(new TLAToken("S", 0, TLAToken.IDENT, 0));
		rhs.add(new TLAToken(",", 0, TLAToken.BUILTIN, 0));
		rhs.add(new TLAToken("y", 0, TLAToken.IDENT, 0));
		rhs.add(new TLAToken("\\in", 0, TLAToken.BUILTIN, 0));
		rhs.add(new TLAToken("S", 0, TLAToken.IDENT, 0));
		tla = new PGoTLAVariadic(":", lhs, rhs, 0);
		data.globals.clear();
		data.globals.put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("set[int]")));
		result = new TLAExprToType(tla, data, true).getType();
		assertEquals(PGoType.inferFromGoTypeName("int"), result);
	}

	@Test
	public void testUnary() throws PGoTransException {
		PGoTLAUnary tla = new PGoTLAUnary("~", new PGoTLABool("FALSE", 0), 0);
		assertEquals(PGoType.inferFromGoTypeName("bool"), new TLAExprToType(tla, data, true).getType());

		tla = new PGoTLAUnary("UNION", new PGoTLAGeneralIdentifier("S", 0), 0);
		data.globals.put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("set[set[int]]")));
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), new TLAExprToType(tla, data, true).getType());

		tla = new PGoTLAUnary("SUBSET", new PGoTLAGeneralIdentifier("S", 0), 0);
		assertEquals(PGoType.inferFromGoTypeName("set[set[set[int]]]"), new TLAExprToType(tla, data, true).getType());

		Vector<PGoTLAExpression> lhs = new Vector<>();
		Vector<TLAToken> rhs = new Vector<>();
		lhs.add(new PGoTLASetOp("\\in", new PGoTLAGeneralIdentifier("x", 0), new PGoTLAGeneralIdentifier("S", 0), 0));
		rhs.add(new TLAToken("TRUE", 0, TLAToken.BUILTIN, 0));
		PGoTLAVariadic arg = new PGoTLAVariadic(":", lhs, rhs, 0);
		tla = new PGoTLAUnary("CHOOSE", arg, 0);
		assertEquals(PGoType.inferFromGoTypeName("set[int]"), new TLAExprToType(tla, data, true).getType());
	}

	@Test(expected = PGoTransException.class)
	public void testEltUnionFail() throws PGoTransException {
		PGoTLAUnary tla = new PGoTLAUnary("UNION", new PGoTLAGeneralIdentifier("S", 0), 0);
		data.globals.put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("set[[]int]")));
		new TLAExprToType(tla, data, true);
	}

	@Test(expected = PGoTransException.class)
	public void testPowersetFail() throws PGoTransException {
		PGoTLAUnary tla = new PGoTLAUnary("SUBSET", new PGoTLAGeneralIdentifier("S", 0), 0);
		data.globals.put("S", PGoVariable.convert("S", PGoType.inferFromGoTypeName("map[string]int")));
		new TLAExprToType(tla, data, true);
	}

	@Test(expected = PGoTransException.class)
	public void testNegateFail() throws PGoTransException {
		PGoTLAUnary tla = new PGoTLAUnary("~", new PGoTLANumber("3", 0), 0);
		new TLAExprToType(tla, data, true);
	}

	@Test
	public void testVar() throws PGoTransException {
		PGoTLAGeneralIdentifier tla = new PGoTLAGeneralIdentifier("A", 0);
		data.globals.put("A", PGoVariable.convert("A", PGoType.inferFromGoTypeName("set[[][]int]")));
		assertEquals(PGoType.inferFromGoTypeName("set[[][]int]"), new TLAExprToType(tla, data, true).getType());
	}
}
